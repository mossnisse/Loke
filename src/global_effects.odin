package lokec

import "core:fmt"
import "core:slice"

// design.md "Global write effects": a call writes whatever static-duration
// storage its callee may write, directly or through its own callees. Each body's
// set is settled over the whole program before provenance runs, and a call then
// counts as a write to every global in its callee's set, so a borrow of one that
// is still in use across the call conflicts exactly as a local write would. A
// read settles the same way and counts as a read there, which only a mutable
// borrow conflicts with.

// What one call may reach: a direct procedure, a `dyn` slot, or any procedure of
// a compatible type called through a value.
Effect_Call :: struct {
	callee:        Symbol_Id,
	type:          Type_Id,
	dyn_interface: Symbol_Id,
	dyn_index:     int,
	// Through a procedure value held in this body's parameter or local
	// `variable`, whose values the write effects resolve
	// (`Compiler.called_values`), or the procedure a callable view converted at
	// the call holds.
	variable:      Symbol_Id,
	held:          Symbol_Id,
	// A direct call's arguments that may be followed, each with the callee
	// parameter it binds; one missing there may be any procedure of its type.
	// Kept only until the body is summarized (`Compiler.argument_values`).
	args:          []Effect_Arg,
	// A task's call on its worker: its values are those the `spawn` in this
	// procedure resolved, where none of its parameters are `run`'s.
	values_from:   Symbol_Id,
	// Where the call is, and while the thread summaries collect, the region of
	// each argument by callee parameter, nil when no argument has one.
	span:          Span,
	regions:       []Region_Set,
	// The call is a bare block's task, which runs on a thread of its own: its
	// `thread_local` writes are that thread's, not the caller's (design.md
	// "Globals while tasks run"). A pooled block's task may run on the thread
	// joining it, so its writes count, at that join.
	elsewhere:     bool,
}

// A call in one body; a generic's instances share its spans.
Call_Site :: struct {
	body: Symbol_Id,
	span: Span,
}

// What a procedure value may be.
Effect_Arg :: struct {
	kind:      Effect_Arg_Kind,
	binding:   int,       // in `Effect_Call.args`: the callee parameter it binds
	parameter: int,       // `.Parameter`: the body's own parameter
	symbol:    Symbol_Id, // `.Procedure`, or `.Variable` until summarized
}

Effect_Arg_Kind :: enum u8 {
	Other,     // any procedure of its type
	Parameter, // what the caller passed for the parameter
	Procedure, // a named procedure
	Variable,  // whatever a variable of this body may hold
	Nil,       // none: a declaration without a value
}

// A value stored into a variable that holds a procedure. A declaration's makes
// the variable followed; a parameter is followed from the start.
Effect_Store :: struct {
	variable: Symbol_Id,
	value:    Effect_Arg,
	declares: bool,
}

// A call passing a named procedure for a `@(cross_thread)` parameter, and that
// procedure.
Thread_Spawn :: struct {
	entry: Symbol_Id,
	span:  Span,
}

// The bodies an indirect call may reach, kept from the write effects for the
// summaries settled after them: every clean body, and which are used as values.
Effect_Body :: struct {
	symbol: Symbol_Id,
	type:   Type_Id,
}

Effect_Program :: struct {
	bodies:        []Effect_Body,
	index_of:      map[Symbol_Id]int,
	used_as_value: map[Symbol_Id]bool,
	// Per body, as `bodies`: all it does, and its own part apart from the
	// procedure values it received and calls (`Callback_Summary`), which is all
	// of it for a body that calls none.
	whole:         []Body_Summary,
	own:           []Body_Summary,
}

// design.md "Global write effects", "Globals while tasks run": the globals a
// body may write or read, those whose stored carriers it may reach, and the
// allocator regions it may use. The last two come from the thread summaries,
// settled after the rest, and stay empty when no check reads them.
Body_Summary :: struct {
	writes: []Symbol_Id,
	reads:  []Symbol_Id,
	reach:  []Global_Effect,
	use:    Region_Set,
}

// The whole summary of `body`, or an empty one for a body the effects did not
// settle over.
body_summary :: proc(c: ^Compiler, body: Symbol_Id) -> Body_Summary {
	program := &c.effect_program
	if index, found := program.index_of[body]; found && index < len(program.whole) {
		return program.whole[index]
	}
	return {}
}

// What one part of a call contributes: the whole summary of a body, or a
// direct callee's own part apart from its callbacks.
@(private)
part_summary :: proc(c: ^Compiler, part: Call_Part) -> ^Body_Summary {
	program := &c.effect_program
	return &program.whole[part.body] if part.whole else &program.own[part.body]
}

// Globals in the order found, which diagnostics show, with a bit for each by its
// dense number: a body near `main` may reach most of a program's.
@(private = "file")
Global_Set :: struct {
	list: [dynamic]Symbol_Id,
	row:  []u8,
}

// One body's own writes and calls, before the fixed point.
@(private = "file")
Body_Effects :: struct {
	symbol: Symbol_Id,
	type:   Type_Id,
	// Its own part, apart from the callbacks it calls, then all of it.
	own:       Global_Set,
	writes:    Global_Set,
	own_reads: Global_Set,
	reads:     Global_Set,
	calls:     []Effect_Call,
	// The `hook(copy)`s it may run, which take no part in the other summaries.
	copy_hooks: []Symbol_Id,
}

// design.md "Global write effects": `own` leaves out what received callbacks run,
// which is reported where the crossing call passes them.
@(private = "file")
warn_thread_races :: proc(c: ^Compiler, bodies: []Body_Effects) {
	for spawn in c.thread_spawns {
		index, found := c.effect_program.index_of[spawn.entry]
		if !found {
			continue
		}
		for global in bodies[index].own.list {
			sym := symbol_of(c, global)
			if sym == nil || sym.duration == .Thread_Local || sym.synchronized {
				continue
			}
			warnf(
				c, spawn.span, "L0707",
				"`%s` writes `%s`, which every thread shares, so this thread may race with another",
				identifier_text(c, symbol_of(c, spawn.entry).name), identifier_text(c, sym.name),
			)
			add_notef(c, sym.span, "declared here; make it `thread_local`, an `Atomic`, or a `thread.Mutex`")
		}
	}
}

// ------------------------------------------------------- per-call effects --

// design.md "Global write effects": a parameter a body calls, itself or by
// passing it where a callee calls its own, runs what each caller passes there.
// `elsewhere`: only on a bare block's task, whose `thread_local` writes are its
// own thread's. `span` is a call that runs it.
Called_Parameter :: struct {
	parameter: int,
	elsewhere: bool,
	span:      Span,
}

// The procedure values a body received and calls, so each call of the body
// takes in what its caller passes there instead of every procedure of the
// parameter's type: its own part (`Effect_Program.own`) leaves them out, and
// its whole summary adds that union. `regions` is, per `called`, the regions of
// what the body passes the callback.
Callback_Summary :: struct {
	called:  []Called_Parameter,
	regions: []Region_Set,
}

// One body whose summary a call takes in: the direct callee's own part, or all
// of what a procedure value, a callback the callee calls, or a member of a
// union runs. A callback is the callee `via`'s `called[callback]`, given the
// regions `via` passes it.
@(private)
Call_Part :: struct {
	body:      int,
	whole:     bool,
	elsewhere: bool,
	via:       int,
	callback:  int,
}

// The procedure-valued arguments a call passes, and what the value it goes
// through may be, as the write effects resolved them at its site. A task's
// call on its worker is resolved where its `spawn` is, whose parameters are
// not this body's.
@(private)
call_values :: proc(c: ^Compiler, body: Symbol_Id, call: Effect_Call) -> (args: []Effect_Arg, values: []Effect_Arg, followed: bool) {
	if call.held != INVALID_SYMBOL {
		return nil, slice.clone([]Effect_Arg{{kind = .Procedure, symbol = call.held}}, context.temp_allocator), true
	}
	from := call.values_from if call.values_from != INVALID_SYMBOL else body
	site := Call_Site{body = from, span = call.span}
	args = c.argument_values[site]
	values, followed = c.called_values[site]
	if from != body {
		args, values = foreign_values(args), foreign_values(values)
	}
	return
}

@(private = "file")
foreign_values :: proc(values: []Effect_Arg) -> []Effect_Arg {
	out := make([]Effect_Arg, len(values), context.temp_allocator)
	for value, index in values {
		out[index] = value
		if value.kind == .Parameter {
			out[index] = Effect_Arg{binding = value.binding}
		}
	}
	return out
}

// What one call in `body` takes in. A direct call takes its callee's own part,
// and for each callback the callee calls, what this call passes there; a call
// through a followed value, what each value runs; any other, every body its
// union holds. A value `body` itself received is its caller's to resolve
// while the summaries settle (`Called_Parameter`), or with `open`, any
// procedure of its type.
@(private)
call_parts :: proc(c: ^Compiler, body: Symbol_Id, call: Effect_Call, open: bool) -> []Call_Part {
	program := &c.effect_program
	out := make([dynamic]Call_Part, 0, 2, context.temp_allocator)
	whole := Call_Part{whole = true, elsewhere = call.elsewhere, via = -1, callback = -1}
	args, values, followed := call_values(c, body, call)
	switch {
	case call.callee != INVALID_SYMBOL:
		target, found := program.index_of[call.callee]
		if !found {
			break
		}
		append(&out, Call_Part{body = target, elsewhere = call.elsewhere, via = -1, callback = -1})
		summary := c.callback_summaries[call.callee]
		if summary == nil {
			break
		}
		for called, position in summary.called {
			type := proc_parameter_type(c, program.bodies[target].type, called.parameter)
			part := Call_Part{whole = true, elsewhere = call.elsewhere || called.elsewhere, via = target, callback = position}
			bound := false
			for arg in args {
				if arg.binding == called.parameter {
					bound = true
					value_parts(c, &out, arg, any_value_call(c, type), part, open)
				}
			}
			if !bound {
				value_parts(c, &out, Effect_Arg{}, any_value_call(c, type), part, open)
			}
		}
	case followed:
		any := Effect_Call{type = call.type, dyn_interface = call.dyn_interface, dyn_index = call.dyn_index}
		for value in values {
			value_parts(c, &out, value, any, whole, open)
		}
	case:
		for reached in effect_targets(c, call) {
			part := whole
			part.body = reached
			append(&out, part)
		}
	}
	return out[:]
}

// The parts one value contributes; `any` reaches every value it may be.
@(private = "file")
value_parts :: proc(c: ^Compiler, out: ^[dynamic]Call_Part, value: Effect_Arg, any: Effect_Call, part: Call_Part, open: bool) {
	program := &c.effect_program
	#partial switch value.kind {
	case .Procedure:
		if index, found := program.index_of[value.symbol]; found {
			named := part
			named.body = index
			append(out, named)
		}
		return
	case .Nil:
		return
	case .Parameter:
		if !open {
			return
		}
	}
	for reached in effect_targets(c, any) {
		member := part
		member.body = reached
		append(out, member)
	}
}

// A call reaching any value of `type`: any procedure of a procedure type, or
// whatever a `dyn proc` view of its signature may run.
@(private = "file")
any_value_call :: proc(c: ^Compiler, type: Type_Id) -> Effect_Call {
	if signature, view, _ := callable_signature(c, type); view != INVALID_SYMBOL {
		return Effect_Call{dyn_interface = view, type = signature}
	}
	return Effect_Call{type = type}
}

// What a body's whole summary adds to its own part: every procedure of each
// called parameter's type, given the regions the body passes it.
@(private)
closing_parts :: proc(c: ^Compiler, index: int) -> []Call_Part {
	program := &c.effect_program
	summary := c.callback_summaries[program.bodies[index].symbol]
	if summary == nil {
		return nil
	}
	out := make([dynamic]Call_Part, 0, 2, context.temp_allocator)
	for called, position in summary.called {
		type := proc_parameter_type(c, program.bodies[index].type, called.parameter)
		part := Call_Part{whole = true, elsewhere = called.elsewhere, via = index, callback = position}
		value_parts(c, &out, Effect_Arg{}, any_value_call(c, type), part, true)
	}
	return out[:]
}

// Which parameters each body calls, through a variable that may hold one, or
// by passing one where a callee calls its own. Settled before the effects,
// which need it to tell a body's own part from its callbacks.
@(private = "file")
settle_called_parameters :: proc(c: ^Compiler, bodies: []Body_Effects) -> [][dynamic]Called_Parameter {
	program := &c.effect_program
	called := make([][dynamic]Called_Parameter, len(bodies), context.temp_allocator)
	callers := make([][dynamic]int, len(bodies), context.temp_allocator)
	for &list in called {
		list = make([dynamic]Called_Parameter, context.temp_allocator)
	}
	for &list in callers {
		list = make([dynamic]int, context.temp_allocator)
	}
	for body, index in bodies {
		for call in body.calls {
			if target, found := program.index_of[call.callee]; found {
				append(&callers[target], index)
			}
		}
	}
	queue := body_queue_make(len(bodies))
	for index in worklist_pop(&queue) {
		grew := false
		for call in bodies[index].calls {
			args, values, followed := call_values(c, bodies[index].symbol, call)
			if target, found := program.index_of[call.callee]; found {
				for passed in called[target] {
					for arg in args {
						if arg.binding == passed.parameter && arg.kind == .Parameter {
							grew |= add_called_parameter(&called[index], arg.parameter, call.elsewhere || passed.elsewhere, call.span)
						}
					}
				}
			} else if followed {
				for value in values {
					if value.kind == .Parameter {
						grew |= add_called_parameter(&called[index], value.parameter, call.elsewhere, call.span)
					}
				}
			}
		}
		if grew {
			worklist_wake_all(&queue, callers[index][:])
		}
	}
	return called
}

// A parameter called on the body's own thread is not only a task's.
@(private = "file")
add_called_parameter :: proc(list: ^[dynamic]Called_Parameter, parameter: int, elsewhere: bool, span: Span) -> bool {
	for &existing in list {
		if existing.parameter == parameter {
			if existing.elsewhere && !elsewhere {
				existing.elsewhere = false
				return true
			}
			return false
		}
	}
	append(list, Called_Parameter{parameter = parameter, elsewhere = elsewhere, span = span})
	return true
}

@(private = "file")
proc_parameter_type :: proc(c: ^Compiler, proc_type: Type_Id, index: int) -> Type_Id {
	info := underlying_info(c, proc_type)
	if info == nil || index >= len(info.parameters) {
		return INVALID_TYPE
	}
	return info.parameters[index]
}

// A body fixed point visits the latest woken body first. Every body is
// queued, to be visited first to last.
@(private)
body_queue_make :: proc(count: int) -> Worklist {
	queue := worklist_make(count, context.temp_allocator, latest_first = true)
	for index := count - 1; index >= 0; index -= 1 {
		worklist_wake(&queue, index)
	}
	return queue
}

// A fixed point over each body's call parts `parts`, as the write effects and the
// thread summaries settle: `closing` is what each whole summary adds to its own
// part (`closing_parts`), and a body that grew wakes only the bodies that read
// its summaries, through the parts of their calls or of their whole summaries.
@(private)
Part_Fixpoint :: struct {
	closing: [][]Call_Part,
	readers: [][dynamic]int,
	queue:   Worklist,
}

@(private)
part_fixpoint_make :: proc(c: ^Compiler, parts: [][]Call_Part) -> Part_Fixpoint {
	closing := make([][]Call_Part, len(parts), context.temp_allocator)
	readers := make([][dynamic]int, len(parts), context.temp_allocator)
	for &list in readers {
		list = make([dynamic]int, context.temp_allocator)
	}
	for index in 0 ..< len(parts) {
		closing[index] = closing_parts(c, index)
		for part in parts[index] {
			append(&readers[part.body], index)
		}
		for part in closing[index] {
			append(&readers[part.body], index)
		}
	}
	return {closing, readers, body_queue_make(len(parts))}
}

@(private)
part_fixpoint_grew :: proc(settle: ^Part_Fixpoint, index: int) {
	worklist_wake_all(&settle.queue, settle.readers[index][:])
}

global_is_thread_local :: proc(c: ^Compiler, global: Symbol_Id) -> bool {
	sym := symbol_of(c, global)
	return sym != nil && sym.duration == .Thread_Local
}

// The regions a callback is given, in its callee's terms; unknown until the
// thread summaries settle them.
@(private)
callback_region :: proc(c: ^Compiler, part: Call_Part) -> Region_Set {
	summary := c.callback_summaries[c.effect_program.bodies[part.via].symbol]
	if part.callback >= len(summary.regions) {
		return Region_Set{unknown = true}
	}
	return summary.regions[part.callback]
}

// What a call reached through `target` is said to do in a diagnostic.
@(private)
effect_call_description :: proc(c: ^Compiler, target: Effect_Call, verb, dropped, described: string, unnamed: bool) -> string {
	sym := symbol_of(c, target.callee)
	switch {
	case described != "":
		return fmt.tprintf("%s by %s", verb, described)
	case sym == nil:
		return fmt.tprintf("%s by a procedure this call may reach", verb)
	case dropped == "":
		return fmt.tprintf("%s by `%s`", verb, identifier_text(c, sym.name))
	case unnamed:
		return fmt.tprintf("%s by `%s` when %s is dropped", verb, identifier_text(c, sym.name), dropped)
	}
	return fmt.tprintf("%s by `%s` when `%s` is dropped", verb, identifier_text(c, sym.name), dropped)
}

// The globals whose stored carriers one call may reach, from the thread
// summaries, with its callbacks resolved as its writes are.
@(private)
effect_call_reach :: proc(c: ^Compiler, body: Symbol_Id, target: Effect_Call) -> []Global_Effect {
	out := effect_list_make(context.temp_allocator)
	for part in call_parts(c, body, target, open = true) {
		for reached in part_summary(c, part).reach {
			add_global_effect(&out, reached.global, reached.source)
		}
	}
	return out.list[:]
}

// The settled writes of one call. A union is settled once per key.
@(private)
effect_call_writes :: proc(c: ^Compiler, body: Symbol_Id, target: Effect_Call) -> []Symbol_Id {
	return effect_call_globals(c, body, target, writes = true)
}

@(private)
effect_call_reads :: proc(c: ^Compiler, body: Symbol_Id, target: Effect_Call) -> []Symbol_Id {
	return effect_call_globals(c, body, target, writes = false)
}

@(private = "file")
effect_call_globals :: proc(c: ^Compiler, body: Symbol_Id, target: Effect_Call, writes: bool) -> []Symbol_Id {
	globals_of :: proc(summary: Body_Summary, writes: bool) -> []Symbol_Id {
		return summary.writes if writes else summary.reads
	}
	switch {
	case target.callee != INVALID_SYMBOL:
		if c.callback_summaries[target.callee] == nil {
			return globals_of(body_summary(c, target.callee), writes)
		}
	case target.held == INVALID_SYMBOL && target.variable == INVALID_SYMBOL:
		indirect := &c.indirect_writes if writes else &c.indirect_reads
		key := effect_key(target)
		if globals, found := indirect[key]; found {
			return globals
		}
		globals := global_list_make()
		for reached in effect_targets(c, target) {
			for global in globals_of(c.effect_program.whole[reached], writes) {
				global_list_add(&globals, global)
			}
		}
		settled := slice.clone(globals.list[:], c.semantic_allocator)
		indirect[key] = settled
		return settled
	}
	out := global_list_make()
	for part in call_parts(c, body, target, open = true) {
		for global in globals_of(part_summary(c, part)^, writes) {
			// A bare block's task's `thread_local` storage is its own thread's,
			// not the caller's.
			if !part.elsewhere || !global_is_thread_local(c, global) {
				global_list_add(&out, global)
			}
		}
	}
	return out.list[:]
}

// Globals in the order found, each once, however many a call takes in.
@(private = "file")
Global_List :: struct {
	list: [dynamic]Symbol_Id,
	seen: map[Symbol_Id]bool,
}

@(private = "file")
global_list_make :: proc() -> Global_List {
	return {make([dynamic]Symbol_Id, 0, 4, context.temp_allocator), make(map[Symbol_Id]bool, context.temp_allocator)}
}

@(private = "file")
global_list_add :: proc(globals: ^Global_List, global: Symbol_Id) {
	if !globals.seen[global] {
		globals.seen[global] = true
		append(&globals.list, global)
	}
}

// An indirect target's key: a `dyn` slot, or a procedure type.
Effect_Key :: struct {
	dyn_interface: Symbol_Id,
	dyn_index:     int,
	type:          Type_Id,
}

@(private = "file")
effect_key :: proc(target: Effect_Call) -> Effect_Key {
	return Effect_Key{target.dyn_interface, target.dyn_index, target.type}
}

// Gathers every clean body's effects, then settles them; `call_parts` says what a
// call takes in.
compute_global_writes :: proc(k: ^Checker) {
	c := k.c
	c.indirect_writes = make(map[Effect_Key][]Symbol_Id, c.semantic_allocator)
	c.indirect_reads = make(map[Effect_Key][]Symbol_Id, c.semantic_allocator)
	c.callback_summaries = make(map[Symbol_Id]^Callback_Summary, c.semantic_allocator)
	c.thread_spawns = make([dynamic]Thread_Spawn, c.semantic_allocator)
	bodies := collect_body_effects(k)
	// Kept for the thread summaries, which settle over the same calls.
	program := &c.effect_program
	program.bodies = make([]Effect_Body, len(bodies), c.semantic_allocator)
	program.index_of = make(map[Symbol_Id]int, len(bodies), c.semantic_allocator)
	for body, index in bodies {
		program.bodies[index] = Effect_Body{symbol = body.symbol, type = body.type}
		program.index_of[body.symbol] = index
	}
	c.effect_unions = make(map[Effect_Key][]int, 16, c.semantic_allocator)
	for called, index in settle_called_parameters(c, bodies) {
		if len(called) > 0 {
			summary := new(Callback_Summary, c.semantic_allocator)
			summary.called = slice.clone(called[:], c.semantic_allocator)
			c.callback_summaries[bodies[index].symbol] = summary
		}
	}
	settle_body_effects(c, bodies)
	program.whole = make([]Body_Summary, len(bodies), c.semantic_allocator)
	program.own = make([]Body_Summary, len(bodies), c.semantic_allocator)
	for body, index in bodies {
		whole := &program.whole[index]
		whole.writes = slice.clone(body.writes.list[:], c.semantic_allocator)
		whole.reads = slice.clone(body.reads.list[:], c.semantic_allocator)
		program.own[index] = whole^
		if c.callback_summaries[body.symbol] != nil {
			program.own[index].writes = slice.clone(body.own.list[:], c.semantic_allocator)
			program.own[index].reads = slice.clone(body.own_reads.list[:], c.semantic_allocator)
		}
	}
	c.global_writes_ready = true
	warn_thread_races(c, bodies)
	reject_copy_hook_writes(c)
}

// Builds each clean body's graph and keeps what it writes, reads, and calls.
@(private = "file")
collect_body_effects :: proc(k: ^Checker) -> []Body_Effects {
	c := k.c
	used_as_value := make(map[Symbol_Id]bool, 16, c.semantic_allocator)
	bodies := make([dynamic]Body_Effects, 0, len(c.checked_bodies), context.temp_allocator)
	for body in c.checked_bodies {
		if !body.clean {
			continue
		}
		graph := build_flow_graph(k, body.literal, .Prov_Summary)
		effects := Body_Effects {
			symbol     = body.literal.symbol,
			type       = symbol_of(c, body.literal.symbol).proc_type,
			own        = {list = slice.clone_to_dynamic(graph.effect_writes[:], context.temp_allocator)},
			writes     = {list = make([dynamic]Symbol_Id, context.temp_allocator)},
			own_reads  = {list = slice.clone_to_dynamic(graph.effect_reads[:], context.temp_allocator)},
			reads      = {list = make([dynamic]Symbol_Id, context.temp_allocator)},
			copy_hooks = slice.clone(graph.effect_copy_hooks[:], context.temp_allocator),
			calls      = slice.clone(graph.effect_calls[:], context.temp_allocator),
		}
		// The graph's storage is reset below; what each call's values may be is
		// kept by site. A task's call on its worker is resolved at its `spawn`.
		for &call in effects.calls {
			site := Call_Site{body = body.literal.symbol, span = call.span}
			if call.variable != INVALID_SYMBOL && call.values_from == INVALID_SYMBOL {
				c.called_values[site] = slice.clone(effect_variable_values(c, graph.effect_stores[:], call.variable), c.semantic_allocator)
			}
			if len(call.args) > 0 {
				c.argument_values[site] = slice.clone(effect_resolved_args(c, graph.effect_stores[:], call.args), c.semantic_allocator)
			}
			call.args = nil
		}
		for id in graph.effect_values {
			used_as_value[id] = true
		}
		append(&c.thread_spawns, ..graph.thread_spawns[:])
		append(&bodies, effects)
		free_all(c.analysis_allocator)
	}
	c.effect_program.used_as_value = used_as_value
	return bodies[:]
}

// A body writes what it writes itself and what anything it may call writes, and
// reads likewise.
@(private = "file")
settle_body_effects :: proc(c: ^Compiler, bodies: []Body_Effects) {
	program := &c.effect_program
	parts := make([][]Call_Part, len(bodies), context.temp_allocator)
	for body, index in bodies {
		list := make([dynamic]Call_Part, 0, len(body.calls), context.temp_allocator)
		for call in body.calls {
			append(&list, ..call_parts(c, body.symbol, call, open = false))
		}
		for hook in body.copy_hooks {
			if target, found := program.index_of[hook]; found {
				append(&list, Call_Part{body = target, whole = true, via = -1, callback = -1})
			}
		}
		parts[index] = list[:]
	}
	numbers := number_body_globals(c, bodies)
	settle := part_fixpoint_make(c, parts)
	for index in worklist_pop(&settle.queue) {
		body := &bodies[index]
		grew := false
		for part in parts[index] {
			reached := &bodies[part.body]
			grew |= add_part_to_set(c, numbers, &body.own, reached.writes if part.whole else reached.own, part)
			grew |= add_part_to_set(c, numbers, &body.own_reads, reached.reads if part.whole else reached.own_reads, part)
		}
		grew |= add_part_to_set(c, numbers, &body.writes, body.own, {})
		grew |= add_part_to_set(c, numbers, &body.reads, body.own_reads, {})
		for part in settle.closing[index] {
			grew |= add_part_to_set(c, numbers, &body.writes, bodies[part.body].writes, part)
			grew |= add_part_to_set(c, numbers, &body.reads, bodies[part.body].reads, part)
		}
		if grew {
			part_fixpoint_grew(&settle, index)
		}
	}
}

// Numbers, by symbol, every global a body names itself, the only ones its sets can
// come to hold, and gives each set its row.
@(private = "file")
number_body_globals :: proc(c: ^Compiler, bodies: []Body_Effects) -> []int {
	numbers := make([]int, len(c.symbols), context.temp_allocator)
	count := 0
	for body in bodies {
		for list in ([2][dynamic]Symbol_Id{body.own.list, body.own_reads.list}) {
			for global in list {
				if numbers[global] == 0 {
					count += 1
					numbers[global] = count
				}
			}
		}
	}
	for &body in bodies {
		for set in ([4]^Global_Set{&body.own, &body.writes, &body.own_reads, &body.reads}) {
			set.row = make([]u8, count / 8 + 1, context.temp_allocator)
			for global in set.list {
				bit_mark(set.row, numbers[global])
			}
		}
	}
	return numbers
}

@(private = "file")
add_part_to_set :: proc(c: ^Compiler, numbers: []int, into: ^Global_Set, from: Global_Set, part: Call_Part) -> bool {
	grew := false
	for global in from.list {
		if !bit_get(into.row, numbers[global]) && (!part.elsewhere || !global_is_thread_local(c, global)) {
			bit_mark(into.row, numbers[global])
			append(&into.list, global)
			grew = true
		}
	}
	return grew
}

// design.md "Lifecycle hooks and resource types": how many copies run is
// unspecified, so a copy hook writes no global. Reported once per declaration,
// not per generic instance.
@(private = "file")
reject_copy_hook_writes :: proc(c: ^Compiler) {
	reported := make(map[Span]bool, context.temp_allocator)
	for body in c.checked_bodies {
		sym := symbol_of(c, body.literal.symbol)
		writes := body_summary(c, body.literal.symbol).writes
		if sym == nil || sym.hook != .Copy || len(writes) == 0 || reported[sym.span] {
			continue
		}
		reported[sym.span] = true
		global := symbol_of(c, writes[0])
		errorf(
			c, sym.span, "L0711",
			"`%s` is a copy hook and may not write `%s`: how many copies run is unspecified",
			identifier_text(c, sym.name), identifier_text(c, global.name),
		)
		add_notef(c, global.span, "declared here; a count kept by copies can be a `sync.Atomic`, whose updates are not writes")
	}
}

// A union is kept once settled, but a `dyn` slot's walk from inside another's
// leaves out what that one has reached.
@(private = "file")
effect_targets :: proc(c: ^Compiler, call: Effect_Call, seen: ^map[Effect_Key]bool = nil) -> []int {
	bodies, index_of, used_as_value := c.effect_program.bodies, c.effect_program.index_of, c.effect_program.used_as_value
	key := effect_key(call)
	// A view of itself would otherwise recurse.
	if seen != nil && key in seen^ {
		return nil
	}
	if cached, found := c.effect_unions[key]; found {
		return cached
	}
	visited := seen
	if visited == nil {
		first := make(map[Effect_Key]bool, context.temp_allocator)
		visited = &first
	}
	visited^[key] = true
	out := make([dynamic]int, 0, 4, context.temp_allocator)
	if call.dyn_interface == INVALID_SYMBOL {
		// A distinct procedure type holds what the type it wraps holds.
		held := type_underlying(c, call.type)
		for body, index in bodies {
			if used_as_value[body.symbol] && assignable(c, body.type, held) {
				append(&out, index)
			}
		}
	} else {
		same_interface := c.interface_witnesses[call.dyn_interface]
		for witness in same_interface {
			if call.dyn_index >= len(witness.slots) {
				continue
			}
			// A callable view's witnesses are per signature.
			if call.type != INVALID_TYPE && (len(witness.args) == 0 || witness.args[0].type != call.type) {
				continue
			}
			target := witness.slots[call.dyn_index].target
			if index, found := index_of[target]; found {
				append(&out, index)
			}
			// A view of a view runs what the inner view may run.
			if sym := symbol_of(c, target); sym != nil {
				if inner, is_forward := forwarding_effect(c, sym); is_forward {
					append(&out, ..effect_targets(c, inner, visited))
				}
			}
		}
		// design.md "Borrowed callable views": or a procedure the view holds.
		if call.type != INVALID_TYPE {
			append(&out, ..effect_targets(c, Effect_Call{type = call.type}, visited))
		}
		// standard-library.md "Printed forms": the witnesses nested and generic
		// printing reach are built after this pass, so the slot may reach any
		// `format` method it can meet, which a public type's private one is not.
		if interface_is_printing(c, call.dyn_interface) {
			for body, index in bodies {
				if sym := symbol_of(c, body.symbol); sym != nil && sym.has_receiver && identifier_text(c, sym.name) == "format" && format_meets_slot(c, sym, sym.owner_type) {
					append(&out, index)
				}
			}
		}
	}
	if c.effect_unions != nil && (seen == nil || call.dyn_interface == INVALID_SYMBOL) {
		kept := slice.clone(out[:], c.semantic_allocator)
		c.effect_unions[key] = kept
		return kept
	}
	return out[:]
}

// Whether a call's effects come from bodies the effects settle over: a direct
// callee with a body, or any call through a value or a `dyn` slot.
call_follows_bodies :: proc(c: ^Compiler, v: ^Expr_Call) -> bool {
	target, ok := call_effect(c, v)
	if !ok {
		return false
	}
	return target.callee == INVALID_SYMBOL || target.callee in c.effect_program.index_of
}

// The bodies a call through a value or a `dyn` slot may run, as the write
// effects found them, and whether the call is one; none before they settle.
// A procedure type's inferred contract bounds only what its result borrows, so
// any body of its plain signature may be the one called.
indirect_call_targets :: proc(c: ^Compiler, v: ^Expr_Call) -> ([]Symbol_Id, bool) {
	target, ok := call_effect(c, v)
	if !ok {
		return nil, false
	}
	// A view converted at the call runs what its concrete value supplies.
	if converted := target.callee if target.callee != INVALID_SYMBOL else target.held; converted != INVALID_SYMBOL {
		if !prov_dispatches_on_view(c, v) {
			return nil, false
		}
		return slice.clone([]Symbol_Id{converted}, context.temp_allocator), true
	}
	if target.dyn_interface == INVALID_SYMBOL {
		target.type = erase_proc_contract(c, type_underlying(c, target.type))
	}
	return effect_target_symbols(c, target), true
}

// design.md "Allocator regions and region provenance": the procedures a call
// through a procedure value may run, when their summaries say every region its
// result may be in: each procedure of its type the program uses as a value has
// a body the effects settled over, or is a compiler-contributed member, whose
// summary is written directly (`set_synth_result_summary`). False for any other
// call, before the effects settle, when such a procedure has no summary, as a
// foreign one, and when no procedure is such a value, as one foreign code hands
// over.
procedure_value_targets :: proc(c: ^Compiler, v: ^Expr_Call) -> ([]Symbol_Id, bool) {
	if !c.global_writes_ready {
		return nil, false
	}
	target, ok := call_effect(c, v)
	if !ok || target.callee != INVALID_SYMBOL || target.held != INVALID_SYMBOL || target.dyn_interface != INVALID_SYMBOL ||
	   underlying_kind(c, target.type) != .Proc {
		return nil, false
	}
	target.type = erase_proc_contract(c, type_underlying(c, target.type))
	program := &c.effect_program
	targets := make([dynamic]Symbol_Id, 0, 4, context.temp_allocator)
	append(&targets, ..effect_target_symbols(c, target))
	for symbol in program.used_as_value {
		if symbol in program.index_of {
			continue
		}
		sym := symbol_of(c, symbol)
		if sym == nil {
			return nil, false
		}
		if !assignable(c, sym.proc_type, target.type) {
			continue
		}
		if _, summarized := result_summary(c, symbol); !summarized {
			return nil, false
		}
		append(&targets, symbol)
	}
	return targets[:], len(targets) > 0
}

// What brings `global` into a call's writes, or its reach, besides its
// callee's own part: a procedure value, a callback, or a union member, and for
// a callback, the callee that calls it and the parameter it was passed for.
Effect_Origin :: struct {
	target:    Symbol_Id,
	callee:    Symbol_Id,
	parameter: int,
}

// Each origin of `global` at `call` in `body`, as the summaries resolve it
// there, for a diagnostic to name. A direct callee's own part is the call's
// subject, except the concrete target of a view converted at the call.
call_effect_origins :: proc(c: ^Compiler, body: Symbol_Id, call: ^Expr_Call, global: Symbol_Id, writes: bool) -> []Effect_Origin {
	target, ok := call_effect(c, call)
	if !ok {
		return nil
	}
	target.span = call.span
	bodies := c.effect_program.bodies
	converted := prov_dispatches_on_view(c, call)
	out := make([dynamic]Effect_Origin, 0, 2, context.temp_allocator)
	for part in call_parts(c, body, target, open = true) {
		if !part.whole && !converted {
			continue
		}
		found := false
		if writes {
			found = slice.contains(part_summary(c, part).writes, global)
		} else {
			for reached in part_summary(c, part).reach {
				found ||= reached.global == global
			}
		}
		if !found {
			continue
		}
		origin := Effect_Origin{target = bodies[part.body].symbol, parameter = -1}
		if part.callback >= 0 {
			origin.callee = bodies[part.via].symbol
			origin.parameter = c.callback_summaries[origin.callee].called[part.callback].parameter
		}
		if !slice.contains(out[:], origin) {
			append(&out, origin)
		}
	}
	return out[:]
}

// The bodies a value of a procedure type or a `dyn proc` view may run.
callable_type_targets :: proc(c: ^Compiler, type: Type_Id) -> []Symbol_Id {
	signature, view, callable := callable_signature(c, type)
	if !callable {
		return nil
	}
	if view == INVALID_SYMBOL {
		signature = erase_proc_contract(c, signature)
	}
	return effect_target_symbols(c, Effect_Call{dyn_interface = view, type = signature})
}

@(private = "file")
effect_target_symbols :: proc(c: ^Compiler, call: Effect_Call) -> []Symbol_Id {
	reached := effect_targets(c, call)
	out := make([]Symbol_Id, len(reached), context.temp_allocator)
	for index, position in reached {
		out[position] = c.effect_program.bodies[index].symbol
	}
	return out
}

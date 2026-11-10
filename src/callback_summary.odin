// What a call may leave in its arguments or return of `thread_local` storage,
// with each callback its callee calls substituted by the one the call passes. It
// reads the summaries through `Compiler`, and pairs with `indirect_call_targets`
// and `callable_type_targets` in `global_effects.odin`.
package lokec

// design.md "Borrows crossing between tasks": a body that calls a callback it
// received may leave in its parameter `into` what that callback leaves in its
// own argument `argument`, counted among the callback's parameters. Each call
// of the body substitutes the callback it passes (`call_thread_local_left`).
Callback_Write :: struct {
	callback, argument, into: int,
}

// A callback's own result, as the argument a `Callback_Write` or
// `Callback_Read` names: what a call through it returns.
CALLBACK_RESULT :: -1

// design.md "Borrows crossing between tasks": a body's result may hold what a
// callback it received, in parameter `callback`, leaves in its own argument
// `argument`. Each call of the body substitutes the callback it passes
// (`call_callback_reads`).
Callback_Read :: struct {
	callback, argument: int,
}

// Adds `value` to `table`'s set for `declaration`; returns whether it grew.
@(private)
add_unique :: proc(c: ^Compiler, table: ^map[Symbol_Id][]$T, declaration: Symbol_Id, value: T) -> bool {
	known := table[declaration]
	if !set_add(&known, value, c.semantic_allocator) {
		return false
	}
	table[declaration] = known
	return true
}

// What a call may leave in its argument `at`, by its position in the call's
// bound arguments: a borrow of `global`, or while a body is summarized, what
// the callback that body received in parameter `callback` leaves in its own
// argument `argument`.
Thread_Local_Left :: struct {
	at:       int,
	global:   Symbol_Id,
	callback: Symbol_Id,
	argument: int,
}

// What a call may leave in its arguments. A direct call substitutes the
// procedure it passes for each callback its callee calls. A summary with one
// parameter fewer than the call has arguments is a procedure a callable view
// holds, after the view itself; one with one more is a callable record's `call`,
// whose record the view hides. With `forward`, a callback the calling `body`
// received itself stays its own caller's to name. `consulted` gathers each
// summary read.
call_thread_local_left :: proc(
	c: ^Compiler, call: ^Expr_Call, body: Symbol_Id, forward: bool, consulted: ^[dynamic]Symbol_Id,
) -> []Thread_Local_Left {
	if !call_writes_caller(c, call) {
		return nil
	}
	count := len(call.bound)
	out := make([dynamic]Thread_Local_Left, 0, 2, context.temp_allocator)
	seen := make(map[[2]int]bool, context.temp_allocator)
	targets, stand_ins := call_summary_targets(c, call, body, forward)
	info := underlying_info(c, call_proc_type(c, call))
	for callback in stand_ins {
		type := symbol_of(c, callback).type
		for argument, index in call.bound {
			if argument == nil || index >= len(info.parameters) || !parameter_may_hold_written_borrow(c, info, index) {
				continue
			}
			position := index - (count - callable_arity(c, type))
			// Only a type some procedure of which may leave one needs a stand-in.
			clear(&seen)
			if type_left_at(c, type, position, consulted, &seen) != INVALID_SYMBOL {
				append(&out, Thread_Local_Left{at = index, global = INVALID_SYMBOL, callback = callback, argument = position})
			}
		}
	}
	site := Call_Site{body = body, span = call.span}
	for target in targets {
		append(consulted, target)
		sym := symbol_of(c, target)
		if sym == nil {
			continue
		}
		shift := count - len(sym.param_symbols)
		for global, index in c.thread_local_writes[target] {
			if global != INVALID_SYMBOL && index + shift >= 0 && index + shift < count {
				append(&out, Thread_Local_Left{at = index + shift, global = global, callback = INVALID_SYMBOL})
			}
		}
		for write in c.callback_thread_local_writes[target] {
			at, passed := write.into + shift, write.callback + shift
			if at < 0 || at >= count {
				continue
			}
			type := symbol_of(c, sym.param_symbols[write.callback]).type
			for value in passed_values(c, site, call, passed) {
				if left, found := value_left(c, value, type, write.argument, body, forward, consulted, &seen); found {
					left.at = at
					append(&out, left)
				}
			}
		}
	}
	return out[:]
}

// The bodies a call may run, whose summaries say what it does: what a procedure
// value it goes through may be (`callee_values`), or else its callee
// (`call_thread_local_targets`). A value the effects did not resolve may run any
// body they found for the call (`indirect_call_targets`), whatever contract its
// type carries, since a contract bounds only what the result borrows. With
// `forward`, a callback the calling `body` received is a stand-in instead.
@(private)
call_summary_targets :: proc(c: ^Compiler, call: ^Expr_Call, body: Symbol_Id, forward: bool) -> (targets, stand_ins: [dynamic]Symbol_Id) {
	targets = make([dynamic]Symbol_Id, 0, 4, context.temp_allocator)
	stand_ins = make([dynamic]Symbol_Id, 0, 2, context.temp_allocator)
	values, through := callee_values(c, call, body)
	if !through {
		append(&targets, ..call_thread_local_targets(c, call))
		return
	}
	unresolved := false
	for value in values {
		#partial switch value.kind {
		case .Procedure:
			append(&targets, value.symbol)
		case .Nil:
		case .Parameter:
			if callback := body_parameter(c, body, value.parameter); forward && callback != INVALID_SYMBOL {
				append(&stand_ins, callback)
			} else {
				unresolved = true
			}
		case:
			unresolved = true
		}
	}
	if unresolved {
		indirect, _ := indirect_call_targets(c, call)
		append(&targets, ..indirect)
	}
	return
}

// The declarations a call's summary is read from: its callee, or every body a
// call through a value or a `dyn` slot may run.
@(private = "file")
call_thread_local_targets :: proc(c: ^Compiler, call: ^Expr_Call) -> []Symbol_Id {
	if targets, indirect := indirect_call_targets(c, call); indirect {
		return targets
	}
	declaration := call_contract_declaration(c, call)
	if declaration == INVALID_SYMBOL {
		return nil
	}
	single := make([]Symbol_Id, 1, context.temp_allocator)
	single[0] = declaration
	return single
}

// What the value a call goes through may be: what the write effects resolved
// for a procedure variable, or a callable view the calling body received.
@(private = "file")
callee_values :: proc(c: ^Compiler, call: ^Expr_Call, body: Symbol_Id) -> ([]Effect_Arg, bool) {
	if values, found := c.called_values[Call_Site{body = body, span = call.span}]; found {
		return values, true
	}
	if callback := called_parameter(c, call); callback != INVALID_SYMBOL {
		single := make([]Effect_Arg, 1, context.temp_allocator)
		single[0] = Effect_Arg{kind = .Parameter, parameter = int(symbol_of(c, callback).index)}
		return single, true
	}
	return nil, false
}

// What the argument a call passes at `passed` may be: what the write effects
// resolved for it, or else what the expression names.
@(private = "file")
passed_values :: proc(c: ^Compiler, site: Call_Site, call: ^Expr_Call, passed: int) -> []Effect_Arg {
	out := make([dynamic]Effect_Arg, 0, 2, context.temp_allocator)
	for value in c.argument_values[site] {
		if value.binding == passed {
			append(&out, value)
		}
	}
	if len(out) > 0 {
		return out[:]
	}
	value: Expr = passed >= 0 && passed < len(call.bound) ? call.bound[passed] : nil
	if moved, is_move := value.(^Expr_Move); is_move {
		value = moved.value
	}
	id := named_value_symbol(value)
	named := Effect_Arg{}
	if sym := symbol_of(c, id); sym != nil && sym.kind == .Proc {
		named = Effect_Arg{kind = .Procedure, symbol = id}
	} else if sym != nil && sym.kind == .Parameter {
		named = Effect_Arg{kind = .Parameter, parameter = int(sym.index)}
	}
	append(&out, named)
	return out[:]
}

// The parameter of `body` at `index`, if it holds a callable.
@(private = "file")
body_parameter :: proc(c: ^Compiler, body: Symbol_Id, index: int) -> Symbol_Id {
	sym := symbol_of(c, body)
	if sym == nil || index < 0 || index >= len(sym.param_symbols) {
		return INVALID_SYMBOL
	}
	parameter := symbol_of(c, sym.param_symbols[index])
	if parameter == nil || callable_arity(c, parameter.type) < 0 {
		return INVALID_SYMBOL
	}
	return sym.param_symbols[index]
}

// What a call's result may hold from the callbacks its callee calls
// (`Callback_Read`): the callback each passes resolved as for a write-back
// (`value_left`), `at` unused. A callable view's contract reads its
// original's, past the view.
call_callback_reads :: proc(
	c: ^Compiler, call: ^Expr_Call, declaration, body: Symbol_Id, forward: bool, consulted: ^[dynamic]Symbol_Id,
) -> []Thread_Local_Left {
	if declaration == INVALID_SYMBOL {
		return nil
	}
	contract := declaration
	if original, shifted := c.receiver_contract_of[declaration]; shifted {
		contract = original
	}
	out := make([dynamic]Thread_Local_Left, 0, 2, context.temp_allocator)
	seen := make(map[[2]int]bool, context.temp_allocator)
	site := Call_Site{body = body, span = call.span}
	for member in contract_members(c, contract) {
		append(consulted, member)
		sym := symbol_of(c, member)
		if sym == nil {
			continue
		}
		shift := len(call.bound) - len(sym.param_symbols)
		for read in c.callback_result_reads[member] {
			type := symbol_of(c, sym.param_symbols[read.callback]).type
			for value in passed_values(c, site, call, read.callback + shift) {
				if left, found := value_left(c, value, type, read.argument, body, forward, consulted, &seen); found {
					append(&out, left)
				}
			}
		}
	}
	return out[:]
}

// The parameter of the calling body a call goes through: `f(out)`, or
// `f.call(out)` on a callable view.
@(private = "file")
called_parameter :: proc(c: ^Compiler, call: ^Expr_Call) -> Symbol_Id {
	ident, is_ident := callable_view_operand(c, call.callee).(^Expr_Ident)
	if !is_ident {
		return INVALID_SYMBOL
	}
	sym := symbol_of(c, ident.symbol)
	if sym == nil || sym.kind != .Parameter || callable_arity(c, sym.type) < 0 {
		return INVALID_SYMBOL
	}
	return ident.symbol
}

// The view `f` of a callee `f.call`, and any other callee as it is.
@(private = "file")
callable_view_operand :: proc(c: ^Compiler, callee: Expr) -> Expr {
	if selector, is_selector := callee.(^Expr_Selector); is_selector && selector.operand != nil {
		if base := expr_base(selector.operand); base != nil && dyn_proc_signature(c, base.type) != INVALID_TYPE {
			return selector.operand
		}
	}
	return callee
}

// How many parameters a procedure type or a `dyn proc` view's signature has,
// or -1 for any other type.
@(private = "file")
callable_arity :: proc(c: ^Compiler, type: Type_Id) -> int {
	signature, _, callable := callable_signature(c, type)
	info := underlying_info(c, signature)
	if !callable || info == nil || info.kind != .Proc {
		return -1
	}
	return len(info.parameters)
}

// What a callback that may be `value`, of `type`, leaves in its argument
// `argument`, if anything: a named procedure's own summary; with `forward`, a
// callback the calling `body` received as a stand-in, where any procedure of the
// type may leave one at all; otherwise what any procedure of the type may leave.
// `seen` is this query's own, as what an earlier one visited it may yet leave
// here (`procedure_left_at`).
@(private = "file")
value_left :: proc(
	c: ^Compiler, value: Effect_Arg, type: Type_Id, argument: int, body: Symbol_Id, forward: bool,
	consulted: ^[dynamic]Symbol_Id, seen: ^map[[2]int]bool,
) -> (left: Thread_Local_Left, found: bool) {
	clear(seen)
	left.global, left.callback = INVALID_SYMBOL, INVALID_SYMBOL
	arity := callable_arity(c, type)
	#partial switch value.kind {
	case .Nil:
		return left, false
	case .Procedure:
		if prov_has_direct_body(c, value.symbol) {
			left.global = procedure_left_at(c, value.symbol, arity, argument, consulted, seen)
			return left, left.global != INVALID_SYMBOL
		}
	case .Parameter:
		callback := body_parameter(c, body, value.parameter)
		if forward && callback != INVALID_SYMBOL && callable_arity(c, symbol_of(c, callback).type) == arity {
			if type_left_at(c, type, argument, consulted, seen) == INVALID_SYMBOL {
				return left, false
			}
			left.callback, left.argument = callback, argument
			return left, true
		}
	}
	left.global = type_left_at(c, type, argument, consulted, seen)
	return left, left.global != INVALID_SYMBOL
}

// A `thread_local` global that procedure `id`, standing for a callback whose
// signature has `arity` parameters, may leave in that signature's argument
// `argument`. A callback it calls in turn may be any procedure of its type.
@(private = "file")
procedure_left_at :: proc(
	c: ^Compiler, id: Symbol_Id, arity, argument: int, consulted: ^[dynamic]Symbol_Id, seen: ^map[[2]int]bool,
) -> Symbol_Id {
	sym := symbol_of(c, id)
	if sym == nil || arity < 0 {
		return INVALID_SYMBOL
	}
	index := argument
	if argument != CALLBACK_RESULT {
		index += len(sym.param_symbols) - arity
	}
	// A cycle of callbacks adds nothing its first visit does not.
	key := [2]int{int(id), index}
	if seen[key] {
		return INVALID_SYMBOL
	}
	seen[key] = true
	append(consulted, id)
	if index == CALLBACK_RESULT {
		return returned_thread_local(c, id, consulted, seen)
	}
	if written := c.thread_local_writes[id]; index >= 0 && index < len(written) && written[index] != INVALID_SYMBOL {
		return written[index]
	}
	for write in c.callback_thread_local_writes[id] {
		if write.into != index {
			continue
		}
		type := symbol_of(c, sym.param_symbols[write.callback]).type
		if global := type_left_at(c, type, write.argument, consulted, seen); global != INVALID_SYMBOL {
			return global
		}
	}
	return INVALID_SYMBOL
}

// A `thread_local` global procedure `id` may return a borrow of: one its result
// summary names, or what a callback it calls may leave for its result.
@(private = "file")
returned_thread_local :: proc(c: ^Compiler, id: Symbol_Id, consulted: ^[dynamic]Symbol_Id, seen: ^map[[2]int]bool) -> Symbol_Id {
	if summary, found := result_summary(c, id); found {
		for global in summary.globals {
			if global_sym := symbol_of(c, global); global_sym != nil && global_sym.duration == .Thread_Local {
				return global
			}
		}
	}
	sym := symbol_of(c, id)
	for read in c.callback_result_reads[id] {
		type := symbol_of(c, sym.param_symbols[read.callback]).type
		if global := type_left_at(c, type, read.argument, consulted, seen); global != INVALID_SYMBOL {
			return global
		}
	}
	return INVALID_SYMBOL
}

// What a call through a value or a `dyn` slot may return of a callback's
// `thread_local` storage, which a call with no summary does not show: for each
// value it may go through (`callee_values`), as `value_left` resolves it, or
// with none resolved, what any body the global-write effects found for the
// call may return (`indirect_call_targets`), as for a write-back. `at` is
// unused.
call_callback_returns :: proc(
	c: ^Compiler, call: ^Expr_Call, body: Symbol_Id, forward: bool, consulted: ^[dynamic]Symbol_Id,
) -> []Thread_Local_Left {
	type := INVALID_TYPE
	if base := expr_base(callable_view_operand(c, call.callee)); base != nil {
		type = base.type
	}
	if callable_arity(c, type) < 0 {
		return nil
	}
	out := make([dynamic]Thread_Local_Left, 0, 2, context.temp_allocator)
	seen := make(map[[2]int]bool, context.temp_allocator)
	values, through := callee_values(c, call, body)
	if !through {
		targets, _ := indirect_call_targets(c, call)
		for target in targets {
			clear(&seen)
			if global := procedure_left_at(c, target, callable_arity(c, type), CALLBACK_RESULT, consulted, &seen); global != INVALID_SYMBOL {
				append(&out, Thread_Local_Left{global = global, callback = INVALID_SYMBOL})
			}
		}
		return out[:]
	}
	for value in values {
		if left, found := value_left(c, value, type, CALLBACK_RESULT, body, forward, consulted, &seen); found {
			append(&out, left)
		}
	}
	return out[:]
}

// What any procedure a value of the callable `type` may hold leaves in its
// argument `argument`.
@(private = "file")
type_left_at :: proc(
	c: ^Compiler, type: Type_Id, argument: int, consulted: ^[dynamic]Symbol_Id, seen: ^map[[2]int]bool,
) -> Symbol_Id {
	arity := callable_arity(c, type)
	for target in callable_type_targets(c, type) {
		if global := procedure_left_at(c, target, arity, argument, consulted, seen); global != INVALID_SYMBOL {
			return global
		}
	}
	return INVALID_SYMBOL
}

@(private)
call_writes_caller :: proc(c: ^Compiler, call: ^Expr_Call) -> bool {
	info := underlying_info(c, call_proc_type(c, call))
	if info == nil {
		return false
	}
	for _, index in info.parameters {
		if parameter_may_hold_written_borrow(c, info, index) {
			return true
		}
	}
	return false
}

// Counts only a mutable carrier that can hold a borrow, where `param_writes_caller`
// counts any, as an owner can be left through it. design.md "Borrows crossing between
// tasks": a read-only carrier that reaches a mutable one counts too, such as
// `outs: []^mut ^int` or a variadic `..^mut ^int`.
@(private = "file")
parameter_may_hold_written_borrow :: proc(c: ^Compiler, info: ^Type_Info, index: int) -> bool {
	type := info.parameters[index]
	return param_mode_at(info, index) == .Inout || carrier_is_mutable(c, type) ||
		prov_type_reaches_destination(c, type)
}

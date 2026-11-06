// Shared overload resolution for calls, methods, operators, construction, and indexing.
package lokec

import "core:slice"
import "core:fmt"

// Conversion ranks (design.md "Operator lookup and overload resolution").
RANK_EXACT :: 0 // exact type and parameter-mode match
RANK_ADJUST :: 1 // a capability adjustment that does not create a value
RANK_CONST_KIND :: 2 // an untyped constant converted without changing its kind
RANK_BUILTIN :: 3 // any other built-in implicit conversion
RANK_NONE :: 4 // no conversion at all: the candidate is not viable

// One supplied argument, checked before candidates rank it.
Arg_Info :: struct {
	expr:        Expr,
	span:        Span,
	name:        Identifier_Id, // INVALID_IDENTIFIER for a positional argument
	mode:        Argument_Mode,
	type:        Type_Id,
	const_value: Const_Value,
	is_receiver: bool,
	// design.md "Arguments typed after inference": unchecked until
	// `bind_chosen_call` types it against the chosen parameter.
	waiting:     bool,
}

// Why a candidate is not viable. The common reasons are worded only if the call
// fails (`rejection_text`), since most rejected members are never reported.
Rejection :: union {
	string,
	Rejected_Arity,
	Rejected_Argument,
}

Rejected_Arity :: struct {
	count, supplied: int,
}

// An argument, by its index in the candidate's `args`, that ranked `RANK_NONE`.
Rejected_Argument :: struct {
	index: int,
	want:  Type_Id,
	mode:  Param_Mode,
}

Candidate :: struct {
	symbol: Symbol_Id,
	// One rank per written argument, compile-time `$` arguments included.
	ranks:  []int,
	slots:  []int,
	filled: []bool,
	// Generic candidates keep only their runtime arguments here.
	args:   []Arg_Info,

	omitted:    int,
	variadic:   bool,
	parametric: bool,
	// Tie-breaker 1: owned arguments (temporaries and `move(...)`) the candidate
	// consumes.
	consumed:   int,
	instance:   ^Instance,
	// The originating generic, also used to report a rejected bound.
	template:   ^Generic_Template,
	bindings:   []Generic_Binding,
	scope:      ^Scope,
	viable:     bool,
	reason:     Rejection,
	// Inference left a waiting argument's parameter type with an unbound `$`
	// name; `waiting_arg` is that argument's index.
	unbound_wait: bool,
	waiting_arg:  int,
}

// ------------------------------------------------------------------ arguments --

// Checks each argument once while leaving scalar constants untyped for ranking.
collect_call_arguments :: proc(
	k: ^Checker,
	args: []Argument,
	candidates: []Symbol_Id = nil,
	offset := 0,
	live_group: Symbol_Id = INVALID_SYMBOL,
) -> ([]Arg_Info, bool) {
	out := make([]Arg_Info, len(args), k.c.semantic_allocator)
	ok := true
	for arg, index in args {
		info := Arg_Info {
			expr = arg.value,
			span = arg.span,
			mode = arg.mode,
		}
		if arg.name.text != "" {
			info.name = intern_identifier(k.c, arg.name.text)
		}
		if arg.checked {
			info.type = settle_single_value(k, arg.value, expr_base(arg.value).type, INVALID_TYPE)
		} else {
			expected := INVALID_TYPE
			if argument_needs_context(arg.value) {
				context_candidates := candidates
				if live_group != INVALID_SYMBOL {
					if group := symbol_of(k.c, live_group); group != nil && group.kind == .Proc_Group {
						context_candidates = group.members
					}
				}
				expected = common_argument_type(k, context_candidates, info.name, index + offset)
				// design.md "Arguments typed after inference": typed once a
				// candidate is chosen, against its parameter.
				if expected == INVALID_TYPE && arg.mode == .Value && argument_can_wait(arg.value) &&
				   argument_waits(k, context_candidates, info.name, index + offset) {
					info.waiting = true
					out[index] = info
					continue
				}
			}
			info.type = check_single_expr(k, arg.value, expected, arg.mode == .Inout ? .Place : .Value)
		}
		if info.type == INVALID_TYPE {
			ok = false
		} else if base := expr_base(arg.value); base != nil {
			info.const_value = base.const_value
		}
		out[index] = info
	}
	return out, ok
}

// Typeless aggregates and implicit selectors need a destination type, and a
// conditional passes its own to both operands.
argument_needs_context :: proc(e: Expr) -> bool {
	#partial switch v in e {
	case ^Expr_Cond:
		return argument_needs_context(v.then) || argument_needs_context(v.otherwise)
	case ^Expr_Composite:
		return v.type_expr == nil
	case ^Expr_Selector:
		return v.operand == nil
	case ^Expr_Call:
		sel, is_selector := v.callee.(^Expr_Selector)
		return is_selector && sel.operand == nil
	}
	return false
}

// A capture literal lowers to a composite but has its own type, so it is
// checked, and binds, like any typed argument; only the forms that have no
// type without a destination wait.
@(private = "file")
argument_can_wait :: proc(e: Expr) -> bool {
	#partial switch v in e {
	case ^Expr_Cond:
		return (argument_needs_context(v.then) && argument_can_wait(v.then)) ||
			(argument_needs_context(v.otherwise) && argument_can_wait(v.otherwise))
	case ^Expr_Composite:
		return v.capture == nil
	}
	return true
}

// Whether a generic candidate's parameter for this argument names the
// candidate's `$` parameters, so the argument waits for inference.
@(private = "file")
argument_waits :: proc(k: ^Checker, candidates: []Symbol_Id, name: Identifier_Id, position: int) -> bool {
	for candidate in candidates {
		sym := symbol_of(k.c, candidate)
		if sym == nil || !sym.generic {
			continue
		}
		template := generic_template_for(k, candidate)
		if template != nil && template.kind == .Procedure && generic_parameter_waits(k, template, name, position) {
			return true
		}
	}
	return false
}

@(private = "file")
common_argument_type :: proc(k: ^Checker, candidates: []Symbol_Id, name: Identifier_Id, position: int) -> Type_Id {
	common := INVALID_TYPE
	for candidate in candidates {
		sym := symbol_of(k.c, candidate)
		if sym == nil { return INVALID_TYPE }
		if sym.generic {
			template := generic_template_for(k, candidate)
			if template == nil || template.kind != .Procedure { return INVALID_TYPE }
			type, has_parameter := generic_parameter_context_type(k, template, name, position)
			if !has_parameter { continue }
			if type == INVALID_TYPE || (common != INVALID_TYPE && common != type) { return INVALID_TYPE }
			common = type
			continue
		}
		slot := name != INVALID_IDENTIFIER ? parameter_slot_named(k.c, sym, name) : position
		if slot < 0 { continue }
		// A written variadic element wants `T`, not the pack's `[]T`.
		pack := variadic_parameter_index(underlying_info(k.c, sym.proc_type))
		if pack >= 0 { slot = min(slot, pack) }
		if slot >= len(sym.params) { continue }
		type := slot == pack ? slice_element(k.c, sym.params[slot]) : sym.params[slot]
		if common != INVALID_TYPE && common != type { return INVALID_TYPE }
		common = type
	}
	return common
}

// Wraps an expression already checked by an operator or method path.
arg_from_expr :: proc(e: Expr, mode := Argument_Mode.Value) -> Arg_Info {
	base := expr_base(e)
	if base == nil {
		return Arg_Info{expr = e, type = INVALID_TYPE}
	}
	return Arg_Info {
		expr        = e,
		span        = base.span,
		mode        = mode,
		type        = base.type,
		const_value = base.const_value,
	}
}

// ------------------------------------------------------------------- ranking --

@(private = "file")
constant_conversion_preserves_kind :: proc(c: ^Compiler, from, to: Type_Id) -> bool {
	target := underlying_kind(c, to)
	#partial switch type_kind(c, from) {
	case .Untyped_Int:
		return target == .Int
	case .Untyped_Float:
		return target == .Float
	case .Untyped_Bool:
		return target == .Bool
	case .Untyped_Rune:
		return target == .Rune
	case .Untyped_String:
		return target == .String
	}
	return false
}

// Side-effect-free conversion rank; materialization happens after selection.
@(private = "file")
argument_rank :: proc(k: ^Checker, arg: Arg_Info, param: Type_Id, mode: Param_Mode) -> int {
	// design.md "Arguments typed after inference": a waiting argument takes no
	// part in choosing; whether it fits is checked against the chosen
	// candidate's parameter. It is never a place, so it cannot be `inout`.
	if arg.waiting {
		return param == INVALID_TYPE || mode == .Inout ? RANK_NONE : RANK_EXACT
	}
	if param == INVALID_TYPE || arg.type == INVALID_TYPE {
		return RANK_NONE
	}
	adjusted := false
	if arg.is_receiver {
		// A receiver's mode is implicit, so it costs `RANK_ADJUST` instead of
		// needing a match.
		if mode == .Move {
			if !expression_is_owned_argument(arg.expr) {
				return RANK_NONE
			}
		} else if _, moved := arg.expr.(^Expr_Move); moved {
			return RANK_NONE
		}
		// A consuming receiver takes an owned receiver as it is.
		adjusted = mode != .Value && mode != .Move
	} else if (mode == .Inout) != (arg.mode == .Inout) || (mode == .Move && !expression_is_owned_argument(arg.expr)) {
		return RANK_NONE
	}
	if arg.type == param {
		return adjusted ? RANK_ADJUST : RANK_EXACT
	}
	// design.md "Parameter semantics and ABI lowering": the callee writes the
	// caller's variable itself, so no conversion may stand between them.
	if mode == .Inout && !arg.is_receiver {
		return RANK_NONE
	}
	// design.md "Receiver forms": `Type.method(&value)` names the receiver
	// `self: ^T` receives.
	if mode == .Borrow && !arg.is_receiver && pointer_to_element(k.c, arg.type) == param {
		return RANK_ADJUST
	}
	if !assignable(k.c, arg.type, param) {
		return RANK_NONE
	}
	if type_is_untyped(k.c, arg.type) {
		if arg.const_value.kind != .Invalid {
			if _, fits := convert_const(k.c, arg.const_value, param, false); !fits {
				return RANK_NONE
			}
		}
		return constant_conversion_preserves_kind(k.c, arg.type, param) ? RANK_CONST_KIND : RANK_BUILTIN
	}
	return carrier_weakens_to(k.c, arg.type, param) ? RANK_ADJUST : RANK_BUILTIN
}

// design.md "Variadic parameters": a value a `..dyn I` pack views ranks as a
// built-in conversion, at the default type of an untyped constant.
@(private = "file")
variadic_view_rank :: proc(k: ^Checker, arg: Arg_Info, element: Type_Id) -> int {
	if arg.waiting || arg.mode == .Inout || !variadic_view_accepts(k.c, arg.type, element) {
		return RANK_NONE
	}
	concrete := arg.type
	if type_is_untyped(k.c, concrete) {
		concrete = default_type(k.c, concrete)
		if arg.const_value.kind != .Invalid {
			if _, fits := convert_const(k.c, arg.const_value, concrete, false); !fits {
				return RANK_NONE
			}
		}
	}
	return variadic_view_satisfied(k, concrete, element, arg.span) ? RANK_BUILTIN : RANK_NONE
}

// design.md "Variadic parameters": a value a `..^T` pack borrows ranks as a borrow,
// an unfixed constant as its conversion to `T`, and a spread lending its elements as
// that spread of a `[]T` would.
@(private = "file")
variadic_lend_rank :: proc(k: ^Checker, arg: Arg_Info, element, want: Type_Id) -> int {
	pointee, lends := variadic_lent_pointee(k.c, element)
	if !lends || arg.waiting || arg.mode == .Inout {
		return RANK_NONE
	}
	if arg.mode == .Spread {
		if !variadic_spread_lends(k.c, arg.type, want) {
			return RANK_NONE
		}
		return argument_rank(k, arg, slice_of(k.c, pointee, false), .Value)
	}
	if !variadic_lend_accepts(k.c, arg.type, element) {
		return RANK_NONE
	}
	return type_is_untyped(k.c, arg.type) ? argument_rank(k, arg, pointee, .Value) : RANK_ADJUST
}

// ----------------------------------------------------------------- candidates --

arity_reason :: proc(c: ^Compiler, count: int, supplied: int) -> string {
	return fmt.aprintf(
		"it takes %d argument%s, found %d",
		count,
		count == 1 ? "" : "s",
		supplied,
		allocator = c.semantic_allocator,
	)
}

// design.md "`@(c_vararg)`": why an argument past the fixed parameters cannot be
// passed, or "" when it can.
@(private = "file")
c_vararg_rejection :: proc(k: ^Checker, arg: Arg_Info, position: int) -> string {
	reason := ""
	switch {
	case arg.mode == .Spread:
		reason = "a C-variadic call cannot spread"
	case arg.mode == .Inout:
		reason = "a C-variadic argument is passed by value, so it cannot be `inout`"
	case arg.waiting:
		reason = "a C-variadic argument needs a concrete type"
	case:
		concrete := type_is_untyped(k.c, arg.type) ? default_type(k.c, arg.type) : arg.type
		if concrete == INVALID_TYPE {
			reason = "a C-variadic argument needs a concrete type"
		} else if safe, why := foreign_abi_safe(k.c, concrete); !safe {
			reason = why
		}
	}
	if reason == "" {
		return ""
	}
	return fmt.aprintf("argument %d: %s", position + 1, reason, allocator = k.c.semantic_allocator)
}

@(private = "file")
argument_mismatch_reason :: proc(c: ^Compiler, index: int, found, want: Type_Id) -> string {
	return fmt.aprintf(
		"argument %d is `%s` where `%s` is wanted",
		index + 1,
		type_name(c, found),
		type_name(c, want),
		allocator = c.semantic_allocator,
	)
}

// Why a candidate cannot take `arg`, which ranked `RANK_NONE` against `want`.
@(private = "file")
rejection_reason :: proc(k: ^Checker, arg: Arg_Info, index: int, want: Type_Id, mode: Param_Mode) -> string {
	if !arg.is_receiver && (mode == .Inout) != (arg.mode == .Inout) {
		format := "it does not take argument %d by `inout`"
		if mode == .Inout {
			format = arg.waiting ? "it takes argument %d by `inout`, which needs a place" : "it takes argument %d by `inout`; write `inout` at the call site"
		}
		return fmt.aprintf(format, index + 1, allocator = k.c.semantic_allocator)
	}
	if _, moved := arg.expr.(^Expr_Move); moved && arg.is_receiver && mode != .Move {
		return "it borrows its receiver, so `move(...)` gives away more than it takes"
	}
	// A wrong type is the reason whatever the mode, since `move(...)` would not
	// change it.
	if mode == .Move && !expression_is_owned_argument(arg.expr) && argument_rank(k, arg, want, .Value) != RANK_NONE {
		// design.md "Union argument expansion": a place lends its payload, and
		// moving the operand is what gives it up.
		if payload, expanded := arg.expr.(^Expr_Ident); expanded && payload.name == DISPATCH_PAYLOAD {
			return "it takes the payload by `move`, and a place lends it; this is written `..move(...)`"
		}
		if arg.is_receiver {
			return "it consumes its receiver, which is written `move(...)`"
		}
		return fmt.aprintf(
			"it takes argument %d by `move`, which is written `move(...)`",
			index + 1,
			allocator = k.c.semantic_allocator,
		)
	}
	return argument_mismatch_reason(k.c, index, arg.type, want)
}

@(private = "file")
rejection_text :: proc(k: ^Checker, cand: Candidate) -> string {
	switch why in cand.reason {
	case string:
		return why
	case Rejected_Arity:
		return arity_reason(k.c, why.count, why.supplied)
	case Rejected_Argument:
		return rejection_reason(k, cand.args[why.index], why.index, why.want, why.mode)
	}
	return "it is not viable here"
}

// Places, ranks, and records why a rejected candidate is rejected.
@(private = "file")
build_candidate :: proc(k: ^Checker, symbol_id: Symbol_Id, args: []Arg_Info) -> Candidate {
	if template := generic_template_for(k, symbol_id); template != nil && template.kind == .Procedure {
		return build_generic_candidate(k, template, args)
	}
	cand := Candidate {
		symbol = symbol_id,
		args   = args,
		ranks  = make([]int, len(args), k.c.semantic_allocator),
		slots  = make([]int, len(args), k.c.semantic_allocator),
	}
	sym := symbol_of(k.c, symbol_id)
	if sym == nil {
		cand.reason = "this name is not a procedure"
		return cand
	}
	if sym.proc_type == INVALID_TYPE && sym.decl != nil {
		resolve_declaration_signature(k, sym.decl)
		sym = symbol_of(k.c, symbol_id)
	}
	info := type_of(k.c, sym.proc_type)
	if info == nil || info.kind != .Proc {
		cand.reason = "this name is not a procedure"
		return cand
	}

	count := len(sym.params)
	cand.filled = make([]bool, count, k.c.semantic_allocator)
	// Trailing values rank against the pack element; spreads rank against the pack.
	pack := variadic_parameter_index(info)
	element := INVALID_TYPE
	if pack >= 0 {
		element = slice_element(k.c, sym.params[pack])
	}
	cand.variadic = pack >= 0 || info.c_vararg
	named := false
	for arg, index in args {
		slot := index
		if arg.name != INVALID_IDENTIFIER {
			named = true
			slot = parameter_slot_named(k.c, sym, arg.name)
			if slot < 0 {
				cand.reason = fmt.aprintf(
					"it has no parameter named `%s`",
					identifier_text(k.c, arg.name),
					allocator = k.c.semantic_allocator,
				)
				return cand
			}
			if cand.filled[slot] {
				cand.reason = fmt.aprintf(
					"`%s` is given twice",
					identifier_text(k.c, arg.name),
					allocator = k.c.semantic_allocator,
				)
				return cand
			}
		} else if named {
			cand.reason = "a positional argument cannot follow a named one"
			return cand
		} else if pack >= 0 && slot >= pack {
			slot = pack
		} else if info.c_vararg && slot >= count {
			if rejection := c_vararg_rejection(k, arg, index); rejection != "" {
				cand.reason = rejection
				return cand
			}
			cand.slots[index] = -1
			cand.ranks[index] = RANK_BUILTIN
			continue
		} else if slot >= count {
			cand.reason = Rejected_Arity{count, len(args)}
			return cand
		}
		cand.filled[slot] = true
		cand.slots[index] = slot
		mode := proc_parameter_mode(k.c, sym.proc_type, slot)
		want := sym.params[slot]
		if slot == pack {
			if arg.name != INVALID_IDENTIFIER {
				cand.reason = "a variadic argument cannot be named"
				return cand
			}
			mode = .Value
			want = arg.mode == .Spread ? sym.params[pack] : element
		} else if arg.mode == .Spread {
			cand.reason = "`..` spreads into a variadic parameter"
			return cand
		}
		rank := argument_rank(k, arg, want, mode)
		if rank == RANK_NONE && slot == pack && arg.mode != .Spread {
			rank = variadic_view_rank(k, arg, element)
		}
		if rank == RANK_NONE && slot == pack {
			rank = variadic_lend_rank(k, arg, element, want)
		}
		if rank == RANK_NONE {
			cand.reason = Rejected_Argument{index, want, mode}
			return cand
		}
		cand.ranks[index] = rank
		// `argument_rank` lets only an owned argument reach a `move` parameter.
		if mode == .Move {
			cand.consumed += 1
		}
	}

	for slot in 0 ..< count {
		if cand.filled[slot] || slot == pack {
			continue
		}
		if slot >= len(sym.param_defaults) || sym.param_defaults[slot] == nil {
			cand.reason = Rejected_Arity{count, len(args)}
			return cand
		}
		cand.omitted += 1
	}
	cand.viable = true
	return cand
}

// Instantiates and ranks a generic signature without checking its body.
@(private = "file")
build_generic_candidate :: proc(k: ^Checker, template: ^Generic_Template, args: []Arg_Info) -> Candidate {
	if template_rejected(k, template) {
		return Candidate{symbol = template.symbol, args = args, template = template}
	}
	inference := infer_generic_arguments(k, template, args)
	if !inference.ok {
		return Candidate {
			symbol       = template.symbol,
			args         = args,
			reason       = inference.reason,
			unbound_wait = inference.unbound_wait,
			waiting_arg  = inference.waiting_arg,
		}
	}
	instance, made := instantiate_generic(k, template, inference.bindings, inference.scope, NO_SPAN, report = false)
	if !made {
		reason := "its `where` bounds are not satisfied by these arguments"
		if instance != nil && instance.rejection.message != "" {
			reason = instance.rejection.message
		} else if instance != nil && instance.failed_bound != nil {
			reason = failed_bound_reason(k, template, instance)
		}
		return Candidate {
			symbol   = template.symbol,
			args     = args,
			reason   = reason,
			template = template,
			bindings = inference.bindings,
			scope    = inference.scope,
		}
	}
	cand := build_candidate(k, instance.symbol, inference.runtime_args)
	if cand.viable {
		ordering := make([]int, len(args), k.c.semantic_allocator)
		runtime_index := 0
		for arg, index in args {
			if inference.compile_time[index] {
				rank := argument_rank(k, arg, inference.compile_targets[index], .Value)
				if rank == RANK_NONE {
					cand.viable = false
					cand.reason = argument_mismatch_reason(k.c, index, arg.type, inference.compile_targets[index])
					break
				}
				ordering[index] = rank
				continue
			}
			ordering[index] = cand.ranks[runtime_index]
			runtime_index += 1
		}
		cand.ranks = ordering
	}
	if cand.viable {
		cand.template = template
	}
	cand.parametric = true
	cand.omitted += inference.compile_omitted
	cand.instance = instance
	return cand
}

// ------------------------------------------------------------------ ordering --

// -1: a wins, 1: b wins, 0: equal, 2: crossed and ambiguous.
@(private = "file")
compare_vectors :: proc(a, b: []int) -> int {
	a_better, b_better := false, false
	for value, index in a {
		if value < b[index] {
			a_better = true
		} else if value > b[index] {
			b_better = true
		}
	}
	switch {
	case a_better && b_better:
		return 2
	case a_better:
		return -1
	case b_better:
		return 1
	}
	return 0
}

// Returns -1 when a wins, 1 when b wins, or 0 when still tied. Ownership comes
// first, so a temporary or `move(...)` reaches a consuming member whatever the
// members' shapes (design.md tie-breaker 1).
@(private = "file")
tie_break :: proc(k: ^Checker, a, b: ^Candidate) -> int {
	if a.consumed != b.consumed {
		return a.consumed > b.consumed ? -1 : 1
	}
	if a.variadic != b.variadic {
		return a.variadic ? 1 : -1
	}
	if a.omitted != b.omitted {
		return a.omitted < b.omitted ? -1 : 1
	}
	if a.parametric != b.parametric {
		return a.parametric ? 1 : -1
	}
	return a.parametric ? compare_generic_specificity(k, a.template, b.template) : 0
}

@(private = "file")
candidate_better :: proc(k: ^Checker, a, b: ^Candidate) -> bool {
	switch compare_vectors(a.ranks, b.ranks) {
	case -1:
		return true
	case 1, 2:
		return false
	}
	return tie_break(k, a, b) == -1
}

// ------------------------------------------------------------------- entry --

// `description` names the construct in diagnostics. Selection reads only the
// arguments; a destination type checks the chosen result afterwards and never
// selects (design.md "Operator lookup and overload resolution").
resolve_overload :: proc(
	k: ^Checker,
	span: Span,
	description: string,
	members: []Symbol_Id,
	args: []Arg_Info,
) -> (Candidate, bool) {
	return choose_candidate(k, span, description, members, form_candidates(k, members, args), args)
}

form_candidates :: proc(k: ^Checker, members: []Symbol_Id, args: []Arg_Info) -> []Candidate {
	all := make([]Candidate, len(members), context.temp_allocator)
	for member, index in members {
		all[index] = build_candidate(k, member, args)
	}
	return all
}

// The best of `all`, formed from `members` against `args`.
choose_candidate :: proc(
	k: ^Checker,
	span: Span,
	description: string,
	members: []Symbol_Id,
	all: []Candidate,
	args: []Arg_Info,
) -> (Candidate, bool) {
	if len(members) == 0 {
		errorf(k.c, span, "L0392", "%s has no overloads", description)
		return Candidate{}, false
	}
	if !candidates_viable(all) {
		report_no_match(k, span, description, all, args, members)
		return Candidate{}, false
	}

	maximal := make([dynamic]int, 0, len(all), context.temp_allocator)
	for &cand, index in all {
		if !cand.viable {
			continue
		}
		dominated := false
		for &other, other_index in all {
			if other.viable && other_index != index && candidate_better(k, &other, &cand) {
				dominated = true
				break
			}
		}
		if !dominated {
			append(&maximal, index)
		}
	}
	if len(maximal) == 1 {
		chosen := all[maximal[0]]
		promote_generic_instance(k, chosen.instance, span)
		return chosen, true
	}
	report_ambiguity(k, span, description, all, maximal[:])
	return Candidate{}, false
}

// Ambiguity counts as viable so syntax fallbacks do not hide it.
candidates_viable :: proc(all: []Candidate) -> bool {
	for cand in all {
		if cand.viable {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------- diagnostics --

@(private = "file")
report_no_match :: proc(
	k: ^Checker, span: Span, description: string, all: []Candidate, args: []Arg_Info, members: []Symbol_Id,
) {
	// A candidate whose declaration was rejected already explains the call.
	for cand in all {
		if cand.template != nil && cand.template.rejected {
			return
		}
	}
	// design.md "Arguments typed after inference": a sole generic reports at the
	// waiting argument that alone could bind a `$` name.
	if len(all) == 1 && all[0].unbound_wait {
		errorf(k.c, args[all[0].waiting_arg].span, "L0385", "%s", rejection_text(k, all[0]))
		return
	}
	// design.md "Parameter semantics and ABI lowering": a sole candidate reports
	// an `inout` argument of another type as a direct call does, at the argument.
	if len(all) == 1 {
		if why, rejected := all[0].reason.(Rejected_Argument); rejected {
			arg := all[0].args[why.index]
			if arg.mode == .Inout && why.mode == .Inout {
				check_bound_argument_mode(k, arg.expr, why.want, .Inout, "an `inout` argument")
				return
			}
		}
	}
	// A sole rejected generic can report its precise failed bound.
	if len(all) == 1 && all[0].template != nil {
		instantiate_generic(k, all[0].template, all[0].bindings, all[0].scope, span, report = true)
		return
	}
	errorf(k.c, span, "L0392", "no overload of %s applies to these arguments", description)
	for cand in all {
		sym := symbol_of(k.c, cand.symbol)
		if sym == nil {
			continue
		}
		add_notef(
			k.c,
			sym.span,
			"`%s` does not apply: %s",
			identifier_text(k.c, sym.name),
			rejection_text(k, cand),
		)
	}
	note_mutable_slice_arguments(k, args, members)
}

// design.md "Slices": a read-only `a[lo:hi]` passed where an overload wants a
// `[]mut T` is the usual reason none applies, so say so when the mutable
// slice would have selected one.
@(private = "file")
note_mutable_slice_arguments :: proc(k: ^Checker, args: []Arg_Info, members: []Symbol_Id) {
	for arg, index in args {
		sliced, is_slice := arg.expr.(^Expr_Slice)
		if !is_slice || sliced.mutable || type_kind(k.c, arg.type) != .Slice || slice_is_mutable(k.c, arg.type) {
			continue
		}
		strengthened := slice.clone(args, context.temp_allocator)
		strengthened[index].type = slice_of(k.c, type_of(k.c, arg.type).element, mutable = true)
		for member in members {
			if build_candidate(k, member, strengthened).viable {
				note_mutable_slicing(k, arg.expr, arg.type, strengthened[index].type)
				break
			}
		}
	}
}

@(private = "file")
report_ambiguity :: proc(k: ^Checker, span: Span, description: string, all: []Candidate, maximal: []int) {
	errorf(k.c, span, "L0391", "%s is ambiguous here: %d candidates are equally good", description, len(maximal))
	for index in maximal {
		sym := symbol_of(k.c, all[index].symbol)
		// design.md "Operator lookup and overload resolution": signatures, not
		// rank vectors.
		add_notef(
			k.c,
			sym.span,
			"candidate `%s`: `%s`",
			identifier_text(k.c, sym.name),
			type_name(k.c, sym.proc_type),
		)
	}
	add_notef(k.c, NO_SPAN, "%s", failing_tie_breaker(all, maximal))
}

@(private = "file")
failing_tie_breaker :: proc(all: []Candidate, maximal: []int) -> string {
	for index in maximal {
		for other in maximal {
			if other == index {
				continue
			}
			if compare_vectors(all[index].ranks, all[other].ranks) == 2 {
				return "each of these converts a different argument better than the others, which is ambiguous by design; call the one you want by name, or give the arguments the types it declares"
			}
		}
	}
	return "no candidate is more specialized than the others; call the one you want by name, or give the arguments the types it declares"
}

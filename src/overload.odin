// Shared overload resolution for calls, methods, operators, construction, and indexing.
package lokec

import "core:slice"
import "core:fmt"
import "core:strings"

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
	is_const:    bool,
	const_value: Const_Value,
	is_receiver: bool,
}

Candidate :: struct {
	symbol: Symbol_Id,
	// Runtime ranks and the full vector including compile-time `$` arguments.
	ranks:  []int,
	ordering_ranks: []int,
	slots:  []int,
	filled: []bool,
	// Generic candidates keep only their runtime arguments here.
	args:   []Arg_Info,

	omitted:    int,
	variadic:   bool,
	parametric: bool,
	// Tie-breaker 5: arguments whose written form did not name the chosen mode.
	mode_adjusted: int,
	instance:   ^Instance,
	// The originating generic, also used to report a rejected bound.
	template:   ^Generic_Template,
	bindings:   []Generic_Binding,
	scope:      ^Scope,
	viable:     bool,
	reason:     string,
}

@(private = "file")
candidate_ranks :: proc(cand: ^Candidate) -> []int {
	return cand.ordering_ranks != nil ? cand.ordering_ranks : cand.ranks
}

// -------------------------------------------------------------- groups --

// Members resolve after declaration collection, including later declarations.
resolve_group_members :: proc(k: ^Checker, group_id: Symbol_Id, value: ^Expr_Proc_Group) {
	members := make([dynamic]Symbol_Id, 0, len(value.names), k.c.semantic_allocator)
	for name in value.names {
		id := name.id
		if id == INVALID_IDENTIFIER {
			id = intern_identifier(k.c, name.text)
		}
		member := INVALID_SYMBOL
		owner := symbol_of(k.c, group_id)
		if owner != nil && owner.owner_type != INVALID_TYPE {
			member = find_member(k, owner.owner_type, id)
			if member == INVALID_SYMBOL && excluded_member(k, owner.owner_type, id) != nil {
				continue
			}
		} else {
			member = lookup_symbol(k.scope, id)
		}
		if member == INVALID_SYMBOL {
			errorf(k.c, name.span, "L0395", "unknown name `%s` in this procedure group", name.text)
			continue
		}
		if sym := symbol_of(k.c, member); sym != nil && sym.decl != nil && sym.decl.sig_state == .Unchecked {
			resolve_declaration_signature(k, sym.decl)
		}
		sym := symbol_of(k.c, member)
		if sym == nil || sym.kind != .Proc {
			errorf(k.c, name.span, "L0393", "`%s` is not a procedure, so it cannot be a group member", name.text)
			continue
		}
		if slice.contains(members[:], member) {
			errorf(k.c, name.span, "L0394", "`%s` is already a member of this group", name.text)
			continue
		}
		append(&members, member)
	}
	if group := symbol_of(k.c, group_id); group != nil {
		group.members = members[:]
	}
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
		k.place_position, k.insert_position = arg.mode == .Inout, false
		expected := INVALID_TYPE
		if argument_needs_context(arg.value) {
			context_candidates := candidates
			if live_group != INVALID_SYMBOL {
				if group := symbol_of(k.c, live_group); group != nil && group.kind == .Proc_Group {
					context_candidates = group.members
				}
			}
			expected = common_argument_type(k, context_candidates, info.name, index + offset)
		}
		info.type = check_single_expr(k, arg.value, expected)
		k.place_position, k.insert_position = false, false
		if info.type == INVALID_TYPE {
			ok = false
		} else if base := expr_base(arg.value); base != nil {
			info.is_const = base.is_const
			info.const_value = base.const_value
		}
		out[index] = info
	}
	return out, ok
}

// Typeless aggregates and implicit selectors need a destination type.
argument_needs_context :: proc(e: Expr) -> bool {
	#partial switch v in e {
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

@(private = "file")
common_argument_type :: proc(k: ^Checker, candidates: []Symbol_Id, name: Identifier_Id, position: int) -> Type_Id {
	common := INVALID_TYPE
	for candidate in candidates {
		sym := symbol_of(k.c, candidate)
		if sym == nil || sym.generic { return INVALID_TYPE }
		slot := position
		if name != INVALID_IDENTIFIER {
			slot = -1
			for binding, index in sym.param_symbols {
				if param := symbol_of(k.c, binding); param != nil && param.name == name {
					slot = index
					break
				}
			}
		}
		if slot < 0 { continue }
		// A written variadic element wants `T`, not the pack's `[]T`.
		variadic := -1
		if signature := underlying_info(k.c, sym.proc_type); signature != nil {
			for mode, index in signature.param_modes {
				if mode == .Variadic {
					variadic = index
					break
				}
			}
		}
		if variadic >= 0 && slot > variadic { slot = variadic }
		if slot >= len(sym.params) { continue }
		type := sym.params[slot]
		if slot == variadic {
			pack := underlying_info(k.c, type)
			if pack == nil { return INVALID_TYPE }
			type = pack.element
		}
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
		is_const    = base.is_const,
		const_value = base.const_value,
	}
}

// ------------------------------------------------------------------- ranking --

// Side-effect-free conversion rank; materialization happens after selection.
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

@(private = "file")
argument_rank :: proc(k: ^Checker, arg: Arg_Info, param: Type_Id, mode: Param_Mode) -> int {
	if param == INVALID_TYPE || arg.type == INVALID_TYPE {
		return RANK_NONE
	}
	// Modes decide viability and ties, not conversion rank. Receiver modes are implicit.
	_, moved := arg.expr.(^Expr_Move)
	adjusted := false
	if arg.is_receiver {
		if mode == .Move {
			if !expression_is_owned_argument(arg.expr) {
				return RANK_NONE
			}
		} else if moved {
			return RANK_NONE
		}
		adjusted = mode != .Value
	} else {
		want_inout := mode == .Inout
		if want_inout != (arg.mode == .Inout) {
			return RANK_NONE
		}
		owned := expression_is_owned_argument(arg.expr)
		if mode == .Move && !owned {
			return RANK_NONE
		}
	}
	if arg.type == param {
		return adjusted ? RANK_ADJUST : RANK_EXACT
	}
	// design.md "Receiver forms": `Type.method(&value)` names the receiver
	// `self: ^T` receives.
	if mode == .Borrow && !arg.is_receiver && pointer_to_element(k.c, arg.type) == param {
		return RANK_ADJUST
	}
	if type_is_untyped(k.c, arg.type) {
		if assignable(k.c, arg.type, param) {
			if arg.is_const {
				wanted := param
				if param == TYPE_ANY_VIEW {
					wanted = any_view_source_type(k.c, arg.type)
				}
				if _, fits := convert_const(k.c, arg.const_value, wanted, false); !fits {
					return RANK_NONE
				}
			}
			if constant_conversion_preserves_kind(k.c, arg.type, param) {
				return RANK_CONST_KIND
			}
			return RANK_BUILTIN
		}
		return RANK_NONE
	}
	if assignable(k.c, arg.type, param) {
		return carrier_weakens_to(k.c, arg.type, param) ? RANK_ADJUST : RANK_BUILTIN
	}
	return RANK_NONE
}

// ----------------------------------------------------------------- candidates --

@(private = "file")
arity_reason :: proc(c: ^Compiler, count: int, supplied: int) -> string {
	return fmt.aprintf(
		"it takes %d argument%s, found %d",
		count,
		count == 1 ? "" : "s",
		supplied,
		allocator = c.semantic_allocator,
	)
}

// Places, ranks, and records a diagnostic reason for a rejected candidate.
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
		cand.variadic = true
		element = slice_element(k.c, sym.params[pack])
	}
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
		} else if slot >= count {
			cand.reason = arity_reason(k.c, count, len(args))
			return cand
		}
		cand.filled[slot] = true
		cand.slots[index] = slot
		mode := slot < len(info.param_modes) ? info.param_modes[slot] : Param_Mode.Value
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
		if rank == RANK_NONE {
			if _, moved := arg.expr.(^Expr_Move); moved != (mode == .Move) {
				if arg.is_receiver {
					cand.reason = "it borrows its receiver, so `move(...)` gives away more than it takes"
					if mode == .Move {
						cand.reason = "it consumes its receiver, which is written `move(...)`"
					}
					return cand
				}
				if mode == .Move {
					cand.reason = fmt.aprintf(
						"it takes argument %d by `move`, which is written `move(...)`",
						index + 1,
						allocator = k.c.semantic_allocator,
					)
					return cand
				}
			}
			cand.reason = fmt.aprintf(
				"argument %d is `%s` where `%s` is wanted",
				index + 1,
				type_name(k.c, args[index].type),
				type_name(k.c, want),
				allocator = k.c.semantic_allocator,
			)
			return cand
		}
		cand.ranks[index] = rank
		if _, transferred := arg.expr.(^Expr_Move); transferred != (mode == .Move) {
			cand.mode_adjusted += 1
		}
	}

	for slot in 0 ..< count {
		if cand.filled[slot] {
			continue
		}
		if slot == pack {
			continue
		}
		if slot >= len(sym.param_defaults) || sym.param_defaults[slot] == nil {
			cand.reason = arity_reason(k.c, count, len(args))
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
	inference := infer_generic_arguments(k, template, args)
	if !inference.ok {
		return Candidate{symbol = template.symbol, args = args, reason = inference.reason}
	}
	instance, made := instantiate_generic(k, template, inference.bindings, inference.scope, no_span(), report = false)
	if !made {
		reason := "its `where` bounds are not satisfied by these arguments"
		if instance != nil && instance.rejection.message != "" {
			reason = instance.rejection.message
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
					cand.reason = fmt.aprintf(
						"argument %d is `%s` where `%s` is wanted",
						index + 1,
						type_name(k.c, arg.type),
						type_name(k.c, inference.compile_targets[index]),
						allocator = k.c.semantic_allocator,
					)
					break
				}
				ordering[index] = rank
				continue
			}
			ordering[index] = cand.ranks[runtime_index]
			runtime_index += 1
		}
		cand.ordering_ranks = ordering
	}
	if cand.viable {
		cand.template = template
	}
	cand.parametric = true
	cand.omitted += inference.compile_omitted
	cand.instance = instance
	if !cand.viable && cand.reason == "" {
		cand.reason = "it does not apply to these arguments"
	}
	return cand
}

// ------------------------------------------------------------------ ordering --

// -1: a wins, 1: b wins, 0: equal, 2: crossed and ambiguous.
@(private = "file")
compare_vectors :: proc(a, b: []int) -> int {
	if len(a) != len(b) {
		return 2
	}
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

// Returns -1 when a wins, 1 when b wins, or 0 when still tied.
@(private = "file")
tie_break :: proc(a, b: ^Candidate) -> int {
	if a.variadic != b.variadic {
		return a.variadic ? 1 : -1
	}
	if a.omitted != b.omitted {
		return a.omitted < b.omitted ? -1 : 1
	}
	if a.parametric != b.parametric {
		return a.parametric ? 1 : -1
	}
	if a.parametric && b.parametric {
		if preference := compare_generic_specificity(a.template, b.template); preference != 0 {
			return preference
		}
	}
	if a.mode_adjusted != b.mode_adjusted {
		return a.mode_adjusted < b.mode_adjusted ? -1 : 1
	}
	return 0
}

@(private = "file")
candidate_better :: proc(a, b: ^Candidate) -> bool {
	switch compare_vectors(candidate_ranks(a), candidate_ranks(b)) {
	case -1:
		return true
	case 1, 2:
		return false
	}
	return tie_break(a, b) == -1
}

// ------------------------------------------------------------------- entry --

// `description` names the construct in diagnostics.
resolve_overload :: proc(
	k: ^Checker,
	span: Span,
	description: string,
	members: []Symbol_Id,
	args: []Arg_Info,
	expected: Type_Id = INVALID_TYPE,
	report := true,
) -> (Candidate, bool) {
	if len(members) == 0 {
		if report {
			errorf(k.c, span, "L0392", "%s has no overloads", description)
		}
		return Candidate{}, false
	}
	all := make([]Candidate, len(members), context.temp_allocator)
	viable := make([dynamic]int, 0, len(members), context.temp_allocator)
	for member, index in members {
		all[index] = build_candidate(k, member, args)
		if all[index].viable {
			append(&viable, index)
		}
	}
	if len(viable) == 0 {
		if report {
			report_no_match(k, span, description, all[:])
		}
		return Candidate{}, false
	}

	if expected != INVALID_TYPE && len(viable) > 1 {
		kept := make([dynamic]int, 0, len(viable), context.temp_allocator)
		for index in viable {
			if candidate_result_fits(k, all[index].symbol, expected) {
				append(&kept, index)
			}
		}
		if len(kept) > 0 {
			viable = kept
		}
	}

	maximal := make([dynamic]int, 0, len(viable), context.temp_allocator)
	for index in viable {
		dominated := false
		for other in viable {
			if other != index && candidate_better(&all[other], &all[index]) {
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
	if report {
		report_ambiguity(k, span, description, all[:], maximal[:])
	}
	return Candidate{}, false
}

// Ambiguity counts as viable so syntax fallbacks do not hide it.
overload_has_viable :: proc(
	k: ^Checker,
	members: []Symbol_Id,
	args: []Arg_Info,
) -> bool {
	for member in members {
		cand := build_candidate(k, member, args)
		if cand.viable {
			return true
		}
	}
	return false
}

@(private = "file")
candidate_result_fits :: proc(k: ^Checker, symbol_id: Symbol_Id, expected: Type_Id) -> bool {
	sym := symbol_of(k.c, symbol_id)
	if sym == nil || sym.result == INVALID_TYPE {
		return false
	}
	return sym.result == expected || assignable(k.c, sym.result, expected)
}

// ---------------------------------------------------------------- diagnostics --

@(private = "file")
report_no_match :: proc(k: ^Checker, span: Span, description: string, all: []Candidate) {
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
			cand.reason == "" ? "it is not viable here" : cand.reason,
		)
	}
}

@(private = "file")
report_ambiguity :: proc(k: ^Checker, span: Span, description: string, all: []Candidate, maximal: []int) {
	errorf(k.c, span, "L0391", "%s is ambiguous here: %d candidates are equally good", description, len(maximal))
	for index in maximal {
		sym := symbol_of(k.c, all[index].symbol)
		if sym == nil {
			continue
		}
		add_notef(
			k.c,
			sym.span,
			"candidate `%s` with conversion vector %s",
			identifier_text(k.c, sym.name),
			vector_text(k.c, candidate_ranks(&all[index])),
		)
	}
	add_notef(k.c, no_span(), "selection failed at %s", failing_tie_breaker(all, maximal))
}

@(private = "file")
failing_tie_breaker :: proc(all: []Candidate, maximal: []int) -> string {
	for index in maximal {
		for other in maximal {
			if other == index {
				continue
			}
			if compare_vectors(candidate_ranks(&all[index]), candidate_ranks(&all[other])) == 2 {
				return "crossed conversion vectors, which are ambiguous by design"
			}
		}
	}
	return "tie-breaker 5, where no candidate better matches the written parameter modes"
}

@(private = "file")
vector_text :: proc(c: ^Compiler, ranks: []int) -> string {
	b := strings.builder_make(c.semantic_allocator)
	strings.write_string(&b, "(")
	for rank, index in ranks {
		if index > 0 {
			strings.write_string(&b, ", ")
		}
		fmt.sbprintf(&b, "%d", rank)
	}
	strings.write_string(&b, ")")
	return strings.to_string(b)
}

// --------------------------------------------------------------- binding --

// Binds the chosen candidate in parameter order and materializes constants.
bind_chosen_call :: proc(k: ^Checker, v: ^Expr_Call, cand: Candidate) -> bool {
	sym := symbol_of(k.c, cand.symbol)
	if sym == nil {
		return false
	}
	if info := type_of(k.c, sym.proc_type); variadic_parameter_index(info) >= 0 {
		receiver: Expr
		if len(cand.args) > 0 && cand.args[0].is_receiver {
			receiver = cand.args[0].expr
		}
		bound_ok := bind_variadic_arguments(
			k, v, info, cand.symbol, candidate_arguments(k.c, cand),
			prechecked = true, receiver = receiver,
		)
		require_argument_ownership(k, v, cand.symbol)
		return bound_ok
	}
	count := len(sym.params)
	bound := make([]Expr, count, k.c.semantic_allocator)
	ok := true
	for arg, index in cand.args {
		slot := cand.slots[index]
		value := arg.expr
		mode := proc_parameter_mode(k.c, sym.proc_type, slot)
		if mode == .Borrow && !arg.is_receiver && pointer_to_element(k.c, arg.type) == sym.params[slot] {
			value = dereference_argument(k, value)
		}
		if !materialize_argument(k, value, sym.params[slot]) {
			ok = false
			continue
		}
		if !check_bound_argument_mode(k, value, mode, "an `inout` argument") {
			ok = false
		}
		bound[slot] = value
	}
	for slot in 0 ..< count {
		if !cand.filled[slot] && slot < len(sym.param_defaults) {
			bound[slot] = substitute_caller_location(k, sym.param_defaults[slot], v.span)
		}
	}
	v.bound = bound
	require_argument_ownership(k, v, cand.symbol)
	return ok
}

@(private = "file")
candidate_arguments :: proc(c: ^Compiler, cand: Candidate) -> []Argument {
	count := len(cand.args)
	if count > 0 && cand.args[0].is_receiver {
		count -= 1
	}
	out := make([]Argument, count, c.semantic_allocator)
	index := 0
	for arg in cand.args {
		if arg.is_receiver {
			continue
		}
		name := Name{}
		if arg.name != INVALID_IDENTIFIER {
			name = Name{text = identifier_text(c, arg.name), span = arg.span, id = arg.name}
		}
		out[index] = Argument{span = arg.span, name = name, mode = arg.mode, value = arg.expr}
		index += 1
	}
	return out
}

// The pointee of a `^T` or `^mut T`, or INVALID_TYPE.
pointer_to_element :: proc(c: ^Compiler, type: Type_Id) -> Type_Id {
	info := type_of(c, type)
	return info != nil && info.kind == .Pointer ? info.element : INVALID_TYPE
}

// `pointer^`, already checked: a borrowing parameter given the address takes
// the place it names.
dereference_argument :: proc(k: ^Checker, pointer: Expr) -> Expr {
	info := type_of(k.c, expr_base(pointer).type)
	deref := new(Expr_Postfix, k.c.semantic_allocator)
	deref.span, deref.op_span, deref.op, deref.operand = expr_span(pointer), expr_span(pointer), .Caret, pointer
	deref.type = info.element
	deref.value_category = .Place
	deref.addressable = true
	deref.assignable = info.mutable
	deref.immutable = info.mutable ? .None : .Through_Pointer
	return deref
}

materialize_argument :: proc(k: ^Checker, e: Expr, target: Type_Id) -> bool {
	return materialize_value_expr(k, e, target, "pass")
}

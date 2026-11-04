// Call checking, overload selection, argument binding, and explicit conversions.
// check_expr.odin dispatches expressions here; overload.odin owns candidate
// ranking, and feature checkers retain their specialized call contracts.
package lokec

import "core:slice"

// ------------------------------------------------------- calls and casts --

// design.md "Evaluation order": the parameter slot a call evaluates at `step`.
call_slot_at :: proc(v: ^Expr_Call, step: int) -> int {
	return step < len(v.bound_order) ? v.bound_order[step] : step
}

// design.md "Procedure type", "Evaluation order": a call through a procedure
// value rather than to a named procedure, method, or callable record's `call`.
call_through_value :: proc(c: ^Compiler, v: ^Expr_Call) -> bool {
	if _, procedure := v.operation.(Call_Procedure); !procedure {
		return false
	}
	if sym := symbol_of(c, v.resolution.chosen_overload); sym != nil && sym.kind == .Proc {
		return false
	}
	base := expr_base(v.callee)
	return base != nil && underlying_kind(c, base.type) == .Proc
}

@(private)
check_call :: proc(k: ^Checker, v: ^Expr_Call, expected: Type_Id) {
	if check_union_argument_expansion(k, v, expected) {
		return
	}
	defer materialize_call_receiver(k, v)
	defer report_argument_copies(k, v)
	v.value_category = .Value

	selector, _ := v.callee.(^Expr_Selector)
	if selector != nil {
		selector.receiver_checked = false
	}
	if check_compile_time_callee(k, v, expected) {
		if selector != nil {
			selector.receiver_checked = false
		}
		return
	}

	// A bare `.name(payload)` takes its union from the expected type.
	callee_expected := INVALID_TYPE
	if sel, is_selector := v.callee.(^Expr_Selector); is_selector && sel.operand == nil {
		callee_expected = expected
	}
	callee_type := check_expr(k, v.callee, callee_expected, .Callee)
	callee_base := expr_base(v.callee)
	if callee_base == nil {
		return
	}
	if callee_base.resolution.kind == .Method {
		check_method_call(k, v, v.callee.(^Expr_Selector))
		return
	}
	if callee_base.resolution.kind == .Union_Variant {
		check_union_construct(k, v, v.callee.(^Expr_Selector))
		return
	}
	if callee_type == INVALID_TYPE {
		return
	}
	if callee_base.value_category == .Type {
		// `(dyn Drawable)(&circle)` checks satisfaction and requests a witness.
		if type_is_dyn(k.c, callee_base.denoted_type) {
			check_dyn_conversion(k, v, callee_base.denoted_type)
			return
		}
		check_conversion(k, v, callee_base.denoted_type)
		return
	}

	info := underlying_info(k.c, callee_type)
	if info == nil || info.kind != .Proc {
		if !check_callable_value_call(k, v, callee_type) {
			report_not_callable(k, v, callee_type)
		}
		return
	}
	check_procedure_call(k, v, callee_base, info)
}

// The receiver of `v.callee`, for a form that must see its type to know whether
// it applies: checked once per check of the call, whichever form asks, and the
// selector then takes this answer if none does. INVALID_TYPE for a package alias,
// which is no receiver, and for what failed to check.
check_receiver :: proc(k: ^Checker, sel: ^Expr_Selector) -> Type_Id {
	if sel.receiver_checked {
		return expr_base(sel.operand).type
	}
	if ident, is_ident := sel.operand.(^Expr_Ident); is_ident {
		if sym := symbol_of(k.c, lookup_symbol(k.scope, identifier_of(k.c, ident))); sym != nil && sym.kind == .Package_Alias {
			return INVALID_TYPE
		}
	}
	type := check_single_expr(k, sel.operand)
	sel.receiver_checked = true
	return type
}

// What a selector's operand names, if a type. A generic procedure's call must be
// checked to say, which makes it the receiver's one check.
receiver_denoted_type :: proc(k: ^Checker, sel: ^Expr_Selector) -> Type_Id {
	if call, is_call := sel.operand.(^Expr_Call); is_call && generic_template_of_callee(k, call.callee, .Procedure) != nil {
		check_receiver(k, sel)
		return call.value_category == .Type ? call.denoted_type : INVALID_TYPE
	}
	return resolve_type_syntax(k, sel.operand)
}

// The forms whose callee is not a value: built-ins, groups and generic
// procedures, interface and type applications, and compiler-defined operations.
// False when the callee is an ordinary expression to check.
@(private = "file")
check_compile_time_callee :: proc(k: ^Checker, v: ^Expr_Call, expected: Type_Id) -> bool {
	callee_symbol := named_callee_symbol(k, v.callee)
	sym := symbol_of(k.c, callee_symbol)

	// A built-in, spelled plainly or as `pkg.builtin`, is not a value.
	if sym != nil && sym.kind == .Builtin {
		ident, is_ident := v.callee.(^Expr_Ident)
		if !is_ident {
			ident = qualify_builtin_callee(k, v)
		}
		check_builtin_call(k, v, ident, callee_symbol, expected)
		return true
	}

	if report_handle_type_spelling(k, v, type_position = false) {
		return true
	}

	// Nor is a group or a generic procedure: overloads rank before any single
	// procedure type exists.
	template := generic_template_for(k, callee_symbol)
	if (sym != nil && sym.kind == .Proc_Group) || (template != nil && template.kind == .Procedure) {
		check_group_call(k, v, callee_symbol)
		return true
	}
	if group := associated_group(k, v.callee); group != INVALID_SYMBOL {
		check_group_call(k, v, group)
		return true
	}
	// An interface application is a compile-time boolean, not a conversion.
	if info := interface_info_for(k, callee_symbol); info != nil {
		v.operation = Call_Compile_Time{}
		check_interface_application(k, v, info)
		return true
	}
	// `Simd(f32, 4)`, `Range(int)`, `Box(int)`, and generic record applications
	// denote types.
	if range_callee(k, v.callee) {
		set_type_call(v, resolve_range_application(k, v))
		return true
	}
	if box_type_callee(k, v.callee) {
		set_type_call(v, resolve_box_application(k, v))
		return true
	}
	if simd_callee(k, v.callee) {
		set_type_call(v, resolve_simd_application(k, v))
		return true
	}
	if template != nil && (template.kind == .Record || template.kind == .Alias) {
		set_type_call(v, resolve_type_syntax(k, v))
		return true
	}
	// Compiler-defined operations on unions, text, enums, and descriptors.
	if sel, is_selector := v.callee.(^Expr_Selector); is_selector && sel.operand != nil {
		return check_box_unbox(k, v, sel) ||
		       check_as_call(k, v, sel) ||
		       check_text_operation(k, v, sel) ||
		       check_enum_builtin(k, v, sel) ||
		       check_descriptor_operation(k, v, sel)
	}
	return false
}

@(private = "file")
report_not_callable :: proc(k: ^Checker, v: ^Expr_Call, callee_type: Type_Id) {
	sel, is_sel := v.callee.(^Expr_Selector)
	if is_sel && sel.variant_union != INVALID_TYPE &&
	   union_variant_payload(k.c, sel.variant_union, sel.variant_index) == TYPE_VOID {
		errorf(
			k.c, v.span, "L0425",
			"`%s.%s` carries no payload: write it without a call",
			type_name(k.c, sel.variant_union), sel.name.text,
		)
		return
	}
	errorf(k.c, expr_span(v.callee), "L0320", "`%s` is not callable", type_name(k.c, callee_type))
	if field := symbol_of(k.c, subject_field_named(k, callee_type, intern_identifier(k.c, "call"))); field != nil {
		add_notef(k.c, field.span, "this `call` is a field; only a `call` method makes a value callable")
	}
}

// A call of one known procedure type, which only a directly named procedure
// (`f` or `pkg.f`) gives defaults and named parameters.
@(private = "file")
check_procedure_call :: proc(k: ^Checker, v: ^Expr_Call, callee_base: ^Expr_Base, info: ^Type_Info) {
	declaration := INVALID_SYMBOL
	if named := callee_base.resolution.symbol; callee_base.resolution.kind == .Value {
		if sym := symbol_of(k.c, named); sym != nil && sym.kind == .Proc {
			declaration = named
		}
	}
	if reject_direct_hook_call(k, v.span, declaration) {
		return
	}
	record_called_procedure(k, v, declaration)
	if !bind_arguments(k, v, info, declaration) {
		return
	}
	settle_call(k, v, info.result, info.result_inout, symbol_of(k.c, declaration))
}

// Every call of a procedure names what it called here.
@(private = "file")
record_called_procedure :: proc(k: ^Checker, v: ^Expr_Call, chosen: Symbol_Id) {
	v.resolution = Resolution{kind = .Call, symbol = chosen, chosen_overload = chosen}
	v.operation = Call_Procedure{}
	enroll_synth(k.c, chosen)
}

// Binds the candidate overload resolution chose and settles the call.
@(private = "file")
finish_chosen_call :: proc(k: ^Checker, v: ^Expr_Call, cand: Candidate) {
	if !bind_chosen_call(k, v, cand) {
		return
	}
	chosen := symbol_of(k.c, cand.symbol)
	settle_call(k, v, chosen.result, chosen.result_inout, chosen)
}

// Every call of a procedure ends here, whichever spelling reached it, so that
// `value.method()` and `Type.method(value)` stay the same call (design.md
// "Receiver forms"). `chosen` is nil for a call through a procedure value.
@(private = "file")
settle_call :: proc(k: ^Checker, v: ^Expr_Call, result: Type_Id, result_inout: bool, chosen: ^Symbol) {
	set_call_result(v, result, result_inout, result_written_but_unresolved(chosen))
	check_container_call(k, v, chosen)
	fold_standard_customization_call(k, v, chosen)
}

// design.md "Calling a value": `x(args)` on a value whose type has a `call`
// method is `x.call(args)`. The method is selected as `x.call` would select it,
// but never a field named `call`. The callee was checked already and becomes
// the receiver.
@(private = "file")
check_callable_value_call :: proc(k: ^Checker, v: ^Expr_Call, callee_type: Type_Id) -> bool {
	span := expr_span(v.callee)
	sel := synth_selector(k.c, v.callee, "call", span)
	if !select_call_method(k, sel, callee_type) {
		return false
	}
	v.callee = sel
	check_method_call(k, v, sel)
	return true
}

// Whether a procedure wrote a result that did not resolve. `Symbol.result` is
// INVALID_TYPE for that and for no result alike; only the syntax tells them apart.
@(private = "file")
result_written_but_unresolved :: proc(sym: ^Symbol) -> bool {
	if sym == nil || sym.result != INVALID_TYPE {
		return false
	}
	literal := sym.proc_literal
	if literal == nil && sym.decl != nil {
		literal = decl_proc_literal(sym.decl)
	}
	return literal != nil && literal.signature != nil && literal.signature.result != nil &&
		!literal.signature.result.diverges
}

// A call that denotes a type, such as `Simd(f32, 4)`.
@(private = "file")
set_type_call :: proc(v: ^Expr_Call, denoted: Type_Id) {
	if denoted == INVALID_TYPE {
		return
	}
	v.operation = Call_Compile_Time{}
	v.type = TYPE_TYPE
	v.value_category = .Type
	v.const_value = type_const(denoted)
}

// Every call spelling settles its result here. An `inout` result is a place
// (design.md "Parameter semantics and ABI lowering"); an unresolved one was
// already reported, so the call is invalid rather than void.
set_call_result :: proc(v: ^Expr_Call, result: Type_Id, result_inout: bool, result_unresolved := false) {
	if result == INVALID_TYPE {
		v.type = result_unresolved ? INVALID_TYPE : TYPE_VOID
		return
	}
	v.type = result
	if result_inout {
		v.value_category = .Place
		v.addressable = true
		v.assignable = true
		v.immutable = .None
	}
}

// design.md "@(require_results)": a bare call statement discards its results;
// `_ = call()` is an assignment and never reaches this.
report_discarded_required_results :: proc(k: ^Checker, expr: Expr) {
	call, is_call := expr.(^Expr_Call)
	if !is_call || call.type == TYPE_VOID || call.type == INVALID_TYPE {
		return // not a call, a call with no results, or one that did not resolve
	}
	if name, required := required_result_of_call(k, call); required {
		if name != "" {
			errorf(
				k.c, call.span, "L0612",
				"the result of `%s` must be used or discarded with `_ = ...`", name,
			)
			return
		}
		errorf(
			k.c, call.span, "L0612",
			"this call produces `%s`, which must be used or discarded with `_ = ...`",
			type_name(k.c, call.type),
		)
	}
}

// Whether a call's result must be handled, and the declaration or group that
// says so; an empty name means the result type requires it.
required_result_of_call :: proc(k: ^Checker, call: ^Expr_Call) -> (name: string, required: bool) {
	// design.md "Union argument expansion": the value is one of its calls'.
	if call.dispatch != nil {
		for entry in call.dispatch.cases {
			if arm, is_call := entry.arm.(^Expr_Call); is_call {
				if name, required = required_result_of_call(k, arm); required {
					return
				}
			}
		}
		return "", false
	}
	if selected := symbol_of(k.c, call.resolution.chosen_overload); selected != nil && selected.require_results {
		return identifier_text(k.c, selected.name), true
	}
	if group := symbol_of(k.c, call.group); group != nil && group.require_results {
		return identifier_text(k.c, group.name), true
	}
	return "", type_requires_results(k.c, call.type)
}

// Rewrites `pkg.builtin(...)` to the identifier form, keeping the written span.
@(private = "file")
qualify_builtin_callee :: proc(k: ^Checker, v: ^Expr_Call) -> ^Expr_Ident {
	selector := v.callee.(^Expr_Selector)
	ident := synth_ident(k.c, selector.name.text, selector.span)
	v.callee = ident
	return ident
}

// `Type.group(...)` or `pkg.Type.group(...)`, or a generic member such as
// `M(2, 3).times(a, b)`, which ranks as a template does when called bare. A
// value receiver is not type syntax, so it falls through to the method path
// silently.
@(private = "file")
associated_group :: proc(k: ^Checker, callee: Expr) -> Symbol_Id {
	sel, is_selector := callee.(^Expr_Selector)
	if !is_selector || sel.operand == nil {
		return INVALID_SYMBOL
	}
	subject := receiver_denoted_type(k, sel)
	if subject == INVALID_TYPE {
		return INVALID_SYMBOL
	}
	member := find_member(k, subject, name_identifier(k.c, sel.name))
	if sym := symbol_of(k.c, member); sym != nil && sym.kind == .Proc_Group {
		return member
	}
	if template := generic_template_for(k, member); template != nil && template.kind == .Procedure {
		return member
	}
	return INVALID_SYMBOL
}

// `value.method(args)`, with the receiver as argument zero. An `inout` receiver
// is implicit; a consuming one is written `move(value).method()` (design.md
// "Receiver forms").
@(private = "file")
check_method_call :: proc(k: ^Checker, v: ^Expr_Call, sel: ^Expr_Selector) {
	receiver := sel.operand
	receiver_base := expr_base(receiver)
	// design.md "Borrowed dynamic interface values": a `dyn` slot call
	// dispatches through the witness, however the view is held. A callable
	// view's `call` is its forwarding member, reached as any method is.
	if type_is_dyn(k.c, receiver_base.type) && dyn_proc_signature(k.c, receiver_base.type) == INVALID_TYPE &&
	   check_dyn_slot_call(k, v, sel, receiver_base.type) {
		return
	}
	method_name := name_identifier(k.c, sel.name)
	candidates := method_candidates(k, receiver_base.type, method_name)
	written, args_ok := collect_call_arguments(k, v.args, candidates, 1)
	if !args_ok {
		return
	}
	// A place receiver that every candidate consumes needs `move`; say so directly
	// rather than as a failed overload match.
	if !expression_is_owned_argument(receiver) && all_candidates_consume(k, candidates) {
		errorf(
			k.c, expr_span(receiver), "L0501",
			"`%s` consumes its receiver, so the call is written `move(...).%s(...)`",
			sel.name.text, sel.name.text,
		)
		return
	}
	args := make([]Arg_Info, len(written) + 1, k.c.semantic_allocator)
	args[0] = arg_from_expr(receiver)
	args[0].is_receiver = true
	copy(args[1:], written)

	description := concat(k.c, "method `", sel.name.text, "`")
	cand, resolved := resolve_overload(k, v.span, description, candidates, args)
	if !resolved {
		return
	}
	if len(candidates) > 1 {
		v.overload_members = candidates
	}
	group := find_member(k, receiver_base.type, method_name)
	if named := symbol_of(k.c, group); named != nil && named.kind == .Proc_Group {
		v.group = group
	}
	chosen := symbol_of(k.c, cand.symbol)
	if reject_direct_hook_call(k, v.span, cand.symbol) {
		return
	}
	// A mutating receiver is passed by address, so it must be an assignable place
	// and not a packed field, whose address may be misaligned.
	if chosen.receiver == .Inout && !check_inout_place(k, receiver, sel.name.span, "the receiver of a mutating method") {
		return
	}
	sel.resolution = Resolution{kind = .Method, symbol = cand.symbol}
	sel.type = chosen.proc_type
	record_called_procedure(k, v, cand.symbol)
	finish_chosen_call(k, v, cand)
}

reject_direct_hook_call :: proc(k: ^Checker, span: Span, symbol_id: Symbol_Id) -> bool {
	sym := symbol_of(k.c, symbol_id)
	if sym == nil || sym.hook == .None {
		return false
	}
	operation: string
	#partial switch sym.hook {
	case .Convert: operation = "`T(value)`"
	case .Copy:    operation = "`clone(value)` or `try_clone(value)`"
	case .Drop:    operation = "`drop(value)`"
	}
	errorf(k.c, span, "L0412", "`%s` implements `hook(%s)` and is not directly accessible; use %s", identifier_text(k.c, sym.name), hook_name(sym.hook), operation)
	return true
}

// A call through a group or generic procedure.
@(private = "file")
check_group_call :: proc(k: ^Checker, v: ^Expr_Call, group: Symbol_Id) {
	sym := symbol_of(k.c, group)
	members := sym.kind == .Proc_Group ? sym.members : []Symbol_Id{group}
	description := concat(k.c, "`", identifier_text(k.c, sym.name), "`")
	args, args_ok := collect_call_arguments(k, v.args, members, live_group = group)
	if !args_ok {
		return
	}
	// Checking an argument may instantiate a generic subject and add members.
	if current := symbol_of(k.c, group); current != nil && current.kind == .Proc_Group {
		members = current.members
	}
	cand, resolved := resolve_overload(k, v.span, description, members, args)
	if !resolved {
		return
	}
	if len(members) > 1 {
		v.overload_members = members
	}
	if sym.kind == .Proc_Group {
		v.group = group
	}
	annotate_chosen_callee(k, v, cand.symbol)
	finish_chosen_call(k, v, cand)
}

// Every call spelling passes a `self: ^` receiver by address, including
// `Type.method(CONSTANT)` and calls resolved through a procedure group.
@(private = "file")
materialize_call_receiver :: proc(k: ^Checker, v: ^Expr_Call) {
	if v.type == INVALID_TYPE || base_is_const(v) || len(v.bound) == 0 || v.bound[0] == nil {
		return
	}
	if type_is_compile_time_only(k.c, expr_base(v.bound[0]).type) {
		return
	}
	chosen := symbol_of(k.c, v.resolution.chosen_overload)
	if chosen != nil && chosen.has_receiver && chosen.receiver == .Borrow && is_const_expr(v.bound[0]) {
		request_materialization(k, v.bound[0])
	}
}

// Rewrites the callee to name the selected overload, so later phases see an
// ordinary call.
@(private = "file")
annotate_chosen_callee :: proc(k: ^Checker, v: ^Expr_Call, chosen: Symbol_Id) {
	sym := symbol_of(k.c, chosen)
	if base := expr_base(v.callee); base != nil && sym != nil {
		base.resolution = Resolution{kind = .Value, symbol = chosen}
		base.value_category = .Value
		base.type = sym.proc_type
	}
	if ident, is_ident := v.callee.(^Expr_Ident); is_ident {
		ident.symbol = chosen
	}
	record_called_procedure(k, v, chosen)
}

// A place copied into a trivial aggregate `value: T` parameter is a copy site; a
// managed one is borrowed for the call (design.md). Operations that read no
// arguments, or report their own copies, are skipped.
@(private = "file")
report_argument_copies :: proc(k: ^Checker, v: ^Expr_Call) {
	#partial switch operation in v.operation {
	case Call_Enum_From_Int, Call_Box_Unbox, Call_Union_As, Call_Union_Construct:
		return
	case Call_Reflect:
		if operation.op == .Field_Get { return }
	}
	sym := symbol_of(k.c, v.resolution.symbol)
	if sym != nil && sym.kind == .Builtin {
		#partial switch sym.builtin {
		case .Size_Of, .Align_Of, .Offset_Of, .Is_Copyable, .Is_Union, .Type_Of, .Source_Location, .Exchange, .Unsafe_Take, .Unsafe_Write, .Drop:
			return
		}
	}
	info := underlying_info(k.c, call_proc_type(k.c, v))
	if info == nil {
		return
	}
	// A container insertion reports its element as the insertion it is.
	inserted := sym != nil ? container_inserted_slot(sym.container_op) : -1
	for argument, index in v.bound {
		if argument == nil || index >= len(info.parameters) || index == inserted {
			continue
		}
		mode := index < len(info.param_modes) ? info.param_modes[index] : Param_Mode.Value
		type := info.parameters[index]
		if mode != .Value || type_is_managed(k.c, type) || !type_is_aggregate(k.c, type) {
			continue
		}
		if expression_is_borrowed_place(argument) {
			record_copy(k, .Argument, expr_span(argument), argument, type)
		}
	}
}

// design.md "@(packed)": `inout` passes the address, which may be misaligned, and
// the place must be one the callee may write. `span` is where a packed field is
// reported.
@(private = "file")
check_inout_place :: proc(k: ^Checker, value: Expr, span: Span, subject: string) -> bool {
	if field, packed := packed_field_reached(k, value); packed {
		errorf(k.c, span, "L0614", "cannot take the address of `%s`: it is reached through a packed struct", field)
		return false
	}
	base := expr_base(value)
	if base != nil && !base.assignable {
		report_not_assignable(k, base, subject)
		return false
	}
	return true
}

check_bound_argument_mode :: proc(k: ^Checker, value: Expr, target: Type_Id, mode: Param_Mode, subject: string) -> bool {
	if mode == .Borrow {
		if field, packed := packed_field_reached(k, value); packed {
			errorf(k.c, expr_span(value), "L0614", "cannot borrow `%s`: it is reached through a packed struct", field)
			return false
		}
		request_materialization(k, value)
		return true
	}
	if mode != .Inout {
		return true
	}
	if !check_inout_place(k, value, expr_span(value), subject) {
		return false
	}
	base := expr_base(value)
	// design.md "Parameter semantics and ABI lowering": the callee writes the
	// caller's variable itself, so no conversion may stand between them.
	if base != nil && (base.type != target || expression_converts_storage(value)) {
		found := base.type
		if from := conversion_source(base); from != INVALID_TYPE {
			found = from
		}
		errorf(
			k.c, expr_span(value), "L0310", "%s must be a `%s`, found `%s`",
			subject, type_name(k.c, target), type_name(k.c, found),
		)
		return false
	}
	return true
}

bind_written_argument :: proc(
	k: ^Checker, arg: Argument, target: Type_Id, expected: Param_Mode, prechecked := false,
) -> (Expr, bool) {
	if (expected == .Inout) != (arg.mode == .Inout) {
		if expected == .Inout {
			errorf(k.c, arg.span, "L0370", "this parameter is `inout`; write `inout` at the call site")
		} else {
			errorf(k.c, arg.span, "L0370", "this parameter is not `inout`")
		}
		return arg.value, false
	}
	if !prechecked && check_single_expr(k, arg.value, target, arg.mode == .Inout ? .Place : .Value) == INVALID_TYPE {
		return arg.value, false
	}
	return bind_checked_argument(k, arg.value, target, expected)
}

// A checked argument taken into its parameter. design.md "Receiver forms":
// `Type.method(&value)` names the receiver `self: ^T` receives; a method call's
// own receiver is a place already, so its caller says so.
bind_checked_argument :: proc(
	k: ^Checker, argument: Expr, target: Type_Id, mode: Param_Mode, is_receiver := false,
) -> (Expr, bool) {
	value := argument
	if mode == .Borrow && !is_receiver && pointer_to_element(k.c, expr_base(value).type) == target {
		value = implicit_pointer_deref(k, value, target, type_of(k.c, expr_base(value).type).mutable)
	}
	if !materialize_argument(k, value, target) {
		return value, false
	}
	return value, check_bound_argument_mode(k, value, target, mode, "an `inout` argument")
}

check_argument_value :: proc(k: ^Checker, e: Expr, target: Type_Id) -> (Expr, bool) {
	type := check_single_expr(k, e, target)
	if type == INVALID_TYPE || target == INVALID_TYPE {
		return e, false
	}
	return e, materialize_argument(k, e, target)
}

// Overload resolution already checked every written argument, so binding the
// chosen candidate must not check them again.
pass_argument :: proc(k: ^Checker, e: Expr, target: Type_Id, prechecked: bool) -> (Expr, bool) {
	if !prechecked {
		return check_argument_value(k, e, target)
	}
	return e, materialize_argument(k, e, target)
}

// design.md "Named arguments": the slot a name reaches, shared by overload
// resolution and binding so they cannot disagree. `limit` stops short of a
// variadic pack. -1 when nothing carries the name.
parameter_slot_named :: proc(c: ^Compiler, declared: ^Symbol, name: Identifier_Id, limit := -1) -> int {
	stop := limit < 0 ? len(declared.param_symbols) : min(limit, len(declared.param_symbols))
	for binding, position in declared.param_symbols[:stop] {
		if symbol := symbol_of(c, binding); symbol != nil && symbol.name == name {
			return position
		}
	}
	return -1
}

// Whether a written name reached a slot the call has not filled yet; reports why
// not. `bound` holds the arguments placed so far.
named_slot_is_open :: proc(k: ^Checker, arg: Argument, slot: int, bound: []Expr) -> bool {
	if slot < 0 {
		errorf(k.c, arg.span, "L0371", "no parameter named `%s`", arg.name.text)
		return false
	}
	if bound[slot] != nil {
		errorf(k.c, arg.span, "L0371", "`%s` is given twice", arg.name.text)
		return false
	}
	return true
}

// The slot of a named argument on a call without candidates, or -1 once reported.
@(private = "file")
named_argument_slot :: proc(k: ^Checker, arg: Argument, declared: ^Symbol, bound: []Expr, limit := -1) -> int {
	if declared == nil {
		errorf(k.c, arg.span, "L0371", "a call through a procedure value cannot use named arguments")
		return -1
	}
	slot := parameter_slot_named(k.c, declared, name_identifier(k.c, arg.name), limit)
	return named_slot_is_open(k, arg, slot, bound) ? slot : -1
}

@(private = "file")
report_argument_count :: proc(k: ^Checker, span: Span, expected, found: int, at_least := false) {
	errorf(
		k.c, span, "L0322", "this procedure takes %s%d argument%s, found %d",
		at_least ? "at least " : "", expected, expected == 1 ? "" : "s", found,
	)
}

// The binder for a call with no candidates: a single named procedure or a
// procedure value.
@(private = "file")
bind_arguments :: proc(k: ^Checker, v: ^Expr_Call, info: ^Type_Info, declaration: Symbol_Id) -> bool {
	count := len(info.parameters)
	if info.c_vararg {
		return bind_c_vararg_arguments(k, v, info)
	}
	if variadic_parameter_index(info) >= 0 {
		bound_ok := bind_variadic_arguments(k, v, info, declaration, v.args)
		if bound_ok {
			require_argument_ownership(k, v, declaration, info)
		}
		return bound_ok
	}
	bound := make([]Expr, count, k.c.semantic_allocator)
	declared := symbol_of(k.c, declaration)
	ok := true
	named := false
	// design.md "Evaluation order": arguments run in written order, then defaults.
	order := make([dynamic]int, 0, count, k.c.semantic_allocator)

	for arg, index in v.args {
		if arg.mode == .Spread {
			errorf(k.c, arg.span, "L0371", "`..` needs a variadic parameter to spread into")
			ok = false
			continue
		}
		slot := index
		if arg.name.text != "" {
			named = true
			slot = named_argument_slot(k, arg, declared, bound)
			if slot < 0 {
				ok = false
				continue
			}
		} else if named {
			errorf(k.c, arg.span, "L0372", "a positional argument cannot follow a named one")
			ok = false
			continue
		} else if slot >= count {
			report_argument_count(k, v.span, count, len(v.args))
			return false
		}

		append(&order, slot)
		expected_mode := slot < len(info.param_modes) ? info.param_modes[slot] : Param_Mode.Value
		value, passed := bind_written_argument(k, arg, info.parameters[slot], expected_mode)
		bound[slot] = value
		ok = ok && passed
	}

	for index in 0 ..< count {
		if bound[index] != nil {
			continue
		}
		// A failed argument's slot is not a second mistake.
		if !ok {
			return false
		}
		if declared == nil || index >= len(declared.param_defaults) || declared.param_defaults[index] == nil {
			if declared != nil && index < len(declared.param_symbols) {
				if parameter := symbol_of(k.c, declared.param_symbols[index]); parameter != nil {
					errorf(
						k.c, v.span, "L0322", "missing an argument for `%s`",
						identifier_text(k.c, parameter.name),
					)
					return false
				}
			}
			report_argument_count(k, v.span, count, len(v.args))
			return false
		}
		bound[index] = substitute_caller_location(k, declared.param_defaults[index], v.span)
		append(&order, index)
	}

	v.bound = bound
	if named {
		v.bound_order = order[:]
	}
	if ok {
		require_argument_ownership(k, v, declaration, info)
	}
	return ok
}

// design.md "`@(c_vararg)`": the fixed parameters bind normally, and each later
// argument is a concrete, foreign-ABI-safe value passed by value.
bind_c_vararg_arguments :: proc(k: ^Checker, v: ^Expr_Call, info: ^Type_Info, prechecked := false) -> bool {
	fixed := len(info.parameters)
	if len(v.args) < fixed {
		report_argument_count(k, v.span, fixed, len(v.args), at_least = true)
		return false
	}
	bound := make([]Expr, len(v.args), k.c.semantic_allocator)
	ok := true
	for arg, index in v.args {
		if arg.mode == .Spread {
			errorf(k.c, arg.span, "L0628", "a C-variadic call cannot spread; pass each concrete argument")
			ok = false
			continue
		}
		if arg.name.text != "" {
			errorf(k.c, arg.span, "L0371", "a C-variadic call takes positional arguments only")
			ok = false
			continue
		}
		if index < fixed {
			mode := index < len(info.param_modes) ? info.param_modes[index] : Param_Mode.Value
			value, passed := bind_written_argument(k, arg, info.parameters[index], mode, prechecked)
			bound[index] = value
			ok = ok && passed
			continue
		}
		bound[index] = arg.value
		if arg.mode == .Inout {
			errorf(k.c, arg.span, "L0370", "a C-variadic argument is passed by value, so it cannot be `inout`")
			ok = false
			continue
		}
		type := prechecked ? expr_base(arg.value).type : check_single_expr(k, arg.value)
		if type == INVALID_TYPE {
			ok = false
			continue
		}
		// An untyped constant crosses at its default type.
		if type_is_untyped(k.c, type) {
			typed := default_type(k.c, type)
			if typed == INVALID_TYPE {
				errorf(k.c, arg.span, "L0619", "a C-variadic argument needs a concrete type, found `%s`", type_name(k.c, type))
				ok = false
				continue
			}
			if !materialize(k, arg.value, typed) {
				ok = false
				continue
			}
			type = typed
		}
		if safe, reason := foreign_abi_safe(k.c, type); !safe {
			errorf(k.c, arg.span, "L0619", "a C-variadic argument is not ABI-safe: %s", reason)
			ok = false
		}
	}
	v.bound = bound
	return ok
}

// Binds the chosen candidate in parameter order and materializes constants.
bind_chosen_call :: proc(k: ^Checker, v: ^Expr_Call, cand: Candidate) -> bool {
	sym := symbol_of(k.c, cand.symbol)
	if sym == nil {
		return false
	}
	if !type_waiting_arguments(k, v, sym, cand) {
		return false
	}
	info := type_of(k.c, sym.proc_type)
	if info != nil && info.c_vararg {
		return bind_c_vararg_arguments(k, v, info, prechecked = true)
	}
	if variadic_parameter_index(info) >= 0 {
		receiver: Expr
		written := cand.args
		if len(written) > 0 && written[0].is_receiver {
			receiver = written[0].expr
			written = written[1:]
		}
		bound_ok := bind_variadic_arguments(
			k, v, info, cand.symbol, written_arguments(k.c, written),
			prechecked = true, receiver = receiver,
		)
		if bound_ok {
			require_argument_ownership(k, v, cand.symbol)
		}
		return bound_ok
	}
	bound, ok := bind_candidate_slots(k, cand, sym, v.span)
	// design.md "Evaluation order": written arguments first, then defaults.
	order := make([dynamic]int, 0, len(bound), k.c.semantic_allocator)
	append(&order, ..cand.slots)
	for slot in 0 ..< len(bound) {
		if !cand.filled[slot] {
			append(&order, slot)
		}
	}
	v.bound = bound
	if !slice.is_sorted(order[:]) {
		v.bound_order = order[:]
	}
	if ok {
		require_argument_ownership(k, v, cand.symbol)
	}
	return ok
}

// The chosen candidate's arguments in parameter order, defaults filled in.
bind_candidate_slots :: proc(k: ^Checker, cand: Candidate, sym: ^Symbol, span: Span) -> ([]Expr, bool) {
	bound := make([]Expr, len(sym.params), k.c.semantic_allocator)
	ok := true
	for arg, index in cand.args {
		slot := cand.slots[index]
		mode := proc_parameter_mode(k.c, sym.proc_type, slot)
		value, passed := bind_checked_argument(k, arg.expr, sym.params[slot], mode, arg.is_receiver)
		bound[slot] = value
		ok = ok && passed
	}
	for slot in 0 ..< len(bound) {
		if !cand.filled[slot] {
			bound[slot] = substitute_caller_location(k, sym.param_defaults[slot], span)
		}
	}
	return bound, ok
}

// design.md "Arguments typed after inference": each waiting argument is checked
// against the chosen candidate's parameter, its `$` names now substituted (the
// element type, for a variadic pack).
@(private = "file")
type_waiting_arguments :: proc(k: ^Checker, v: ^Expr_Call, sym: ^Symbol, cand: Candidate) -> bool {
	info := type_of(k.c, sym.proc_type)
	pack := variadic_parameter_index(info)
	ok := true
	for arg, index in cand.args {
		if !arg.waiting {
			continue
		}
		slot := cand.slots[index]
		target := sym.params[slot]
		if slot == pack {
			target = slice_element(k.c, target)
		}
		if check_single_expr(k, arg.expr, target) != INVALID_TYPE {
			continue
		}
		ok = false
		// A group chose this member without it, which the error alone hides.
		if len(v.overload_members) > 1 {
			add_notef(
				k.c, sym.span,
				"the other arguments chose `%s`; an argument that takes its parameter's type does not take part in choosing",
				identifier_text(k.c, sym.name),
			)
		}
	}
	return ok
}

@(private = "file")
written_arguments :: proc(c: ^Compiler, args: []Arg_Info) -> []Argument {
	out := make([]Argument, len(args), c.semantic_allocator)
	for arg, index in args {
		name := Name{}
		if arg.name != INVALID_IDENTIFIER {
			name = Name{text = identifier_text(c, arg.name), span = arg.span, id = arg.name}
		}
		out[index] = Argument{span = arg.span, name = name, mode = arg.mode, value = arg.expr}
	}
	return out
}

materialize_argument :: proc(k: ^Checker, e: Expr, target: Type_Id) -> bool {
	return materialize_value_expr(k, e, target, "pass")
}

// `T(value)` is conversion only. Built-in source/target pairs are reserved;
// every other pair may be supplied by an inherent `hook(convert)` on T.
@(private = "file")
check_conversion :: proc(k: ^Checker, v: ^Expr_Call, target: Type_Id) {
	if !gate_type(k, target, v.span) {
		return
	}
	if !has_one_plain_argument(v) {
		errorf(k.c, v.span, "L0410", "a conversion to `%s` takes exactly one plain value argument", type_name(k.c, target))
		return
	}
	// Checked without the target as context: the conversion node owns it.
	saved_raw_place := k.raw_address_place
	if address, is_unary := v.args[0].value.(^Expr_Unary); is_unary && address.op == .Amp &&
	   type_underlying(k.c, target) == TYPE_RAWPTR && address.operand != nil {
		k.raw_address_place = address.operand
	}
	source := check_single_expr(k, v.args[0].value)
	k.raw_address_place = saved_raw_place
	if source == INVALID_TYPE {
		return
	}
	if type_is_enum(k.c, target) && (type_is_numeric(k.c, source) || type_is_enum(k.c, source)) &&
	   type_underlying(k.c, source) != type_underlying(k.c, target) {
		errorf(k.c, v.span, "L0410", "an enum is closed; use `%s.from_int(value)` to validate a backing integer", type_name(k.c, target))
		return
	}
	// Invalid UTF-8 is reported as such, not as a missing conversion.
	if operand := expr_base(v.args[0].value); base_is_const(operand) &&
	   constant_is_invalid_text(k.c, operand.const_value, target) {
		report_invalid_utf8(k, operand.span, target)
		return
	}
	if builtin_conversion(k, v, target, source) {
		return
	}
	check_conversion_hook_call(k, v, target)
}

// The built-in half of `T(v)`, including pointer and `distinct` conversions.
// Returns false, silently, when only a conversion hook could apply.
@(private = "file")
builtin_conversion :: proc(k: ^Checker, v: ^Expr_Call, target, source: Type_Id) -> bool {
	base := expr_base(v.args[0].value)
	// Two distinct types meet only through a hook, even for a constant operand.
	if type_kind(k.c, source) == .Distinct && type_kind(k.c, target) == .Distinct && source != target {
		return false
	}
	// A typed constant meets the same rules as a runtime value; only an untyped
	// one converts by what its value fits.
	typed := !base_is_const(base) || !type_is_untyped(k.c, source)
	if typed && !convertible(k.c, source, target) {
		return false
	}
	if typed && unchecked_pointer_conversion(k.c, source, target) &&
	   !require_unsafe_import(k, v.span, concat(k.c, "converting to `", type_name(k.c, target), "`")) {
		return true
	}
	// A named constant array is viewed in its read-only storage, not folded.
	folds := base_is_const(base) && !array_views_as(k.c, source, target)
	converted: Const_Value
	if folds {
		fits: bool
		converted, fits = convert_const(k.c, base.const_value, target, true)
		fits &&= nil_converts(k.c, source, target)
		if !fits && report_constant_out_of_range(k.c, v.span, base.const_value, target) {
			return true
		}
		if !fits {
			return false
		}
	}
	operand := v.args[0].value
	clones := false
	if !folds && (type_views_as(k.c, source, target) || (type_is_simd(k.c, target) && !type_is_simd(k.c, source))) {
		// design.md "Implicit type conversions": a view or a splat is the implicit
		// conversion written out, so the operand takes the target's representation
		// as it would at a typed destination, and a place is borrowed, not cloned.
		if !materialize(k, operand, target) {
			return true
		}
	} else {
		// design.md "Distinct types": converting a managed value between a distinct
		// name and its underlying type reinterprets it, so a place must be cloned or
		// both it and the result would own one allocation.
		clones = classify_copy(k, operand, source, .Conversion)
		if clones {
			record_copy(k, .Conversion, expr_span(operand), operand, source)
		}
	}
	v.operation = Call_Conversion{clones = clones}
	v.resolution = {}
	record_proc_contract_check(k.c, source, target, v.span)
	v.bound = make([]Expr, 1, k.c.semantic_allocator)
	v.bound[0] = operand
	v.type = target
	if folds {
		v.const_value = converted
	}
	return true
}

// Every inherent conversion hook, matched by role rather than name. Crossed
// generic blocks' hooks of one name stand in the table as a group.
@(private = "file")
conversion_hooks :: proc(k: ^Checker, target: Type_Id) -> []Symbol_Id {
	info := type_of(k.c, target)
	if info == nil {
		return nil
	}
	out := make([dynamic]Symbol_Id, 0, 4, k.c.semantic_allocator)
	for member in info.members {
		sym := symbol_of(k.c, member)
		if sym != nil && sym.kind == .Proc_Group {
			for nested in sym.members {
				append_conversion_hook(k, nested, target, &out)
			}
		} else {
			append_conversion_hook(k, member, target, &out)
		}
	}
	return out[:]
}

@(private = "file")
append_conversion_hook :: proc(k: ^Checker, member: Symbol_Id, target: Type_Id, out: ^[dynamic]Symbol_Id) {
	sym := symbol_of(k.c, member)
	if sym != nil && sym.hook == .Convert && !sym.bound_excluded {
		resolve_symbol_signature_in_place(k, member, target)
		append(out, member)
	}
}

// Conversion hooks are inherent to the target, so imports cannot change `T(value)`.
@(private = "file")
check_conversion_hook_call :: proc(k: ^Checker, v: ^Expr_Call, target: Type_Id) {
	usable := conversion_hooks(k, target)
	if len(usable) == 0 {
		attempted := expr_base(v.args[0].value).type
		errorf(k.c, expr_span(v.args[0].value), "L0373", "`%s` cannot be converted to `%s`", type_name(k.c, attempted), type_name(k.c, target))
		note_mutable_slicing(k, v.args[0].value, attempted, type_underlying(k.c, target))
		if (target == TYPE_STRING || target == TYPE_STRING_VIEW) &&
		   (slice_element(k.c, attempted) == TYPE_U8 || (target == TYPE_STRING && underlying_kind(k.c, attempted) == .CString_View)) {
			add_notef(k.c, v.span, "use `%s.from_utf8(bytes)`, which returns `Option(%s)`", type_name(k.c, target), type_name(k.c, target))
		}
		return
	}
	description := concat(k.c, "conversion to `", type_name(k.c, target), "`")
	args := []Arg_Info{arg_from_expr(v.args[0].value)}
	cand, resolved := resolve_overload(k, v.span, description, usable, args)
	if !resolved {
		return
	}
	annotate_chosen_callee(k, v, cand.symbol)
	if !bind_chosen_call(k, v, cand) {
		return
	}
	v.type = target
}

// Whether every candidate consumes its receiver, so only `move(...)` reaches one.
@(private = "file")
all_candidates_consume :: proc(k: ^Checker, candidates: []Symbol_Id) -> bool {
	for candidate in candidates {
		if sym := symbol_of(k.c, candidate); sym == nil || sym.receiver != .Move {
			return false
		}
	}
	return len(candidates) > 0
}

// ------------------------------------------------------------- variadics --

// The index of a procedure type's variadic parameter, always the last, or -1.
variadic_parameter_index :: proc(info: ^Type_Info) -> int {
	if info == nil || len(info.param_modes) == 0 {
		return -1
	}
	last := len(info.param_modes) - 1
	return info.param_modes[last] == .Variadic ? last : -1
}

// design.md "Variadic parameters": explicit arguments, `..slice` spreads, or
// both, packed here into the one read-only slice the callee receives. A sole
// spread forwards its slice unchanged. `receiver` is a method call's parameter
// 0 (nil for a free call), so a variadic method such as the contributed
// `append` never ranks its first written argument against its own receiver.
bind_variadic_arguments :: proc(
	k: ^Checker,
	v: ^Expr_Call,
	info: ^Type_Info,
	declaration: Symbol_Id,
	args: []Argument,
	prechecked := false,
	receiver: Expr = nil,
) -> bool {
	pack := variadic_parameter_index(info)
	element := slice_element(k.c, info.parameters[pack])
	bound := make([]Expr, pack + 1, k.c.semantic_allocator)
	declared := symbol_of(k.c, declaration)
	ok := true

	// design.md "Evaluation order": kept only when written and slot order
	// disagree, because a name reorders the fixed parameters or an omitted
	// default must wait for the pack.
	slot_order := make([dynamic]int, 0, pack + 1, k.c.semantic_allocator)
	defaulted := false
	first := 0
	if receiver != nil {
		bound[0] = receiver
		append(&slot_order, 0)
		if !check_bound_argument_mode(k, receiver, info.parameters[0], info.param_modes[0], "an `inout` argument") {
			ok = false
		}
		first = 1
	}
	fixed := 0
	for first + fixed < pack && fixed < len(args) {
		arg := args[fixed]
		if arg.name.text != "" || arg.mode == .Spread {
			break
		}
		slot := first + fixed
		value, passed := bind_written_argument(k, arg, info.parameters[slot], info.param_modes[slot], prechecked)
		bound[slot] = value
		append(&slot_order, slot)
		ok = ok && passed
		fixed += 1
	}
	// design.md "Named arguments": positional arguments precede named ones and no
	// name reaches a pack element, so once a name appears the pack is empty.
	named := 0
	for fixed + named < len(args) && args[fixed + named].name.text != "" {
		arg := args[fixed + named]
		named += 1
		slot := named_argument_slot(k, arg, declared, bound, pack)
		if slot < 0 {
			ok = false
			continue
		}
		value, passed := bind_written_argument(k, arg, info.parameters[slot], info.param_modes[slot], prechecked)
		bound[slot] = value
		append(&slot_order, slot)
		ok = ok && passed
	}
	if named > 0 && fixed + named < len(args) {
		errorf(k.c, args[fixed + named].span, "L0372", "a positional argument cannot follow a named one")
		return false
	}
	append(&slot_order, pack)
	for index in first ..< pack {
		if bound[index] != nil {
			continue
		}
		if !ok {
			// The failed argument already explains the empty slot.
			return false
		}
		if declared == nil || index >= len(declared.param_defaults) || declared.param_defaults[index] == nil {
			report_argument_count(k, v.span, pack - first, len(args), at_least = true)
			return false
		}
		bound[index] = substitute_caller_location(k, declared.param_defaults[index], v.span)
		append(&slot_order, index)
		defaulted = true
	}
	if named > 0 || defaulted {
		v.bound_order = slot_order[:]
	}

	rest := args[fixed + named:]
	if len(rest) == 1 && rest[0].mode == .Spread {
		spread, passed := check_spread_argument(k, rest[0], info.parameters[pack], prechecked)
		bound[pack] = spread
		v.bound = bound
		v.is_variadic = true
		v.variadic_slot = pack
		v.variadic_forwards = true
		return ok && passed
	}

	elements := make([dynamic]Expr, 0, len(rest), k.c.semantic_allocator)
	spreads := make([dynamic]Expr, 0, len(rest), k.c.semantic_allocator)
	order := make([dynamic]bool, 0, len(rest), k.c.semantic_allocator) // true = spread
	needs_element_clone := false
	for arg in rest {
		if arg.name.text != "" {
			errorf(k.c, arg.span, "L0371", "a variadic argument cannot be named")
			ok = false
			continue
		}
		if arg.mode == .Spread {
			spread, passed := check_spread_argument(k, arg, info.parameters[pack], prechecked)
			append(&spreads, spread)
			append(&order, true)
			needs_element_clone = true
			ok = ok && passed
			continue
		}
		if arg.mode == .Inout {
			errorf(k.c, arg.span, "L0370", "a variadic argument is passed by value, so it cannot be `inout`")
			ok = false
			continue
		}
		value, passed := pass_variadic_element(k, arg.value, element, prechecked)
		append(&elements, value)
		append(&order, false)
		// Managed or not: a pack copies what it is given.
		classify_copy_cost(k, value, element, .Variadic)
		if expression_is_borrowed_place(value) && copied_type(value, element) != element {
			// design.md "Widening by label": the pack copies a widened place at its
			// own type, which may be copyable where the element is not; a lending
			// `append` body still copies at the element type.
			classify_copy(k, value, element, .Variadic)
			needs_element_clone ||= !type_clone_disabled(k.c, element)
		} else {
			needs_element_clone ||= expression_is_borrowed_place(value)
		}
		ok = ok && passed
	}
	if type_is_managed(k.c, element) && needs_element_clone && !lifecycle_of(k.c, element).intrinsic {
		if type_clone_disabled(k.c, element) {
			// design.md "Container insertion": each borrowed element is reported
			// where `move(...)` belongs; a spread has no `move` form.
			for value in elements {
				classify_copy(k, value, element, .Variadic)
			}
			for spread in spreads {
				report_move_only_spread(k, spread, element)
			}
			ok = false
		} else {
			contribute_lifecycle_members(k, element)
			for spread in spreads {
				expr_base(spread).copied_as = element
			}
		}
	}
	v.is_variadic = true
	v.variadic_slot = pack
	v.variadic_elements = elements[:]
	v.variadic_spreads = spreads[:]
	v.variadic_order = order[:]
	v.bound = bound
	return ok
}

// Whether bound argument `index` of a call is a variadic pack built from
// separate arguments, which has no `bound` expression, rather than one
// forwarded slice.
call_packs :: proc(call: ^Expr_Call, index: int) -> bool {
	return call.is_variadic && !call.variadic_forwards && index == call.variadic_slot
}

// A `..` spread of a move-only element, whose pack would have to copy it.
report_move_only_spread :: proc(k: ^Checker, spread: Expr, element: Type_Id) {
	errorf(
		k.c, expr_span(spread), "L0503",
		"`%s` is move-only, so a `..` spread cannot copy its elements into the pack",
		type_name(k.c, element),
	)
}

@(private = "file")
check_spread_argument :: proc(k: ^Checker, arg: Argument, pack: Type_Id, prechecked: bool) -> (Expr, bool) {
	type: Type_Id
	switch {
	case prechecked:
		type = expr_base(arg.value).type
	case arg.checked:
		type = settle_single_value(k, arg.value, expr_base(arg.value).type, pack)
	case:
		type = check_single_expr(k, arg.value, pack)
	}
	if type == INVALID_TYPE {
		return arg.value, false
	}
	if !assignable(k.c, type, pack) {
		errorf(
			k.c, arg.span, "L0574",
			"`..` spreads a `%s`, found `%s`", type_name(k.c, pack), type_name(k.c, type),
		)
		return arg.value, false
	}
	// A `[dynamic]T` or `[N]T` is spread as the `[]T` it views, so a lone
	// spread forwards a slice and several spreads read a slice's data and length.
	return arg.value, materialize(k, arg.value, pack)
}


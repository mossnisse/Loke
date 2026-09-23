// Call checking, overload selection, argument binding, and explicit conversions.
// check_expr.odin dispatches expressions here; overload.odin owns candidate
// ranking, and feature checkers retain their specialized call contracts.
package lokec

// ------------------------------------------------------- calls and casts --

// design.md "Evaluation order": the parameter slot a call evaluates at `step`.
call_slot_at :: proc(v: ^Expr_Call, step: int) -> int {
	return step < len(v.bound_order) ? v.bound_order[step] : step
}

@(private)
check_call :: proc(k: ^Checker, v: ^Expr_Call, expected: Type_Id) {
	defer materialize_call_receiver(k, v)
	v.value_category = .Value

	// A built-in, spelled plainly or as `pkg.builtin`, is not a value.
	if ident, is_ident := v.callee.(^Expr_Ident); is_ident {
		symbol_id := lookup_symbol(k.scope, identifier_of(k.c, ident))
		if sym := symbol_of(k.c, symbol_id); sym != nil && sym.kind == .Builtin {
			check_builtin_call(k, v, ident, symbol_id, expected)
			return
		}
	}
	if symbol_id := callee_package_builtin(k, v.callee); symbol_id != INVALID_SYMBOL {
		check_builtin_call(k, v, qualify_builtin_callee(k, v), symbol_id, expected)
		return
	}

	// Nor is a group or a generic procedure: overloads rank before any single
	// procedure type exists.
	if group := callee_group(k, v.callee); group != INVALID_SYMBOL {
		check_group_call(k, v, group)
		return
	}
	if group := associated_group(k, v.callee); group != INVALID_SYMBOL {
		check_group_call(k, v, group)
		return
	}
	if template := callee_generic_procedure(k, v.callee); template != INVALID_SYMBOL {
		check_group_call(k, v, template)
		return
	}
	callee_symbol := named_callee_symbol(k, v.callee)
	// An interface application is a compile-time boolean, not a conversion.
	if info := interface_info_for(k, callee_symbol); info != nil {
		v.operation = Call_Compile_Time{}
		check_interface_application(k, v, info)
		return
	}
	// design.md "Shared ownership": `shared(Node)` is the type, and anything that
	// is not a type goes to the constructor group.
	if k.c.shared_symbol != INVALID_SYMBOL && callee_symbol == k.c.shared_symbol && !callee_argument_denotes_type(k, v) {
		check_group_call(k, v, k.c.shared_construct_symbol)
		return
	}
	// `Simd(f32, 4)`, `Range(int)`, and generic record applications denote types.
	if range_callee(k, v.callee) {
		set_type_call(v, resolve_range_application(k, v))
		return
	}
	if simd_callee(k, v.callee) {
		set_type_call(v, resolve_simd_application(k, v))
		return
	}
	if generic_template_of_callee(k, v.callee, .Record) != nil {
		set_type_call(v, resolve_type_syntax(k, v))
		return
	}
	if sel, is_selector := v.callee.(^Expr_Selector); is_selector && sel.operand != nil {
		// A `dyn` slot call dispatches through the witness.
		if operand := dyn_operand_type(k, sel.operand); operand != INVALID_TYPE {
			if check_dyn_slot_call(k, v, sel, operand) {
				note_nil_use(k, sel.operand, "dispatch")
				return
			}
			errorf(k.c, v.span, "L0467", "`%s` has no slot `%s`", type_name(k.c, operand), sel.name.text)
			v.type = INVALID_TYPE
			return
		}
		// Compiler-defined operations on unions, text, and enums.
		if check_any_view_as(k, v, sel) ||
		   check_text_operation(k, v, sel) ||
		   check_enum_values(k, v, sel) ||
		   check_enum_from_int(k, v, sel) {
			return
		}
		// `field.get(value)` / `field.pointer(value)` on a descriptor constant. The
		// operand is a plain name, so checking it again below is harmless.
		if callee_is_descriptor(k, sel.operand) {
			check_single_expr(k, sel.operand)
			if check_descriptor_operation(k, v, sel) {
				return
			}
		}
	}

	outer_callee := k.in_callee
	k.in_callee = true
	// A bare `.name(payload)` takes its union from the expected type.
	callee_expected := INVALID_TYPE
	if sel, is_selector := v.callee.(^Expr_Selector); is_selector && sel.operand == nil {
		callee_expected = expected
	}
	callee_type := check_expr(k, v.callee, callee_expected)
	k.in_callee = outer_callee
	callee_base := expr_base(v.callee)
	if callee_base == nil {
		v.type = INVALID_TYPE
		return
	}
	// The receiver becomes argument zero.
	if callee_base.resolution.kind == .Method {
		check_method_call(k, v, v.callee.(^Expr_Selector))
		return
	}
	if callee_base.resolution.kind == .Union_Variant {
		check_union_construct(k, v, v.callee.(^Expr_Selector))
		return
	}
	if callee_type == INVALID_TYPE {
		v.type = INVALID_TYPE
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
		sel, is_sel := v.callee.(^Expr_Selector)
		if is_sel && sel.variant_union != INVALID_TYPE &&
		   union_variant_payload(k.c, sel.variant_union, sel.variant_index) == TYPE_VOID {
			errorf(
				k.c, v.span, "L0425",
				"`%s.%s` carries no payload: write `%s` without a call",
				type_name(k.c, sel.variant_union), sel.name.text, sel.name.text,
			)
			v.type = INVALID_TYPE
			return
		}
		errorf(k.c, expr_span(v.callee), "L0320", "`%s` is not callable", type_name(k.c, callee_type))
		v.type = INVALID_TYPE
		return
	}
	// Only a procedure value can be nil.
	note_nil_use(k, v.callee, "call")

	// Only a directly named procedure (`f` or `pkg.f`) has defaults and named
	// parameters.
	declaration := INVALID_SYMBOL
	if named := callee_base.resolution.symbol; callee_base.resolution.kind == .Value {
		if sym := symbol_of(k.c, named); sym != nil && sym.kind == .Proc {
			declaration = named
		}
	}
	if reject_direct_hook_call(k, v.span, declaration) {
		v.type = INVALID_TYPE
		return
	}
	v.resolution = Resolution{kind = .Call, symbol = declaration, chosen_overload = declaration}
	v.operation = Call_Procedure{}

	if !bind_arguments(k, v, info, declaration) {
		v.type = INVALID_TYPE
		return
	}

	set_call_result(
		v, info.result, info.result_inout,
		result_written_but_unresolved(symbol_of(k.c, declaration)),
	)
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
	return literal != nil && literal.signature != nil && literal.signature.result != nil
}

// A call that denotes a type, such as `Simd(f32, 4)`.
@(private = "file")
set_type_call :: proc(v: ^Expr_Call, denoted: Type_Id) {
	if denoted == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}
	v.operation = Call_Compile_Time{}
	v.type = TYPE_TYPE
	v.value_category = .Type
	v.is_const = true
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
	if selected := symbol_of(k.c, call.resolution.chosen_overload); selected != nil && selected.require_results {
		return identifier_text(k.c, selected.name), true
	}
	if group := symbol_of(k.c, callee_group(k, call.callee)); group != nil && group.require_results {
		return identifier_text(k.c, group.name), true
	}
	return "", type_requires_results(k.c, call.type)
}

// The procedure group a callee (`group` or `pkg.group`) names, or INVALID_SYMBOL.
@(private = "file")
callee_group :: proc(k: ^Checker, callee: Expr) -> Symbol_Id {
	id := named_callee_symbol(k, callee)
	sym := symbol_of(k.c, id)
	return sym != nil && sym.kind == .Proc_Group ? id : INVALID_SYMBOL
}

// A `pkg.name` callee naming a public built-in of `pkg`, or INVALID_SYMBOL.
@(private = "file")
callee_package_builtin :: proc(k: ^Checker, callee: Expr) -> Symbol_Id {
	if _, is_selector := callee.(^Expr_Selector); !is_selector {
		return INVALID_SYMBOL
	}
	id := named_callee_symbol(k, callee)
	sym := symbol_of(k.c, id)
	return sym != nil && sym.kind == .Builtin ? id : INVALID_SYMBOL
}

// Rewrites `pkg.builtin(...)` to the identifier form, keeping the written span.
@(private = "file")
qualify_builtin_callee :: proc(k: ^Checker, v: ^Expr_Call) -> ^Expr_Ident {
	selector := v.callee.(^Expr_Selector)
	ident := new(Expr_Ident, k.c.semantic_allocator)
	ident.span = selector.span
	ident.name = selector.name.text
	ident.name_id = intern_identifier(k.c, selector.name.text)
	v.callee = ident
	return ident
}

// The `dyn` type of a named receiver, or INVALID_TYPE.
@(private = "file")
dyn_operand_type :: proc(k: ^Checker, operand: Expr) -> Type_Id {
	ident, is_ident := operand.(^Expr_Ident)
	if !is_ident {
		return INVALID_TYPE
	}
	sym := symbol_of(k.c, lookup_symbol(k.scope, identifier_of(k.c, ident)))
	if sym == nil || !type_is_dyn(k.c, sym.type) {
		return INVALID_TYPE
	}
	check_single_expr(k, operand)
	return sym.type
}

// Does this operand name a reflection descriptor constant?
@(private = "file")
callee_is_descriptor :: proc(k: ^Checker, operand: Expr) -> bool {
	ident, is_ident := operand.(^Expr_Ident)
	if !is_ident {
		return false
	}
	sym := symbol_of(k.c, lookup_symbol(k.scope, identifier_of(k.c, ident)))
	return sym != nil && sym.kind == .Const && type_is_descriptor(k.c, sym.type)
}

// The generic procedure template a callee names, or INVALID_SYMBOL.
@(private = "file")
callee_generic_procedure :: proc(k: ^Checker, callee: Expr) -> Symbol_Id {
	template := generic_template_of_callee(k, callee, .Procedure)
	return template == nil ? INVALID_SYMBOL : template.symbol
}

// `Type.group(...)` or `pkg.Type.group(...)`. A value receiver is not type
// syntax, so it falls through to the method path silently.
@(private = "file")
associated_group :: proc(k: ^Checker, callee: Expr) -> Symbol_Id {
	sel, is_selector := callee.(^Expr_Selector)
	if !is_selector || sel.operand == nil {
		return INVALID_SYMBOL
	}
	subject := resolve_type_syntax(k, sel.operand)
	if subject == INVALID_TYPE {
		return INVALID_SYMBOL
	}
	member := find_member(k, subject, intern_identifier(k.c, sel.name.text))
	if sym := symbol_of(k.c, member); sym != nil && sym.kind == .Proc_Group {
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
	candidates := method_candidates(k, receiver_base.type, intern_identifier(k.c, sel.name.text))
	written, args_ok := collect_call_arguments(k, v.args, candidates, 1)
	if !args_ok {
		v.type = INVALID_TYPE
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
		v.type = INVALID_TYPE
		return
	}
	args := make([]Arg_Info, len(written) + 1, k.c.semantic_allocator)
	args[0] = arg_from_expr(receiver)
	args[0].is_receiver = true
	copy(args[1:], written)

	description := concat(k.c, "method `", concat(k.c, sel.name.text, "`"))
	cand, resolved := resolve_overload(k, v.span, description, candidates, args)
	if !resolved {
		v.type = INVALID_TYPE
		return
	}
	if len(candidates) > 1 {
		v.overload_members = candidates
	}
	chosen := symbol_of(k.c, cand.symbol)
	if reject_direct_hook_call(k, v.span, cand.symbol) {
		v.type = INVALID_TYPE
		return
	}
	// A mutating receiver is passed by address, so it must be an assignable place
	// and not a packed field, whose address may be misaligned.
	if chosen.receiver == .Inout {
		if field, packed := packed_field_reached(k, receiver); packed {
			errorf(
				k.c, sel.name.span, "L0614",
				"cannot take the address of `%s`: it is reached through a packed struct", field,
			)
			v.type = INVALID_TYPE
			return
		}
		if !receiver_base.assignable {
			report_not_assignable(k, receiver_base, "the receiver of a mutating method")
			v.type = INVALID_TYPE
			return
		}
	}
	sel.resolution = Resolution{kind = .Method, symbol = cand.symbol}
	sel.type = chosen.proc_type
	v.resolution = Resolution{kind = .Call, symbol = cand.symbol, chosen_overload = cand.symbol}
	v.operation = Call_Procedure{}
	if !bind_chosen_call(k, v, cand) {
		v.type = INVALID_TYPE
		return
	}
	set_call_result(v, chosen.result, chosen.result_inout, result_written_but_unresolved(chosen))
	// Reported after the result shape is settled, so a destructuring keeps its arity.
	#partial switch chosen.container_op {
	case .Resize:
		// design.md "Zero values": growth fills new slots with the element's zero.
		require_type_has_zero(
			k, container_element(k.c, chosen.params[0]), v.span, "growing a container",
		)
	case .Map_Lookup_Value:
		element := container_element(k.c, chosen.params[0])
		if type_clone_disabled(k.c, element) {
			errorf(
				k.c, v.span, "L0491",
				"`%s` is move-only, so `lookup_value` cannot copy it out; use `find` or `find_ref`, which borrow",
				type_name(k.c, element),
			)
		}
	case .Insert, .Map_Find_Or_Insert, .Map_Try_Insert:
		// design.md "Container insertion": taken like an initialization, so a
		// borrowed place is copied and a move-only one needs `move(...)`.
		element := container_element(k.c, chosen.params[0])
		if len(v.bound) > 2 {
			classify_copy_cost(k, v.bound[2], element, .Insertion)
			if type_clone_disabled(k.c, element) {
				classify_copy(k, v.bound[2], element, .Insertion)
			}
		}
	case .Append:
		// A lone spread lends its slice instead of building a pack, and `append`
		// would keep the elements.
		element := container_element(k.c, chosen.params[0])
		if type_clone_disabled(k.c, element) && v.variadic_forwards && len(v.bound) > 1 {
			errorf(
				k.c, expr_span(v.bound[1]), "L0503",
				"`%s` is move-only, so a `..` spread cannot copy its elements into the pack",
				type_name(k.c, element),
			)
		}
	}
	require_sort_order_policy(k, chosen, v.span)
	fold_standard_customization_call(k, v, chosen)
}

// A fixed array's or vector's `len()` is constant, though the receiver is still
// evaluated once for its effects.
fold_standard_customization_call :: proc(k: ^Checker, v: ^Expr_Call, chosen: ^Symbol) {
	if chosen == nil || chosen.synth != .Standard_Len || len(chosen.params) == 0 {
		return
	}
	info := underlying_info(k.c, chosen.params[0])
	if info == nil || (info.kind != .Array && info.kind != .Simd) {
		return
	}
	v.is_const = true
	v.const_value = int_const(k.c, i64(info.count))
}

reject_direct_hook_call :: proc(k: ^Checker, span: Span, symbol_id: Symbol_Id) -> bool {
	sym := symbol_of(k.c, symbol_id)
	if sym == nil || sym.hook == .None {
		return false
	}
	operation := "the corresponding language operation"
	switch sym.hook {
	case .Convert: operation = "`T(value)`"
	case .Copy:    operation = "`clone(value)` or `try_clone(value)`"
	case .Drop:    operation = "`drop(value)`"
	case .None:
	}
	errorf(k.c, span, "L0412", "`%s` implements `hook(%s)` and is not directly accessible; use %s", identifier_text(k.c, sym.name), hook_name(sym.hook), operation)
	return true
}

// Whether a one-argument application names a type; the probe is silent.
@(private = "file")
callee_argument_denotes_type :: proc(k: ^Checker, v: ^Expr_Call) -> bool {
	if len(v.args) != 1 || v.args[0].name.text != "" || v.args[0].mode != .Value {
		return false
	}
	return resolve_type_syntax(k, v.args[0].value) != INVALID_TYPE
}

// A call through a group or generic procedure: check the arguments once, rank
// the members, and bind the winner.
@(private = "file")
check_group_call :: proc(k: ^Checker, v: ^Expr_Call, group: Symbol_Id) {
	sym := symbol_of(k.c, group)
	members := sym.kind == .Proc_Group ? sym.members : []Symbol_Id{group}
	description := concat(k.c, "`", concat(k.c, identifier_text(k.c, sym.name), "`"))
	args, args_ok := collect_call_arguments(k, v.args, members, live_group = group)
	if !args_ok {
		v.type = INVALID_TYPE
		return
	}
	// Checking an argument may instantiate a generic subject and add members.
	if current := symbol_of(k.c, group); current != nil && current.kind == .Proc_Group {
		members = current.members
	}
	cand, resolved := resolve_overload(k, v.span, description, members, args)
	if !resolved {
		v.type = INVALID_TYPE
		return
	}
	if len(members) > 1 {
		v.overload_members = members
	}
	annotate_chosen_callee(k, v, cand.symbol)
	if !bind_chosen_call(k, v, cand) {
		v.type = INVALID_TYPE
		return
	}
	chosen := symbol_of(k.c, cand.symbol)
	set_call_result(v, chosen.result, chosen.result_inout, result_written_but_unresolved(chosen))
}

// Every call spelling passes a `self: ^` receiver by address, including
// `Type.method(CONSTANT)` and calls resolved through a procedure group.
@(private = "file")
materialize_call_receiver :: proc(k: ^Checker, v: ^Expr_Call) {
	if v.type == INVALID_TYPE || v.is_const || len(v.bound) == 0 || v.bound[0] == nil {
		return
	}
	if type_is_compile_time_only(k.c, expr_base(v.bound[0]).type) {
		return
	}
	chosen := symbol_of(k.c, v.resolution.chosen_overload)
	if chosen != nil && chosen.has_receiver && chosen.receiver == .Borrow && expr_base(v.bound[0]).is_const {
		request_materialization(k, v.bound[0])
	}
}

// Rewrites the callee to name the selected overload, so later phases see an
// ordinary call. A sort's element `<` is settled here, as `check_method_call`
// does for methods.
annotate_chosen_callee :: proc(k: ^Checker, v: ^Expr_Call, chosen: Symbol_Id) {
	sym := symbol_of(k.c, chosen)
	require_sort_order_policy(k, sym, v.span)
	if base := expr_base(v.callee); base != nil && sym != nil {
		base.resolution = Resolution{kind = .Value, symbol = chosen}
		base.value_category = .Value
		base.type = sym.proc_type
	}
	if ident, is_ident := v.callee.(^Expr_Ident); is_ident {
		ident.symbol = chosen
	}
	v.resolution = Resolution{kind = .Call, symbol = chosen, chosen_overload = chosen}
	v.operation = Call_Procedure{}
}

check_bound_argument_mode :: proc(k: ^Checker, value: Expr, mode: Param_Mode, subject: string) -> bool {
	if mode == .Borrow {
		return check_borrow_argument(k, value)
	}
	if mode != .Inout {
		return true
	}
	note_unknown_nil_write(k, value)
	if base := expr_base(value); base != nil && !base.assignable {
		report_not_assignable(k, base, subject)
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
	value, pre := arg.value, prechecked
	// design.md "Receiver forms": `Type.method(&value)` names the receiver
	// `self: ^T` receives.
	if expected == .Borrow {
		if !pre && check_single_expr(k, value, target) == INVALID_TYPE {
			return value, false
		}
		pre = true
		if pointer_to_element(k.c, expr_base(value).type) == target {
			value = dereference_argument(k, value)
		}
	}
	passed: bool
	value, passed = pass_argument(k, value, target, pre, arg.mode == .Inout)
	if !passed {
		return value, false
	}
	if !check_bound_argument_mode(k, value, expected, "an `inout` argument") {
		return value, false
	}
	return value, true
}

check_argument_value :: proc(k: ^Checker, e: Expr, target: Type_Id, inout_argument := false) -> (Expr, bool) {
	// design.md "Indexing and slicing" and "Maps": an `inout` argument selects an
	// `inout` indexing overload, which never inserts.
	k.place_position, k.insert_position = inout_argument, false
	type := check_single_expr(k, e, target)
	k.place_position, k.insert_position = false, false
	if type == INVALID_TYPE || target == INVALID_TYPE {
		return e, false
	}
	return e, materialize_value_expr(k, e, target, "pass")
}

// Binds written arguments to parameters in `v.bound`, then fills the omitted
// ones from the declaration's defaults.
@(private = "file")
bind_arguments :: proc(k: ^Checker, v: ^Expr_Call, info: ^Type_Info, declaration: Symbol_Id) -> bool {
	count := len(info.parameters)
	if info.c_vararg {
		return bind_c_vararg_arguments(k, v, info)
	}
	if variadic_parameter_index(info) >= 0 {
		bound_ok := bind_variadic_arguments(k, v, info, declaration, v.args)
		require_argument_ownership(k, v, declaration, info)
		return bound_ok
	}
	bound := make([]Expr, count, k.c.semantic_allocator)
	filled := make([]bool, count, k.c.semantic_allocator)
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
			if declared == nil {
				errorf(k.c, arg.span, "L0371", "a call through a procedure value cannot use named arguments")
				ok = false
				continue
			}
			slot = parameter_slot_named(k.c, declared, intern_identifier(k.c, arg.name.text))
			if slot < 0 {
				errorf(k.c, arg.span, "L0371", "no parameter named `%s`", arg.name.text)
				ok = false
				continue
			}
			if filled[slot] {
				errorf(k.c, arg.span, "L0371", "`%s` is given twice", arg.name.text)
				ok = false
				continue
			}
		} else if named {
			errorf(k.c, arg.span, "L0372", "a positional argument cannot follow a named one")
			ok = false
			continue
		} else if slot >= count {
			errorf(
				k.c,
				v.span,
				"L0322",
				"this procedure takes %d argument%s, found %d",
				count,
				count == 1 ? "" : "s",
				len(v.args),
			)
			return false
		}

		filled[slot] = true
		append(&order, slot)
		expected_mode := slot < len(info.param_modes) ? info.param_modes[slot] : Param_Mode.Value
		value, passed := bind_written_argument(k, arg, info.parameters[slot], expected_mode)
		bound[slot] = value
		ok = ok && passed
	}

	for index in 0 ..< count {
		if filled[index] {
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
			errorf(
				k.c,
				v.span,
				"L0322",
				"this procedure takes %d argument%s, found %d",
				count,
				count == 1 ? "" : "s",
				len(v.args),
			)
			return false
		}
		bound[index] = substitute_caller_location(k, declared.param_defaults[index], v.span)
		append(&order, index)
	}

	v.bound = bound
	if named {
		v.bound_order = order[:]
	}
	require_argument_ownership(k, v, declaration, info)
	return ok
}

// design.md "`@(c_vararg)`": the fixed parameters bind normally, and each later
// argument is a concrete, foreign-ABI-safe value passed by value.
@(private = "file")
bind_c_vararg_arguments :: proc(k: ^Checker, v: ^Expr_Call, info: ^Type_Info) -> bool {
	fixed := len(info.parameters)
	if len(v.args) < fixed {
		errorf(
			k.c, v.span, "L0322", "this procedure takes at least %d argument%s, found %d",
			fixed, fixed == 1 ? "" : "s", len(v.args),
		)
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
			value, passed := bind_written_argument(k, arg, info.parameters[index], mode)
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
		type := check_single_expr(k, arg.value)
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

// `T(value)` is conversion only. Built-in source/target pairs are reserved;
// every other pair may be supplied by an inherent `hook(convert)` on T.
@(private = "file")
check_conversion :: proc(k: ^Checker, v: ^Expr_Call, target: Type_Id) {
	if !gate_type(k, target, v.span) {
		v.type = INVALID_TYPE
		return
	}
	if len(v.args) != 1 || v.args[0].name.text != "" || v.args[0].mode != .Value {
		errorf(k.c, v.span, "L0410", "a conversion to `%s` takes exactly one plain value argument", type_name(k.c, target))
		v.type = INVALID_TYPE
		return
	}
	// Checked without the target as context: the conversion node owns it.
	source := check_single_expr(k, v.args[0].value)
	if source == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}
	if type_is_enum(k.c, target) && (type_is_numeric(k.c, source) || type_is_enum(k.c, source)) &&
	   type_underlying(k.c, source) != type_underlying(k.c, target) {
		errorf(k.c, v.span, "L0410", "an enum is closed; use `%s.from_int(value)` to validate a backing integer", type_name(k.c, target))
		v.type = INVALID_TYPE
		return
	}
	// Invalid UTF-8 is reported as such, not as a missing conversion.
	if operand := expr_base(v.args[0].value); operand.is_const &&
	   constant_is_invalid_text(k.c, operand.const_value, target) {
		report_invalid_utf8(k, operand.span, target)
		v.type = INVALID_TYPE
		return
	}
	if builtin_conversion(k, v, target, source) {
		return
	}
	args := make([]Arg_Info, 1, k.c.semantic_allocator)
	args[0] = arg_from_expr(v.args[0].value)
	check_conversion_hook_call(k, v, target, args, source)
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
	converted: Const_Value
	if base.is_const {
		fits: bool
		converted, fits = convert_const(k.c, base.const_value, target, true)
		if !fits {
			return false
		}
	} else if !convertible(k.c, source, target) {
		return false
	}
	// design.md "Distinct types": converting a managed value between a distinct
	// name and its underlying type reinterprets it, so a place must be cloned or
	// both it and the result would own one allocation.
	clones := classify_copy(k, v.args[0].value, source, .Conversion)
	if clones {
		report_copy_cost(k, .Conversion, expr_span(v.args[0].value), v.args[0].value, source, k.loop_depth > 0)
	}
	v.operation = Call_Conversion{clones = clones}
	v.resolution = {}
	record_proc_contract_check(k.c, source, target, v.span)
	v.bound = make([]Expr, 1, k.c.semantic_allocator)
	v.bound[0] = v.args[0].value
	v.type = target
	if base.is_const {
		v.is_const = true
		v.const_value = converted
	}
	return true
}

// Conversion hooks are inherent to the target, so imports cannot change `T(value)`.
@(private = "file")
check_conversion_hook_call :: proc(k: ^Checker, v: ^Expr_Call, target: Type_Id, args: []Arg_Info, attempted: Type_Id) {
	usable := hook_candidates(k, target, .Convert)
	if len(usable) == 0 {
		errorf(k.c, expr_span(v.args[0].value), "L0373", "`%s` cannot be converted to `%s`", type_name(k.c, attempted), type_name(k.c, target))
		if (target == TYPE_STRING || target == TYPE_STRING_VIEW) &&
		   (slice_element(k.c, attempted) == TYPE_U8 || (target == TYPE_STRING && underlying_kind(k.c, attempted) == .CString_View)) {
			add_notef(k.c, v.span, "use `%s.from_utf8(bytes)`, which returns `Option(%s)`", type_name(k.c, target), type_name(k.c, target))
		}
		v.type = INVALID_TYPE
		return
	}
	description := concat(k.c, "conversion to `", concat(k.c, type_name(k.c, target), "`"))
	cand, resolved := resolve_overload(k, v.span, description, usable, args)
	if !resolved {
		v.type = INVALID_TYPE
		return
	}
	annotate_chosen_callee(k, v, cand.symbol)
	if !bind_chosen_call(k, v, cand) {
		v.type = INVALID_TYPE
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

	// design.md "Evaluation order": kept only when a name reorders the fixed
	// parameters, the one case where written and slot order disagree.
	slot_order := make([dynamic]int, 0, pack + 1, k.c.semantic_allocator)
	first := 0
	if receiver != nil {
		bound[0] = receiver
		append(&slot_order, 0)
		if len(info.param_modes) > 0 &&
		   !check_bound_argument_mode(k, receiver, info.param_modes[0], "an `inout` argument") {
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
		expected := slot < len(info.param_modes) ? info.param_modes[slot] : Param_Mode.Value
		value, passed := bind_written_argument(k, arg, info.parameters[slot], expected, prechecked)
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
		if declared == nil {
			errorf(k.c, arg.span, "L0371", "a call through a procedure value cannot use named arguments")
			ok = false
			continue
		}
		slot := parameter_slot_named(k.c, declared, intern_identifier(k.c, arg.name.text), pack)
		if slot < 0 {
			errorf(k.c, arg.span, "L0371", "no parameter named `%s`", arg.name.text)
			ok = false
			continue
		}
		if bound[slot] != nil {
			errorf(k.c, arg.span, "L0371", "`%s` is given twice", arg.name.text)
			ok = false
			continue
		}
		expected := slot < len(info.param_modes) ? info.param_modes[slot] : Param_Mode.Value
		value, passed := bind_written_argument(k, arg, info.parameters[slot], expected, prechecked)
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
			errorf(
				k.c, v.span, "L0322",
				"this procedure takes at least %d argument%s, found %d",
				pack - first, pack - first == 1 ? "" : "s", len(args),
			)
			return false
		}
		bound[index] = substitute_caller_location(k, declared.param_defaults[index], v.span)
		append(&slot_order, index)
	}
	if named > 0 {
		v.bound_order = slot_order[:]
	}

	rest := args[fixed + named:]
	// One spread and nothing else: forward the slice itself.
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
		value, passed := pass_argument(k, arg.value, element, prechecked)
		append(&elements, value)
		append(&order, false)
		// Managed or not: a pack copies what it is given.
		classify_copy_cost(k, value, element, .Variadic)
		needs_element_clone ||= expression_is_borrowed_place(value)
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
				errorf(
					k.c, expr_span(spread), "L0503",
					"`%s` is move-only, so a `..` spread cannot copy its elements into the pack",
					type_name(k.c, element),
				)
			}
			ok = false
		} else {
			contribute_lifecycle_members(k, element)
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

// design.md "Named arguments": the slot a name reaches, shared by overload
// resolution and binding so they cannot disagree. `limit` stops short of a
// variadic pack. -1 when nothing carries the name, including a call through a
// procedure value, which has no parameter symbols.
parameter_slot_named :: proc(c: ^Compiler, declared: ^Symbol, name: Identifier_Id, limit := -1) -> int {
	if declared == nil {
		return -1
	}
	stop := limit < 0 ? len(declared.param_symbols) : min(limit, len(declared.param_symbols))
	for binding, position in declared.param_symbols[:stop] {
		if symbol := symbol_of(c, binding); symbol != nil && symbol.name == name {
			return position
		}
	}
	return -1
}

// Overload resolution already checked every written argument, so binding the
// chosen candidate must not check them again.
pass_argument :: proc(
	k: ^Checker, e: Expr, target: Type_Id, prechecked: bool, inout_argument := false,
) -> (Expr, bool) {
	if !prechecked {
		return check_argument_value(k, e, target, inout_argument)
	}
	return e, materialize_argument(k, e, target)
}

@(private = "file")
check_spread_argument :: proc(k: ^Checker, arg: Argument, pack: Type_Id, prechecked := false) -> (Expr, bool) {
	type := prechecked ? expr_base(arg.value).type : check_single_expr(k, arg.value, pack)
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
	return arg.value, true
}

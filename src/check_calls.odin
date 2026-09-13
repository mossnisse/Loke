// Call checking, overload selection, argument binding, and explicit conversions.
// check_expr.odin dispatches expressions here; overload.odin owns candidate
// ranking, and feature checkers retain their specialized call contracts.
package lokec

// ------------------------------------------------------- calls and casts --

@(private)
check_call :: proc(k: ^Checker, v: ^Expr_Call, expected: Type_Id) {
	defer materialize_call_receiver(k, v)
	v.value_category = .Value

	// A built-in is not a value, so it is recognised before the callee is
	// checked as one.
	if ident, is_ident := v.callee.(^Expr_Ident); is_ident {
		symbol_id := lookup_symbol(k.scope, identifier_of(k.c, ident))
		if sym := symbol_of(k.c, symbol_id); sym != nil && sym.kind == .Builtin {
			check_builtin_call(k, v, ident, symbol_id, expected)
			return
		}
	}
	// The same built-in reached through the standard package that publishes it —
	// `mem.default_allocator()`. The qualified spelling names the identical
	// symbol, so it collapses to the identical call rather than to a wrapper.
	if symbol_id := callee_package_builtin(k, v.callee); symbol_id != INVALID_SYMBOL {
		check_builtin_call(k, v, qualify_builtin_callee(k, v), symbol_id, expected)
		return
	}

	// Nor is a procedure group: it stands for several procedures, so it goes to
	// the overload engine before anything asks it for a single procedure type.
	if group := callee_group(k, v.callee); group != INVALID_SYMBOL {
		check_group_call(k, v, group, expected)
		return
	}
	if group := associated_group(k, v.callee); group != INVALID_SYMBOL {
		check_group_call(k, v, group, expected)
		return
	}
	// Nor is a generic procedure: `$T` has no type until the call's own arguments
	// bind it, so it is never checked as a value.
	if template := callee_generic_procedure(k, v.callee); template != INVALID_SYMBOL {
		check_group_call(k, v, template, expected)
		return
	}
	// An interface application is a compile-time boolean, not a conversion.
	if info := interface_info_for(k, named_callee_symbol(k, v.callee)); info != nil {
		v.operation = Call_Compile_Time{}
		check_interface_application(k, v, info)
		return
	}
	// design.md "Shared ownership": one name means two things. `shared(Node)` is
	// the type and `shared(node)` takes ownership of a value, and nothing but the
	// operand tells them apart — so the call settles it, and everything that is
	// not a type goes to the constructor group.
	if k.c.shared_symbol != INVALID_SYMBOL &&
	   named_callee_symbol(k, v.callee) == k.c.shared_symbol &&
	   !callee_argument_denotes_type(k, v) {
		check_group_call(k, v, k.c.shared_construct_symbol, expected)
		return
	}
	// `Simd(f32, 4)` and `Range(int)` denote a type wherever they appear too,
	// which is what makes `Simd(i32, 4)(v)` an ordinary written conversion.
	if simd_callee(k, v.callee) || range_callee(k, v.callee) {
		denoted := INVALID_TYPE
		if range_callee(k, v.callee) {
			denoted = resolve_range_application(k, v)
		} else {
			denoted = resolve_simd_application(k, v)
		}
		if denoted == INVALID_TYPE {
			v.type = INVALID_TYPE
			return
		}
		v.operation = Call_Compile_Time{}
		v.type = TYPE_TYPE
		v.value_category = .Type
		v.is_const = true
		v.const_value = type_const(denoted)
		return
	}
	// A generic record application denotes a type wherever it appears, which is
	// what makes `Iterator :: Stack_Iterator(T, N);` an associated type.
	if generic_template_of_callee(k, v.callee, .Record) != nil {
		denoted := resolve_type_syntax(k, v)
		if denoted == INVALID_TYPE {
			v.type = INVALID_TYPE
			return
		}
		v.operation = Call_Compile_Time{}
		v.type = TYPE_TYPE
		v.value_category = .Type
		v.is_const = true
		v.const_value = type_const(denoted)
		return
	}
	// A slot called through a `dyn` view: an indirect call through the witness,
	// not an ordinary method lookup on a concrete type.
	if sel, is_selector := v.callee.(^Expr_Selector); is_selector && sel.operand != nil {
		if operand := dyn_operand_type(k, sel.operand); operand != INVALID_TYPE {
			if check_dyn_slot_call(k, v, sel, operand) {
				return
			}
			errorf(k.c, v.span, "L0467", "`%s` has no slot `%s`", type_name(k.c, operand), sel.name.text)
			v.type = INVALID_TYPE
			return
		}
	}
	// `field.get(value)` / `field.pointer(value)`: compiler-defined operations on
	// a descriptor constant, whose result type follows that descriptor. Only a
	// name bound to one qualifies, which is what a `$field` binding is, so no
	// other callee is checked twice looking for it.
	// `text.byte_len()`, `text.bytes()`, `string.from_runes(...)`, and
	// `union.active_typeid()`: compiler-defined operations on built-in carriers.
	if sel, is_selector := v.callee.(^Expr_Selector); is_selector && sel.operand != nil {
		if check_union_extract(k, v, sel) {
			return
		}
		if check_text_operation(k, v, sel) {
			return
		}
		if check_enum_values(k, v, sel) {
			return
		}
		if check_enum_from_int(k, v, sel) {
			return
		}
	}
	if sel, is_selector := v.callee.(^Expr_Selector); is_selector && callee_is_descriptor(k, sel.operand) {
		check_single_expr(k, sel.operand)
		if check_descriptor_operation(k, v, sel) {
			return
		}
	}

	outer_callee := k.in_callee
	k.in_callee = true
	// A bare `.name(payload)` callee takes its union from the expected type, the
	// same way the implicit enum selector takes its enum from one.
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
	// A method selector is not a value: the receiver becomes argument zero, which
	// the selector alone cannot do.
	if callee_base.resolution.kind == .Method {
		check_method_call(k, v, v.callee.(^Expr_Selector), expected)
		return
	}
	// `U.name(payload)` / `.name(payload)`: the selector named the variant, and
	// the argument supplies its payload.
	if callee_base.resolution.kind == .Union_Variant {
		check_union_construct(k, v, v.callee.(^Expr_Selector))
		return
	}
	if callee_type == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}
	if callee_base.value_category == .Type {
		// `(dyn Drawable)(&circle)`: an ordinary explicit conversion, but one that
		// checks satisfaction and requests a witness rather than reinterpreting.
		if type_is_dyn(k.c, callee_base.denoted_type) {
			check_dyn_conversion(k, v, callee_base.denoted_type)
			return
		}
		check_conversion(k, v, callee_base.denoted_type)
		return
	}

	info := underlying_info(k.c, callee_type)
	if info == nil || info.kind != .Proc {
		// A payloadless variant is complete on its own, so the call is the
		// mistake rather than the selector.
		if sel, is_sel := v.callee.(^Expr_Selector);
		   is_sel && sel.variant_union != INVALID_TYPE &&
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

	// Only a directly named procedure may use defaults or named arguments; a
	// call through a procedure value supplies every parameter positionally.
	// `pkg.f` names one just as plainly as `f` does.
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

	set_call_result(v, info.result, info.result_inout)
}

// design.md "Parameter semantics and ABI lowering": an `inout` result returns a
// place, so the call is one — addressable and assignable. Every call spelling
// settles its result here, because which one reached the procedure does not
// change what the procedure returns.
set_call_result :: proc(v: ^Expr_Call, result: Type_Id, result_inout: bool) {
	if result == INVALID_TYPE {
		v.type = TYPE_VOID
		return
	}
	v.type = result
	if result_inout {
		v.value_category = .Place
		v.addressable = true
		v.assignable = true
	}
}

// design.md "@(require_results)": a bare call statement discards its results.
// The policy comes from the selected declaration or, after overload selection,
// from the procedure group the call went through. An explicit
// `_ = call()` is an assignment, not this statement, so it is never reached.
report_discarded_required_results :: proc(k: ^Checker, expr: Expr) {
	call, is_call := expr.(^Expr_Call)
	if !is_call || call.type == TYPE_VOID {
		return // not a call, or a call with no results
	}
	required := false
	name := ""
	if selected := symbol_of(k.c, call.resolution.chosen_overload); selected != nil {
		required = selected.require_results
		name = identifier_text(k.c, selected.name)
	}
	if !required {
		if group := symbol_of(k.c, callee_group(k, call.callee)); group != nil && group.require_results {
			required = true
			name = identifier_text(k.c, group.name)
		}
	}
	if required {
		errorf(
			k.c, call.span, "L0612",
			"the result of `%s` must be used or discarded with `_ = ...`", name,
		)
		return
	}
	// design.md "@(require_results)": the attribute is a *type* attribute as
	// well, so a result whose type requires handling is required whoever
	// declared the procedure. `Result` is the one that matters in practice.
	if type_requires_results(k.c, call.type) {
		errorf(
			k.c, call.span, "L0612",
			"this call produces `%s`, which must be used or discarded with `_ = ...`",
			type_name(k.c, call.type),
		)
		return
	}
}

// The procedure group a callee names, or INVALID_SYMBOL. `pkg.group` names one
// as plainly as `group` does — `named_callee_symbol` already walks the package
// alias and requires the member to be public.
@(private = "file")
callee_group :: proc(k: ^Checker, callee: Expr) -> Symbol_Id {
	id := named_callee_symbol(k, callee)
	sym := symbol_of(k.c, id)
	return sym != nil && sym.kind == .Proc_Group ? id : INVALID_SYMBOL
}

// A `pkg.name` callee naming a public built-in of `pkg`, or INVALID_SYMBOL.
// Only the qualified spelling: `qualify_builtin_callee` rewrites a selector,
// and a plain identifier is already the form the built-in checkers expect.
@(private = "file")
callee_package_builtin :: proc(k: ^Checker, callee: Expr) -> Symbol_Id {
	if _, is_selector := callee.(^Expr_Selector); !is_selector {
		return INVALID_SYMBOL
	}
	id := named_callee_symbol(k, callee)
	sym := symbol_of(k.c, id)
	return sym != nil && sym.kind == .Builtin ? id : INVALID_SYMBOL
}

// Rewrites `pkg.builtin(...)` to the identifier form the built-in checkers and
// the backend already understand, keeping the original span so diagnostics still
// point at what was written.
@(private = "file")
qualify_builtin_callee :: proc(k: ^Checker, v: ^Expr_Call) -> ^Expr_Ident {
	selector := v.callee.(^Expr_Selector)
	ident := new(Expr_Ident, k.c.semantic_allocator)
	ident.span = selector.span
	ident.name = selector.name.text
	ident.name_id = intern_identifier(k.c, selector.name.text)
	ident.symbol = INVALID_SYMBOL
	v.callee = ident
	return ident
}

// The `dyn` type of a call's receiver, or INVALID_TYPE. Checked before the
// operand is used as anything else, so a slot call never falls through to
// ordinary method lookup.
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

// `Type.group(...)` and `pkg.Type.group(...)`: an associated group named through
// the type. Resolving the operand as a type is silent when it is not one, so a
// value receiver falls straight through to the method path.
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

// `value.method(args)`. The receiver is argument zero. An `inout` receiver
// carries its mode implicitly; a consuming one is written `move(value).method()`
// (design.md "Receiver forms").
@(private = "file")
check_method_call :: proc(k: ^Checker, v: ^Expr_Call, sel: ^Expr_Selector, expected: Type_Id) {
	receiver := sel.operand
	receiver_base := expr_base(receiver)
	candidates := method_candidates(k, receiver_base.type, intern_identifier(k.c, sel.name.text))
	written, args_ok := collect_call_arguments(k, v.args, candidates, 1)
	if !args_ok {
		v.type = INVALID_TYPE
		return
	}
	// Every candidate consumes, and the transfer is not written: say so here
	// rather than through a no-overload-matches report of the same fact.
	if _, moved := receiver.(^Expr_Move); !moved && all_candidates_consume(k, candidates) {
		errorf(
			k.c, expr_span(receiver), "L0501",
			"`%s` consumes its receiver, so the call is written `move(...).%s(...)`",
			sel.name.text, sel.name.text,
		)
		v.type = INVALID_TYPE
		return
	}
	args := make([]Arg_Info, len(written) + 1, k.c.semantic_allocator)
	args[0] = arg_from_expr(k, receiver)
	args[0].is_receiver = true
	copy(args[1:], written)

	description := concat(k.c, "method `", concat(k.c, sel.name.text, "`"))
	cand, resolved := resolve_overload(k, v.span, description, candidates, args, expected)
	if !resolved {
		v.type = INVALID_TYPE
		return
	}
	chosen := symbol_of(k.c, cand.symbol)
	if reject_direct_hook_call(k, v.span, cand.symbol) {
		v.type = INVALID_TYPE
		return
	}
	// An exclusive mutable borrow needs a mutable place. A consuming receiver is
	// an `^Expr_Move` by the rank filter above, and `check_move` has already held
	// it to `move`'s storage rule -- no partial move, no static-duration source.
	if chosen.receiver == .Inout {
		// A mutating receiver is passed by address just like an explicit `&mut`.
		// Packed fields are writable but deliberately not addressable: silently
		// accepting one here can hand a misaligned pointer to the method body.
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
	if !bind_chosen_call(k, v, cand, args) {
		v.type = INVALID_TYPE
		return
	}
	set_call_result(v, chosen.result, chosen.result_inout)
	// `lookup_value` produces an owned copy of the stored element, so a move-only
	// element has nothing for it to produce. Reported after the result shape is
	// settled, so a `v, ok :=` destructuring still knows its arity.
	// design.md "Zero values": growth fills the new slots with the element's
	// zero, and a no-zero element has none to fill them with.
	#partial switch chosen.container_op {
	case .Resize:
		require_type_has_zero(
			k, container_element(k.c, chosen.params[0]), v.span, "growing a container",
		)
	}
	if chosen.container_op == .Map_Lookup_Value {
		element := container_element(k.c, chosen.params[0])
		if type_clone_disabled(k.c, element) {
			errorf(
				k.c, v.span, "L0491",
				"`%s` is move-only, so `lookup_value` cannot copy it out; use `find` or `find_ref`, which borrow",
				type_name(k.c, element),
			)
		}
	}
	// design.md "Container insertion": an inserted element is taken the way an
	// initialization takes it, so a borrowed place is copied and a move-only one
	// has to be written `move(...)`. `append`'s pack applies the same rule when
	// it is bound.
	#partial switch chosen.container_op {
	case .Insert, .Map_Find_Or_Insert, .Map_Try_Insert:
		element := container_element(k.c, chosen.params[0])
		if type_clone_disabled(k.c, element) && len(v.bound) > 2 {
			classify_copy(k, v.bound[2], element, "insertion")
		}
	case .Append:
		// A lone spread forwards its slice instead of building a pack, so binding
		// never saw it; that slice is lent, and `append` would keep its elements.
		element := container_element(k.c, chosen.params[0])
		if type_clone_disabled(k.c, element) && v.variadic_forwards && len(v.bound) > 1 {
			errorf(
				k.c, expr_span(v.bound[1]), "L0503",
				"`%s` is move-only, so a `..` spread cannot copy its elements into the pack",
				type_name(k.c, element),
			)
		}
	}
	// design.md "Iteration adapters": a map view yields owned elements, so the
	// halves it copies need a copy entry point. The view itself costs nothing;
	// what it cannot do is produce a `move_only` key or value.
	#partial switch chosen.container_op {
	case .Map_Entries, .Map_Keys, .Map_Values:
		require_copyable_view_element(k, chosen, v.span)
	}
	// A sort needs its element's `<` settled before the backend asks for it.
	require_sort_order_policy(k, chosen, v.span)
	fold_standard_customization_call(k, v, chosen)
}

// A fixed array's and a vector's length are properties of their type, so the
// call has a constant value. The call itself stays ordinary: the backend still
// evaluates the receiver exactly once, for its effects.
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

@(private = "file")
require_copyable_view_element :: proc(k: ^Checker, chosen: ^Symbol, span: Span) {
	subject := chosen.params[0]
	halves := [2]struct{copied: bool, type: Type_Id, what: string}{
		{chosen.container_op != .Map_Values, container_key(k.c, subject), "key"},
		{chosen.container_op != .Map_Keys, container_element(k.c, subject), "value"},
	}
	for half in halves {
		if !half.copied || !type_clone_disabled(k.c, half.type) {
			continue
		}
		errorf(
			k.c, span, "L0491",
			"`%s` is move-only, so this view cannot copy the %s out of the map; iterate `&value`, or remove the entries",
			type_name(k.c, half.type), half.what,
		)
		return
	}
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

// Whether a one-argument application is naming a type rather than passing a
// value. `resolve_type_syntax` is a probe: it stays silent on anything that is
// not a type, which is what lets this ask without reporting.
@(private = "file")
callee_argument_denotes_type :: proc(k: ^Checker, v: ^Expr_Call) -> bool {
	if len(v.args) != 1 || v.args[0].name.text != "" || v.args[0].mode != .Value {
		return false
	}
	return resolve_type_syntax(k, v.args[0].value) != INVALID_TYPE
}

// A call through a group: check every argument once, rank the members, then bind
// against the one that wins.
@(private = "file")
check_group_call :: proc(k: ^Checker, v: ^Expr_Call, group: Symbol_Id, expected: Type_Id) {
	sym := symbol_of(k.c, group)
	// A generic procedure is one candidate rather than several, but it still has
	// to be inferred and substituted before it can be ranked, so it takes the
	// same path.
	members := sym.kind == .Proc_Group ? sym.members : []Symbol_Id{group}
	description := concat(k.c, "`", concat(k.c, identifier_text(k.c, sym.name), "`"))
	args, args_ok := collect_call_arguments(k, v.args, members, live_group = group)
	if !args_ok {
		v.type = INVALID_TYPE
		return
	}
	// Checking an explicitly typed argument may instantiate a generic subject and
	// add its public extension procedure to this synthetic group. Read the group
	// again rather than resolving against the member snapshot from before the
	// arguments existed.
	if current := symbol_of(k.c, group); current != nil && current.kind == .Proc_Group {
		members = current.members
	}
	cand, resolved := resolve_overload(k, v.span, description, members, args, expected)
	if !resolved {
		v.type = INVALID_TYPE
		return
	}
	annotate_chosen_callee(k, v, cand.symbol)
	if !bind_chosen_call(k, v, cand, args) {
		v.type = INVALID_TYPE
		return
	}
	chosen := symbol_of(k.c, cand.symbol)
	set_call_result(v, chosen.result, chosen.result_inout)
}

// Every call spelling passes an immutable receiver by address, including
// `Type.method(CONSTANT)` and calls resolved through a procedure group.
@(private = "file")
materialize_call_receiver :: proc(k: ^Checker, v: ^Expr_Call) {
	if v.type == INVALID_TYPE || v.is_const || len(v.bound) == 0 || v.bound[0] == nil {
		return
	}
	chosen := symbol_of(k.c, v.resolution.chosen_overload)
	if type_is_compile_time_only(k.c, expr_base(v.bound[0]).type) { return }
	if chosen != nil && chosen.has_receiver && chosen.receiver == .Borrow && expr_base(v.bound[0]).is_const {
		request_materialization(k, v.bound[0])
	}
}

// Rewrites the callee to name the selected overload, so every later phase — the
// backend included — sees an ordinary call to one procedure.
annotate_chosen_callee :: proc(k: ^Checker, v: ^Expr_Call, chosen: Symbol_Id) {
	sym := symbol_of(k.c, chosen)
	// A sort needs its element's `<` settled before the backend asks for it, and
	// this is where every call form — method, group — has arrived at one
	// declaration.
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

// One written argument bound against one parameter, returned as the expression
// to bind.
// design.md "Parameter semantics and ABI lowering": `inout` is written at both
// ends, and the argument is a place because the callee writes through it.
// Shared, so a call with a variadic pack enforces the same contract as one
// without.
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
	value, passed := pass_argument(k, arg.value, target, prechecked, arg.mode == .Inout)
	if !passed {
		return value, false
	}
	if expected == .Borrow && !check_borrow_argument(k, value) { return value, false }
	if arg.mode == .Inout {
		if base := expr_base(value); base != nil && !base.assignable {
			report_not_assignable(k, base, "an `inout` argument")
			return value, false
		}
	}
	return value, true
}

check_argument_value :: proc(k: ^Checker, e: Expr, target: Type_Id, inout_argument := false) -> (Expr, bool) {
	// design.md "Indexing and slicing" and "Maps": an `inout` argument is a place
	// the callee really writes, so it selects an `inout` indexing overload. It
	// does not insert: `inout m[key]` hands the callee an element that must
	// already be there. Every path that binds an argument goes through here, so
	// the rule is stated once.
	k.place_position, k.insert_position = inout_argument, false
	type := check_single_expr(k, e, target)
	k.place_position, k.insert_position = false, false
	if type == INVALID_TYPE || target == INVALID_TYPE {
		return e, false
	}
	return e, materialize_value_expr(k, e, target, "pass")
}

// Binds written arguments to parameters, then fills the omitted ones from the
// declaration's defaults. `v.bound` is the resolved parameter-order list the
// backend evaluates.
@(private = "file")
bind_arguments :: proc(k: ^Checker, v: ^Expr_Call, info: ^Type_Info, declaration: Symbol_Id) -> bool {
	count := len(info.parameters)
	// design.md "`@(c_vararg)`": a foreign C-variadic call passes each concrete
	// argument after the fixed ones, with no slice built.
	if info.c_vararg {
		return bind_c_vararg_arguments(k, v, info)
	}
	// design.md "Variadic parameters": every trailing argument fills one
	// parameter, so the pack is settled before the ordinary positional binding
	// runs and the written arguments it consumed are no longer separate.
	if variadic_parameter_index(info) >= 0 {
		bound_ok := bind_variadic_arguments(k, v, info, declaration)
		// A pack changes how the arguments are packed, not whether a `move`
		// parameter's transfer is written at the call site. A call through a group
		// asks the same question right after binding the same way.
		require_argument_ownership(k, v, declaration, info)
		return bound_ok
	}
	bound := make([]Expr, count, k.c.semantic_allocator)
	filled := make([]bool, count, k.c.semantic_allocator)
	declared := symbol_of(k.c, declaration)
	ok := true
	named := false
	// design.md "Evaluation order": a written argument runs where it is
	// written, whatever slot its name selects. The order is recorded here, where
	// the slot for each source element is already known, so neither the backend
	// nor the evaluator has to rediscover it.
	order := make([dynamic]int, 0, count, k.c.semantic_allocator)

	for arg, index in v.args {
		if arg.mode == .Spread {
			// design.md "Variadic parameters": a spread fills a variadic pack, and
			// this callee has none — a permanent answer, not a pending milestone
			//.
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
		if !ok {
			// An argument already failed, so the slot it should have filled is
			// not a second mistake to report.
			return false
		}
		if declared == nil || index >= len(declared.param_defaults) || declared.param_defaults[index] == nil {
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

// design.md "`@(c_vararg)`": the fixed parameters bind normally; every argument
// after them is a concrete C variadic — inferred, required foreign-ABI-safe
// after the default promotions, and never spread. `v.bound` keeps all of them
// so the backend emits one true varargs call.
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
			value, passed := check_argument_value(k, arg.value, info.parameters[index])
			bound[index] = value
			if !passed {
				ok = false
			}
			continue
		}
		bound[index] = arg.value
		type := check_single_expr(k, arg.value)
		if type == INVALID_TYPE {
			ok = false
			continue
		}
		// An untyped literal defaults to its concrete type, which is what actually
		// crosses (and what the C promotions then act on).
		if type_is_untyped(k.c, type) {
			type = default_type(k.c, type)
			check_single_expr(k, arg.value, type)
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
	// The operand is checked without the destination as expression context. The
	// conversion node, not a nested binary operator, owns that destination.
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
	if builtin_conversion(k, v, target, source) {
		return
	}
	args := make([]Arg_Info, 1, k.c.semantic_allocator)
	args[0] = arg_from_expr(k, v.args[0].value)
	check_conversion_hook_call(k, v, target, args, source)
}

// The built-in half of `T(v)`, including pointer and `distinct` conversions.
// Returns false — without reporting — when no built-in conversion reaches the
// target, which is what lets stage 2 run.
@(private = "file")
builtin_conversion :: proc(k: ^Checker, v: ^Expr_Call, target, source: Type_Id) -> bool {
	base := expr_base(v.args[0].value)
	// Constant folding must not reintroduce a representation-only conversion
	// that runtime values do not have. Two distinct identities meet only through
	// an explicit target hook, even when the operand happens to be constant.
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
	v.operation = Call_Conversion{}
	v.resolution = {}
	record_proc_contract_check(k.c, source, target, v.span)
	v.bound = make([]Expr, 1, k.c.semantic_allocator)
	v.bound[0] = v.args[0].value
	v.type = target
	if base.is_const {
		// The operand keeps its own type; the conversion node carries the result.
		v.is_const = true
		v.const_value = converted
	}
	return true
}

// User conversion hooks are inherent to the target, so imports and extension
// packages cannot alter an existing `T(value)` expression.
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
	cand, resolved := resolve_overload(k, v.span, description, usable[:], args, target)
	if !resolved {
		v.type = INVALID_TYPE
		return
	}
	annotate_chosen_callee(k, v, cand.symbol)
	if !bind_chosen_call(k, v, cand, args) {
		v.type = INVALID_TYPE
		return
	}
	v.type = target
}

// Whether `move(...)` is the only spelling that can reach any of these. An
// overload group mixing consuming and borrowing receivers has no such advice to
// give: the written form simply selects between them.
@(private = "file")
all_candidates_consume :: proc(k: ^Checker, candidates: []Symbol_Id) -> bool {
	for candidate in candidates {
		if sym := symbol_of(k.c, candidate); sym == nil || sym.receiver != .Move {
			return false
		}
	}
	return len(candidates) > 0
}

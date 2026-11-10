// The checker's ownership special forms: `move`, `drop`, `forget`, `exchange` and the
// capacity builtins, what a call's arguments must own, and the variable a place is
// rooted in. Liveness, which they feed, is in `lifecycle.odin`.
package lokec

import "core:fmt"

check_move :: proc(k: ^Checker, v: ^Expr_Move) {
	operand := check_single_expr(k, v.value)
	if operand != INVALID_TYPE && require_lexical_owner(k, v.value, "move") {
		v.type = operand
	}
}

check_drop_builtin :: proc(k: ^Checker, v: ^Expr_Call) {
	if !has_one_plain_argument(v) {
		errorf(k.c, v.span, "L0496", "`drop` takes one argument, the variable being cleaned up")
		return
	}
	if check_single_expr(k, v.args[0].value) == INVALID_TYPE || !require_lexical_owner(k, v.args[0].value, "drop") {
		return
	}
	v.bound = bound_exprs(k, v.args[0].value)
	v.type = TYPE_VOID
}

// `unsafe.forget` consumes without cleanup; it does not extend borrows.
check_forget_builtin :: proc(k: ^Checker, v: ^Expr_Call) {
	if !has_one_plain_argument(v) {
		errorf(k.c, v.span, "L0649", "`unsafe.forget` takes one argument, the value whose cleanup is suppressed")
		return
	}
	operand := v.args[0].value
	type := check_single_expr(k, operand)
	if type == INVALID_TYPE {
		return
	}
	// A place must spell its transfer; a temporary is already owned.
	if expression_is_borrowed_place(operand) {
		errorf(
			k.c,
			expr_span(operand),
			"L0501",
			"`unsafe.forget` consumes its operand, so a place is written `unsafe.forget(move(...))`",
		)
		return
	}
	// Forgetting a non-owner must not discard borrow provenance.
	if !type_is_managed(k.c, type) && type_carries_borrow(k.c, type).any {
		errorf(
			k.c,
			expr_span(operand),
			"L0650",
			"`%s` owns nothing and carries a borrow, so there is no cleanup for `unsafe.forget` to suppress",
			type_name(k.c, type),
		)
		return
	}
	v.bound = bound_exprs(k, operand)
	v.type = TYPE_VOID
}

// `move` and `drop` require an owned lexical variable.
require_lexical_owner :: proc(k: ^Checker, e: Expr, form: string) -> bool {
	ident, is_ident := e.(^Expr_Ident)
	sym := is_ident ? symbol_of(k.c, ident.symbol) : nil
	if sym == nil || (sym.kind != .Var && sym.kind != .Parameter) {
		errorf(
			k.c,
			expr_span(e),
			"L0497",
			"`%s` names a variable; move the owner out of the aggregate first, or %s the whole value",
			form,
			form,
		)
		return false
	}
	if symbol_outlives_bodies(sym) {
		errorf(
			k.c,
			expr_span(e),
			"L0498",
			"`%s` cannot be applied to %s, which is always live",
			form,
			storage_phrase(sym.duration),
		)
		add_notef(k.c, sym.span, "declared here; `exchange` replaces a static-duration value instead")
		return false
	}
	if sym.borrowed_binding != .None {
		errorf(
			k.c,
			expr_span(e),
			"L0690",
			sym.borrowed_binding == .Switch_Payload ? "`%s` views the payload of a switch over a place, which still owns it; `switch (move(...))` hands it over first" :
				"`%s` views an element a `foreach` source still owns; take the element out of the source instead",
			form,
		)
		add_notef(k.c, sym.span, "bound here")
		return false
	}
	if sym.kind == .Parameter && sym.mode != .Move {
		errorf(
			k.c,
			expr_span(e),
			"L0499",
			"`%s` borrows `%s`, so this body does not own it; `move` at the call site is what transfers ownership",
			form,
			identifier_text(k.c, sym.name),
		)
		add_notef(k.c, sym.span, "declared here")
		return false
	}
	return true
}


// `exchange` replaces a live value and returns the old one without cloning.
check_exchange_builtin :: proc(k: ^Checker, v: ^Expr_Call) {
	if len(v.args) != 2 {
		errorf(k.c, v.span, "L0505", "`exchange` takes a destination place and its replacement")
		return
	}
	if v.args[0].mode != .Inout {
		errorf(
			k.c,
			v.args[0].span,
			"L0505",
			"`exchange` replaces the destination, so it is written `exchange(inout place, replacement)`",
		)
		return
	}
	if v.args[0].name.text != "" || v.args[1].name.text != "" {
		errorf(k.c, v.span, "L0505", "`exchange` takes positional arguments only")
		return
	}
	if v.args[1].mode != .Value {
		errorf(k.c, v.args[1].span, "L0505", "`exchange`'s replacement is passed by value")
		return
	}

	destination := check_single_expr(k, v.args[0].value)
	if destination == INVALID_TYPE {
		return
	}
	base := expr_base(v.args[0].value)
	if base == nil || !base.assignable {
		report_not_assignable(k, base, "the destination of an `exchange`")
		return
	}
	replacement := v.args[1].value
	if !check_value_expr(k, replacement, destination, "exchange into") {
		return
	}
	// design.md "Exchange": the replacement's bits are stored, and a place would
	// go on owning them.
	if expression_is_borrowed_place(replacement) && type_is_managed(k.c, copied_type(replacement, destination)) {
		errorf(
			k.c,
			expr_span(replacement),
			"L0501",
			"`exchange` takes ownership of its replacement and copies nothing, so a place is written `move(...)`, or `.clone()` for a copy",
		)
		return
	}

	v.bound = bound_exprs(k, v.args[0].value, replacement)
	v.type = destination
	contribute_lifecycle_members(k, destination)
}

// Move values across container capacity whose liveness the compiler cannot track.
check_capacity_builtin :: proc(k: ^Checker, v: ^Expr_Call, kind: Builtin_Kind) {
	taking := kind == .Unsafe_Take
	name := taking ? "unsafe.take" : "unsafe.write"
	wanted := taking ? 1 : 2
	if len(v.args) != wanted {
		errorf(
			k.c, v.span, "L0692",
			taking ? "`unsafe.take` takes one argument, the place the value is read out of" :
				"`unsafe.write` takes the place and the value written into it",
		)
		return
	}
	for argument in v.args {
		if argument.name.text != "" || argument.mode != .Value {
			errorf(k.c, v.span, "L0692", "`%s` takes positional arguments only", name)
			return
		}
	}
	place := check_single_expr(k, v.args[0].value)
	if place == INVALID_TYPE {
		return
	}
	base := expr_base(v.args[0].value)
	if base == nil || !base.assignable {
		report_not_assignable(k, base, taking ? "the place `unsafe.take` reads" : "the place `unsafe.write` fills")
		return
	}
	if _, is_ident := v.args[0].value.(^Expr_Ident); is_ident {
		errorf(
			k.c, expr_span(v.args[0].value), "L0692",
			"`%s` reaches storage whose liveness is not tracked, and a variable's is; %s",
			name, taking ? "`move` takes a variable's value out" : "an ordinary assignment fills it",
		)
		return
	}
	bound := make([]Expr, wanted, k.c.semantic_allocator)
	bound[0] = v.args[0].value
	if !taking {
		if !check_value_expr(k, v.args[1].value, place, "write into") {
			return
		}
		classify_costed_copy(k, v.args[1].value, place, .Write)
		bound[1] = v.args[1].value
	}
	v.bound = bound
	v.type = taking ? place : TYPE_VOID
	if taking {
		contribute_lifecycle_members(k, place)
	}
}

// ------------------------------------------------- ownership at the call --

// A place passed to a `move` parameter must spell the transfer.
require_argument_ownership :: proc(
	k: ^Checker, v: ^Expr_Call, declaration: Symbol_Id, signature: ^Type_Info = nil,
) {
	sym := symbol_of(k.c, declaration)
	info := signature
	if info == nil && sym != nil {
		info = type_of(k.c, sym.proc_type)
	}
	if info == nil {
		return
	}
	first := 0
	if sym != nil && sym.has_receiver && sym.receiver != .Move {
		first = 1 // an `inout` receiver's marker is implicit in method-call syntax
	}
	for slot in first ..< len(v.bound) {
		if param_mode_at(info, slot) != .Move {
			continue
		}
		argument := v.bound[slot]
		if argument == nil {
			continue
		}
		if expression_is_owned_argument(argument) {
			continue
		}
		// A call through a procedure value has no declaration to name the parameter.
		name := "this parameter"
		if sym != nil && slot < len(sym.param_symbols) {
			if parameter := symbol_of(k.c, sym.param_symbols[slot]); parameter != nil {
				name = fmt.tprintf("`%s`", identifier_text(k.c, parameter.name))
			}
		}
		errorf(
			k.c,
			expr_span(argument),
			"L0501",
			"%s is a `move` parameter, so this argument is written `move(...)`",
			name,
		)
	}
}

// The variable a place is rooted in; INVALID_SYMBOL for a temporary or through a dereference.
place_root_symbol :: proc(e: Expr) -> Symbol_Id {
	#partial switch v in e {
	case ^Expr_Ident:
		return v.symbol
	case ^Expr_Selector:
		return place_root_symbol(v.operand)
	case ^Expr_Index:
		// A value-returning `operator([])` produces a temporary, not a place.
		if v.resolution.kind == .User_Operator && v.value_category != .Place {
			return INVALID_SYMBOL
		}
		return place_root_symbol(v.operand)
	}
	return INVALID_SYMBOL
}

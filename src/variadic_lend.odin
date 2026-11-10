// design.md "Variadic parameters": a `..^T` pack lends what is written at the call.
// Each value of type `T` is borrowed where it is, or from a temporary holding it, as
// the `view_from` conversion does elsewhere, and a spread of `T`s lends each of its
// elements. Nothing is copied, so a callee may copy each value fallibly.
package lokec

// The `T` a `..^T` pack lends values as: a read-only `^T` element.
variadic_lent_pointee :: proc(c: ^Compiler, element: Type_Id) -> (Type_Id, bool) {
	info := underlying_info(c, element)
	if info == nil || info.kind != .Pointer || info.mutable || info.element == INVALID_TYPE {
		return INVALID_TYPE, false
	}
	return info.element, true
}

// Whether a value of type `from` written into a `..^T` pack is lent as a `^T`: one
// of type `T`, or an unfixed constant that fixes at it. A value already a `^T` is
// passed as it is. `nil` is the null address, not an unfixed constant (design.md
// "Unfixed constants"), so it is never lent, even into a `..^rawptr` pack.
variadic_lend_accepts :: proc(c: ^Compiler, from, element: Type_Id) -> bool {
	pointee, lends := variadic_lent_pointee(c, element)
	if !lends || from == INVALID_TYPE || assignable(c, from, element) {
		return false
	}
	if type_is_untyped(c, from) {
		return from != TYPE_UNTYPED_NIL && assignable(c, from, pointee)
	}
	return from == pointee
}

// The slice type a spread of type `from` into `pack` is checked and held as, and
// whether the pack lends its elements: a `..^T` pack lends those of a spread that
// is a `[]T`, or views as one, rather than the `[]^T` the pack is. Any other spread
// is the pack's own type. Once checked, a lending spread's type is that `[]T`.
variadic_spread_type :: proc(c: ^Compiler, from, pack: Type_Id) -> (Type_Id, bool) {
	pointee, lends := variadic_lent_pointee(c, slice_element(c, pack))
	if !lends || from == INVALID_TYPE || assignable(c, from, pack) {
		return pack, false
	}
	lent := slice_of(c, pointee, false)
	if !assignable(c, from, lent) {
		return pack, false
	}
	return lent, true
}

// A pack element's base once it is checked against `expected`, unless ranking
// already checked it, or nil if it has no type. Shared with `..dyn I` packs.
checked_pack_element :: proc(k: ^Checker, e: Expr, expected: Type_Id, prechecked: bool) -> ^Expr_Base {
	if !prechecked && check_single_expr(k, e, expected) == INVALID_TYPE {
		return nil
	}
	base := expr_base(e)
	return base != nil && base.type != INVALID_TYPE ? base : nil
}

// One element of a `..^T` pack: a `T` is borrowed, an unfixed constant fixed at
// `T` first, in a temporary that lives through the call.
pass_lent_element :: proc(k: ^Checker, e: Expr, element, pointee: Type_Id, prechecked: bool) -> (Expr, bool) {
	base := checked_pack_element(k, e, pointee, prechecked)
	if base == nil {
		return e, false
	}
	if !variadic_lend_accepts(k.c, base.type, element) {
		return e, materialize_argument(k, e, element)
	}
	if type_is_untyped(k.c, base.type) && !materialize(k, e, pointee) {
		return e, false
	}
	// A named constant is lent in its read-only storage; another is a temporary.
	if base_is_const(base) {
		request_materialization(k, e)
	}
	base.view_from = base.type
	base.type = element
	return e, true
}

// design.md "Variadic parameters": the type a spread operand lends as in `pack`.
// A spread a `..^T` pack lends the elements of points where it points, as one
// `^T` element whose targets are the spread's, and any other at the pack's type.
prov_pack_spread_type :: proc(c: ^Compiler, spread, pack: Type_Id) -> Type_Id {
	_, lends := variadic_spread_type(c, spread, pack)
	return lends ? slice_element(c, pack) : pack
}

// design.md "Variadic parameters": the `T` of a `..^T` pack at parameter `index`
// of `proc_type`, which lends its values only for the call.
proc_param_lent_type :: proc(c: ^Compiler, proc_type: Type_Id, index: int) -> (Type_Id, bool) {
	info := underlying_info(c, proc_type)
	if info == nil || index >= len(info.parameters) || param_mode_at(info, index) != .Variadic {
		return INVALID_TYPE, false
	}
	return variadic_lent_pointee(c, slice_element(c, info.parameters[index]))
}

// Whether parameter symbol `sym` is a `..^T` pack.
param_symbol_lends :: proc(c: ^Compiler, sym: ^Symbol) -> bool {
	if sym == nil || sym.kind != .Parameter || sym.mode != .Variadic {
		return false
	}
	_, lends := variadic_lent_pointee(c, slice_element(c, sym.type))
	return lends
}

// Whether a loan of a `..^T` pack names its own storage or what one of its pointers
// names, which a call may not keep at any escape level: only what the lent values
// hold, one load further, is bounded by the level.
loan_names_lent_value :: proc(loan: Prov_Loan) -> bool {
	return !loan.content || loan.depth <= 1
}

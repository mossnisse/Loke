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

// design.md "Variadic parameters": what of a pack parameter is a temporary of the
// call, which neither its result nor storage that outlives the call may borrow at
// any escape level. Every pack's own storage is; a `..^T` pack's pointers also
// name values lent for the call, one load further. Only what `held` holds, below
// that, is bounded by the parameter's escape level.
Pack_Lending :: struct {
	// The type whose borrows a call may keep: a `..T` pack's `T`, and a `..^T`
	// pack's `T` too.
	held:  Type_Id,
	// The deepest content loan of the parameter that names lent storage: 0 when
	// only the pack's own storage is, its non-content loan, and 1 for `..^T`.
	depth: int,
}

// The lending of a pack the body receives as `pack`, a `[]T` or `[]^T`.
pack_lending :: proc(c: ^Compiler, pack: Type_Id) -> Pack_Lending {
	element := slice_element(c, pack)
	if pointee, lends := variadic_lent_pointee(c, element); lends {
		return Pack_Lending{held = pointee, depth = 1}
	}
	return Pack_Lending{held = element, depth = 0}
}

// The lending of parameter `index` of `proc_type`, if it is a pack.
proc_param_pack_lending :: proc(c: ^Compiler, proc_type: Type_Id, index: int) -> (Pack_Lending, bool) {
	info := underlying_info(c, proc_type)
	if info == nil || index >= len(info.parameters) || param_mode_at(info, index) != .Variadic {
		return {}, false
	}
	return pack_lending(c, info.parameters[index]), true
}

// The lending of parameter symbol `sym`, if it is a pack.
param_symbol_pack_lending :: proc(c: ^Compiler, sym: ^Symbol) -> (Pack_Lending, bool) {
	if sym == nil || sym.kind != .Parameter || sym.mode != .Variadic {
		return {}, false
	}
	return pack_lending(c, sym.type), true
}

// Whether a loan of a pack parameter names its own storage or, of a `..^T` pack,
// what one of its pointers names.
loan_names_lent_value :: proc(loan: Prov_Loan, lending: Pack_Lending) -> bool {
	return !loan.content || loan.depth <= lending.depth
}

// Whether a result that depends on pack parameter `index` as `dependencies` say may
// borrow what `lending` says the pack lends: the pack itself, or a value one of its
// pointers names (bit `depth - 1` of `param_loads` is a load `depth` deep).
result_borrows_lent :: proc(dependencies: Result_Dependencies, index: int, lending: Pack_Lending) -> bool {
	if index >= len(dependencies.params) {
		return false
	}
	lent := (u8(1) << u8(lending.depth)) - 1
	return dependencies.params[index] || dependencies.param_loads[index] & lent != 0
}

// The phrases of a diagnostic about a pack reaching what outlives the call, for
// `lending`: what the pack lends, then what may not reach there.
pack_lent_phrases :: proc(lending: Pack_Lending) -> (lends, reaches: string) {
	if lending.depth > 0 {
		return "lends its values only for the call", "neither it nor a pointer in it can reach"
	}
	return "is a pack that lives only for the call", "it cannot reach"
}

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
// passed as it is.
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

// Whether a spread of type `from` into a `..^T` pack lends its elements: one that
// spreads as a `[]T`, rather than as the `[]^T` the pack is.
variadic_spread_lends :: proc(c: ^Compiler, from, pack: Type_Id) -> bool {
	pointee, lends := variadic_lent_pointee(c, slice_element(c, pack))
	return lends && from != INVALID_TYPE && !assignable(c, from, pack) && assignable(c, from, slice_of(c, pointee, false))
}

// The slice type a spread into `pack` is checked as: the `[]T` whose elements a
// `..^T` pack lends, when the spread is not already a `[]^T`.
variadic_spread_type :: proc(c: ^Compiler, from, pack: Type_Id) -> Type_Id {
	if variadic_spread_lends(c, from, pack) {
		pointee, _ := variadic_lent_pointee(c, slice_element(c, pack))
		return slice_of(c, pointee, false)
	}
	return pack
}

// One element of a `..^T` pack: a `T` is borrowed, an unfixed constant fixed at
// `T` first, in a temporary that lives through the call.
pass_lent_element :: proc(k: ^Checker, e: Expr, element, pointee: Type_Id, prechecked: bool) -> (Expr, bool) {
	if !prechecked && check_single_expr(k, e, pointee) == INVALID_TYPE {
		return e, false
	}
	base := expr_base(e)
	if base == nil || base.type == INVALID_TYPE {
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

// Whether the checked spread `spread` into `pack` lends its elements.
variadic_pack_spread_lends :: proc(c: ^Compiler, spread: Expr, pack: Type_Id) -> bool {
	base := expr_base(spread)
	return base != nil && base.type != pack && variadic_spread_lends(c, base.type, pack)
}

@(private)
slice_clone_expr :: proc(k: ^Checker, e: Expr) -> []Expr {
	out := make([]Expr, 1, k.c.semantic_allocator)
	out[0] = e
	return out
}

@(private)
slice_clone_bool :: proc(k: ^Checker, value: bool) -> []bool {
	out := make([]bool, 1, k.c.semantic_allocator)
	out[0] = value
	return out
}

// design.md "Variadic parameters": the type a spread operand lends as in `pack`.
// A spread a `..^T` pack lends the elements of points where it points, as one
// `^T` element whose targets are the spread's, and any other at the pack's type.
prov_pack_spread_type :: proc(c: ^Compiler, spread, pack: Type_Id) -> Type_Id {
	return spread != pack && variadic_spread_lends(c, spread, pack) ? slice_element(c, pack) : pack
}

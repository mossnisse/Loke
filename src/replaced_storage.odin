// Destinations of one multiple assignment that lie in storage another owns.
package lokec

// design.md "Evaluation order": every destination is prepared before the first
// write, so one that lies in storage an earlier destination's write replaces,
// as `d[1]` in `d, d[1] = other, 9;`, would be written after that storage is
// dropped.
reject_replaced_destinations :: proc(k: ^Checker, s: ^Stmt_Assign) {
	for later, at in s.lhs {
		for earlier in s.lhs[:at] {
			if !is_discard(earlier) && in_replaced_storage(k.c, earlier, later) {
				errorf(
					k.c, expr_span(earlier), "L0512", "`%s` cannot be assigned here: the later destination `%s` is in storage this write replaces",
					source_text(k.c, earlier), source_text(k.c, later),
				)
				add_notef(k.c, expr_span(later), "this destination is prepared before the first write, in the storage it held then")
				return
			}
		}
	}
}

// Whether writing `outer` may drop the storage `inner` is in: `inner` is
// reached from a place that may be `outer` through storage that place owns
// apart from its own, a dynamic array's or map's elements, a box's payload, or
// what a user `operator([])` returns. A field or a fixed array's element is part
// of its owner, and a pointer or a slice reaches another root. Inserting
// `m[key]` may move every entry of `m`, so it replaces what `m` owns.
@(private = "file")
in_replaced_storage :: proc(c: ^Compiler, outer, inner: Expr) -> bool {
	replaced, operand := outer, false
	if index, is_index := outer.(^Expr_Index); is_index && index.map_inserts {
		replaced, operand = index.operand, true
	}
	owned := false
	place := inner
	for {
		parent, owns, pointee := place_owner(c, place)
		if parent == nil {
			return false
		}
		owned ||= owns
		if owned && places_may_overlap(c, replaced, parent, operand, true) {
			return true
		}
		if pointee {
			return false
		}
		place = parent
	}
}

// Whether `place` is in storage some place it is part of owns apart from its
// own, so that writing that place, or a carrier to it, may drop it.
in_owned_storage :: proc(c: ^Compiler, place: Expr) -> bool {
	for at := place; at != nil; {
		parent, owns, pointee := place_owner(c, at)
		if owns || pointee {
			return owns
		}
		at = parent
	}
	return false
}

// The place `place` is part of, read as an operand, and whether it is in
// storage of that place's own allocation; nil where it is no part of a place a
// variable roots. `pointee` is set where that operand is a pointer a selector or
// index dereferences, the root of another place.
@(private = "file")
place_owner :: proc(c: ^Compiler, place: Expr) -> (parent: Expr, owns, pointee: bool) {
	#partial switch v in place {
	case ^Expr_Selector:
		if v.resolution.kind != .Field && v.variant_union == INVALID_TYPE {
			return
		}
		return storage_owner(c, v.operand, false)
	case ^Expr_Index:
		parent, owns, pointee = storage_owner(c, v.operand, v.resolution.kind == .User_Operator)
		// `m[key] = elem` inserts into the map's own place when it writes.
		return parent, owns && !v.map_inserts, pointee
	case ^Expr_Postfix:
		if v.op == .Caret && v.boxed {
			return v.operand, true, false
		}
	}
	return
}

// `operand` as the place a field or element is part of; a user operator's
// result, `user_result`, may be anywhere it owns.
@(private = "file")
storage_owner :: proc(c: ^Compiler, operand: Expr, user_result: bool) -> (parent: Expr, owns, pointee: bool) {
	base := expr_base(operand)
	if base == nil {
		return
	}
	type := base.type
	if element := pointee_of(c, type); element != INVALID_TYPE {
		type, pointee = element, true
	}
	#partial switch underlying_kind(c, type) {
	case .Dynamic_Array, .Map, .Box:
		return operand, true, pointee
	case .Struct, .Union, .Array, .Simd:
		return operand, user_result, pointee
	}
	return nil, false, false
}

// Whether `a` and `b` may name one place: the same variable, then the same
// fields, with indices that are not two different constants of a built-in
// index. `x^`, and a pointer an operand (`a_operand`, `b_operand`) of a
// selector or index dereferences, name the place the pointer does.
@(private = "file")
places_may_overlap :: proc(c: ^Compiler, a, b: Expr, a_operand := false, b_operand := false) -> bool {
	x, y := dereferenced(c, a, a_operand), dereferenced(c, b, b_operand)
	if x != nil || y != nil {
		return x != nil && y != nil && places_may_overlap(c, x, y)
	}
	#partial switch first in a {
	case ^Expr_Ident:
		second, same := b.(^Expr_Ident)
		return same && first.symbol != INVALID_SYMBOL && first.symbol == second.symbol
	case ^Expr_Selector:
		second, same := b.(^Expr_Selector)
		return same && first.name.id == second.name.id && places_may_overlap(c, first.operand, second.operand, true, true)
	case ^Expr_Postfix:
		second, same := b.(^Expr_Postfix)
		return same && first.op == .Caret && second.op == .Caret && places_may_overlap(c, first.operand, second.operand)
	case ^Expr_Index:
		second, same := b.(^Expr_Index)
		if !same || len(first.indices) != len(second.indices) || !places_may_overlap(c, first.operand, second.operand, true, true) {
			return false
		}
		// A user `operator([])` may return one place for different arguments.
		if first.resolution.kind == .User_Operator {
			return true
		}
		for index, at in first.indices {
			i, j := expr_base(index), expr_base(second.indices[at])
			if i != nil && j != nil && base_is_const(i) && base_is_const(j) {
				equal, comparable := fold_comparison(c, .Eq_Eq, i.const_value, j.const_value)
				if comparable && !equal {
					return false
				}
			}
		}
		return true
	}
	return false
}

// The pointer whose pointee `place` names: `p` in `p^`, or `place` itself where
// it is a pointer the selector or index it is the `operand` of dereferences.
@(private = "file")
dereferenced :: proc(c: ^Compiler, place: Expr, operand: bool) -> Expr {
	if v, is_postfix := place.(^Expr_Postfix); is_postfix && v.op == .Caret && !v.boxed {
		return v.operand
	}
	if base := expr_base(place); operand && base != nil && pointee_of(c, base.type) != INVALID_TYPE {
		return place
	}
	return nil
}

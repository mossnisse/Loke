// Constant-value operations, shared by the checker and the compile-time
// evaluator (m3-plan decision "Fold ownership").
//
// Nothing here knows about `Checker`: leaf and operator folding stay in
// `check_expr.odin`, but the *value* semantics — one operator table, one
// wrapping rule, one comparison order — live here so `eval.odin` cannot
// develop a second, subtly different arithmetic.
package lokec

import "core:strings"

fold_arithmetic :: proc(
	c: ^Compiler,
	op: Token_Kind,
	op_span: Span,
	a, b: Const_Value,
	type: Type_Id,
) -> (Const_Value, bool) {
	if a.kind == .String || b.kind == .String {
		// design.md: `+` joins two compile-time strings, and nothing else applies
		// to them. Runtime text operations belong to `string`, not to this.
		if op != .Plus || a.kind != .String || b.kind != .String {
			errorf(c, op_span, "L0355", "`%s` does not apply to `%s`", operator_text(op), type_name(c, type))
			return Const_Value{}, false
		}
		joined := strings.concatenate({a.text, b.text}, c.semantic_allocator)
		return Const_Value{kind = .String, text = joined}, true
	}

	if a.kind == .Float || b.kind == .Float {
		bits := u16(type_bits(c, type))
		if type_is_untyped(c, type) {
			bits = 64
		}
		x, y := a.float, b.float
		result: f64
		#partial switch op {
		case .Plus:
			result = x + y
		case .Minus:
			result = x - y
		case .Star:
			result = x * y
		case .Slash:
			// design.md "Floating-point operators": IEEE-754, and no panic.
			result = x / y
		case:
			errorf(c, op_span, "L0355", "`%s` does not apply to `%s`", operator_text(op), type_name(c, type))
			return Const_Value{}, false
		}
		return float_const(result, bits), true
	}

	if (op == .Slash || op == .Percent) && bi_is_zero(b.integer) {
		errorf(c, op_span, "L0319", "division by zero")
		return Const_Value{}, false
	}

	x, y := a.integer, b.integer
	result: Big_Int
	#partial switch op {
	case .Plus:
		result = bi_add(c, x, y)
	case .Minus:
		result = bi_sub(c, x, y)
	case .Star:
		result = bi_mul(c, x, y)
	case .Slash:
		result = bi_quo(c, x, y)
	case .Percent:
		result = bi_rem(c, x, y)
	case .Amp:
		result = bi_and(c, x, y)
	case .Pipe:
		result = bi_or(c, x, y)
	case .Tilde:
		result = bi_xor(c, x, y)
	case .Amp_Tilde:
		result = bi_and_not(c, x, y)
	case:
		errorf(c, op_span, "L0355", "`%s` does not apply to `%s`", operator_text(op), type_name(c, type))
		return Const_Value{}, false
	}
	return Const_Value{kind = a.kind, integer = wrap_to_type(c, result, type)}, true
}

// A typed integer operation is computed exactly and then projected modulo its
// own width, which is what makes folding agree with the wrapping arithmetic the
// backend emits (design.md "Integer overflow"). An untyped operation keeps its
// exact value.
wrap_to_type :: proc(c: ^Compiler, value: Big_Int, type: Type_Id) -> Big_Int {
	if type_is_untyped(c, type) {
		return value
	}
	bits := type_bits(c, type)
	if bits <= 0 {
		return value
	}
	return bi_wrap(c, value, bits, type_signed(c, type))
}

fold_comparison :: proc(c: ^Compiler, op: Token_Kind, a, b: Const_Value) -> (bool, bool) {
	order := 0
	switch {
	case a.kind == .String || b.kind == .String:
		if a.kind != .String || b.kind != .String {
			return false, false
		}
		// Byte order, which is what `<` on a compile-time string means.
		order = compare_strings(a.text, b.text)
	case a.kind == .Float || b.kind == .Float:
		x := a.kind == .Float ? a.float : bi_to_f64(c, a.integer)
		y := b.kind == .Float ? b.float : bi_to_f64(c, b.integer)
		// NaN compares false against everything, including itself.
		if x != x || y != y {
			return op == .Not_Eq, true
		}
		order = x < y ? -1 : (x > y ? 1 : 0)
	case a.kind == .Integer || a.kind == .Rune:
		if b.kind != .Integer && b.kind != .Rune {
			return false, false
		}
		order = bi_cmp(c, a.integer, b.integer)
	case a.kind == .Boolean:
		if b.kind != .Boolean {
			return false, false
		}
		if op != .Eq_Eq && op != .Not_Eq {
			return false, false
		}
		return (a.boolean == b.boolean) == (op == .Eq_Eq), true
	case a.kind == .Nil && b.kind == .Nil:
		return op == .Eq_Eq, true
	// design.md: two `type` values compare during compilation, and equality means
	// the same Loke type identity after aliases are resolved. A symbolic `typeid`
	// constant carries the same identity, so both fold here.
	case a.kind == .Type && b.kind == .Type:
		if op != .Eq_Eq && op != .Not_Eq {
			return false, false
		}
		return (a.type_value == b.type_value) == (op == .Eq_Eq), true
	case a.kind == .Aggregate && b.kind == .Aggregate:
		if op != .Eq_Eq && op != .Not_Eq {
			return false, false
		}
		equal := aggregate_equal(c, a.aggregate, b.aggregate)
		return equal == (op == .Eq_Eq), true
	case:
		return false, false
	}

	#partial switch op {
	case .Eq_Eq:
		return order == 0, true
	case .Not_Eq:
		return order != 0, true
	case .Lt:
		return order < 0, true
	case .Lt_Eq:
		return order <= 0, true
	case .Gt:
		return order > 0, true
	case .Gt_Eq:
		return order >= 0, true
	}
	return false, false
}

@(private = "file")
compare_strings :: proc(a, b: string) -> int {
	limit := min(len(a), len(b))
	for i in 0 ..< limit {
		if a[i] != b[i] {
			return a[i] < b[i] ? -1 : 1
		}
	}
	if len(a) == len(b) {
		return 0
	}
	return len(a) < len(b) ? -1 : 1
}

@(private = "file")
aggregate_equal :: proc(c: ^Compiler, a, b: ^Const_Aggregate) -> bool {
	if a == nil || b == nil || len(a.elements) != len(b.elements) {
		return false
	}
	for element, index in a.elements {
		equal, ok := fold_comparison(c, .Eq_Eq, element, b.elements[index])
		if !ok || !equal {
			return false
		}
	}
	return true
}

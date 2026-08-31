// Constant-value operations, shared by the checker and the compile-time
// evaluator.
//
// Nothing here knows about `Checker`: leaf and operator folding stay in
// `check_expr.odin`, but the *value* semantics — one operator table, one
// wrapping rule, one comparison order — live here so `eval.odin` cannot
// develop a second, subtly different arithmetic.
package lokec

import "core:mem"
import "core:strings"

value_allocator :: proc(c: ^Compiler, requested: mem.Allocator) -> mem.Allocator {
	return requested.procedure == nil ? c.semantic_allocator : requested
}

fold_arithmetic :: proc(
	c: ^Compiler,
	op: Token_Kind,
	op_span: Span,
	a, b: Const_Value,
	type: Type_Id,
	allocator: mem.Allocator = {},
) -> (Const_Value, bool) {
	storage := value_allocator(c, allocator)
	if a.kind == .String || b.kind == .String {
		// design.md: `+` joins two compile-time strings, and nothing else applies
		// to them. Runtime text operations belong to `string`, not to this.
		if op != .Plus || a.kind != .String || b.kind != .String {
			errorf(c, op_span, "L0355", "`%s` does not apply to `%s`", operator_text(op), type_name(c, type))
			return Const_Value{}, false
		}
		joined, err := strings.concatenate({a.text, b.text}, storage)
		return Const_Value{kind = .String, text = joined}, err == nil
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
		result = bi_add(storage, x, y)
	case .Minus:
		result = bi_sub(storage, x, y)
	case .Star:
		result = bi_mul(storage, x, y)
	case .Slash:
		result = bi_quo(storage, x, y)
	case .Percent:
		result = bi_rem(storage, x, y)
	case .Amp:
		result = bi_and(storage, x, y)
	case .Pipe:
		result = bi_or(storage, x, y)
	case .Tilde:
		result = bi_xor(storage, x, y)
	case .Amp_Tilde:
		result = bi_and_not(storage, x, y)
	case .Shl, .Shr:
		// An exact untyped result past this width would need more storage than the
		// compiler is willing to spend; every runtime type saturates long before it.
		count, fits := bi_to_u64(storage, y)
		if !fits || count > 1 << 20 {
			errorf(c, op_span, "L0356", "shift count %s is too large to fold", bi_text(storage, y))
			return Const_Value{}, false
		}
		result = op == .Shl ? bi_shl(storage, x, int(count)) : bi_shr(storage, x, int(count))
	case:
		errorf(c, op_span, "L0355", "`%s` does not apply to `%s`", operator_text(op), type_name(c, type))
		return Const_Value{}, false
	}
	return Const_Value{kind = a.kind, integer = wrap_to_type(c, result, type, storage)}, true
}

// A typed integer operation is computed exactly and then projected modulo its
// own width, which is what makes folding agree with the wrapping arithmetic the
// backend emits (design.md "Integer overflow"). An untyped operation keeps its
// exact value.
wrap_to_type :: proc(c: ^Compiler, value: Big_Int, type: Type_Id, allocator: mem.Allocator = {}) -> Big_Int {
	if type_is_untyped(c, type) {
		return value
	}
	bits := type_bits(c, type)
	if bits <= 0 {
		return value
	}
	return bi_wrap(value_allocator(c, allocator), value, bits, type_signed(c, type))
}

fold_comparison :: proc(c: ^Compiler, op: Token_Kind, a, b: Const_Value, allocator: mem.Allocator = {}) -> (bool, bool) {
	storage := value_allocator(c, allocator)
	order := 0
	switch {
	case a.kind == .String || b.kind == .String:
		if a.kind != .String || b.kind != .String {
			return false, false
		}
		// Byte order, which is what `<` on a compile-time string means.
		order = strings.compare(a.text, b.text)
	case a.kind == .Float || b.kind == .Float:
		x := a.kind == .Float ? a.float : bi_to_f64(storage, a.integer)
		y := b.kind == .Float ? b.float : bi_to_f64(storage, b.integer)
		// NaN compares false against everything, including itself.
		if x != x || y != y {
			return op == .Not_Eq, true
		}
		order = x < y ? -1 : (x > y ? 1 : 0)
	case a.kind == .Integer || a.kind == .Rune:
		if b.kind != .Integer && b.kind != .Rune {
			return false, false
		}
		order = bi_cmp(storage, a.integer, b.integer)
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
		equal := aggregate_equal(c, a.aggregate, b.aggregate, storage)
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
aggregate_equal :: proc(c: ^Compiler, a, b: ^Const_Aggregate, allocator: mem.Allocator = {}) -> bool {
	if a == nil || b == nil || len(a.elements) != len(b.elements) {
		return false
	}
	// design.md "Unions": two union values are equal only when they hold the
	// same *variant*. Two variants may share a payload type, so comparing the
	// payloads alone would make `.left(3)` equal `.right(3)`.
	if a.variant != b.variant && type_is_union(c, a.type) {
		return false
	}
	for element, index in a.elements {
		equal, ok := fold_comparison(c, .Eq_Eq, element, b.elements[index], allocator)
		if !ok || !equal {
			return false
		}
	}
	return true
}

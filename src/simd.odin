// `Simd(T, N)`: its element and lane-count rules, its lane-wise operators, and
// the `core:simd` intrinsics (design.md "SIMD vectors").
//
// `Simd` is predeclared, so it needs no import and can be shadowed.
package lokec

import "core:reflect"

SIMD_MAX_LANES :: 64
SIMD_MAX_BYTES :: 64

// The predeclared `Simd`, not a user declaration that shares the name.
simd_callee :: proc(k: ^Checker, callee: Expr) -> bool {
	ident, is_ident := callee.(^Expr_Ident)
	if !is_ident || ident.name != "Simd" {
		return false
	}
	return lookup_symbol(k.scope, identifier_of(k.c, ident)) == INVALID_SYMBOL
}

// `Simd(T, N)` in type position. Reports rather than staying silent: once the
// name is the predeclared one there is no other reading to fall back to.
resolve_simd_application :: proc(k: ^Checker, v: ^Expr_Call) -> Type_Id {
	if v.denoted_type != INVALID_TYPE {
		return v.denoted_type
	}
	if len(v.args) != 2 || v.args[0].name.text != "" || v.args[1].name.text != "" ||
	   v.args[0].mode != .Value || v.args[1].mode != .Value {
		errorf(k.c, v.span, "L0681", "`Simd` takes an element type and a lane count, as in `Simd(f32, 4)`")
		return INVALID_TYPE
	}
	element := resolve_type_reporting(k, v.args[0].value)
	if element == INVALID_TYPE {
		return INVALID_TYPE
	}
	if !simd_element_permitted(k.c, element) {
		errorf(
			k.c, expr_span(v.args[0].value), "L0682",
			"`%s` is not a SIMD lane type; lanes are `bool`, an integer up to 64 bits, or a float",
			type_name(k.c, element),
		)
		return INVALID_TYPE
	}
	count, counted := constant_count(k, v.args[1].value, "a SIMD lane count", "L0683")
	if !counted || !simd_lane_count_permitted(k, v.args[1].value, element, count) {
		return INVALID_TYPE
	}
	v.denoted_type = simd_of(k.c, element, count)
	v.resolution.kind = .Type
	v.value_category = .Type
	return v.denoted_type
}

@(private = "file")
simd_element_permitted :: proc(c: ^Compiler, element: Type_Id) -> bool {
	info := underlying_info(c, element)
	if info == nil {
		return false
	}
	#partial switch info.kind {
	case .Bool, .Float:
		return true
	case .Int:
		return info.bits <= 64
	}
	return false
}

@(private = "file")
simd_lane_count_permitted :: proc(k: ^Checker, written: Expr, element: Type_Id, count: u64) -> bool {
	if count == 0 || count > SIMD_MAX_LANES || (count & (count - 1)) != 0 {
		errorf(
			k.c, expr_span(written), "L0683",
			"a SIMD lane count is a power of two from 1 through %d, found %d",
			SIMD_MAX_LANES, count,
		)
		return false
	}
	if bytes := type_size(k.c, element) * count; bytes > SIMD_MAX_BYTES {
		errorf(
			k.c, expr_span(written), "L0683",
			"`Simd(%s, %d)` is %d bytes; a SIMD vector is at most %d",
			type_name(k.c, element), count, bytes, SIMD_MAX_BYTES,
		)
		return false
	}
	return true
}

type_is_simd :: proc(c: ^Compiler, id: Type_Id) -> bool {
	return underlying_kind(c, id) == .Simd
}

// Nominal, where `type_is_simd` reaches through: a `distinct` type inherits
// none of the underlying type's operations, so `distinct Simd(f32, 4)` reaches
// the operators and the intrinsics through an overload, as `distinct f64` does.
// `builtin_operator_applies` rejects `.Distinct` the same way, and the two must
// answer alike or `v += x` and `v = v + x` would disagree.
simd_operand :: proc(c: ^Compiler, id: Type_Id) -> bool {
	return type_kind(c, id) == .Simd
}

// `v[i]`. The index must be a constant in range: a dynamic lane index has no
// efficient lowering and hides a store-and-reload the source did not write.
check_simd_index :: proc(
	k: ^Checker, v: ^Expr_Index, info: ^Type_Info, vector: Type_Id,
	operand: ^Expr_Base, through_pointer: bool, pointer_mutable: bool,
) {
	v.type = INVALID_TYPE
	if check_single_expr(k, v.indices[0], TYPE_INT) == INVALID_TYPE {
		return
	}
	if !materialize(k, v.indices[0], TYPE_INT) { return }
	index := expr_base(v.indices[0])
	if !type_is_integer(k.c, index.type) {
		errorf(k.c, expr_span(v.indices[0]), "L0684", "a lane index must be an integer, found `%s`", type_name(k.c, index.type))
		return
	}
	if index.const_value.kind != .Integer {
		errorf(
			k.c, expr_span(v.indices[0]), "L0684",
			"a lane index must be a constant; `%s` has %d lanes, and a runtime lane index has no efficient lowering",
			type_name(k.c, vector), info.count,
		)
		add_notef(k.c, v.span, "use a fixed array when the index is a runtime value")
		return
	}
	value, fits := bi_to_i64(k.c, index.const_value.integer)
	if !fits || value < 0 || u64(value) >= info.count {
		errorf(
			k.c, expr_span(v.indices[0]), "L0685",
			"lane %s is out of range for `%s`",
			bi_text(k.c, index.const_value.integer), type_name(k.c, vector),
		)
		return
	}

	v.type = info.element
	v.value_category = .Place
	inherit_capability(&v.base, operand, through_pointer, pointer_mutable)
	fold_constant_element(v, operand, value)
}

// ----------------------------------------------------------- operators --

// Lane-wise, both operands at one vector type after splatting. Answered ahead
// of the scalar table rather than by widening `type_is_numeric` and friends, so
// that "is this arithmetic?" keeps its meaning everywhere else in the checker.
check_simd_binary :: proc(k: ^Checker, v: ^Expr_Binary, lhs, rhs: Type_Id) {
	v.type = INVALID_TYPE
	v.resolution.kind = .Builtin_Operator
	vector := simd_operand(k.c, lhs) ? lhs : rhs
	other := vector == lhs ? rhs : lhs
	if type_is_simd(k.c, other) && other != vector {
		errorf(
			k.c, v.op_span, "L0686",
			"`%s` applies lane-wise to one vector type; `%s` and `%s` are different vector types",
			operator_text(v.op), type_name(k.c, lhs), type_name(k.c, rhs),
		)
		return
	}
	info := type_of(k.c, vector)
	// A shift's count splats like any other operand; the scalar rule that a count
	// keeps its own type has nothing lane-wise to mean.
	if !simd_splat_operands(k, v, vector, info.element) {
		return
	}
	if !simd_operator_applies(k.c, v.op, info.element) {
		errorf(
			k.c, v.op_span, "L0686",
			"`%s` does not apply to `%s` lanes",
			operator_text(v.op), type_name(k.c, info.element),
		)
		return
	}
	if reject_negative_count_lanes(k, v.op, v.rhs) || constant_zero_divisor(k, v.op, v.op_span, v.rhs) {
		return
	}
	#partial switch v.op {
	case .Eq_Eq, .Not_Eq, .Lt, .Lt_Eq, .Gt, .Gt_Eq:
		// A mask, not a `bool`: not an `if` condition until `simd.any` reduces it.
		v.type = simd_of(k.c, TYPE_BOOL, info.count)
	case:
		v.type = vector
	}
	fold_simd_binary(k, v)
}

// Whether `other` meets `vector` in a built-in lane-wise operator: `vector`
// itself, or a scalar that splats to it. `v + x` and `v += x` both ask, and an
// overload is found only where this says no.
simd_operand_is_builtin :: proc(c: ^Compiler, vector, other: Type_Id) -> bool {
	return other == vector || (!type_is_simd(c, other) && assignable(c, other, type_of(c, vector).element))
}

// design.md "Lane-wise operators": also serves `v <<= c`.
reject_negative_count_lanes :: proc(k: ^Checker, op: Token_Kind, count: Expr) -> bool {
	base := expr_base(count)
	if (op != .Shl && op != .Shr) || !base_is_const(base) {
		return false
	}
	for lane, index in base.const_value.aggregate.elements {
		if lane.kind == .Integer && bi_sign(lane.integer) < 0 {
			errorf(
				k.c, expr_span(count), "L0356", "a shift count cannot be negative, found %s in lane %d",
				bi_text(k.c, lane.integer), index,
			)
			return true
		}
	}
	return false
}

@(private = "file")
fold_simd_binary :: proc(k: ^Checker, v: ^Expr_Binary) {
	left, right := expr_base(v.lhs), expr_base(v.rhs)
	if !base_is_const(left) || !base_is_const(right) {
		return
	}
	info := underlying_info(k.c, v.type)
	elements := make([]Const_Value, info.count, k.c.semantic_allocator)
	for index in 0 ..< int(info.count) {
		a, b := left.const_value.aggregate.elements[index], right.const_value.aggregate.elements[index]
		#partial switch v.op {
		case .Eq_Eq, .Not_Eq, .Lt, .Lt_Eq, .Gt, .Gt_Eq:
			result, ok := fold_comparison(k.c, v.op, a, b)
			if !ok {
				return
			}
			elements[index] = bool_const(result)
		case:
			folded, ok := fold_arithmetic(k.c, v.op, v.op_span, a, b, info.element)
			if !ok {
				v.type = INVALID_TYPE
				return
			}
			elements[index] = folded
		}
	}
	set_simd_const(k, &v.base, elements)
}

@(private = "file")
set_simd_const :: proc(k: ^Checker, base: ^Expr_Base, elements: []Const_Value) {
	base.const_value = aggregate_const(k.c, base.type, elements)
}

// A scalar operand splats. Materialising it at the vector type makes a written
// constant the splat aggregate and records `splat_from` on a runtime scalar, so
// both operands reach the backend as the vector.
@(private = "file")
simd_splat_operands :: proc(k: ^Checker, v: ^Expr_Binary, vector, element: Type_Id) -> bool {
	ok := true
	for side in ([2]Expr{v.lhs, v.rhs}) {
		base := expr_base(side)
		if base.type == vector {
			continue
		}
		if !base_is_const(base) && !assignable(k.c, base.type, element) {
			errorf(
				k.c, v.op_span, "L0686",
				"`%s` is neither `%s` nor one of its lanes",
				type_name(k.c, base.type), type_name(k.c, vector),
			)
			ok = false
			continue
		}
		if !materialize(k, side, vector) {
			ok = false
		}
	}
	return ok
}

// design.md's operator table, read by lane type. `builtin_operator_applies`
// reads it too, so `v += 1` and `v = v + 1` answer alike.
simd_operator_applies :: proc(c: ^Compiler, op: Token_Kind, element: Type_Id) -> bool {
	integer := type_is_integer(c, element)
	float := type_is_float(c, element)
	boolean := type_is_boolean(c, element)
	#partial switch op {
	case .Plus, .Minus, .Star, .Slash:
		return integer || float
	case .Plus_Wrap, .Minus_Wrap, .Star_Wrap, .Percent, .Shl, .Shr:
		return integer
	case .Amp, .Pipe, .Tilde, .Amp_Tilde:
		return integer || boolean
	case .Eq_Eq, .Not_Eq:
		return integer || float || boolean
	case .Lt, .Lt_Eq, .Gt, .Gt_Eq:
		return integer || float
	}
	return false
}

// `-v` and `~v`. Not `!v`: a mask is negated with `~`, and `!` stays scalar.
simd_unary_applies :: proc(c: ^Compiler, op: Token_Kind, element: Type_Id) -> bool {
	#partial switch op {
	case .Minus:
		return (type_is_integer(c, element) && type_signed(c, element)) || type_is_float(c, element)
	case .Tilde:
		return type_is_integer(c, element) || type_is_boolean(c, element)
	}
	return false
}

check_simd_unary :: proc(k: ^Checker, v: ^Expr_Unary, operand: Type_Id) {
	v.type = INVALID_TYPE
	info := type_of(k.c, operand)
	element := info.element
	if !simd_unary_applies(k.c, v.op, element) {
		errorf(
			k.c, v.op_span, "L0686",
			"unary `%s` does not apply to `%s` lanes",
			operator_text(v.op), type_name(k.c, element),
		)
		if v.op == .Not {
			add_notef(k.c, v.op_span, "a lane mask is negated with `~`")
		}
		return
	}
	v.type = operand
	operand_base := expr_base(v.operand)
	if !base_is_const(operand_base) {
		return
	}
	elements := make([]Const_Value, info.count, k.c.semantic_allocator)
	for lane, index in operand_base.const_value.aggregate.elements {
		folded, ok := fold_unary_const(k, v.op, v.op_span, lane, element)
		if !ok {
			v.type = INVALID_TYPE
			return
		}
		elements[index] = folded
	}
	set_simd_const(k, &v.base, elements)
}

reject_simd_logical :: proc(k: ^Checker, v: ^Expr_Binary, lhs, rhs: Type_Id) -> bool {
	if !simd_operand(k.c, lhs) && !simd_operand(k.c, rhs) {
		return false
	}
	errorf(
		k.c, v.op_span, "L0686",
		"`%s` short-circuits, so it does not apply lane-wise; use `%s` on the masks",
		operator_text(v.op), v.op == .And_And ? "&" : "|",
	)
	v.type = INVALID_TYPE
	return true
}

// ------------------------------------------------------- `core:simd` --

// The folds, matched by member name against the `Fold` enum `core:simd`
// declares. Only that package can reach the intrinsic, so the constant needs no
// bound compiler-side identity the way an atomic ordering does.
Simd_Fold :: enum {
	Add,
	Mul,
	Min,
	Max,
	Any,
	All,
}

// Only `core:simd` reaches these, and its signatures settle the operands' shapes.
check_simd_builtin :: proc(k: ^Checker, v: ^Expr_Call, kind: Builtin_Kind) {
	v.value_category = .Value
	v.type = INVALID_TYPE
	#partial switch kind {
	case .Simd_Cast:
		check_simd_cast(k, v)
	case .Simd_Select:
		check_simd_select(k, v)
	case .Simd_Reduce:
		check_simd_reduce(k, v)
	}
	if v.type == INVALID_TYPE {
		return
	}
	if kind == .Simd_Select {
		v.bound = bound_exprs(k, v.args[0].value, v.args[1].value, v.args[2].value)
	} else {
		v.bound = bound_exprs(k, v.args[0].value)
	}
}

// `from_array` and `to_array`, one built-in because the direction is the
// operand's kind.
@(private = "file")
check_simd_cast :: proc(k: ^Checker, v: ^Expr_Call) {
	operand := check_single_expr(k, v.args[0].value)
	if operand == INVALID_TYPE {
		return
	}
	info := type_of(k.c, operand)
	v.type = info.kind == .Simd ? array_of(k.c, info.element, info.count) : simd_of(k.c, info.element, info.count)
}

@(private = "file")
check_simd_select :: proc(k: ^Checker, v: ^Expr_Call) {
	for arg in v.args {
		if check_single_expr(k, arg.value) == INVALID_TYPE {
			return
		}
	}
	v.type = expr_base(v.args[1].value).type
}

// The reductions, plus `any` and `all` over a mask.
@(private = "file")
check_simd_reduce :: proc(k: ^Checker, v: ^Expr_Call) {
	vector := check_single_expr(k, v.args[0].value)
	if vector == INVALID_TYPE {
		return
	}
	fold, known := simd_written_fold(k, v.args[1].value)
	if !known {
		return
	}
	info := type_of(k.c, vector)
	switch fold {
	case .Any, .All:
		v.type = TYPE_BOOL
	case .Add, .Mul, .Min, .Max:
		if type_is_boolean(k.c, info.element) {
			errorf(
				k.c, expr_span(v.args[1].value), "L0687",
				"`%s` folds numeric lanes, and `%s` is a lane mask",
				reflect.enum_string(fold), type_name(k.c, vector),
			)
			return
		}
		v.type = info.element
	}
	v.operation = Call_Simd_Reduce{fold = fold}
}

// The `Fold` member a call wrote.
@(private = "file")
simd_written_fold :: proc(k: ^Checker, written: Expr) -> (Simd_Fold, bool) {
	if check_single_expr(k, written) == INVALID_TYPE {
		return .Add, false
	}
	base := expr_base(written)
	member := symbol_of(k.c, enum_member_by_value(k.c, base.type, base.const_value))
	return reflect.enum_from_name(Simd_Fold, identifier_text(k.c, member.name))
}

// `Simd(T, N)` (design.md "SIMD vectors").
//
// A vector is the same identity an array has — one element type and one lane
// count — with three differences that the rest of the compiler asks about
// here: its layout, its element and lane-count rules, and that the ordinary
// operators act on it lane-wise rather than not at all.
//
// `Simd` is a predeclared name rather than a symbol in a package, because
// design.md writes `Simd(f32, 4)` with no import in sight. It is shadowable:
// a program that declares its own `Simd` gets its own, exactly as for any
// other predeclared name.
package lokec

// design.md: "`N` must be a constant power of two from 1 through 64, and
// `N * size_of(T)` must not exceed 64 bytes."
SIMD_MAX_LANES :: 64
SIMD_MAX_BYTES :: 64

// Whether this written type is the predeclared `Simd` rather than a user
// declaration that happens to share the name.
simd_callee :: proc(k: ^Checker, callee: Expr) -> bool {
	ident, is_ident := callee.(^Expr_Ident)
	if !is_ident || ident.name != "Simd" {
		return false
	}
	return lookup_symbol(k.scope, identifier_of(k.c, ident)) == INVALID_SYMBOL
}

// `Simd(T, N)` in type position. Reports rather than staying silent: unlike a
// generic application, there is no other reading of this spelling to fall back
// to once the name is the predeclared one.
resolve_simd_application :: proc(k: ^Checker, v: ^Expr_Call) -> Type_Id {
	if v.denoted_type != INVALID_TYPE {
		return v.denoted_type
	}
	if len(v.args) != 2 || v.args[0].name.text != "" || v.args[1].name.text != "" {
		errorf(k.c, v.span, "L0681", "`Simd` takes an element type and a lane count, as in `Simd(f32, 4)`")
		return INVALID_TYPE
	}
	element := resolve_type_syntax(k, v.args[0].value)
	if element == INVALID_TYPE {
		report_unresolved_type(k, v.args[0].value)
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
	count, counted := simd_lane_count(k, v.args[1].value, element)
	if !counted {
		return INVALID_TYPE
	}
	v.denoted_type = simd_of(k.c, element, count)
	v.resolution.kind = .Type
	v.value_category = .Type
	return v.denoted_type
}

// design.md: "`T` must be a boolean, an integer, or a floating-point type ...
// `rune`, 128-bit integers, enums, pointers, and every aggregate are rejected".
// `distinct` over a permitted element is itself permitted.
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

// The written lane count, held to design.md's three bounds at once so the
// diagnostic can name whichever one it broke.
@(private = "file")
simd_lane_count :: proc(k: ^Checker, written: Expr, element: Type_Id) -> (u64, bool) {
	if poly, is_poly := written.(^Type_Poly); is_poly {
		// `Simd(T, $N)` inside a generic instance: the count is a bound constant,
		// not an expression to check, exactly as an array length is.
		count, bound := poly_array_length(k, poly)
		if !bound {
			return 0, false
		}
		return count, simd_lane_count_permitted(k, written, element, count)
	}
	if check_single_expr(k, written, TYPE_INT) == INVALID_TYPE {
		return 0, false
	}
	folded, evaluated := require_const(k, written, "a SIMD lane count", "L0683")
	if !evaluated {
		return 0, false
	}
	if folded.kind != .Integer {
		errorf(k.c, expr_span(written), "L0683", "a SIMD lane count must be a constant integer")
		return 0, false
	}
	value, fits := bi_to_i64(k.c, folded.integer)
	if !fits || value <= 0 {
		errorf(k.c, expr_span(written), "L0683", "a SIMD lane count must be a positive constant")
		return 0, false
	}
	return u64(value), simd_lane_count_permitted(k, written, element, u64(value))
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

// The vector the built-in lane-wise operators act on, asked nominally where
// `type_is_simd` reaches through. design.md: a `distinct` type "does not inherit
// the underlying type's operations", so `distinct Simd(f32, 4)` is a user type
// that reaches the operators through `delegate` or an overload, exactly as
// `distinct f64` does. `compound_applies` rejects `.Distinct` the same way, and
// the two must answer alike or `v += x` and `v = v + x` would disagree.
simd_operand :: proc(c: ^Compiler, id: Type_Id) -> bool {
	return type_kind(c, id) == .Simd
}

// design.md "SIMD vectors": "`v[i]` reads a lane and `v[i] = x` writes one. The
// index must be a constant that the compiler can prove is in range; a runtime
// index is an error naming the lane count, because a dynamic lane index has no
// efficient lowering and hides a store-and-reload the source did not ask for."
check_simd_index :: proc(
	k: ^Checker, v: ^Expr_Index, info: ^Type_Info, vector: Type_Id,
	operand: ^Expr_Base, through_pointer: bool, pointer_mutable: bool,
) {
	v.type = INVALID_TYPE
	if check_single_expr(k, v.indices[0], TYPE_INT) == INVALID_TYPE {
		return
	}
	materialize(k, v.indices[0], TYPE_INT)
	index := expr_base(v.indices[0])
	if index == nil {
		return
	}
	if !type_is_integer(k.c, index.type) {
		errorf(k.c, expr_span(v.indices[0]), "L0684", "a lane index must be an integer, found `%s`", type_name(k.c, index.type))
		return
	}
	if !index.is_const || index.const_value.kind != .Integer {
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
	if through_pointer {
		v.addressable, v.assignable = true, pointer_mutable
		v.immutable = pointer_mutable ? .None : .Through_Pointer
	} else {
		v.addressable, v.assignable = operand.addressable, operand.assignable
		v.immutable = operand.immutable
	}
	// A constant vector's lane is itself a constant, so `SPLAT[2]` folds like
	// `ARRAY[2]` does and needs no storage.
	if operand.is_const && operand.const_value.kind == .Aggregate {
		aggregate := operand.const_value.aggregate
		if aggregate != nil && int(value) < len(aggregate.elements) {
			v.is_const = true
			v.const_value = aggregate.elements[value]
		}
	}
}

// ----------------------------------------------------------- operators --

// design.md "SIMD vectors": "Every operator below applies lane-wise and
// produces a vector of the same lane count. Both operands must have the same
// `Simd` type after splatting."
//
// This is answered ahead of the scalar table rather than by widening
// `type_is_numeric` and friends, so that "is this arithmetic?" keeps meaning
// what it means everywhere else in the checker.
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
	// A shift's count is a vector too, so `v << 2` splats the count exactly as
	// `v + 2` splats the addend; the scalar rule that a count keeps its own type
	// has nothing lane-wise to mean.
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
	#partial switch v.op {
	case .Eq_Eq, .Not_Eq, .Lt, .Lt_Eq, .Gt, .Gt_Eq:
		// design.md: "A comparison **yields a lane mask, not a `bool`**", so it
		// cannot be an `if` condition; `simd.any` and `simd.all` reduce it.
		v.type = simd_of(k.c, TYPE_BOOL, info.count)
		fold_simd_comparison(k, v)
	case:
		v.type = vector
		// Two constant vectors fold lane-wise, exactly as two constant scalars do.
		left, right := expr_base(v.lhs), expr_base(v.rhs)
		if !left.is_const || !right.is_const {
			return
		}
		folded, ok := fold_arithmetic(k.c, v.op, v.op_span, left.const_value, right.const_value, vector)
		if !ok {
			v.type = INVALID_TYPE
			return
		}
		v.is_const = true
		v.const_value = folded
	}
}

// A constant comparison folds to a constant mask, one lane at a time.
@(private = "file")
fold_simd_comparison :: proc(k: ^Checker, v: ^Expr_Binary) {
	left, right := expr_base(v.lhs), expr_base(v.rhs)
	if !left.is_const || !right.is_const || v.type == INVALID_TYPE {
		return
	}
	info := type_of(k.c, v.type)
	elements := make([]Const_Value, info.count, k.c.semantic_allocator)
	for index in 0 ..< int(info.count) {
		result, ok := fold_comparison(
			k.c, v.op, simd_lane_const(left.const_value, index), simd_lane_const(right.const_value, index),
		)
		if !ok {
			return
		}
		elements[index] = bool_const(result)
	}
	aggregate := new(Const_Aggregate, k.c.semantic_allocator)
	aggregate.type = v.type
	aggregate.elements = elements
	v.is_const = true
	v.const_value = Const_Value{kind = .Aggregate, aggregate = aggregate}
}

// One lane of a constant vector. A non-aggregate is the splatted scalar.
@(private = "file")
simd_lane_const :: proc(value: Const_Value, index: int) -> Const_Value {
	if value.kind != .Aggregate || value.aggregate == nil {
		return value
	}
	return index < len(value.aggregate.elements) ? value.aggregate.elements[index] : Const_Value{}
}

// Both operands at the vector type: one may be written as a scalar, which
// design.md splats. Materialising at the vector type is what turns a written
// constant into the splat aggregate; a runtime scalar keeps its own type and
// the backend splats it.
@(private = "file")
simd_splat_operands :: proc(k: ^Checker, v: ^Expr_Binary, vector, element: Type_Id) -> bool {
	ok := true
	for side in ([2]Expr{v.lhs, v.rhs}) {
		base := expr_base(side)
		if base.type == vector {
			continue
		}
		if base.is_const {
			if !materialize(k, side, vector) {
				ok = false
			}
			continue
		}
		if !assignable(k.c, base.type, element) {
			errorf(
				k.c, v.op_span, "L0686",
				"`%s` is neither `%s` nor one of its lanes",
				type_name(k.c, base.type), type_name(k.c, vector),
			)
			ok = false
			continue
		}
		// Left at the element type: the backend reads that as "splat me".
		if !materialize(k, side, element) {
			ok = false
		}
	}
	return ok
}

// design.md's operator table, read by lane type. `compound_applies` reads it
// too: a compound assignment is the binary operator plus a write, so the two
// must answer alike or `v += 1` and `v = v + 1` would disagree.
simd_operator_applies :: proc(c: ^Compiler, op: Token_Kind, element: Type_Id) -> bool {
	integer := type_is_integer(c, element)
	float := type_is_float(c, element)
	boolean := type_is_boolean(c, element)
	#partial switch op {
	case .Plus, .Minus, .Star, .Slash:
		return integer || float
	case .Percent, .Shl, .Shr:
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

// `-v` and `~v`. `!v` is not among them: design.md gives the mask `~` for
// negation, and `!` stays the scalar boolean operator.
check_simd_unary :: proc(k: ^Checker, v: ^Expr_Unary, operand: Type_Id) {
	v.type = INVALID_TYPE
	info := type_of(k.c, type_underlying(k.c, operand))
	element := info.element
	permitted := false
	#partial switch v.op {
	case .Minus:
		permitted =
			(type_is_integer(k.c, element) && type_signed(k.c, element)) ||
			type_is_float(k.c, element)
	case .Tilde:
		permitted = type_is_integer(k.c, element) || type_is_boolean(k.c, element)
	}
	if !permitted {
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
}

// design.md: "`&&` and `||` are rejected: they short-circuit, and there is
// nothing lane-wise for a short circuit to mean."
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

// The folds `simd.reduce` offers, matched by the member name of the `Fold`
// enum `core:simd` declares. Only that package can reach the intrinsic, so the
// constant needs no bound compiler-side identity the way an atomic ordering
// does.
Simd_Fold :: enum {
	Add,
	Mul,
	Min,
	Max,
	Any,
	All,
}

@(private = "file")
simd_fold_name :: proc(fold: Simd_Fold) -> string {
	switch fold {
	case .Add: return "Add"
	case .Mul: return "Mul"
	case .Min: return "Min"
	case .Max: return "Max"
	case .Any: return "Any"
	case .All: return "All"
	}
	return "?"
}

// design.md "SIMD vectors": the `core:simd` operations. Each takes exactly the
// operands its own entry describes, so the shapes are checked here rather than
// through a written signature no built-in has.
check_simd_builtin :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident, kind: Builtin_Kind) {
	v.value_category = .Value
	v.type = INVALID_TYPE
	wanted := 1
	if kind == .Simd_Select { wanted = 3 }
	if kind == .Simd_Reduce { wanted = 2 }
	if len(v.args) != wanted {
		errorf(
			k.c, v.span, "L0687", "`%s` takes %d argument%s, found %d",
			ident.name, wanted, wanted == 1 ? "" : "s", len(v.args),
		)
		return
	}
	for arg in v.args {
		if arg.name.text != "" || arg.mode != .Value {
			reject_builtin_argument_shape(k, arg)
			return
		}
	}
	bound := make([dynamic]Expr, 0, wanted, k.c.semantic_allocator)
	#partial switch kind {
	case .Simd_Cast:
		check_simd_cast(k, v, &bound)
	case .Simd_Select:
		check_simd_select(k, v, &bound)
	case .Simd_Reduce:
		check_simd_reduce(k, v, &bound)
	}
	v.bound = bound[:]
}

// design.md: "`from_array(array) -> Simd(T, N)` and `to_array(v) -> [N]T`, the
// two conversions between a vector and an array of the same element and
// length." One built-in, because the direction is the operand.
@(private = "file")
check_simd_cast :: proc(k: ^Checker, v: ^Expr_Call, bound: ^[dynamic]Expr) {
	operand := check_single_expr(k, v.args[0].value)
	if operand == INVALID_TYPE {
		return
	}
	info := underlying_info(k.c, operand)
	if info == nil {
		return
	}
	append(bound, v.args[0].value)
	#partial switch info.kind {
	case .Simd:
		v.type = array_of(k.c, info.element, info.count)
	case .Array:
		if !simd_element_permitted(k.c, info.element) {
			errorf(
				k.c, expr_span(v.args[0].value), "L0682",
				"`%s` is not a SIMD lane type", type_name(k.c, info.element),
			)
			return
		}
		v.type = simd_of(k.c, info.element, info.count)
	case:
		errorf(
			k.c, expr_span(v.args[0].value), "L0687",
			"this converts between a vector and an array; `%s` is neither",
			type_name(k.c, operand),
		)
	}
}

// design.md: "`select(mask, a, b) -> Simd(T, N)`, choosing lane-wise between
// two vectors — what a lane mask is for."
@(private = "file")
check_simd_select :: proc(k: ^Checker, v: ^Expr_Call, bound: ^[dynamic]Expr) {
	mask := check_single_expr(k, v.args[0].value)
	left := check_single_expr(k, v.args[1].value)
	right := check_single_expr(k, v.args[2].value, left)
	if mask == INVALID_TYPE || left == INVALID_TYPE || right == INVALID_TYPE {
		return
	}
	if !type_is_simd(k.c, left) {
		errorf(k.c, expr_span(v.args[1].value), "L0687", "`%s` is not a vector", type_name(k.c, left))
		return
	}
	chosen := underlying_info(k.c, left)
	materialize(k, v.args[2].value, left)
	if type_underlying(k.c, expr_base(v.args[2].value).type) != type_underlying(k.c, left) {
		errorf(
			k.c, expr_span(v.args[2].value), "L0687",
			"both selected vectors are one type; found `%s` and `%s`",
			type_name(k.c, left), type_name(k.c, right),
		)
		return
	}
	wanted := simd_of(k.c, TYPE_BOOL, chosen.count)
	if type_underlying(k.c, mask) != wanted {
		errorf(
			k.c, expr_span(v.args[0].value), "L0687",
			"a lane mask for `%s` is `%s`, found `%s`",
			type_name(k.c, left), type_name(k.c, wanted), type_name(k.c, mask),
		)
		return
	}
	append(bound, v.args[0].value, v.args[1].value, v.args[2].value)
	v.type = left
}

// design.md: the reductions, plus `any` and `all` over a lane mask. The fold is
// a constant because it selects the instruction.
@(private = "file")
check_simd_reduce :: proc(k: ^Checker, v: ^Expr_Call, bound: ^[dynamic]Expr) {
	vector := check_single_expr(k, v.args[0].value)
	if vector == INVALID_TYPE {
		return
	}
	if !type_is_simd(k.c, vector) {
		errorf(k.c, expr_span(v.args[0].value), "L0687", "`%s` is not a vector", type_name(k.c, vector))
		return
	}
	fold, known := simd_written_fold(k, v.args[1].value)
	if !known {
		return
	}
	info := underlying_info(k.c, vector)
	mask := type_is_boolean(k.c, info.element)
	switch fold {
	case .Any, .All:
		if !mask {
			errorf(
				k.c, expr_span(v.args[1].value), "L0687",
				"`%s` reduces a lane mask, and `%s` has `%s` lanes",
				simd_fold_name(fold), type_name(k.c, vector), type_name(k.c, info.element),
			)
			return
		}
		v.type = TYPE_BOOL
	case .Add, .Mul, .Min, .Max:
		if mask {
			errorf(
				k.c, expr_span(v.args[1].value), "L0687",
				"`%s` folds numeric lanes, and `%s` is a lane mask",
				simd_fold_name(fold), type_name(k.c, vector),
			)
			return
		}
		v.type = info.element
	}
	v.operation = Call_Simd_Reduce{fold = fold}
	append(bound, v.args[0].value)
}

// The `Fold` member a call wrote, matched by name. `core:simd` declares that
// enum in its own source and is the only caller, so the constant is read rather
// than a second identity for it bound into the compiler.
@(private = "file")
simd_written_fold :: proc(k: ^Checker, written: Expr) -> (Simd_Fold, bool) {
	if check_single_expr(k, written) == INVALID_TYPE {
		return .Add, false
	}
	base := expr_base(written)
	if base == nil || !base.is_const || !type_is_enum(k.c, base.type) {
		errorf(k.c, expr_span(written), "L0687", "a reduction fold is a constant `Fold` member")
		return .Add, false
	}
	name := ""
	if info := underlying_info(k.c, base.type); info != nil {
		for member in info.fields {
			sym := symbol_of(k.c, member)
			if sym == nil || sym.const_value.kind != .Integer {
				continue
			}
			if bi_cmp(k.c, sym.const_value.integer, base.const_value.integer) == 0 {
				name = identifier_text(k.c, sym.name)
				break
			}
		}
	}
	for candidate in Simd_Fold {
		if simd_fold_name(candidate) == name {
			return candidate, true
		}
	}
	errorf(k.c, expr_span(written), "L0687", "`%s` is not a reduction fold", name == "" ? "this" : name)
	return .Add, false
}

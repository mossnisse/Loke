// Expressions, conversions, and constant folding (m2-plan steps 2 and 4).
//
// `check.odin` owns declarations and statements; everything that produces a
// value lives here. Expression checking is contextual: an expected type flows
// down so that an untyped constant, an implicit `.Member`, a typeless composite
// literal, and `nil` can each take their meaning from where they are used.
//
// Every untyped value in M2 is a constant, which is what makes materialisation
// simple: converting a node to its destination type is folding its constant
// again at that width, and no untyped value ever reaches the backend.
package lokec

import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

// The type a use site wants, or INVALID_TYPE when nothing constrains it.
check_expr :: proc(k: ^Checker, e: Expr, expected: Type_Id = INVALID_TYPE) -> Type_Id {
	if e == nil {
		return INVALID_TYPE
	}
	base := expr_base(e)
	if base == nil {
		return INVALID_TYPE
	}
	base.immutable = .Not_A_Place

	switch v in e {
	case ^Expr_Error:
		v.type = INVALID_TYPE

	case ^Expr_Literal:
		check_literal(k, v, expected)

	case ^Expr_Ident:
		check_ident(k, v)

	case ^Expr_Selector:
		check_selector(k, v, expected)

	case ^Expr_Index:
		check_index(k, v)

	case ^Expr_Call:
		check_call(k, v, expected)

	case ^Expr_Unary:
		check_unary(k, v, expected)

	case ^Expr_Postfix:
		check_postfix(k, v)

	case ^Expr_Binary:
		check_binary(k, v, expected)

	case ^Expr_Cond:
		check_cond(k, v, expected)

	case ^Expr_Composite:
		check_composite(k, v, expected)

	case ^Expr_Proc:
		check_proc_literal(k, v)

	case ^Expr_Type_Assert, ^Expr_Slice, ^Expr_Range, ^Expr_Or_Else, ^Expr_Move,
	     ^Expr_Hash, ^Expr_Proc_Group, ^Expr_Operator,
	     ^Type_Pointer, ^Type_Multi_Pointer, ^Type_Slice, ^Type_Dynamic_Array,
	     ^Type_Array, ^Type_Map, ^Type_Distinct, ^Type_Dyn, ^Type_Type,
	     ^Type_Poly, ^Type_Proc, ^Type_Record, ^Type_Enum, ^Type_Interface:
		// A type in expression position denotes a type, which is legal as a
		// conversion callee and nowhere else in M2. `check_call` reads
		// `denoted_type` before falling back to this.
		reported := k.c.error_count
		denoted := resolve_type_syntax(k, e)
		if k.c.error_count > reported {
			// Resolution already said what is wrong with this type; the gate
			// would only add a second diagnostic for the same mistake.
			base.type = INVALID_TYPE
		} else if denoted != INVALID_TYPE {
			base.denoted_type = denoted
			base.value_category = .Type
			base.type = TYPE_TYPE
			base.is_const = true
			base.const_value = type_const(denoted)
		} else {
			unsupported_construct(k, base.span)
			base.type = INVALID_TYPE
		}
	}
	return base.type
}

// One value, exactly. A call with several results is legal only where the
// statement form explicitly expands it.
check_single_expr :: proc(k: ^Checker, e: Expr, expected: Type_Id = INVALID_TYPE) -> Type_Id {
	type := check_expr(k, e, expected)
	base := expr_base(e)
	if base != nil && len(base.result_types) > 1 {
		errorf(
			k.c,
			base.span,
			"L0382",
			"this call produces %d values, but one is expected here",
			len(base.result_types),
		)
		base.type = INVALID_TYPE
		return INVALID_TYPE
	}
	if type == TYPE_VOID {
		errorf(k.c, expr_span(e), "L0309", "this expression produces no value")
		if base != nil {
			base.type = INVALID_TYPE
		}
		return INVALID_TYPE
	}
	return type
}

// Checks an expression against a destination type and materialises it there.
// This is the single seam every assignment, argument, initialiser, and return
// value goes through.
check_value_expr :: proc(k: ^Checker, e: Expr, target: Type_Id, what: string) -> bool {
	type := check_single_expr(k, e, target)
	if type == INVALID_TYPE || target == INVALID_TYPE {
		return false
	}
	if !materialize(k, e, target) {
		return false
	}
	final := expr_base(e).type
	if !assignable(k.c, final, target) {
		errorf(
			k.c,
			expr_span(e),
			"L0310",
			"cannot %s `%s` with `%s`",
			what,
			type_name(k.c, target),
			type_name(k.c, final),
		)
		return false
	}
	return true
}

// ---------------------------------------------------------------- literals --

@(private = "file")
check_literal :: proc(k: ^Checker, v: ^Expr_Literal, expected: Type_Id) {
	v.value_category = .Value
	switch v.kind {
	case .Int:
		value, ok := bi_parse_int_literal(k.c, v.text)
		if !ok {
			errorf(k.c, v.span, "L0351", "`%s` is not a valid integer literal", v.text)
			v.type = INVALID_TYPE
			return
		}
		v.type = TYPE_UNTYPED_INT
		v.is_const = true
		v.const_value = integer_const(k.c, value)

	case .Float:
		text, _ := strings.replace_all(v.text, "_", "", k.c.semantic_allocator)
		value, ok := strconv.parse_f64(text)
		if !ok {
			errorf(k.c, v.span, "L0351", "`%s` is not a valid floating-point literal", v.text)
			v.type = INVALID_TYPE
			return
		}
		v.is_const = true
		// Parsed straight to the destination width when there is one: rounding
		// an `f32` expression's operands only at materialisation can disagree
		// with the same expression evaluated at runtime.
		if type_is_float(k.c, expected) && !type_is_untyped(k.c, expected) {
			v.type = expected
			v.const_value = float_const(value, u16(type_bits(k.c, expected)))
		} else {
			v.type = TYPE_UNTYPED_FLOAT
			v.const_value = float_const(value, 64)
		}

	case .Rune:
		value, ok := decode_rune_literal(v.text)
		if !ok {
			errorf(k.c, v.span, "L0351", "`%s` is not a valid character literal", v.text)
			v.type = INVALID_TYPE
			return
		}
		v.type = TYPE_UNTYPED_RUNE
		v.is_const = true
		v.const_value = rune_const(k.c, bi_from_i64(k.c, i64(value)))

	case .String, .Raw_String:
		unsupported_construct(k, v.span)
		v.type = INVALID_TYPE
	}
}

// The lexer has already validated the spelling, so this only has to decode it.
@(private = "file")
decode_rune_literal :: proc(text: string) -> (value: rune, ok: bool) {
	if len(text) < 3 || text[0] != '\'' || text[len(text) - 1] != '\'' {
		return 0, false
	}
	body := text[1:len(text) - 1]
	if body == "" {
		return 0, false
	}
	if body[0] != '\\' {
		decoded, width := utf8.decode_rune_in_string(body)
		return decoded, width == len(body)
	}
	if len(body) < 2 {
		return 0, false
	}
	switch body[1] {
	case 'a':
		return '\a', len(body) == 2
	case 'b':
		return '\b', len(body) == 2
	case 'e':
		return 0x1b, len(body) == 2
	case 'f':
		return '\f', len(body) == 2
	case 'n':
		return '\n', len(body) == 2
	case 'r':
		return '\r', len(body) == 2
	case 't':
		return '\t', len(body) == 2
	case 'v':
		return '\v', len(body) == 2
	case '\\':
		return '\\', len(body) == 2
	case '"':
		return '"', len(body) == 2
	case '\'':
		return '\'', len(body) == 2
	case 'x', 'u', 'U':
		digits, parsed := strconv.parse_u64_of_base(body[2:], 16)
		return rune(digits), parsed
	case '0' ..= '7':
		digits, parsed := strconv.parse_u64_of_base(body[1:], 8)
		return rune(digits), parsed
	}
	return 0, false
}

// ------------------------------------------------------------ identifiers --

@(private = "file")
check_ident :: proc(k: ^Checker, v: ^Expr_Ident) {
	name_id := v.name_id
	if name_id == INVALID_IDENTIFIER {
		name_id = intern_identifier(k.c, v.name)
		v.name_id = name_id
	}
	symbol_id, owner := lookup_symbol_with_scope(k.scope, name_id)
	if symbol_id == INVALID_SYMBOL && v.symbol != INVALID_SYMBOL {
		symbol_id = v.symbol
	}
	sym := symbol_of(k.c, symbol_id)
	if sym == nil {
		if v.resolution.kind != .Error {
			if v.name == "_" {
				errorf(k.c, v.span, "L0314", "`_` cannot be read")
			} else {
				errorf(k.c, v.span, "L0315", "unknown name `%s`", v.name)
			}
		}
		v.type = INVALID_TYPE
		return
	}
	v.symbol = symbol_id

	// A nested procedure literal has no closure in M2 (m2-plan decision
	// "Procedure values"), so a name that lives in an enclosing procedure's
	// frame is rejected here rather than silently miscompiled.
	if owner != nil && owner.owner_proc != nil && owner.owner_proc != k.proc_literal {
		if sym.kind == .Var || sym.kind == .Parameter || sym.kind == .Result {
			errorf(
				k.c,
				v.span,
				"L0374",
				"`%s` belongs to an enclosing procedure; a procedure literal cannot capture it",
				v.name,
			)
			v.type = INVALID_TYPE
			return
		}
	}

	if sym.kind == .Const && sym.decl != nil {
		switch sym.decl.check_state {
		case .Unchecked:
			check_decl(k, sym.decl)
			sym = symbol_of(k.c, symbol_id)
		case .Checking:
			errorf(k.c, v.span, "L0324", "constant initialisation cycle involving `%s`", v.name)
			v.type = INVALID_TYPE
			return
		case .Checked:
		}
	}

	switch sym.kind {
	case .Type:
		v.resolution = Resolution{kind = .Type, symbol = symbol_id}
		v.denoted_type = sym.type
		v.value_category = .Type
		v.type = TYPE_TYPE
		v.is_const = true
		v.const_value = type_const(sym.type)

	case .Proc:
		// A named procedure is a value with its interned procedure type; a call
		// obtains its results from the type, not from a single result field.
		v.resolution = Resolution{kind = .Value, symbol = symbol_id}
		v.value_category = .Value
		v.type = sym.proc_type

	case .Builtin:
		v.resolution = Resolution{kind = .Value, symbol = symbol_id}
		errorf(k.c, v.span, "L0316", "`%s` is a built-in procedure and must be called", v.name)
		v.type = INVALID_TYPE

	case .Const, .Enum_Member:
		v.resolution = Resolution{kind = .Value, symbol = symbol_id}
		v.value_category = .Value
		v.type = sym.type
		v.is_const = true
		v.const_value = sym.const_value
		v.immutable = .Constant

	case .Var, .Parameter, .Result:
		v.resolution = Resolution{kind = .Value, symbol = symbol_id}
		v.value_category = .Place
		v.type = sym.type
		v.addressable = true
		v.assignable = !sym.immutable
		v.immutable = sym.immutable ? .Value_Parameter : .None

	case .Field:
		v.resolution = Resolution{kind = .Field, symbol = symbol_id}
		v.type = sym.type

	case .Proc_Group, .Package_Alias, .Invalid:
		unsupported_construct(k, v.span)
		v.type = INVALID_TYPE
	}
}

// -------------------------------------------------------------- selectors --

@(private = "file")
check_selector :: proc(k: ^Checker, v: ^Expr_Selector, expected: Type_Id) {
	v.value_category = .Value

	// `.Member`: the implicit enum selector, whose operand is the expected type.
	if v.operand == nil {
		enum_type := type_underlying(k.c, expected)
		if !type_is_enum(k.c, enum_type) {
			errorf(k.c, v.span, "L0385", "`.%s` needs an expected enum type here", v.name.text)
			v.type = INVALID_TYPE
			return
		}
		member := enum_member(k.c, enum_type, intern_identifier(k.c, v.name.text))
		if member == INVALID_SYMBOL {
			errorf(k.c, v.span, "L0363", "`%s` has no member `%s`", type_name(k.c, expected), v.name.text)
			v.type = INVALID_TYPE
			return
		}
		sym := symbol_of(k.c, member)
		v.resolution = Resolution{kind = .Field, symbol = member}
		v.type = expected
		v.is_const = true
		v.const_value = sym.const_value
		v.immutable = .Constant
		return
	}

	operand := check_single_expr(k, v.operand)
	if operand == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}
	operand_base := expr_base(v.operand)

	// A named enum type selects its own member: `Colour.Red`.
	if operand_base.value_category == .Type {
		enum_type := type_underlying(k.c, operand_base.denoted_type)
		if type_is_enum(k.c, enum_type) {
			member := enum_member(k.c, enum_type, intern_identifier(k.c, v.name.text))
			if member == INVALID_SYMBOL {
				errorf(k.c, v.span, "L0363", "`%s` has no member `%s`", type_name(k.c, operand_base.denoted_type), v.name.text)
				v.type = INVALID_TYPE
				return
			}
			sym := symbol_of(k.c, member)
			v.resolution = Resolution{kind = .Field, symbol = member}
			v.type = operand_base.denoted_type
			v.is_const = true
			v.const_value = sym.const_value
			v.immutable = .Constant
			return
		}
		unsupported_construct(k, v.span)
		v.type = INVALID_TYPE
		return
	}

	// `p.field` through one pointer is the same selection as `p^.field`.
	base_type := type_underlying(k.c, operand)
	through_pointer := false
	if info := type_of(k.c, base_type); info != nil && info.kind == .Pointer {
		base_type = type_underlying(k.c, info.element)
		through_pointer = true
	}
	info := type_of(k.c, base_type)
	if info == nil || info.kind != .Struct {
		errorf(k.c, v.span, "L0363", "`%s` has no field `%s`", type_name(k.c, operand), v.name.text)
		v.type = INVALID_TYPE
		return
	}
	field := struct_field(k.c, base_type, intern_identifier(k.c, v.name.text))
	if field == INVALID_SYMBOL {
		errorf(k.c, v.span, "L0363", "`%s` has no field `%s`", type_name(k.c, base_type), v.name.text)
		v.type = INVALID_TYPE
		return
	}
	sym := symbol_of(k.c, field)
	v.resolution = Resolution{kind = .Field, symbol = field}
	v.type = sym.type
	v.value_category = .Place
	if through_pointer {
		v.addressable = true
		v.assignable = true
		v.immutable = .None
	} else {
		v.addressable = operand_base.addressable
		v.assignable = operand_base.assignable
		v.immutable = operand_base.immutable
	}
	// Selecting from a constant aggregate is itself constant.
	if operand_base.is_const && operand_base.const_value.kind == .Aggregate {
		aggregate := operand_base.const_value.aggregate
		if aggregate != nil && int(sym.index) < len(aggregate.elements) {
			v.is_const = true
			v.const_value = aggregate.elements[sym.index]
			v.immutable = .Constant
		}
	}
}

// ---------------------------------------------------------------- indexing --

@(private = "file")
check_index :: proc(k: ^Checker, v: ^Expr_Index) {
	v.value_category = .Value
	operand := check_single_expr(k, v.operand)
	if operand == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}
	if len(v.indices) != 1 {
		unsupported_construct(k, v.span)
		v.type = INVALID_TYPE
		return
	}

	base_type := type_underlying(k.c, operand)
	operand_base := expr_base(v.operand)
	through_pointer := false
	if info := type_of(k.c, base_type); info != nil && info.kind == .Pointer {
		base_type = type_underlying(k.c, info.element)
		through_pointer = true
	}
	info := type_of(k.c, base_type)
	if info == nil || info.kind != .Array {
		errorf(k.c, v.span, "L0362", "`%s` cannot be indexed", type_name(k.c, operand))
		v.type = INVALID_TYPE
		return
	}

	index_type := check_single_expr(k, v.indices[0], TYPE_INT)
	if index_type != INVALID_TYPE {
		materialize(k, v.indices[0], TYPE_INT)
		if !type_is_integer(k.c, expr_base(v.indices[0]).type) {
			errorf(k.c, expr_span(v.indices[0]), "L0362", "an index must be an integer, found `%s`", type_name(k.c, index_type))
		}
	}

	v.type = info.element
	v.value_category = .Place
	if through_pointer {
		v.addressable = true
		v.assignable = true
	} else {
		v.addressable = operand_base.addressable
		v.assignable = operand_base.assignable
		v.immutable = operand_base.immutable
	}

	index_base := expr_base(v.indices[0])
	if index_base != nil && index_base.is_const && index_base.const_value.kind == .Integer {
		index_value, ok := bi_to_i64(k.c, index_base.const_value.integer)
		if !ok || index_value < 0 || u64(index_value) >= info.count {
			errorf(
				k.c,
				expr_span(v.indices[0]),
				"L0361",
				"index %s is out of range for `%s`",
				bi_text(k.c, index_base.const_value.integer),
				type_name(k.c, base_type),
			)
			v.type = INVALID_TYPE
			return
		}
		if operand_base.is_const && operand_base.const_value.kind == .Aggregate {
			aggregate := operand_base.const_value.aggregate
			if aggregate != nil && int(index_value) < len(aggregate.elements) {
				v.is_const = true
				v.const_value = aggregate.elements[index_value]
				v.immutable = .Constant
			}
		}
	}
}

// ------------------------------------------------------------------ unary --

@(private = "file")
check_unary :: proc(k: ^Checker, v: ^Expr_Unary, expected: Type_Id) {
	v.value_category = .Value

	if v.op == .Amp {
		operand := check_single_expr(k, v.operand, pointee_of(k.c, expected))
		if operand == INVALID_TYPE {
			v.type = INVALID_TYPE
			return
		}
		operand_base := expr_base(v.operand)
		if !operand_base.addressable {
			errorf(k.c, v.op_span, "L0357", "`&` needs an addressable operand")
			v.type = INVALID_TYPE
			return
		}
		v.type = pointer_to(k.c, operand)
		return
	}

	operand := check_single_expr(k, v.operand, expected)
	if operand == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}
	operand_base := expr_base(v.operand)
	if type_kind(k.c, operand) == .Distinct {
		operator_mismatch(k, v.op_span, v.op, operand)
		v.type = INVALID_TYPE
		return
	}

	#partial switch v.op {
	case .Plus, .Minus:
		if !type_is_numeric(k.c, operand) {
			operator_mismatch(k, v.op_span, v.op, operand)
			v.type = INVALID_TYPE
			return
		}
	case .Tilde:
		if !type_is_integer(k.c, operand) && !type_is_rune(k.c, operand) {
			operator_mismatch(k, v.op_span, v.op, operand)
			v.type = INVALID_TYPE
			return
		}
	case .Not:
		if !type_is_boolean(k.c, operand) {
			operator_mismatch(k, v.op_span, v.op, operand)
			v.type = INVALID_TYPE
			return
		}
	case:
		unsupported_construct(k, v.span)
		v.type = INVALID_TYPE
		return
	}

	v.type = operand
	if !operand_base.is_const {
		return
	}
	value := operand_base.const_value
	folded: Const_Value
	#partial switch v.op {
	case .Plus:
		folded = value
	case .Minus:
		if value.kind == .Float {
			folded = float_const(-value.float, value.float_bits)
		} else {
			folded = Const_Value{kind = value.kind, integer = bi_neg(k.c, value.integer)}
		}
	case .Tilde:
		folded = Const_Value{kind = value.kind, integer = bi_not(k.c, value.integer)}
	case .Not:
		folded = bool_const(!value.boolean)
	}
	if folded.kind == .Integer || folded.kind == .Rune {
		folded.integer = wrap_to_type(k.c, folded.integer, v.type)
	}
	v.is_const = true
	v.const_value = folded
}

@(private = "file")
check_postfix :: proc(k: ^Checker, v: ^Expr_Postfix) {
	v.value_category = .Value
	if v.op != .Caret {
		unsupported_construct(k, v.span)
		v.type = INVALID_TYPE
		return
	}
	operand := check_single_expr(k, v.operand)
	if operand == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}
	info := type_of(k.c, type_underlying(k.c, operand))
	if info == nil || info.kind != .Pointer {
		errorf(k.c, v.op_span, "L0355", "`^` needs a pointer, found `%s`", type_name(k.c, operand))
		v.type = INVALID_TYPE
		return
	}
	v.type = info.element
	v.value_category = .Place
	v.addressable = true
	v.assignable = true
}

// ----------------------------------------------------------------- binary --

@(private = "file")
check_binary :: proc(k: ^Checker, v: ^Expr_Binary, expected: Type_Id) {
	v.value_category = .Value
	v.resolution.kind = .Builtin_Operator

	#partial switch v.op {
	case .And_And, .Or_Or:
		check_logical(k, v)
		return
	case .Shl, .Shr:
		check_shift(k, v, expected)
		return
	}

	is_comparison := false
	#partial switch v.op {
	case .Eq_Eq, .Not_Eq, .Lt, .Lt_Eq, .Gt, .Gt_Eq:
		is_comparison = true
	}

	hint := is_comparison ? INVALID_TYPE : expected
	lhs := check_single_expr(k, v.lhs, hint)
	rhs := check_single_expr(k, v.rhs, hint)
	if lhs == INVALID_TYPE || rhs == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}

	operand_type, unified := unify_operands(k, v.lhs, v.rhs, v.op_span)
	if !unified {
		v.type = INVALID_TYPE
		return
	}

	if is_comparison {
		check_comparison(k, v, operand_type)
		return
	}

	if !operator_applies(k.c, v.op, operand_type) {
		operator_mismatch2(k, v.op_span, v.op, lhs, rhs)
		v.type = INVALID_TYPE
		return
	}
	v.type = operand_type

	left, right := expr_base(v.lhs), expr_base(v.rhs)
	if !left.is_const || !right.is_const {
		return
	}
	folded, ok := fold_arithmetic(k, v.op, v.op_span, left.const_value, right.const_value, operand_type)
	if !ok {
		v.type = INVALID_TYPE
		return
	}
	v.is_const = true
	v.const_value = folded
}

// design.md: `a && b` is "b if a else false", so the right operand is checked
// but only the selected value is folded.
@(private = "file")
check_logical :: proc(k: ^Checker, v: ^Expr_Binary) {
	lhs := check_single_expr(k, v.lhs, TYPE_BOOL)
	rhs := check_single_expr(k, v.rhs, TYPE_BOOL)
	if lhs == INVALID_TYPE || rhs == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}
	if !type_is_boolean(k.c, lhs) || !type_is_boolean(k.c, rhs) {
		operator_mismatch2(k, v.op_span, v.op, lhs, rhs)
		v.type = INVALID_TYPE
		return
	}
	left, right := expr_base(v.lhs), expr_base(v.rhs)
	both_untyped := type_is_untyped(k.c, lhs) && type_is_untyped(k.c, rhs)
	if !both_untyped {
		materialize(k, v.lhs, TYPE_BOOL)
		materialize(k, v.rhs, TYPE_BOOL)
	}
	v.type = both_untyped ? TYPE_UNTYPED_BOOL : TYPE_BOOL
	if !left.is_const {
		return
	}
	short_circuit := v.op == .And_And ? !left.const_value.boolean : left.const_value.boolean
	if short_circuit {
		v.is_const = true
		v.const_value = bool_const(v.op == .Or_Or)
		return
	}
	if right.is_const {
		v.is_const = true
		v.const_value = bool_const(right.const_value.boolean)
	}
}

// design.md "Arithmetic operators": the shift count is an unsigned integer or
// an untyped constant representable by one, and an untyped left operand first
// takes the type it would have on its own.
@(private = "file")
check_shift :: proc(k: ^Checker, v: ^Expr_Binary, expected: Type_Id) {
	lhs := check_single_expr(k, v.lhs, expected)
	rhs := check_single_expr(k, v.rhs)
	if lhs == INVALID_TYPE || rhs == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}
	if type_kind(k.c, lhs) == .Distinct || (!type_is_integer(k.c, lhs) && !type_is_rune(k.c, lhs)) {
		operator_mismatch2(k, v.op_span, v.op, lhs, rhs)
		v.type = INVALID_TYPE
		return
	}

	if !validate_shift_count(k, v.rhs, rhs) {
		v.type = INVALID_TYPE
		return
	}

	right := expr_base(v.rhs)
	left := expr_base(v.lhs)
	if type_is_untyped(k.c, lhs) && !left.is_const {
		materialize(k, v.lhs, default_type(k.c, lhs))
		lhs = left.type
	}
	v.type = lhs

	if !left.is_const || !right.is_const {
		// A runtime shift needs a concrete left operand to shift.
		if type_is_untyped(k.c, lhs) {
			target := expected != INVALID_TYPE && type_is_integer(k.c, expected) ? expected : default_type(k.c, lhs)
			materialize(k, v.lhs, target)
			v.type = left.type
		}
		return
	}

	count, fits := bi_to_u64(k.c, right.const_value.integer)
	if !fits || count > 1 << 20 {
		// An exact untyped result would need more storage than the compiler is
		// willing to spend; every runtime type saturates long before this.
		errorf(k.c, expr_span(v.rhs), "L0356", "shift count %s is too large to fold", bi_text(k.c, right.const_value.integer))
		v.type = INVALID_TYPE
		return
	}
	value := left.const_value.integer
	shifted := v.op == .Shl ? bi_shl(k.c, value, int(count)) : bi_shr(k.c, value, int(count))
	v.is_const = true
	v.const_value = Const_Value {
		kind    = left.const_value.kind,
		integer = wrap_to_type(k.c, shifted, v.type),
	}
}

// The same rule for `a << b` and `a <<= b`: an unsigned typed count, or an
// untyped constant a typed unsigned integer could represent. The compound form
// checks its own operand here rather than against the destination's type, which
// would happily accept a signed one.
check_shift_count :: proc(k: ^Checker, e: Expr) -> bool {
	type := check_single_expr(k, e)
	if type == INVALID_TYPE {
		return false
	}
	return validate_shift_count(k, e, type)
}

@(private = "file")
validate_shift_count :: proc(k: ^Checker, e: Expr, type: Type_Id) -> bool {
	base := expr_base(e)
	if type_is_untyped(k.c, type) {
		if base.is_const && (base.const_value.kind == .Integer || base.const_value.kind == .Rune) {
			if bi_sign(base.const_value.integer) < 0 {
				errorf(k.c, expr_span(e), "L0356", "a shift count cannot be negative")
				return false
			}
			return materialize(k, e, TYPE_UINT)
		}
	} else if type_is_integer(k.c, type) && !type_signed(k.c, type) {
		return true
	}
	errorf(
		k.c,
		expr_span(e),
		"L0356",
		"a shift count must have an unsigned integer type, found `%s`",
		type_name(k.c, type),
	)
	return false
}

@(private = "file")
check_comparison :: proc(k: ^Checker, v: ^Expr_Binary, operand_type: Type_Id) {
	ordered := v.op != .Eq_Eq && v.op != .Not_Eq
	if ordered && !type_is_ordered(k.c, operand_type) {
		errorf(k.c, v.op_span, "L0355", "`%s` does not order `%s`", operator_text(v.op), type_name(k.c, operand_type))
		v.type = INVALID_TYPE
		return
	}
	if !ordered && !type_is_comparable(k.c, operand_type) {
		errorf(k.c, v.op_span, "L0355", "`%s` is not comparable", type_name(k.c, operand_type))
		v.type = INVALID_TYPE
		return
	}

	left, right := expr_base(v.lhs), expr_base(v.rhs)
	if left.is_const && right.is_const {
		result, ok := fold_comparison(k, v.op, left.const_value, right.const_value)
		if ok {
			v.type = TYPE_UNTYPED_BOOL
			v.is_const = true
			v.const_value = bool_const(result)
			return
		}
	}
	v.type = TYPE_BOOL
}

// One untyped operand takes the other's concrete type; two untyped operands
// meet at the wider untyped kind (design.md "Arithmetic operators").
@(private = "file")
unify_operands :: proc(k: ^Checker, lhs, rhs: Expr, op_span: Span) -> (Type_Id, bool) {
	left, right := expr_base(lhs), expr_base(rhs)
	lt, rt := left.type, right.type
	if lt == rt {
		return lt, true
	}
	left_untyped := type_is_untyped(k.c, lt)
	right_untyped := type_is_untyped(k.c, rt)

	switch {
	case left_untyped && right_untyped:
		merged, ok := merge_untyped(lt, rt)
		if !ok {
			operand_mismatch(k, op_span, lt, rt)
			return INVALID_TYPE, false
		}
		materialize(k, lhs, merged)
		materialize(k, rhs, merged)
		return merged, true
	case left_untyped:
		if !materialize(k, lhs, rt) {
			return INVALID_TYPE, false
		}
		return rt, true
	case right_untyped:
		if !materialize(k, rhs, lt) {
			return INVALID_TYPE, false
		}
		return lt, true
	}
	operand_mismatch(k, op_span, lt, rt)
	return INVALID_TYPE, false
}

@(private = "file")
merge_untyped :: proc(a, b: Type_Id) -> (Type_Id, bool) {
	if a == b {
		return a, true
	}
	rank :: proc(t: Type_Id) -> int {
		switch t {
		case TYPE_UNTYPED_INT:
			return 1
		case TYPE_UNTYPED_RUNE:
			return 2
		case TYPE_UNTYPED_FLOAT:
			return 3
		}
		return 0
	}
	ra, rb := rank(a), rank(b)
	if ra == 0 || rb == 0 {
		return INVALID_TYPE, false
	}
	return ra > rb ? a : b, true
}

@(private = "file")
operator_applies :: proc(c: ^Compiler, op: Token_Kind, type: Type_Id) -> bool {
	if type_kind(c, type) == .Distinct {
		return false
	}
	#partial switch op {
	case .Plus, .Minus, .Star, .Slash:
		return type_is_numeric(c, type)
	case .Percent:
		return type_is_integer(c, type) || type_is_rune(c, type)
	case .Amp, .Pipe, .Tilde, .Amp_Tilde:
		return type_is_integer(c, type) || type_is_rune(c, type)
	}
	return false
}

// ---------------------------------------------------- conditional and calls --

@(private = "file")
check_cond :: proc(k: ^Checker, v: ^Expr_Cond, expected: Type_Id) {
	v.value_category = .Value
	cond := check_single_expr(k, v.cond, TYPE_BOOL)
	if cond != INVALID_TYPE {
		materialize(k, v.cond, TYPE_BOOL)
		if !type_is_boolean(k.c, expr_base(v.cond).type) {
			errorf(k.c, expr_span(v.cond), "L0355", "a condition must be `bool`, found `%s`", type_name(k.c, cond))
		}
	}
	then_type := check_single_expr(k, v.then, expected)
	else_type := check_single_expr(k, v.otherwise, expected)
	if cond == INVALID_TYPE || then_type == INVALID_TYPE || else_type == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}
	result, unified := unify_operands(k, v.then, v.otherwise, v.span)
	if !unified {
		v.type = INVALID_TYPE
		return
	}
	v.type = result

	// Both branches are checked, but only the selected one is folded.
	condition := expr_base(v.cond)
	if !condition.is_const {
		return
	}
	selected := condition.const_value.boolean ? expr_base(v.then) : expr_base(v.otherwise)
	if selected.is_const {
		v.is_const = true
		v.const_value = selected.const_value
	}
}

// ------------------------------------------------------- calls and casts --

@(private = "file")
check_call :: proc(k: ^Checker, v: ^Expr_Call, expected: Type_Id) {
	v.value_category = .Value

	// A built-in is not a value, so it is recognised before the callee is
	// checked as one.
	if ident, is_ident := v.callee.(^Expr_Ident); is_ident {
		symbol_id := lookup_symbol(k.scope, identifier_of(k.c, ident))
		if sym := symbol_of(k.c, symbol_id); sym != nil && sym.kind == .Builtin {
			check_builtin_call(k, v, ident, symbol_id)
			return
		}
	}

	callee_type := check_expr(k, v.callee)
	callee_base := expr_base(v.callee)
	if callee_base == nil || callee_type == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}
	if callee_base.value_category == .Type {
		check_conversion(k, v, callee_base.denoted_type)
		return
	}

	info := type_of(k.c, type_underlying(k.c, callee_type))
	if info == nil || info.kind != .Proc {
		errorf(k.c, expr_span(v.callee), "L0320", "`%s` is not callable", type_name(k.c, callee_type))
		v.type = INVALID_TYPE
		return
	}

	// Only a directly named procedure may use defaults or named arguments; a
	// call through a procedure value supplies every parameter positionally.
	declaration := INVALID_SYMBOL
	if ident, is_ident := v.callee.(^Expr_Ident); is_ident {
		if sym := symbol_of(k.c, ident.symbol); sym != nil && sym.kind == .Proc {
			declaration = ident.symbol
		}
	}
	v.resolution = Resolution{kind = .Call, symbol = declaration, chosen_overload = declaration}

	if !bind_arguments(k, v, info, declaration) {
		v.type = INVALID_TYPE
		return
	}

	switch len(info.results) {
	case 0:
		v.type = TYPE_VOID
	case 1:
		v.type = info.results[0]
	case:
		v.type = info.results[0]
		v.result_types = info.results
	}
}

@(private = "file")
check_builtin_call :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident, symbol_id: Symbol_Id) {
	sym := symbol_of(k.c, symbol_id)
	ident.symbol = symbol_id
	ident.resolution = Resolution{kind = .Value, symbol = symbol_id}
	ident.type = sym.proc_type
	v.resolution = Resolution{kind = .Call, symbol = symbol_id, chosen_overload = symbol_id}

	if len(v.args) != len(sym.params) {
		errorf(
			k.c,
			v.span,
			"L0322",
			"`%s` takes %d argument%s, found %d",
			ident.name,
			len(sym.params),
			len(sym.params) == 1 ? "" : "s",
			len(v.args),
		)
		v.type = INVALID_TYPE
		return
	}
	bound := make([]Expr, len(sym.params), k.c.semantic_allocator)
	for arg, index in v.args {
		if arg.name.text != "" || arg.mode != .Value {
			unsupported_construct(k, arg.span)
			continue
		}
		bound[index] = arg.value
		check_value_expr(k, arg.value, sym.params[index], "pass")
	}
	v.bound = bound
	v.type = sym.type
}

// Binds written arguments to parameters, then fills the omitted ones from the
// declaration's defaults. `v.bound` is the resolved parameter-order list the
// backend evaluates.
@(private = "file")
bind_arguments :: proc(k: ^Checker, v: ^Expr_Call, info: ^Type_Info, declaration: Symbol_Id) -> bool {
	count := len(info.parameters)
	bound := make([]Expr, count, k.c.semantic_allocator)
	modes := make([]Argument_Mode, count, k.c.semantic_allocator)
	filled := make([]bool, count, k.c.semantic_allocator)
	declared := symbol_of(k.c, declaration)
	ok := true
	named := false

	for arg, index in v.args {
		if arg.mode == .Spread {
			unsupported_construct(k, arg.span)
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
			slot = -1
			target := intern_identifier(k.c, arg.name.text)
			for symbol_id, position in declared.param_symbols {
				if symbol := symbol_of(k.c, symbol_id); symbol != nil && symbol.name == target {
					slot = position
					break
				}
			}
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
		bound[slot] = arg.value
		modes[slot] = arg.mode
		expected_mode := slot < len(info.param_modes) ? info.param_modes[slot] : Param_Mode.Value
		if expected_mode == .Inout && arg.mode != .Inout {
			errorf(k.c, arg.span, "L0370", "this parameter is `inout`; write `inout` at the call site")
			ok = false
			continue
		}
		if expected_mode != .Inout && arg.mode == .Inout {
			errorf(k.c, arg.span, "L0370", "this parameter is not `inout`")
			ok = false
			continue
		}
		if !check_value_expr(k, arg.value, info.parameters[slot], "pass") {
			ok = false
			continue
		}
		if arg.mode == .Inout {
			base := expr_base(arg.value)
			if !base.assignable {
				report_not_assignable(k, base, "an `inout` argument")
				ok = false
			}
		}
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
		bound[index] = declared.param_defaults[index]
	}

	v.bound = bound
	return ok
}

// Built-in `T(v)`. Pointer and distinct conversions are here too; user
// conversions and their ranking are M4.
@(private = "file")
check_conversion :: proc(k: ^Checker, v: ^Expr_Call, target: Type_Id) {
	v.resolution = Resolution{kind = .Conversion}
	if !gate_type(k, target, v.span) {
		v.type = INVALID_TYPE
		return
	}
	if len(v.args) != 1 || v.args[0].name.text != "" || v.args[0].mode != .Value {
		errorf(k.c, v.span, "L0373", "a conversion takes exactly one argument")
		v.type = INVALID_TYPE
		return
	}
	source := check_single_expr(k, v.args[0].value, target)
	if source == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}
	v.bound = make([]Expr, 1, k.c.semantic_allocator)
	v.bound[0] = v.args[0].value
	v.type = target

	base := expr_base(v.args[0].value)
	if base.is_const {
		converted, fits := convert_const(k.c, base.const_value, target, true)
		if !fits {
			errorf(
				k.c,
				expr_span(v.args[0].value),
				"L0373",
				"`%s` cannot be converted to `%s`",
				type_name(k.c, source),
				type_name(k.c, target),
			)
			v.type = INVALID_TYPE
			return
		}
		// The operand keeps its own type; the conversion node carries the result.
		v.is_const = true
		v.const_value = converted
		return
	}
	if !convertible(k.c, source, target) {
		errorf(
			k.c,
			expr_span(v.args[0].value),
			"L0373",
			"`%s` cannot be converted to `%s`",
			type_name(k.c, source),
			type_name(k.c, target),
		)
		v.type = INVALID_TYPE
	}
}

// A procedure literal in expression position is hoisted to its own module
// function. It has no closure, so `check_ident` rejects any name that lives in
// an enclosing procedure's frame.
@(private = "file")
check_proc_literal :: proc(k: ^Checker, v: ^Expr_Proc) {
	v.value_category = .Value
	if v.bodiless || len(v.where_clauses) > 0 || v.signature == nil {
		unsupported_construct(k, v.span)
		v.type = INVALID_TYPE
		return
	}
	if v.symbol == INVALID_SYMBOL {
		name := identifier_text(k.c, intern_identifier(k.c, "proc_literal"))
		_ = name
		v.symbol = new_symbol(k.c, Symbol {
			name = intern_identifier(k.c, "proc$literal"),
			span = v.span,
			kind = .Proc,
			pkg  = k.pkg,
		})
	}
	resolve_proc_signature(k, v, v.symbol)
	symbol := symbol_of(k.c, v.symbol)
	if symbol == nil {
		v.type = INVALID_TYPE
		return
	}
	v.type = symbol.proc_type
	append(&k.c.hoisted_procs, v)
	check_proc_body(k, v)
}

// ------------------------------------------------------------- composites --

@(private = "file")
check_composite :: proc(k: ^Checker, v: ^Expr_Composite, expected: Type_Id) {
	v.value_category = .Value
	target := expected
	if array, is_array := v.type_expr.(^Type_Array); is_array && array.inferred {
		// `[?]T` takes its length from the literal it types.
		element := resolve_type_syntax(k, array.elem)
		if element == INVALID_TYPE {
			unsupported_construct(k, expr_span(v.type_expr))
			v.type = INVALID_TYPE
			return
		}
		array.denoted_type = array_of(k.c, element, u64(len(v.elements)))
		array.resolution.kind = .Type
		target = array.denoted_type
	} else if v.type_expr != nil {
		target = resolve_type_syntax(k, v.type_expr)
		if target == INVALID_TYPE {
			unsupported_construct(k, expr_span(v.type_expr))
			v.type = INVALID_TYPE
			return
		}
	}
	if target == INVALID_TYPE {
		errorf(k.c, v.span, "L0376", "this composite literal needs a type")
		v.type = INVALID_TYPE
		return
	}
	if !gate_type(k, target, v.span) {
		v.type = INVALID_TYPE
		return
	}

	under := type_underlying(k.c, target)
	info := type_of(k.c, under)
	if info == nil {
		v.type = INVALID_TYPE
		return
	}
	v.type = target
	// A composite literal is addressable temporary storage, and is never itself
	// an assignment destination (m2-plan decision "Place model").
	v.addressable = true
	v.assignable = false
	v.immutable = .Temporary

	#partial switch info.kind {
	case .Struct:
		check_struct_literal(k, v, target, info)
	case .Array:
		check_array_literal(k, v, target, info)
	case:
		errorf(k.c, v.span, "L0376", "`%s` cannot be built from a composite literal", type_name(k.c, target))
		v.type = INVALID_TYPE
	}
}

@(private = "file")
check_struct_literal :: proc(k: ^Checker, v: ^Expr_Composite, target: Type_Id, info: ^Type_Info) {
	count := len(info.fields)
	values := make([]Expr, count, k.c.semantic_allocator)
	seen := make([]bool, count, k.c.semantic_allocator)
	named := false
	ok := true

	for element, index in v.elements {
		if element.key != nil {
			key, is_ident := element.key.(^Expr_Ident)
			if !is_ident {
				errorf(k.c, element.span, "L0376", "a struct literal key must be a field name")
				ok = false
				continue
			}
			named = true
			field := struct_field(k.c, target, intern_identifier(k.c, key.name))
			if field == INVALID_SYMBOL {
				errorf(k.c, element.span, "L0363", "`%s` has no field `%s`", type_name(k.c, target), key.name)
				ok = false
				continue
			}
			symbol := symbol_of(k.c, field)
			if seen[symbol.index] {
				errorf(k.c, element.span, "L0376", "field `%s` is set twice", key.name)
				ok = false
				continue
			}
			seen[symbol.index] = true
			values[symbol.index] = element.value
			if !check_value_expr(k, element.value, symbol.type, "initialise") {
				ok = false
			}
			continue
		}
		if named {
			errorf(k.c, element.span, "L0372", "a positional element cannot follow a named one")
			ok = false
			continue
		}
		if index >= count {
			errorf(k.c, element.span, "L0376", "`%s` has %d field%s", type_name(k.c, target), count, count == 1 ? "" : "s")
			ok = false
			continue
		}
		symbol := symbol_of(k.c, info.fields[index])
		seen[index] = true
		values[index] = element.value
		if !check_value_expr(k, element.value, symbol.type, "initialise") {
			ok = false
		}
	}
	if !ok {
		return
	}
	fold_aggregate(k, v, target, values, info.fields)
}

@(private = "file")
check_array_literal :: proc(k: ^Checker, v: ^Expr_Composite, target: Type_Id, info: ^Type_Info) {
	count := int(info.count)
	values := make([]Expr, count, k.c.semantic_allocator)
	ok := true
	for element, index in v.elements {
		if element.key != nil {
			unsupported_construct(k, element.span)
			ok = false
			continue
		}
		if index >= count {
			errorf(k.c, element.span, "L0376", "`%s` holds %d element%s", type_name(k.c, target), count, count == 1 ? "" : "s")
			ok = false
			continue
		}
		values[index] = element.value
		if !check_value_expr(k, element.value, info.element, "initialise") {
			ok = false
		}
	}
	if ok {
		fold_aggregate(k, v, target, values, nil)
	}
}

// A literal whose every written element folded, with zero values for the rest,
// is itself a constant — which is what makes a non-zero aggregate global and a
// constant field selection possible.
@(private = "file")
fold_aggregate :: proc(k: ^Checker, v: ^Expr_Composite, target: Type_Id, values: []Expr, fields: []Symbol_Id) {
	elements := make([]Const_Value, len(values), k.c.semantic_allocator)
	for value, index in values {
		if value == nil {
			element_type := INVALID_TYPE
			if fields == nil {
				element_type = type_of(k.c, type_underlying(k.c, target)).element
			} else {
				element_type = symbol_of(k.c, fields[index]).type
			}
			zero, ok := zero_const(k.c, element_type)
			if !ok {
				return
			}
			elements[index] = zero
			continue
		}
		base := expr_base(value)
		if !base.is_const {
			return
		}
		elements[index] = base.const_value
	}
	aggregate := new(Const_Aggregate, k.c.semantic_allocator)
	aggregate.type = target
	aggregate.elements = elements
	v.is_const = true
	v.const_value = Const_Value{kind = .Aggregate, aggregate = aggregate}
}

// The compile-time zero value of every runtime M2 type (design.md "Zero
// values"). Recursive for aggregates.
zero_const :: proc(c: ^Compiler, type: Type_Id) -> (Const_Value, bool) {
	under := type_underlying(c, type)
	info := type_of(c, under)
	if info == nil {
		return Const_Value{}, false
	}
	#partial switch info.kind {
	case .Bool:
		return bool_const(false), true
	case .Int:
		return int_const(c, 0), true
	case .Rune:
		return rune_const(c, bi_from_i64(c, 0)), true
	case .Float:
		return float_const(0, info.bits), true
	case .Enum:
		return int_const(c, 0), true
	case .Pointer, .Raw_Pointer, .Proc:
		return nil_const(), true
	case .Array:
		elements := make([]Const_Value, info.count, c.semantic_allocator)
		element, ok := zero_const(c, info.element)
		if !ok {
			return Const_Value{}, false
		}
		for index in 0 ..< int(info.count) {
			elements[index] = element
		}
		aggregate := new(Const_Aggregate, c.semantic_allocator)
		aggregate.type = type
		aggregate.elements = elements
		return Const_Value{kind = .Aggregate, aggregate = aggregate}, true
	case .Struct:
		elements := make([]Const_Value, len(info.fields), c.semantic_allocator)
		for field, index in info.fields {
			symbol := symbol_of(c, field)
			if symbol == nil {
				return Const_Value{}, false
			}
			element, ok := zero_const(c, symbol.type)
			if !ok {
				return Const_Value{}, false
			}
			elements[index] = element
		}
		aggregate := new(Const_Aggregate, c.semantic_allocator)
		aggregate.type = type
		aggregate.elements = elements
		return Const_Value{kind = .Aggregate, aggregate = aggregate}, true
	}
	return Const_Value{}, false
}

// -------------------------------------------------------------- materialise --

// Rewrites an untyped node so it carries `target` and a constant folded at that
// width. Reports the representability failure itself; returns false only when
// the value cannot live in the target type.
materialize :: proc(k: ^Checker, e: Expr, target: Type_Id) -> bool {
	base := expr_base(e)
	if base == nil || target == INVALID_TYPE || base.type == INVALID_TYPE {
		return false
	}
	if !type_is_untyped(k.c, base.type) {
		return true
	}
	// `a if c else b` with a runtime condition is the one untyped node that is
	// not itself a constant: its branches carry the values, so they take the
	// destination type with it.
	if conditional, is_cond := e.(^Expr_Cond); is_cond && !base.is_const {
		if !materialize(k, conditional.then, target) || !materialize(k, conditional.otherwise, target) {
			return false
		}
		base.type = expr_base(conditional.then).type
		return true
	}
	if type_is_untyped(k.c, target) {
		if base.type == target {
			return true
		}
		merged, ok := merge_untyped(base.type, target)
		if !ok {
			return true
		}
		target := merged
		converted, fits := convert_const(k.c, base.const_value, target, false)
		if !fits {
			return true
		}
		base.type = target
		base.const_value = converted
		return true
	}
	if !base.is_const {
		// Untyped and not constant cannot arise in M2; if it ever does, the
		// default type is the honest answer rather than a silent retype.
		base.type = default_type(k.c, base.type)
		return base.type == target
	}
	converted, fits := convert_const(k.c, base.const_value, target, false)
	if !fits {
		report_unrepresentable(k, base, target)
		return false
	}
	base.type = target
	base.const_value = converted
	return true
}

@(private = "file")
report_unrepresentable :: proc(k: ^Checker, base: ^Expr_Base, target: Type_Id) {
	switch base.const_value.kind {
	case .Integer, .Rune:
		errorf(
			k.c,
			base.span,
			"L0352",
			"%s is not representable by `%s`",
			bi_text(k.c, base.const_value.integer),
			type_name(k.c, target),
		)
	case .Float:
		errorf(k.c, base.span, "L0353", "%v is not representable by `%s`", base.const_value.float, type_name(k.c, target))
	case .Nil:
		errorf(k.c, base.span, "L0310", "`nil` is not a value of `%s`", type_name(k.c, target))
	case .Boolean, .String, .Type, .Aggregate, .Invalid:
		errorf(k.c, base.span, "L0310", "this constant is not a value of `%s`", type_name(k.c, target))
	}
}

// Converts a constant to a target type. `explicit` is set for a written
// `T(v)`, which truncates a float towards zero where an implicit conversion
// requires an exact value.
convert_const :: proc(c: ^Compiler, value: Const_Value, target: Type_Id, explicit: bool) -> (Const_Value, bool) {
	info := type_of(c, type_underlying(c, target))
	if info == nil {
		return value, false
	}
	#partial switch info.kind {
	case .Untyped_Int, .Untyped_Rune:
		if value.kind == .Integer || value.kind == .Rune {
			return Const_Value{kind = info.kind == .Untyped_Rune ? .Rune : .Integer, integer = value.integer}, true
		}
	case .Untyped_Float:
		if value.kind == .Float {
			return value, true
		}
		if value.kind == .Integer || value.kind == .Rune {
			return float_const(bi_to_f64(c, value.integer), 64), true
		}
	case .Untyped_Bool:
		if value.kind == .Boolean {
			return value, true
		}
	case .Untyped_Nil:
		if value.kind == .Nil {
			return value, true
		}
	case .Bool:
		if value.kind == .Boolean {
			return value, true
		}
	case .Int, .Enum:
		bits, signed := type_bits(c, target), type_signed(c, target)
		#partial switch value.kind {
		case .Integer, .Rune:
			if !bi_fits(c, value.integer, bits, signed) {
				return value, false
			}
			return Const_Value{kind = .Integer, integer = value.integer}, true
		case .Float:
			truncated, exact, ok := bi_from_f64_trunc(c, value.float)
			if !ok || (!explicit && !exact) {
				return value, false
			}
			if !bi_fits(c, truncated, bits, signed) {
				return value, false
			}
			return Const_Value{kind = .Integer, integer = truncated}, true
		}
	case .Rune:
		#partial switch value.kind {
		case .Integer, .Rune:
			if !bi_fits(c, value.integer, 32, true) {
				return value, false
			}
			return Const_Value{kind = .Rune, integer = value.integer}, true
		}
	case .Float:
		#partial switch value.kind {
		case .Float:
			return float_const(value.float, info.bits), true
		case .Integer, .Rune:
			return float_const(bi_to_f64(c, value.integer), info.bits), true
		}
	case .Pointer, .Raw_Pointer, .Proc:
		if value.kind == .Nil {
			return nil_const(), true
		}
	case .Struct, .Array:
		if value.kind == .Aggregate && value.aggregate != nil && value.aggregate.type == target {
			return value, true
		}
	case .Type:
		if value.kind == .Type {
			return value, true
		}
	}
	return value, false
}

// Is a value of `from` acceptable where `to` is wanted, with no written
// conversion? Representability of an untyped constant is settled by
// `materialize` before this is asked.
assignable :: proc(c: ^Compiler, from, to: Type_Id) -> bool {
	if from == to {
		return true
	}
	if from == INVALID_TYPE || to == INVALID_TYPE {
		return false
	}
	if from == TYPE_UNTYPED_NIL {
		#partial switch type_kind(c, type_underlying(c, to)) {
		case .Pointer, .Raw_Pointer, .Proc:
			return true
		}
		return false
	}
	if type_is_untyped(c, from) {
		#partial switch type_kind(c, type_underlying(c, to)) {
		case .Int, .Float, .Rune, .Bool, .Enum:
			return true
		}
		return false
	}
	// Any pointer converts to `rawptr` without a written conversion; the reverse
	// needs one.
	if to == TYPE_RAWPTR && type_kind(c, type_underlying(c, from)) == .Pointer {
		return true
	}
	return false
}

// Is `T(v)` legal? Built-in conversions only; user conversions are M4.
convertible :: proc(c: ^Compiler, from, to: Type_Id) -> bool {
	if assignable(c, from, to) {
		return true
	}
	source := type_underlying(c, from)
	dest := type_underlying(c, to)
	if source == dest {
		return true // between a distinct type and what it wraps, either way
	}
	source_kind, dest_kind := type_kind(c, source), type_kind(c, dest)

	numeric :: proc(kind: Type_Kind) -> bool {
		#partial switch kind {
		case .Int, .Float, .Rune, .Enum, .Untyped_Int, .Untyped_Float, .Untyped_Rune:
			return true
		}
		return false
	}
	if numeric(source_kind) && numeric(dest_kind) {
		return true
	}
	pointerish :: proc(kind: Type_Kind) -> bool {
		#partial switch kind {
		case .Pointer, .Raw_Pointer:
			return true
		}
		return false
	}
	if pointerish(source_kind) && pointerish(dest_kind) {
		return true
	}
	return false
}

// ---------------------------------------------------------------- folding --

@(private = "file")
fold_arithmetic :: proc(
	k: ^Checker,
	op: Token_Kind,
	op_span: Span,
	a, b: Const_Value,
	type: Type_Id,
) -> (Const_Value, bool) {
	if a.kind == .Float || b.kind == .Float {
		bits := u16(type_bits(k.c, type))
		if type_is_untyped(k.c, type) {
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
			errorf(k.c, op_span, "L0355", "`%s` does not apply to `%s`", operator_text(op), type_name(k.c, type))
			return Const_Value{}, false
		}
		return float_const(result, bits), true
	}

	if (op == .Slash || op == .Percent) && bi_is_zero(b.integer) {
		errorf(k.c, op_span, "L0319", "division by zero")
		return Const_Value{}, false
	}

	x, y := a.integer, b.integer
	result: Big_Int
	#partial switch op {
	case .Plus:
		result = bi_add(k.c, x, y)
	case .Minus:
		result = bi_sub(k.c, x, y)
	case .Star:
		result = bi_mul(k.c, x, y)
	case .Slash:
		result = bi_quo(k.c, x, y)
	case .Percent:
		result = bi_rem(k.c, x, y)
	case .Amp:
		result = bi_and(k.c, x, y)
	case .Pipe:
		result = bi_or(k.c, x, y)
	case .Tilde:
		result = bi_xor(k.c, x, y)
	case .Amp_Tilde:
		result = bi_and_not(k.c, x, y)
	case:
		errorf(k.c, op_span, "L0355", "`%s` does not apply to `%s`", operator_text(op), type_name(k.c, type))
		return Const_Value{}, false
	}
	return Const_Value{kind = a.kind, integer = wrap_to_type(k.c, result, type)}, true
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

@(private = "file")
fold_comparison :: proc(k: ^Checker, op: Token_Kind, a, b: Const_Value) -> (bool, bool) {
	order := 0
	switch {
	case a.kind == .Float || b.kind == .Float:
		x := a.kind == .Float ? a.float : bi_to_f64(k.c, a.integer)
		y := b.kind == .Float ? b.float : bi_to_f64(k.c, b.integer)
		// NaN compares false against everything, including itself.
		if x != x || y != y {
			return op == .Not_Eq, true
		}
		order = x < y ? -1 : (x > y ? 1 : 0)
	case a.kind == .Integer || a.kind == .Rune:
		if b.kind != .Integer && b.kind != .Rune {
			return false, false
		}
		order = bi_cmp(k.c, a.integer, b.integer)
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
	case a.kind == .Aggregate && b.kind == .Aggregate:
		if op != .Eq_Eq && op != .Not_Eq {
			return false, false
		}
		equal := aggregate_equal(k, a.aggregate, b.aggregate)
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
aggregate_equal :: proc(k: ^Checker, a, b: ^Const_Aggregate) -> bool {
	if a == nil || b == nil || len(a.elements) != len(b.elements) {
		return false
	}
	for element, index in a.elements {
		equal, ok := fold_comparison(k, .Eq_Eq, element, b.elements[index])
		if !ok || !equal {
			return false
		}
	}
	return true
}

// ------------------------------------------------------------- diagnostics --

@(private = "file")
operator_mismatch :: proc(k: ^Checker, span: Span, op: Token_Kind, type: Type_Id) {
	errorf(k.c, span, "L0317", "`%s` does not apply to `%s`", operator_text(op), type_name(k.c, type))
}

@(private = "file")
operator_mismatch2 :: proc(k: ^Checker, span: Span, op: Token_Kind, lhs, rhs: Type_Id) {
	errorf(
		k.c,
		span,
		"L0318",
		"`%s` does not apply to `%s` and `%s`",
		operator_text(op),
		type_name(k.c, lhs),
		type_name(k.c, rhs),
	)
}

@(private = "file")
operand_mismatch :: proc(k: ^Checker, span: Span, lhs, rhs: Type_Id) {
	errorf(
		k.c,
		span,
		"L0354",
		"mismatched operand types `%s` and `%s`",
		type_name(k.c, lhs),
		type_name(k.c, rhs),
	)
}

// ------------------------------------------------------------------ helpers --

@(private = "file")
pointee_of :: proc(c: ^Compiler, type: Type_Id) -> Type_Id {
	info := type_of(c, type_underlying(c, type))
	if info == nil || info.kind != .Pointer {
		return INVALID_TYPE
	}
	return info.element
}

struct_field :: proc(c: ^Compiler, type: Type_Id, name: Identifier_Id) -> Symbol_Id {
	info := type_of(c, type_underlying(c, type))
	if info == nil || name == INVALID_IDENTIFIER {
		return INVALID_SYMBOL
	}
	for field in info.fields {
		if symbol := symbol_of(c, field); symbol != nil && symbol.name == name {
			return field
		}
	}
	return INVALID_SYMBOL
}

enum_member :: proc(c: ^Compiler, type: Type_Id, name: Identifier_Id) -> Symbol_Id {
	return struct_field(c, type, name)
}

// Constness lives on Expr_Base, which every node embeds, so these need no
// per-node switch: a node the checker never folded is simply not constant.
is_const_expr :: proc(e: Expr) -> bool {
	base := expr_base(e)
	return base != nil && base.is_const
}

const_value_of :: proc(e: Expr) -> Const_Value {
	base := expr_base(e)
	return base == nil ? Const_Value{} : base.const_value
}

operator_text :: proc(op: Token_Kind) -> string {
	#partial switch op {
	case .Plus:
		return "+"
	case .Minus:
		return "-"
	case .Star:
		return "*"
	case .Slash:
		return "/"
	case .Percent:
		return "%"
	case .Amp:
		return "&"
	case .Pipe:
		return "|"
	case .Tilde:
		return "~"
	case .Amp_Tilde:
		return "&~"
	case .Shl:
		return "<<"
	case .Shr:
		return ">>"
	case .And_And:
		return "&&"
	case .Or_Or:
		return "||"
	case .Not:
		return "!"
	case .Eq_Eq:
		return "=="
	case .Not_Eq:
		return "!="
	case .Lt:
		return "<"
	case .Lt_Eq:
		return "<="
	case .Gt:
		return ">"
	case .Gt_Eq:
		return ">="
	}
	return "?"
}

// Closed payloadless sums with an integer representation.
package lokec

// The compiler-defined `Enum.from_int` and `Enum.values`, which no `impl` or
// `extend` member may shadow.
enum_builtin_member :: proc(name: string) -> bool {
	return name == "from_int" || name == "values"
}

// The enum a `Type.<name>(...)` call names, or INVALID_TYPE.
@(private = "file")
enum_builtin_subject :: proc(k: ^Checker, v: ^Expr_Call, sel: ^Expr_Selector, name: string) -> Type_Id {
	if sel.name.text != name {
		return INVALID_TYPE
	}
	subject := resolve_type_syntax(k, sel.operand)
	if subject == INVALID_TYPE || !type_is_enum(k.c, subject) {
		return INVALID_TYPE
	}
	v.value_category = .Value
	v.resolution = Resolution{kind = .Builtin_Operator}
	return subject
}

// design.md "Integer conversion": validation is a named fallible constructor,
// never a representation-only type conversion.
check_enum_from_int :: proc(k: ^Checker, v: ^Expr_Call, sel: ^Expr_Selector) -> bool {
	subject := enum_builtin_subject(k, v, sel, "from_int")
	if subject == INVALID_TYPE {
		return false
	}
	if len(v.args) != 1 || v.args[0].name.text != "" || v.args[0].mode != .Value {
		errorf(k.c, v.span, "L0410", "`%s.from_int` takes exactly one plain backing integer argument", type_name(k.c, subject))
		v.type = INVALID_TYPE
		return true
	}
	if !check_value_expr(k, v.args[0].value, underlying_info(k.c, subject).element, "initialize") {
		v.type = INVALID_TYPE
		return true
	}
	v.operation = Call_Enum_From_Int{type = subject}
	v.bound = make([]Expr, 1, k.c.semantic_allocator)
	v.bound[0] = v.args[0].value
	v.type = option_type(k, subject, v.span)
	if v.type == INVALID_TYPE {
		return true
	}
	if base := expr_base(v.bound[0]); base.is_const {
		present := enum_member_by_value(k.c, subject, base.const_value) != INVALID_SYMBOL
		index := union_index_of(k.c, v.type, present ? "some" : "none")
		v.is_const = true
		v.const_value = union_const(k.c, v.type, index, present ? base.const_value : Const_Value{})
	}
	return true
}

// design.md "Iterating an enumeration": the declaration-ordered constant array
// of members, which serves loops, static expansion, and `$` arguments alike.
check_enum_values :: proc(k: ^Checker, v: ^Expr_Call, sel: ^Expr_Selector) -> bool {
	subject := enum_builtin_subject(k, v, sel, "values")
	if subject == INVALID_TYPE {
		return false
	}
	if len(v.args) != 0 {
		errorf(k.c, v.span, "L0460", "`%s.values` takes no arguments", type_name(k.c, subject))
		v.type = INVALID_TYPE
		return true
	}
	members, ok := enum_member_constants(k, subject)
	if !ok {
		v.type = INVALID_TYPE
		return true
	}
	aggregate := new(Const_Aggregate, k.c.semantic_allocator)
	aggregate.type = array_of(k.c, subject, u64(len(members)))
	aggregate.elements = members
	v.type = aggregate.type
	v.is_const = true
	v.const_value = Const_Value{kind = .Aggregate, aggregate = aggregate}
	v.immutable = .Constant
	return true
}

enum_member_constants :: proc(k: ^Checker, enum_type: Type_Id) -> ([]Const_Value, bool) {
	info := underlying_info(k.c, enum_type)
	if info == nil {
		return nil, false
	}
	out := make([]Const_Value, len(info.fields), k.c.semantic_allocator)
	for member, index in info.fields {
		if sym := symbol_of(k.c, member); sym != nil {
			out[index] = sym.const_value
		}
	}
	return out, true
}

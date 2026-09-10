// Closed payloadless sums with an integer representation.
package lokec

// design.md "Integer conversion": validation is a named fallible constructor,
// never a representation-only type conversion.
check_enum_from_int :: proc(k: ^Checker, v: ^Expr_Call, sel: ^Expr_Selector) -> bool {
	if sel.name.text != "from_int" {
		return false
	}
	subject := resolve_type_syntax(k, sel.operand)
	if subject == INVALID_TYPE || !type_is_enum(k.c, subject) {
		return false
	}
	v.value_category = .Value
	v.resolution = Resolution{kind = .Builtin_Operator}
	if len(v.args) != 1 || v.args[0].name.text != "" || v.args[0].mode != .Value {
		errorf(k.c, v.span, "L0410", "`%s.from_int` takes exactly one plain backing integer argument", type_name(k.c, subject))
		v.type = INVALID_TYPE
		return true
	}
	if !check_value_expr(k, v.args[0].value, underlying_info(k.c, subject).element, "initialize") {
		v.type = INVALID_TYPE
		return true
	}
	v.enum_from_int = subject
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

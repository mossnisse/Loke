// `Enum.from_int` and `Enum.values`; members are resolved in check.odin.
package lokec

// An enum the compiler declares, over `int`, numbered in member order.
synth_enum :: proc(c: ^Compiler, name: string, members: []string) -> Type_Id {
	type := new_type(c, Type_Info {
		kind    = .Enum,
		name    = intern_identifier(c, name),
		element = TYPE_INT,
		bits    = u16(type_bits(c, TYPE_INT)),
		signed  = true,
	})
	fields := make([]Symbol_Id, len(members), c.semantic_allocator)
	for member, index in members {
		fields[index] = new_symbol(c, Symbol {
			name        = intern_identifier(c, member),
			span        = no_span(),
			kind        = .Enum_Member,
			type        = type,
			index       = u32(index),
			const_value = Const_Value{kind = .Integer, integer = bi_from_i64(c, i64(index))},
		})
	}
	type_of(c, type).fields = fields
	return type
}

// The compiler-defined `Enum.from_int` and `Enum.values`, which no `impl` or
// `extend` member may shadow.
enum_builtin_member :: proc(name: string) -> bool {
	return name == "from_int" || name == "values"
}

// A `Type.from_int(...)` or `Type.values()` call on an enum, or false if this
// is not one.
check_enum_builtin :: proc(k: ^Checker, v: ^Expr_Call, sel: ^Expr_Selector) -> bool {
	if !enum_builtin_member(sel.name.text) {
		return false
	}
	subject := resolve_type_syntax(k, sel.operand)
	if subject == INVALID_TYPE || !type_is_enum(k.c, subject) {
		return false
	}
	v.value_category = .Value
	v.resolution = Resolution{kind = .Builtin_Operator}
	v.type = INVALID_TYPE
	// The members are still being resolved, so they cannot be counted or searched.
	if sym := symbol_of(k.c, underlying_info(k.c, subject).symbol); sym != nil && sym.decl != nil && sym.decl.sig_state == .Checking {
		errorf(k.c, v.span, "L0324", "constant initialisation cycle involving `%s`", type_name(k.c, subject))
		return true
	}
	if sel.name.text == "values" {
		check_enum_values(k, v, subject)
	} else {
		check_enum_from_int(k, v, subject)
	}
	return true
}

// design.md "Integer conversion": validation is a named fallible constructor,
// never a representation-only type conversion.
@(private = "file")
check_enum_from_int :: proc(k: ^Checker, v: ^Expr_Call, subject: Type_Id) {
	if len(v.args) != 1 || v.args[0].name.text != "" || v.args[0].mode != .Value {
		errorf(k.c, v.span, "L0410", "`%s.from_int` takes exactly one plain integer argument", type_name(k.c, subject))
		return
	}
	// An untyped constant takes the backing type.
	arg := v.args[0].value
	backing := underlying_info(k.c, subject).element
	arg_type := check_single_expr(k, arg, backing)
	if arg_type == INVALID_TYPE || (type_is_untyped(k.c, arg_type) && !materialize(k, arg, backing)) {
		return
	}
	if !type_is_integer(k.c, expr_base(arg).type) {
		errorf(k.c, expr_span(arg), "L0410", "`%s.from_int` takes an integer, found `%s`", type_name(k.c, subject), type_name(k.c, arg_type))
		return
	}
	v.operation = Call_Enum_From_Int{type = subject}
	v.bound = make([]Expr, 1, k.c.semantic_allocator)
	v.bound[0] = arg
	v.type = option_type(k, subject, v.span)
	if v.type == INVALID_TYPE {
		return
	}
	if base := expr_base(arg); base.is_const {
		present := enum_member_by_value(k.c, subject, base.const_value) != INVALID_SYMBOL
		index := union_index_of(k.c, v.type, present ? "some" : "none")
		v.is_const = true
		v.const_value = union_const(k.c, v.type, index, present ? base.const_value : Const_Value{})
	}
}

// design.md "Iterating an enumeration".
@(private = "file")
check_enum_values :: proc(k: ^Checker, v: ^Expr_Call, subject: Type_Id) {
	if len(v.args) != 0 {
		errorf(k.c, v.span, "L0460", "`%s.values` takes no arguments", type_name(k.c, subject))
		return
	}
	fields := underlying_info(k.c, subject).fields
	members := make([]Const_Value, len(fields), k.c.semantic_allocator)
	for member, index in fields {
		members[index] = symbol_of(k.c, member).const_value
	}
	aggregate := new(Const_Aggregate, k.c.semantic_allocator)
	aggregate.type = array_of(k.c, subject, u64(len(members)))
	aggregate.elements = members
	v.type = aggregate.type
	v.is_const = true
	v.const_value = Const_Value{kind = .Aggregate, aggregate = aggregate}
	v.immutable = .Constant
}

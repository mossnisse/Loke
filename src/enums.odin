// Enum members, `Enum.from_int`, and `Enum.values`.
package lokec

// design.md "Enumerations": an enum's members are named constants that need not be
// contiguous.
resolve_enum_members :: proc(k: ^Checker, type: Type_Id, value: ^Type_Enum) {
	backing := TYPE_INT
	if resolved := resolve_type_reporting(k, value.backing); resolved != INVALID_TYPE {
		if type_is_integer(k.c, resolved) {
			backing = resolved
		} else {
			errorf(k.c, expr_span(value.backing), "L0380", "an enum's backing type must be an integer type")
		}
	}
	info := type_of(k.c, type)
	if info != nil {
		info.element = backing
		info.bits = u16(type_bits(k.c, backing))
		info.signed = type_signed(k.c, backing)
		info.enum_backing_explicit = value.backing != nil
	}

	members := make([dynamic]Symbol_Id, 0, len(value.fields), k.c.semantic_allocator)
	seen := new_integer_set(len(value.fields), context.temp_allocator)
	next := bi_from_i64(k.c, 0)
	for &field in value.fields {
		discriminant := next
		if field.value != nil {
			if written, ok := enum_member_value(k, field.value, backing); ok {
				discriminant = written
			}
		} else if !bi_fits(k.c, discriminant, type_bits(k.c, backing), type_signed(k.c, backing)) {
			errorf(k.c, field.name.span, "L0352", "enum member representation does not fit `%s`", type_name(k.c, backing))
		}
		if field.name.text != "" && field.name.text != "_" && member_named(k.c, members[:], name_identifier(k.c, field.name)) != INVALID_SYMBOL {
			errorf(k.c, field.name.span, "L0304", "`%s` is already a member of this enum", field.name.text)
		}
		if !integer_set_add(k.c, &seen, discriminant) {
			errorf(k.c, field.name.span, "L0380", "enum variants must have distinct integer representations")
		}
		field.symbol = new_binding_symbol(k, field.name, .Enum_Member)
		if symbol := symbol_of(k.c, field.symbol); symbol != nil {
			symbol.type = type
			symbol.index = u32(len(members))
			symbol.const_value = Const_Value{kind = .Integer, integer = discriminant}
		}
		if field.symbol != INVALID_SYMBOL {
			append(&members, field.symbol)
		}
		next = bi_add(k.c, discriminant, bi_from_i64(k.c, 1))
	}
	if info != nil {
		info.fields = members[:]
	}
}

// A member's written value, reported when it is not one the backing type holds.
@(private = "file")
enum_member_value :: proc(k: ^Checker, value: Expr, backing: Type_Id) -> (Big_Int, bool) {
	if check_single_expr(k, value, backing) == INVALID_TYPE {
		return {}, false
	}
	folded, evaluated := require_const(k, value, "an enum member's value", "L0380")
	if !evaluated {
		return {}, false
	}
	if folded.kind != .Integer && folded.kind != .Rune {
		errorf(k.c, expr_span(value), "L0380", "an enum member's value must be a constant integer")
		return {}, false
	}
	if !bi_fits(k.c, folded.integer, type_bits(k.c, backing), type_signed(k.c, backing)) {
		errorf(
			k.c, expr_span(value), "L0352", "%s is not representable by `%s`",
			bi_text(k.c, folded.integer), type_name(k.c, backing),
		)
		return {}, false
	}
	return folded.integer, true
}

// An enum's members by value, for those that fit `i64`.
enum_members_by_value :: proc(c: ^Compiler, type: Type_Id) -> map[i64]Symbol_Id {
	info := underlying_info(c, type)
	members := make(map[i64]Symbol_Id, len(info.fields), context.temp_allocator)
	for member in info.fields {
		symbol := symbol_of(c, member)
		if symbol != nil && symbol.const_value.kind == .Integer {
			if value, fits := bi_to_i64(c, symbol.const_value.integer); fits {
				members[value] = member
			}
		}
	}
	return members
}

// The member whose value is `value`, or none: a value the type never admits.
enum_member_by_value :: proc(c: ^Compiler, type: Type_Id, value: Const_Value) -> Symbol_Id {
	info := underlying_info(c, type)
	if info == nil || value.kind != .Integer {
		return INVALID_SYMBOL
	}
	for member in info.fields {
		symbol := symbol_of(c, member)
		if symbol == nil || symbol.const_value.kind != .Integer {
			continue
		}
		if bi_cmp(c, symbol.const_value.integer, value.integer) == 0 {
			return member
		}
	}
	return INVALID_SYMBOL
}

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
			span        = NO_SPAN,
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
	subject := receiver_denoted_type(k, sel)
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
	if !has_one_plain_argument(v) {
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
	if base := expr_base(arg); base_is_const(base) {
		present := enum_member_by_value(k.c, subject, base.const_value) != INVALID_SYMBOL
		index := union_index_of(k.c, v.type, present ? "some" : "none")
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
	v.const_value = Const_Value{kind = .Aggregate, aggregate = aggregate}
	v.immutable = .Constant
}

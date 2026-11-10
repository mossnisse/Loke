// Runtime text: the operations a `string`, `string_view`, or `cstring_view`
// answers to (design.md "string type", "string type conversions", "C string
// views"). They are compiler-defined because their operand and result types are
// all built in, and Loke has no methods on built-in types.
package lokec

// The two carriers that promise valid UTF-8 and carry a byte length. A
// `cstring_view` makes no encoding promise (design.md).
type_is_utf8_text :: proc(c: ^Compiler, id: Type_Id) -> bool {
	#partial switch underlying_kind(c, id) {
	case .String, .String_View:
		return true
	}
	return false
}

// Nominal: a `distinct` text type inherits none of these operations (design.md
// "Distinct types").
@(private = "file")
type_is_text :: proc(c: ^Compiler, id: Type_Id) -> bool {
	info := type_of(c, id)
	return info != nil && (info.kind == .String || info.kind == .String_View || info.kind == .CString_View)
}

// `text.op()`, `string.from_runes(...)`, `string.from_utf8(...)` /
// `string_view.from_utf8(...)`, or `cstring_view.from_bytes(...)`. Returns true
// when the selector named one, so the caller stops looking for an ordinary method.
check_text_operation :: proc(k: ^Checker, v: ^Expr_Call, sel: ^Expr_Selector) -> bool {
	name := sel.name.text
	op := text_op_named(name)
	if op == .None && name != "from_utf8" && name != "from_runes" && name != "from_bytes" {
		return false
	}
	operand := check_receiver(k, sel)
	if operand == INVALID_TYPE {
		return false
	}
	// design.md "string type": an unfixed string receiver is a `string_view` of the
	// literal's static storage, so it takes the view's methods and borrows nothing
	// that ends.
	if operand == TYPE_UNTYPED_STRING && op != .None {
		operand = materialize(k, sel.operand, TYPE_STRING_VIEW) ? TYPE_STRING_VIEW : INVALID_TYPE
	}

	if base := expr_base(sel.operand); base.value_category == .Type {
		switch {
		case name == "from_utf8" && (base.denoted_type == TYPE_STRING || base.denoted_type == TYPE_STRING_VIEW):
			check_from_utf8(k, v, base.denoted_type)
		case name == "from_bytes" && base.denoted_type == TYPE_CSTRING_VIEW:
			check_from_utf8(k, v, base.denoted_type)
		case name == "from_runes" && base.denoted_type == TYPE_STRING:
			check_from_runes(k, v)
		case:
			return false
		}
		return true
	}
	if op == .None || !type_is_text(k.c, operand) {
		return false
	}

	v.operation = Call_Text{op = op}
	v.resolution = Resolution{kind = .Builtin_Operator}
	v.bound = bound_exprs(k, sel.operand)
	if len(v.args) != 0 {
		errorf(k.c, v.span, "L0561", "`%s` takes no arguments, found %d", name, len(v.args))
		return true
	}
	// A `cstring_view` is terminated, not measured, so it has none of these;
	// `to_c_view` needs a `string`'s terminator.
	kind := type_of(k.c, operand).kind
	if op == .To_C_View ? kind != .String : kind == .CString_View {
		errorf(k.c, sel.span, "L0561", "`%s` is not available on `%s`", name, type_name(k.c, operand))
		return true
	}

	#partial switch op {
	case .Byte_Len, .Rune_Count:
		v.type = TYPE_INT
	case .Bytes:
		v.type = slice_of(k.c, TYPE_U8, mutable = false)
	case .Runes:
		// design.md "String iteration": the rune traversal is the view's own
		// `Element`, so this borrows rather than copies.
		v.type = TYPE_STRING_VIEW
		ensure_iteration_members(k, TYPE_STRING_VIEW)
	case .Rune_Offsets:
		v.type = container_view_type(k.c, TYPE_STRING_VIEW, .Rune_Offsets)
		ensure_iteration_members(k, v.type)
	case .Copy:
		v.type = TYPE_STRING
	case .To_C_View:
		v.type = TYPE_CSTRING_VIEW
	case .To_Runes:
		// An owner, so its lifecycle members must exist before it is built.
		v.type = dynamic_array_of(k.c, TYPE_RUNE)
		ensure_container_members(k, v.type)
		contribute_lifecycle_members(k, v.type)
	}
	return true
}

// The member each operation is written as.
@(private = "file", rodata)
TEXT_OP_NAMES := [Text_Op]string {
	.None         = "",
	.Byte_Len     = "byte_len",
	.Rune_Count   = "rune_count",
	.Bytes        = "bytes",
	.Runes        = "runes",
	.Rune_Offsets = "rune_offsets",
	.Copy         = "copy",
	.To_C_View    = "to_c_view",
	.To_Runes     = "to_runes",
}

@(private = "file")
text_op_named :: proc(name: string) -> Text_Op {
	for op_name, op in TEXT_OP_NAMES {
		if op != .None && op_name == name {
			return op
		}
	}
	return .None
}

// design.md "string type conversions" and "Typed fallibility": the validating
// constructors produce `Option(T)`, `.none` for invalid input. The one argument
// is a value, by position or under `parameter`, and a `[dynamic]T` or `[N]T` reads
// as the slice expected (design.md "Implicit type conversions"). Its type, or
// INVALID_TYPE once reported.
@(private = "file")
text_constructor_source :: proc(k: ^Checker, v: ^Expr_Call, name, parameter: string, element: Type_Id) -> Type_Id {
	if len(v.args) != 1 {
		errorf(k.c, v.span, "L0561", "`%s` takes one argument, found %d", name, len(v.args))
		return INVALID_TYPE
	}
	arg := v.args[0]
	if arg.mode != .Value || (arg.name.text != "" && arg.name.text != parameter) {
		errorf(k.c, arg.span, "L0561", "`%s` takes one value argument named `%s`", name, parameter)
		return INVALID_TYPE
	}
	expected := slice_of(k.c, element, mutable = false)
	source := check_single_expr(k, arg.value, expected)
	if source != INVALID_TYPE && array_views_as(k.c, source, expected) && !materialize(k, arg.value, expected) {
		return INVALID_TYPE
	}
	return expr_base(arg.value).type
}

@(private = "file")
bind_text_constructor :: proc(k: ^Checker, v: ^Expr_Call, op: Text_Conversion, target: Type_Id) {
	v.resolution = Resolution{kind = .Builtin_Operator}
	v.operation = Call_Text_Conversion{op = op}
	v.bound = bound_exprs(k, v.args[0].value)
	v.type = option_type(k, target, v.span)
}

@(private = "file")
check_from_runes :: proc(k: ^Checker, v: ^Expr_Call) {
	source := text_constructor_source(k, v, "string.from_runes", "runes", TYPE_RUNE)
	if source == INVALID_TYPE {
		return
	}
	if info := type_of(k.c, source); info.kind != .Slice || info.element != TYPE_RUNE {
		errorf(
			k.c, expr_span(v.args[0].value), "L0561",
			"`string.from_runes` takes a `[]rune`, found `%s`", type_name(k.c, source),
		)
		return
	}
	bind_text_constructor(k, v, .String_From_Runes, TYPE_STRING)
}

@(private = "file")
check_from_utf8 :: proc(k: ^Checker, v: ^Expr_Call, target: Type_Id) {
	name, op := "string.from_utf8", Text_Conversion.String_From_Bytes
	switch target {
	case TYPE_STRING_VIEW:  name, op = "string_view.from_utf8", .View_From_Bytes
	case TYPE_CSTRING_VIEW: name, op = "cstring_view.from_bytes", .C_View_From_Bytes
	}
	source := text_constructor_source(k, v, name, "bytes", TYPE_U8)
	if source == INVALID_TYPE {
		return
	}
	// Nominal, like the receivers: a `distinct` byte slice needs a written conversion.
	info := type_of(k.c, source)
	if target == TYPE_STRING && info.kind == .CString_View {
		op = .String_From_C_View
	} else if info.kind != .Slice || info.element != TYPE_U8 {
		accepted := target == TYPE_STRING ? "a `[]u8` or `cstring_view`" : "a `[]u8`"
		errorf(k.c, expr_span(v.args[0].value), "L0561", "`%s` takes %s, found `%s`", name, accepted, type_name(k.c, source))
		return
	}
	bind_text_constructor(k, v, op, target)
}

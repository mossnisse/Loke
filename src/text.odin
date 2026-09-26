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

// `text.op()`, `string.from_runes(...)`, or `string.from_utf8(...)` /
// `string_view.from_utf8(...)`. Returns true when the selector named one, so the
// caller stops looking for an ordinary method.
check_text_operation :: proc(k: ^Checker, v: ^Expr_Call, sel: ^Expr_Selector) -> bool {
	name := sel.name.text
	op := text_op_named(name)
	if op == .None && name != "from_utf8" && name != "from_runes" {
		return false
	}
	// A receiver that is a name already knows its type, so an ordinary method
	// call's receiver is not checked here and then again as a method.
	if ident, is_ident := sel.operand.(^Expr_Ident); is_ident {
		sym := symbol_of(k.c, lookup_symbol(k.scope, identifier_of(k.c, ident)))
		if sym != nil && sym.kind != .Type && sym.const_value.kind != .Type &&
		   !type_is_text(k.c, sym.type) && sym.type != TYPE_UNTYPED_STRING {
			return false
		}
	}
	operand := check_single_expr(k, sel.operand)
	if operand == INVALID_TYPE {
		return false
	}
	if operand == TYPE_UNTYPED_STRING && op != .None {
		operand = fix_string_receiver(k, sel.operand)
	}

	if base := expr_base(sel.operand); base.value_category == .Type {
		switch {
		case name == "from_utf8" && (base.denoted_type == TYPE_STRING || base.denoted_type == TYPE_STRING_VIEW):
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

	v.value_category = .Value
	v.operation = Call_Text{op = op}
	v.resolution = Resolution{kind = .Builtin_Operator}
	v.bound = make([]Expr, 1, k.c.semantic_allocator)
	v.bound[0] = sel.operand
	v.type = INVALID_TYPE
	if len(v.args) != 0 {
		errorf(k.c, v.span, "L0561", "`%s` takes no arguments, found %d", name, len(v.args))
		return true
	}
	// A `cstring_view` is terminated, not measured, so it answers only to what a
	// `string` converts it to; `to_c_view` needs a `string`'s terminator.
	kind := type_of(k.c, operand).kind
	if op == .To_C_View ? kind != .String : kind == .CString_View {
		errorf(k.c, sel.span, "L0561", "`%s` is not available on `%s`", name, type_name(k.c, operand))
		return true
	}

	#partial switch op {
	case .Byte_Len, .Rune_Count:
		v.type = TYPE_INT
	case .Bytes:
		// Read-only: a `string`'s bytes never become `[]mut u8`.
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
		ensure_container_fields(k.c, v.type)
		ensure_container_members(k, v.type)
		contribute_lifecycle_members(k, v.type)
	}
	return true
}

// design.md "string type": an unfixed string receiver is a `string_view` of the
// literal's static storage, so it takes the view's methods and borrows nothing
// that ends.
fix_string_receiver :: proc(k: ^Checker, operand: Expr) -> Type_Id {
	return materialize(k, operand, TYPE_STRING_VIEW) ? TYPE_STRING_VIEW : INVALID_TYPE
}

@(private = "file")
text_op_named :: proc(name: string) -> Text_Op {
	switch name {
	case "byte_len":
		return .Byte_Len
	case "rune_count":
		return .Rune_Count
	case "bytes":
		return .Bytes
	case "runes":
		return .Runes
	case "rune_offsets":
		return .Rune_Offsets
	case "copy":
		return .Copy
	case "to_c_view":
		return .To_C_View
	case "to_runes":
		return .To_Runes
	}
	return .None
}

// design.md "string type conversions" and "Typed fallibility": the validating
// constructors produce `Option(T)`, `.none` for invalid input.
@(private = "file")
check_from_runes :: proc(k: ^Checker, v: ^Expr_Call) {
	v.value_category = .Value
	v.operation = Call_Text{op = .From_Runes}
	v.resolution = Resolution{kind = .Builtin_Operator}
	if len(v.args) != 1 {
		errorf(k.c, v.span, "L0561", "`string.from_runes` takes one `[]rune`, found %d arguments", len(v.args))
		v.type = INVALID_TYPE
		return
	}
	operand := check_single_expr(k, v.args[0].value, slice_of(k.c, TYPE_RUNE, mutable = false))
	if operand == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}
	if info := type_of(k.c, operand); info.kind != .Slice || info.element != TYPE_RUNE {
		errorf(
			k.c, expr_span(v.args[0].value), "L0561",
			"`string.from_runes` takes a `[]rune`, found `%s`", type_name(k.c, operand),
		)
		v.type = INVALID_TYPE
		return
	}
	v.bound = make([]Expr, 1, k.c.semantic_allocator)
	v.bound[0] = v.args[0].value
	v.type = option_type(k, TYPE_STRING, v.span)
}

@(private = "file")
check_from_utf8 :: proc(k: ^Checker, v: ^Expr_Call, target: Type_Id) {
	v.value_category = .Value
	name := target == TYPE_STRING ? "string.from_utf8" : "string_view.from_utf8"
	if len(v.args) != 1 {
		errorf(k.c, v.span, "L0561", "`%s` takes one argument, found %d", name, len(v.args))
		v.type = INVALID_TYPE
		return
	}
	arg := v.args[0]
	if arg.mode != .Value || (arg.name.text != "" && arg.name.text != "bytes") {
		errorf(k.c, arg.span, "L0561", "`%s` takes one value argument named `bytes`", name)
		v.type = INVALID_TYPE
		return
	}
	source := check_single_expr(k, arg.value, slice_of(k.c, TYPE_U8, mutable = false))
	if source == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}
	// Nominal, like the receivers: a `distinct` byte slice needs a written conversion.
	info := type_of(k.c, source)
	op := Text_Conversion.None
	switch {
	case info.kind == .Slice && info.element == TYPE_U8:
		op = target == TYPE_STRING ? .String_From_Bytes : .View_From_Bytes
	case target == TYPE_STRING && info.kind == .CString_View:
		op = .String_From_C_View
	case:
		accepted := target == TYPE_STRING ? "a `[]u8` or `cstring_view`" : "a `[]u8`"
		errorf(k.c, expr_span(arg.value), "L0561", "`%s` takes %s, found `%s`", name, accepted, type_name(k.c, source))
		v.type = INVALID_TYPE
		return
	}
	v.resolution = Resolution{kind = .Builtin_Operator}
	v.operation = Call_Text_Conversion{op = op}
	v.bound = make([]Expr, 1, k.c.semantic_allocator)
	v.bound[0] = arg.value
	v.type = option_type(k, target, v.span)
}

// ----------------------------------------------------------- core:strings --

// `allocate_string(text, allocator) -> (string, Allocator_Error)`, the
// package-private primitive `core:strings` wraps: a copy of already-valid UTF-8
// from the caller's allocator.
check_strings_allocate :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident) {
	v.value_category = .Value
	if len(v.args) != 2 {
		errorf(
			k.c, v.span, "L0637",
			"`%s` takes a `string_view` and an `Allocator`, found %d argument%s",
			ident.name, len(v.args), len(v.args) == 1 ? "" : "s",
		)
		v.type = INVALID_TYPE
		return
	}
	bound := make([]Expr, 2, k.c.semantic_allocator)
	for target, index in ([]Type_Id{TYPE_STRING_VIEW, TYPE_ALLOCATOR}) {
		value, passed := check_argument_value(k, v.args[index].value, target)
		bound[index] = value
		if !passed {
			v.type = INVALID_TYPE
			return
		}
	}
	v.bound = bound
	v.type = result_type(k, TYPE_STRING, TYPE_ALLOCATOR_ERROR)
}

// ------------------------------------------------------------ core:unsafe --

// design.md "unsafe.raw_data procedure":
//
//	unsafe.raw_data([]$E | []mut $E | [dynamic]$E) -> [^]E
//	unsafe.raw_data(^[$N]$E)                        -> [^]E   one array level
//	unsafe.raw_data(string | string_view | cstring_view) -> [^]byte
//
// and the two view constructors whose operands the compiler cannot trace to an
// owner.
check_unsafe_builtin :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident, kind: Builtin_Kind) {
	v.value_category = .Value
	arity := kind == .Unsafe_String_View ? 2 : 1
	if len(v.args) != arity {
		errorf(
			k.c, v.span, "L0569",
			"`unsafe.%s` takes %d argument%s, found %d",
			ident.name, arity, arity == 1 ? "" : "s", len(v.args),
		)
		v.type = INVALID_TYPE
		return
	}
	bound := make([]Expr, arity, k.c.semantic_allocator)
	for index in 0 ..< arity {
		bound[index] = v.args[index].value
	}
	v.bound = bound
	operand := check_single_expr(k, bound[0])
	if operand == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}
	info := underlying_info(k.c, operand)
	is_byte_pointer := info.kind == .C_Pointer && info.element == TYPE_U8

	#partial switch kind {
	case .Unsafe_Raw_Data:
		element := INVALID_TYPE
		#partial switch info.kind {
		case .Slice, .Dynamic_Array:
			element = info.element
		case .Pointer:
			if pointee := underlying_info(k.c, info.element); pointee != nil && pointee.kind == .Array {
				element = pointee.element
			}
		case .String, .String_View, .CString_View:
			element = TYPE_U8
		}
		if element == INVALID_TYPE {
			errorf(
				k.c, expr_span(bound[0]), "L0569",
				"`unsafe.raw_data` takes a slice, a pointer to a fixed array, or text, found `%s`",
				type_name(k.c, operand),
			)
			v.type = INVALID_TYPE
			return
		}
		v.type = c_pointer_to(k.c, element)

	case .Unsafe_String_View:
		// Borrowed from an owner the compiler cannot see, but still validated: the
		// result promises UTF-8.
		if !is_byte_pointer {
			errorf(
				k.c, expr_span(bound[0]), "L0569",
				"`unsafe.string_view` takes a `[^]u8` and a length, found `%s`",
				type_name(k.c, operand),
			)
			v.type = INVALID_TYPE
			return
		}
		if length := check_single_expr(k, bound[1], TYPE_INT); length != INVALID_TYPE {
			materialize(k, bound[1], TYPE_INT)
			if !type_is_integer(k.c, expr_base(bound[1]).type) {
				errorf(k.c, expr_span(bound[1]), "L0569", "a length must be an integer, found `%s`", type_name(k.c, length))
				v.type = INVALID_TYPE
				return
			}
		}
		v.type = option_type(k, TYPE_STRING_VIEW, v.span)

	case .Unsafe_C_String_View:
		// Not validated at all: a `cstring_view` promises no encoding.
		if !is_byte_pointer {
			errorf(
				k.c, expr_span(bound[0]), "L0569",
				"`unsafe.cstring_view` takes a `[^]u8`, found `%s`", type_name(k.c, operand),
			)
			v.type = INVALID_TYPE
			return
		}
		v.type = TYPE_CSTRING_VIEW
	}
}

// Runtime text: the operations a `string`, `string_view`, or `cstring_view`
// answers to (design.md "string type", "string type conversions", "C string
// views").
//
// These are compiler-defined rather than library members because both operand
// and result types are built in: `bytes()` on a `string` produces the `[]u8`
// the slice machinery already owns, and `copy()` produces the managed carrier
// the lifecycle analysis already tracks. Writing them as `core:strings`
// procedures would need a nonexistent feature — a method on a built-in type —
// and would change nothing about what they lower to.
package lokec

// Whether a type is one of the three text carriers.
type_is_text :: proc(c: ^Compiler, id: Type_Id) -> bool {
	#partial switch underlying_kind(c, id) {
	case .String, .String_View, .CString_View:
		return true
	}
	return false
}

// The two carriers that promise valid UTF-8 and carry a byte length. A
// `cstring_view` is neither: foreign strings often use another encoding or
// arbitrary bytes, so it makes no UTF-8 promise (design.md).
type_is_utf8_text :: proc(c: ^Compiler, id: Type_Id) -> bool {
	#partial switch underlying_kind(c, id) {
	case .String, .String_View:
		return true
	}
	return false
}

// `text.op(...)`. Returns true when the selector named a text operation, so the
// caller stops looking for an ordinary method.
check_text_operation :: proc(k: ^Checker, v: ^Expr_Call, sel: ^Expr_Selector) -> bool {
	// Two cheap filters, so an ordinary method call's receiver is not checked
	// twice on the way to failing here: only these names can name a text
	// operation, and a receiver that is a name already knows its type — which
	// keeps a record's generated `clone` off this path.
	if text_op_named(sel.name.text) == .None && sel.name.text != "from_runes" && sel.name.text != "from_utf8" {
		return false
	}
	if ident, is_ident := sel.operand.(^Expr_Ident); is_ident {
		sym := symbol_of(k.c, lookup_symbol(k.scope, identifier_of(k.c, ident)))
		if sym != nil && sym.kind != .Type && sym.const_value.kind != .Type && !type_is_text(k.c, sym.type) {
			return false
		}
	}

	// Resolve aliases and generic type parameters before inspecting the type
	// category; built-in type syntax already has that category from parsing.
	if sel.name.text == "from_utf8" || sel.name.text == "from_runes" {
		if check_single_expr(k, sel.operand) == INVALID_TYPE { return false }
	}
	// Named validating constructors select through the type, not a value.
	if base := expr_base(sel.operand); base != nil && base.value_category == .Type {
		if sel.name.text == "from_utf8" && (base.denoted_type == TYPE_STRING || base.denoted_type == TYPE_STRING_VIEW) {
			check_from_utf8(k, v, base.denoted_type)
			return true
		}
		if type_underlying(k.c, base.denoted_type) != TYPE_STRING || sel.name.text != "from_runes" {
			return false
		}
		check_from_runes(k, v)
		return true
	}

	operand := check_single_expr(k, sel.operand)
	if operand == INVALID_TYPE || !type_is_text(k.c, operand) {
		return false
	}
	op := text_op_named(sel.name.text)
	if op == .None {
		return false
	}

	v.value_category = .Value
	v.operation = Call_Text{op = op}
	v.resolution = Resolution{kind = .Builtin_Operator}
	bound := make([]Expr, 1, k.c.semantic_allocator)
	bound[0] = sel.operand
	v.bound = bound
	if len(v.args) != 0 {
		errorf(k.c, v.span, "L0561", "`%s` takes no arguments, found %d", sel.name.text, len(v.args))
		v.type = INVALID_TYPE
		return true
	}

	kind := underlying_kind(k.c, operand)
	switch op {
	case .None:
		v.type = INVALID_TYPE

	case .Byte_Len, .Rune_Count:
		// design.md: a `cstring_view` has no length of its own — it is terminated,
		// not measured — so it is converted to `string` first.
		if !type_is_utf8_text(k.c, operand) {
			text_operand_error(k, v, sel, operand)
			return true
		}
		v.type = TYPE_INT

	case .Bytes:
		if !type_is_utf8_text(k.c, operand) {
			text_operand_error(k, v, sel, operand)
			return true
		}
		// A view obtained from a `string` is `[]u8`, not `[]mut u8` — it cannot be
		// converted to the mutable form (design.md "string type conversions").
		v.type = slice_of(k.c, TYPE_U8, mutable = false)

	case .Runes:
		// design.md "String iteration": the rune traversal *is* the string's own
		// `Element`, so `runes()` hands back a borrowed `string_view` rather than a
		// wrapper of its own. Nothing is copied and nothing is allocated.
		if !type_is_utf8_text(k.c, operand) {
			text_operand_error(k, v, sel, operand)
			return true
		}
		v.type = TYPE_STRING_VIEW
		ensure_iteration_members(k, TYPE_STRING_VIEW)

	case .Rune_Offsets:
		// The byte offset a code point begins at is a second traversal, so it needs
		// an `Element` and an `Iterator` of its own. The view holds the borrowed
		// bytes and nothing else.
		if !type_is_utf8_text(k.c, operand) {
			text_operand_error(k, v, sel, operand)
			return true
		}
		v.type = container_view_type(k.c, TYPE_STRING_VIEW, .Rune_Offsets)
		ensure_iteration_members(k, v.type)

	case .Copy:
		if !type_is_utf8_text(k.c, operand) {
			text_operand_error(k, v, sel, operand)
			return true
		}
		v.type = TYPE_STRING

	case .To_C_View:
		if kind != .String {
			text_operand_error(k, v, sel, operand)
			return true
		}
		v.type = TYPE_CSTRING_VIEW

	case .To_Runes:
		// design.md "string type conversions": `[dynamic]rune` by copy. The result
		// is an owner, so its lifecycle members have to exist before it is built.
		if !type_is_utf8_text(k.c, operand) {
			text_operand_error(k, v, sel, operand)
			return true
		}
		v.type = dynamic_array_of(k.c, TYPE_RUNE)
		ensure_container_fields(k.c, v.type)
		ensure_container_members(k, v.type)
		contribute_lifecycle_members(k, v.type)

	case .From_Runes:
		v.type = INVALID_TYPE // reached only through the type-name path above
	}
	return true
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

@(private = "file")
text_operand_error :: proc(k: ^Checker, v: ^Expr_Call, sel: ^Expr_Selector, operand: Type_Id) {
	errorf(
		k.c, sel.span, "L0561",
		"`%s` is not available on `%s`",
		sel.name.text, type_name(k.c, operand),
	)
	v.type = INVALID_TYPE
}

// design.md "string type conversions": `string.from_runes(st)` validates and
// copies, with optional-ok semantics.
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
	if slice_element(k.c, operand) != TYPE_RUNE {
		errorf(
			k.c, expr_span(v.args[0].value), "L0561",
			"`string.from_runes` takes a `[]rune`, found `%s`", type_name(k.c, operand),
		)
		v.type = INVALID_TYPE
		return
	}
	bound := make([]Expr, 1, k.c.semantic_allocator)
	bound[0] = v.args[0].value
	v.bound = bound
	set_optional_ok_results(k, v, TYPE_STRING)
}

// design.md "Typed fallibility": a validating conversion produces
// `Option(value)`; invalid input is `.none` rather than a zero paired with a
// `false` nobody is obliged to read.
set_optional_ok_results :: proc(k: ^Checker, v: ^Expr_Call, value: Type_Id) {
	v.type = option_type(k, value, v.span)
}

// design.md "string type conversions": validation belongs to a named
// constructor returning Option(T); a type call T(value) always produces T.
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
	if source == INVALID_TYPE { v.type = INVALID_TYPE; return }
	target_kind := underlying_kind(k.c, target)
	source_kind := underlying_kind(k.c, source)
	op := Text_Conversion.None
	switch {
	case target_kind == .String && source_kind == .Slice && slice_element(k.c, source) == TYPE_U8:
		op = .String_From_Bytes
	case target_kind == .String_View && source_kind == .Slice && slice_element(k.c, source) == TYPE_U8:
		op = .View_From_Bytes
	case target_kind == .String && source_kind == .CString_View:
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
	v.bound[0] = v.args[0].value
	set_optional_ok_results(k, v, target)
}

// ----------------------------------------------------------- core:strings --

// `allocate_string(text, allocator) -> (string, Allocator_Error)`, the
// package-private primitive `core:strings` wraps. The bytes come from a
// `string_view`, which already promises valid UTF-8, so this copies without
// re-validating; the allocator is the caller's, which is the whole point.
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
//	unsafe.raw_data([]$E)          -> [^]E   read-only slices; capability discarded
//	unsafe.raw_data([]mut $E)      -> [^]E
//	unsafe.raw_data([dynamic]$E)   -> [^]E
//	unsafe.raw_data(^[$N]$E)       -> [^]E   fixed arrays
//	unsafe.raw_data(string)        -> [^]byte
//	unsafe.raw_data(string_view)   -> [^]byte
//	unsafe.raw_data(cstring_view)  -> [^]byte
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
	under := type_underlying(k.c, operand)
	info := type_of(k.c, under)

	switch kind {
	case .None, .Assert, .Panic, .Size_Of, .Align_Of, .Offset_Of, .Is_Copyable,
	     .Static_Assert, .Build_Config, .Source_Location, .Caller_Location,
	     .Type_Of, .Typeid_Of, .Fields_Of, .Enum_Values_Of, .New, .New_Clone, .Make, .Free,
	     .Free_All, .Default_Allocator, .Drop, .Exchange, .Type_Info_Of, .Unsafe_Forget, .Unsafe_Free,
	     .Unsafe_Take, .Unsafe_Write,
	     .Unsafe_Transmute, .Simd_Cast, .Simd_Select, .Simd_Reduce,
	     .Fmt_Stdout_Writer, .Fmt_Stderr_Writer, .Fmt_Write_Bytes, .Fmt_Format_Any,
	     .Strings_Allocate, .Slice_Sort_By,
	     .Atomic_Load, .Atomic_Store, .Atomic_Exchange, .Atomic_Compare_Exchange,
	     .Atomic_Add, .Atomic_Sub, .Atomic_And, .Atomic_Or, .Atomic_Xor, .Atomic_Fence:
		v.type = INVALID_TYPE

	case .Unsafe_Raw_Data:
		element := INVALID_TYPE
		#partial switch info.kind {
		case .Slice:
			element = info.element
		case .Pointer:
			// For a nested fixed array, `unsafe.raw_data` exposes one array level
			// at a time (design.md).
			if pointee := underlying_info(k.c, info.element); pointee != nil && pointee.kind == .Array {
				element = pointee.element
			}
		case .String, .String_View, .CString_View:
			element = TYPE_U8
		case .Dynamic_Array:
			// The result carries neither length nor owner (design.md), crossing the
			// unsafe boundary exactly as a slice's does. The container may relocate
			// its storage later and nothing here records that — the point of the
			// boundary.
			element = info.element
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
		// An unsafe validate-and-borrow, optional-ok (design.md "string type
		// conversions"). The owner is unknown to the compiler, so keeping
		// storage alive is the caller's job — but bytes are still validated, since
		// the result type promises UTF-8.
		if info == nil || info.kind != .C_Pointer || info.element != TYPE_U8 {
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
		set_optional_ok_results(k, v, TYPE_STRING_VIEW)

	case .Unsafe_C_String_View:
		// design.md "string type conversions": an unsafe borrow, and no
		// validation at all — a `cstring_view` promises no encoding.
		if info == nil || info.kind != .C_Pointer || info.element != TYPE_U8 {
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

// ------------------------------------------------------- source locations --

// design.md "`source_location() or source_location(<entity>)`": returns a
// `runtime.Source_Code_Location`, for the current location with no arguments or
// for the declaration of a named entity with one.
//
// Every field is known at compile time, so the whole thing folds to one
// constant aggregate over static storage and costs nothing at run time.
check_location :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident) {
	v.value_category = .Value
	type, resolved := runtime_type_named(k, "Source_Code_Location")
	if !resolved {
		errorf(
			k.c, v.span, "L0573",
			"`%s` produces a `runtime.Source_Code_Location`; add `import \"base:runtime\"` to this file's package",
			ident.name,
		)
		v.type = INVALID_TYPE
		return
	}
	span := v.span
	switch len(v.args) {
	case 0:
	case 1:
		// The declaration span of the named entity, not the span of naming it.
		declared, found := entity_declaration_span(k, v.args[0].value)
		if !found {
			errorf(k.c, expr_span(v.args[0].value), "L0573", "`source_location` takes a declared name")
			v.type = INVALID_TYPE
			return
		}
		span = declared
	case:
		errorf(k.c, v.span, "L0573", "`source_location` takes at most one name, found %d", len(v.args))
		v.type = INVALID_TYPE
		return
	}
	v.type = type
	v.is_const = true
	v.const_value = source_location_const(k, type, span)
}

// `{file, procedure: string_view, line, column: int}`, all four constant. The
// type itself comes from the `base:runtime` this package imports, looked up
// rather than owned a second time, which is what keeps one identity between the
// compiler, the seed runtime, and the library.
source_location_const :: proc(k: ^Checker, type: Type_Id, span: Span) -> Const_Value {
	file, line, column := "", 0, 0
	if span.file != NO_FILE && int(span.file) < len(k.c.sources) {
		source := &k.c.sources[span.file]
		file = source.path
		line, column = line_col(source, span.lo)
	}
	elements := make([]Const_Value, 4, k.c.semantic_allocator)
	elements[0] = Const_Value{kind = .String, text = file}
	elements[1] = Const_Value{kind = .String, text = enclosing_procedure_name(k)}
	elements[2] = int_const(k.c, i64(line))
	elements[3] = int_const(k.c, i64(column))
	aggregate := new(Const_Aggregate, k.c.semantic_allocator)
	aggregate.type = type
	aggregate.elements = elements
	return Const_Value{kind = .Aggregate, aggregate = aggregate}
}

@(private = "file")
enclosing_procedure_name :: proc(k: ^Checker) -> string {
	if k.proc_literal != nil && k.proc_literal.symbol != INVALID_SYMBOL {
		if sym := symbol_of(k.c, k.proc_literal.symbol); sym != nil {
			return identifier_text(k.c, sym.name)
		}
	}
	return ""
}

@(private = "file")
entity_declaration_span :: proc(k: ^Checker, e: Expr) -> (Span, bool) {
	ident, is_ident := e.(^Expr_Ident)
	if !is_ident {
		return no_span(), false
	}
	sym := symbol_of(k.c, lookup_symbol(k.scope, identifier_of(k.c, ident)))
	if sym == nil {
		return no_span(), false
	}
	return sym.span, true
}

// design.md "`caller_location()`": denotes the calling code's source location.
// It lives as a procedure parameter's default value, evaluated at each call
// that omits the argument, like any other default.
//
// At the declaration it types the parameter and carries the declaration's own
// span, but nothing observes that span: every omitting call substitutes its
// own location first.
check_caller_location :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident) {
	v.value_category = .Value
	if len(v.args) != 0 {
		errorf(k.c, v.span, "L0573", "`caller_location` takes no arguments, found %d", len(v.args))
		v.type = INVALID_TYPE
		return
	}
	type, resolved := runtime_type_named(k, "Source_Code_Location")
	if !resolved {
		errorf(
			k.c, v.span, "L0573",
			"`caller_location` produces a `runtime.Source_Code_Location`; add `import \"base:runtime\"` to this file's package",
		)
		v.type = INVALID_TYPE
		return
	}
	v.type = type
	v.is_const = true
	v.const_value = source_location_const(k, type, v.span)
}

// One omitted argument whose default is `caller_location()`, replaced by a
// constant for *this* call. Any other default is passed through untouched.
substitute_caller_location :: proc(k: ^Checker, default: Expr, at: Span) -> Expr {
	call, is_call := default.(^Expr_Call)
	if !is_call || call.type == INVALID_TYPE {
		return default
	}
	sym := symbol_of(k.c, call.resolution.symbol)
	if sym == nil || sym.kind != .Builtin || sym.builtin != .Caller_Location {
		return default
	}
	substituted := new(Expr_Call, k.c.semantic_allocator)
	substituted^ = call^
	substituted.span = at
	substituted.const_value = source_location_const(k, call.type, at)
	return substituted
}

// ------------------------------------------------------------- variadics --

// The index of a procedure type's variadic parameter, or -1. design.md allows
// exactly one, and it is always the last.
variadic_parameter_index :: proc(info: ^Type_Info) -> int {
	if info == nil || len(info.param_modes) == 0 {
		return -1
	}
	last := len(info.param_modes) - 1
	return info.param_modes[last] == .Variadic ? last : -1
}

// design.md "Variadic parameters": zero or more explicit arguments, or one or
// more `..slice` spreads, or both. The callee always receives one read-only
// slice, so packing happens here and the ABI matches a written slice
// parameter.
//
// A sole compatible spread forwards its slice directly, so `println(..args)`
// inside a variadic procedure costs nothing. `receiver` is the method-call
// receiver (parameter 0, not a written argument; nil for a free call) —
// without it a variadic method would rank its first written argument against
// its own receiver's type (the contributed `append` is exactly such a method).
bind_variadic_arguments :: proc(
	k: ^Checker,
	v: ^Expr_Call,
	info: ^Type_Info,
	declaration: Symbol_Id,
	prechecked := false,
	receiver: Expr = nil,
) -> bool {
	pack := variadic_parameter_index(info)
	element := slice_element(k.c, info.parameters[pack])
	bound := make([]Expr, pack + 1, k.c.semantic_allocator)
	declared := symbol_of(k.c, declaration)
	ok := true

	// design.md "Evaluation order": a written argument runs where it is
	// written. Recorded only when a name reorders the fixed parameters, which is
	// the one case where written order and slot order can disagree here.
	slot_order := make([dynamic]int, 0, pack + 1, k.c.semantic_allocator)
	// The fixed parameters, positionally. design.md gives no way to name one past
	// a variadic, so a named argument here names a fixed one.
	first := 0
	if receiver != nil {
		bound[0] = receiver
		append(&slot_order, 0)
		first = 1
	}
	fixed := 0
	for first + fixed < pack && fixed < len(v.args) {
		arg := v.args[fixed]
		if arg.name.text != "" || arg.mode == .Spread {
			break
		}
		slot := first + fixed
		expected := slot < len(info.param_modes) ? info.param_modes[slot] : Param_Mode.Value
		value, passed := bind_written_argument(k, arg, info.parameters[slot], expected, prechecked)
		bound[slot] = value
		append(&slot_order, slot)
		ok = ok && passed
		fixed += 1
	}
	// design.md "Named arguments": positional arguments precede named ones, and
	// no argument can name a pack element — so once a name appears, every
	// remaining argument names a fixed parameter and the pack is empty. A name
	// can't skip a fixed slot either: positional arguments ahead of it already
	// filled the slots to its left.
	named := 0
	for fixed + named < len(v.args) && v.args[fixed + named].name.text != "" {
		arg := v.args[fixed + named]
		named += 1
		if declared == nil {
			errorf(k.c, arg.span, "L0371", "a call through a procedure value cannot use named arguments")
			ok = false
			continue
		}
		// A name reaches a fixed parameter, never a pack element, so the search
		// stops at the pack.
		slot := parameter_slot_named(k.c, declared, intern_identifier(k.c, arg.name.text), pack)
		if slot < 0 {
			errorf(k.c, arg.span, "L0371", "no parameter named `%s`", arg.name.text)
			ok = false
			continue
		}
		if bound[slot] != nil {
			errorf(k.c, arg.span, "L0371", "`%s` is given twice", arg.name.text)
			ok = false
			continue
		}
		expected := slot < len(info.param_modes) ? info.param_modes[slot] : Param_Mode.Value
		value, passed := bind_written_argument(k, arg, info.parameters[slot], expected, prechecked)
		bound[slot] = value
		append(&slot_order, slot)
		ok = ok && passed
	}
	if named > 0 && fixed + named < len(v.args) {
		errorf(k.c, v.args[fixed + named].span, "L0372", "a positional argument cannot follow a named one")
		return false
	}
	append(&slot_order, pack)
	for index in first ..< pack {
		if bound[index] != nil {
			continue
		}
		if !ok {
			// An argument already failed, so the slot it should have filled is not a
			// second mistake to report.
			return false
		}
		if declared == nil || index >= len(declared.param_defaults) || declared.param_defaults[index] == nil {
			errorf(
				k.c, v.span, "L0322",
				"this procedure takes at least %d argument%s, found %d",
				pack - first, pack - first == 1 ? "" : "s", len(v.args),
			)
			return false
		}
		bound[index] = substitute_caller_location(k, declared.param_defaults[index], v.span)
		append(&slot_order, index)
	}
	if named > 0 {
		v.bound_order = slot_order[:]
	}

	rest := v.args[fixed + named:]
	// One spread and nothing else: forward the slice itself.
	if len(rest) == 1 && rest[0].mode == .Spread {
		spread, passed := check_spread_argument(k, rest[0], info.parameters[pack], prechecked)
		bound[pack] = spread
		v.bound = bound
		v.is_variadic = true
		v.variadic_slot = pack
		v.variadic_forwards = true
		return ok && passed
	}

	elements := make([dynamic]Expr, 0, len(rest), k.c.semantic_allocator)
	spreads := make([dynamic]Expr, 0, len(rest), k.c.semantic_allocator)
	order := make([dynamic]bool, 0, len(rest), k.c.semantic_allocator) // true = spread
	needs_element_clone := false
	for arg in rest {
		if arg.name.text != "" {
			errorf(k.c, arg.span, "L0371", "a variadic argument cannot be named")
			ok = false
			continue
		}
		if arg.mode == .Spread {
			spread, passed := check_spread_argument(k, arg, info.parameters[pack], prechecked)
			append(&spreads, spread)
			append(&order, true)
			needs_element_clone = true
			ok = ok && passed
			continue
		}
		value, passed := pass_argument(k, arg.value, element, prechecked)
		append(&elements, value)
		append(&order, false)
		// Asked of every element, managed or not: a pack copies what it is given,
		// and a large unmanaged one costs by the byte without a clone to report.
		classify_copy_cost(k, value, element, .Variadic)
		needs_element_clone ||= expression_is_borrowed_place(k.c, value)
		ok = ok && passed
	}
	if type_is_managed(k.c, element) && needs_element_clone && !lifecycle_of(k.c, element).intrinsic {
		if type_clone_disabled(k.c, element) {
			// design.md "Container insertion": a borrowed element is copied, so each
			// one is reported where `move(...)` belongs. A spread lends its elements
			// and has no `move` form.
			for value in elements {
				classify_copy(k, value, element, .Variadic)
			}
			for spread in spreads {
				errorf(
					k.c, expr_span(spread), "L0503",
					"`%s` is move-only, so a `..` spread cannot copy its elements into the pack",
					type_name(k.c, element),
				)
			}
			ok = false
		} else {
			contribute_lifecycle_members(k, element)
		}
	}
	v.is_variadic = true
	v.variadic_slot = pack
	v.variadic_elements = elements[:]
	v.variadic_spreads = spreads[:]
	v.variadic_order = order[:]
	v.bound = bound
	return ok
}

// design.md "Named arguments": a name reaches a declared parameter by that
// parameter's own name. Every call form asks it here, so overload resolution
// and the finally-bound call can't disagree about which slot a name means.
// `limit` stops the search short of a variadic pack, whose elements have no
// names to reach.
//
// -1 when no parameter carries the name, including a call through a procedure
// value, which has no parameter symbols to carry one.
parameter_slot_named :: proc(c: ^Compiler, declared: ^Symbol, name: Identifier_Id, limit := -1) -> int {
	if declared == nil {
		return -1
	}
	stop := limit < 0 ? len(declared.param_symbols) : min(limit, len(declared.param_symbols))
	for binding, position in declared.param_symbols[:stop] {
		if symbol := symbol_of(c, binding); symbol != nil && symbol.name == name {
			return position
		}
	}
	return -1
}

// Overload resolution checks every written argument once, before it knows which
// candidate wins, so binding the chosen one must not check them again: a second
// pass would re-resolve nested calls and report their diagnostics twice.
pass_argument :: proc(
	k: ^Checker, e: Expr, target: Type_Id, prechecked: bool, inout_argument := false,
) -> (Expr, bool) {
	if !prechecked {
		return check_argument_value(k, e, target, inout_argument)
	}
	return e, materialize_argument(k, e, target)
}

@(private = "file")
check_spread_argument :: proc(k: ^Checker, arg: Argument, pack: Type_Id, prechecked := false) -> (Expr, bool) {
	type := prechecked ? expr_base(arg.value).type : check_single_expr(k, arg.value, pack)
	if type == INVALID_TYPE {
		return arg.value, false
	}
	if !assignable(k.c, type, pack) && type != pack {
		errorf(
			k.c, arg.span, "L0574",
			"`..` spreads a `%s`, found `%s`", type_name(k.c, pack), type_name(k.c, type),
		)
		return arg.value, false
	}
	return arg.value, true
}

// ------------------------------------------------------ runtime metadata --

// `type_info_of(id)` accepts a runtime `typeid` and returns runtime metadata.
// It can't recover a compile-time `type`, since runtime information cannot
// flow back into specialization (design.md "`type` and `typeid`").
//
// The result is a `^runtime.Type_Info`, nil for the nil `typeid` and for any
// id the program has no entry for — a `typeid` is an ordinary scalar forgeable
// through unsafe bit operations, so the lookup is checked.
check_type_info_of :: proc(k: ^Checker, v: ^Expr_Call) {
	v.value_category = .Value
	if len(v.args) != 1 {
		errorf(k.c, v.span, "L0322", "`type_info_of` takes 1 argument, found %d", len(v.args))
		v.type = INVALID_TYPE
		return
	}
	record, resolved := runtime_type_named(k, "Type_Info")
	// The member record is part of the same layout, so it is resolved with it
	// rather than only when an aggregate happens to reach the table builder.
	_, members_resolved := runtime_type_named(k, "Member_Info")
	if !resolved || !members_resolved {
		errorf(
			k.c, v.span, "L0575",
			"`type_info_of` produces a `^runtime.Type_Info`; add `import \"base:runtime\"` to this file's package",
		)
		v.type = INVALID_TYPE
		return
	}
	operand := check_single_expr(k, v.args[0].value, TYPE_TYPEID)
	if operand == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}
	if type_underlying(k.c, operand) != TYPE_TYPEID {
		errorf(
			k.c, expr_span(v.args[0].value), "L0575",
			"`type_info_of` takes a `typeid`, found `%s`", type_name(k.c, operand),
		)
		v.type = INVALID_TYPE
		return
	}
	// The table is only emitted when a program asks for it, and every entry it
	// holds is one the compilation already requested a `typeid` for.
	if k.c.speculation_depth == 0 {
		k.c.type_info_requested = true
	}
	bound := make([]Expr, 1, k.c.semantic_allocator)
	bound[0] = v.args[0].value
	v.bound = bound
	// Reflection metadata lives in a shared static table, so `type_info_of`
	// hands back a read-only `^runtime.Type_Info`.
	v.type = pointer_to(k.c, record, false)
}

// A type declared by a `base:runtime` this package imports. One identity, owned
// by the source declaration, exactly as `Source_Code_Location` is.
runtime_type_named :: proc(k: ^Checker, name: string) -> (Type_Id, bool) {
	pkg := package_of(k.c, k.pkg)
	if pkg == nil {
		return INVALID_TYPE, false
	}
	for edge in pkg.imports {
		target := package_of(k.c, edge.target)
		if target == nil || target.key != STD_RUNTIME || target.scope == nil {
			continue
		}
		symbol := symbol_of(k.c, target.scope.names[intern_identifier(k.c, name)])
		if symbol != nil && symbol.kind == .Type && symbol.type != INVALID_TYPE {
			k.c.runtime_types[name] = symbol.type
			return symbol.type, true
		}
	}
	return INVALID_TYPE, false
}

// Runtime text: the operations a `string`, `string_view`, or `cstring_view`
// answers to (design.md "string type", "string type conversions", "C string
// views"; m6a-plan step 4).
//
// These are compiler-defined operations rather than library members because
// both their operand types and their result types are built in: `bytes()` on a
// `string` produces the `[]u8` the slice machinery already owns, and `copy()`
// produces the managed carrier the lifecycle analysis already tracks. Writing
// them as `core:strings` procedures would need a language feature that does not
// exist — a method on a built-in type — and would change nothing about what
// they lower to.
package lokec

// design.md "Multi-pointers": "Implicit conversions between `^T` and `[^]T`."
// Both directions, and only when the element types agree — a multi-pointer is a
// slimmer view of the same storage, not a reinterpretation of it.
multi_pointer_converts :: proc(c: ^Compiler, from, to: Type_Id) -> bool {
	source, dest := underlying_info(c, from), underlying_info(c, to)
	if source == nil || dest == nil || source.element != dest.element {
		return false
	}
	if source.kind == .Pointer && dest.kind == .Multi_Pointer {
		return true
	}
	return source.kind == .Multi_Pointer && dest.kind == .Pointer
}

// Whether a type is one of the three text carriers.
type_is_text :: proc(c: ^Compiler, id: Type_Id) -> bool {
	#partial switch underlying_kind(c, id) {
	case .String, .String_View, .CString_View:
		return true
	}
	return false
}

// The two carriers that promise valid UTF-8 and carry a byte length. A
// `cstring_view` is neither: design.md says it "does not promise UTF-8 because
// foreign strings frequently use another encoding or arbitrary bytes".
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
	// Two cheap filters, so the receiver of an ordinary method call is not
	// checked twice on the way to failing here. Only these names can name a text
	// operation at all, and a receiver that is a name already knows its type —
	// which is what keeps a record's generated `clone` off this path.
	if text_op_named(sel.name.text) == .None && sel.name.text != "from_runes" {
		return false
	}
	if ident, is_ident := sel.operand.(^Expr_Ident); is_ident {
		sym := symbol_of(k.c, lookup_symbol(k.scope, identifier_of(k.c, ident)))
		if sym != nil && sym.kind != .Type && !type_is_text(k.c, sym.type) {
			return false
		}
	}

	// `string.from_runes(...)` selects through the type name, not through a value.
	if base := expr_base(sel.operand); base != nil && base.value_category == .Type {
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
	v.text = op
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
		// design.md "string type conversions": "A view obtained from a `string` is
		// therefore `[]u8`; it cannot be converted to `[]mut u8`."
		v.type = slice_of(k.c, TYPE_U8, mutable = false)

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

// design.md "From []rune to string": `string.from_runes(st)` validates and
// copies, with optional-ok semantics.
@(private = "file")
check_from_runes :: proc(k: ^Checker, v: ^Expr_Call) {
	v.value_category = .Value
	v.text = .From_Runes
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

// design.md "Optional-ok results": a validating conversion "produces `(value,
// ok: bool)`. On invalid input, `value` is the zero value and `ok` is false."
set_optional_ok_results :: proc(k: ^Checker, v: ^Expr_Call, value: Type_Id) {
	results := make([]Type_Id, 2, k.c.semantic_allocator)
	results[0], results[1] = value, TYPE_BOOL
	v.result_types = results
	v.type = value
}

// The validating conversions of design.md's conversion tables. Each has
// optional-ok semantics: "On invalid input, `value` is the zero value and `ok`
// is false."
//
//   string(bytes)        []u8         validate and copy
//   string_view(bytes)   []u8         validate and borrow
//   string(cview)        cstring_view scan, validate, and copy
//
// Returns true when the pair was one of them, so the ordinary built-in
// conversion table is not asked about it a second time.
check_text_conversion :: proc(k: ^Checker, v: ^Expr_Call, target, source: Type_Id) -> bool {
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
		return false
	}
	v.resolution = Resolution{kind = .Conversion}
	v.text_conversion = op
	v.bound = make([]Expr, 1, k.c.semantic_allocator)
	v.bound[0] = v.args[0].value
	set_optional_ok_results(k, v, target)
	return true
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
	results := make([]Type_Id, 2, k.c.semantic_allocator)
	results[0], results[1] = TYPE_STRING, TYPE_ALLOCATOR_ERROR
	v.result_types = results
	v.type = TYPE_STRING
}

// ------------------------------------------------------------ core:unsafe --

// design.md "unsafe.raw_data procedure":
//
//	unsafe.raw_data([]$E)          -> [^]E   read-only slices; capability discarded
//	unsafe.raw_data([]mut $E)      -> [^]E
//	unsafe.raw_data(^[$N]$E)       -> [^]E   fixed arrays
//	unsafe.raw_data(string)        -> [^]byte
//	unsafe.raw_data(cstring_view)  -> [^]byte
//
// and the two view constructors whose operands the compiler cannot trace to an
// owner. The `[dynamic]E` and `Simd` overloads wait for the milestones that
// introduce those operands.
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
	case .None, .Assert, .Panic, .Size_Of, .Align_Of, .Offset_Of, .Len, .Cap, .Hash,
	     .Static_Assert, .Build_Config, .Source_Location, .Caller_Location,
	     .Type_Of, .Typeid_Of, .Fields_Of, .Enum_Values_Of, .Iter, .New, .New_Clone, .Make, .Free,
	     .Free_All, .Default_Allocator, .Drop, .Exchange, .Type_Info_Of,
	     .Clone, .Try_Clone,
	     .Fmt_Stdout_Writer, .Fmt_Stderr_Writer, .Fmt_Write_Bytes, .Fmt_Format_Any, .Strings_Allocate:
		v.type = INVALID_TYPE

	case .Unsafe_Raw_Data:
		element := INVALID_TYPE
		#partial switch info.kind {
		case .Slice:
			element = info.element
		case .Pointer:
			// design.md: "For a nested fixed array, `unsafe.raw_data` exposes one
			// array level at a time."
			if pointee := underlying_info(k.c, info.element); pointee != nil && pointee.kind == .Array {
				element = pointee.element
			}
		case .String, .String_View, .CString_View:
			element = TYPE_U8
		case .Dynamic_Array:
			// design.md: the result "carries neither a length nor an owner", so it
			// crosses the unsafe boundary exactly as a slice's does. The container
			// may relocate its storage at any later operation and nothing here
			// records that -- which is the point of the boundary.
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
		v.type = multi_pointer_to(k.c, element)

	case .Unsafe_String_View:
		// design.md "From [^]u8 and length int to string": "unsafe validate and
		// borrow, optional-ok". The pointer's owner is unknown to the compiler, so
		// keeping the storage alive is the programmer's responsibility — but the
		// bytes are still validated, because the resulting type promises UTF-8.
		if info == nil || info.kind != .Multi_Pointer || info.element != TYPE_U8 {
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
		// design.md "From [^]u8 to cstring_view": an unsafe borrow, and no
		// validation at all — a `cstring_view` promises no encoding.
		if info == nil || info.kind != .Multi_Pointer || info.element != TYPE_U8 {
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

// design.md "`source_location()` or `source_location(<entity>)`": returns a
// `runtime.Source_Code_Location`, for the current location with no arguments or
// for the declaration of a named entity with one.
//
// Every field is known at compile time, so the whole thing folds to one
// constant aggregate over static storage and costs nothing at run time.
check_location :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident) {
	v.value_category = .Value
	type, resolved := source_location_type(k)
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

// The `Source_Code_Location` declared by a `base:runtime` this package imports.
// Looking it up rather than owning a second copy is what keeps one identity
// between the compiler, the seed runtime, and the library.
source_location_type :: proc(k: ^Checker) -> (Type_Id, bool) {
	pkg := package_of(k.c, k.pkg)
	if pkg == nil {
		return INVALID_TYPE, false
	}
	for edge in pkg.imports {
		target := package_of(k.c, edge.target)
		if target == nil || target.key != STD_RUNTIME || target.scope == nil {
			continue
		}
		symbol := symbol_of(k.c, target.scope.names[intern_identifier(k.c, "Source_Code_Location")])
		if symbol != nil && symbol.kind == .Type && symbol.type != INVALID_TYPE {
			return symbol.type, true
		}
	}
	return INVALID_TYPE, false
}

// `{file, procedure: string_view, line, column: int}`, all four constant.
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

// design.md "`caller_location()`": it denotes the source location of the code
// calling the procedure. Its place is the default value of a procedure
// parameter, where it is evaluated at each call that omits that argument, like
// any other default.
//
// At the declaration it types the parameter and carries the declaration's own
// span, which nothing observes: every call that omits the argument substitutes
// its own location first.
check_caller_location :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident) {
	v.value_category = .Value
	if len(v.args) != 0 {
		errorf(k.c, v.span, "L0573", "`caller_location` takes no arguments, found %d", len(v.args))
		v.type = INVALID_TYPE
		return
	}
	type, resolved := source_location_type(k)
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
// slice, so the packing happens here and the ABI stays the same as a written
// slice parameter.
//
// A sole compatible spread forwards its slice directly, which is what makes
// `println(..args)` inside a variadic procedure cost nothing.
// `receiver` is the method-call receiver, which is parameter 0 and is not one of
// the written arguments; it is nil for a free call. Without it a variadic
// method would rank its first written argument against its own receiver's type
// (m6b-plan step 2: the contributed `append` is exactly such a method).
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

	// The fixed parameters, positionally. design.md gives no way to name one past
	// a variadic, so a named argument here would have to name a fixed one.
	first := 0
	if receiver != nil {
		bound[0] = receiver
		first = 1
	}
	fixed := 0
	for first + fixed < pack && fixed < len(v.args) {
		arg := v.args[fixed]
		if arg.name.text != "" || arg.mode == .Spread {
			break
		}
		value, passed := pass_argument(k, arg.value, info.parameters[first + fixed], prechecked)
		bound[first + fixed] = value
		ok = ok && passed
		fixed += 1
	}
	for index in first + fixed ..< pack {
		if declared == nil || index >= len(declared.param_defaults) || declared.param_defaults[index] == nil {
			errorf(
				k.c, v.span, "L0322",
				"this procedure takes at least %d argument%s, found %d",
				pack - first, pack - first == 1 ? "" : "s", len(v.args),
			)
			return false
		}
		bound[index] = substitute_caller_location(k, declared.param_defaults[index], v.span)
	}

	rest := v.args[fixed:]
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
		needs_element_clone ||= expression_is_borrowed_place(k.c, value)
		ok = ok && passed
	}
	if type_is_managed(k.c, element) && needs_element_clone && !lifecycle_of(k.c, element).intrinsic {
		if type_clone_disabled(k.c, element) {
			errorf(
				k.c, v.span, "L0503",
				"a `%s` variadic pack must clone borrowed elements, but `try_clone` is disabled",
				type_name(k.c, element),
			)
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

// Overload resolution checks every written argument once, before it knows which
// candidate wins, so binding the chosen one must not check them again: a second
// pass would re-resolve nested calls and report their diagnostics twice.
@(private = "file")
pass_argument :: proc(k: ^Checker, e: Expr, target: Type_Id, prechecked: bool) -> (Expr, bool) {
	if !prechecked {
		return check_argument_value(k, e, target)
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

// design.md "`type` and `typeid`": `type_info_of(id)` "accepts a runtime
// `typeid` and returns runtime metadata. It does not recover a compile-time
// `type`, because runtime information cannot flow back into specialization."
//
// The result is a `^runtime.Type_Info`, which is nil for the nil `typeid` and
// for any id this program has no entry for — a `typeid` is an ordinary scalar
// and can be forged through unsafe bit operations, so the lookup is checked.
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
	v.type = pointer_to(k.c, record)
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

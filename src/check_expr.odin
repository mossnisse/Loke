// Expressions, conversions, and constant folding.
//
// `check.odin` owns declarations and statements; everything that produces a
// value is dispatched here. Call checking and binding live in `check_calls.odin`.
// Expression checking is contextual: an expected type flows down so that an
// untyped constant, an implicit `.Member`, a typeless composite literal, and
// `nil` can each take their meaning from where they are used.
package lokec

import "core:math"
import "core:mem"
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

	// A place position belongs to this node alone: its operands and indices are
	// ordinary value positions.
	place := k.place_position
	k.place_position = false

	switch v in e {
	case ^Expr_Error:
		v.type = INVALID_TYPE

	case ^Expr_Literal:
		check_literal(k, v, expected)

	case ^Expr_Ident:
		check_ident(k, v)

	case ^Expr_Selector:
		// `m[key].x = v` reaches the index as a place but never inserts
		// (design.md "Maps").
		k.place_position, k.insert_position = place, false
		check_selector(k, v, expected)
		k.place_position = false

	case ^Expr_Index:
		check_index(k, v, place)

	case ^Expr_Slice:
		check_slice(k, v, place)

	case ^Expr_Checked_Extract:
		check_extract_of(k, v, check_single_expr(k, v.operand))

	case ^Expr_Or_Else:
		check_or_else(k, v)

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

	case ^Expr_Range:
		check_range(k, v)

	case ^Expr_Move:
		check_move(k, v)

	case ^Expr_Proc_Group, ^Expr_Operator,
	     ^Type_Pointer, ^Type_C_Pointer, ^Type_Slice, ^Type_Dynamic_Array,
	     ^Type_Array, ^Type_Map, ^Type_Distinct, ^Type_Dyn, ^Type_Type,
	     ^Type_Poly, ^Type_Proc, ^Type_Record, ^Type_Anon_Record, ^Type_Enum, ^Type_Interface:
		// A type in expression position, such as a conversion callee.
		reported := k.c.error_count
		denoted := resolve_type_syntax(k, e)
		if k.c.error_count > reported {
			// Already reported.
			base.type = INVALID_TYPE
		} else if denoted != INVALID_TYPE {
			base.denoted_type = denoted
			base.value_category = .Type
			base.type = TYPE_TYPE
			base.is_const = true
			base.const_value = type_const(denoted)
		} else {
			report_unresolved_type(k, e)
			base.type = INVALID_TYPE
		}
	}
	// design.md "Compile-time reflection": a descriptor or `type` value is only
	// ever folded, so one computed at run time, such as `fields_of(T)[i]` with a
	// runtime `i`, has no representation.
	if base.type != INVALID_TYPE && !base.is_const && type_is_reflection_value(k.c, base.type) {
		errorf(
			k.c, base.span, "L0453",
			"`%s` exists only during compilation, so this expression must be a constant",
			type_name(k.c, base.type),
		)
		base.type = INVALID_TYPE
	}
	return base.type
}

// One value, exactly: rejects a call to a procedure with no result.
check_single_expr :: proc(k: ^Checker, e: Expr, expected: Type_Id = INVALID_TYPE) -> Type_Id {
	type := check_expr(k, e, expected)
	base := expr_base(e)
	if type == TYPE_VOID {
		errorf(k.c, expr_span(e), "L0309", "this expression produces no value")
		if base != nil {
			base.type = INVALID_TYPE
		}
		return INVALID_TYPE
	}
	return type
}

// Checks an expression against a destination type and materialises it there:
// the seam every assignment, argument, initialiser, and return value uses.
check_value_expr :: proc(k: ^Checker, e: Expr, target: Type_Id, what: string) -> bool {
	type := check_single_expr(k, e, target)
	if type == INVALID_TYPE || target == INVALID_TYPE {
		return false
	}
	return materialize_value_expr(k, e, target, what)
}

// A destination never selects an overload, so a call result that does not fit
// names the member its arguments selected and any member whose result would.
@(private = "file")
note_overload_selection :: proc(k: ^Checker, e: Expr, target: Type_Id) {
	call, is_call := e.(^Expr_Call)
	if !is_call || len(call.overload_members) < 2 {
		return
	}
	chosen := symbol_of(k.c, call.resolution.chosen_overload)
	if chosen == nil {
		return
	}
	add_notef(
		k.c, chosen.span,
		"the arguments select `%s`, which returns `%s`; a destination type does not choose an overload",
		identifier_text(k.c, chosen.name), type_name(k.c, chosen.result),
	)
	for member in call.overload_members {
		sym := symbol_of(k.c, member)
		if sym == nil || sym.name == chosen.name || sym.result == INVALID_TYPE || !assignable(k.c, sym.result, target) {
			continue
		}
		add_notef(
			k.c, sym.span,
			"`%s` returns `%s`; call it by name, or pass arguments that select it",
			identifier_text(k.c, sym.name), type_name(k.c, sym.result),
		)
	}
}

// `check_value_expr` for an expression already checked, as overload selection
// needs; checking it twice would repeat diagnostics.
materialize_value_expr :: proc(k: ^Checker, e: Expr, target: Type_Id, what: string) -> bool {
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
		note_overload_selection(k, e, target)
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
		v.const_value = integer_const(value)

	case .Float:
		text, _ := strings.replace_all(v.text, "_", "", k.c.semantic_allocator)
		value, ok := strconv.parse_f64(text)
		if !ok {
			errorf(k.c, v.span, "L0351", "`%s` is not a valid floating-point literal", v.text)
			v.type = INVALID_TYPE
			return
		}
		v.type = TYPE_UNTYPED_FLOAT
		v.is_const = true
		v.const_value = float_const(value, 64)
		// Rounded at the destination width now: rounding an `f32` expression's
		// operands only later can disagree with the same expression at runtime.
		if type_is_float(k.c, expected) && !type_is_untyped(k.c, expected) && !materialize(k, v, expected) {
			v.type = INVALID_TYPE
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
		v.const_value = rune_const(bi_from_i64(k.c, i64(value)))

	case .String, .Raw_String:
		text, ok := decode_string_literal(k.c, v.text, v.kind == .Raw_String)
		if !ok {
			errorf(k.c, v.span, "L0351", "`%s` is not a valid string literal", v.text)
			v.type = INVALID_TYPE
			return
		}
		v.type = TYPE_UNTYPED_STRING
		v.is_const = true
		v.const_value = Const_Value{kind = .String, text = text}
	}
}

// The lexer has already validated the spelling; a raw string has no escapes at
// all and a quoted one reuses the rune decoder for each of its own.
decode_string_literal :: proc(c: ^Compiler, text: string, raw: bool) -> (string, bool) {
	if len(text) < 2 {
		return "", false
	}
	body := text[1:len(text) - 1]
	if raw {
		return body, true
	}
	out := strings.builder_make(c.semantic_allocator)
	for i := 0; i < len(body); {
		if body[i] != '\\' {
			strings.write_byte(&out, body[i])
			i += 1
			continue
		}
		width := escape_width(body[i:])
		if width == 0 {
			return "", false
		}
		value, ok := decode_rune_literal(concat_quoted(c, body[i:i + width]))
		if !ok {
			return "", false
		}
		// `\xNN` is one byte; every other escape names a code point.
		if width >= 2 && body[i + 1] == 'x' {
			strings.write_byte(&out, u8(value))
		} else {
			strings.write_rune(&out, value)
		}
		i += width
	}
	return strings.to_string(out), true
}

// How many bytes of `\...` this escape spans.
@(private = "file")
escape_width :: proc(s: string) -> int {
	if len(s) < 2 {
		return 0
	}
	digits :: proc(s: string, count: int, base: int) -> int {
		if len(s) < 2 + count {
			return 0
		}
		for i in 2 ..< 2 + count {
			if _, ok := strconv.parse_u64_of_base(s[i:i + 1], base); !ok {
				return 0
			}
		}
		return 2 + count
	}
	switch s[1] {
	case 'x':
		return digits(s, 2, 16)
	case 'u':
		return digits(s, 4, 16)
	case 'U':
		return digits(s, 8, 16)
	}
	return 2
}

@(private = "file")
concat_quoted :: proc(c: ^Compiler, body: string) -> string {
	out := make([]u8, len(body) + 2, c.semantic_allocator)
	out[0] = '\''
	copy(out[1:], body)
	out[len(out) - 1] = '\''
	return string(out)
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
	}
	return 0, false
}

// ------------------------------------------------------------ identifiers --

// Which immutable name this is. A `foreach` binding, a `switch` payload and a
// value parameter share one immutability flag, so the construct the programmer
// wrote has to be recovered here or the diagnostic calls all three a parameter.
@(private = "file")
immutable_name_reason :: proc(sym: ^Symbol) -> Immutable_Reason {
	switch sym.borrowed_binding {
	case .Loop_Element:
		return .Loop_Binding
	case .Switch_Payload:
		return .Payload_Binding
	case .None:
	}
	return sym.kind == .Parameter ? .Value_Parameter : .Read_Only_Name
}

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
	// Every use of a name, including an assignment destination, counts as a read
	// for design.md "@(require_results)".
	sym.named = true

	// A procedure literal has no closure.
	if owner != nil && owner.owner_proc != nil && owner.owner_proc != k.proc_literal {
		if sym.kind == .Var || sym.kind == .Parameter {
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

	// Constants and globals are checked on demand, so a forward reference sees a
	// real type.
	if sym.decl != nil && (sym.kind == .Const || (sym.kind == .Var && sym.decl.top_level)) {
		switch sym.decl.check_state {
		case .Unchecked:
			check_symbol_decl_in_place(k, symbol_id)
			sym = symbol_of(k.c, symbol_id)
		case .Checking:
			errorf(
				k.c, v.span, "L0324", "%s initialisation cycle involving `%s`",
				sym.kind == .Const ? "constant" : "global", v.name,
			)
			v.type = INVALID_TYPE
			return
		case .Checked:
		}
	}

	annotate_symbol_use(k, &v.base, symbol_id, v.name)
}

// Writes what a resolved symbol means onto the node that named it, for both
// `name` and `package.name`.
@(private = "file")
annotate_symbol_use :: proc(k: ^Checker, v: ^Expr_Base, symbol_id: Symbol_Id, name: string) {
	sym := symbol_of(k.c, symbol_id)
	if sym == nil {
		v.type = INVALID_TYPE
		return
	}
	// design.md "Generics": uninstantiated, it is neither a value nor a type.
	if sym.generic {
		errorf(
			k.c,
			v.span,
			"L0431",
			"`%s` is generic and needs its arguments; an uninstantiated generic is not a value",
			name,
		)
		v.type = INVALID_TYPE
		return
	}
	switch sym.kind {
	case .Type:
		resolve_symbol_signature_in_place(k, symbol_id)
		sym = symbol_of(k.c, symbol_id)
		v.resolution = Resolution{kind = .Type, symbol = symbol_id}
		v.denoted_type = sym.type
		v.value_category = .Type
		v.type = TYPE_TYPE
		v.is_const = true
		v.const_value = type_const(sym.type)

	case .Proc:
		if sym.hook != .None && !k.in_callee {
			reject_direct_hook_call(k, v.span, symbol_id)
			v.type = INVALID_TYPE
			return
		}
		// Resolved on demand, so a constant may call a procedure declared later.
		if sym.proc_type == INVALID_TYPE && sym.decl != nil {
			resolve_symbol_signature_in_place(k, symbol_id)
			sym = symbol_of(k.c, symbol_id)
		}
		v.resolution = Resolution{kind = .Value, symbol = symbol_id}
		v.value_category = .Value
		v.type = sym.proc_type
		// design.md "`@(deprecated=<string>)`": a warning at each use.
		if sym.deprecated {
			if sym.deprecated_message != "" {
				warnf(k.c, v.span, "L0611", "`%s` is deprecated: %s", name, sym.deprecated_message)
			} else {
				warnf(k.c, v.span, "L0611", "`%s` is deprecated", name)
			}
		}

	case .Builtin:
		v.resolution = Resolution{kind = .Value, symbol = symbol_id}
		errorf(k.c, v.span, "L0316", "`%s` is a built-in procedure and must be called", name)
		v.type = INVALID_TYPE

	case .Const, .Enum_Member:
		// A `LOKE_*` build-config constant allocates its enum type on first use.
		if sym.build_config_enum != .None && sym.type == INVALID_TYPE {
			sym.type = build_config_enum_type(k.c, sym.build_config_enum)
		}
		v.resolution = Resolution{kind = .Value, symbol = symbol_id}
		v.value_category = .Value
		v.type = sym.type
		v.is_const = true
		v.const_value = sym.const_value
		v.immutable = .Constant
		// design.md "Type alias": a constant whose value is a type denotes it.
		if const_names_type(k.c, sym.const_value, sym.type) {
			v.resolution = Resolution{kind = .Type, symbol = symbol_id}
			v.denoted_type = sym.const_value.type_value
			v.value_category = .Type
		}

	case .Var, .Parameter:
		v.resolution = Resolution{kind = .Value, symbol = symbol_id}
		v.value_category = .Place
		v.type = sym.type
		v.addressable = true
		v.assignable = !sym.immutable
		v.immutable = sym.immutable ? immutable_name_reason(sym) : .None

	case .Field:
		v.resolution = Resolution{kind = .Field, symbol = symbol_id}
		v.type = sym.type

	case .Package_Alias:
		errorf(k.c, v.span, "L0334", "`%s` names a package; write `%s.name` to use one of its declarations", name, name)
		v.type = INVALID_TYPE

	case .Proc_Group:
		v.resolution = Resolution{kind = .Procedure_Group, symbol = symbol_id}
		errorf(k.c, v.span, "L0396", "`%s` is a procedure group and can only be called", name)
		v.type = INVALID_TYPE

	case .Invalid:
		unsupported_construct(k, v.span)
		v.type = INVALID_TYPE
	}
}

// -------------------------------------------------------------- selectors --

@(private = "file")
check_selector :: proc(k: ^Checker, v: ^Expr_Selector, expected: Type_Id) {
	v.value_category = .Value

	// `.Member`: the implicit enum selector and the payloadless union variant,
	// both of which take their type from the expected one.
	if v.operand == nil {
		if check_union_variant_selector(k, v, expected) {
			if v.resolution.kind == .Union_Variant && !k.in_callee {
				reject_incomplete_variant(k, v)
				v.type = INVALID_TYPE
			}
			return
		}
		enum_type := type_underlying(k.c, expected)
		if !type_is_enum(k.c, enum_type) {
			wanted := underlying_info(k.c, expected)
			if type_is_union(k.c, enum_type) {
				errorf(k.c, v.span, "L0425", "`%s` has no variant `%s`", type_name(k.c, expected), v.name.text)
			} else if wanted != nil && wanted.kind == .Proc && type_is_union(k.c, type_underlying(k.c, wanted.result)) &&
			          union_variant_index(k.c, wanted.result, intern_identifier(k.c, v.name.text)) >= 0 {
				// A constructor value names its union: the destination never picks one.
				errorf(
					k.c, v.span, "L0425", "a variant used as a procedure names its union: write `%s.%s`",
					type_name(k.c, wanted.result), v.name.text,
				)
			} else {
				errorf(k.c, v.span, "L0385", "`.%s` needs an expected enum type here", v.name.text)
			}
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

	// A package alias is not a value, so it is resolved before the operand is
	// checked as one.
	if ident, is_ident := v.operand.(^Expr_Ident); is_ident {
		alias := lookup_symbol(k.scope, identifier_of(k.c, ident))
		if sym := symbol_of(k.c, alias); sym != nil && sym.kind == .Package_Alias {
			check_package_selector(k, v, ident, alias)
			return
		}
	}

	// The operand is not itself in callee position, whatever this selector is.
	callee_position := k.in_callee
	k.in_callee = false
	operand := check_single_expr(k, v.operand)
	k.in_callee = callee_position
	if operand == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}
	operand_base := expr_base(v.operand)

	// A named union type selects its own variant: `Option.none`, `Result.ok`.
	// Outside a call, a payload variant is its constructor procedure.
	if operand_base.value_category == .Type &&
	   check_union_variant_selector(k, v, operand_base.denoted_type) {
		if v.resolution.kind == .Union_Variant && !callee_position {
			constructor := variant_constructor(k.c, v.variant_union, v.variant_index)
			annotate_symbol_use(k, &v.base, constructor, v.name.text)
		}
		return
	}

	// A named enum type selects its own member: `Colour.Red`.
	if operand_base.value_category == .Type {
		subject := operand_base.denoted_type
		enum_type := type_underlying(k.c, subject)
		if type_is_enum(k.c, enum_type) {
			member := enum_member(k.c, enum_type, intern_identifier(k.c, v.name.text))
			if member != INVALID_SYMBOL {
				sym := symbol_of(k.c, member)
				v.resolution = Resolution{kind = .Field, symbol = member}
				v.type = subject
				v.is_const = true
				v.const_value = sym.const_value
				v.immutable = .Constant
				return
			}
		}
		// design.md: associated procedures and constants without `self` are
		// accessed through the type name, and so is `Type.method(value)`.
		if select_associated_member(k, v, subject) {
			return
		}
		errorf(k.c, v.span, "L0408", "`%s` has no member `%s`", type_name(k.c, subject), v.name.text)
		note_excluded_member(k, subject, v.name.text)
		v.type = INVALID_TYPE
		return
	}

	// `p.field` through one pointer is the same selection as `p^.field`, and it
	// inherits the pointer's capability the same way.
	base_type := type_underlying(k.c, operand)
	through_pointer := false
	pointer_mutable := false
	pointee_type := INVALID_TYPE
	if info := type_of(k.c, base_type); info != nil && info.kind == .Pointer {
		pointee_type = info.element
		base_type = type_underlying(k.c, info.element)
		through_pointer = true
		pointer_mutable = info.mutable
	}
	info := type_of(k.c, base_type)
	field := INVALID_SYMBOL
	if info != nil && info.kind == .Struct {
		field = struct_field(k.c, base_type, intern_identifier(k.c, v.name.text))
	}
	// design.md "Promoted struct fields": a declared field wins, then one reached
	// through `using` fields. `e.x` becomes the checked chain `e.position.x`.
	if field == INVALID_SYMBOL && info != nil && info.kind == .Struct {
		name := intern_identifier(k.c, v.name.text)
		path := make([dynamic]Symbol_Id, 0, 4, context.temp_allocator)
		found, ambiguous := promoted_field_path(k.c, base_type, name, &path, 0)
		if ambiguous {
			errorf(k.c, v.span, "L0703", "`%s` is promoted into `%s` by more than one `using` field; select it explicitly", v.name.text, type_name(k.c, operand))
			v.type = INVALID_TYPE
			return
		}
		if found {
			current_type, current_base := operand, operand_base
			for link in path[:len(path) - 1] {
				inner := new(Expr_Selector, k.c.semantic_allocator)
				inner.span = v.span
				inner.operand = v.operand
				inner.name = Name{text = identifier_text(k.c, symbol_of(k.c, link).name), span = v.name.span, id = symbol_of(k.c, link).name}
				if !select_field(k, inner, current_type, current_base, through_pointer, pointer_mutable, link) {
					v.type = INVALID_TYPE
					return
				}
				v.operand = inner
				current_type, current_base = inner.type, &inner.base
				through_pointer, pointer_mutable = false, false
			}
			select_field(k, v, current_type, current_base, false, false, path[len(path) - 1])
			return
		}
	}
	// A field always wins over method-call sugar with the same name (design.md).
	if field == INVALID_SYMBOL {
		// A pointer may declare inherent methods of its own. Preserve that lookup
		// first; implicit dereference is the fallback when the pointer type itself
		// has no matching receiver.
		if select_method(k, v, operand, callee_position) {
			return
		}
		if through_pointer && select_method(k, v, pointee_type, callee_position) {
			v.operand = implicit_pointer_deref(k, v.operand, pointee_type, pointer_mutable)
			return
		}
		// An unfixed receiver takes its default type (design.md "Unfixed
		// constants"), so `TEXT.len()` finds `string`'s member.
		if type_is_untyped(k.c, operand) {
			materialized := default_type(k.c, operand)
			if materialized != operand && materialized != INVALID_TYPE {
				if !materialize(k, v.operand, materialized) {
					v.type = INVALID_TYPE
					return
				}
				if select_method(k, v, materialized, callee_position) {
					return
				}
			}
		}
		errorf(k.c, v.span, "L0363", "`%s` has no field or member `%s`", type_name(k.c, operand), v.name.text)
		note_excluded_member(k, operand, v.name.text)
		v.type = INVALID_TYPE
		return
	}
	select_field(k, v, operand, operand_base, through_pointer, pointer_mutable, field)
}

// Annotates `v` as selecting `field` from its already-checked operand.
@(private = "file")
select_field :: proc(
	k: ^Checker,
	v: ^Expr_Selector,
	operand: Type_Id,
	operand_base: ^Expr_Base,
	through_pointer, pointer_mutable: bool,
	field: Symbol_Id,
) -> bool {
	// An inaccessible field is reported, not skipped for a same-named method.
	if !require_visible_field(k, v.span, operand, field, "L0471", "used") {
		v.type = INVALID_TYPE
		return false
	}
	sym := symbol_of(k.c, field)
	v.resolution = Resolution{kind = .Field, symbol = field}
	v.type = sym.type
	v.value_category = .Place
	inherit_capability(&v.base, operand_base, through_pointer, pointer_mutable)
	// Selecting from a constant aggregate is itself constant.
	if operand_base.is_const && operand_base.const_value.kind == .Aggregate {
		aggregate := operand_base.const_value.aggregate
		if aggregate != nil && int(sym.index) < len(aggregate.elements) {
			v.is_const = true
			v.const_value = aggregate.elements[sym.index]
			v.immutable = .Constant
			// design.md "Compile-time reflection": an `Enum_Value`'s `value` has its
			// enum's backing type, so a `u64` member above `max(int)` keeps its value.
			if operand_base.type == k.c.meta_enum_value_type && operand_base.type != INVALID_TYPE &&
			   sym.index == META_ENUM_VALUE {
				if owner := underlying_info(k.c, aggregate.elements[META_ENUM_OWNER].type_value); owner != nil {
					v.type = owner.element
				}
			}
		}
	}
	return true
}

// A field or element place: writable through a `^mut T`, read-only through a
// `^T`, and otherwise exactly as writable as the operand it is part of.
@(private = "file")
inherit_capability :: proc(v, operand: ^Expr_Base, through_pointer, pointer_mutable: bool) {
	if through_pointer {
		v.addressable = true
		v.assignable = pointer_mutable
		v.immutable = pointer_mutable ? .None : .Through_Pointer
	} else {
		v.addressable = operand.addressable
		v.assignable = operand.assignable
		v.immutable = operand.immutable
	}
}

// The `using` fields leading from `record` to a field named `name`, ending with
// that field. A field declared at a level hides deeper ones; two matches at the
// same level are ambiguous. Only a by-value struct field promotes.
@(private = "file")
promoted_field_path :: proc(
	c: ^Compiler, record: Type_Id, name: Identifier_Id, path: ^[dynamic]Symbol_Id, depth: int,
) -> (found: bool, ambiguous: bool) {
	info := underlying_info(c, record)
	// A record containing itself by value is already an error; stop the recursion.
	if info == nil || info.kind != .Struct || depth > 32 {
		return false, false
	}
	if direct := struct_field(c, record, name); direct != INVALID_SYMBOL {
		append(path, direct)
		return true, false
	}
	mark := len(path)
	for field in info.fields {
		sym := symbol_of(c, field)
		if sym == nil || !sym.is_using {
			continue
		}
		start := len(path)
		append(path, field)
		sub_found, sub_ambiguous := promoted_field_path(c, sym.type, name, path, depth + 1)
		if sub_ambiguous || (sub_found && found) {
			return false, true
		}
		if sub_found {
			found = true
		} else {
			resize(path, start)
		}
	}
	if !found {
		resize(path, mark)
	}
	return found, false
}

// An implicit `operand^`, written into the typed AST so later passes see the
// real place and its capability.
@(private = "file")
implicit_pointer_deref :: proc(
	k: ^Checker,
	operand: Expr,
	pointee: Type_Id,
	mutable: bool,
) -> Expr {
	base := expr_base(operand)
	n := new(Expr_Postfix, k.c.semantic_allocator)
	n.span = base.span
	n.type = pointee
	n.value_category = .Place
	n.addressable = true
	n.assignable = mutable
	n.immutable = mutable ? .None : .Through_Pointer
	n.op = .Caret
	n.op_span = base.span
	n.operand = operand
	return n
}

// `Type.member`: an associated constant, an associated type, or a procedure
// reached through the type name.
@(private = "file")
select_associated_member :: proc(
	k: ^Checker, v: ^Expr_Selector, subject: Type_Id,
) -> bool {
	member := find_member(k, subject, intern_identifier(k.c, v.name.text))
	if member == INVALID_SYMBOL {
		return false
	}
	// Checked on demand with the block's subject, which binds an instantiated
	// block's generic arguments.
	outer := k.impl_type
	k.impl_type = subject
	defer k.impl_type = outer
	if sym := symbol_of(k.c, member); sym != nil && sym.kind == .Const && sym.decl != nil {
		if sym.decl.check_state == .Unchecked {
			check_symbol_decl_in_place(k, member, subject)
		}
	}
	annotate_symbol_use(k, &v.base, member, v.name.text)
	return true
}

// A method on the operand's own type. A `distinct` type carries its own members,
// so this never looks through to the underlying type.
@(private = "file")
select_method :: proc(k: ^Checker, v: ^Expr_Selector, receiver: Type_Id, callee_position: bool) -> bool {
	candidates := method_candidates(k, receiver, intern_identifier(k.c, v.name.text))
	if len(candidates) == 0 {
		return false
	}
	v.resolution = Resolution{kind = .Method, symbol = candidates[0]}
	v.value_category = .Value
	if !callee_position {
		// There are no bound method values: the receiver is supplied by the call.
		errorf(k.c, v.span, "L0408", "`%s` is a method and must be called", v.name.text)
		v.type = INVALID_TYPE
		return true
	}
	v.type = TYPE_VOID // `check_call` reads the resolution, never this
	return true
}

// Explains a "no such member" report when a `where` bound removed the member.
note_excluded_member :: proc(k: ^Checker, type: Type_Id, name: string) {
	excluded := excluded_member(k, type, intern_identifier(k.c, name))
	if excluded == nil {
		return
	}
	add_notef(
		k.c,
		excluded.span,
		"`%s` is declared with a `where` bound that does not hold for this instantiation",
		name,
	)
}

// The members named `name` that method-call syntax can reach: those with a
// receiver.
method_candidates :: proc(k: ^Checker, receiver: Type_Id, name: Identifier_Id) -> []Symbol_Id {
	all := member_candidates(k, receiver, name)
	out := make([dynamic]Symbol_Id, 0, len(all), k.c.semantic_allocator)
	for candidate in all {
		if sym := symbol_of(k.c, candidate); sym != nil && sym.has_receiver {
			append(&out, candidate)
		}
	}
	return out[:]
}

// `alias.name`. Only the target package's own scope is searched — never its
// parents — and only a `@(public)` declaration is visible from outside.
check_package_selector :: proc(k: ^Checker, v: ^Expr_Selector, ident: ^Expr_Ident, alias: Symbol_Id) {
	alias_symbol := symbol_of(k.c, alias)
	ident.symbol = alias
	ident.resolution = Resolution{kind = .Package, symbol = alias}
	ident.type = TYPE_VOID

	target := package_of(k.c, alias_symbol.pkg)
	if target == nil || target.scope == nil {
		v.type = INVALID_TYPE
		return
	}
	name := intern_identifier(k.c, v.name.text)
	symbol_id, found := target.scope.names[name]
	if !found {
		errorf(k.c, v.span, "L0335", "package `%s` has no declaration `%s`", ident.name, v.name.text)
		v.type = INVALID_TYPE
		return
	}
	symbol := symbol_of(k.c, symbol_id)
	if symbol == nil || !symbol.public {
		errorf(k.c, v.span, "L0336", "`%s` is not public in package `%s`", v.name.text, ident.name)
		if symbol != nil {
			add_notef(k.c, symbol.span, "declared here; add `@(public)` to export it")
		}
		v.type = INVALID_TYPE
		return
	}
	// It may be reached before its own package is checked.
	if symbol.decl != nil && symbol.decl.check_state == .Unchecked &&
	   (symbol.kind == .Const || symbol.kind == .Var) {
		check_symbol_decl_in_place(k, symbol_id)
	}
	annotate_symbol_use(k, &v.base, symbol_id, v.name.text)
}

// ---------------------------------------------------------------- indexing --

@(private = "file")
check_index :: proc(k: ^Checker, v: ^Expr_Index, place: bool) {
	v.value_category = .Value
	// In `outer[key][i] = v` only the last index may insert; `outer[key]` must
	// already exist (design.md "Maps").
	inserts := place && k.insert_position
	k.place_position, k.insert_position = place, false
	operand := check_single_expr(k, v.operand)
	k.place_position = false
	if operand == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}

	// Nominal: a `distinct` type inherits none of the underlying type's
	// operations (design.md "Distinct types"), so it reaches `check_user_index`
	// below with its own kind rather than the built-in table for free.
	base_type := operand
	operand_base := expr_base(v.operand)
	through_pointer := false
	pointer_mutable := false
	pointee := INVALID_TYPE
	if info := type_of(k.c, base_type); info != nil && info.kind == .Pointer {
		pointee = info.element
		base_type = info.element
		through_pointer = true
		pointer_mutable = info.mutable
	}
	info := type_of(k.c, base_type)
	single := len(v.indices) == 1
	// A carrier is reached through its header, so the pointer hop is written into
	// the typed AST as `p^`, which every later pass already understands.
	if through_pointer && info != nil && (info.kind == .Slice || info.kind == .Dynamic_Array || info.kind == .Map) {
		v.operand = implicit_pointer_deref(k, v.operand, pointee, pointer_mutable)
		operand_base = expr_base(v.operand)
		through_pointer = false
	}
	// A UTF-8 code point may span several bytes (design.md "string type").
	if info != nil && (info.kind == .String || info.kind == .String_View) {
		errorf(
			k.c, v.span, "L0563",
			"`%s` cannot be indexed by an integer, because a UTF-8 code point may span several bytes",
			type_name(k.c, operand),
		)
		add_notef(k.c, v.span, "use `text.bytes()[index]`, a subrange `text[low:high]`, or rune iteration")
		v.type = INVALID_TYPE
		return
	}
	if info != nil && single {
		#partial switch info.kind {
		case .C_Pointer:
			// Unchecked, and writable exactly as `p^` is (design.md "C pointers").
			check_integer_index(k, v.indices[0])
			if !require_unsafe_import(k, v.span, "indexing a C pointer") {
				v.type = INVALID_TYPE
				return
			}
			v.type = info.element
			v.value_category = .Place
			v.addressable = true
			v.assignable = true
			return
		case .Slice:
			// The element lives in the slice's root, so `[]mut T` decides the write,
			// not whether the slice variable itself is assignable.
			check_integer_index(k, v.indices[0])
			v.type = info.element
			v.value_category = .Place
			v.addressable = true
			v.assignable = info.mutable
			v.immutable = info.mutable ? .None : .Through_Slice
			return
		case .Dynamic_Array:
			// The element lives in the container's allocation, so it has the
			// container's capability (design.md "Dynamic arrays").
			check_integer_index(k, v.indices[0])
			v.type = info.element
			v.value_category = .Place
			v.addressable = true
			v.assignable = operand_base.assignable
			v.immutable = operand_base.immutable
			return
		case .Map:
			check_map_index(k, v, info, place, inserts, operand_base)
			return
		case .Simd:
			// A lane index must be a constant (design.md "SIMD vectors").
			check_simd_index(k, v, info, base_type, operand_base, through_pointer, pointer_mutable)
			return
		}
	}
	// Built-in indexing first; a user `operator([])` supplies what it does not.
	indexable := info != nil && (info.kind == .Array || info.kind == .Slice)
	if !indexable || !single {
		if check_user_index(k, v, operand, place) {
			return
		}
		if indexable {
			// Permanently reserved for a user `operator([])` (design.md "Indexing
			// and slicing").
			errorf(
				k.c, v.span, "L0362",
				"`%s` takes one index; `a[i, j]` is reserved for a user `operator([])` taking that many",
				type_name(k.c, operand),
			)
		} else {
			errorf(k.c, v.span, "L0362", "`%s` cannot be indexed", type_name(k.c, operand))
		}
		v.type = INVALID_TYPE
		return
	}

	check_integer_index(k, v.indices[0])
	v.type = info.element
	v.value_category = .Place
	inherit_capability(&v.base, operand_base, through_pointer, pointer_mutable)

	index_base := expr_base(v.indices[0])
	// A constant indexed at runtime needs read-only storage (design.md
	// "Materialization"); a constant index folds below instead.
	if operand_base.is_const && (index_base == nil || !index_base.is_const) {
		if request_materialization(k, v.operand) {
			v.addressable = false
			v.assignable = false
			v.immutable = .Read_Only
		}
	}
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

// An index into a built-in sequence: an integer, `int` when unfixed.
@(private = "file")
check_integer_index :: proc(k: ^Checker, e: Expr) {
	type := check_single_expr(k, e, TYPE_INT)
	if type == INVALID_TYPE {
		return
	}
	materialize(k, e, TYPE_INT)
	if !type_is_integer(k.c, expr_base(e).type) {
		errorf(k.c, expr_span(e), "L0362", "an index must be an integer, found `%s`", type_name(k.c, type))
	}
}

// `ok := key in m` (design.md "Maps").
@(private = "file")
check_map_membership :: proc(k: ^Checker, v: ^Expr_Binary) {
	container := check_single_expr(k, v.rhs)
	if container == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}
	if !type_is_map(k.c, container) {
		element := check_single_expr(k, v.lhs)
		if element == INVALID_TYPE {
			v.type = INVALID_TYPE
			return
		}
		if check_user_binary(k, v, element, container) {
			return
		}
		errorf(
			k.c, v.op_span, "L0587",
			"`in` tests a `map[K]V` for a key, found `%s`", type_name(k.c, container),
		)
		v.type = INVALID_TYPE
		return
	}
	if !check_map_key(k, v.lhs, container_key(k.c, container), true) {
		v.type = INVALID_TYPE
		return
	}
	v.type = TYPE_BOOL
}

// design.md "Maps": a key that is only compared may be a `string_view` for a
// `map[string]V`; one that is stored must be the owned `string`.
@(private = "file")
check_map_key :: proc(k: ^Checker, e: Expr, key: Type_Id, borrows: bool) -> bool {
	type := check_single_expr(k, e, key)
	if type == INVALID_TYPE || key == INVALID_TYPE {
		return false
	}
	if borrows && key == TYPE_STRING && type == TYPE_STRING_VIEW {
		return true
	}
	return materialize_value_expr(k, e, key, "look up")
}

// design.md "Maps": only `m[key] = elem` creates an entry. Every other position
// names part of an element that must already be there, and panics for a missing
// key. Insertion may reallocate, so it is a mutable borrow of `m` for the
// statement, which `src/cfg.odin` records.
@(private = "file")
check_map_index :: proc(
	k: ^Checker, v: ^Expr_Index, info: ^Type_Info, place, inserts: bool, operand: ^Expr_Base,
) {
	if !check_map_key(k, v.indices[0], info.key, !inserts) {
		v.type = INVALID_TYPE
		return
	}
	v.map_inserts = inserts
	v.type = info.element
	contribute_lifecycle_members(k, info.key)
	contribute_lifecycle_members(k, info.element)
	if !place {
		// `m.lookup_value(key)` and `m.find(key)` are the forms that do not panic.
		return
	}
	v.value_category = .Place
	v.addressable = true
	v.assignable = operand.assignable
	v.immutable = operand.immutable
	if inserts && !v.assignable {
		report_not_assignable(k, &v.base, "an inserting map index")
		v.type = INVALID_TYPE
	}
}

// design.md "Indexing and slicing": a place position requires the `inout`
// overload; any other position prefers the value one.
@(private = "file")
check_user_index :: proc(k: ^Checker, v: ^Expr_Index, operand: Type_Id, place: bool) -> bool {
	all := operator_candidates_for_receiver(k, "[]", operand)
	if len(all) == 0 {
		return false
	}
	candidates := select_by_place(k, all, place)
	if len(candidates) == 0 {
		errorf(
			k.c,
			v.span,
			"L0419",
			"`%s` has no `operator([])` returning `inout`, so this is not a place",
			type_name(k.c, operand),
		)
		v.type = INVALID_TYPE
		return true
	}

	args, ok := index_arguments(k, v.operand, v.indices, candidates)
	if !ok {
		v.type = INVALID_TYPE
		return true
	}
	chosen, bound := resolve_operator(k, v.span, "[]", []Type_Id{operand}, args, among = candidates)
	if chosen == INVALID_SYMBOL {
		v.type = INVALID_TYPE
		return true
	}
	sym := symbol_of(k.c, chosen)
	v.bound = bound
	v.resolution = Resolution{kind = .User_Operator, symbol = chosen, chosen_overload = chosen}
	v.type = sym.result
	if operator_result_is_place(k, chosen) {
		v.value_category = .Place
		v.addressable = true
		v.assignable = true
	}
	return true
}

// `x[lo:hi]`: built in for a carrier, `operator([:])` for anything else.
@(private = "file")
check_slice :: proc(k: ^Checker, v: ^Expr_Slice, place: bool) {
	v.value_category = .Value
	operand := check_single_expr(k, v.operand)
	if operand == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}
	if check_builtin_slice(k, v, operand) {
		return
	}
	slicers := operator_candidates_for_receiver(k, "[:]", operand)
	if len(slicers) == 0 {
		errorf(
			k.c, v.span, "L0362",
			"`%s` cannot be sliced; a user type needs an `operator([:])` overload",
			type_name(k.c, operand),
		)
		v.type = INVALID_TYPE
		return
	}
	// design.md "Indexing and slicing": an omitted endpoint means what it means
	// for built-in slicing, 0 and `x.len()`. The length is read from a second copy
	// of the operand, so only an operand whose evaluation has no effect qualifies.
	if v.lo == nil {
		zero := new(Expr_Literal, k.c.semantic_allocator)
		zero.span = v.span
		zero.kind = .Int
		zero.text = "0"
		v.lo = zero
	}
	length_omitted := false
	if v.hi == nil {
		if !is_effect_free_place(v.operand) {
			errorf(
				k.c, v.span, "L0421",
				"an omitted high endpoint is the operand's `len()`, so the operand must be a variable, field, or dereference; write the endpoint",
			)
			v.type = INVALID_TYPE
			return
		}
		callee := new(Expr_Selector, k.c.semantic_allocator)
		callee.span = v.span
		callee.operand = clone_expr(k.c, v.operand)
		callee.name = Name{text = "len", span = v.span, id = intern_identifier(k.c, "len")}
		length := new(Expr_Call, k.c.semantic_allocator)
		length.span = v.span
		length.callee = callee
		v.hi = length
		length_omitted = true
	}
	endpoints := make([]Expr, 2, k.c.semantic_allocator)
	endpoints[0], endpoints[1] = v.lo, v.hi
	args, ok := index_arguments(k, v.operand, endpoints)
	if !ok {
		if length_omitted && expr_base(v.hi).type == INVALID_TYPE {
			add_notef(k.c, v.span, "an omitted high endpoint is the operand's `len()`")
		}
		v.type = INVALID_TYPE
		return
	}
	chosen, bound := resolve_operator(k, v.span, "[:]", []Type_Id{operand}, args, among = slicers)
	if chosen == INVALID_SYMBOL {
		v.type = INVALID_TYPE
		return
	}
	sym := symbol_of(k.c, chosen)
	v.bound = bound
	v.resolution = Resolution{kind = .User_Operator, symbol = chosen, chosen_overload = chosen}
	v.type = sym.result
	// A `[]mut T` needs an exclusive receiver (design.md "Capabilities and the
	// one rule").
	if slice_is_mutable(k.c, v.type) && sym.receiver != .Inout {
		errorf(
			k.c,
			v.span,
			"L0547",
			"this `operator([:])` yields `%s`, which is an exclusive borrow, so its `self` parameter must be `inout`",
			type_name(k.c, v.type),
		)
		add_notef(k.c, sym.span, "declared here with a read-only receiver, which can only yield a read-only slice")
		v.type = INVALID_TYPE
	}
}

// A variable, a field path, or a dereference: evaluating one twice reads the same
// place and runs nothing.
@(private = "file")
is_effect_free_place :: proc(e: Expr) -> bool {
	#partial switch v in e {
	case ^Expr_Ident:
		return true
	case ^Expr_Selector:
		return is_effect_free_place(v.operand)
	case ^Expr_Postfix:
		return v.op == .Caret && is_effect_free_place(v.operand)
	}
	return false
}

// Slicing a built-in carrier (design.md "Slices"). Returns false for any other
// operand, leaving the user `operator([:])` path to run. An omitted low bound is
// 0 and an omitted high bound is the length.
@(private = "file")
check_builtin_slice :: proc(k: ^Checker, v: ^Expr_Slice, operand: Type_Id) -> bool {
	// Nominal, like `check_index`: a `distinct []T` leaves this to the user
	// `operator([:])` its declaration has to bring over.
	info := type_of(k.c, operand)
	if info == nil {
		return false
	}
	#partial switch info.kind {
	case .Array, .Slice, .Dynamic_Array, .String, .String_View, .C_Pointer:
	case:
		return false
	}
	base := expr_base(v.operand)
	// A constant array slices its materialised storage, which is static and
	// read-only.
	materialized := info.kind == .Array && base.is_const && request_materialization(k, v.operand)
	lo := v.lo == nil || check_slice_endpoint(k, v.lo)
	hi := v.hi == nil || check_slice_endpoint(k, v.hi)
	ok := lo && hi
	// The slice keeps its root's address, which a temporary would not outlive.
	if info.kind == .Array && !materialized && !base.addressable {
		errorf(k.c, v.span, "L0477", "`%s` has no storage to slice; bind it to a variable first", type_name(k.c, operand))
		ok = false
	}
	v.value_category = .Value
	v.immutable = .Temporary
	if info.kind == .C_Pointer && !require_unsafe_import(k, v.span, "slicing a C pointer") {
		ok = false
	}
	if !ok {
		v.type = INVALID_TYPE
		return true
	}
	#partial switch info.kind {
	case .Array:
		v.type = slice_of(k.c, info.element, !materialized && base.addressable && base.immutable == .None)
	case .Slice:
		v.type = slice_of(k.c, info.element, info.mutable)
	case .Dynamic_Array:
		v.type = slice_of(k.c, info.element, base.assignable)
	case .String, .String_View:
		// The bounds are checked at run time against the length and the encoding.
		v.type = TYPE_STRING_VIEW
	case .C_Pointer:
		// Without a high bound there is no length, so the result stays a C
		// pointer (design.md "C pointers").
		v.type = v.hi == nil ? c_pointer_to(k.c, info.element) : slice_of(k.c, info.element, mutable = true)
	}
	return true
}

@(private = "file")
check_slice_endpoint :: proc(k: ^Checker, e: Expr) -> bool {
	type := check_single_expr(k, e, TYPE_INT)
	if type == INVALID_TYPE {
		return false
	}
	if type_is_untyped(k.c, type) {
		return materialize(k, e, TYPE_INT)
	}
	if !type_is_integer(k.c, type) {
		errorf(k.c, expr_span(e), "L0477", "a slice bound must be an integer, found `%s`", type_name(k.c, type))
		return false
	}
	return true
}

// The overloads a place or value position may use; a value position falls back
// to `inout` ones when there is nothing else.
@(private = "file")
select_by_place :: proc(k: ^Checker, all: []Symbol_Id, place: bool) -> []Symbol_Id {
	out := make([dynamic]Symbol_Id, 0, len(all), k.c.semantic_allocator)
	for candidate in all {
		if operator_result_is_place(k, candidate) == place {
			append(&out, candidate)
		}
	}
	if len(out) == 0 && !place {
		return all
	}
	return out[:]
}

// The receiver and every index, each checked exactly once.
@(private = "file")
index_arguments :: proc(
	k: ^Checker,
	receiver: Expr,
	indices: []Expr,
	candidates: []Symbol_Id = nil,
) -> ([]Arg_Info, bool) {
	args := make([]Arg_Info, len(indices) + 1, k.c.semantic_allocator)
	args[0] = arg_from_expr(receiver)
	args[0].is_receiver = true
	ok := true
	for index, position in indices {
		expected := agreed_index_param(k, candidates, position, len(indices))
		if check_single_expr(k, index, expected) == INVALID_TYPE {
			ok = false
			continue
		}
		args[position + 1] = arg_from_expr(index)
	}
	return args, ok
}

// The expected type for an index, so `counts[.North]` resolves: the parameter
// type every candidate agrees on, or INVALID_TYPE.
@(private = "file")
agreed_index_param :: proc(k: ^Checker, candidates: []Symbol_Id, position: int, arity: int) -> Type_Id {
	agreed := INVALID_TYPE
	for id in candidates {
		sym := symbol_of(k.c, id)
		if sym == nil || len(sym.params) != arity + 1 {
			continue
		}
		if agreed == INVALID_TYPE {
			agreed = sym.params[position + 1]
		} else if agreed != sym.params[position + 1] {
			return INVALID_TYPE
		}
	}
	return agreed
}

// ------------------------------------------------------------------ unary --

// design.md "@(packed)": the name of a field reached through a packed struct
// anywhere in the selector chain.
@(private)
packed_field_reached :: proc(k: ^Checker, operand: Expr) -> (string, bool) {
	cur := operand
	for {
		name: string
		next: Expr
		#partial switch v in cur {
		case ^Expr_Selector:
			name, next = v.name.text, v.operand
		case ^Expr_Call:
			// `field.get(value)` selects from what `value` points at.
			reflect, is_reflect := v.operation.(Call_Reflect)
			sym := symbol_of(k.c, reflect.field)
			if !is_reflect || reflect.op != .Field_Get || sym == nil || len(v.bound) != 1 {
				return "", false
			}
			name, next = identifier_text(k.c, sym.name), v.bound[0]
		}
		if next == nil {
			return "", false
		}
		base := expr_base(next)
		if base != nil {
			struct_type := type_underlying(k.c, base.type)
			if info := type_of(k.c, struct_type); info != nil && info.kind == .Pointer {
				struct_type = type_underlying(k.c, info.element)
			}
			if info := type_of(k.c, struct_type); info != nil && info.kind == .Struct && info.packed {
				return name, true
			}
		}
		cur = next
	}
}

@(private = "file")
check_unary :: proc(k: ^Checker, v: ^Expr_Unary, expected: Type_Id) {
	v.value_category = .Value

	if v.op == .Amp {
		// A place position that never inserts.
		saved_insert := k.insert_position
		k.place_position, k.insert_position = true, false
		operand := check_single_expr(k, v.operand, pointee_of(k.c, expected))
		k.place_position, k.insert_position = false, saved_insert
		if operand == INVALID_TYPE {
			v.type = INVALID_TYPE
			return
		}
		operand_base := expr_base(v.operand)
		// `&mut local` hands out a write this pass cannot read.
		if v.mutable {
			note_unknown_nil_write(k, v.operand)
		}
		// A named constant gets read-only storage (design.md "Materialization"),
		// so `&mut` is then rejected as a constant.
		if !operand_base.addressable && request_materialization(k, v.operand) {
			operand_base.addressable = true
		}
		if !operand_base.addressable {
			errorf(k.c, v.op_span, "L0357", "`%s` needs an addressable operand", v.mutable ? "&mut" : "&")
			v.type = INVALID_TYPE
			return
		}
		if v.mutable && !operand_base.assignable {
			report_not_assignable(k, operand_base, "borrowed with `&mut`")
			v.type = INVALID_TYPE
			return
		}
		// A packed field may be misaligned (design.md "@(packed)").
		if field, packed := packed_field_reached(k, v.operand); packed {
			errorf(
				k.c, v.op_span, "L0614",
				"cannot take the address of `%s`: it is reached through a packed struct", field,
			)
			v.type = INVALID_TYPE
			return
		}
		v.type = pointer_to(k.c, operand, v.mutable)
		return
	}

	operand := check_single_expr(k, v.operand, expected)
	if operand == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}
	operand_base := expr_base(v.operand)
	// A built-in operation cannot be shadowed by a user overload.
	if !builtin_unary_defined(k, v.op, operand) {
		if check_user_unary(k, v, operand) {
			return
		}
	}
	if simd_operand(k.c, operand) {
		check_simd_unary(k, v, operand)
		return
	}
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
		if v.op == .Minus && !signed_fits(k.c, folded.integer, v.type) {
			report_signed_overflow(k.c, v.op_span, folded.integer, v.type)
			return
		}
		folded.integer = wrap_to_type(k.c, folded.integer, v.type)
	}
	v.is_const = true
	v.const_value = folded
}

@(private = "file")
check_user_unary :: proc(k: ^Checker, v: ^Expr_Unary, operand: Type_Id) -> bool {
	symbol := operator_text(v.op)
	operands := []Type_Id{operand}
	if !operator_exists(k, symbol, operands) {
		return false
	}
	args := make([]Arg_Info, 1, k.c.semantic_allocator)
	args[0] = arg_from_expr(v.operand)
	chosen, bound := resolve_operator(k, v.op_span, symbol, operands, args)
	if chosen == INVALID_SYMBOL {
		v.type = INVALID_TYPE
		return true
	}
	sym := symbol_of(k.c, chosen)
	v.operand = bound[0]
	v.resolution = Resolution{kind = .User_Operator, symbol = chosen, chosen_overload = chosen}
	v.type = sym.result
	return true
}

// design.md: `!=` falls back to `!(left == right)` when `==` is available and no
// more specific `!=` overload exists.
@(private = "file")
check_user_binary :: proc(k: ^Checker, v: ^Expr_Binary, lhs, rhs: Type_Id) -> bool {
	symbol := operator_text(v.op)
	operands := []Type_Id{lhs, rhs}
	args := make([]Arg_Info, 2, k.c.semantic_allocator)
	args[0] = arg_from_expr(v.lhs)
	args[1] = arg_from_expr(v.rhs)
	negate := false
	if !operator_viable(k, symbol, operands, args) {
		if v.op != .Not_Eq || !operator_viable(k, "==", operands, args) {
			if operator_exists(k, symbol, operands) {
				resolve_operator(k, v.op_span, symbol, operands, args)
				v.type = INVALID_TYPE
				return true
			}
			return false
		}
		symbol = "=="
		negate = true
	}
	chosen, bound := resolve_operator(k, v.op_span, symbol, operands, args)
	if chosen == INVALID_SYMBOL {
		v.type = INVALID_TYPE
		return true
	}
	sym := symbol_of(k.c, chosen)
	v.lhs, v.rhs = bound[0], bound[1]
	v.negated = negate
	v.resolution = Resolution{kind = .User_Operator, symbol = chosen, chosen_overload = chosen}
	v.type = sym.result
	return true
}

@(private = "file")
check_postfix :: proc(k: ^Checker, v: ^Expr_Postfix) {
	v.value_category = .Value
	if v.op == .Or_Return {
		check_or_return(k, v)
		return
	}
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
	info := underlying_info(k.c, operand)
	if info == nil || info.kind != .Pointer {
		errorf(k.c, v.op_span, "L0355", "`^` needs a pointer, found `%s`", type_name(k.c, operand))
		v.type = INVALID_TYPE
		return
	}
	note_nil_use(k, v.operand, "dereference")
	v.type = info.element
	v.value_category = .Place
	v.addressable = true
	v.assignable = info.mutable
	v.immutable = info.mutable ? .None : .Through_Pointer
}

// ----------------------------------------------------------------- binary --

// A bare `.Member` with no operand — the implicit enum selector.
@(private = "file")
is_implicit_selector :: proc(e: Expr) -> bool {
	sel, ok := e.(^Expr_Selector)
	return ok && sel.operand == nil
}

@(private = "file")
check_binary :: proc(k: ^Checker, v: ^Expr_Binary, expected: Type_Id) {
	v.value_category = .Value
	v.resolution.kind = .Builtin_Operator

	// `&&` and `||` control whether an operand is evaluated, so they are not
	// overloadable (design.md "Operator declarations").
	if v.op == .And_And || v.op == .Or_Or {
		check_logical(k, v)
		return
	}

	// `ok := key in m` (design.md "Maps"). The right operand settles the key's
	// type, so this is not an ordinary unified binary operation.
	if v.op == .In {
		check_map_membership(k, v)
		return
	}

	is_comparison := false
	#partial switch v.op {
	case .Eq_Eq, .Not_Eq, .Lt, .Lt_Eq, .Gt, .Gt_Eq:
		is_comparison = true
	}
	shift := v.op == .Shl || v.op == .Shr

	hint := is_comparison ? INVALID_TYPE : expected
	lhs, rhs: Type_Id
	// `LOKE_OS == .Windows`: a bare `.Member` takes the other operand's type.
	if is_comparison && is_implicit_selector(v.rhs) && !is_implicit_selector(v.lhs) {
		lhs = check_single_expr(k, v.lhs, INVALID_TYPE)
		rhs = check_single_expr(k, v.rhs, lhs)
	} else if is_comparison && is_implicit_selector(v.lhs) && !is_implicit_selector(v.rhs) {
		rhs = check_single_expr(k, v.rhs, INVALID_TYPE)
		lhs = check_single_expr(k, v.lhs, rhs)
	} else {
		lhs = check_single_expr(k, v.lhs, hint)
		rhs = check_single_expr(k, v.rhs, shift ? INVALID_TYPE : hint)
	}
	if lhs == INVALID_TYPE || rhs == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}

	// design.md "SIMD vectors": lane-wise, with its own operator table.
	if simd_operand(k.c, lhs) || simd_operand(k.c, rhs) {
		check_simd_binary(k, v, lhs, rhs)
		return
	}
	if !builtin_binary_defined(k, v.op, lhs, rhs) {
		if check_user_binary(k, v, lhs, rhs) {
			return
		}
	}
	if shift {
		check_shift(k, v, expected, lhs, rhs)
		return
	}

	// Asked before unification materialises a written `nil`.
	nil_only := is_comparison &&
	            (type_compares_to_nil_only(k.c, lhs) || type_compares_to_nil_only(k.c, rhs))
	against_nil := lhs == TYPE_UNTYPED_NIL || rhs == TYPE_UNTYPED_NIL

	operand_type, unified := unify_operands(k, v.lhs, v.rhs, v.op_span)
	if !unified {
		v.type = INVALID_TYPE
		return
	}

	if is_comparison {
		// A slice or dyn value compares against nil only (design.md "Nil slices").
		if nil_only && !against_nil {
			errorf(
				k.c,
				v.op_span,
				"L0476",
				"`%s` compares against `nil` and nothing else",
				type_name(k.c, type_compares_to_nil_only(k.c, lhs) ? lhs : rhs),
			)
			v.type = INVALID_TYPE
			return
		}
		check_comparison(k, v, operand_type, nil_only)
		return
	}

	if !builtin_operator_applies(k.c, v.op, operand_type) {
		operator_mismatch2(k, v.op_span, v.op, lhs, rhs)
		v.type = INVALID_TYPE
		return
	}
	v.type = operand_type
	// Concatenating text always produces an owning `string`.
	if v.op == .Plus && type_is_utf8_text(k.c, operand_type) {
		v.type = TYPE_STRING
	}

	left, right := expr_base(v.lhs), expr_base(v.rhs)
	if !left.is_const || !right.is_const {
		return
	}
	folded, ok := fold_arithmetic(k.c, v.op, v.op_span, left.const_value, right.const_value, operand_type)
	if !ok {
		v.type = INVALID_TYPE
		return
	}
	v.is_const = true
	v.const_value = folded
}

// `a && b` evaluates to `b` if `a` else `false` (design.md), so the right
// operand is checked but only the selected value is folded.
@(private = "file")
check_logical :: proc(k: ^Checker, v: ^Expr_Binary) {
	lhs := check_single_expr(k, v.lhs, TYPE_BOOL)
	rhs := check_single_expr(k, v.rhs, TYPE_BOOL)
	if lhs == INVALID_TYPE || rhs == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}
	if reject_simd_logical(k, v, lhs, rhs) {
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
check_shift :: proc(k: ^Checker, v: ^Expr_Binary, expected: Type_Id, left_type, rhs: Type_Id) {
	lhs := left_type
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

	folded, folded_ok := fold_arithmetic(
		k.c, v.op, v.op_span, left.const_value, right.const_value, v.type,
	)
	if !folded_ok {
		v.type = INVALID_TYPE
		return
	}
	v.is_const = true
	v.const_value = folded
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
// `nil_only` says the operand type compares against `nil` and nothing else,
// which `check_binary` has already confirmed is what this comparison does.
check_comparison :: proc(k: ^Checker, v: ^Expr_Binary, operand_type: Type_Id, nil_only := false) {
	ordered := v.op != .Eq_Eq && v.op != .Not_Eq
	both := []Type_Id{operand_type, operand_type}
	if ordered && !type_is_ordered(k.c, operand_type) {
		// Said in the message, not a note: an interface requirement keeps only
		// the message.
		if hidden_inherent_operator(k, operator_text(v.op), both) {
			errorf(
				k.c, v.op_span, "L0355",
				"`%s` does not order `%s` here: its inherent `%s` is not `@(public)`",
				operator_text(v.op), type_name(k.c, operand_type), operator_text(v.op),
			)
		} else {
			errorf(k.c, v.op_span, "L0355", "`%s` does not order `%s`", operator_text(v.op), type_name(k.c, operand_type))
		}
		v.type = INVALID_TYPE
		return
	}
	if !ordered && !nil_only && !type_is_comparable(k.c, operand_type) {
		errorf(k.c, v.op_span, "L0355", "`%s` is not comparable", type_name(k.c, operand_type))
		v.type = INVALID_TYPE
		return
	}
	// A hidden inherent `==` must not be replaced by field-wise equality: one
	// type has one equality (design.md "Maps"). `!=` falls back to `==`.
	if !ordered &&
	   (hidden_inherent_operator(k, "==", both) ||
	    (v.op == .Not_Eq && hidden_inherent_operator(k, "!=", both))) {
		errorf(
			k.c, v.op_span, "L0355",
			"`%s` has an inherent `%s` that is not `@(public)`, so this package cannot compare it",
			type_name(k.c, operand_type), v.op == .Not_Eq ? "!=" : "==",
		)
		add_notef(
			k.c, v.op_span,
			"comparing field-wise here would be a second equality for one type; export the operator instead",
		)
		v.type = INVALID_TYPE
		return
	}

	left, right := expr_base(v.lhs), expr_base(v.rhs)
	if left.is_const && right.is_const {
		result, ok := fold_comparison(k.c, v.op, left.const_value, right.const_value)
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
	if type_kind(k.c, lt) == .Proc && type_kind(k.c, rt) == .Proc {
		plain := erase_proc_contract(k.c, lt)
		if plain == erase_proc_contract(k.c, rt) { return plain, true }
	}
	left_untyped := type_is_untyped(k.c, lt)
	right_untyped := type_is_untyped(k.c, rt)

	switch {
	case left_untyped && right_untyped:
		merged, ok := merge_untyped_types(lt, rt)
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
	// A `string` and a `string_view` may occur in either order (design.md
	// "Arithmetic operators" and "Comparison operators"). They meet at the borrowed
	// view, which is the one both sides can produce without allocating.
	if type_is_utf8_text(k.c, lt) && type_is_utf8_text(k.c, rt) {
		if materialize(k, lhs, TYPE_STRING_VIEW) && materialize(k, rhs, TYPE_STRING_VIEW) {
			return TYPE_STRING_VIEW, true
		}
	}
	operand_mismatch(k, op_span, lt, rt)
	return INVALID_TYPE, false
}

// Shared with operator lookup, which has to know what the built-in table would
// unify two untyped operands to before anything materialises.
merge_untyped_types :: proc(a, b: Type_Id) -> (Type_Id, bool) {
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

// The built-in operator table, asked as a predicate so the unshadowable
// built-in rule can be decided before any user lookup.
builtin_operator_applies :: proc(c: ^Compiler, op: Token_Kind, type: Type_Id) -> bool {
	if type_kind(c, type) == .Distinct {
		return false
	}
	#partial switch op {
	case .Plus:
		// design.md "Arithmetic operators": two `string`/`string_view` operands in
		// either order produce an owning `string`.
		#partial switch underlying_kind(c, type) {
		case .String, .String_View:
			return true
		}
		return type_is_numeric(c, type) || type_kind(c, type) == .Untyped_String
	case .Minus, .Star, .Slash:
		return type_is_numeric(c, type)
	case .Percent:
		return type_is_integer(c, type) || type_is_rune(c, type)
	case .Amp, .Pipe, .Tilde, .Amp_Tilde:
		return type_is_integer(c, type) || type_is_rune(c, type)
	}
	return false
}

// ------------------------------------------------------------ conditional --

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
	// An expected procedure type constrains both arms.
	if type_kind(k.c, expected) == .Proc && assignable(k.c, then_type, expected) && assignable(k.c, else_type, expected) {
		materialize(k, v.then, expected)
		materialize(k, v.otherwise, expected)
		v.type = expected
		return
	}
	if joined, ok := join_callback_types(k.c, then_type, else_type); ok {
		v.type = joined
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

// A procedure literal in expression position is hoisted to its own module
// function. It has no closure, so `check_ident` rejects any name that lives in
// an enclosing procedure's frame.
@(private = "file")
check_proc_literal :: proc(k: ^Checker, v: ^Expr_Proc) {
	v.value_category = .Value
	if v.bodiless {
		errorf(
			k.c, v.span, "L0630",
			"only a foreign declaration ends with `---`; a procedure value needs a body",
		)
		v.type = INVALID_TYPE
		return
	}
	if len(v.where_clauses) > 0 || v.signature == nil {
		unsupported_construct(k, v.span)
		v.type = INVALID_TYPE
		return
	}
	if v.symbol == INVALID_SYMBOL {
		v.symbol = new_symbol(k.c, Symbol {
			name = intern_identifier(k.c, "proc$literal"),
			span = v.span,
			kind = .Proc,
			pkg  = k.pkg,
		})
	}
	outer_impl := k.impl_type
	k.impl_type = INVALID_TYPE
	defer k.impl_type = outer_impl
	resolve_proc_signature(k, v, v.symbol)
	symbol := symbol_of(k.c, v.symbol)
	if symbol == nil {
		v.type = INVALID_TYPE
		return
	}
	symbol.proc_literal = v
	v.type = symbol.proc_type
	// Not while speculatively checking an interface requirement.
	if pkg := package_of(k.c, k.pkg); pkg != nil && k.c.speculation_depth == 0 {
		append(&pkg.hoisted_procs, v)
	}
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
			report_unresolved_type(k, array.elem)
			v.type = INVALID_TYPE
			return
		}
		array.denoted_type = array_of(k.c, element, u64(len(v.elements)))
		array.resolution.kind = .Type
		target = array.denoted_type
	} else if v.type_expr != nil {
		target = resolve_type_syntax(k, v.type_expr)
		if target == INVALID_TYPE {
			// `resolve_type_syntax` is silent, so a written type reports here.
			report_unresolved_type(k, v.type_expr)
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
	v.addressable = true
	v.assignable = false
	v.immutable = .Temporary
	// A container's operation table holds clone beside drop, so even one that is
	// never copied needs both.
	if type_is_managed(k.c, target) {
		contribute_lifecycle_members(k, target)
	}

	#partial switch info.kind {
	case .Struct:
		check_struct_literal(k, v, target, info)
	case .Array, .Simd:
		// design.md "SIMD vectors": one element per lane, as for an array.
		check_array_literal(k, v, target, info)
	case .Slice:
		check_slice_literal(k, v, target, info)
	case .Dynamic_Array:
		check_dynamic_literal(k, v, target, info)
	case .Map:
		check_map_literal(k, v, target, info)
	case:
		// design.md "Zero values": `{}` is any type's zero value.
		if len(v.elements) == 0 {
			if !require_type_has_zero(k, target, v.span, "`{}`") {
				v.type = INVALID_TYPE
				return
			}
			if zero, ok := zero_const(k.c, target); ok {
				v.is_const = true
				v.const_value = zero
				return
			}
		}
		errorf(k.c, v.span, "L0376", "`%s` cannot be built from a composite literal", type_name(k.c, target))
		v.type = INVALID_TYPE
	}
}

// A slice literal has its written type, never the destination's (design.md
// "Slice literals"). It views a hidden fixed array in the enclosing scope.
@(private = "file")
check_slice_literal :: proc(k: ^Checker, v: ^Expr_Composite, target: Type_Id, info: ^Type_Info) {
	if v.type_expr == nil {
		// The braces are not in the format string, where `{` is a directive.
		errorf(k.c, v.span, "L0479", "a slice literal must be written with its type, as in `%s`", concat(k.c, type_name(k.c, target), "{ ... }"))
		v.type = INVALID_TYPE
		return
	}
	v.backing = array_of(k.c, info.element, u64(len(v.elements)))
	ok := true
	for element, index in v.elements {
		if element.key != nil {
			errorf(k.c, element.span, "L0479", "a slice literal has no keyed elements")
			ok = false
			continue
		}
		if !check_value_expr(k, element.value, info.element, "initialise") {
			ok = false
			continue
		}
		// The hidden array owns its elements, so a borrowed one is cloned.
		classify_composite_element(k, v, index, info.element)
	}
	if !ok {
		v.type = INVALID_TYPE
		return
	}
	v.addressable = false
	v.assignable = false
	v.immutable = .Temporary
}

@(private = "file")
check_struct_literal :: proc(k: ^Checker, v: ^Expr_Composite, target: Type_Id, info: ^Type_Info) {
	count := len(info.fields)
	values := make([]Expr, count, k.c.semantic_allocator)
	seen := make([]bool, count, k.c.semantic_allocator)
	v.field_indices = make([]int, len(v.elements), k.c.semantic_allocator)
	for &slot in v.field_indices { slot = -1 }
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
			if !require_visible_field(k, element.span, target, field, "L0473", "initialised") {
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
			v.field_indices[index] = int(symbol.index)
			if !check_value_expr(k, element.value, symbol.type, "initialise") {
				ok = false
			} else {
				classify_composite_element(k, v, index, symbol.type)
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
		// Supplying an inaccessible field is rejected; omitting one is not.
		if !require_visible_field(k, element.span, target, info.fields[index], "L0474", "initialised positionally") {
			ok = false
			continue
		}
		symbol := symbol_of(k.c, info.fields[index])
		seen[index] = true
		values[index] = element.value
		v.field_indices[index] = index
		if !check_value_expr(k, element.value, symbol.type, "initialise") {
			ok = false
		} else {
			classify_composite_element(k, v, index, symbol.type)
		}
	}
	if !ok {
		return
	}
	// design.md "Zero values": an omitted field is filled with its type's zero,
	// and a no-zero type has none to fill it with.
	for field, index in info.fields {
		if seen[index] {
			continue
		}
		symbol := symbol_of(k.c, field)
		if symbol == nil || symbol.initialized_by != INVALID_SYMBOL {
			continue
		}
		if !require_type_has_zero(k, symbol.type, v.span, strings.concatenate({"the omitted field `", identifier_text(k.c, symbol.name), "`"}, context.temp_allocator)) {
			ok = false
		}
	}
	if !ok {
		return
	}
	fold_aggregate(k, v, target, values, info.fields)
}

// A sequence literal lists its elements positionally. Reported once per literal.
@(private = "file")
reject_keyed_element :: proc(k: ^Checker, element: Element, target: Type_Id) {
	errorf(
		k.c, element.span, "L0372",
		"a `%s` literal lists its elements positionally",
		type_name(k.c, target),
	)
}

@(private = "file")
check_array_literal :: proc(k: ^Checker, v: ^Expr_Composite, target: Type_Id, info: ^Type_Info) {
	count := int(info.count)
	if len(v.elements) < count && !require_type_has_zero(k, info.element, v.span, "omitted array elements") {
		v.type = INVALID_TYPE
		return
	}
	values := make([]Expr, count, k.c.semantic_allocator)
	ok := true
	for element, index in v.elements {
		if element.key != nil {
			if ok {
				reject_keyed_element(k, element, target)
			}
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
		} else {
			classify_composite_element(k, v, index, info.element)
		}
	}
	if ok {
		fold_aggregate(k, v, target, values, nil)
	}
}

// design.md "Dynamic arrays": a literal allocates, so only the empty one is a
// constant: the all-zero header.
@(private = "file")
check_dynamic_literal :: proc(k: ^Checker, v: ^Expr_Composite, target: Type_Id, info: ^Type_Info) {
	if len(v.elements) == 0 {
		v.is_const = true
		if zero, ok := zero_const(k.c, target); ok {
			v.const_value = zero
		}
		return
	}
	// Insertion clones a borrowed element, so its copy entry point has to exist.
	contribute_lifecycle_members(k, info.element)
	reported := false
	for element, index in v.elements {
		if element.key != nil {
			if !reported {
				reject_keyed_element(k, element, target)
				reported = true
			}
			continue
		}
		if !check_value_expr(k, element.value, info.element, "initialise") {
			continue
		}
		classify_composite_element(k, v, index, info.element)
	}
}

// `{key = value, ...}` (design.md "Maps"); allocates like a dynamic array's.
@(private = "file")
check_map_literal :: proc(k: ^Checker, v: ^Expr_Composite, target: Type_Id, info: ^Type_Info) {
	if len(v.elements) == 0 {
		v.is_const = true
		if zero, ok := zero_const(k.c, target); ok {
			v.const_value = zero
		}
		return
	}
	// Insertion clones both halves, so both copy entry points have to exist.
	contribute_lifecycle_members(k, info.key)
	contribute_lifecycle_members(k, info.element)
	for element, index in v.elements {
		if element.key == nil {
			errorf(
				k.c, element.span, "L0376",
				"a `%s` literal writes each entry as `key = value`", type_name(k.c, target),
			)
			continue
		}
		if !check_value_expr(k, element.key, info.key, "use as a key") {
			continue
		}
		if !check_value_expr(k, element.value, info.element, "initialise") {
			continue
		}
		classify_composite_element(k, v, index, info.element)
	}
}

// A literal whose written elements all folded is a constant, with zero values
// for the rest.
@(private = "file")
fold_aggregate :: proc(k: ^Checker, v: ^Expr_Composite, target: Type_Id, values: []Expr, fields: []Symbol_Id) {
	elements := make([]Const_Value, len(values), k.c.semantic_allocator)
	for value, index in values {
		if value == nil {
			element_type := INVALID_TYPE
			if fields == nil {
				element_type = underlying_info(k.c, target).element
			} else {
				field := symbol_of(k.c, fields[index])
				element_type = field.type
				if field.initialized_by != INVALID_SYMBOL {
					elements[index] = capacity_const(k.c, element_type)
					continue
				}
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

// The all-zero bytes of a fixed array field whose elements are not yet values.
// Invalid element constants preserve that distinction for the evaluator, while
// the backend writes their inert representation as `zeroinitializer`.
capacity_const :: proc(c: ^Compiler, type: Type_Id) -> Const_Value {
	info := underlying_info(c, type)
	elements := make([]Const_Value, info.count, c.semantic_allocator)
	aggregate := new(Const_Aggregate, c.semantic_allocator)
	aggregate.type = type
	aggregate.elements = elements
	return Const_Value{kind = .Aggregate, aggregate = aggregate}
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
		return rune_const(bi_from_i64(c, 0)), true
	case .Float:
		return float_const(0, info.bits), true
	case .Enum:
		return int_const(c, 0), type_has_zero(c, type)
	case .Typeid:
		// design.md "`type` and `typeid`": `Invalid`, numerically 0.
		return type_const(INVALID_TYPE), true
	case .Pointer, .C_Pointer, .Raw_Pointer, .Proc, .Union, .Allocator, .Allocator_Error,
	     .CString_View:
		return nil_const(), true
	case .String, .String_View:
		return Const_Value{kind = .String}, true
	case .Array, .Simd:
		elements := make([]Const_Value, info.count, c.semantic_allocator)
		if info.count > 0 {
			element, ok := zero_const(c, info.element)
			if !ok {
				return Const_Value{}, false
			}
			for index in 0 ..< int(info.count) {
				elements[index] = element
			}
		}
		aggregate := new(Const_Aggregate, c.semantic_allocator)
		aggregate.type = type
		aggregate.elements = elements
		return Const_Value{kind = .Aggregate, aggregate = aggregate}, true
	case .Struct, .Any_View, .Dyn, .Slice, .Dynamic_Array, .Map:
		// A record containing itself by value was already reported and has no
		// zero value to build.
		if info.size_state == .Cyclic {
			return Const_Value{}, false
		}
		// All-zero fields: a nil view or slice, or an empty container.
		ensure_slice_fields(c, under)
		ensure_container_fields(c, under)
		info = type_of(c, under)
		elements := make([]Const_Value, len(info.fields), c.semantic_allocator)
		for field, index in info.fields {
			symbol := symbol_of(c, field)
			if symbol == nil {
				return Const_Value{}, false
			}
			if symbol.initialized_by != INVALID_SYMBOL {
				elements[index] = capacity_const(c, symbol.type)
				continue
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
	if type_is_enum(k.c, target) && type_is_untyped(k.c, base.type) {
		errorf(k.c, base.span, "L0310", "an enum requires a variant; use `%s.from_int(value)` to validate a backing integer", type_name(k.c, target))
		return false
	}
	// A `string` borrows as a `string_view` with no validation: it is already
	// valid UTF-8.
	if (underlying_kind(k.c, target) == .String_View && underlying_kind(k.c, base.type) == .String) ||
	   dynamic_views_as(k.c, base.type, target) {
		base.view_from = base.type
		base.type = target
		return true
	}
	// design.md "SIMD vectors": a runtime scalar splats; a constant folds below.
	if type_is_simd(k.c, target) && !type_is_simd(k.c, base.type) && !base.is_const {
		element := type_of(k.c, type_underlying(k.c, target)).element
		if base.type != element && !materialize(k, e, element) {
			return false
		}
		base.splat_from = expr_base(e).type
		base.type = target
		return true
	}
	// The concrete type is kept so the backend knows what to take the address
	// of and which `typeid` to pair with it (design.md "any_view type").
	if target == TYPE_ANY_VIEW && base.type != TYPE_ANY_VIEW {
		if !any_view_accepts(k.c, base.type) {
			// Erasing a descriptor would materialise it at run time.
			if offender := compile_time_only_component(k.c, base.type); offender != INVALID_TYPE {
				report_compile_time_only(k, offender, base.span)
			}
			return false
		}
		concrete := any_view_source_type(k.c, base.type)
		if type_is_untyped(k.c, base.type) && !materialize(k, e, concrete) {
			return false
		}
		ensure_any_view_fields(k.c)
		request_typeid(k.c, concrete)
		base.erased_from = concrete
		base.type = TYPE_ANY_VIEW
		return true
	}
	if !type_is_untyped(k.c, base.type) {
		record_proc_contract_check(k.c, base.type, target, base.span)
		return true
	}
	// `a if c else b` with a runtime condition is untyped but not constant, so
	// its branches take the type.
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
		merged, ok := merge_untyped_types(base.type, target)
		if !ok {
			return true
		}
		converted, fits := convert_const(k.c, base.const_value, merged, false)
		if !fits {
			return true
		}
		base.type = merged
		base.const_value = converted
		return true
	}
	if !base.is_const {
		// Should not arise; the default type is the honest answer.
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
	case .String:
		if !utf8.valid_string(base.const_value.text) {
			report_invalid_utf8(k, base.span, target)
			return
		}
		errorf(k.c, base.span, "L0310", "this constant is not a value of `%s`", type_name(k.c, target))
	case .Boolean, .Type, .Aggregate, .Invalid:
		errorf(k.c, base.span, "L0310", "this constant is not a value of `%s`", type_name(k.c, target))
	}
}

// Is this the constant `convert_const` refuses because its bytes are not text?
constant_is_invalid_text :: proc(c: ^Compiler, value: Const_Value, target: Type_Id) -> bool {
	#partial switch underlying_kind(c, target) {
	case .String, .String_View:
		return value.kind == .String && !utf8.valid_string(value.text)
	}
	return false
}

// Shared by implicit and written conversions, so `s: string = "\xff"` and
// `string("\xff")` say the same thing.
report_invalid_utf8 :: proc(k: ^Checker, span: Span, target: Type_Id) {
	errorf(
		k.c,
		span,
		"L0702",
		"this string constant is not valid UTF-8, so it is not a `%s`; write the bytes as a `[]u8` literal, or use a `cstring_view`",
		type_name(k.c, target),
	)
}

// Converts a constant to a target type. An `explicit` `T(v)` truncates a float
// to an integer; an implicit conversion needs it exact.
convert_const :: proc(c: ^Compiler, value: Const_Value, target: Type_Id, explicit: bool, allocator: mem.Allocator = {}) -> (Const_Value, bool) {
	storage := value_allocator(c, allocator)
	info := underlying_info(c, target)
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
			converted, fits := bi_to_float(storage, value.integer, 64)
			return fits ? float_const(converted, 64) : value, fits
		}
	case .Untyped_Bool:
		if value.kind == .Boolean {
			return value, true
		}
	case .Untyped_Nil:
		if value.kind == .Nil {
			return value, true
		}
	case .Untyped_String, .CString_View:
		if value.kind == .String {
			return value, true
		}
		// A view's zero value is `nil` (design.md "Zero values"); a `string`'s is `""`.
		if value.kind == .Nil && info.kind == .CString_View {
			return nil_const(), true
		}
	// A `string` always holds valid UTF-8 (design.md "string type"). It is checked
	// after folding, so `"\xc3" + "\xa9"` is the `é` it spells.
	case .String, .String_View:
		if value.kind == .String {
			return value, utf8.valid_string(value.text)
		}
		if value.kind == .Nil && info.kind == .String_View {
			return Const_Value{kind = .String}, true
		}
	case .Bool:
		if value.kind == .Boolean {
			return value, true
		}
	case .Enum:
		// Retyping a constant must never manufacture a non-variant. Source-type
		// checks at conversion and generic-binding sites enforce enum identity.
		return value, value.kind == .Integer && enum_member_by_value(c, target, value) != INVALID_SYMBOL
	case .Int:
		bits, signed := type_bits(c, target), type_signed(c, target)
		#partial switch value.kind {
		case .Integer, .Rune:
			if !bi_fits(storage, value.integer, bits, signed) {
				return value, false
			}
			return Const_Value{kind = .Integer, integer = value.integer}, true
		case .Float:
			// The interval the runtime conversion checks (design.md "Type
			// conversion"); NaN and infinities fail it.
			limit := power_of_two(int(bits) - (signed ? 1 : 0))
			if !(value.float >= (signed ? -limit : 0) && value.float < limit) {
				return value, false
			}
			truncated, exact, ok := bi_from_f64_trunc(storage, value.float)
			if !ok || (!explicit && !exact) {
				return value, false
			}
			if !bi_fits(storage, truncated, bits, signed) {
				return value, false
			}
			return Const_Value{kind = .Integer, integer = truncated}, true
		}
	case .Rune:
		#partial switch value.kind {
		case .Integer, .Rune:
			if !bi_fits(storage, value.integer, 32, true) {
				return value, false
			}
			return Const_Value{kind = .Rune, integer = value.integer}, true
		}
	case .Float:
		#partial switch value.kind {
		case .Float:
			// Kept as is, so a signalling NaN is not quieted.
			if value.float_bits == info.bits {
				return value, true
			}
			// design.md "Number literals": a finite constant may not round to an
			// infinity.
			converted := float_const(value.float, info.bits)
			return converted, !math.is_inf(converted.float) || math.is_inf(value.float)
		case .Integer, .Rune:
			converted, fits := bi_to_float(storage, value.integer, info.bits)
			return fits ? float_const(converted, info.bits) : value, fits
		}
	case .Typeid:
		if value.kind == .Nil {
			return type_const(INVALID_TYPE), true
		}
		// A folded `typeid_of(T)` keeps the type it identifies; the value's own
		// type, checked before this, is what separates it from a type.
		if value.kind == .Type {
			return value, true
		}
	case .Pointer, .C_Pointer, .Raw_Pointer, .Proc, .Allocator, .Allocator_Error:
		if value.kind == .Nil {
			return nil_const(), true
		}
	case .Union, .Dyn, .Any_View, .Slice:
		// Every other value of these is built at run time.
		if value.kind == .Nil {
			return nil_const(), true
		}
	case .Simd:
		// design.md "SIMD vectors": each lane converts as a scalar would, and a
		// scalar splats into every lane.
		if value.kind == .Aggregate {
			if value.aggregate == nil || len(value.aggregate.elements) != int(info.count) {
				return value, false
			}
			if value.aggregate.type == target {
				return value, true
			}
		}
		elements := make([]Const_Value, info.count, storage)
		for index in 0 ..< int(info.count) {
			lane := value
			if value.kind == .Aggregate {
				lane = value.aggregate.elements[index]
			}
			converted, fits := convert_const(c, lane, info.element, explicit, allocator)
			if !fits {
				return value, false
			}
			elements[index] = converted
		}
		aggregate := new(Const_Aggregate, storage)
		aggregate.type = target
		aggregate.elements = elements
		return Const_Value{kind = .Aggregate, aggregate = aggregate}, true
	case .Struct, .Array:
		// design.md "Shared ownership": a handle's zero value is `nil`.
		if value.kind == .Nil && type_is_shared_handle(c, target) {
			return zero_const(c, target)
		}
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
		#partial switch underlying_kind(c, to) {
		// design.md "Zero values"; a nil `Allocator_Error` is success.
		case .Pointer, .C_Pointer, .Raw_Pointer, .Proc, .Union, .Dyn, .Any_View, .Slice, .Typeid,
		     .String_View, .CString_View, .Allocator, .Allocator_Error:
			return true
		}
		return type_is_shared_handle(c, to)
	}
	// design.md "SIMD vectors": a scalar splats; nothing else converts.
	if type_is_simd(c, to) && !type_is_simd(c, from) {
		element := type_of(c, type_underlying(c, to)).element
		return from == element || assignable(c, from, element)
	}
	if carrier_weakens_to(c, from, to) {
		return true
	}
	// design.md "Escape levels".
	if proc_escape_weakens_to(c, from, to) {
		return true
	}
	// Above the untyped cases: a constant reaches `any_view` at its default type.
	if to == TYPE_ANY_VIEW && any_view_accepts(c, from) {
		return true
	}
	if from == TYPE_UNTYPED_STRING {
		#partial switch underlying_kind(c, to) {
		case .String, .String_View, .CString_View:
			return true
		}
		return false
	}
	if underlying_kind(c, from) == .String &&
	   underlying_kind(c, to) == .String_View {
		return true
	}
	if dynamic_views_as(c, from, to) {
		return true
	}
	if type_is_untyped(c, from) {
		#partial switch underlying_kind(c, to) {
		case .Int, .Float, .Rune, .Bool:
			return true
		}
		return false
	}
	if to == TYPE_RAWPTR {
		#partial switch underlying_kind(c, from) {
		case .Pointer, .C_Pointer:
			return true
		}
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
	// Two distinct types convert only through `hook(convert)`.
	if type_kind(c, from) == .Distinct && type_kind(c, to) == .Distinct && from != to {
		return false
	}
	if source == dest {
		return true // between a distinct type and what it wraps, either way
	}
	source_kind, dest_kind := type_kind(c, source), type_kind(c, dest)
	if dest_kind == .Enum {
		return false // only an existing value of the same enum may convert
	}

	// design.md "SIMD vectors": lane-wise, with the same lane count.
	if source_kind == .Simd || dest_kind == .Simd {
		if source_kind != .Simd || dest_kind != .Simd {
			return false // the scalar splat is the assignable path above
		}
		source_info, dest_info := type_of(c, source), type_of(c, dest)
		if source_info.count != dest_info.count {
			return false
		}
		return convertible(c, source_info.element, dest_info.element)
	}

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
		case .Pointer, .C_Pointer, .Raw_Pointer:
			return true
		}
		return false
	}
	if pointerish(source_kind) && pointerish(dest_kind) {
		// `^T` never converts directly to `^mut T`.
		if source_kind == .Pointer && dest_kind == .Pointer {
			source_info := type_of(c, source)
			dest_info := type_of(c, dest)
			if source_info != nil && dest_info != nil && !source_info.mutable && dest_info.mutable {
				return false
			}
		}
		return true
	}
	return false
}

// design.md "The `unsafe` package": a conversion that gives an unchecked
// address, or another pointee, a checked shape. Losing provenance (anything to
// `rawptr`, a `^T` to `[^]T`) and weakening `^mut T` to `^T` are not.
unchecked_pointer_conversion :: proc(c: ^Compiler, from, to: Type_Id) -> bool {
	source, dest := type_underlying(c, from), type_underlying(c, to)
	if source == dest {
		return false
	}
	#partial switch type_kind(c, dest) {
	case .Pointer:
		#partial switch type_kind(c, source) {
		case .Raw_Pointer, .C_Pointer:
			return true
		case .Pointer:
			return type_of(c, source).element != type_of(c, dest).element
		}
	case .C_Pointer:
		#partial switch type_kind(c, source) {
		case .Raw_Pointer, .C_Pointer:
			return true
		}
	}
	return false
}

// design.md "The `unsafe` package": the file's `core:unsafe` import is what
// marks it for review. `base:` packages are the language's own runtime, which
// cannot import `core:`; a span in no source file is compiler-synthesized.
require_unsafe_import :: proc(k: ^Checker, span: Span, what: string) -> bool {
	for &pkg in k.c.packages {
		for f in pkg.files {
			if f.file != span.file {
				continue
			}
			if strings.has_prefix(pkg.key, "base:") {
				return true
			}
			for edge in pkg.imports {
				if target := package_of(k.c, edge.target); edge.span.file == span.file && target != nil && target.key == STD_UNSAFE {
					return true
				}
			}
			errorf(k.c, span, "L0706", "%s is unchecked, so this file must import `core:unsafe`", what)
			return false
		}
	}
	return true
}

// Value-level folding lives in `const_ops.odin`, so the interpreter in
// `eval.odin` runs the same operator table rather than a second copy.

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
	info := underlying_info(c, type)
	if info == nil || info.kind != .Pointer {
		return INVALID_TYPE
	}
	return info.element
}

struct_field :: proc(c: ^Compiler, type: Type_Id, name: Identifier_Id) -> Symbol_Id {
	info := underlying_info(c, type)
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

is_const_expr :: proc(e: Expr) -> bool {
	base := expr_base(e)
	return base != nil && base.is_const
}

const_value_of :: proc(e: Expr) -> Const_Value {
	base := expr_base(e)
	return base == nil ? Const_Value{} : base.const_value
}

operator_text :: proc(op: Token_Kind) -> string {
	if op == .In {
		return "in"
	}
	text := operator_spelling(op)
	return text != "" ? text : "?"
}

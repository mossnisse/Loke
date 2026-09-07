// Expressions, conversions, and constant folding.
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
		// A place position reaches through a field chain to the index that roots
		// it, but only the whole-element `m[key] = elem` creates an entry: writing
		// `m["Dana"].x` names a field of an element that must already be there
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
		check_or_else(k, v, expected)

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
			// The same answer a written type position gets: a composed type names the
			// component that failed, and only a shape nothing accounts for falls
			// through to the milestone guard inside.
			report_unresolved_type(k, e)
			base.type = INVALID_TYPE
		}
	}
	return base.type
}

// One value, exactly. design.md: every value-producing expression produces one
// value, so what is left here is the no-value case — a call to a procedure with
// no result, used where a value is wanted.
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

// Checks an expression against a destination type and materialises it there.
// This is the single seam every assignment, argument, initialiser, and return
// value goes through.
check_value_expr :: proc(k: ^Checker, e: Expr, target: Type_Id, what: string) -> bool {
	type := check_single_expr(k, e, target)
	if type == INVALID_TYPE || target == INVALID_TYPE {
		return false
	}
	return materialize_value_expr(k, e, target, what)
}

// Finishes a value expression that has already been checked. Overload selection
// sometimes needs its source type before it can decide whether the built-in or
// user path owns the operation; checking it again would duplicate side effects
// in the checker and diagnostics.
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
		text, ok := decode_string_literal(k.c, v.text, v.kind == .Raw_String)
		if !ok {
			errorf(k.c, v.span, "L0351", "`%s` is not a valid string literal", v.text)
			v.type = INVALID_TYPE
			return
		}
		// Compile-time only: `TYPE_STRING` stays gated, so this value can be
		// concatenated, compared, measured, and used as a message or a
		// configuration value, but never stored.
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
	case '0' ..= '7':
		return digits(s, 2, 8) // `\NNN`, three octal digits including this one
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

	// A nested procedure literal has no closure in M2, so a name that lives in
	// an enclosing procedure's frame is rejected here rather than silently
	// miscompiled.
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

	// A constant, or a file-scope variable a `when` condition or an earlier
	// declaration reached before the ordinary phase order would: both are
	// checked on demand so a forward reference sees a real type.
	if sym.decl != nil && (sym.kind == .Const || (sym.kind == .Var && sym.decl.top_level)) {
		switch sym.decl.check_state {
		case .Unchecked:
			check_symbol_decl_in_place(k, symbol_id)
			sym = symbol_of(k.c, symbol_id)
		case .Checking:
			errorf(k.c, v.span, "L0324", "constant initialisation cycle involving `%s`", v.name)
			v.type = INVALID_TYPE
			return
		case .Checked:
		}
	}

	annotate_symbol_use(k, &v.base, symbol_id, v.name)
}

// Writes what a resolved symbol means onto the node that named it. Shared by a
// plain identifier and by `package.name`, so a qualified use cannot drift from
// an unqualified one.
@(private = "file")
annotate_symbol_use :: proc(k: ^Checker, v: ^Expr_Base, symbol_id: Symbol_Id, name: string) {
	sym := symbol_of(k.c, symbol_id)
	if sym == nil {
		v.type = INVALID_TYPE
		return
	}
	// design.md "Generics": a generic declaration has no runtime representation
	// before instantiation, so it is neither a value nor a type on its own.
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
		// A named procedure is a value with its interned procedure type; a call
		// obtains its results from the type, not from a single result field.
		// A signature the current phase has not reached yet is resolved on
		// demand, so an enum value or array length may call a procedure declared
		// later in the file.
		if sym.proc_type == INVALID_TYPE && sym.decl != nil {
			resolve_symbol_signature_in_place(k, symbol_id)
			sym = symbol_of(k.c, symbol_id)
		}
		v.resolution = Resolution{kind = .Value, symbol = symbol_id}
		v.value_category = .Value
		v.type = sym.proc_type
		// design.md "`@(deprecated=<string>)`": a warning at each use — a call or a
		// value use both resolve the name here.
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
		// design.md "Type alias": `Alias :: Box` gives another name to the type,
		// and a constant whose value *is* a type is that alias. It has to behave
		// as the type everywhere the type does — conversion, associated members,
		// enum members — not only where `resolve_type_syntax` reaches it.
		if sym.const_value.kind == .Type {
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
		v.immutable = sym.immutable ? .Value_Parameter : .None

	case .Field:
		v.resolution = Resolution{kind = .Field, symbol = symbol_id}
		v.type = sym.type

	case .Package_Alias:
		errorf(k.c, v.span, "L0334", "`%s` names a package; write `%s.name` to use one of its declarations", name, name)
		v.type = INVALID_TYPE

	case .Proc_Group:
		// A group names several procedures, so it has no one procedure type to be
		// a value of; call it, or name the member you meant.
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
			if type_is_union(k.c, enum_type) {
				errorf(k.c, v.span, "L0425", "`%s` has no variant `%s`", type_name(k.c, expected), v.name.text)
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

	// Package resolution comes before enum, type, and value field selection: a
	// package alias is not a value, so checking the operand as one would reject
	// it first.
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
	if operand_base.value_category == .Type &&
	   check_union_variant_selector(k, v, operand_base.denoted_type) {
		if v.resolution.kind == .Union_Variant && !callee_position {
			reject_incomplete_variant(k, v)
			v.type = INVALID_TYPE
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
		// A receiver is a context that needs a type, so an unfixed constant takes
		// its default one here exactly as it does in an argument (design.md
		// "Unfixed constants"). This is what lets `TEXT.len()` select `string`'s
		// member; the fold keeps the result constant.
		if type_is_untyped(k.c, operand) {
			materialized := default_type(k.c, operand)
			if materialized != operand && materialized != INVALID_TYPE {
				materialize(k, v.operand, materialized)
				if select_method(k, v, materialized, callee_position) {
					return
				}
			}
		}
		errorf(k.c, v.span, "L0363", "`%s` has no field or member `%s`", type_name(k.c, operand), v.name.text)
		v.type = INVALID_TYPE
		return
	}
	// Field lookup already won over method sugar, so an inaccessible field is
	// reported as itself rather than falling through to a same-named method.
	if !require_visible_field(k, v.span, operand, field, "L0471", "used") {
		v.type = INVALID_TYPE
		return
	}
	sym := symbol_of(k.c, field)
	v.resolution = Resolution{kind = .Field, symbol = field}
	v.type = sym.type
	v.value_category = .Place
	if through_pointer {
		v.addressable = true
		v.assignable = pointer_mutable
		v.immutable = pointer_mutable ? .None : .Through_Pointer
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

// Method syntax through a pointer uses the same implicit dereference as field
// selection. Materialising that adjustment in the typed AST lets overload
// binding, provenance, and emission all see the real receiver place, including
// the read-only capability that rejects an `inout self` method with L0640.
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
	// A member's own signature or value may be needed before the phase that
	// would ordinarily reach it, and both need the block's subject *and its own
	// declaration scope*: inside an instantiated block that scope is what binds
	// the block's generic arguments.
	outer := k.impl_type
	k.impl_type = subject
	defer k.impl_type = outer
	if sym := symbol_of(k.c, member); sym != nil && sym.kind == .Const && sym.decl != nil {
		if sym.decl.check_state == .Unchecked {
			check_member_decl_in_place(k, member, subject)
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

// The members of `receiver` named `name` that method-call syntax can reach: an
// associated procedure without a receiver is not one of them.
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

// Whether `move(...)` is the only spelling that can reach any of these. An
// overload group mixing consuming and borrowing receivers has no such advice to
// give: the written form simply selects between them.
@(private = "file")
all_candidates_consume :: proc(k: ^Checker, candidates: []Symbol_Id) -> bool {
	for candidate in candidates {
		if sym := symbol_of(k.c, candidate); sym == nil || sym.receiver != .Move {
			return false
		}
	}
	return len(candidates) > 0
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
	// A cross-package constant or global may be reached before its own package's
	// phase 3; check it on demand so the use sees a real value.
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
	// A chain such as `outer[key][i] = v` inserts into the innermost map only:
	// `outer[key]` names an element that must already be there, and the operand
	// of any index is checked as one (design.md "Maps").
	inserts := place && k.insert_position
	k.place_position, k.insert_position = place, false
	operand := check_single_expr(k, v.operand)
	k.place_position = false
	if operand == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}

	base_type := type_underlying(k.c, operand)
	operand_base := expr_base(v.operand)
	through_pointer := false
	pointer_mutable := false
	if info := type_of(k.c, base_type); info != nil && info.kind == .Pointer {
		base_type = type_underlying(k.c, info.element)
		through_pointer = true
		pointer_mutable = info.mutable
	}
	info := type_of(k.c, base_type)
	// A C pointer indexes without bounds checking (design.md "C pointers").
	// The loss of the bound is the whole point of the type, and it is visible at
	// the `unsafe.raw_data` call that produced the C pointer.
	if info != nil && info.kind == .C_Pointer && len(v.indices) == 1 {
		check_c_pointer_index(k, v, info)
		return
	}
	// A string cannot be indexed by an integer, because a UTF-8 code point may
	// span multiple bytes (design.md "string type").
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
	// Indexing and slicing a dynamic array produce views into its current
	// allocation (design.md "Dynamic arrays"). A dynamic array's element is an
	// ordinary mutable place whose bound is the header's length word, exactly
	// as a `[]mut T`'s is.
	if info != nil && info.kind == .Dynamic_Array && len(v.indices) == 1 {
		check_dynamic_index(k, v, info)
		return
	}
	if info != nil && info.kind == .Map && len(v.indices) == 1 {
		check_map_index(k, v, info, place, inserts)
		return
	}
	// design.md "SIMD vectors": "`v[i]` reads a lane and `v[i] = x` writes one.
	// **The index must be a constant**". Answered before the shared array path
	// because that path permits a runtime index and a vector does not.
	if info != nil && info.kind == .Simd && len(v.indices) == 1 {
		check_simd_index(k, v, info, base_type, through_pointer, pointer_mutable)
		return
	}
	// Built-in indexing first; a user `operator([])` supplies what it does not.
	indexable := info != nil && (info.kind == .Array || info.kind == .Slice)
	if !indexable || len(v.indices) != 1 {
		if check_user_index(k, v, operand, place) {
			return
		}
		if indexable {
			// The comma form is reserved for a user-defined `operator([])` taking
			// that many indices, and is a compile-time error on a built-in container
			// (design.md "Indexing and slicing") — permanently, not pending a
			// milestone.
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

	// A slice's length is a runtime value, so nothing here folds and the bound is
	// checked at run time against the length word.
	if info.kind == .Slice {
		check_slice_index(k, v, info, operand)
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
		v.assignable = pointer_mutable
		v.immutable = pointer_mutable ? .None : .Through_Pointer
	} else {
		v.addressable = operand_base.addressable
		v.assignable = operand_base.assignable
		v.immutable = operand_base.immutable
	}

	index_base := expr_base(v.indices[0])
	// design.md "Materialization": a constant indexed by a non-constant index
	// needs storage, and that storage is read-only. A constant index still folds
	// below and asks for none.
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

// `s[i]` over a slice. The element is a place in the *root's* storage, so its
// capability comes from the slice's, not from whether the slice variable itself
// is assignable: rebinding `s` and writing `s[0]` are different rights.
@(private = "file")
check_c_pointer_index :: proc(k: ^Checker, v: ^Expr_Index, info: ^Type_Info) {
	if index_type := check_single_expr(k, v.indices[0], TYPE_INT); index_type != INVALID_TYPE {
		materialize(k, v.indices[0], TYPE_INT)
		if !type_is_integer(k.c, expr_base(v.indices[0]).type) {
			errorf(k.c, expr_span(v.indices[0]), "L0362", "an index must be an integer, found `%s`", type_name(k.c, index_type))
		}
	}
	v.type = info.element
	// The element is a place through the address, exactly as `p^` is: a
	// C pointer carries no read-only capability either.
	v.value_category = .Place
	v.addressable = true
	v.assignable = true
}

@(private = "file")
check_slice_index :: proc(k: ^Checker, v: ^Expr_Index, info: ^Type_Info, operand: Type_Id) {
	index_type := check_single_expr(k, v.indices[0], TYPE_INT)
	if index_type != INVALID_TYPE {
		materialize(k, v.indices[0], TYPE_INT)
		if !type_is_integer(k.c, expr_base(v.indices[0]).type) {
			errorf(k.c, expr_span(v.indices[0]), "L0362", "an index must be an integer, found `%s`", type_name(k.c, index_type))
		}
	}
	v.type = info.element
	v.value_category = .Place
	// Element assignment and iteration by reference both require `[]mut T`
	// (design.md). A `[]T` element is a readable place: `&` reaches it and yields
	// a `^T`, while `&mut` and assignment do not.
	v.addressable = true
	v.assignable = info.mutable
	v.immutable = info.mutable ? .None : .Read_Only
}

// A dynamic array's element place. The bound is a runtime word, so nothing here
// folds; the capability is unconditional, because a `[dynamic]T` is an owner
// rather than a borrow and its owner may always write through it.
@(private = "file")
check_dynamic_index :: proc(k: ^Checker, v: ^Expr_Index, info: ^Type_Info) {
	index_type := check_single_expr(k, v.indices[0], TYPE_INT)
	if index_type != INVALID_TYPE {
		materialize(k, v.indices[0], TYPE_INT)
		if !type_is_integer(k.c, expr_base(v.indices[0]).type) {
			errorf(
				k.c, expr_span(v.indices[0]), "L0362",
				"an index must be an integer, found `%s`", type_name(k.c, index_type),
			)
		}
	}
	v.type = info.element
	v.value_category = .Place
	v.addressable = true
	v.assignable = true
	v.immutable = .None
}

// `ok := key in m` is true iff the key has an element (design.md "Maps"). It
// never inserts and never produces the value, so it is the cheapest of the
// three membership forms.
@(private = "file")
check_map_membership :: proc(k: ^Checker, v: ^Expr_Binary) {
	container := check_single_expr(k, v.rhs)
	if container == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}
	if !type_is_map(k.c, container) {
		errorf(
			k.c, v.op_span, "L0587",
			"`in` tests a `map[K]V` for a key, found `%s`", type_name(k.c, container),
		)
		v.type = INVALID_TYPE
		return
	}
	if !check_value_expr(k, v.lhs, container_key(k.c, container), "look up") {
		v.type = INVALID_TYPE
		return
	}
	v.type = TYPE_BOOL
}

// design.md "Maps": one syntax, two behaviours chosen by position.
//
// `m[key] = elem` is the one index form that creates an entry, and it can: the
// whole element is written, so nothing is manufactured. Every other position —
// a read, a field or index chain, a compound assignment, an `inout` argument,
// and `&m[key]` — names a location inside an element that must already be
// there, and panics for a missing key exactly as a dynamic array's index does.
//
// Insertion may reallocate the map, so an inserting index is a mutable borrow
// of `m` for the duration of the statement — which is what the receiver access
// recorded by `src/cfg.odin` makes true.
@(private = "file")
check_map_index :: proc(k: ^Checker, v: ^Expr_Index, info: ^Type_Info, place, inserts: bool) {
	if !check_value_expr(k, v.indices[0], info.key, "look up") {
		v.type = INVALID_TYPE
		return
	}
	v.map_inserts = inserts
	v.type = info.element
	// Indexing exposes synthesized reads and insertion for both managed halves,
	// just as a map literal does, even when the RHS transfers a temporary.
	contribute_lifecycle_members(k, info.key)
	contribute_lifecycle_members(k, info.element)
	if place {
		// A stored element is addressable, but keeps the capability of the map
		// through which it was reached, including an immutable receiver.
		v.value_category = .Place
		v.addressable = true
		v.assignable = expr_base(v.operand).assignable
		v.immutable = expr_base(v.operand).immutable
		if inserts && !expr_base(v.operand).assignable {
			report_not_assignable(k, expr_base(v.operand), "an inserting map index")
			v.type = INVALID_TYPE
		}
		return
	}
	// A read produces a value: `m.lookup_value(key)` is the form that answers
	// `Option(V)` instead of panicking, and `m.find(key)` the one that answers a
	// pointer.
	v.value_category = .Value
	v.addressable = false
	v.assignable = false
}

// design.md "Indexing and slicing": in a place position the `inout` overload is
// required and selected before ordinary ranking; everywhere else the value
// overload is preferred, even when the receiver is mutable. Without this rule
// the two would differ only by receiver mutability and return mode, which rank 2
// would treat as an adjustment rather than a distinction.
@(private = "file")
check_user_index :: proc(k: ^Checker, v: ^Expr_Index, operand: Type_Id, place: bool) -> bool {
	all := operator_candidates_for_receiver(k, "[]", operand)
	if len(all) == 0 {
		return false
	}
	candidates := select_by_place(k, all, place)
	if len(candidates) == 0 {
		// design.md: `operator([]=)` can serve an assignment — which `check_assign`
		// has already tried by the time this runs — but never an address.
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

// `operator([:])`. A built-in carrier slices on its own; every other type needs
// the overload, and a type without one simply cannot be sliced.
@(private = "file")
check_slice :: proc(k: ^Checker, v: ^Expr_Slice, place: bool) {
	v.value_category = .Value
	operand := check_single_expr(k, v.operand)
	if operand == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}
	// A built-in carrier slices without consulting user operators; `operator([:])`
	// exists for user types (design.md "Slices").
	if check_builtin_slice(k, v, operand) {
		return
	}
	slicers := operator_candidates_for_receiver(k, "[:]", operand)
	if len(slicers) == 0 {
		// design.md "Indexing and slicing": slicing a user type is an
		// `operator([:])` overload and nothing else, so its absence is a permanent
		// answer rather than a pending milestone.
		errorf(
			k.c, v.span, "L0362",
			"`%s` cannot be sliced; a user type needs an `operator([:])` overload",
			type_name(k.c, operand),
		)
		v.type = INVALID_TYPE
		return
	}
	if v.lo == nil || v.hi == nil {
		errorf(k.c, v.span, "L0421", "a user `operator([:])` needs both endpoints written")
		v.type = INVALID_TYPE
		return
	}
	endpoints := make([]Expr, 2, k.c.semantic_allocator)
	endpoints[0], endpoints[1] = v.lo, v.hi
	args, ok := index_arguments(k, v.operand, endpoints)
	if !ok {
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
	// design.md "Capabilities and the one rule": a mutable borrow excludes
	// competing access, so a `[]mut T` result can only come from a receiver the
	// call already holds exclusively. An immutable receiver may produce `[]T`.
	if type_is_slice(k.c, v.type) && slice_is_mutable(k.c, v.type) && sym.receiver != .Inout {
		errorf(
			k.c,
			v.span,
			"L0547",
			"this `operator([:])` yields `%s`, which is an exclusive borrow, so its `self` parameter must be `inout`",
			type_name(k.c, v.type),
		)
		add_notef(k.c, sym.span, "declared here with an immutable receiver, which can only yield a read-only slice")
		v.type = INVALID_TYPE
	}
}

// Slicing a built-in sequence: a fixed array or another slice. Returns false
// when the operand is neither, leaving the user `operator([:])` path to run.
//
// Slicing a mutable, addressable array or dynamic array produces `[]mut T`;
// slicing an immutable parameter, a string, or an existing `[]T` produces
// `[]T` (design.md "Slices"). Endpoints may be omitted; the low bound
// defaults to 0 and the high bound to the base's length.
@(private = "file")
check_builtin_slice :: proc(k: ^Checker, v: ^Expr_Slice, operand: Type_Id) -> bool {
	info := underlying_info(k.c, operand)
	if info == nil {
		return false
	}
	element := INVALID_TYPE
	mutable := false
	materialized := false
	base := expr_base(v.operand)
	#partial switch info.kind {
	case .Array:
		element = info.element
		// A constant array has no storage until it is materialised, and that
		// storage is read-only, so a slice of it is always `[]T` and needs no
		// addressable root of its own.
		materialized = base.is_const && request_materialization(k, v.operand)
		mutable = !materialized && base.addressable && base.immutable == .None
	case .Slice:
		element = info.element
		mutable = info.mutable
	case .Dynamic_Array:
		// Indexing and slicing a dynamic array produce views into its current
		// allocation (design.md "Dynamic arrays"). A container is an owner, so the
		// view it hands out is mutable whenever the place it is taken from can be
		// written.
		element = info.element
		mutable = base.assignable
	case .String, .String_View:
		// design.md "From string to X": `st[low:high]` borrows a subrange as a
		// `string_view`. It is a borrow of the string's owner and cannot outlive
		// it, which `src/borrow.odin` checks.
		return check_text_subrange(k, v)
	case .C_Pointer:
		// design.md "C pointers": `x[:]` and `x[i:]` stay C pointers,
		// while `x[:n]` and `x[i:n]` produce a bounds-carrying `[]T`.
		return check_c_pointer_slice(k, v, info.element)
	case:
		return false
	}

	ok := true
	if v.lo != nil && !check_slice_endpoint(k, v.lo) {
		ok = false
	}
	if v.hi != nil && !check_slice_endpoint(k, v.hi) {
		ok = false
	}
	// A fixed array must be addressable to be sliced: the slice needs its root
	// address, and a temporary's would not outlive the expression. A materialised
	// constant has static storage instead, so it is exempt.
	if info.kind == .Array && !materialized && !base.addressable {
		errorf(k.c, v.span, "L0477", "`%s` has no storage to slice; bind it to a variable first", type_name(k.c, operand))
		ok = false
	}
	if !ok {
		v.type = INVALID_TYPE
		return true
	}
	v.type = slice_of(k.c, element, mutable)
	v.value_category = .Value
	v.immutable = .Temporary
	return true
}

// `st[low:high]` produces a subrange view (design.md). A byte range that splits
// a code point would break the type's UTF-8 invariant, so the bounds are
// checked at run time against both the length and the encoding.
@(private = "file")
check_text_subrange :: proc(k: ^Checker, v: ^Expr_Slice) -> bool {
	ok := true
	if v.lo != nil && !check_slice_endpoint(k, v.lo) {
		ok = false
	}
	if v.hi != nil && !check_slice_endpoint(k, v.hi) {
		ok = false
	}
	v.type = ok ? TYPE_STRING_VIEW : INVALID_TYPE
	v.value_category = .Value
	v.immutable = .Temporary
	return true
}

// C pointer slicing is bounds-checked exactly when both endpoints are
// given (design.md "C pointers") — which is exactly the case whose result
// carries a length.
@(private = "file")
check_c_pointer_slice :: proc(k: ^Checker, v: ^Expr_Slice, element: Type_Id) -> bool {
	ok := true
	if v.lo != nil && !check_slice_endpoint(k, v.lo) {
		ok = false
	}
	if v.hi != nil && !check_slice_endpoint(k, v.hi) {
		ok = false
	}
	if !ok {
		v.type = INVALID_TYPE
		return true
	}
	// A C pointer has no length, so an omitted high bound cannot produce one:
	// the result stays a C pointer and the loss of bounds stays visible.
	v.type = v.hi == nil ? c_pointer_to(k.c, element) : slice_of(k.c, element, mutable = true)
	v.value_category = .Value
	v.immutable = .Temporary
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

// The overloads a place or value position may use. In a value position the
// non-`inout` overloads are preferred but an `inout` one still serves when it is
// all there is.
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
	args[0] = arg_from_expr(k, receiver)
	args[0].is_receiver = true
	ok := true
	for index, position in indices {
		expected := agreed_index_param(k, candidates, position, len(indices))
		if check_single_expr(k, index, expected) == INVALID_TYPE {
			ok = false
			continue
		}
		args[position + 1] = arg_from_expr(k, index)
	}
	return args, ok
}

// An implicit selector — `counts[.North]` — needs its enum type from context,
// and a user `operator([])` receiver cannot supply one the way a `map[E]V` key
// does, because the index type is not known until an overload is chosen. Where
// every applicable overload declares one and the same type for this index, that
// type is settled before ranking and serves as the expectation; where they
// disagree there is nothing to expect and the ordinary diagnostic stands.
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

// design.md "@(packed)": whether a place expression is a field reached through a
// packed struct at any level of its selector chain, and the field name to name in
// the diagnostic. The whole packed value is fine; only a field of it is rejected.
@(private)
packed_field_reached :: proc(k: ^Checker, operand: Expr) -> (string, bool) {
	cur := operand
	for {
		sel, ok := cur.(^Expr_Selector)
		if !ok || sel.operand == nil {
			return "", false
		}
		base := expr_base(sel.operand)
		if base != nil {
			struct_type := type_underlying(k.c, base.type)
			if info := type_of(k.c, struct_type); info != nil && info.kind == .Pointer {
				struct_type = type_underlying(k.c, info.element)
			}
			if info := type_of(k.c, struct_type); info != nil && info.kind == .Struct && info.packed {
				return sel.name.text, true
			}
		}
		cur = sel.operand
	}
}

@(private = "file")
check_unary :: proc(k: ^Checker, v: ^Expr_Unary, expected: Type_Id) {
	v.value_category = .Value

	if v.op == .Amp {
		// design.md: `&` is a place position for the purpose of overload
		// selection, but it never creates an element in any container.
		saved_insert := k.insert_position
		k.place_position, k.insert_position = true, false
		operand := check_single_expr(k, v.operand, pointee_of(k.c, expected))
		k.place_position, k.insert_position = false, saved_insert
		if operand == INVALID_TYPE {
			v.type = INVALID_TYPE
			return
		}
		operand_base := expr_base(v.operand)
		// design.md "Materialization": a place rooted in a named constant has an
		// address once the shared read-only object is registered. Marked here for
		// `&mut` too, so that form is rejected as a constant rather than as
		// something with no address at all.
		if !operand_base.addressable {
			if root, symbol := constant_root_of(k.c, v.operand); symbol != INVALID_SYMBOL {
				if request_materialization(k, root) {
					operand_base.addressable = true
				}
			}
		}
		if !operand_base.addressable {
			errorf(k.c, v.op_span, "L0357", "`%s` needs an addressable operand", v.mutable ? "&mut" : "&")
			v.type = INVALID_TYPE
			return
		}
		// `&` borrows readable storage; `&mut` needs storage this body may write.
		// The distinction is the whole point of the capability: a value parameter,
		// a `[]T` element, and a materialized constant are all readable places
		// that no `^mut T` may reach (design.md "Capabilities and the one rule").
		if v.mutable && !operand_base.assignable {
			report_not_assignable(k, operand_base, "borrowed with `&mut`")
			v.type = INVALID_TYPE
			return
		}
		// An individual packed field is not addressable (design.md "@(packed)") —
		// the base address of a packed value need not meet a field's alignment.
		// The whole value's address stays valid.
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
	// A built-in operation on built-in operands cannot be shadowed; where the
	// language defines none, an ordinary user overload is found by lookup.
	if !builtin_unary_defined(k, v.op, operand) {
		if check_user_unary(k, v, operand, expected) {
			return
		}
	}
	if type_is_simd(k.c, operand) {
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
		folded.integer = wrap_to_type(k.c, folded.integer, v.type)
	}
	v.is_const = true
	v.const_value = folded
}

@(private = "file")
check_user_unary :: proc(k: ^Checker, v: ^Expr_Unary, operand: Type_Id, expected: Type_Id) -> bool {
	symbol := operator_text(v.op)
	operands := []Type_Id{operand}
	if !operator_exists(k, symbol, operands) {
		return false
	}
	args := make([]Arg_Info, 1, k.c.semantic_allocator)
	args[0] = arg_from_expr(k, v.operand)
	chosen, bound := resolve_operator(k, v.op_span, symbol, operands, args, expected)
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
check_user_binary :: proc(k: ^Checker, v: ^Expr_Binary, lhs, rhs: Type_Id, expected: Type_Id) -> bool {
	symbol := operator_text(v.op)
	operands := []Type_Id{lhs, rhs}
	args := make([]Arg_Info, 2, k.c.semantic_allocator)
	args[0] = arg_from_expr(k, v.lhs)
	args[1] = arg_from_expr(k, v.rhs)
	negate := false
	if !operator_viable(k, symbol, operands, args) {
		if v.op != .Not_Eq || !operator_viable(k, "==", operands, args) {
			if operator_exists(k, symbol, operands) {
				resolve_operator(k, v.op_span, symbol, operands, args, expected)
				v.type = INVALID_TYPE
				return true
			}
			return false
		}
		symbol = "=="
		negate = true
	}
	chosen, bound := resolve_operator(k, v.op_span, symbol, operands, args, negate ? TYPE_BOOL : expected)
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
	v.type = info.element
	v.value_category = .Place
	// Dereferencing either capability yields a real place with an address. Only
	// `^mut T` yields one this body may write (design.md "Capabilities and the
	// one rule").
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
	// A comparison operand written as a bare `.Member` takes its expected enum
	// type from the other operand, which is how `when (LOKE_OS == .Windows)`
	// resolves the selector (design.md "Build configuration").
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

	// design.md "SIMD vectors": lane-wise, with its own operator table and its
	// own answer for a comparison, so it is settled before the scalar table.
	if type_is_simd(k.c, lhs) || type_is_simd(k.c, rhs) {
		check_simd_binary(k, v, lhs, rhs)
		return
	}
	// The built-in operation wins whenever every operand is a built-in type and
	// the built-in table defines this operator for them.
	if !builtin_binary_defined(k, v.op, lhs, rhs) {
		if check_user_binary(k, v, lhs, rhs, expected) {
			return
		}
	}
	if shift {
		check_shift(k, v, expected, lhs, rhs)
		return
	}

	// Asked before unification, because materialising an untyped nil against the
	// other side is exactly what would hide which operand was written as `nil`.
	nil_only := is_comparison && (type_is_slice(k.c, lhs) || type_is_slice(k.c, rhs))
	against_nil := lhs == TYPE_UNTYPED_NIL || rhs == TYPE_UNTYPED_NIL

	operand_type, unified := unify_operands(k, v.lhs, v.rhs, v.op_span)
	if !unified {
		v.type = INVALID_TYPE
		return
	}

	if is_comparison {
		// Slices can be compared only against nil, never against each other
		// (design.md "Nil slices"). Two slices may share a root, overlap, or view
		// the same bytes at different lengths, so element-wise equality would not
		// mean what `==` means anywhere else.
		if nil_only && !against_nil {
			errorf(
				k.c,
				v.op_span,
				"L0476",
				"`%s` compares against `nil` and nothing else",
				type_name(k.c, type_is_slice(k.c, lhs) ? lhs : rhs),
			)
			v.type = INVALID_TYPE
			return
		}
		check_comparison(k, v, operand_type)
		return
	}

	if !builtin_operator_applies(k.c, v.op, operand_type) {
		operator_mismatch2(k, v.op_span, v.op, lhs, rhs)
		v.type = INVALID_TYPE
		return
	}
	v.type = operand_type
	// `a + b` on two `string` operands returns a new owning `string`; two
	// `string_view` operands also produce an owning `string` (design.md).
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
	// "Concatenation" and "Comparison operators"). They meet at the borrowed
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
	// An explicit callback contract constrains both arms. Without one, distinct
	// procedure contracts meet at their shared written signature.
	if type_kind(k.c, expected) == .Proc && assignable(k.c, then_type, expected) && assignable(k.c, else_type, expected) {
		materialize(k, v.then, expected)
		materialize(k, v.otherwise, expected)
		v.type = expected
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
	defer materialize_call_receiver(k, v)
	v.value_category = .Value

	// A built-in is not a value, so it is recognised before the callee is
	// checked as one.
	if ident, is_ident := v.callee.(^Expr_Ident); is_ident {
		symbol_id := lookup_symbol(k.scope, identifier_of(k.c, ident))
		if sym := symbol_of(k.c, symbol_id); sym != nil && sym.kind == .Builtin {
			check_builtin_call(k, v, ident, symbol_id, expected)
			return
		}
	}
	// The same built-in reached through the standard package that publishes it —
	// `mem.default_allocator()`. The qualified spelling names the identical
	// symbol, so it collapses to the identical call rather than to a wrapper.
	if symbol_id := callee_package_builtin(k, v.callee); symbol_id != INVALID_SYMBOL {
		check_builtin_call(k, v, qualify_builtin_callee(k, v), symbol_id, expected)
		return
	}

	// Nor is a procedure group: it stands for several procedures, so it goes to
	// the overload engine before anything asks it for a single procedure type.
	if group := callee_group(k, v.callee); group != INVALID_SYMBOL {
		check_group_call(k, v, group, expected)
		return
	}
	if group := associated_group(k, v.callee); group != INVALID_SYMBOL {
		check_group_call(k, v, group, expected)
		return
	}
	// Nor is a generic procedure: `$T` has no type until the call's own arguments
	// bind it, so it is never checked as a value.
	if template := callee_generic_procedure(k, v.callee); template != INVALID_SYMBOL {
		check_group_call(k, v, template, expected)
		return
	}
	// An interface application is a compile-time boolean, not a conversion.
	if info := interface_info_for(k, named_callee_symbol(k, v.callee)); info != nil {
		check_interface_application(k, v, info)
		return
	}
	// design.md "Shared ownership": one name means two things. `shared(Node)` is
	// the type and `shared(node)` takes ownership of a value, and nothing but the
	// operand tells them apart — so the call settles it, and everything that is
	// not a type goes to the constructor group.
	if k.c.shared_symbol != INVALID_SYMBOL &&
	   named_callee_symbol(k, v.callee) == k.c.shared_symbol &&
	   !callee_argument_denotes_type(k, v) {
		check_group_call(k, v, k.c.shared_construct_symbol, expected)
		return
	}
	// `Simd(f32, 4)` and `Range(int)` denote a type wherever they appear too,
	// which is what makes `Simd(i32, 4)(v)` an ordinary written conversion.
	if simd_callee(k, v.callee) || range_callee(k, v.callee) {
		denoted := INVALID_TYPE
		if range_callee(k, v.callee) {
			denoted = resolve_range_application(k, v)
		} else {
			denoted = resolve_simd_application(k, v)
		}
		if denoted == INVALID_TYPE {
			v.type = INVALID_TYPE
			return
		}
		v.type = TYPE_TYPE
		v.value_category = .Type
		v.is_const = true
		v.const_value = type_const(denoted)
		return
	}
	// A generic record application denotes a type wherever it appears, which is
	// what makes `Iterator :: Stack_Iterator(T, N);` an associated type.
	if generic_template_of_callee(k, v.callee, .Record) != nil {
		denoted := resolve_type_syntax(k, v)
		if denoted == INVALID_TYPE {
			v.type = INVALID_TYPE
			return
		}
		v.type = TYPE_TYPE
		v.value_category = .Type
		v.is_const = true
		v.const_value = type_const(denoted)
		return
	}
	// A slot called through a `dyn` view: an indirect call through the witness,
	// not an ordinary method lookup on a concrete type.
	if sel, is_selector := v.callee.(^Expr_Selector); is_selector && sel.operand != nil {
		if operand := dyn_operand_type(k, sel.operand); operand != INVALID_TYPE {
			if check_dyn_slot_call(k, v, sel, operand) {
				return
			}
			errorf(k.c, v.span, "L0467", "`%s` has no slot `%s`", type_name(k.c, operand), sel.name.text)
			v.type = INVALID_TYPE
			return
		}
	}
	// `field.get(value)` / `field.pointer(value)`: compiler-defined operations on
	// a descriptor constant, whose result type follows that descriptor. Only a
	// name bound to one qualifies, which is what a `$field` binding is, so no
	// other callee is checked twice looking for it.
	// `text.byte_len()`, `text.bytes()`, `string.from_runes(...)`, and
	// `union.active_typeid()`: compiler-defined operations on built-in carriers.
	if sel, is_selector := v.callee.(^Expr_Selector); is_selector && sel.operand != nil {
		if check_union_extract(k, v, sel) {
			return
		}
		if check_text_operation(k, v, sel) {
			return
		}
		if check_enum_values(k, v, sel) {
			return
		}
	}
	if sel, is_selector := v.callee.(^Expr_Selector); is_selector && callee_is_descriptor(k, sel.operand) {
		check_single_expr(k, sel.operand)
		if check_descriptor_operation(k, v, sel) {
			return
		}
	}

	outer_callee := k.in_callee
	k.in_callee = true
	// A bare `.name(payload)` callee takes its union from the expected type, the
	// same way the implicit enum selector takes its enum from one.
	callee_expected := INVALID_TYPE
	if sel, is_selector := v.callee.(^Expr_Selector); is_selector && sel.operand == nil {
		callee_expected = expected
	}
	callee_type := check_expr(k, v.callee, callee_expected)
	k.in_callee = outer_callee
	callee_base := expr_base(v.callee)
	if callee_base == nil {
		v.type = INVALID_TYPE
		return
	}
	// A method selector is not a value: the receiver becomes argument zero, which
	// the selector alone cannot do.
	if callee_base.resolution.kind == .Method {
		check_method_call(k, v, v.callee.(^Expr_Selector), expected)
		return
	}
	// `U.name(payload)` / `.name(payload)`: the selector named the variant, and
	// the argument supplies its payload.
	if callee_base.resolution.kind == .Union_Variant {
		check_union_construct(k, v, v.callee.(^Expr_Selector))
		return
	}
	if callee_type == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}
	if callee_base.value_category == .Type {
		// `(dyn Drawable)(&circle)`: an ordinary explicit conversion, but one that
		// checks satisfaction and requests a witness rather than reinterpreting.
		if type_is_dyn(k.c, callee_base.denoted_type) {
			check_dyn_conversion(k, v, callee_base.denoted_type)
			return
		}
		check_conversion(k, v, callee_base.denoted_type)
		return
	}

	info := underlying_info(k.c, callee_type)
	if info == nil || info.kind != .Proc {
		// A payloadless variant is complete on its own, so the call is the
		// mistake rather than the selector.
		if sel, is_sel := v.callee.(^Expr_Selector);
		   is_sel && sel.variant_union != INVALID_TYPE &&
		   union_variant_payload(k.c, sel.variant_union, sel.variant_index) == TYPE_VOID {
			errorf(
				k.c, v.span, "L0425",
				"`%s.%s` carries no payload: write `%s` without a call",
				type_name(k.c, sel.variant_union), sel.name.text, sel.name.text,
			)
			v.type = INVALID_TYPE
			return
		}
		errorf(k.c, expr_span(v.callee), "L0320", "`%s` is not callable", type_name(k.c, callee_type))
		v.type = INVALID_TYPE
		return
	}

	// Only a directly named procedure may use defaults or named arguments; a
	// call through a procedure value supplies every parameter positionally.
	// `pkg.f` names one just as plainly as `f` does.
	declaration := INVALID_SYMBOL
	if named := callee_base.resolution.symbol; callee_base.resolution.kind == .Value {
		if sym := symbol_of(k.c, named); sym != nil && sym.kind == .Proc {
			declaration = named
		}
	}
	if reject_direct_hook_call(k, v.span, declaration) {
		v.type = INVALID_TYPE
		return
	}
	v.resolution = Resolution{kind = .Call, symbol = declaration, chosen_overload = declaration}

	if !bind_arguments(k, v, info, declaration) {
		v.type = INVALID_TYPE
		return
	}

	set_call_result(v, info.result, info.result_inout)
}

// design.md "Parameter semantics and ABI lowering": an `inout` result returns a
// place, so the call is one — addressable and assignable. Every call spelling
// settles its result here, because which one reached the procedure does not
// change what the procedure returns.
set_call_result :: proc(v: ^Expr_Call, result: Type_Id, result_inout: bool) {
	if result == INVALID_TYPE {
		v.type = TYPE_VOID
		return
	}
	v.type = result
	if result_inout {
		v.value_category = .Place
		v.addressable = true
		v.assignable = true
	}
}

// design.md "@(require_results)": a bare call statement discards its results.
// The policy comes from the selected declaration or, after overload selection,
// from the procedure group the call went through. An explicit
// `_ = call()` is an assignment, not this statement, so it is never reached.
report_discarded_required_results :: proc(k: ^Checker, expr: Expr) {
	call, is_call := expr.(^Expr_Call)
	if !is_call || call.type == TYPE_VOID {
		return // not a call, or a call with no results
	}
	required := false
	name := ""
	if selected := symbol_of(k.c, call.resolution.chosen_overload); selected != nil {
		required = selected.require_results
		name = identifier_text(k.c, selected.name)
	}
	if !required {
		if group := symbol_of(k.c, callee_group(k, call.callee)); group != nil && group.require_results {
			required = true
			name = identifier_text(k.c, group.name)
		}
	}
	if required {
		errorf(
			k.c, call.span, "L0612",
			"the result of `%s` must be used or discarded with `_ = ...`", name,
		)
		return
	}
	// design.md "@(require_results)": the attribute is a *type* attribute as
	// well, so a result whose type requires handling is required whoever
	// declared the procedure. `Result` is the one that matters in practice.
	if type_requires_results(k.c, call.type) {
		errorf(
			k.c, call.span, "L0612",
			"this call produces `%s`, which must be used or discarded with `_ = ...`",
			type_name(k.c, call.type),
		)
		return
	}
}

// The procedure group a callee names, or INVALID_SYMBOL. `pkg.group` names one
// as plainly as `group` does — `named_callee_symbol` already walks the package
// alias and requires the member to be public.
@(private = "file")
callee_group :: proc(k: ^Checker, callee: Expr) -> Symbol_Id {
	id := named_callee_symbol(k, callee)
	sym := symbol_of(k.c, id)
	return sym != nil && sym.kind == .Proc_Group ? id : INVALID_SYMBOL
}

// A `pkg.name` callee naming a public built-in of `pkg`, or INVALID_SYMBOL.
// Only the qualified spelling: `qualify_builtin_callee` rewrites a selector,
// and a plain identifier is already the form the built-in checkers expect.
@(private = "file")
callee_package_builtin :: proc(k: ^Checker, callee: Expr) -> Symbol_Id {
	if _, is_selector := callee.(^Expr_Selector); !is_selector {
		return INVALID_SYMBOL
	}
	id := named_callee_symbol(k, callee)
	sym := symbol_of(k.c, id)
	return sym != nil && sym.kind == .Builtin ? id : INVALID_SYMBOL
}

// Rewrites `pkg.builtin(...)` to the identifier form the built-in checkers and
// the backend already understand, keeping the original span so diagnostics still
// point at what was written.
@(private = "file")
qualify_builtin_callee :: proc(k: ^Checker, v: ^Expr_Call) -> ^Expr_Ident {
	selector := v.callee.(^Expr_Selector)
	ident := new(Expr_Ident, k.c.semantic_allocator)
	ident.span = selector.span
	ident.name = selector.name.text
	ident.name_id = intern_identifier(k.c, selector.name.text)
	ident.symbol = INVALID_SYMBOL
	v.callee = ident
	return ident
}

// The `dyn` type of a call's receiver, or INVALID_TYPE. Checked before the
// operand is used as anything else, so a slot call never falls through to
// ordinary method lookup.
@(private = "file")
dyn_operand_type :: proc(k: ^Checker, operand: Expr) -> Type_Id {
	ident, is_ident := operand.(^Expr_Ident)
	if !is_ident {
		return INVALID_TYPE
	}
	sym := symbol_of(k.c, lookup_symbol(k.scope, identifier_of(k.c, ident)))
	if sym == nil || !type_is_dyn(k.c, sym.type) {
		return INVALID_TYPE
	}
	check_single_expr(k, operand)
	return sym.type
}

// Does this operand name a reflection descriptor constant?
@(private = "file")
callee_is_descriptor :: proc(k: ^Checker, operand: Expr) -> bool {
	ident, is_ident := operand.(^Expr_Ident)
	if !is_ident {
		return false
	}
	sym := symbol_of(k.c, lookup_symbol(k.scope, identifier_of(k.c, ident)))
	return sym != nil && sym.kind == .Const && type_is_descriptor(k.c, sym.type)
}

// The generic procedure template a callee names, or INVALID_SYMBOL.
@(private = "file")
callee_generic_procedure :: proc(k: ^Checker, callee: Expr) -> Symbol_Id {
	template := generic_template_of_callee(k, callee, .Procedure)
	return template == nil ? INVALID_SYMBOL : template.symbol
}

// `Type.group(...)` and `pkg.Type.group(...)`: an associated group named through
// the type. Resolving the operand as a type is silent when it is not one, so a
// value receiver falls straight through to the method path.
@(private = "file")
associated_group :: proc(k: ^Checker, callee: Expr) -> Symbol_Id {
	sel, is_selector := callee.(^Expr_Selector)
	if !is_selector || sel.operand == nil {
		return INVALID_SYMBOL
	}
	subject := resolve_type_syntax(k, sel.operand)
	if subject == INVALID_TYPE {
		return INVALID_SYMBOL
	}
	member := find_member(k, subject, intern_identifier(k.c, sel.name.text))
	if sym := symbol_of(k.c, member); sym != nil && sym.kind == .Proc_Group {
		return member
	}
	return INVALID_SYMBOL
}

// `value.method(args)`. The receiver is argument zero. An `inout` receiver
// carries its mode implicitly; a consuming one is written `move(value).method()`
// (design.md "Receiver forms").
@(private = "file")
check_method_call :: proc(k: ^Checker, v: ^Expr_Call, sel: ^Expr_Selector, expected: Type_Id) {
	receiver := sel.operand
	receiver_base := expr_base(receiver)
	candidates := method_candidates(k, receiver_base.type, intern_identifier(k.c, sel.name.text))
	written, args_ok := collect_call_arguments(k, v.args, candidates, 1)
	if !args_ok {
		v.type = INVALID_TYPE
		return
	}
	// Every candidate consumes, and the transfer is not written: say so here
	// rather than through a no-overload-matches report of the same fact.
	if _, moved := receiver.(^Expr_Move); !moved && all_candidates_consume(k, candidates) {
		errorf(
			k.c, expr_span(receiver), "L0501",
			"`%s` consumes its receiver, so the call is written `move(...).%s(...)`",
			sel.name.text, sel.name.text,
		)
		v.type = INVALID_TYPE
		return
	}
	args := make([]Arg_Info, len(written) + 1, k.c.semantic_allocator)
	args[0] = arg_from_expr(k, receiver)
	args[0].is_receiver = true
	copy(args[1:], written)

	description := concat(k.c, "method `", concat(k.c, sel.name.text, "`"))
	cand, resolved := resolve_overload(k, v.span, description, candidates, args, expected)
	if !resolved {
		v.type = INVALID_TYPE
		return
	}
	chosen := symbol_of(k.c, cand.symbol)
	if reject_direct_hook_call(k, v.span, cand.symbol) {
		v.type = INVALID_TYPE
		return
	}
	// An exclusive mutable borrow needs a mutable place. A consuming receiver is
	// an `^Expr_Move` by the rank filter above, and `check_move` has already held
	// it to `move`'s storage rule -- no partial move, no static-duration source.
	if chosen.receiver == .Inout {
		// A mutating receiver is passed by address just like an explicit `&mut`.
		// Packed fields are writable but deliberately not addressable: silently
		// accepting one here can hand a misaligned pointer to the method body.
		if field, packed := packed_field_reached(k, receiver); packed {
			errorf(
				k.c, sel.name.span, "L0614",
				"cannot take the address of `%s`: it is reached through a packed struct", field,
			)
			v.type = INVALID_TYPE
			return
		}
		if !receiver_base.assignable {
			report_not_assignable(k, receiver_base, "the receiver of a mutating method")
			v.type = INVALID_TYPE
			return
		}
	}
	sel.resolution = Resolution{kind = .Method, symbol = cand.symbol}
	sel.type = chosen.proc_type
	v.resolution = Resolution{kind = .Call, symbol = cand.symbol, chosen_overload = cand.symbol}
	if !bind_chosen_call(k, v, cand, args) {
		v.type = INVALID_TYPE
		return
	}
	set_call_result(v, chosen.result, chosen.result_inout)
	// `lookup_value` produces an owned copy of the stored element, so a move-only
	// element has nothing for it to produce. Reported after the result shape is
	// settled, so a `v, ok :=` destructuring still knows its arity.
	// design.md "Zero values": growth fills the new slots with the element's
	// zero, and a no-zero element has none to fill them with.
	#partial switch chosen.container_op {
	case .Resize:
		require_type_has_zero(
			k, container_element(k.c, chosen.params[0]), v.span, "growing a container",
		)
	}
	if chosen.container_op == .Map_Lookup_Value {
		element := container_element(k.c, chosen.params[0])
		if type_clone_disabled(k.c, element) {
			errorf(
				k.c, v.span, "L0491",
				"`%s` is move-only, so `lookup_value` cannot copy it out; use `find`, which borrows",
				type_name(k.c, element),
			)
		}
	}
	// design.md "Iteration adapters": a map view yields owned elements, so the
	// halves it copies need a copy entry point. The view itself costs nothing;
	// what it cannot do is produce a `move_only` key or value.
	#partial switch chosen.container_op {
	case .Map_Entries, .Map_Keys, .Map_Values:
		require_copyable_view_element(k, chosen, v.span)
	}
	// A sort needs its element's `<` settled before the backend asks for it.
	require_sort_order_policy(k, chosen, v.span)
	fold_standard_customization_call(k, v, chosen)
}

// A fixed array's and a vector's length are properties of their type, so the
// call has a constant value. The call itself stays ordinary: the backend still
// evaluates the receiver exactly once, for its effects.
fold_standard_customization_call :: proc(k: ^Checker, v: ^Expr_Call, chosen: ^Symbol) {
	if chosen == nil || chosen.synth != .Standard_Len || len(chosen.params) == 0 {
		return
	}
	info := underlying_info(k.c, chosen.params[0])
	if info == nil || (info.kind != .Array && info.kind != .Simd) {
		return
	}
	v.is_const = true
	v.const_value = int_const(k.c, i64(info.count))
}

@(private = "file")
require_copyable_view_element :: proc(k: ^Checker, chosen: ^Symbol, span: Span) {
	subject := chosen.params[0]
	halves := [2]struct{copied: bool, type: Type_Id, what: string}{
		{chosen.container_op != .Map_Values, container_key(k.c, subject), "key"},
		{chosen.container_op != .Map_Keys, container_element(k.c, subject), "value"},
	}
	for half in halves {
		if !half.copied || !type_clone_disabled(k.c, half.type) {
			continue
		}
		errorf(
			k.c, span, "L0491",
			"`%s` is move-only, so this view cannot copy the %s out of the map; iterate `&value`, or remove the entries",
			type_name(k.c, half.type), half.what,
		)
		return
	}
}

reject_direct_hook_call :: proc(k: ^Checker, span: Span, symbol_id: Symbol_Id) -> bool {
	sym := symbol_of(k.c, symbol_id)
	if sym == nil || sym.hook == .None {
		return false
	}
	operation := "the corresponding language operation"
	switch sym.hook {
	case .Convert: operation = "`T(value)`"
	case .Copy:    operation = "`clone(value)` or `try_clone(value)`"
	case .Drop:    operation = "`drop(value)`"
	case .None:
	}
	errorf(k.c, span, "L0412", "`%s` implements `hook(%s)` and is not directly accessible; use %s", identifier_text(k.c, sym.name), hook_name(sym.hook), operation)
	return true
}

// Whether a one-argument application is naming a type rather than passing a
// value. `resolve_type_syntax` is a probe: it stays silent on anything that is
// not a type, which is what lets this ask without reporting.
@(private = "file")
callee_argument_denotes_type :: proc(k: ^Checker, v: ^Expr_Call) -> bool {
	if len(v.args) != 1 || v.args[0].name.text != "" || v.args[0].mode != .Value {
		return false
	}
	return resolve_type_syntax(k, v.args[0].value) != INVALID_TYPE
}

// A call through a group: check every argument once, rank the members, then bind
// against the one that wins.
@(private = "file")
check_group_call :: proc(k: ^Checker, v: ^Expr_Call, group: Symbol_Id, expected: Type_Id) {
	sym := symbol_of(k.c, group)
	// A generic procedure is one candidate rather than several, but it still has
	// to be inferred and substituted before it can be ranked, so it takes the
	// same path.
	members := sym.kind == .Proc_Group ? sym.members : []Symbol_Id{group}
	description := concat(k.c, "`", concat(k.c, identifier_text(k.c, sym.name), "`"))
	args, args_ok := collect_call_arguments(k, v.args, members, live_group = group)
	if !args_ok {
		v.type = INVALID_TYPE
		return
	}
	// Checking an explicitly typed argument may instantiate a generic subject and
	// add its public extension procedure to this synthetic group. Read the group
	// again rather than resolving against the member snapshot from before the
	// arguments existed.
	if current := symbol_of(k.c, group); current != nil && current.kind == .Proc_Group {
		members = current.members
	}
	cand, resolved := resolve_overload(k, v.span, description, members, args, expected)
	if !resolved {
		v.type = INVALID_TYPE
		return
	}
	annotate_chosen_callee(k, v, cand.symbol)
	if !bind_chosen_call(k, v, cand, args) {
		v.type = INVALID_TYPE
		return
	}
	chosen := symbol_of(k.c, cand.symbol)
	set_call_result(v, chosen.result, chosen.result_inout)
}

// Every call spelling passes an immutable receiver by address, including
// `Type.method(CONSTANT)` and calls resolved through a procedure group.
@(private = "file")
materialize_call_receiver :: proc(k: ^Checker, v: ^Expr_Call) {
	if v.type == INVALID_TYPE || v.is_const || len(v.bound) == 0 || v.bound[0] == nil {
		return
	}
	chosen := symbol_of(k.c, v.resolution.chosen_overload)
	if type_is_compile_time_only(k.c, expr_base(v.bound[0]).type) { return }
	if chosen != nil && chosen.has_receiver && chosen.receiver == .Borrow && expr_base(v.bound[0]).is_const {
		request_materialization(k, v.bound[0])
	}
}

// Rewrites the callee to name the selected overload, so every later phase — the
// backend included — sees an ordinary call to one procedure.
annotate_chosen_callee :: proc(k: ^Checker, v: ^Expr_Call, chosen: Symbol_Id) {
	sym := symbol_of(k.c, chosen)
	// A sort needs its element's `<` settled before the backend asks for it, and
	// this is where every call form — method, group — has arrived at one
	// declaration.
	require_sort_order_policy(k, sym, v.span)
	if base := expr_base(v.callee); base != nil && sym != nil {
		base.resolution = Resolution{kind = .Value, symbol = chosen}
		base.value_category = .Value
		base.type = sym.proc_type
	}
	if ident, is_ident := v.callee.(^Expr_Ident); is_ident {
		ident.symbol = chosen
	}
	v.resolution = Resolution{kind = .Call, symbol = chosen, chosen_overload = chosen}
}

// One written argument bound against one parameter, returned as the expression
// to bind.
// design.md "Parameter semantics and ABI lowering": `inout` is written at both
// ends, and the argument is a place because the callee writes through it.
// Shared, so a call with a variadic pack enforces the same contract as one
// without.
bind_written_argument :: proc(
	k: ^Checker, arg: Argument, target: Type_Id, expected: Param_Mode, prechecked := false,
) -> (Expr, bool) {
	if (expected == .Inout) != (arg.mode == .Inout) {
		if expected == .Inout {
			errorf(k.c, arg.span, "L0370", "this parameter is `inout`; write `inout` at the call site")
		} else {
			errorf(k.c, arg.span, "L0370", "this parameter is not `inout`")
		}
		return arg.value, false
	}
	value, passed := pass_argument(k, arg.value, target, prechecked, arg.mode == .Inout)
	if !passed {
		return value, false
	}
	if expected == .Borrow && !check_borrow_argument(k, value) { return value, false }
	if arg.mode == .Inout {
		if base := expr_base(value); base != nil && !base.assignable {
			report_not_assignable(k, base, "an `inout` argument")
			return value, false
		}
	}
	return value, true
}

check_argument_value :: proc(k: ^Checker, e: Expr, target: Type_Id, inout_argument := false) -> (Expr, bool) {
	// design.md "Indexing and slicing" and "Maps": an `inout` argument is a place
	// the callee really writes, so it selects an `inout` indexing overload. It
	// does not insert: `inout m[key]` hands the callee an element that must
	// already be there. Every path that binds an argument goes through here, so
	// the rule is stated once.
	k.place_position, k.insert_position = inout_argument, false
	type := check_single_expr(k, e, target)
	k.place_position, k.insert_position = false, false
	if type == INVALID_TYPE || target == INVALID_TYPE {
		return e, false
	}
	if !materialize(k, e, target) {
		return e, false
	}
	final := expr_base(e).type
	if !assignable(k.c, final, target) {
		errorf(
			k.c,
			expr_span(e),
			"L0310",
			"cannot pass `%s` with `%s`",
			type_name(k.c, target),
			type_name(k.c, final),
		)
		return e, false
	}
	return e, true
}

// Binds written arguments to parameters, then fills the omitted ones from the
// declaration's defaults. `v.bound` is the resolved parameter-order list the
// backend evaluates.
@(private = "file")
bind_arguments :: proc(k: ^Checker, v: ^Expr_Call, info: ^Type_Info, declaration: Symbol_Id) -> bool {
	count := len(info.parameters)
	// design.md "`@(c_vararg)`": a foreign C-variadic call passes each concrete
	// argument after the fixed ones, with no slice built.
	if info.c_vararg {
		return bind_c_vararg_arguments(k, v, info)
	}
	// design.md "Variadic parameters": every trailing argument fills one
	// parameter, so the pack is settled before the ordinary positional binding
	// runs and the written arguments it consumed are no longer separate.
	if variadic_parameter_index(info) >= 0 {
		bound_ok := bind_variadic_arguments(k, v, info, declaration)
		// A pack changes how the arguments are packed, not whether a `move`
		// parameter's transfer is written at the call site. A call through a group
		// asks the same question right after binding the same way.
		require_argument_ownership(k, v, declaration)
		return bound_ok
	}
	bound := make([]Expr, count, k.c.semantic_allocator)
	filled := make([]bool, count, k.c.semantic_allocator)
	declared := symbol_of(k.c, declaration)
	ok := true
	named := false
	// design.md "Evaluation order": a written argument runs where it is
	// written, whatever slot its name selects. The order is recorded here, where
	// the slot for each source element is already known, so neither the backend
	// nor the evaluator has to rediscover it.
	order := make([dynamic]int, 0, count, k.c.semantic_allocator)

	for arg, index in v.args {
		if arg.mode == .Spread {
			// design.md "Variadic parameters": a spread fills a variadic pack, and
			// this callee has none — a permanent answer, not a pending milestone
			//.
			errorf(k.c, arg.span, "L0371", "`..` needs a variadic parameter to spread into")
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
			slot = parameter_slot_named(k.c, declared, intern_identifier(k.c, arg.name.text))
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
		append(&order, slot)
		expected_mode := slot < len(info.param_modes) ? info.param_modes[slot] : Param_Mode.Value
		value, passed := bind_written_argument(k, arg, info.parameters[slot], expected_mode)
		bound[slot] = value
		ok = ok && passed
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
		bound[index] = substitute_caller_location(k, declared.param_defaults[index], v.span)
		append(&order, index)
	}

	v.bound = bound
	if named {
		v.bound_order = order[:]
	}
	require_argument_ownership(k, v, declaration)
	return ok
}

// design.md "`@(c_vararg)`": the fixed parameters bind normally; every argument
// after them is a concrete C variadic — inferred, required foreign-ABI-safe
// after the default promotions, and never spread. `v.bound` keeps all of them
// so the backend emits one true varargs call.
@(private = "file")
bind_c_vararg_arguments :: proc(k: ^Checker, v: ^Expr_Call, info: ^Type_Info) -> bool {
	fixed := len(info.parameters)
	if len(v.args) < fixed {
		errorf(
			k.c, v.span, "L0322", "this procedure takes at least %d argument%s, found %d",
			fixed, fixed == 1 ? "" : "s", len(v.args),
		)
		return false
	}
	bound := make([]Expr, len(v.args), k.c.semantic_allocator)
	ok := true
	for arg, index in v.args {
		if arg.mode == .Spread {
			errorf(k.c, arg.span, "L0628", "a C-variadic call cannot spread; pass each concrete argument")
			ok = false
			continue
		}
		if arg.name.text != "" {
			errorf(k.c, arg.span, "L0371", "a C-variadic call takes positional arguments only")
			ok = false
			continue
		}
		if index < fixed {
			value, passed := check_argument_value(k, arg.value, info.parameters[index])
			bound[index] = value
			if !passed {
				ok = false
			}
			continue
		}
		bound[index] = arg.value
		type := check_single_expr(k, arg.value)
		if type == INVALID_TYPE {
			ok = false
			continue
		}
		// An untyped literal defaults to its concrete type, which is what actually
		// crosses (and what the C promotions then act on).
		if type_is_untyped(k.c, type) {
			type = default_type(k.c, type)
			check_single_expr(k, arg.value, type)
		}
		if safe, reason := foreign_abi_safe(k.c, type); !safe {
			errorf(k.c, arg.span, "L0619", "a C-variadic argument is not ABI-safe: %s", reason)
			ok = false
		}
	}
	v.bound = bound
	return ok
}

// `T(value)` is conversion only. Built-in source/target pairs are reserved;
// every other pair may be supplied by an inherent `hook(convert)` on T.
@(private = "file")
check_conversion :: proc(k: ^Checker, v: ^Expr_Call, target: Type_Id) {
	if !gate_type(k, target, v.span) {
		v.type = INVALID_TYPE
		return
	}
	if len(v.args) != 1 || v.args[0].name.text != "" || v.args[0].mode != .Value {
		errorf(k.c, v.span, "L0410", "a conversion to `%s` takes exactly one plain value argument", type_name(k.c, target))
		v.type = INVALID_TYPE
		return
	}
	// The operand is checked without the destination as expression context. The
	// conversion node, not a nested binary operator, owns that destination.
	source := check_single_expr(k, v.args[0].value)
	if source == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}
	if builtin_conversion(k, v, target, source) {
		return
	}
	args := make([]Arg_Info, 1, k.c.semantic_allocator)
	args[0] = arg_from_expr(k, v.args[0].value)
	check_conversion_hook_call(k, v, target, args, source)
}

// The built-in half of `T(v)`, including pointer and `distinct` conversions.
// Returns false — without reporting — when no built-in conversion reaches the
// target, which is what lets stage 2 run.
@(private = "file")
builtin_conversion :: proc(k: ^Checker, v: ^Expr_Call, target, source: Type_Id) -> bool {
	base := expr_base(v.args[0].value)
	// Constant folding must not reintroduce a representation-only conversion
	// that runtime values do not have. Two distinct identities meet only through
	// an explicit target hook, even when the operand happens to be constant.
	if type_kind(k.c, source) == .Distinct && type_kind(k.c, target) == .Distinct && source != target {
		return false
	}
	converted: Const_Value
	if base.is_const {
		fits: bool
		converted, fits = convert_const(k.c, base.const_value, target, true)
		if !fits {
			return false
		}
	} else if !convertible(k.c, source, target) {
		return false
	}
	v.resolution = Resolution{kind = .Conversion}
	record_proc_contract_check(k.c, source, target, v.span)
	v.bound = make([]Expr, 1, k.c.semantic_allocator)
	v.bound[0] = v.args[0].value
	v.type = target
	if base.is_const {
		// The operand keeps its own type; the conversion node carries the result.
		v.is_const = true
		v.const_value = converted
	}
	return true
}

// User conversion hooks are inherent to the target, so imports and extension
// packages cannot alter an existing `T(value)` expression.
@(private = "file")
check_conversion_hook_call :: proc(k: ^Checker, v: ^Expr_Call, target: Type_Id, args: []Arg_Info, attempted: Type_Id) {
	usable := hook_candidates(k, target, .Convert)
	if len(usable) == 0 {
		errorf(k.c, expr_span(v.args[0].value), "L0373", "`%s` cannot be converted to `%s`", type_name(k.c, attempted), type_name(k.c, target))
		if (target == TYPE_STRING || target == TYPE_STRING_VIEW) &&
		   (slice_element(k.c, attempted) == TYPE_U8 || (target == TYPE_STRING && underlying_kind(k.c, attempted) == .CString_View)) {
			add_notef(k.c, v.span, "use `%s.from_utf8(bytes)`, which returns `Option(%s)`", type_name(k.c, target), type_name(k.c, target))
		}
		v.type = INVALID_TYPE
		return
	}
	description := concat(k.c, "conversion to `", concat(k.c, type_name(k.c, target), "`"))
	cand, resolved := resolve_overload(k, v.span, description, usable[:], args, target)
	if !resolved {
		v.type = INVALID_TYPE
		return
	}
	annotate_chosen_callee(k, v, cand.symbol)
	if !bind_chosen_call(k, v, cand, args) {
		v.type = INVALID_TYPE
		return
	}
	v.type = target
}

// A procedure literal in expression position is hoisted to its own module
// function. It has no closure, so `check_ident` rejects any name that lives in
// an enclosing procedure's frame.
@(private = "file")
check_proc_literal :: proc(k: ^Checker, v: ^Expr_Proc) {
	v.value_category = .Value
	// design.md: `---` is foreign-declaration syntax, so a procedure *value* never
	// ends with one — it has nothing to call.
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
	// A nested literal is its own procedure, so an enclosing `impl` block's
	// subject is not its receiver's type.
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
	// The same registry gate every other backend-only list has: an interface
	// requirement is a hypothetical program checked on cloned syntax, so a literal
	// written inside one would otherwise be hoisted to a real module function that
	// nothing can call.
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
			// `resolve_type_syntax` stays silent so it can be used as a probe; the
			// literal's written type is a position that requires one, so it says
			// what is missing here — about the element, which is the failing part
			// of `[?]T`.
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
			// `resolve_type_syntax` stays silent so it can be used as a probe; the
			// literal's written type is a position that requires one, so it says
			// what is missing here.
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
	// A composite literal is addressable temporary storage, and is never itself
	// an assignment destination.
	v.addressable = true
	v.assignable = false
	v.immutable = .Temporary
	// A literal produces a value the backend has to clean up, and a managed one
	// is cleaned up through its lifecycle operations. A container's run through
	// one operation table per element type, and that table carries the element's
	// clone beside its drop — so a container that is only ever constructed and
	// dropped still needs the copy entry points a written copy would contribute.
	// Contributed here, at the one place every aggregate is built, rather than
	// only at the sites that copy.
	if type_is_managed(k.c, target) {
		contribute_lifecycle_members(k, target)
	}

	#partial switch info.kind {
	case .Struct:
		check_struct_literal(k, v, target, info)
	case .Array, .Simd:
		// design.md "SIMD vectors": "written as a composite literal with one
		// element per lane, in lane order" — the array's own rule, including the
		// zero fill that makes `{}` the zero vector.
		check_array_literal(k, v, target, info)
	case .Slice:
		check_slice_literal(k, v, target, info)
	case .Dynamic_Array:
		check_dynamic_literal(k, v, target, info)
	case .Map:
		check_map_literal(k, v, target, info)
	case:
		// design.md "Zero values": the zero value is *written* `{}`, for every type
		// that has one — not only for an aggregate. `{}` at a scalar is therefore
		// that zero, and it is the only spelling generic code has for `T`'s zero
		// when `T` may be bound to a non-aggregate. Anything with elements in it
		// is still a composite, and still wrong here.
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

// A slice literal has the type it is written with (design.md "Slice
// literals"): `[]T{...}` produces `[]T`, `[]mut T{...}` produces `[]mut T` —
// never inferred from the destination. Elements go into a hidden fixed-array
// owner in the surrounding lexical scope, which the slice then views.
@(private = "file")
check_slice_literal :: proc(k: ^Checker, v: ^Expr_Composite, target: Type_Id, info: ^Type_Info) {
	// Written without a type — `x: []int = {1, 2}` — would have to infer the
	// capability from the destination, which is exactly what the design forbids.
	if v.type_expr == nil {
		// `{` is a directive to core:fmt, so the braces are not spelled in the
		// format string.
		errorf(k.c, v.span, "L0479", "a slice literal must be written with its type, as in `%s`", concat(k.c, type_name(k.c, target), "{ ... }"))
		v.type = INVALID_TYPE
		return
	}
	v.backing = array_of(k.c, info.element, u64(len(v.elements)))
	ok := true
	for element in v.elements {
		if element.key != nil {
			errorf(k.c, element.span, "L0479", "a slice literal has no keyed elements")
			ok = false
			continue
		}
		if !check_value_expr(k, element.value, info.element, "initialise") {
			ok = false
		}
	}
	if !ok {
		v.type = INVALID_TYPE
		return
	}
	// The literal denotes the slice, not the root: it is a borrow of storage the
	// backend owns, so it is not itself an addressable place.
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
		// Positional aggregate construction does not bypass field visibility: an
		// initializer that supplies an inaccessible field is still rejected
		// (design.md). Omitted trailing fields still zero-fill, so this rejects
		// supplying one, not declaring one.
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
		if symbol == nil {
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

// design.md's array, slice, and dynamic-array literals list their elements
// positionally; only a struct literal names fields and only a map literal
// writes `key = value`. A keyed element in a sequence literal is therefore a
// permanent answer rather than an unimplemented milestone, and it is reported
// once for the whole literal instead of once per element.
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

// design.md "Dynamic arrays": a literal builds a container, so unlike a fixed
// array's it is never a constant — it allocates through the destination's
// selected allocator. An empty one allocates nothing and stays the constant
// all-zero header, which is what `xs = {}` means.
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

// A map literal initializes a map, written `key = value` (design.md "Maps").
// Like a dynamic array's it allocates and is therefore never a constant; the
// empty one is the constant all-zero header.
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
				element_type = underlying_info(k.c, target).element
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
	case .Typeid:
		// design.md "`type` and `typeid`": `Invalid` is the zero value, and a nil id
		// resolves to it. Its numeric form is 0, so an uninitialised `typeid` local
		// must be zeroed rather than left as stack garbage (an optimizer otherwise
		// promotes the undef and `type_info_of` reads past the table).
		return type_const(INVALID_TYPE), true
	case .Pointer, .C_Pointer, .Raw_Pointer, .Proc, .Union, .Allocator, .Allocator_Error,
	     .CString_View:
		return nil_const(), true
	// A string's empty value is all zero (design.md "string type"). A nil view
	// has length 0 and points at no storage.
	case .String, .String_View:
		return Const_Value{kind = .String}, true
	case .Array, .Simd:
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
	case .Struct, .Any_View, .Dyn, .Slice, .Dynamic_Array, .Map:
		// The zero value of an erased view is nil: a null pointer pair. A nil slice
		// is the same shape — a null pointer and a zero length (design.md "Nil
		// slices"). A container's is the four-word all-zero header, which design.md
		// requires be empty, allocator-unbound, constant, and immediately usable.
		ensure_slice_fields(c, under)
		ensure_container_fields(c, under)
		info = type_of(c, under)
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
	// design.md "Unions": a payload never becomes a union implicitly. Two variants
	// may share a payload type, so only a written `.name(payload)` says which one
	// is meant.
	// design.md "any_view type": the conversion is implicit at an `any_view`
	// destination. The concrete type is kept so the backend knows what to take
	// the address of and which `typeid` to pair with it.
	// A `string` converts implicitly to a `string_view` (design.md) — a borrow
	// that costs nothing and needs no validation, because a `string` is already
	// valid UTF-8 by construction.
	if underlying_kind(k.c, target) == .String_View &&
	   underlying_kind(k.c, base.type) == .String {
		base.view_from = base.type
		base.type = target
		return true
	}
	// design.md "SIMD vectors": "A scalar converts to a vector implicitly
	// wherever a vector is expected, producing the **splat**." A constant folds
	// into the vector's own constant below; a runtime scalar is splatted by the
	// backend, which is what this records.
	if type_is_simd(k.c, target) && !type_is_simd(k.c, base.type) && !base.is_const {
		element := type_of(k.c, type_underlying(k.c, target)).element
		if base.type != element && !materialize(k, e, element) {
			return false
		}
		base.splat_from = expr_base(e).type
		base.type = target
		return true
	}
	if target == TYPE_ANY_VIEW && base.type != TYPE_ANY_VIEW {
		if !any_view_accepts(k.c, base.type) {
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
			return float_const(bi_to_f64(storage, value.integer), 64), true
		}
	case .Untyped_Bool:
		if value.kind == .Boolean {
			return value, true
		}
	case .Untyped_Nil:
		if value.kind == .Nil {
			return value, true
		}
	// design.md "From a string literal to X": a literal's zero-terminated bytes
	// have static lifetime, so the same constant initializes an owning `string`,
	// a borrowed view, and a C view alike.
	case .Untyped_String, .String, .String_View, .CString_View:
		if value.kind == .String {
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
			if !bi_fits(storage, value.integer, bits, signed) {
				return value, false
			}
			return Const_Value{kind = .Integer, integer = value.integer}, true
		case .Float:
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
			// An unchanged width keeps the constant exactly as it is. Re-encoding
			// from the numeric field would quiet a signalling NaN that
			// `unsafe.transmute` produced, and this conversion changes nothing.
			if value.float_bits == info.bits {
				return value, true
			}
			return float_const(value.float, info.bits), true
		case .Integer, .Rune:
			return float_const(bi_to_f64(storage, value.integer), info.bits), true
		}
	case .Typeid:
		// `typeid` is a runtime scalar, but its reserved zero value is still written
		// `nil`, just like the zero id returned for a nil union.
		if value.kind == .Nil {
			return type_const(INVALID_TYPE), true
		}
	case .Pointer, .C_Pointer, .Raw_Pointer, .Proc, .Allocator, .Allocator_Error:
		// `nil` is the zero value of pointer, C pointer, `rawptr`, and
		// procedure alike (design.md "Zero values"). A C pointer is one word
		// like the others, so the null constant is its zero exactly as it is a
		// `^T`'s.
		if value.kind == .Nil {
			return nil_const(), true
		}
	case .Union, .Dyn, .Any_View, .Slice:
		// The only union constant is its zero value; a variant value becomes one
		// at run time, where the tag can be written. An erased view is the same:
		// its zero value is nil and every other one is built at run time. A slice
		// constant is likewise only ever the nil one — a live slice needs a root
		// address, which exists only at run time.
		if value.kind == .Nil {
			return nil_const(), true
		}
	case .Simd:
		// design.md "SIMD vectors": `Simd(U, N)(v)` "converts each lane of `v`
		// from `T` to `U` under the same rule the scalar conversion `U(lane)`
		// would use, and requires the same lane count". A scalar constant is the
		// splat: that same conversion, into every lane. Both are the one loop
		// below, so a constant vector folds exactly where `convertible` already
		// says it may — otherwise the fold would refuse what the backend emits.
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
		// design.md "Shared ownership": "Its zero value is `nil`". A handle is one
		// pointer, so its zero representation *is* the null one; writing it `nil`
		// is what makes `handle == nil` and `h: shared(T) = nil` mean the obvious
		// thing on a library record.
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
		case .Pointer, .C_Pointer, .Raw_Pointer, .Proc, .Union, .Dyn, .Any_View, .Slice, .Typeid,
		     .String, .String_View, .CString_View,
		     .Allocator, .Allocator_Error:
			// The zero value of every erased view and `typeid` is nil, and so is a
			// slice's (design.md "Nil slices"). A nil `Allocator_Error` is success.
			return true
		}
		// design.md "Shared ownership": "Its zero value is `nil`" — the one
		// record type whose zero has that spelling, because it is one pointer and
		// the language, not the library, says so.
		return type_is_shared_handle(c, to)
	}
	// design.md "SIMD vectors": "A scalar converts to a vector implicitly
	// wherever a vector is expected, producing the **splat**". The reverse is not
	// a conversion, and neither is one vector type to another.
	if type_is_simd(c, to) && !type_is_simd(c, from) {
		element := type_of(c, type_underlying(c, to)).element
		return from == element || assignable(c, from, element)
	}
	// A mutable carrier implicitly weakens to a read-only one; a read-only
	// carrier never converts to a mutable one (design.md).
	if carrier_weakens_to(c, from, to) {
		return true
	}
	// A callee may promise more about what it keeps of an argument than the
	// procedure type it is stored in asks for, and never less (design.md
	// "Escape levels").
	if proc_escape_weakens_to(c, from, to) {
		return true
	}
	// design.md: conversion from a concrete value to `any_view` is implicit when
	// an `any_view` destination is expected, and never allocates. This sits above
	// the untyped branches because a constant reaches an `any_view` through its
	// default type - which is what every `..any_view` variadic is given.
	if to == TYPE_ANY_VIEW && any_view_accepts(c, from) {
		return true
	}
	if from == TYPE_UNTYPED_STRING {
		// design.md "From a string literal to X": a literal's bytes have static
		// lifetime, so it initializes an owning `string`, a borrowed view, and a
		// zero-terminated C view alike.
		#partial switch underlying_kind(c, to) {
		case .String, .String_View, .CString_View:
			return true
		}
		return false
	}
	// A `string` converts implicitly to a `string_view` (design.md "string type
	// conversions"). The conversion is a borrow of the string, costs nothing,
	// and needs no validation because a `string` is already valid UTF-8 by
	// construction. It runs one way only.
	if underlying_kind(c, from) == .String &&
	   underlying_kind(c, to) == .String_View {
		return true
	}
	if type_is_untyped(c, from) {
		#partial switch underlying_kind(c, to) {
		case .Int, .Float, .Rune, .Bool, .Enum:
			return true
		}
		return false
	}
	// Any pointer converts to `rawptr` without a written conversion; the reverse
	// needs one. A C pointer converts to `rawptr` like all pointers do
	// (design.md).
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
	// Two distinct types with the same representation are not a built-in
	// conversion pair. Their semantic relationship is exactly what
	// `hook(convert)` declares.
	if type_kind(c, from) == .Distinct && type_kind(c, to) == .Distinct && from != to {
		return false
	}
	if source == dest {
		return true // between a distinct type and what it wraps, either way
	}
	source_kind, dest_kind := type_kind(c, source), type_kind(c, dest)

	// design.md "SIMD vectors": "An explicit `Simd(U, N)(v)` converts each lane
	// of `v` from `T` to `U` under the same rule the scalar conversion `U(lane)`
	// would use, and requires the same lane count." Nothing else converts to or
	// from a vector: no reinterpretation, and no vector-to-scalar.
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
		// Crossing through `rawptr` or `[^]T` is the explicit unchecked boundary,
		// but a direct checked-pointer conversion must preserve capability. Without
		// this guard `(^mut T)(reader)` would silently strengthen a `^T` and make
		// the read-only spelling writable.
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

// An operator as it appears in a diagnostic. `?` stands in for a kind with no
// punctuation spelling, which is what a keyword operator reaching here would be.
operator_text :: proc(op: Token_Kind) -> string {
	text := operator_spelling(op)
	return text != "" ? text : "?"
}

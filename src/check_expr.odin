// Expressions, conversions, and constant folding (m2-plan steps 2 and 4).
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
		check_selector(k, v, expected)

	case ^Expr_Index:
		check_index(k, v, place)

	case ^Expr_Slice:
		check_slice(k, v, place)

	case ^Expr_Type_Assert:
		check_type_assert(k, v)

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

	case ^Expr_Hash:
		// A `#name` outside a call. `#location` and `#caller_location` are the
		// only ones that mean anything here, and both wait for M6.
		errorf(k.c, v.span, "L0390", "`%s` needs the runtime source-location type, which arrives in M6", v.name)
		v.type = INVALID_TYPE

	case ^Expr_Range:
		check_range(k, v)

	case ^Expr_Move:
		check_move(k, v)

	case ^Expr_Proc_Group, ^Expr_Operator,
	     ^Type_Pointer, ^Type_Multi_Pointer, ^Type_Slice, ^Type_Dynamic_Array,
	     ^Type_Array, ^Type_Map, ^Type_Distinct, ^Type_Dyn, ^Type_Type,
	     ^Type_Poly, ^Type_Proc, ^Type_Record, ^Type_Enum, ^Type_Interface:
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
			unsupported_construct(k, base.span)
			base.type = INVALID_TYPE
		}
	}
	return base.type
}

// One value, exactly. A call with several results is legal only where the
// statement form explicitly expands it.
check_single_expr :: proc(k: ^Checker, e: Expr, expected: Type_Id = INVALID_TYPE) -> Type_Id {
	type := check_expr(k, e, expected)
	base := expr_base(e)
	if base != nil && len(base.result_types) > 1 {
		errorf(
			k.c,
			base.span,
			"L0382",
			"this call produces %d values, but one is expected here",
			len(base.result_types),
		)
		base.type = INVALID_TYPE
		return INVALID_TYPE
	}
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
		// configuration value, but never stored (m3-plan decision "Strings").
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

	// A nested procedure literal has no closure in M2 (m2-plan decision
	// "Procedure values"), so a name that lives in an enclosing procedure's
	// frame is rejected here rather than silently miscompiled.
	if owner != nil && owner.owner_proc != nil && owner.owner_proc != k.proc_literal {
		if sym.kind == .Var || sym.kind == .Parameter || sym.kind == .Result {
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
			check_decl(k, sym.decl)
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
		v.resolution = Resolution{kind = .Type, symbol = symbol_id}
		v.denoted_type = sym.type
		v.value_category = .Type
		v.type = TYPE_TYPE
		v.is_const = true
		v.const_value = type_const(sym.type)

	case .Proc:
		// A named procedure is a value with its interned procedure type; a call
		// obtains its results from the type, not from a single result field.
		// A signature the current phase has not reached yet is resolved on
		// demand, so an enum value or array length may call a procedure declared
		// later in the file.
		if sym.proc_type == INVALID_TYPE && sym.decl != nil {
			resolve_declaration_signature(k, sym.decl)
			sym = symbol_of(k.c, symbol_id)
		}
		v.resolution = Resolution{kind = .Value, symbol = symbol_id}
		v.value_category = .Value
		v.type = sym.proc_type

	case .Builtin:
		v.resolution = Resolution{kind = .Value, symbol = symbol_id}
		errorf(k.c, v.span, "L0316", "`%s` is a built-in procedure and must be called", name)
		v.type = INVALID_TYPE

	case .Const, .Enum_Member:
		v.resolution = Resolution{kind = .Value, symbol = symbol_id}
		v.value_category = .Value
		v.type = sym.type
		v.is_const = true
		v.const_value = sym.const_value
		v.immutable = .Constant

	case .Var, .Parameter, .Result:
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

	// `.Member`: the implicit enum selector, whose operand is the expected type.
	if v.operand == nil {
		enum_type := type_underlying(k.c, expected)
		if !type_is_enum(k.c, enum_type) {
			errorf(k.c, v.span, "L0385", "`.%s` needs an expected enum type here", v.name.text)
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
	// it first (m3-plan decision "Import symbols").
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

	// `p.field` through one pointer is the same selection as `p^.field`.
	base_type := type_underlying(k.c, operand)
	through_pointer := false
	if info := type_of(k.c, base_type); info != nil && info.kind == .Pointer {
		base_type = type_underlying(k.c, info.element)
		through_pointer = true
	}
	info := type_of(k.c, base_type)
	field := INVALID_SYMBOL
	if info != nil && info.kind == .Struct {
		field = struct_field(k.c, base_type, intern_identifier(k.c, v.name.text))
	}
	// design.md: "Field lookup takes priority over method-call sugar."
	if field == INVALID_SYMBOL {
		if select_method(k, v, operand, callee_position) {
			return
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
		v.assignable = true
		v.immutable = .None
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

// `Type.member`: an associated constant, an associated type, or a procedure
// reached through the type name.
@(private = "file")
select_associated_member :: proc(k: ^Checker, v: ^Expr_Selector, subject: Type_Id) -> bool {
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
		outer_scope, outer_pkg, outer_file := k.scope, k.pkg, k.file_node
		k.scope, k.pkg, k.file_node = target.scope, target.id, nil
		check_decl(k, symbol.decl)
		k.scope, k.pkg, k.file_node = outer_scope, outer_pkg, outer_file
	}
	annotate_symbol_use(k, &v.base, symbol_id, v.name.text)
}

// ---------------------------------------------------------------- indexing --

@(private = "file")
check_index :: proc(k: ^Checker, v: ^Expr_Index, place: bool) {
	v.value_category = .Value
	operand := check_single_expr(k, v.operand)
	if operand == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}

	base_type := type_underlying(k.c, operand)
	operand_base := expr_base(v.operand)
	through_pointer := false
	if info := type_of(k.c, base_type); info != nil && info.kind == .Pointer {
		base_type = type_underlying(k.c, info.element)
		through_pointer = true
	}
	info := type_of(k.c, base_type)
	// Built-in indexing first; a user `operator([])` supplies what it does not.
	indexable := info != nil && (info.kind == .Array || info.kind == .Slice)
	if !indexable || len(v.indices) != 1 {
		if check_user_index(k, v, operand, place) {
			return
		}
		if indexable {
			unsupported_construct(k, v.span)
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
		v.assignable = true
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
	// design.md: "Element assignment and iteration by reference require
	// `[]mut T`." A `[]T` element is a readable place and nothing more, so no
	// `^T` can be taken to it either.
	v.addressable = info.mutable
	v.assignable = info.mutable
	v.immutable = info.mutable ? .None : .Read_Only
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

	args, ok := index_arguments(k, v.operand, v.indices)
	if !ok {
		v.type = INVALID_TYPE
		return true
	}
	chosen, bound := resolve_operator(k, v.span, "[]", []Type_Id{operand}, args, among = candidates)
	if chosen == INVALID_SYMBOL || !check_operator_modes(k, chosen, bound) {
		v.type = INVALID_TYPE
		return true
	}
	sym := symbol_of(k.c, chosen)
	v.bound = bound
	v.resolution = Resolution{kind = .User_Operator, symbol = chosen, chosen_overload = chosen}
	v.type = len(sym.results) == 1 ? sym.results[0] : INVALID_TYPE
	if operator_result_is_place(k, chosen) {
		v.value_category = .Place
		v.addressable = true
		v.assignable = true
	}
	return true
}

// `operator([:])`. A built-in slice expression arrives with M5, so a type with
// no `[:]` overload is still the deferred family it was.
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
		unsupported_construct(k, v.span)
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
	if chosen == INVALID_SYMBOL || !check_operator_modes(k, chosen, bound) {
		v.type = INVALID_TYPE
		return
	}
	sym := symbol_of(k.c, chosen)
	v.bound = bound
	v.resolution = Resolution{kind = .User_Operator, symbol = chosen, chosen_overload = chosen}
	v.type = len(sym.results) == 1 ? sym.results[0] : INVALID_TYPE
}

// Slicing a built-in sequence: a fixed array or another slice. Returns false
// when the operand is neither, leaving the user `operator([:])` path to run.
//
// design.md "Slices": "Slicing a mutable, addressable array or dynamic array
// produces `[]mut T`; slicing an immutable parameter, a string, or an existing
// `[]T` produces `[]T`." Endpoints may be omitted; the low bound defaults to 0
// and the high bound to the base's length.
@(private = "file")
check_builtin_slice :: proc(k: ^Checker, v: ^Expr_Slice, operand: Type_Id) -> bool {
	info := type_of(k.c, type_underlying(k.c, operand))
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
index_arguments :: proc(k: ^Checker, receiver: Expr, indices: []Expr) -> ([]Arg_Info, bool) {
	args := make([]Arg_Info, len(indices) + 1, k.c.semantic_allocator)
	args[0] = arg_from_expr(k, receiver)
	args[0].is_receiver = true
	ok := true
	for index, position in indices {
		if check_single_expr(k, index) == INVALID_TYPE {
			ok = false
			continue
		}
		args[position + 1] = arg_from_expr(k, index)
	}
	return args, ok
}

// ------------------------------------------------------------------ unary --

@(private = "file")
check_unary :: proc(k: ^Checker, v: ^Expr_Unary, expected: Type_Id) {
	v.value_category = .Value

	if v.op == .Amp {
		// design.md: `&` is a place position for the purpose of overload
		// selection, but it never creates an element in any container.
		k.place_position = true
		operand := check_single_expr(k, v.operand, pointee_of(k.c, expected))
		k.place_position = false
		if operand == INVALID_TYPE {
			v.type = INVALID_TYPE
			return
		}
		operand_base := expr_base(v.operand)
		if !operand_base.addressable {
			errorf(k.c, v.op_span, "L0357", "`&` needs an addressable operand")
			v.type = INVALID_TYPE
			return
		}
		v.type = pointer_to(k.c, operand)
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
	if chosen == INVALID_SYMBOL || !check_operator_modes(k, chosen, bound) {
		v.type = INVALID_TYPE
		return true
	}
	sym := symbol_of(k.c, chosen)
	v.operand = bound[0]
	v.resolution = Resolution{kind = .User_Operator, symbol = chosen, chosen_overload = chosen}
	v.type = len(sym.results) == 1 ? sym.results[0] : INVALID_TYPE
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
	if chosen == INVALID_SYMBOL || !check_operator_modes(k, chosen, bound) {
		v.type = INVALID_TYPE
		return true
	}
	sym := symbol_of(k.c, chosen)
	v.lhs, v.rhs = bound[0], bound[1]
	v.negated = negate
	v.resolution = Resolution{kind = .User_Operator, symbol = chosen, chosen_overload = chosen}
	v.type = len(sym.results) == 1 ? sym.results[0] : INVALID_TYPE
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
	info := type_of(k.c, type_underlying(k.c, operand))
	if info == nil || info.kind != .Pointer {
		errorf(k.c, v.op_span, "L0355", "`^` needs a pointer, found `%s`", type_name(k.c, operand))
		v.type = INVALID_TYPE
		return
	}
	v.type = info.element
	v.value_category = .Place
	v.addressable = true
	v.assignable = true
}

// ----------------------------------------------------------------- binary --

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

	is_comparison := false
	#partial switch v.op {
	case .Eq_Eq, .Not_Eq, .Lt, .Lt_Eq, .Gt, .Gt_Eq:
		is_comparison = true
	}
	shift := v.op == .Shl || v.op == .Shr

	hint := is_comparison ? INVALID_TYPE : expected
	lhs := check_single_expr(k, v.lhs, hint)
	rhs := check_single_expr(k, v.rhs, shift ? INVALID_TYPE : hint)
	if lhs == INVALID_TYPE || rhs == INVALID_TYPE {
		v.type = INVALID_TYPE
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
		// design.md "Nil slices": "Slices can be compared against nil and nothing
		// else." Two slices may share a root, overlap, or view the same bytes at
		// different lengths, so element-wise equality would not mean what `==`
		// means anywhere else.
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

// design.md: `a && b` is "b if a else false", so the right operand is checked
// but only the selected value is folded.
@(private = "file")
check_logical :: proc(k: ^Checker, v: ^Expr_Binary) {
	lhs := check_single_expr(k, v.lhs, TYPE_BOOL)
	rhs := check_single_expr(k, v.rhs, TYPE_BOOL)
	if lhs == INVALID_TYPE || rhs == INVALID_TYPE {
		v.type = INVALID_TYPE
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

	count, fits := bi_to_u64(k.c, right.const_value.integer)
	if !fits || count > 1 << 20 {
		// An exact untyped result would need more storage than the compiler is
		// willing to spend; every runtime type saturates long before this.
		errorf(k.c, expr_span(v.rhs), "L0356", "shift count %s is too large to fold", bi_text(k.c, right.const_value.integer))
		v.type = INVALID_TYPE
		return
	}
	value := left.const_value.integer
	shifted := v.op == .Shl ? bi_shl(k.c, value, int(count)) : bi_shr(k.c, value, int(count))
	v.is_const = true
	v.const_value = Const_Value {
		kind    = left.const_value.kind,
		integer = wrap_to_type(k.c, shifted, v.type),
	}
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
	v.value_category = .Value

	// `#assert(...)` and `#config(...)` arrive through the ordinary call suffix,
	// and their callee is not a value at all.
	if hash, is_hash := v.callee.(^Expr_Hash); is_hash {
		check_hash_call(k, v, hash)
		return
	}

	// A built-in is not a value, so it is recognised before the callee is
	// checked as one.
	if ident, is_ident := v.callee.(^Expr_Ident); is_ident {
		symbol_id := lookup_symbol(k.scope, identifier_of(k.c, ident))
		if sym := symbol_of(k.c, symbol_id); sym != nil && sym.kind == .Builtin {
			check_builtin_call(k, v, ident, symbol_id)
			return
		}
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
	if sel, is_selector := v.callee.(^Expr_Selector); is_selector && callee_is_descriptor(k, sel.operand) {
		check_single_expr(k, sel.operand)
		if check_descriptor_operation(k, v, sel) {
			return
		}
	}

	outer_callee := k.in_callee
	k.in_callee = true
	callee_type := check_expr(k, v.callee)
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

	info := type_of(k.c, type_underlying(k.c, callee_type))
	if info == nil || info.kind != .Proc {
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
	v.resolution = Resolution{kind = .Call, symbol = declaration, chosen_overload = declaration}

	if !bind_arguments(k, v, info, declaration) {
		v.type = INVALID_TYPE
		return
	}

	switch len(info.results) {
	case 0:
		v.type = TYPE_VOID
	case 1:
		v.type = info.results[0]
	case:
		v.type = info.results[0]
		v.result_types = info.results
	}
}

// The procedure group a callee names, or INVALID_SYMBOL. `pkg.group` names one
// as plainly as `group` does.
@(private = "file")
callee_group :: proc(k: ^Checker, callee: Expr) -> Symbol_Id {
	#partial switch v in callee {
	case ^Expr_Ident:
		id := lookup_symbol(k.scope, identifier_of(k.c, v))
		if sym := symbol_of(k.c, id); sym != nil && sym.kind == .Proc_Group {
			return id
		}
	case ^Expr_Selector:
		ident, is_ident := v.operand.(^Expr_Ident)
		if !is_ident {
			return INVALID_SYMBOL
		}
		alias := symbol_of(k.c, lookup_symbol(k.scope, identifier_of(k.c, ident)))
		if alias == nil || alias.kind != .Package_Alias {
			return INVALID_SYMBOL
		}
		target := package_of(k.c, alias.pkg)
		if target == nil || target.scope == nil {
			return INVALID_SYMBOL
		}
		member, found := target.scope.names[intern_identifier(k.c, v.name.text)]
		if !found {
			return INVALID_SYMBOL
		}
		if sym := symbol_of(k.c, member); sym != nil && sym.kind == .Proc_Group && sym.public {
			return member
		}
	}
	return INVALID_SYMBOL
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

// `value.method(args)`. The receiver is argument zero and carries its mode
// implicitly, which is what makes `inout self` and `move self` reachable through
// one spelling (design.md "Receiver forms").
@(private = "file")
check_method_call :: proc(k: ^Checker, v: ^Expr_Call, sel: ^Expr_Selector, expected: Type_Id) {
	receiver := sel.operand
	receiver_base := expr_base(receiver)
	candidates := method_candidates(k, receiver_base.type, intern_identifier(k.c, sel.name.text))
	written, args_ok := collect_call_arguments(k, v.args)
	if !args_ok {
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
	// An exclusive mutable borrow, or a consuming receiver, needs a mutable place.
	if chosen.receiver == .Inout || chosen.receiver == .Move {
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
	switch len(chosen.results) {
	case 0:
		v.type = TYPE_VOID
	case 1:
		v.type = chosen.results[0]
	case:
		v.type = chosen.results[0]
		v.result_types = chosen.results
	}
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
	args, args_ok := collect_call_arguments(k, v.args)
	if !args_ok {
		v.type = INVALID_TYPE
		return
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
	switch len(chosen.results) {
	case 0:
		v.type = TYPE_VOID
	case 1:
		v.type = chosen.results[0]
	case:
		v.type = chosen.results[0]
		v.result_types = chosen.results
	}
}

// Rewrites the callee to name the selected overload, so every later phase — the
// backend included — sees an ordinary call to one procedure.
annotate_chosen_callee :: proc(k: ^Checker, v: ^Expr_Call, chosen: Symbol_Id) {
	sym := symbol_of(k.c, chosen)
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

@(private = "file")
check_builtin_call :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident, symbol_id: Symbol_Id) {
	sym := symbol_of(k.c, symbol_id)
	ident.symbol = symbol_id
	ident.resolution = Resolution{kind = .Value, symbol = symbol_id}
	ident.type = sym.proc_type
	v.resolution = Resolution{kind = .Call, symbol = symbol_id, chosen_overload = symbol_id}

	// Exhaustive on purpose: a built-in with no arm here would fall through to
	// the ordinary parameter path and be emitted as `print_int`.
	switch sym.builtin {
	case .Assert, .Panic:
		check_assert_or_panic(k, v, ident, sym.builtin)
		return
	case .Size_Of, .Align_Of, .Offset_Of, .Len:
		check_layout_builtin(k, v, ident, sym.builtin)
		return
	case .Hash:
		check_hash_builtin(k, v, ident)
		return
	case .Type_Of, .Typeid_Of, .Fields_Of, .Enum_Values_Of:
		check_reflection_builtin(k, v, ident, sym.builtin)
		return
	case .Iter:
		check_iter_builtin(k, v, ident)
		return
	case .New, .New_Clone, .Free, .Free_All:
		check_allocation_builtin(k, v, ident, sym.builtin)
		return
	case .Drop:
		check_drop_builtin(k, v, ident)
		return
	case .Exchange:
		check_exchange_builtin(k, v, ident)
		return
	case .Default_Allocator:
		if len(v.args) != 0 {
			errorf(k.c, v.span, "L0490", "`default_allocator` takes no arguments")
			v.type = INVALID_TYPE
			return
		}
		v.bound = nil
		v.type = TYPE_ALLOCATOR
		return
	case .Print_Int:
		// Checked against its declared parameters, just below.
	case .None:
		unsupported_construct(k, v.span)
		v.type = INVALID_TYPE
		return
	}

	if len(v.args) != len(sym.params) {
		errorf(
			k.c,
			v.span,
			"L0322",
			"`%s` takes %d argument%s, found %d",
			ident.name,
			len(sym.params),
			len(sym.params) == 1 ? "" : "s",
			len(v.args),
		)
		v.type = INVALID_TYPE
		return
	}
	bound := make([]Expr, len(sym.params), k.c.semantic_allocator)
	for arg, index in v.args {
		if arg.name.text != "" || arg.mode != .Value {
			unsupported_construct(k, arg.span)
			continue
		}
		bound[index] = arg.value
		check_value_expr(k, arg.value, sym.params[index], "pass")
	}
	v.bound = bound
	v.type = sym.type
}

// `assert(condition[, message])` and `panic([message])`. Both produce no value
// and both are legal in either phase, so neither is folded here: the evaluator
// diagnoses the compile-time occurrence and the backend lowers the runtime one
// to the trap seam.
@(private = "file")
check_assert_or_panic :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident, kind: Builtin_Kind) {
	v.type = TYPE_VOID
	first := kind == .Assert ? 1 : 0
	if len(v.args) < first || len(v.args) > first + 1 {
		errorf(
			k.c,
			v.span,
			"L0322",
			"`%s` takes %s, found %d",
			ident.name,
			kind == .Assert ? "a condition and an optional message" : "an optional message",
			len(v.args),
		)
		v.type = INVALID_TYPE
		return
	}
	bound := make([]Expr, len(v.args), k.c.semantic_allocator)
	for arg, index in v.args {
		if arg.name.text != "" || arg.mode != .Value {
			unsupported_construct(k, arg.span)
			continue
		}
		bound[index] = arg.value
		if kind == .Assert && index == 0 {
			check_condition(k, arg.value)
			continue
		}
		check_message_arg(k, arg.value)
	}
	v.bound = bound
}

// `#assert(condition[, message])` and `#config(NAME, default)`. Both are
// compile-time-only forms, so each produces its answer here and nothing is left
// for the backend.
@(private = "file")
check_hash_call :: proc(k: ^Checker, v: ^Expr_Call, hash: ^Expr_Hash) {
	hash.type = TYPE_VOID
	switch hash.name {
	case "#assert":
		v.type = TYPE_VOID
		v.value_category = .Value
		if len(v.args) < 1 || len(v.args) > 2 {
			errorf(k.c, v.span, "L0387", "`#assert` takes a condition and an optional message")
			v.type = INVALID_TYPE
			return
		}
		check_condition(k, v.args[0].value)
		message := ""
		if len(v.args) == 2 {
			check_message_arg(k, v.args[1].value)
			if base := expr_base(v.args[1].value); base != nil && base.const_value.kind == .String {
				message = concat(k.c, ": ", base.const_value.text)
			}
		}
		folded, evaluated := require_const(k, v.args[0].value, "a `#assert` condition", "L0387")
		if !evaluated {
			v.type = INVALID_TYPE
			return
		}
		if folded.kind == .Boolean && !folded.boolean {
			errorf(k.c, v.span, "L0387", "static assertion failed%s", message)
		}

	case "#config":
		check_config(k, v)

	case:
		// `#location` and `#caller_location` need a runtime `string` and
		// `runtime.Source_Code_Location`, which arrive with the seed runtime.
		errorf(k.c, v.span, "L0390", "`%s` needs the runtime source-location type, which arrives in M6", hash.name)
		v.type = INVALID_TYPE
	}
}

// `#config(NAME, default)`: the name is a token, not a lexical value, and the
// default fixes both the result's type and what an override may say.
@(private = "file")
check_config :: proc(k: ^Checker, v: ^Expr_Call) {
	v.value_category = .Value
	if len(v.args) != 2 {
		errorf(k.c, v.span, "L0388", "`#config` takes a name and a default value")
		v.type = INVALID_TYPE
		return
	}
	name, is_ident := v.args[0].value.(^Expr_Ident)
	if !is_ident {
		errorf(k.c, expr_span(v.args[0].value), "L0388", "`#config` needs a name")
		v.type = INVALID_TYPE
		return
	}
	if check_single_expr(k, v.args[1].value) == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}
	fallback, evaluated := require_const(k, v.args[1].value, "a `#config` default", "L0388")
	if !evaluated {
		v.type = INVALID_TYPE
		return
	}
	#partial switch fallback.kind {
	case .Boolean, .Integer, .String:
	case:
		errorf(k.c, expr_span(v.args[1].value), "L0388", "a `#config` default must be a boolean, an integer, or a string")
		v.type = INVALID_TYPE
		return
	}

	v.type = expr_base(v.args[1].value).type
	v.is_const = true
	v.const_value = fallback
	override, defined := k.c.defines[name.name]
	if !defined {
		return
	}
	if override.kind != fallback.kind {
		errorf(
			k.c,
			v.span,
			"L0388",
			"`-define:%s=` gives %s, but this `#config` defaults to %s",
			name.name,
			const_kind_name(override.kind),
			const_kind_name(fallback.kind),
		)
		return
	}
	if fallback.kind == .Integer && !type_is_untyped(k.c, v.type) {
		if !bi_fits(k.c, override.integer, type_bits(k.c, v.type), type_signed(k.c, v.type)) {
			errorf(
				k.c,
				v.span,
				"L0388",
				"`-define:%s=%s` is not representable by `%s`",
				name.name,
				bi_text(k.c, override.integer),
				type_name(k.c, v.type),
			)
			return
		}
	}
	v.const_value = override
}

const_kind_name :: proc(kind: Const_Kind) -> string {
	#partial switch kind {
	case .Boolean:
		return "a boolean"
	case .Integer:
		return "an integer"
	case .String:
		return "a string"
	}
	return "a value"
}

// `size_of`, `align_of`, `offset_of`, and `len`. Every one of these inspects
// static type or declaration information, so nothing here is evaluated: the
// operand is resolved and type-checked, never read, and never required to be
// live (m3-plan decision "Unevaluated layout operands").
@(private = "file")
check_layout_builtin :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident, kind: Builtin_Kind) {
	v.type = TYPE_INT
	arity := kind == .Offset_Of ? 2 : 1
	if len(v.args) != arity {
		errorf(
			k.c,
			v.span,
			"L0322",
			"`%s` takes %d argument%s, found %d",
			ident.name,
			arity,
			arity == 1 ? "" : "s",
			len(v.args),
		)
		v.type = INVALID_TYPE
		return
	}
	for arg in v.args {
		if arg.name.text != "" || arg.mode != .Value {
			unsupported_construct(k, arg.span)
			v.type = INVALID_TYPE
			return
		}
	}
	// The call is folded, so nothing here reaches the backend; binding the
	// operand would only invite it to be emitted.
	v.bound = nil

	operand := layout_operand_type(k, v.args[0].value, kind)
	if operand == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}
	// design.md "Slices": "Its length is a runtime value." So this one does not
	// fold — it reads the slice's second word.
	if kind == .Len && type_is_slice(k.c, operand) {
		bound := make([]Expr, 1, k.c.semantic_allocator)
		bound[0] = v.args[0].value
		v.bound = bound
		v.type = TYPE_INT
		return
	}
	// A compile-time string has a length but no runtime type to gate, so it is
	// answered before the type is inspected.
	if kind == .Len && operand == TYPE_UNTYPED_STRING {
		base := expr_base(v.args[0].value)
		if !base.is_const || base.const_value.kind != .String {
			errorf(k.c, v.span, "L0386", "`len` needs a compile-time string here")
			v.type = INVALID_TYPE
			return
		}
		v.is_const = true
		v.const_value = int_const(k.c, i64(len(base.const_value.text)))
		return
	}
	if !gate_type(k, operand, expr_span(v.args[0].value)) {
		v.type = INVALID_TYPE
		return
	}

	result := u64(0)
	switch kind {
	case .Size_Of:
		result = type_size(k.c, operand)
	case .Align_Of:
		result = type_align(k.c, operand)
	case .Len:
		info := type_of(k.c, type_underlying(k.c, operand))
		if info == nil || info.kind != .Array {
			errorf(k.c, v.span, "L0386", "`len` needs a fixed array, found `%s`", type_name(k.c, operand))
			v.type = INVALID_TYPE
			return
		}
		result = info.count
	case .Offset_Of:
		// The second operand is a member name, not a lexical value expression:
		// resolving it as one would find an unrelated variable of the same name.
		name, is_ident := v.args[1].value.(^Expr_Ident)
		if !is_ident {
			errorf(k.c, expr_span(v.args[1].value), "L0386", "`offset_of` needs a field name")
			v.type = INVALID_TYPE
			return
		}
		field := struct_field(k.c, operand, intern_identifier(k.c, name.name))
		if field == INVALID_SYMBOL {
			errorf(k.c, name.span, "L0363", "`%s` has no field `%s`", type_name(k.c, operand), name.name)
			v.type = INVALID_TYPE
			return
		}
		if !require_visible_field(k, name.span, operand, field, "L0472", "measured with `offset_of`") {
			v.type = INVALID_TYPE
			return
		}
		symbol := symbol_of(k.c, field)
		name.symbol = field
		name.resolution = Resolution{kind = .Field, symbol = field}
		result = type_field_offset(k.c, operand, int(symbol.index))
	case .New, .New_Clone, .Free, .Free_All, .Default_Allocator, .Drop, .Exchange,
	     .None, .Print_Int, .Assert, .Panic, .Hash, .Iter,
	     .Type_Of, .Typeid_Of, .Fields_Of, .Enum_Values_Of:
		return
	}
	v.is_const = true
	v.const_value = int_const(k.c, i64(result))
}

// The type a layout operand denotes: a written type, or the type of an
// expression that is checked exactly once and never evaluated. `len` keeps an
// untyped string as itself, because the length is in the value.
@(private = "file")
layout_operand_type :: proc(k: ^Checker, e: Expr, kind: Builtin_Kind) -> Type_Id {
	if e == nil {
		return INVALID_TYPE
	}
	if denoted := resolve_type_syntax(k, e); denoted != INVALID_TYPE {
		return denoted
	}
	if check_single_expr(k, e) == INVALID_TYPE {
		return INVALID_TYPE
	}
	base := expr_base(e)
	if base.value_category == .Type {
		return base.denoted_type
	}
	if kind == .Len && base.type == TYPE_UNTYPED_STRING {
		return TYPE_UNTYPED_STRING
	}
	return base.type
}

// design.md "Allocators" and "Allocation failure". `new` and `new_clone` are
// explicitly fallible and always return their error rather than invoking a
// failure policy; `free` returns no status.
//
//   new(T)             -> (^T, Allocator_Error)
//   new(T, allocator)  -> (^T, Allocator_Error)
//   new_clone(value)   -> (^T, Allocator_Error)
//   free(pointer)
//   free_all(allocator)
//
// An omitted allocator argument is the default provider, which the compiler
// supplies until `core:mem` is nameable in M6.
@(private = "file")
check_allocation_builtin :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident, kind: Builtin_Kind) {
	arity_low, arity_high := 1, 2
	if kind == .Free || kind == .Free_All {
		arity_high = 1
	}
	if len(v.args) < arity_low || len(v.args) > arity_high {
		errorf(
			k.c,
			v.span,
			"L0490",
			"`%s` takes %s",
			ident.name,
			arity_high == 1 ? "one argument" : "an operand and an optional allocator",
		)
		v.type = INVALID_TYPE
		return
	}
	for arg in v.args {
		if arg.name.text != "" || arg.mode != .Value {
			unsupported_construct(k, arg.span)
			v.type = INVALID_TYPE
			return
		}
	}

	bound := make([dynamic]Expr, 0, 2, k.c.semantic_allocator)
	switch kind {
	case .New:
		// The operand is a type, inspected rather than evaluated, exactly as the
		// layout built-ins treat theirs.
		element := layout_operand_type(k, v.args[0].value, kind)
		if element == INVALID_TYPE || !gate_type(k, element, expr_span(v.args[0].value)) {
			v.type = INVALID_TYPE
			return
		}
		if type_is_compile_time_only(k.c, element) {
			errorf(k.c, expr_span(v.args[0].value), "L0490", "`new` needs a runtime type, found `%s`", type_name(k.c, element))
			v.type = INVALID_TYPE
			return
		}
		v.alloc_type = element
		set_allocation_results(k, v, pointer_to(k.c, element))

	case .New_Clone:
		value := check_single_expr(k, v.args[0].value)
		if value == INVALID_TYPE || !gate_type(k, value, expr_span(v.args[0].value)) {
			v.type = INVALID_TYPE
			return
		}
		// An untyped constant operand has no representation to allocate for, so it
		// takes its default type first. Without this the allocation is sized from
		// the untyped type and comes out zero.
		if type_is_untyped(k.c, value) {
			value = default_type(k.c, value)
			if value == INVALID_TYPE || !materialize(k, v.args[0].value, value) {
				v.type = INVALID_TYPE
				return
			}
		}
		append(&bound, v.args[0].value)
		v.alloc_type = value
		// design.md: `new_clone` "creates a new allocation root containing a clone
		// of the value", so the operand's own copy hook has to exist by emission.
		contribute_lifecycle_members(k, value)
		// The result shape is settled before the copyability complaint, so a
		// `p, err := new_clone(x)` destructuring still knows its arity and the
		// failure is reported once.
		set_allocation_results(k, v, pointer_to(k.c, value))
		if type_clone_disabled(k.c, value) {
			errorf(
				k.c,
				expr_span(v.args[0].value),
				"L0491",
				"`%s` disables `try_clone`, so it cannot be cloned into a new allocation",
				type_name(k.c, value),
			)
		}

	case .Free:
		pointer := check_single_expr(k, v.args[0].value)
		if pointer == INVALID_TYPE {
			v.type = INVALID_TYPE
			return
		}
		if !check_free_operand(k, v.args[0].value, pointer) {
			v.type = INVALID_TYPE
			return
		}
		append(&bound, v.args[0].value)
		v.type = TYPE_VOID

	case .Free_All:
		allocator := check_single_expr(k, v.args[0].value, TYPE_ALLOCATOR)
		if allocator != INVALID_TYPE && type_underlying(k.c, allocator) != TYPE_ALLOCATOR {
			errorf(k.c, expr_span(v.args[0].value), "L0490", "`free_all` names the allocator being reset, found `%s`", type_name(k.c, allocator))
		}
		// design.md: "The compiler rejects `free_all`, or any call carrying the
		// same allocator-reset effect, while a live owning value (managed or
		// manual) or borrow still refers to storage from that allocator." That
		// liveness proof is M5b's region analysis, so the call is registered and
		// type-checked here and gated before lowering.
		errorf(
			k.c,
			v.span,
			"L0492",
			"`free_all` is not lowered until M5b: a region reset needs the region analysis that proves no live owner or borrow depends on it",
		)
		v.type = INVALID_TYPE
		return

	case .None, .Print_Int, .Assert, .Panic, .Size_Of, .Align_Of, .Offset_Of, .Len,
	     .Hash, .Type_Of, .Typeid_Of, .Fields_Of, .Enum_Values_Of, .Iter, .Default_Allocator, .Drop,
	     .Exchange:
		return
	}

	// The allocator argument, written or supplied. Keeping it bound means the
	// backend never has to re-derive which provider a call selected.
	if len(v.args) == 2 {
		allocator := check_single_expr(k, v.args[1].value, TYPE_ALLOCATOR)
		if allocator != INVALID_TYPE && type_underlying(k.c, allocator) != TYPE_ALLOCATOR {
			errorf(
				k.c,
				expr_span(v.args[1].value),
				"L0490",
				"an allocator argument is an `Allocator`, found `%s`",
				type_name(k.c, allocator),
			)
			v.type = INVALID_TYPE
			return
		}
		append(&bound, v.args[1].value)
	}
	v.bound = bound[:]
}

@(private = "file")
set_allocation_results :: proc(k: ^Checker, v: ^Expr_Call, pointer: Type_Id) {
	results := make([]Type_Id, 2, k.c.semantic_allocator)
	results[0] = pointer
	results[1] = TYPE_ALLOCATOR_ERROR
	v.result_types = results
	v.type = pointer
	v.value_category = .Value
}

// design.md: "passing `free` the wrong allocation or allocator is a programmer
// error". M5a narrows that to what it can prove without root provenance: the
// operand must be a binding whose initialiser is a direct `new`/`new_clone`
// result. M5b replaces this with propagated allocation identity across pointer
// copies, and adds the liveness half (m5a-plan step 3).
@(private = "file")
check_free_operand :: proc(k: ^Checker, e: Expr, pointer: Type_Id) -> bool {
	if type_kind(k.c, type_underlying(k.c, pointer)) != .Pointer {
		errorf(k.c, expr_span(e), "L0493", "`free` takes an allocation pointer, found `%s`", type_name(k.c, pointer))
		return false
	}
	ident, is_ident := e.(^Expr_Ident)
	if !is_ident || !symbol_is_allocation_root(k, ident.symbol) {
		errorf(
			k.c,
			expr_span(e),
			"L0493",
			"M5a frees only a binding initialised directly by `new` or `new_clone`; propagating an allocation root through pointer copies and derived views is M5b",
		)
		return false
	}
	return true
}

// design.md: an `assert`/`panic` message is a compile-time string in M3; M6
// turns it into a runtime panic message.
@(private = "file")
check_message_arg :: proc(k: ^Checker, e: Expr) {
	if check_single_expr(k, e) == INVALID_TYPE {
		return
	}
	base := expr_base(e)
	if !base.is_const || base.const_value.kind != .String {
		errorf(k.c, expr_span(e), "L0345", "this message must be a compile-time string")
	}
}

// One argument against one parameter, with the `@(implicit)` path for an
// untyped constant that no built-in conversion reaches. Returns the expression
// to bind, which is the written one unless a conversion wrapped it.
check_argument_value :: proc(k: ^Checker, e: Expr, target: Type_Id) -> (Expr, bool) {
	type := check_single_expr(k, e, target)
	if type == INVALID_TYPE || target == INVALID_TYPE {
		return e, false
	}
	if type_is_untyped(k.c, type) && !assignable(k.c, type, target) {
		arg := arg_from_expr(k, e)
		overload, applicable := implicit_init_overload(k, arg, target, report = true)
		if overload != INVALID_SYMBOL {
			return wrap_implicit_conversion(k, e, overload), true
		}
		if applicable {
			return e, false
		}
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
	bound := make([]Expr, count, k.c.semantic_allocator)
	modes := make([]Argument_Mode, count, k.c.semantic_allocator)
	filled := make([]bool, count, k.c.semantic_allocator)
	declared := symbol_of(k.c, declaration)
	ok := true
	named := false

	for arg, index in v.args {
		if arg.mode == .Spread {
			unsupported_construct(k, arg.span)
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
			slot = -1
			target := intern_identifier(k.c, arg.name.text)
			for symbol_id, position in declared.param_symbols {
				if symbol := symbol_of(k.c, symbol_id); symbol != nil && symbol.name == target {
					slot = position
					break
				}
			}
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
		bound[slot] = arg.value
		modes[slot] = arg.mode
		expected_mode := slot < len(info.param_modes) ? info.param_modes[slot] : Param_Mode.Value
		if expected_mode == .Inout && arg.mode != .Inout {
			errorf(k.c, arg.span, "L0370", "this parameter is `inout`; write `inout` at the call site")
			ok = false
			continue
		}
		if expected_mode != .Inout && arg.mode == .Inout {
			errorf(k.c, arg.span, "L0370", "this parameter is not `inout`")
			ok = false
			continue
		}
		value, passed := check_argument_value(k, arg.value, info.parameters[slot])
		bound[slot] = value
		if !passed {
			ok = false
			continue
		}
		if arg.mode == .Inout {
			base := expr_base(value)
			if !base.assignable {
				report_not_assignable(k, base, "an `inout` argument")
				ok = false
			}
		}
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
		bound[index] = declared.param_defaults[index]
	}

	v.bound = bound
	require_argument_ownership(k, v, declaration)
	return ok
}

// `T(...)`, in the two stages design.md "Resolving `T(...)`" fixes: a built-in
// or `distinct` conversion first, and `init` overloads otherwise. Resolution
// stops at the first stage that produces a match, so `int(x)` cannot change
// meaning based on imports.
@(private = "file")
check_conversion :: proc(k: ^Checker, v: ^Expr_Call, target: Type_Id) {
	if !gate_type(k, target, v.span) {
		v.type = INVALID_TYPE
		return
	}
	if conversion_target_is_builtin(k, target) &&
	   len(v.args) == 1 && v.args[0].name.text == "" && v.args[0].mode == .Value {
		source := check_single_expr(k, v.args[0].value, target)
		if source == INVALID_TYPE {
			v.type = INVALID_TYPE
			return
		}
		if builtin_conversion(k, v, target, source) {
			return
		}
		one := make([]Arg_Info, 1, k.c.semantic_allocator)
		one[0] = arg_from_expr(k, v.args[0].value)
		check_init_call(k, v, target, one, source)
		return
	}
	args, ok := collect_call_arguments(k, v.args)
	if !ok {
		v.type = INVALID_TYPE
		return
	}
	// Unwrapping a distinct value is a built-in conversion even when its
	// underlying target is an aggregate. Keep this after argument collection so
	// ordinary aggregate construction still reaches `init` overloads.
	if len(args) == 1 && args[0].name == INVALID_IDENTIFIER && args[0].mode == .Value &&
	   type_kind(k.c, args[0].type) == .Distinct &&
	   type_underlying(k.c, args[0].type) == target &&
	   builtin_conversion(k, v, target, args[0].type) {
		return
	}
	check_init_call(k, v, target, args, INVALID_TYPE)
}

// Stage 1's predicate. A `distinct` type is grouped with the built-ins here —
// and only here: for operator lookup it is an ordinary user type
// (m4a-plan decision "Built-in priority").
@(private = "file")
conversion_target_is_builtin :: proc(k: ^Checker, target: Type_Id) -> bool {
	#partial switch type_kind(k.c, target) {
	case .Struct, .Union, .Interface, .Dyn, .Invalid:
		return false
	}
	return true
}

// The built-in half of `T(v)`, including pointer and `distinct` conversions.
// Returns false — without reporting — when no built-in conversion reaches the
// target, which is what lets stage 2 run.
@(private = "file")
builtin_conversion :: proc(k: ^Checker, v: ^Expr_Call, target, source: Type_Id) -> bool {
	base := expr_base(v.args[0].value)
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

// Stage 2: the visible `init` overloads for `T`, resolved by the ordinary
// engine. `attempted` is the source type stage 1 rejected, so a target with no
// `init` at all still reports the conversion failure the user wrote.
@(private = "file")
check_init_call :: proc(k: ^Checker, v: ^Expr_Call, target: Type_Id, args: []Arg_Info, attempted: Type_Id) {
	usable := make([dynamic]Symbol_Id, 0, 4, k.c.semantic_allocator)
	for candidate in member_candidates(k, target, intern_identifier(k.c, "init")) {
		sym := symbol_of(k.c, candidate)
		if sym != nil && !sym.has_receiver && len(sym.results) == 1 && sym.results[0] == target {
			append(&usable, candidate)
		}
	}
	if len(usable) == 0 {
		if attempted != INVALID_TYPE {
			errorf(
				k.c,
				expr_span(v.args[0].value),
				"L0373",
				"`%s` cannot be converted to `%s`",
				type_name(k.c, attempted),
				type_name(k.c, target),
			)
		} else {
			errorf(k.c, v.span, "L0410", "`%s` has no `init` overload to construct it", type_name(k.c, target))
		}
		v.type = INVALID_TYPE
		return
	}
	description := concat(k.c, "`", concat(k.c, type_name(k.c, target), "`'s `init`"))
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
	if v.bodiless || len(v.where_clauses) > 0 || v.signature == nil {
		unsupported_construct(k, v.span)
		v.type = INVALID_TYPE
		return
	}
	if v.symbol == INVALID_SYMBOL {
		name := identifier_text(k.c, intern_identifier(k.c, "proc_literal"))
		_ = name
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
	if pkg := package_of(k.c, k.pkg); pkg != nil {
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
			unsupported_construct(k, expr_span(v.type_expr))
			v.type = INVALID_TYPE
			return
		}
		array.denoted_type = array_of(k.c, element, u64(len(v.elements)))
		array.resolution.kind = .Type
		target = array.denoted_type
	} else if v.type_expr != nil {
		target = resolve_type_syntax(k, v.type_expr)
		if target == INVALID_TYPE {
			unsupported_construct(k, expr_span(v.type_expr))
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
	// an assignment destination (m2-plan decision "Place model").
	v.addressable = true
	v.assignable = false
	v.immutable = .Temporary

	#partial switch info.kind {
	case .Struct:
		check_struct_literal(k, v, target, info)
	case .Array:
		check_array_literal(k, v, target, info)
	case .Slice:
		check_slice_literal(k, v, target, info)
	case:
		errorf(k.c, v.span, "L0376", "`%s` cannot be built from a composite literal", type_name(k.c, target))
		v.type = INVALID_TYPE
	}
}

// design.md "Slice literals": "A slice literal has the type it is written with."
// `[]T{...}` produces `[]T` and `[]mut T{...}` produces `[]mut T`; the capability
// is never inferred against the spelling. The elements go into a hidden
// fixed-array owner in the surrounding lexical scope, which is what the slice
// then views.
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
			if !check_value_expr(k, element.value, symbol.type, "initialise") {
				ok = false
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
		// design.md: "Positional aggregate construction does not bypass this rule:
		// an initializer that supplies an inaccessible field is rejected." Omitted
		// trailing fields still zero-fill, so this rejects supplying one, not
		// declaring one.
		if !require_visible_field(k, element.span, target, info.fields[index], "L0474", "initialised positionally") {
			ok = false
			continue
		}
		symbol := symbol_of(k.c, info.fields[index])
		seen[index] = true
		values[index] = element.value
		if !check_value_expr(k, element.value, symbol.type, "initialise") {
			ok = false
		}
	}
	if !ok {
		return
	}
	fold_aggregate(k, v, target, values, info.fields)
}

@(private = "file")
check_array_literal :: proc(k: ^Checker, v: ^Expr_Composite, target: Type_Id, info: ^Type_Info) {
	count := int(info.count)
	values := make([]Expr, count, k.c.semantic_allocator)
	ok := true
	for element, index in v.elements {
		if element.key != nil {
			unsupported_construct(k, element.span)
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
		}
	}
	if ok {
		fold_aggregate(k, v, target, values, nil)
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
				element_type = type_of(k.c, type_underlying(k.c, target)).element
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
	case .Pointer, .Raw_Pointer, .Proc, .Union, .Allocator, .Allocator_Error:
		return nil_const(), true
	case .Array:
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
	case .Struct, .Any_View, .Dyn, .Slice:
		// The zero value of an erased view is nil: a null pointer pair. A nil slice
		// is the same shape — a null pointer and a zero length (design.md "Nil
		// slices").
		ensure_slice_fields(c, under)
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
	// design.md "Unions": a variant value becomes a union value at the point of
	// use, which is where the tag can be written.
	if type_is_union(k.c, target) && base.type != target {
		if union_holds(k.c, target, base.type) {
			base.union_from = base.type
			base.type = target
			return true
		}
		// An untyped constant enters through its own default type, so which
		// variant it lands in never depends on the order the variants are written.
		if type_is_untyped(k.c, base.type) && base.type != TYPE_UNTYPED_NIL {
			variant := default_type(k.c, base.type)
			if union_holds(k.c, target, variant) && materialize(k, e, variant) {
				base.union_from = variant
				base.type = target
				return true
			}
		}
	}
	// design.md "any_view type": the conversion is implicit at an `any_view`
	// destination. The concrete type is kept so the backend knows what to take
	// the address of and which `typeid` to pair with it.
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
		target := merged
		converted, fits := convert_const(k.c, base.const_value, target, false)
		if !fits {
			return true
		}
		base.type = target
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
convert_const :: proc(c: ^Compiler, value: Const_Value, target: Type_Id, explicit: bool) -> (Const_Value, bool) {
	info := type_of(c, type_underlying(c, target))
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
			return float_const(bi_to_f64(c, value.integer), 64), true
		}
	case .Untyped_Bool:
		if value.kind == .Boolean {
			return value, true
		}
	case .Untyped_Nil:
		if value.kind == .Nil {
			return value, true
		}
	case .Untyped_String, .String:
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
			if !bi_fits(c, value.integer, bits, signed) {
				return value, false
			}
			return Const_Value{kind = .Integer, integer = value.integer}, true
		case .Float:
			truncated, exact, ok := bi_from_f64_trunc(c, value.float)
			if !ok || (!explicit && !exact) {
				return value, false
			}
			if !bi_fits(c, truncated, bits, signed) {
				return value, false
			}
			return Const_Value{kind = .Integer, integer = truncated}, true
		}
	case .Rune:
		#partial switch value.kind {
		case .Integer, .Rune:
			if !bi_fits(c, value.integer, 32, true) {
				return value, false
			}
			return Const_Value{kind = .Rune, integer = value.integer}, true
		}
	case .Float:
		#partial switch value.kind {
		case .Float:
			return float_const(value.float, info.bits), true
		case .Integer, .Rune:
			return float_const(bi_to_f64(c, value.integer), info.bits), true
		}
	case .Pointer, .Raw_Pointer, .Proc, .Allocator, .Allocator_Error:
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
	case .Struct, .Array:
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
		#partial switch type_kind(c, type_underlying(c, to)) {
		case .Pointer, .Raw_Pointer, .Proc, .Union, .Dyn, .Any_View, .Slice,
		     .Allocator, .Allocator_Error:
			// The zero value of every erased view is nil, and so is a slice's
			// (design.md "Nil slices"). A nil `Allocator_Error` is success.
			return true
		}
		return false
	}
	// design.md: "A mutable slice implicitly weakens to a read-only slice. A
	// read-only slice never converts to a mutable slice."
	if slice_weakens_to(c, from, to) {
		return true
	}
	// design.md "Unions": a union is assignable from any variant it can hold.
	if type_kind(c, to) == .Union && union_holds(c, to, from) {
		return true
	}
	if from == TYPE_UNTYPED_STRING {
		return type_kind(c, type_underlying(c, to)) == .String
	}
	if type_is_untyped(c, from) {
		#partial switch type_kind(c, type_underlying(c, to)) {
		case .Int, .Float, .Rune, .Bool, .Enum:
			return true
		}
		return false
	}
	// Any pointer converts to `rawptr` without a written conversion; the reverse
	// needs one.
	if to == TYPE_RAWPTR && type_kind(c, type_underlying(c, from)) == .Pointer {
		return true
	}
	// design.md: conversion from a concrete value to `any_view` is implicit when
	// an `any_view` destination is expected, and never allocates.
	if to == TYPE_ANY_VIEW && any_view_accepts(c, from) {
		return true
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
	if source == dest {
		return true // between a distinct type and what it wraps, either way
	}
	source_kind, dest_kind := type_kind(c, source), type_kind(c, dest)

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
		case .Pointer, .Raw_Pointer:
			return true
		}
		return false
	}
	if pointerish(source_kind) && pointerish(dest_kind) {
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
	info := type_of(c, type_underlying(c, type))
	if info == nil || info.kind != .Pointer {
		return INVALID_TYPE
	}
	return info.element
}

struct_field :: proc(c: ^Compiler, type: Type_Id, name: Identifier_Id) -> Symbol_Id {
	info := type_of(c, type_underlying(c, type))
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

operator_text :: proc(op: Token_Kind) -> string {
	#partial switch op {
	case .Plus:
		return "+"
	case .Minus:
		return "-"
	case .Star:
		return "*"
	case .Slash:
		return "/"
	case .Percent:
		return "%"
	case .Amp:
		return "&"
	case .Pipe:
		return "|"
	case .Tilde:
		return "~"
	case .Amp_Tilde:
		return "&~"
	case .Shl:
		return "<<"
	case .Shr:
		return ">>"
	case .And_And:
		return "&&"
	case .Or_Or:
		return "||"
	case .Not:
		return "!"
	case .Eq_Eq:
		return "=="
	case .Not_Eq:
		return "!="
	case .Lt:
		return "<"
	case .Lt_Eq:
		return "<="
	case .Gt:
		return ">"
	case .Gt_Eq:
		return ">="
	}
	return "?"
}

// Expressions and their implicit conversion to a destination.
//
// `check.odin` owns declarations and `check_stmt.odin` statements; everything
// that produces a value is dispatched here. Call checking and binding live in `check_calls.odin`,
// indexing and slicing in `check_index.odin`,
// composite literals in `check_composite.odin`, and which types convert to which
// in `conversions.odin`.
// Expression checking is contextual: an expected type flows down so that an
// untyped constant, an implicit `.Member`, a typeless composite literal, and
// `nil` can each take their meaning from where they are used.
package lokec

import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

// Where an expression sits. Only the node it is given for reads it: its
// operands and indices are ordinary value positions.
Expr_Position :: enum u8 {
	Value,
	// The callee of a call: a method selector or a payload variant is about to
	// be called rather than used as a value.
	Callee,
	// design.md "Indexing and slicing": a place position requires an `inout`
	// `operator([])`.
	Place,
	// design.md "Maps": the destination of a plain assignment, the one place
	// where `m[key]` may create an entry.
	Insert,
	// design.md "Slices": the operand of `&mut a[lo:hi]`. A place when there is
	// one, but a value carrying a `[]mut T` serves as well.
	Sliced_Mutably,
}

// The position of what a selection or index reaches into: it reaches the place,
// and never inserts.
operand_position :: proc(position: Expr_Position) -> Expr_Position {
	switch position {
	case .Place, .Insert:
		return .Place
	case .Sliced_Mutably:
		return .Sliced_Mutably
	case .Value, .Callee:
	}
	return .Value
}

check_expr :: proc(
	k: ^Checker,
	e: Expr,
	expected: Type_Id = INVALID_TYPE,
	position := Expr_Position.Value,
) -> Type_Id {
	if e == nil {
		return INVALID_TYPE
	}
	base := expr_base(e)
	// What a rejected expression is; each arm writes what it finds instead.
	base.type = INVALID_TYPE
	base.value_category = .Value
	base.immutable = .Not_A_Place
	// It reset the type; a conversion recorded by an earlier check reads that.
	base.erased_from = INVALID_TYPE
	base.extended = false

	switch v in e {
	case ^Expr_Error:

	case ^Expr_Literal:
		check_literal(k, v, expected)

	case ^Expr_Ident:
		check_ident(k, v, position == .Callee)

	case ^Expr_Selector:
		check_selector(k, v, expected, position)

	case ^Expr_Index:
		check_index(k, v, position)

	case ^Expr_Slice:
		check_slice(k, v, expected)

	case ^Expr_Or_Else:
		check_or_else(k, v)

	case ^Expr_Call:
		check_call(k, v, expected)

	case ^Expr_Unary:
		check_unary(k, v, expected)

	case ^Expr_Postfix:
		check_postfix(k, v, position)

	case ^Expr_Propagated_Error:
		// The operand's failure payload, a temporary either way: a place's is a
		// copy (design.md "Operator ownership").
		if shape, ok := fallible_of(k.c, expr_base(v.owner.operand).type); ok {
			v.type = shape.failure_type
		}

	case ^Expr_Binary:
		check_binary(k, v, expected)

	case ^Expr_Cond:
		check_cond(k, v, expected)

	case ^Expr_Composite:
		check_composite(k, v, expected)

	case ^Expr_Proc:
		check_proc_literal(k, v)

	case ^Expr_Range:
		check_range(k, v, expected)

	case ^Expr_Move:
		check_move(k, v)

	case ^Expr_Proc_Group, ^Expr_Operator,
	     ^Type_Pointer, ^Type_C_Pointer, ^Type_Slice, ^Type_Dynamic_Array,
	     ^Type_Array, ^Type_Map, ^Type_Distinct, ^Type_Dyn, ^Type_Type,
	     ^Type_Poly, ^Type_Proc, ^Type_Record, ^Type_Anon_Record, ^Type_Anon_Union, ^Type_Enum, ^Type_Interface:
		// A type in expression position, such as a conversion callee.
		reported := k.c.error_count
		denoted := resolve_type_syntax(k, e)
		if k.c.error_count > reported {
			break
		}
		if denoted != INVALID_TYPE {
			base.denoted_type = denoted
			base.value_category = .Type
			base.type = TYPE_TYPE
			base.const_value = type_const(denoted)
		} else {
			report_unresolved_type(k, e)
		}
	}
	// design.md "`type` and `typeid`": a call to a compile-time-only procedure
	// runs in the compiler where it is checked, so its result is a constant.
	if call, is_call := e.(^Expr_Call); is_call && base.type != INVALID_TYPE && !base_is_const(base) {
		callee := symbol_of(k.c, call.resolution.symbol)
		if callee != nil && callee.kind == .Proc && compile_time_only_procedure(k.c, callee) {
			folded, ok := require_const(k, e, "a call to a compile-time-only procedure", "L0453")
			if !ok {
				base.type = INVALID_TYPE
			} else if folded.kind == .Type {
				// It names a type, as `Simd(f32, 4)` does.
				base.value_category = .Type
				base.denoted_type = folded.type_value
			}
		}
	}
	// design.md "Compile-time reflection": a descriptor or `type` value is only
	// ever folded, so one computed at run time, such as `fields_of(T)[i]` with a
	// runtime `i`, has no representation.
	if base.type != INVALID_TYPE && !base_is_const(base) && type_is_reflection_value(k.c, base.type) {
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
check_single_expr :: proc(
	k: ^Checker,
	e: Expr,
	expected: Type_Id = INVALID_TYPE,
	position := Expr_Position.Value,
) -> Type_Id {
	return settle_single_value(k, e, check_expr(k, e, expected, position), expected)
}

// The rest of check_single_expr, for an expression already checked as `type`
// whose expected type is known only now.
settle_single_value :: proc(k: ^Checker, e: Expr, type: Type_Id, expected: Type_Id) -> Type_Id {
	base := expr_base(e)
	// design.md "Diverging procedures": a call that never returns stands in
	// for a value of whatever type is expected.
	if type == TYPE_VOID && expected != INVALID_TYPE && expected != TYPE_VOID &&
	   !type_is_untyped(k.c, expected) && call_diverges(k.c, e) {
		base.type = expected
		return expected
	}
	if type == TYPE_VOID {
		errorf(k.c, expr_span(e), "L0309", "this expression produces no value")
		if call_diverges(k.c, e) {
			add_notef(k.c, expr_span(e), "a call that never returns stands in for a value only where a type is expected")
		}
		base.type = INVALID_TYPE
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
	if !expr_assignable(k.c, e, target) {
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
		note_union_widening(k, expr_span(e), final, target)
		note_mutable_slicing(k, e, final, target)
		note_named_callable(k, e, final, target)
		note_written_procedure_conversion(k, e, final, target)
		return false
	}
	return true
}

// design.md "Distinct types": a procedure value that already has a type crosses
// to or from a distinct procedure type only where the conversion is written.
@(private = "file")
note_written_procedure_conversion :: proc(k: ^Checker, e: Expr, found, target: Type_Id) {
	wraps := type_kind(k.c, target) == .Distinct
	if wraps == (type_kind(k.c, found) == .Distinct) || !convertible(k.c, found, target) ||
	   underlying_kind(k.c, found) != .Proc || underlying_kind(k.c, target) != .Proc {
		return
	}
	if wraps {
		add_notef(
			k.c, expr_span(e), "only a named procedure or a procedure literal takes a distinct procedure type; a procedure value converts where it is written: `%s(value)`",
			type_name(k.c, target),
		)
	} else {
		add_notef(
			k.c, expr_span(e), "`%s` converts to the procedure type it wraps only where the conversion is written",
			type_name(k.c, found),
		)
	}
}

// design.md "Borrowed callable views": a named callable record has other roles,
// so it becomes a `dyn proc` view only where the conversion is written.
@(private = "file")
note_named_callable :: proc(k: ^Checker, e: Expr, found, target: Type_Id) {
	signature := dyn_proc_signature(k.c, target)
	info := callable_interface(k)
	if signature == INVALID_TYPE || info == nil || underlying_kind(k.c, found) == .Proc ||
	   callable_call_method(k, info, found, signature) == INVALID_SYMBOL {
		return
	}
	add_notef(
		k.c, expr_span(e), "`%s` has a matching `call`; a named callable converts where it is written: `(%s)(&value)`",
		type_name(k.c, found), type_name(k.c, target),
	)
}

// design.md "Slices": a `[]mut T` is asked for where the slice is written.
note_mutable_slicing :: proc(k: ^Checker, e: Expr, found, target: Type_Id) {
	slice, is_slice := e.(^Expr_Slice)
	if is_slice && !slice.mutable && slice_is_mutable(k.c, target) && !slice_is_mutable(k.c, found) &&
	   type_kind(k.c, found) == .Slice {
		add_notef(k.c, slice.span, "`a[lo:hi]` is read-only; write `&mut a[lo:hi]` for a mutable slice")
	}
}

// ---------------------------------------------------------------- literals --

@(private = "file")
check_literal :: proc(k: ^Checker, v: ^Expr_Literal, expected: Type_Id) {
	switch v.kind {
	case .Int:
		value, ok := bi_parse_int_literal(k.c, v.text)
		if !ok {
			errorf(k.c, v.span, "L0351", "`%s` is not a valid integer literal", v.text)
			return
		}
		v.type = TYPE_UNTYPED_INT
		v.const_value = integer_const(value)

	case .Float:
		text, _ := strings.replace_all(v.text, "_", "", k.c.semantic_allocator)
		value, ok := strconv.parse_f64(text)
		if !ok {
			errorf(k.c, v.span, "L0351", "`%s` is not a valid floating-point literal", v.text)
			return
		}
		// design.md "Number literals": unfixed until a destination or a concrete
		// operand converts it, which rounds the exact decimal value once.
		v.type = TYPE_UNTYPED_FLOAT
		v.const_value = float_const(value, 64)
		v.const_value.text = text

	case .Rune:
		value, ok := decode_rune_literal(v.text)
		if !ok {
			errorf(k.c, v.span, "L0351", "`%s` is not a valid character literal", v.text)
			return
		}
		v.type = TYPE_UNTYPED_RUNE
		v.const_value = rune_const(bi_from_i64(k.c, i64(value)))

	case .String, .Raw_String:
		text, ok := decode_string_literal(k.c, v.text, v.kind == .Raw_String)
		if !ok {
			errorf(k.c, v.span, "L0351", "`%s` is not a valid string literal", v.text)
			return
		}
		v.type = TYPE_UNTYPED_STRING
		v.const_value = string_const(text)
	}
}

// ------------------------------------------------------------ identifiers --

// These share one immutability flag, so the construct written is recovered for
// the diagnostic.
@(private = "file")
immutable_name_reason :: proc(c: ^Compiler, sym: ^Symbol) -> Immutable_Reason {
	if sym.kind == .Parameter && identifier_text(c, sym.name) == CAPTURE_RECEIVER {
		return .Captured_Copy
	}
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
check_ident :: proc(k: ^Checker, v: ^Expr_Ident, callee: bool) {
	symbol_id, owner := lookup_symbol_with_scope(k.scope, identifier_of(k.c, v))
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
		return
	}
	v.symbol = symbol_id
	// Every use of a name, including an assignment destination, counts as a read
	// for design.md "@(require_results)".
	sym.named = true

	// design.md "Capture literals": the body's rewrite reads every capture
	// through the receiver, so a name that reaches the reserved one is in a
	// position the rewrite cannot see.
	if placeholder, reserved := k.c.capture_placeholders[symbol_id]; reserved && placeholder.method == k.proc_literal {
		errorf(k.c, v.span, "L0716", "`%s` is a capture, which cannot be read in this position", v.name)
		return
	}

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
			// design.md "Capture literals": a literal names what it captures.
			add_notef(
				k.c, v.span,
				"capture it after the signature: `capture(%s)` copies it, `capture(&%s)` borrows it, and `capture(&mut %s)` lets the body write it",
				v.name, v.name, v.name,
			)
			return
		}
	}

	// Constants and globals are checked on demand, so a forward reference sees a
	// real type.
	if sym.decl != nil && (sym.kind == .Const || (sym.kind == .Var && sym.decl.top_level)) &&
	   !ensure_decl_checked(k, v.span, symbol_id, v.name) {
		return
	}
	// design.md "Variable declarations": a local is dead until its initializer
	// has run, so the initializer cannot read it. Nothing else would say so: the
	// local has no type yet, and an invalid type reports nothing further.
	if sym.decl != nil && sym.kind == .Var && !sym.decl.top_level && sym.decl.check_state == .Checking {
		errorf(k.c, v.span, "L0500", "`%s` cannot be used in the declaration that introduces it: it has no value yet", v.name)
		return
	}

	annotate_symbol_use(k, &v.base, symbol_id, v.name, callee)
}

// A constant or global is checked on demand; false when that is a cycle, which
// is reported. `subject` binds an associated constant's block.
@(private = "file")
ensure_decl_checked :: proc(
	k: ^Checker, span: Span, symbol_id: Symbol_Id, name: string, subject := INVALID_TYPE,
) -> bool {
	sym := symbol_of(k.c, symbol_id)
	switch sym.decl.check_state {
	case .Unchecked:
		check_symbol_decl_in_place(k, symbol_id, subject)
	case .Checking:
		errorf(
			k.c, span, "L0324", "%s initialisation cycle involving `%s`",
			sym.kind == .Const ? "constant" : "global", name,
		)
		return false
	case .Checked:
	}
	return true
}

// Writes what a resolved symbol means onto the node that named it, for both
// `name` and `package.name`.
@(private = "file")
annotate_symbol_use :: proc(k: ^Checker, v: ^Expr_Base, symbol_id: Symbol_Id, name: string, callee: bool) {
	sym := symbol_of(k.c, symbol_id)
	if sym == nil {
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
		return
	}
	switch sym.kind {
	case .Type:
		resolve_symbol_signature_in_place(k, symbol_id)
		mark_denotes_type(v, sym.type, symbol_id)
		v.type = TYPE_TYPE
		v.const_value = type_const(sym.type)

	case .Proc:
		if sym.hook != .None && !callee {
			reject_direct_hook_call(k, v.span, symbol_id)
			return
		}
		// Resolved on demand, so a constant may call a procedure declared later.
		if sym.proc_type == INVALID_TYPE && sym.decl != nil {
			resolve_symbol_signature_in_place(k, symbol_id)
		}
		// design.md "`type` and `typeid`": only the compiler runs it, so it has
		// no address to hold.
		if !callee && sym.proc_type != INVALID_TYPE && compile_time_only_procedure(k.c, sym) {
			errorf(
				k.c, v.span, "L0378",
				"`%s` is compile-time only: it can be called, but not held as a procedure value", name,
			)
			return
		}
		v.resolution = Resolution{kind = .Value, symbol = symbol_id}
		// A member a probe synthesized is emitted once a value use commits it.
		enroll_synth(k.c, symbol_id)
		if reject_test_procedure_use(k, sym, name, v.span) {
			return
		}
		v.type = sym.proc_type
		warn_deprecated_use(k, sym, name, v.span)

	case .Builtin:
		v.resolution = Resolution{kind = .Value, symbol = symbol_id}
		errorf(k.c, v.span, "L0316", "`%s` is a built-in procedure and must be called", name)

	case .Const, .Enum_Member:
		v.resolution = Resolution{kind = .Value, symbol = symbol_id}
		v.type = sym.type
		v.const_value = sym.const_value
		v.immutable = .Constant
		// design.md "Type alias": a constant whose value is a type denotes it.
		if const_names_type(k.c, sym.const_value, sym.type) {
			mark_denotes_type(v, sym.const_value.type_value, symbol_id)
		}

	case .Var, .Parameter:
		v.resolution = Resolution{kind = .Value, symbol = symbol_id}
		v.value_category = .Place
		v.type = sym.type
		v.addressable = true
		v.assignable = !sym.immutable
		v.immutable = sym.immutable ? immutable_name_reason(k.c, sym) : .None

	case .Field:
		v.resolution = Resolution{kind = .Field, symbol = symbol_id}
		v.type = sym.type

	case .Package_Alias:
		errorf(k.c, v.span, "L0334", "`%s` names a package; write `%s.name` to use one of its declarations", name, name)

	case .Proc_Group:
		v.resolution = Resolution{kind = .Error, symbol = symbol_id}
		errorf(k.c, v.span, "L0396", "`%s` is a procedure group and can only be called", name)

	case .Invalid:
		unsupported_construct(k, v.span)
	}
}

// -------------------------------------------------------------- selectors --

@(private = "file")
check_selector :: proc(k: ^Checker, v: ^Expr_Selector, expected: Type_Id, position: Expr_Position) {
	callee := position == .Callee

	// The parser reported the missing name. The operand is still checked, so
	// an editor sees its type, and no lookup reports a second time.
	if v.name.text == "" {
		if ident, alias, is_alias := selector_package_alias(k, v); is_alias {
			annotate_package_alias(ident, alias)
			return
		}
		if v.operand != nil {
			check_single_expr(k, v.operand)
		}
		return
	}

	if v.operand == nil {
		check_implicit_selector(k, v, expected, callee)
		return
	}

	// A package alias is not a value, so it is resolved before the operand is
	// checked as one.
	if ident, alias, is_alias := selector_package_alias(k, v); is_alias {
		check_package_selector(k, v, ident, alias, callee)
		return
	}

	// The operand is not in callee position, whatever this selector is. It is
	// a place when this is: `m[key].x = v` reaches the index as a place, but
	// never inserts (design.md "Maps").
	// `check_receiver` may already have, for the call whose callee this is.
	operand := v.receiver_checked ? expr_base(v.operand).type : check_single_expr(k, v.operand, position = operand_position(position))
	v.receiver_checked = false
	if operand == INVALID_TYPE {
		return
	}
	if operand_base := expr_base(v.operand); operand_base.value_category == .Type {
		check_type_selector(k, v, operand_base.denoted_type, callee)
	} else {
		check_value_selector(k, v, operand, callee)
	}
}

// `.Member`: the implicit enum selector and the payloadless union variant, both
// of which take their type from the expected one.
@(private = "file")
check_implicit_selector :: proc(k: ^Checker, v: ^Expr_Selector, expected: Type_Id, callee: bool) {
	if check_union_variant_selector(k, v, expected, callee) {
		if v.resolution.kind == .Union_Variant && !callee {
			reject_incomplete_variant(k, v)
			v.type = INVALID_TYPE
		}
		return
	}
	enum_type := type_underlying(k.c, expected)
	if !type_is_enum(k.c, enum_type) {
		wanted := underlying_info(k.c, expected)
		if type_is_union(k.c, expected) {
			errorf(k.c, v.span, "L0425", "`%s` has no variant `%s`", type_name(k.c, expected), v.name.text)
		} else if wanted != nil && wanted.kind == .Proc && type_is_union(k.c, wanted.result) &&
		          union_variant_index(k.c, wanted.result, v.name.id) >= 0 {
			// A constructor value names its union: the destination never picks one.
			errorf(
				k.c, v.span, "L0425", "a variant used as a procedure names its union: write `%s.%s`",
				type_name(k.c, wanted.result), v.name.text,
			)
		} else {
			errorf(k.c, v.span, "L0385", "`.%s` needs an expected enum type here", v.name.text)
		}
		return
	}
	member := field_named(k.c, enum_type, v.name.id)
	if member == INVALID_SYMBOL {
		errorf(k.c, v.span, "L0363", "`%s` has no member `%s`", type_name(k.c, expected), v.name.text)
		return
	}
	select_enum_member(k, v, member, expected)
}

// `v` as the enum member it selected, a constant of `type`.
@(private = "file")
select_enum_member :: proc(k: ^Checker, v: ^Expr_Selector, member: Symbol_Id, type: Type_Id) {
	v.resolution = Resolution{kind = .Field, symbol = member}
	v.type = type
	v.const_value = symbol_of(k.c, member).const_value
	v.immutable = .Constant
}

// `Type.member`: its own variant or enum member, or what its `impl` associates.
@(private = "file")
check_type_selector :: proc(k: ^Checker, v: ^Expr_Selector, subject: Type_Id, callee: bool) {
	// A named union type selects its own variant: `Option.none`, `Result.ok`.
	// Outside a call, a payload variant is its constructor procedure.
	if check_union_variant_selector(k, v, subject, callee) {
		if v.resolution.kind == .Union_Variant && !callee {
			constructor := variant_constructor(k.c, v.variant_union, v.variant_index)
			v.type = INVALID_TYPE
			annotate_symbol_use(k, &v.base, constructor, v.name.text, callee)
		}
		return
	}
	// A named enum type selects its own member: `Colour.Red`.
	enum_type := type_underlying(k.c, subject)
	if type_is_enum(k.c, enum_type) {
		if member := field_named(k.c, enum_type, v.name.id); member != INVALID_SYMBOL {
			select_enum_member(k, v, member, subject)
			return
		}
	}
	// design.md "Methods and implementation blocks": associated procedures and
	// constants without `self` are accessed through the type name, and so is
	// `Type.method(value)`.
	if select_associated_member(k, v, subject, callee) {
		return
	}
	errorf(k.c, v.span, "L0408", "`%s` has no member `%s`", type_name(k.c, subject), v.name.text)
	note_excluded_member(k, subject, v.name.text)
	note_missing_callable_result(k, subject, v.name.text)
}

// An unfixed receiver takes its default type (design.md "Unfixed constants"), and
// an unfixed string is a `string_view` (design.md "string type"), so `TEXT.len()`
// finds the view's member.
@(private = "file")
unfixed_receiver_type :: proc(c: ^Compiler, operand: Type_Id) -> Type_Id {
	return operand == TYPE_UNTYPED_STRING ? TYPE_STRING_VIEW : default_type(c, operand)
}

// A field, then a method. The operand is an ordinary value.
@(private = "file")
check_value_selector :: proc(k: ^Checker, v: ^Expr_Selector, checked: Type_Id, callee: bool) {
	operand := checked
	// design.md "Owned values": a box reaches its payload's fields and methods as
	// a pointer does, after its own members such as `clone`. The hop is written
	// into the typed AST as `b^`, which every later pass already understands.
	if boxed := underlying_info(k.c, operand); boxed != nil && boxed.kind == .Box {
		if struct_field_named(k.c, boxed.element, v.name.id) == INVALID_SYMBOL && select_method(k, v, operand, callee) {
			return
		}
		v.operand = implicit_box_deref(k, v.operand, boxed.element)
		operand = boxed.element
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
	if field := struct_field_named(k.c, base_type, v.name.id); field != INVALID_SYMBOL {
		select_field(k, v, operand, expr_base(v.operand), through_pointer, pointer_mutable, field)
		return
	}
	// A field always wins over method-call sugar with the same name
	// (design.md "Methods and implementation blocks"). A pointer's own methods
	// come first, then the pointee's.
	if select_method(k, v, operand, callee) {
		return
	}
	if through_pointer && select_method(k, v, pointee_type, callee) {
		v.operand = implicit_pointer_deref(k, v.operand, pointee_type, pointer_mutable)
		return
	}
	if type_is_untyped(k.c, operand) {
		materialized := unfixed_receiver_type(k.c, operand)
		if materialized != operand && materialized != INVALID_TYPE {
			if !materialize(k, v.operand, materialized) || select_method(k, v, materialized, callee) {
				return
			}
		}
	}
	if report_missing_dyn_slot(k, v.span, operand, v.name.text) {
		return
	}
	errorf(k.c, v.span, "L0363", "`%s` has no field or member `%s`", type_name(k.c, operand), v.name.text)
	note_excluded_member(k, operand, v.name.text)
}

// design.md "Calling a value": the `call` method `x(args)` calls, found as
// `x.call` finds a method, through a box, a pointer, or an unfixed receiver's
// default type, but with no field taking its place.
select_call_method :: proc(k: ^Checker, v: ^Expr_Selector, operand: Type_Id) -> bool {
	if select_method(k, v, operand, true) {
		return true
	}
	subject := operand
	if boxed := underlying_info(k.c, subject); boxed != nil && boxed.kind == .Box {
		v.operand = implicit_box_deref(k, v.operand, boxed.element)
		subject = boxed.element
		if select_method(k, v, subject, true) {
			return true
		}
	}
	if pointer := underlying_info(k.c, subject); pointer != nil && pointer.kind == .Pointer {
		if select_method(k, v, pointer.element, true) {
			v.operand = implicit_pointer_deref(k, v.operand, pointer.element, pointer.mutable)
			return true
		}
		return false
	}
	if type_is_untyped(k.c, operand) {
		materialized := unfixed_receiver_type(k.c, operand)
		if materialized == operand || materialized == INVALID_TYPE ||
		   first_method(k, materialized, v.name.id) == INVALID_SYMBOL {
			return false
		}
		return materialize(k, v.operand, materialized) && select_method(k, v, materialized, true)
	}
	return false
}

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
		return false
	}
	sym := symbol_of(k.c, field)
	v.resolution = Resolution{kind = .Field, symbol = field}
	v.type = sym.type
	v.value_category = .Place
	inherit_capability(&v.base, operand_base, through_pointer, pointer_mutable)
	if sym.synchronized && sym.pkg != k.pkg && !on_raw_address_chain(k, v) {
		check_synchronized_access(k, v, sym)
	}
	// Selecting from a constant aggregate is itself constant.
	if operand_base.const_value.kind == .Aggregate {
		aggregate := operand_base.const_value.aggregate
		if aggregate != nil && int(sym.index) < len(aggregate.elements) {
			v.const_value = aggregate.elements[sym.index]
			v.immutable = .Constant
			// design.md "Compile-time reflection": an `Enum_Value`'s `value` has its
			// enum's backing type, so a `u64` member above `max(int)` keeps its value.
			if operand_base.type == k.c.meta_enum_value_type && operand_base.type != INVALID_TYPE &&
			   sym.index == META_PAYLOAD {
				if owner := underlying_info(k.c, aggregate.elements[META_OWNER].type_value); owner != nil {
					v.type = owner.element
				}
			}
		}
	}
	return true
}

// A field or element place: writable through a `^mut T`, read-only through a
// `^T`, and otherwise exactly as writable as the operand it is part of.
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

// design.md "@(synchronized)": outside the declaring package, reaching a
// synchronized field needs exclusive access to the record holding it, since a
// synchronizing operation through a read-only borrow may write it meanwhile.
// The place must be one a write could reach; the borrow analysis then counts
// the access as a write against every loan of the owner.
@(private = "file")
check_synchronized_access :: proc(k: ^Checker, v: ^Expr_Selector, field: ^Symbol) {
	v.synchronized = true
	reason := ""
	#partial switch v.immutable {
	case .None:
		if v.assignable {
			return
		}
		reason = "this expression"
	case .Constant, .Temporary, .Read_Only:
		// Its own temporary, or a constant nothing can change.
		return
	case .Through_Pointer:
		reason = "a read-only `^T`"
	case .Through_Slice:
		reason = "a read-only `[]T`"
	case .Value_Parameter:
		reason = "a value parameter, which shares its caller's storage"
	case .Loop_Binding:
		reason = "a `foreach` binding, which names the element read-only"
	case .Payload_Binding:
		reason = "a case binding over storage the subject still owns"
	case:
		reason = "a read-only name"
	}
	pkg := package_of(k.c, field.pkg)
	errorf(
		k.c, v.span, "L0722",
		"`%s` is `@(synchronized)`, so outside `%s` it is reached only with exclusive access to its record, not through %s",
		identifier_text(k.c, field.name), pkg != nil ? pkg.key : "its package", reason,
	)
	add_notef(
		k.c, v.span,
		"use the type's synchronizing operations, or reach it through an owner, `^mut`, `[]mut`, or `inout`",
	)
}

// Whether `v` is on the place chain of a `rawptr(&place)` conversion, which
// takes an address without accessing what is there.
@(private = "file")
on_raw_address_chain :: proc(k: ^Checker, v: ^Expr_Selector) -> bool {
	place := k.raw_address_place
	for place != nil {
		if expr_base(place) == &v.base {
			return true
		}
		#partial switch link in place {
		case ^Expr_Selector:
			place = link.operand
		case ^Expr_Index:
			place = link.operand
		case:
			return false
		}
	}
	return false
}

// The field of struct `record` named `name`. An enum's members are `fields`
// too, and a selector on a value does not reach them.
@(private)
struct_field_named :: proc(c: ^Compiler, record: Type_Id, name: Identifier_Id) -> Symbol_Id {
	if underlying_kind(c, record) != .Struct {
		return INVALID_SYMBOL
	}
	return field_named(c, record, name)
}

// An implicit `operand^`, written into the typed AST so later passes see the
// real place and its capability.
implicit_pointer_deref :: proc(
	k: ^Checker,
	operand: Expr,
	pointee: Type_Id,
	mutable: bool,
) -> Expr {
	base := expr_base(operand)
	n := synth_deref(k.c, operand, base.span)
	n.type = pointee
	n.value_category = .Place
	inherit_capability(&n.base, base, true, mutable)
	return n
}

// A place inside what `owner` owns: a box's payload, a dynamic array's element, or
// a map's value. It has the owner's own capability.
owned_element_place :: proc(v: ^Expr_Base, element: Type_Id, owner: ^Expr_Base) {
	v.type = element
	v.value_category = .Place
	v.addressable = true
	v.assignable = owner.assignable
	v.immutable = owner.immutable
}

// The `b^` an implicit box dereference writes into the typed AST.
implicit_box_deref :: proc(k: ^Checker, operand: Expr, payload: Type_Id) -> Expr {
	base := expr_base(operand)
	n := synth_deref(k.c, operand, base.span)
	n.boxed = true
	owned_element_place(&n.base, payload, base)
	return n
}

// `Type.member`: an associated constant, an associated type, or a procedure
// reached through the type name.
@(private = "file")
select_associated_member :: proc(
	k: ^Checker, v: ^Expr_Selector, subject: Type_Id, callee: bool,
) -> bool {
	member := find_member(k, subject, v.name.id)
	sym := symbol_of(k.c, member)
	if sym == nil {
		return false
	}
	// Checked on demand with the block's subject, which binds an instantiated
	// block's generic arguments.
	outer := k.impl_type
	k.impl_type = subject
	defer k.impl_type = outer
	// design.md "Constant declarations", as for an unqualified name.
	if sym.kind == .Const && sym.decl != nil && !ensure_decl_checked(k, v.span, member, v.name.text, subject) {
		return true
	}
	// A call checks its container operation with its arguments; a procedure
	// value is checked here, since nothing will check its calls.
	if !callee {
		check_container_element(k, v.span, sym)
	}
	annotate_symbol_use(k, &v.base, member, v.name.text, callee)
	return true
}

// A method on the operand's own type. A `distinct` type carries its own members,
// so this never looks through to the underlying type.
@(private = "file")
select_method :: proc(k: ^Checker, v: ^Expr_Selector, receiver: Type_Id, callee_position: bool) -> bool {
	method := first_method(k, receiver, v.name.id)
	if method == INVALID_SYMBOL {
		return false
	}
	v.resolution = Resolution{kind = .Method, symbol = method}
	v.value_category = .Value
	if !callee_position {
		// There are no bound method values: the receiver is supplied by the call.
		errorf(k.c, v.span, "L0408", "`%s` is a method and must be called", v.name.text)
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

// What `method_candidates` would list first.
@(private = "file")
first_method :: proc(k: ^Checker, receiver: Type_Id, name: Identifier_Id) -> Symbol_Id {
	for candidate in member_candidates(k, receiver, name) {
		if sym := symbol_of(k.c, candidate); sym != nil && sym.has_receiver {
			return candidate
		}
	}
	return INVALID_SYMBOL
}

// The members named `name` that method-call syntax can reach: those with a
// receiver. The list is in temporary memory, as `member_candidates`'s is.
method_candidates :: proc(k: ^Checker, receiver: Type_Id, name: Identifier_Id) -> []Symbol_Id {
	all := member_candidates(k, receiver, name)
	if len(all) == 0 {
		return nil
	}
	out := make([dynamic]Symbol_Id, 0, len(all), context.temp_allocator)
	for candidate in all {
		if sym := symbol_of(k.c, candidate); sym != nil && sym.has_receiver {
			append(&out, candidate)
		}
	}
	return out[:]
}

@(private = "file")
annotate_package_alias :: proc(ident: ^Expr_Ident, alias: Symbol_Id) {
	ident.symbol = alias
	ident.resolution = Resolution{kind = .Package, symbol = alias}
	ident.type = TYPE_VOID
}

// `alias.name`. Only the target package's own scope is searched — never its
// parents — and only a `@(public)` declaration is visible from outside.
check_package_selector :: proc(k: ^Checker, v: ^Expr_Selector, ident: ^Expr_Ident, alias: Symbol_Id, callee: bool) {
	v.type = INVALID_TYPE
	v.value_category = .Value
	alias_symbol := symbol_of(k.c, alias)
	annotate_package_alias(ident, alias)

	target := package_of(k.c, alias_symbol.pkg)
	if target == nil || target.scope == nil {
		return
	}
	symbol_id, found := target.scope.names[v.name.id]
	if !found {
		errorf(k.c, v.span, "L0335", "package `%s` has no declaration `%s`", ident.name, v.name.text)
		return
	}
	symbol := symbol_of(k.c, symbol_id)
	if symbol == nil || !symbol.public {
		errorf(k.c, v.span, "L0336", "`%s` is not public in package `%s`", v.name.text, ident.name)
		if symbol != nil && symbol.kind == .Var {
			add_notef(k.c, symbol.span, "declared here; a variable is never public, so export a procedure that reads it")
		} else if symbol != nil {
			add_notef(k.c, symbol.span, "declared here; add `@(public)` to export it")
		}
		return
	}
	// It may be reached before its own package is checked.
	if symbol.decl != nil && (symbol.kind == .Const || symbol.kind == .Var) &&
	   !ensure_decl_checked(k, v.span, symbol_id, v.name.text) {
		return
	}
	annotate_symbol_use(k, &v.base, symbol_id, v.name.text, callee)
}

// ------------------------------------------------------------------ unary --

@(private = "file")
check_unary :: proc(k: ^Checker, v: ^Expr_Unary, expected: Type_Id) {
	if v.op == .Amp {
		// A place position that never inserts.
		operand := check_single_expr(k, v.operand, pointee_of(k.c, expected), .Place)
		if operand == INVALID_TYPE {
			return
		}
		operand_base := expr_base(v.operand)
		// design.md "Materialization" yields a `^T`, so an untyped constant takes
		// the pointee asked for, or else its default type.
		if !operand_base.addressable && base_is_const(operand_base) && type_is_untyped(k.c, operand) {
			target := pointee_of(k.c, expected)
			if target == INVALID_TYPE {
				target = default_type(k.c, operand)
			}
			if target != INVALID_TYPE {
				if !materialize(k, v.operand, target) {
					return
				}
				operand = operand_base.type
			}
		}
		// A named constant gets read-only storage (design.md "Materialization"),
		// so `&mut` is then rejected as a constant.
		if !operand_base.addressable && request_materialization(k, v.operand) {
			operand_base.addressable = true
		}
		if !operand_base.addressable {
			errorf(k.c, v.op_span, "L0357", "`%s` needs an addressable operand", v.mutable ? "&mut" : "&")
			return
		}
		if v.mutable && !operand_base.assignable {
			report_not_assignable(k, operand_base, "borrowed with `&mut`")
			return
		}
		// A packed field may be misaligned (design.md "@(packed)").
		if field, packed := packed_field_reached(k, v.operand); packed {
			errorf(
				k.c, v.op_span, "L0614",
				"cannot take the address of `%s`: it is reached through a packed struct", field,
			)
			return
		}
		v.type = pointer_to(k.c, operand, v.mutable)
		return
	}

	operand := check_single_expr(k, v.operand, expected)
	if operand == INVALID_TYPE {
		return
	}
	operand_base := expr_base(v.operand)
	defined := builtin_unary_defined(k, v.op, operand)
	// A built-in operation cannot be shadowed by a user overload.
	if !defined && check_user_unary(k, v, operand) {
		return
	}
	if simd_operand(k.c, operand) {
		check_simd_unary(k, v, operand)
		return
	}
	if !defined {
		operator_mismatch(k, v.op_span, v.op, operand)
		return
	}

	v.type = operand
	if !base_is_const(operand_base) {
		return
	}
	folded, ok := fold_unary_const(k, v.op, v.op_span, operand_base.const_value, operand)
	if !ok {
		return
	}
	v.const_value = folded
}

// `fold_unary` for the checker, whose float constants keep a decimal spelling.
// It follows the sign, so `-(-x)` still rounds once.
fold_unary_const :: proc(k: ^Checker, op: Token_Kind, op_span: Span, value: Const_Value, type: Type_Id) -> (Const_Value, bool) {
	folded, ok := fold_unary(k.c, op, op_span, value, type)
	if ok && op == .Minus && value.kind == .Float && value.text != "" {
		if value.text[0] == '-' {
			folded.text = value.text[1:]
		} else {
			folded.text = strings.concatenate({"-", value.text}, k.c.semantic_allocator)
		}
	}
	return folded, ok
}

@(private = "file")
check_user_unary :: proc(k: ^Checker, v: ^Expr_Unary, operand: Type_Id) -> bool {
	symbol := operator_text(v.op)
	operands := []Type_Id{operand}
	members := operator_candidates(k, symbol, operands)
	if !operator_exists(k, members, operands) {
		return false
	}
	args := make([]Arg_Info, 1, context.temp_allocator)
	args[0] = arg_from_expr(v.operand)
	chosen, bound := resolve_operator(k, v.op_span, symbol, members, args)
	if chosen == INVALID_SYMBOL {
		return true
	}
	v.operand = bound[0]
	annotate_user_operator(k, &v.base, chosen)
	return true
}

// design.md "`@(deprecated=<string>)`": a warning at each use.
warn_deprecated_use :: proc(k: ^Checker, sym: ^Symbol, name: string, span: Span) {
	if !sym.deprecated {
		return
	}
	if sym.deprecated_message != "" {
		warnf(k.c, span, "L0611", "`%s` is deprecated: %s", name, sym.deprecated_message)
	} else {
		warnf(k.c, span, "L0611", "`%s` is deprecated", name)
	}
}

// design.md "`@(deprecated=<string>)`": a method, a group's member, an
// operator, or a generic instance is a use of the declaration it was chosen
// from. A plain named call warns where its name resolves instead.
warn_deprecated_choice :: proc(k: ^Checker, chosen: Symbol_Id, span: Span) {
	if sym := declaration_of_choice(k, chosen); sym != nil {
		warn_deprecated_use(k, sym, identifier_text(k.c, sym.name), span)
	}
}

// The declaration overload resolution chose: a generic instance's template,
// which holds its attributes, or the procedure itself.
declaration_of_choice :: proc(k: ^Checker, chosen: Symbol_Id) -> ^Symbol {
	sym := symbol_of(k.c, chosen)
	if sym == nil {
		return nil
	}
	if template := symbol_of(k.c, sym.instance_of); template != nil {
		return template
	}
	return sym
}

// `v` as a call of the operator overload resolution chose.
annotate_user_operator :: proc(k: ^Checker, v: ^Expr_Base, chosen: Symbol_Id) -> ^Symbol {
	sym := symbol_of(k.c, chosen)
	v.resolution = Resolution{kind = .User_Operator, symbol = chosen, chosen_overload = chosen}
	v.type = sym.result
	return sym
}

// design.md "Operator declarations": `!=` falls back to `!(left == right)`
// when `==` is available and no more specific `!=` overload exists.
check_user_binary :: proc(k: ^Checker, v: ^Expr_Binary, lhs, rhs: Type_Id) -> bool {
	symbol := operator_text(v.op)
	operands := []Type_Id{lhs, rhs}
	args := make([]Arg_Info, 2, context.temp_allocator)
	args[0] = arg_from_expr(v.lhs)
	args[1] = arg_from_expr(v.rhs)
	negate := false
	set := form_operator_set(k, symbol, operands, args)
	if !candidates_viable(set.formed) {
		equal := v.op == .Not_Eq ? form_operator_set(k, "==", operands, args) : Operator_Set{}
		if !candidates_viable(equal.formed) {
			if operator_exists(k, set.members, operands) {
				resolve_operator_set(k, v.op_span, set, args)
				return true
			}
			return false
		}
		set = equal
		negate = true
	}
	chosen, bound := resolve_operator_set(k, v.op_span, set, args)
	if chosen == INVALID_SYMBOL {
		return true
	}
	// A delegated vector `==` produces a lane mask, which `!` does not apply to.
	if negate && !type_is_boolean(k.c, symbol_of(k.c, chosen).result) {
		operator_mismatch2(k, v.op_span, v.op, lhs, rhs)
		return true
	}
	v.lhs, v.rhs = bound[0], bound[1]
	v.negated = negate
	annotate_user_operator(k, &v.base, chosen)
	return true
}

@(private = "file")
check_postfix :: proc(k: ^Checker, v: ^Expr_Postfix, position: Expr_Position) {
	if v.op == .Or_Return {
		check_or_return(k, v)
		return
	}
	// A box's payload is part of the box's own place, so the box is reached in
	// the same position (design.md "Owned values").
	operand := check_single_expr(k, v.operand, position = operand_position(position))
	if operand == INVALID_TYPE {
		return
	}
	info := underlying_info(k.c, operand)
	if info != nil && info.kind == .Box {
		v.boxed = true
		owned_element_place(&v.base, info.element, expr_base(v.operand))
		return
	}
	if info == nil || info.kind != .Pointer {
		errorf(k.c, v.op_span, "L0355", "`^` needs a pointer, found `%s`", type_name(k.c, operand))
		return
	}
	v.type = info.element
	v.value_category = .Place
	inherit_capability(&v.base, nil, true, info.mutable)
}

// ----------------------------------------------------------------- binary --

// A bare `.Member` with no operand — the implicit enum selector.
is_implicit_selector :: proc(e: Expr) -> bool {
	sel, ok := e.(^Expr_Selector)
	return ok && sel.operand == nil
}

@(private = "file")
check_binary :: proc(k: ^Checker, v: ^Expr_Binary, expected: Type_Id) {
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
		check_in(k, v)
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
		return
	}

	if !builtin_binary_defined(k, v.op, lhs, rhs) {
		if check_user_binary(k, v, lhs, rhs) {
			return
		}
	}
	// design.md "SIMD vectors": lane-wise, with its own operator table.
	if simd_operand(k.c, lhs) || simd_operand(k.c, rhs) {
		check_simd_binary(k, v, lhs, rhs)
		return
	}
	if shift {
		check_shift(k, v, expected, lhs, rhs)
		return
	}

	operand_type, unified := unify_operands(k, v.lhs, v.rhs, v.op_span, is_comparison)
	if !unified {
		return
	}

	if is_comparison {
		check_comparison(k, v, operand_type)
		return
	}

	if !builtin_operator_applies(k.c, v.op, operand_type) {
		// Said in the message, as for ordering: an interface requirement keeps
		// only the message, and a hidden inherent operator is the likely cause of
		// a requirement that holds in the type's own package and nowhere else.
		if hidden_inherent_operator(k, operator_text(v.op), []Type_Id{lhs, rhs}) {
			errorf(
				k.c, v.op_span, "L0318",
				"`%s` does not apply to `%s` here: its inherent `%s` is not `@(public)`",
				operator_text(v.op), type_name(k.c, lhs), operator_text(v.op),
			)
		} else {
			operator_mismatch2(k, v.op_span, v.op, lhs, rhs)
		}
		return
	}
	v.type = operand_type
	// Concatenating text always produces an owning `string`.
	if v.op == .Plus && type_is_utf8_text(k.c, operand_type) {
		v.type = TYPE_STRING
	}
	// Two unfixed strings fold, unless one has a runtime part; then they meet as
	// any two strings do, at the view (design.md "Arithmetic operators").
	if v.op == .Plus && operand_type == TYPE_UNTYPED_STRING && !(is_const_expr(v.lhs) && is_const_expr(v.rhs)) {
		if !materialize(k, v.lhs, TYPE_STRING_VIEW) || !materialize(k, v.rhs, TYPE_STRING_VIEW) {
			v.type = INVALID_TYPE
			return
		}
		v.type = TYPE_STRING
	}

	if constant_zero_divisor(k, v.op, v.op_span, v.rhs) {
		v.type = INVALID_TYPE
		return
	}
	left, right := expr_base(v.lhs), expr_base(v.rhs)
	if !base_is_const(left) || !base_is_const(right) {
		return
	}
	folded, ok := fold_arithmetic(k.c, v.op, v.op_span, left.const_value, right.const_value, operand_type)
	if !ok {
		v.type = INVALID_TYPE
		return
	}
	v.const_value = folded
}

// design.md "Integer operators": a constant zero divisor is an error even when
// the dividend is only known at run time.
constant_zero_divisor :: proc(k: ^Checker, op: Token_Kind, op_span: Span, divisor: Expr) -> bool {
	value := expr_base(divisor)
	if (op != .Slash && op != .Percent) || !base_is_const(value) {
		return false
	}
	is_zero :: proc(value: Const_Value) -> bool {
		return (value.kind == .Integer || value.kind == .Rune) && bi_is_zero(value.integer)
	}
	// design.md "Lane-wise operators": any zero lane fails the whole operation.
	if value.const_value.kind == .Aggregate {
		for lane, index in value.const_value.aggregate.elements {
			if is_zero(lane) {
				errorf(k.c, op_span, "L0319", "division by zero in lane %d", index)
				return true
			}
		}
		return false
	}
	if !is_zero(value.const_value) {
		return false
	}
	errorf(k.c, op_span, "L0319", "division by zero")
	return true
}

// `a && b` evaluates to `b` if `a` else `false` (design.md "Logical
// operators"), so the right operand is checked but only the selected value is
// folded.
@(private = "file")
check_logical :: proc(k: ^Checker, v: ^Expr_Binary) {
	lhs := check_single_expr(k, v.lhs, TYPE_BOOL)
	rhs := check_single_expr(k, v.rhs, TYPE_BOOL)
	if lhs == INVALID_TYPE || rhs == INVALID_TYPE {
		return
	}
	if reject_simd_logical(k, v, lhs, rhs) {
		return
	}
	// Nominal (design.md "Distinct types"): a distinct `bool` has only comparisons.
	if !type_is_boolean(k.c, lhs) || !type_is_boolean(k.c, rhs) ||
	   type_kind(k.c, lhs) == .Distinct || type_kind(k.c, rhs) == .Distinct {
		operator_mismatch2(k, v.op_span, v.op, lhs, rhs)
		return
	}
	left, right := expr_base(v.lhs), expr_base(v.rhs)
	both_untyped := type_is_untyped(k.c, lhs) && type_is_untyped(k.c, rhs)
	if !both_untyped {
		materialize(k, v.lhs, TYPE_BOOL)
		materialize(k, v.rhs, TYPE_BOOL)
	}
	v.type = both_untyped ? TYPE_UNTYPED_BOOL : TYPE_BOOL
	if !base_is_const(left) {
		return
	}
	short_circuit := v.op == .And_And ? !left.const_value.boolean : left.const_value.boolean
	if short_circuit {
		v.const_value = bool_const(v.op == .Or_Or)
		return
	}
	if base_is_const(right) {
		v.const_value = bool_const(right.const_value.boolean)
	}
}

// design.md "Arithmetic operators": the shift count is an integer, a signed one
// panicking when negative, or an untyped constant representable by an unsigned
// integer; an untyped left operand first takes the type it would have on its
// own.
@(private = "file")
check_shift :: proc(k: ^Checker, v: ^Expr_Binary, expected: Type_Id, left_type, rhs: Type_Id) {
	lhs := left_type
	if !shiftable_type(k.c, lhs) {
		operator_mismatch2(k, v.op_span, v.op, lhs, rhs)
		return
	}

	if !validate_shift_count(k, v.rhs, rhs) {
		return
	}

	right := expr_base(v.rhs)
	left := expr_base(v.lhs)
	v.type = lhs

	if !base_is_const(left) || !base_is_const(right) {
		// A runtime shift needs a concrete left operand to shift.
		if type_is_untyped(k.c, lhs) {
			target := shiftable_type(k.c, expected) && !type_is_untyped(k.c, expected) ? expected : default_type(k.c, lhs)
			if !materialize(k, v.lhs, target) {
				v.type = INVALID_TYPE
				return
			}
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
	v.const_value = folded
}

// What a built-in shift shifts. Nominal, as a `distinct` type's shift is its own.
@(private = "file")
shiftable_type :: proc(c: ^Compiler, type: Type_Id) -> bool {
	return type_kind(c, type) != .Distinct && (type_is_integer(c, type) || type_is_rune(c, type))
}

// Shared by `a << b` and `a <<= b`; the compound form checks its own operand here
// rather than against the destination's type.
check_shift_count :: proc(k: ^Checker, e: Expr) -> bool {
	type := check_single_expr(k, e)
	if type == INVALID_TYPE {
		return false
	}
	return validate_shift_count(k, e, type)
}

@(private = "file")
validate_shift_count :: proc(k: ^Checker, e: Expr, checked: Type_Id) -> bool {
	base := expr_base(e)
	// An unfixed count with a runtime part is an ordinary value of its default type.
	if type_is_untyped(k.c, checked) && !base_is_const(base) && !materialize(k, e, default_type(k.c, checked)) {
		return false
	}
	type := base.type
	if type_is_untyped(k.c, type) {
		if base.const_value.kind == .Integer || base.const_value.kind == .Rune {
			if bi_sign(base.const_value.integer) < 0 {
				errorf(k.c, expr_span(e), "L0356", "a shift count cannot be negative")
				return false
			}
			return materialize(k, e, TYPE_UINT)
		}
	} else if type_is_integer(k.c, type) {
		// design.md "Arithmetic operators": a constant negative count is an
		// error whatever the left operand is, so it never reaches run time.
		if base.const_value.kind == .Integer && bi_sign(base.const_value.integer) < 0 {
			errorf(
				k.c, expr_span(e), "L0356", "a shift count cannot be negative, found %s",
				bi_text(k.c, base.const_value.integer),
			)
			return false
		}
		return true
	}
	errorf(
		k.c,
		expr_span(e),
		"L0356",
		"a shift count must have an integer type, found `%s`",
		type_name(k.c, type),
	)
	return false
}

@(private = "file")
check_comparison :: proc(k: ^Checker, v: ^Expr_Binary, operand_type: Type_Id) {
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
			if blocker := record_order_blocker(k.c, operand_type); blocker != "" {
				add_notef(k.c, v.op_span, "an anonymous record is ordered when every field is; %s", blocker)
			}
		}
		return
	}
	if !ordered && !type_is_comparable(k.c, operand_type) {
		errorf(k.c, v.op_span, "L0355", "`%s` is not comparable", type_name(k.c, operand_type))
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
		return
	}

	owned := make([dynamic]Type_Id, context.temp_allocator)
	if !ordered {
		own_equalities_within(k.c, operand_type, &owned)
		if !own_equalities_visible(k, owned[:], operand_type, v.op_span) {
			return
		}
	}

	left, right := expr_base(v.lhs), expr_base(v.rhs)
	// Unfixed operands with a runtime part compare as ordinary values.
	if type_is_untyped(k.c, operand_type) && (!base_is_const(left) || !base_is_const(right)) {
		target := unfixed_receiver_type(k.c, operand_type)
		if !materialize(k, v.lhs, target) || !materialize(k, v.rhs, target) {
			return
		}
	}
	// A user `==` runs when the program does, not while it is checked.
	if base_is_const(left) && base_is_const(right) && len(owned) == 0 {
		result, ok := fold_comparison(k.c, v.op, left.const_value, right.const_value)
		if ok {
			v.type = TYPE_UNTYPED_BOOL
			v.const_value = bool_const(result)
			return
		}
	}
	v.type = TYPE_BOOL
}

// design.md "Maps": one type has one equality, so a part whose inherent `==` is
// not `@(public)` cannot be compared field-wise from here either.
own_equalities_visible :: proc(k: ^Checker, owned: []Type_Id, compared: Type_Id, span: Span) -> bool {
	for part in owned {
		_, declared := own_equality(k.c, part)
		sym := symbol_of(k.c, declared)
		if sym == nil || member_is_visible(k, sym) {
			continue
		}
		errorf(
			k.c, span, "L0355",
			"`%s` holds `%s`, whose inherent `==` is not `@(public)`, so this package cannot compare it",
			type_name(k.c, compared), type_name(k.c, part),
		)
		return false
	}
	return true
}

// One untyped operand takes the other's concrete type; two untyped operands
// meet at the wider untyped kind (design.md "Arithmetic operators").
@(private = "file")
unify_operands :: proc(k: ^Checker, lhs, rhs: Expr, op_span: Span, comparing := false) -> (Type_Id, bool) {
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
		// A comparison needs no value of the merged type: an integer constant
		// compares with a float one exactly, unrounded (design.md "Comparison
		// operators").
		if comparing && merged == TYPE_UNTYPED_FLOAT && (left.const_value.kind == .Integer || right.const_value.kind == .Integer) {
			return merged, true
		}
		if !materialize(k, lhs, merged) || !materialize(k, rhs, merged) {
			return INVALID_TYPE, false
		}
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
	// design.md "Implicit type conversions": a named procedure beside a value of
	// a distinct procedure type takes that type, as `10` does in `a < 10`.
	if procedure_constant_converts(k.c, rhs, lt) {
		return lt, true
	}
	if procedure_constant_converts(k.c, lhs, rt) {
		return rt, true
	}
	joined, joins := join_operand_types(k, lt, rt)
	if !joins {
		operand_mismatch(k, op_span, lt, rt)
		return INVALID_TYPE, false
	}
	if (lt != joined && !materialize(k, lhs, joined)) || (rt != joined && !materialize(k, rhs, joined)) {
		return INVALID_TYPE, false
	}
	return joined, true
}

// The type two operands meet at, decided without materialising or reporting,
// so operator lookup asks exactly what `unify_operands` then does.
join_operand_types :: proc(k: ^Checker, lt, rt: Type_Id) -> (Type_Id, bool) {
	if lt == rt {
		return lt, true
	}
	if type_kind(k.c, lt) == .Proc && type_kind(k.c, rt) == .Proc {
		plain := erase_proc_contract(k.c, lt)
		return plain, plain == erase_proc_contract(k.c, rt)
	}
	left_untyped := type_is_untyped(k.c, lt)
	right_untyped := type_is_untyped(k.c, rt)
	switch {
	case left_untyped && right_untyped:
		return merge_untyped_types(lt, rt)
	case left_untyped:
		return rt, assignable(k.c, lt, rt)
	case right_untyped:
		return lt, assignable(k.c, rt, lt)
	}
	// design.md "Comparison operators": either operand may be assignable to the
	// other. A `string` meets a `string_view` at the view, the one both sides can
	// produce without allocating (design.md "Arithmetic operators"), a `^mut T`
	// the `^T` beside it, and the smaller union the larger (design.md "Widening by
	// label").
	if assignable(k.c, lt, rt) {
		return rt, true
	}
	if assignable(k.c, rt, lt) {
		return lt, true
	}
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
	// design.md "Implicit type conversions": a rune constant never becomes a
	// float, so the two meet at neither.
	if min(ra, rb) == 2 && max(ra, rb) == 3 {
		return INVALID_TYPE, false
	}
	return ra > rb ? a : b, true
}

// ------------------------------------------------------------ conditional --

@(private = "file")
check_cond :: proc(k: ^Checker, v: ^Expr_Cond, expected: Type_Id) {
	cond := check_single_expr(k, v.cond, TYPE_BOOL)
	if cond != INVALID_TYPE && materialize(k, v.cond, TYPE_BOOL) && !type_is_boolean(k.c, expr_base(v.cond).type) {
		errorf(k.c, expr_span(v.cond), "L0355", "a condition must be `bool`, found `%s`", type_name(k.c, cond))
	}
	// design.md "Returned constructions": a returned conditional returns the arm
	// it selects.
	if v.returned {
		mark_returned(v.then)
		mark_returned(v.otherwise)
	}
	then_type := check_single_expr(k, v.then, expected)
	else_type := check_single_expr(k, v.otherwise, expected)
	if cond == INVALID_TYPE || then_type == INVALID_TYPE || else_type == INVALID_TYPE {
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
		return
	}
	v.type = result
	v.then = transfer_returned_operand(k, &v.base, v.then, result)
	v.otherwise = transfer_returned_operand(k, &v.base, v.otherwise, result)
	// design.md "Conditional expression": the result owns its value, so a place
	// operand is copied into it.
	v.then_clone = classify_costed_copy(k, v.then, result, .Conditional)
	v.else_clone = classify_costed_copy(k, v.otherwise, result, .Conditional)

	// Both branches are checked, but only the selected one is folded.
	condition := expr_base(v.cond)
	if !base_is_const(condition) {
		return
	}
	selected := condition.const_value.boolean ? expr_base(v.then) : expr_base(v.otherwise)
	if base_is_const(selected) {
		v.const_value = selected.const_value
	}
}

// A procedure literal in expression position is hoisted to its own module
// function. It has no closure, so `check_ident` rejects any name that lives in
// an enclosing procedure's frame.
@(private = "file")
check_proc_literal :: proc(k: ^Checker, v: ^Expr_Proc) {
	// The program has it, with its body checked, whatever checks it again.
	if v.hoisted {
		v.type = symbol_of(k.c, v.symbol).proc_type
		return
	}
	if !proc_shape_ok(k, v, is_value = true) {
		return
	}
	if v.symbol == INVALID_SYMBOL {
		v.symbol = new_symbol(k.c, Symbol {
			name = intern_identifier(k.c, "proc$literal"),
			span = v.span,
			kind = .Proc,
			pkg  = k.pkg,
			// Which procedure it is written in (`omitted_with_test`).
			def_scope = k.scope,
		})
	}
	outer_impl := k.impl_type
	k.impl_type = INVALID_TYPE
	defer k.impl_type = outer_impl
	resolve_proc_signature(k, v, v.symbol)
	symbol := symbol_of(k.c, v.symbol)
	if symbol == nil {
		return
	}
	symbol.proc_literal = v
	// design.md "`type` and `typeid`": a literal is always a runtime value.
	if !runtime_signature_ok(k, symbol, v.span) {
		return
	}
	v.type = symbol.proc_type
	// Not while speculatively checking an interface requirement.
	if pkg := package_of(k.c, k.pkg); pkg != nil && committing(k.c) {
		append(&pkg.hoisted_procs, v)
		v.hoisted = true
	}
	check_proc_body(k, v)
}

// -------------------------------------------------------------- materialise --

// The type `e`, of type `type`, takes when nothing selects one: its default
// type. An untyped `nil` has none, which this reports. An invalid `type` was
// already reported.
inferred_type :: proc(k: ^Checker, e: Expr, type: Type_Id) -> Type_Id {
	final := default_type(k.c, type)
	if final == INVALID_TYPE && type != INVALID_TYPE {
		errorf(k.c, expr_span(e), "L0310", "`nil` has no type to infer here")
	}
	return final
}

// Records the implicit conversion of `e` to `target` for the emitter and the
// provenance walker: an untyped constant folded at the target's width, a typed
// view, an erasure, or a splat. Reports a representability failure itself and
// returns false only when the value cannot live in the target type.
materialize :: proc(k: ^Checker, e: Expr, target: Type_Id) -> bool {
	base := expr_base(e)
	if target == INVALID_TYPE || base.type == INVALID_TYPE {
		return false
	}
	if type_is_enum(k.c, target) && type_is_untyped(k.c, base.type) {
		errorf(k.c, base.span, "L0310", "an enum requires a variant; use `%s.from_int(value)` to validate a backing integer", type_name(k.c, target))
		return false
	}
	// A `string` borrows as a `string_view` with no validation: it is already
	// valid UTF-8.
	if type_views_as(k.c, base.type, target) {
		// A named constant array is viewed in its read-only storage.
		if base_is_const(base) && underlying_kind(k.c, base.type) == .Array {
			request_materialization(k, e)
		}
		base.view_from = base.type
		base.type = target
		return true
	}
	// design.md "SIMD vectors": a scalar of the lane type splats, at run time or
	// folded here, as a typed constant such as `T(0)` in a generic body does; an
	// unfixed constant folds below.
	if type_is_simd(k.c, target) && !type_is_simd(k.c, base.type) && (!base_is_const(base) || !type_is_untyped(k.c, base.type)) {
		element := underlying_info(k.c, target).element
		// The scalar must be a valid lane before it becomes the vector.
		if base.type != element && !materialize_value_expr(k, e, element, "splat") {
			return false
		}
		if !base_is_const(base) {
			base.splat_from = base.type
			base.type = target
			return true
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
	// design.md "Borrowed callable views": the procedure or capture value is
	// kept for the backend to hold or take the address of.
	if signature := dyn_proc_signature(k.c, target); signature != INVALID_TYPE && base.type != target &&
	   base.erased_from == INVALID_TYPE && dyn_proc_accepts(k.c, base.type, signature) {
		// design.md "Escape levels": a procedure meets the signature as it would
		// converting to it, inferred contract included.
		record_proc_contract_check(k.c, base.type, signature, base.span)
		request_dyn_proc_view(k, base.type, target, base.span)
		base.erased_from = base.type
		base.type = target
		return true
	}
	// design.md "Widening by label": the tag is remapped and the payload moved
	// into the larger storage, so the backend and the evaluator need the source.
	// A constant is remapped here.
	if union_widens_to(k.c, base.type, target) {
		if base.const_value.kind == .Aggregate {
			base.const_value = widen_const(k.c, base.const_value, base.type, target)
		} else if base.widened_from == INVALID_TYPE {
			base.widened_from = base.type
		}
		base.type = target
		return true
	}
	if !type_is_untyped(k.c, base.type) {
		record_proc_contract_check(k.c, base.type, target, base.span)
		return true
	}
	if !base_is_const(base) {
		return materialize_unfixed_parts(k, e, target)
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
			report_unrepresentable(k, base, merged)
			return false
		}
		base.type = merged
		base.const_value = converted
		return true
	}
	converted, fits := convert_const(k.c, base.const_value, target, false)
	if !fits || !nil_converts(k.c, base.type, target) {
		report_unrepresentable(k, base, target)
		return false
	}
	base.type = target
	base.const_value = converted
	return true
}

// `a if c else b` with a runtime condition is unfixed but not constant, and so
// is arithmetic over one: the parts take the type, and the operator runs at it.
@(private = "file")
materialize_unfixed_parts :: proc(k: ^Checker, e: Expr, target: Type_Id) -> bool {
	base := expr_base(e)
	#partial switch v in e {
	case ^Expr_Cond:
		if !materialize(k, v.then, target) || !materialize(k, v.otherwise, target) {
			return false
		}
		base.type = expr_base(v.then).type
	case ^Expr_Binary:
		if !materialize(k, v.lhs, target) || !materialize(k, v.rhs, target) {
			return false
		}
		base.type = expr_base(v.lhs).type
		if v.op != .And_And && v.op != .Or_Or && !builtin_operator_applies(k.c, v.op, base.type) {
			operator_mismatch2(k, v.op_span, v.op, base.type, expr_base(v.rhs).type)
			return false
		}
	case ^Expr_Unary:
		if !materialize(k, v.operand, target) {
			return false
		}
		base.type = expr_base(v.operand).type
		if !builtin_unary_defined(k, v.op, base.type) {
			operator_mismatch(k, v.op_span, v.op, base.type)
			return false
		}
	case:
		// Nothing to pass the type to, so `materialize_value_expr` compares the default.
		if !type_is_untyped(k.c, target) {
			base.type = default_type(k.c, base.type)
		}
	}
	return true
}

@(private = "file")
report_unrepresentable :: proc(k: ^Checker, base: ^Expr_Base, target: Type_Id) {
	switch base.const_value.kind {
	case .Integer, .Rune:
		// design.md "Implicit type conversions": a rune constant converts to
		// integer types, but not to floating-point ones.
		if base.const_value.kind == .Rune && (underlying_kind(k.c, target) == .Float || type_kind(k.c, target) == .Untyped_Float) {
			errorf(
				k.c, base.span, "L0353", "a rune does not convert implicitly to `%s`; write `%s(...)` to convert it",
				type_name(k.c, target), type_name(k.c, target),
			)
			return
		}
		errorf(
			k.c,
			base.span,
			"L0352",
			"%s is not representable by `%s`",
			bi_text(k.c, base.const_value.integer),
			type_name(k.c, target),
		)
	case .Float:
		if type_is_integer(k.c, target) {
			errorf(
				k.c, base.span, "L0353", "a float does not convert implicitly to `%s`; an explicit `%s(...)` truncates it",
				type_name(k.c, target), type_name(k.c, target),
			)
			return
		}
		errorf(k.c, base.span, "L0353", "%v is not representable by `%s`", base.const_value.float, type_name(k.c, target))
	case .Nil:
		errorf(k.c, base.span, "L0310", "`nil` is not a value of `%s`", type_name(k.c, target))
		// design.md "Zero values": `nil` names only a null address.
		// The braces are not in the format string, where `{` is a directive.
		if type_is_slice(k.c, target) || underlying_kind(k.c, target) == .String_View {
			add_notef(k.c, base.span, "the empty `%s` is written %s, and emptiness is `.len() == 0`", type_name(k.c, target), "`{}`")
		} else if type_has_zero(k.c, target) {
			add_notef(k.c, base.span, "the zero value of `%s` is written %s", type_name(k.c, target), "`{}`")
		} else {
			name := type_name(k.c, target)
			add_notef(k.c, base.span, "a `%s` always has a value; one that may be absent is an `Option(%s)`", name, name)
		}
	case .String:
		if !utf8.valid_string(base.const_value.text) {
			report_invalid_utf8(k, base.span, target)
			return
		}
		fallthrough
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

// design.md "Type conversion": an integer constant converts only to a type that
// holds it, where a runtime one would panic. False when `value` is not an
// integer bound for an integer type, which is some other conversion's failure.
report_constant_out_of_range :: proc(c: ^Compiler, span: Span, value: Const_Value, target: Type_Id) -> bool {
	if (value.kind != .Integer && value.kind != .Rune) ||
	   !(type_is_integer(c, target) || type_is_rune(c, target)) || type_is_untyped(c, target) {
		return false
	}
	errorf(
		c, span, "L0712",
		"the value %s does not fit `%s`; `math.wrap(%s, value)` keeps its low bits, and `math.to` tests whether it fits",
		bi_text(value_allocator(c, {}), value.integer), type_name(c, target), type_name(c, target),
	)
	return true
}

// design.md "The `unsafe` package": the file's `core:unsafe` import is what
// marks it for review. `base:` packages are the language's own runtime, which
// cannot import `core:`; a span in no source file is compiler-synthesized.
require_unsafe_import :: proc(k: ^Checker, span: Span, what: string) -> bool {
	pkg := package_holding_file(k.c, k.pkg, span.file)
	if pkg == nil || strings.has_prefix(pkg.key, "base:") {
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

// The package `file` belongs to, or nil. Usually `likely`, the package being
// checked, so that is asked first.
@(private = "file")
package_holding_file :: proc(c: ^Compiler, likely: Package_Id, file: u32) -> ^Package {
	holds :: proc(pkg: ^Package, file: u32) -> bool {
		for f in pkg.files {
			if f.file == file {
				return true
			}
		}
		return false
	}
	first := package_of(c, likely)
	if first != nil && holds(first, file) {
		return first
	}
	for pkg in c.packages {
		if pkg != first && holds(pkg, file) {
			return pkg
		}
	}
	return nil
}

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

is_const_expr :: proc(e: Expr) -> bool {
	base := expr_base(e)
	return base != nil && base_is_const(base)
}

operator_text :: proc(op: Token_Kind) -> string {
	if op == .In {
		return "in"
	}
	text := operator_spelling(op)
	return text != "" ? text : "?"
}

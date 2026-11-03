// Expressions and their implicit conversion to a destination.
//
// `check.odin` owns declarations and statements; everything that produces a
// value is dispatched here. Call checking and binding live in `check_calls.odin`,
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
		if shape, ok := fallible_of(k, expr_base(v.owner.operand).type); ok {
			v.type = shape.info.variants[shape.failure]
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
			base.is_const = true
			base.const_value = type_const(denoted)
		} else {
			report_unresolved_type(k, e)
		}
	}
	// design.md "`type` and `typeid`": a call to a compile-time-only procedure
	// runs in the compiler where it is checked, so its result is a constant.
	if call, is_call := e.(^Expr_Call); is_call && base.type != INVALID_TYPE && !base.is_const {
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
		note_union_widening(k, expr_span(e), final, target)
		note_mutable_slicing(k, e, final, target)
		note_named_callable(k, e, final, target)
		return false
	}
	return true
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
		v.is_const = true
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
		v.is_const = true
		v.const_value = float_const(value, 64)
		v.const_value.text = text

	case .Rune:
		value, ok := decode_rune_literal(v.text)
		if !ok {
			errorf(k.c, v.span, "L0351", "`%s` is not a valid character literal", v.text)
			return
		}
		v.type = TYPE_UNTYPED_RUNE
		v.is_const = true
		v.const_value = rune_const(bi_from_i64(k.c, i64(value)))

	case .String, .Raw_String:
		text, ok := decode_string_literal(k.c, v.text, v.kind == .Raw_String)
		if !ok {
			errorf(k.c, v.span, "L0351", "`%s` is not a valid string literal", v.text)
			return
		}
		v.type = TYPE_UNTYPED_STRING
		v.is_const = true
		v.const_value = Const_Value{kind = .String, text = text}
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
		v.is_const = true
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
		v.type = sym.proc_type
		// A member a probe synthesized is emitted once a value use commits it.
		enroll_synth(k.c, symbol_id)
		if reject_test_procedure_use(k, sym, name, v.span) {
			v.type = INVALID_TYPE
			return
		}
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

	case .Const, .Enum_Member:
		v.resolution = Resolution{kind = .Value, symbol = symbol_id}
		v.type = sym.type
		v.is_const = true
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
		if ident, is_ident := v.operand.(^Expr_Ident); is_ident {
			alias := lookup_symbol(k.scope, identifier_of(k.c, ident))
			if sym := symbol_of(k.c, alias); sym != nil && sym.kind == .Package_Alias {
				annotate_package_alias(ident, alias)
				return
			}
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
	if ident, is_ident := v.operand.(^Expr_Ident); is_ident {
		alias := lookup_symbol(k.scope, identifier_of(k.c, ident))
		if sym := symbol_of(k.c, alias); sym != nil && sym.kind == .Package_Alias {
			check_package_selector(k, v, ident, alias, callee)
			return
		}
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
	member := enum_member(k.c, enum_type, v.name.id)
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
	v.is_const = true
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
		if member := enum_member(k.c, enum_type, v.name.id); member != INVALID_SYMBOL {
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

// A field, declared or promoted, then a method. The operand is an ordinary value.
@(private = "file")
check_value_selector :: proc(k: ^Checker, v: ^Expr_Selector, checked: Type_Id, callee: bool) {
	operand := checked
	// design.md "Owned values": a box reaches its payload's fields and methods as
	// a pointer does, after its own members such as `clone`. The hop is written
	// into the typed AST as `b^`, which every later pass already understands.
	if boxed := underlying_info(k.c, operand); boxed != nil && boxed.kind == .Box {
		path := make([dynamic]Symbol_Id, 0, 4, context.temp_allocator)
		found, ambiguous := promoted_field_path(k.c, boxed.element, v.name.id, &path, 0)
		if !found && !ambiguous && select_method(k, v, operand, callee) {
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
	// design.md "Promoted struct fields": a declared field wins, then one reached
	// through `using` fields. `e.x` becomes the checked chain `e.position.x`.
	path := make([dynamic]Symbol_Id, 0, 4, context.temp_allocator)
	found, ambiguous := promoted_field_path(k.c, base_type, v.name.id, &path, 0)
	if ambiguous {
		errorf(k.c, v.span, "L0703", "`%s` is promoted into `%s` by more than one `using` field; select it explicitly", v.name.text, type_name(k.c, operand))
		return
	}
	if found {
		current_type, current_base := operand, expr_base(v.operand)
		for link in path[:len(path) - 1] {
			link_name := symbol_of(k.c, link).name
			inner := new(Expr_Selector, k.c.semantic_allocator)
			inner.span = v.span
			inner.operand = v.operand
			inner.name = Name{text = identifier_text(k.c, link_name), span = v.name.span, id = link_name}
			if !select_field(k, inner, current_type, current_base, through_pointer, pointer_mutable, link) {
				return
			}
			v.operand = inner
			current_type, current_base = inner.type, &inner.base
			through_pointer, pointer_mutable = false, false
		}
		select_field(k, v, current_type, current_base, through_pointer, pointer_mutable, path[len(path) - 1])
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
		   len(method_candidates(k, materialized, v.name.id)) == 0 {
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

// The `using` fields leading from `record` to a field named `name`, ending with
// that field. A field declared on a struct hides those promoted into it; two
// `using` fields that each lead to the name are ambiguous, whatever their
// depths (design.md "Promoted struct fields"). Only a by-value struct field
// promotes.
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
	inherit_capability(&n.base, base, true, mutable)
	n.op = .Caret
	n.op_span = base.span
	n.operand = operand
	return n
}

// A place inside what `owner` owns: a box's payload, a dynamic array's element, or
// a map's value. It has the owner's own capability.
@(private = "file")
owned_element_place :: proc(v: ^Expr_Base, element: Type_Id, owner: ^Expr_Base) {
	v.type = element
	v.value_category = .Place
	v.addressable = true
	v.assignable = owner.assignable
	v.immutable = owner.immutable
}

// The `b^` an implicit box dereference writes into the typed AST.
@(private = "file")
implicit_box_deref :: proc(k: ^Checker, operand: Expr, payload: Type_Id) -> Expr {
	base := expr_base(operand)
	n := new(Expr_Postfix, k.c.semantic_allocator)
	n.span = base.span
	n.op = .Caret
	n.op_span = base.span
	n.operand = operand
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
// receiver.
method_candidates :: proc(k: ^Checker, receiver: Type_Id, name: Identifier_Id) -> []Symbol_Id {
	all := member_candidates(k, receiver, name)
	if len(all) == 0 {
		return nil
	}
	out := make([dynamic]Symbol_Id, 0, len(all), k.c.semantic_allocator)
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

// ---------------------------------------------------------------- indexing --

@(private = "file")
check_index :: proc(k: ^Checker, v: ^Expr_Index, position: Expr_Position) {
	reach := operand_position(position)
	place, inserts := reach != .Value, position == .Insert
	// In `outer[key][i] = v` only the last index may insert; `outer[key]` must
	// already exist (design.md "Maps").
	operand := check_single_expr(k, v.operand, position = reach)
	if operand == INVALID_TYPE {
		return
	}

	// design.md "Owned values": `b[i]` indexes the payload.
	if boxed := underlying_info(k.c, operand); boxed != nil && boxed.kind == .Box {
		v.operand = implicit_box_deref(k, v.operand, boxed.element)
		operand = boxed.element
	}

	// Nominal (design.md "Distinct types"): a distinct type reaches
	// check_user_index, not the built-in table.
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
	// A carrier is reached through its header, so the hop is written as p^.
	if through_pointer && info != nil &&
	   (info.kind == .Slice || info.kind == .Dynamic_Array || info.kind == .Map || info.kind == .C_Pointer) {
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
		return
	}
	if info != nil && single {
		#partial switch info.kind {
		case .C_Pointer:
			// Unchecked, and writable exactly as `p^` is (design.md "C pointers").
			if !check_integer_index(k, v.indices[0]) { return }
			if !require_unsafe_import(k, v.span, "indexing a C pointer") {
				return
			}
			v.type = info.element
			v.value_category = .Place
			v.addressable = true
			v.assignable = true
			v.immutable = .None
			return
		case .Slice:
			// The element lives in the slice's root, so `[]mut T` decides the write,
			// not whether the slice variable itself is assignable.
			if !check_integer_index(k, v.indices[0]) { return }
			v.type = info.element
			v.value_category = .Place
			v.addressable = true
			v.assignable = info.mutable
			v.immutable = info.mutable ? .None : .Through_Slice
			return
		case .Dynamic_Array:
			// The element lives in the container's allocation, so it has the
			// container's capability (design.md "Dynamic arrays").
			if !check_integer_index(k, v.indices[0]) { return }
			owned_element_place(&v.base, info.element, operand_base)
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
		if check_user_index(k, v, operand, position) {
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
		return
	}

	check_array_index(k, v, info, base_type, operand_base, through_pointer, pointer_mutable)
}

// Whether `check_index` answers `operand[...]` itself. Built-in indexing takes
// one index and cannot be shadowed; a distinct type is nominal, so it never does.
index_is_builtin :: proc(c: ^Compiler, operand: Type_Id, indices: int) -> bool {
	info := type_of(c, operand)
	if info != nil && (info.kind == .Box || info.kind == .Pointer) {
		info = type_of(c, info.element)
	}
	if info == nil {
		return false
	}
	#partial switch info.kind {
	case .String, .String_View:
		return true
	case .C_Pointer, .Slice, .Dynamic_Array, .Map, .Simd, .Array:
		return indices == 1
	}
	return false
}

// `a[i]` for a fixed array.
@(private = "file")
check_array_index :: proc(
	k: ^Checker, v: ^Expr_Index, info: ^Type_Info, array: Type_Id, operand: ^Expr_Base,
	through_pointer, pointer_mutable: bool,
) {
	if !check_integer_index(k, v.indices[0]) {
		return
	}
	v.type = info.element
	v.value_category = .Place
	inherit_capability(&v.base, operand, through_pointer, pointer_mutable)

	index := expr_base(v.indices[0])
	// A constant indexed at runtime needs read-only storage (design.md
	// "Materialization"); a constant index folds below instead.
	if operand.is_const && !index.is_const && request_materialization(k, v.operand) {
		v.addressable = false
		v.assignable = false
		v.immutable = .Read_Only
	}
	if !index.is_const || (index.const_value.kind != .Integer && index.const_value.kind != .Rune) {
		return
	}
	value, ok := bi_to_i64(k.c, index.const_value.integer)
	if !ok || value < 0 || u64(value) >= info.count {
		errorf(
			k.c, expr_span(v.indices[0]), "L0361", "index %s is out of range for `%s`",
			bi_text(k.c, index.const_value.integer), type_name(k.c, array),
		)
		v.type = INVALID_TYPE
		return
	}
	if operand.is_const && operand.const_value.kind == .Aggregate {
		aggregate := operand.const_value.aggregate
		if aggregate != nil && int(value) < len(aggregate.elements) {
			v.is_const = true
			v.const_value = aggregate.elements[value]
			v.immutable = .Constant
		}
	}
}

// An index into a built-in sequence: an integer, `int` when unfixed.
check_integer_index :: proc(k: ^Checker, e: Expr) -> bool {
	type := check_single_expr(k, e, TYPE_INT)
	if type == INVALID_TYPE || !materialize(k, e, TYPE_INT) {
		return false
	}
	// design.md "Fixed arrays": an index has an integer or rune type.
	if index_type := expr_base(e).type; !type_is_integer(k.c, index_type) && !type_is_rune(k.c, index_type) {
		errorf(k.c, expr_span(e), "L0362", "an index must be an integer or rune, found `%s`", type_name(k.c, type))
		return false
	}
	return true
}

// `ok := key in m` (design.md "Maps") and `ok := x in low ..< high`
// (design.md "Ranges").
@(private = "file")
check_in :: proc(k: ^Checker, v: ^Expr_Binary) {
	// A written range takes its endpoint type from a typed element, so
	// `ch in 'a' ..= 'z'` tests a `u8` against a `Range(u8)`.
	if written, is_range := v.rhs.(^Expr_Range); is_range {
		element := check_single_expr(k, v.lhs)
		if element == INVALID_TYPE {
			return
		}
		hint := INVALID_TYPE
		if !type_is_untyped(k.c, element) && (type_is_integer(k.c, element) || type_is_rune(k.c, element)) {
			hint = range_type(k.c, element)
		}
		if check_single_expr(k, written, hint) == INVALID_TYPE {
			return
		}
		check_range_membership(k, v, written.type)
		return
	}
	container := check_single_expr(k, v.rhs)
	if container == INVALID_TYPE {
		return
	}
	if info := type_of(k.c, container); info != nil && info.is_range {
		if check_single_expr(k, v.lhs, info.element) == INVALID_TYPE {
			return
		}
		check_range_membership(k, v, container)
		return
	}
	if !type_is_map(k.c, container) {
		element := check_single_expr(k, v.lhs)
		if element == INVALID_TYPE {
			return
		}
		if check_user_binary(k, v, element, container) {
			return
		}
		errorf(
			k.c, v.op_span, "L0587",
			"`in` tests a `map[K]V` for a key or a `Range(T)` for a value, found `%s`", type_name(k.c, container),
		)
		return
	}
	if !check_map_key(k, v.lhs, container_key(k.c, container), true) {
		return
	}
	v.type = TYPE_BOOL
}

// design.md "Ranges": `x in r` holds when `r.low <= x` and `x` is below
// `r.high`, or at it for a closed range. The element is already checked.
@(private = "file")
check_range_membership :: proc(k: ^Checker, v: ^Expr_Binary, range: Type_Id) {
	element := type_of(k.c, range).element
	if !materialize_value_expr(k, v.lhs, element, "test a range of") {
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
	if key == TYPE_STRING && type == TYPE_STRING_VIEW {
		if borrows {
			return true
		}
		errorf(k.c, expr_span(e), "L0310", "an inserted key must be an owned `string`, found `string_view`")
		add_notef(k.c, no_span(), "`.copy()` makes a `string` from a `string_view`")
		return false
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
	owned_element_place(&v.base, info.element, operand)
	if inserts && !v.assignable {
		report_not_assignable(k, &v.base, "an inserting map index")
		v.type = INVALID_TYPE
	}
}

// design.md "Indexing and slicing": a place position requires the `inout`
// overload; any other position prefers the value one.
@(private = "file")
check_user_index :: proc(k: ^Checker, v: ^Expr_Index, operand: Type_Id, position: Expr_Position) -> bool {
	all := operator_candidates_for_receiver(k, "[]", operand)
	if len(all) == 0 {
		return false
	}
	candidates := select_by_place(k, all, operand_position(position) != .Value)
	if len(candidates) == 0 && position == .Sliced_Mutably {
		candidates = all
	}
	if len(candidates) == 0 {
		errorf(
			k.c,
			v.span,
			"L0419",
			"`%s` has no `operator([])` returning `inout`, so this is not a place",
			type_name(k.c, operand),
		)
		return true
	}

	args, ok := index_arguments(k, v.operand, v.indices, candidates)
	if !ok {
		return true
	}
	chosen, bound := resolve_operator(k, v.span, "[]", []Type_Id{operand}, args, among = candidates)
	if chosen == INVALID_SYMBOL {
		return true
	}
	v.bound = bound
	annotate_user_operator(k, &v.base, chosen)
	if operator_result_is_place(k, chosen) {
		v.value_category = .Place
		v.addressable = true
		v.assignable = true
		v.immutable = .None
	}
	return true
}

// `x[lo:hi]`: built in for a carrier, `operator([:])` for anything else.
@(private = "file")
check_slice :: proc(k: ^Checker, v: ^Expr_Slice, expected: Type_Id) {
	operand := check_single_expr(k, v.operand, position = v.mutable ? .Sliced_Mutably : .Value)
	if operand == INVALID_TYPE {
		return
	}
	if check_builtin_slice(k, v, operand) {
		return
	}
	all := operator_candidates_for_receiver(k, "[:]", operand)
	if len(all) == 0 {
		errorf(
			k.c, v.span, "L0362",
			"`%s` cannot be sliced; a user type needs an `operator([:])` overload",
			type_name(k.c, operand),
		)
		return
	}
	slicers := select_slicers(k, all, v.mutable)
	if len(slicers) == 0 {
		if v.mutable {
			errorf(
				k.c, v.span, "L0419",
				"`%s` has no `operator([:])` yielding a `[]mut T`, so it cannot be sliced mutably",
				type_name(k.c, operand),
			)
		} else {
			errorf(
				k.c, v.span, "L0419",
				"`%s` has only a mutable `operator([:])`; slice it with `&mut`, as in `&mut x[a:b]`",
				type_name(k.c, operand),
			)
		}
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
	args, ok := index_arguments(k, v.operand, endpoints, slicers)
	if !ok {
		if length_omitted && expr_base(v.hi).type == INVALID_TYPE {
			add_notef(k.c, v.span, "an omitted high endpoint is the operand's `len()`")
		}
		return
	}
	chosen, bound := resolve_operator(k, v.span, "[:]", []Type_Id{operand}, args, among = slicers)
	if chosen == INVALID_SYMBOL {
		return
	}
	v.bound = bound
	sym := annotate_user_operator(k, &v.base, chosen)
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

// design.md "Indexing and slicing": `&mut x[a:b]` selects the overload yielding
// `[]mut T`, and `x[a:b]` the one yielding anything else. The destination
// selects nothing.
@(private = "file")
select_slicers :: proc(k: ^Checker, all: []Symbol_Id, mutable: bool) -> []Symbol_Id {
	out := make([dynamic]Symbol_Id, 0, len(all), k.c.semantic_allocator)
	for candidate in all {
		if sym := symbol_of(k.c, candidate); sym != nil && slice_is_mutable(k.c, sym.result) == mutable {
			append(&out, candidate)
		}
	}
	return out[:]
}

// A variable, a field path, or a dereference: evaluating one twice reads the same
// place and runs nothing.
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

// design.md "Slices". False for anything but a built-in carrier.
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
	materialized := info.kind == .Array && request_materialization(k, v.operand)
	lo := v.lo == nil || check_slice_endpoint(k, v.lo)
	hi := v.hi == nil || check_slice_endpoint(k, v.hi)
	ok := lo && hi
	// The slice keeps its root's address, which a temporary would not outlive.
	if info.kind == .Array && !materialized && !base.addressable {
		errorf(k.c, v.span, "L0477", "`%s` has no storage to slice; bind it to a variable first", type_name(k.c, operand))
		ok = false
	}
	// A slice's elements are ordinary, aligned places (design.md "@(packed)").
	if field, packed := packed_field_reached(k, v.operand); packed && info.kind == .Array {
		errorf(k.c, v.span, "L0614", "cannot slice `%s`: it is reached through a packed struct", field)
		ok = false
	}
	v.immutable = .Temporary
	if info.kind == .C_Pointer && !require_unsafe_import(k, v.span, "slicing a C pointer") {
		ok = false
	}
	if !ok {
		return true
	}
	// design.md "Slices": `a[lo:hi]` is read-only; `&mut a[lo:hi]` asks for the
	// mutable capability, which the operand must have.
	#partial switch info.kind {
	case .Array, .Dynamic_Array:
		if v.mutable && !base.assignable {
			report_not_assignable(k, base, "sliced mutably")
			return true
		}
		v.type = slice_of(k.c, info.element, v.mutable)
	case .Slice:
		if v.mutable && !info.mutable {
			errorf(
				k.c, v.span, "L0478",
				"`%s` is read-only, and a read-only slice never becomes mutable", type_name(k.c, operand),
			)
			return true
		}
		v.type = slice_of(k.c, info.element, v.mutable)
	case .String, .String_View:
		if v.mutable {
			errorf(k.c, v.span, "L0478", "a string is immutable and cannot be sliced mutably")
			return true
		}
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

// The already-checked receiver, then every index, checked here once.
index_arguments :: proc(
	k: ^Checker,
	receiver: Expr,
	indices: []Expr,
	candidates: []Symbol_Id,
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

// ---------------------------------------------------------- packed fields --

// design.md "@(packed)": the name of a field that may be misaligned because
// it, or a field holding it in the same storage, sits in a packed struct.
@(private)
packed_field_reached :: proc(k: ^Checker, operand: Expr) -> (string, bool) {
	cur := operand
	for {
		name: string
		next: Expr
		#partial switch v in cur {
		case ^Expr_Ident:
			// A case binding over a packed field names that field.
			if sym := symbol_of(k.c, v.symbol); sym != nil && sym.packed_field != "" {
				return sym.packed_field, true
			}
			return "", false
		case ^Expr_Selector:
			name, next = v.name.text, v.operand
		case ^Expr_Index:
			// An embedded array's element shares the array's storage; any other
			// indexed container is separate storage.
			if underlying_kind(k.c, expr_base(v.operand).type) != .Array {
				return "", false
			}
			cur = v.operand
			continue
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
		struct_type := type_underlying(k.c, expr_base(next).type)
		through_pointer := false
		if info := type_of(k.c, struct_type); info != nil && info.kind == .Pointer {
			struct_type = type_underlying(k.c, info.element)
			through_pointer = true
		}
		if info := type_of(k.c, struct_type); info != nil && info.kind == .Struct && info.packed {
			return name, true
		}
		// A pointer's target is separate storage, aligned for its own type.
		if through_pointer {
			return "", false
		}
		cur = next
	}
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
		if !operand_base.addressable && operand_base.is_const && type_is_untyped(k.c, operand) {
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
			// The decimal spelling follows the sign, so `-(-x)` still rounds once.
			folded = float_const(-value.float, value.float_bits)
			if value.text != "" && value.text[0] == '-' {
				folded.text = value.text[1:]
			} else if value.text != "" {
				folded.text = strings.concatenate({"-", value.text}, k.c.semantic_allocator)
			}
		} else {
			folded = Const_Value{kind = value.kind, integer = bi_neg(k.c, value.integer)}
		}
	case .Tilde:
		folded = Const_Value{kind = value.kind, integer = bi_not(k.c, value.integer)}
	case .Not:
		folded = bool_const(!value.boolean)
	}
	if folded.kind == .Integer || folded.kind == .Rune {
		if v.op == .Minus && !integer_fits(k.c, folded.integer, v.type) {
			report_integer_overflow(k.c, v.op_span, folded.integer, v.type)
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
	if !operator_exists(k, operator_candidates(k, symbol, operands), operands) {
		return false
	}
	args := make([]Arg_Info, 1, k.c.semantic_allocator)
	args[0] = arg_from_expr(v.operand)
	chosen, bound := resolve_operator(k, v.op_span, symbol, operands, args)
	if chosen == INVALID_SYMBOL {
		return true
	}
	v.operand = bound[0]
	annotate_user_operator(k, &v.base, chosen)
	return true
}

// `v` as a call of the operator overload resolution chose.
@(private = "file")
annotate_user_operator :: proc(k: ^Checker, v: ^Expr_Base, chosen: Symbol_Id) -> ^Symbol {
	sym := symbol_of(k.c, chosen)
	v.resolution = Resolution{kind = .User_Operator, symbol = chosen, chosen_overload = chosen}
	v.type = sym.result
	return sym
}

// design.md "Operator declarations": `!=` falls back to `!(left == right)`
// when `==` is available and no more specific `!=` overload exists.
@(private = "file")
check_user_binary :: proc(k: ^Checker, v: ^Expr_Binary, lhs, rhs: Type_Id) -> bool {
	symbol := operator_text(v.op)
	operands := []Type_Id{lhs, rhs}
	args := make([]Arg_Info, 2, k.c.semantic_allocator)
	args[0] = arg_from_expr(v.lhs)
	args[1] = arg_from_expr(v.rhs)
	negate := false
	set := form_operator_set(k, symbol, operands, args)
	if !operator_viable(set) {
		equal := v.op == .Not_Eq ? form_operator_set(k, "==", operands, args) : Operator_Set{}
		if !operator_viable(equal) {
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

// design.md "Integer operators": a constant zero divisor is an error even when
// the dividend is only known at run time.
constant_zero_divisor :: proc(k: ^Checker, op: Token_Kind, op_span: Span, divisor: Expr) -> bool {
	value := expr_base(divisor)
	if (op != .Slash && op != .Percent) || !value.is_const ||
	   (value.const_value.kind != .Integer && value.const_value.kind != .Rune) ||
	   !bi_is_zero(value.const_value.integer) {
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

	if !left.is_const || !right.is_const {
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
	v.is_const = true
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
	if type_is_untyped(k.c, checked) && !base.is_const && !materialize(k, e, default_type(k.c, checked)) {
		return false
	}
	type := base.type
	if type_is_untyped(k.c, type) {
		if base.is_const && (base.const_value.kind == .Integer || base.const_value.kind == .Rune) {
			if bi_sign(base.const_value.integer) < 0 {
				errorf(k.c, expr_span(e), "L0356", "a shift count cannot be negative")
				return false
			}
			return materialize(k, e, TYPE_UINT)
		}
	} else if type_is_integer(k.c, type) {
		// design.md "Arithmetic operators": a constant negative count is an
		// error whatever the left operand is, so it never reaches run time.
		if base.is_const && base.const_value.kind == .Integer && bi_sign(base.const_value.integer) < 0 {
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
	if type_is_untyped(k.c, operand_type) && (!left.is_const || !right.is_const) {
		target := unfixed_receiver_type(k.c, operand_type)
		if !materialize(k, v.lhs, target) || !materialize(k, v.rhs, target) {
			return
		}
	}
	// A user `==` runs when the program does, not while it is checked.
	if left.is_const && right.is_const && len(owned) == 0 {
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

// design.md "Maps": one type has one equality, so a part whose inherent `==` is
// not `@(public)` cannot be compared field-wise from here either.
own_equalities_visible :: proc(k: ^Checker, owned: []Type_Id, compared: Type_Id, span: Span) -> bool {
	for part in owned {
		sym := symbol_of(k.c, type_own_equality_declared(k.c, part))
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
		// A comparison needs no value of the merged type, so an integer past every
		// float still orders against one.
		if comparing && (integer_exceeds_float(k, left) || integer_exceeds_float(k, right)) {
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

@(private = "file")
integer_exceeds_float :: proc(k: ^Checker, base: ^Expr_Base) -> bool {
	if !base.is_const || base.const_value.kind != .Integer {
		return false
	}
	_, fits := bi_to_float(k.c, base.const_value.integer, 64)
	return !fits
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
	case .Plus_Wrap, .Minus_Wrap, .Star_Wrap:
		// design.md "Integer overflow": the wrapping operators are for integers.
		return type_is_integer(c, type)
	case .Percent, .Amp, .Pipe, .Tilde, .Amp_Tilde:
		return type_is_integer(c, type) || type_is_rune(c, type)
	}
	return false
}

// ------------------------------------------------------------ conditional --

@(private = "file")
check_cond :: proc(k: ^Checker, v: ^Expr_Cond, expected: Type_Id) {
	cond := check_single_expr(k, v.cond, TYPE_BOOL)
	if cond != INVALID_TYPE && materialize(k, v.cond, TYPE_BOOL) && !type_is_boolean(k.c, expr_base(v.cond).type) {
		errorf(k.c, expr_span(v.cond), "L0355", "a condition must be `bool`, found `%s`", type_name(k.c, cond))
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
	// design.md "Conditional expression": the result owns its value, so a place
	// operand is copied into it.
	classify_copy_cost(k, v.then, result, .Conditional)
	classify_copy_cost(k, v.otherwise, result, .Conditional)
	v.then_clone = classify_copy(k, v.then, result, .Conditional)
	v.else_clone = classify_copy(k, v.otherwise, result, .Conditional)

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
	v.type = symbol.proc_type
	// design.md "`type` and `typeid`": a literal is always a runtime value.
	if !runtime_signature_ok(k, symbol, v.span) {
		v.type = INVALID_TYPE
		return
	}
	// Not while speculatively checking an interface requirement.
	if pkg := package_of(k.c, k.pkg); pkg != nil && committing(k.c) {
		append(&pkg.hoisted_procs, v)
		v.hoisted = true
	}
	check_proc_body(k, v)
}

// -------------------------------------------------------------- materialise --

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
		if base.is_const && underlying_kind(k.c, base.type) == .Array {
			request_materialization(k, e)
		}
		base.view_from = base.type
		base.type = target
		return true
	}
	// design.md "SIMD vectors": a scalar of the lane type splats, at run time or
	// folded here, as a typed constant such as `T(0)` in a generic body does; an
	// unfixed constant folds below.
	if type_is_simd(k.c, target) && !type_is_simd(k.c, base.type) && (!base.is_const || !type_is_untyped(k.c, base.type)) {
		element := type_of(k.c, type_underlying(k.c, target)).element
		// The scalar must be a valid lane before it becomes the vector.
		if base.type != element && !materialize_value_expr(k, e, element, "splat") {
			return false
		}
		if !base.is_const {
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
		if base.is_const && base.const_value.kind == .Aggregate {
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
	if !base.is_const {
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
	for pkg in k.c.packages {
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

operator_text :: proc(op: Token_Kind) -> string {
	if op == .In {
		return "in"
	}
	text := operator_spelling(op)
	return text != "" ? text : "?"
}

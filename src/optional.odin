// Checked extractions, variant switches, and the typed failure protocol.
package lokec

import "core:fmt"
import "core:slice"

// ---------------------------------------------------------- optional-ok --

Fallible :: struct {
	union_type: Type_Id,
	info:       ^Type_Info,
	failure:    int,
	success:    int,
}

failure_assignment_borrows :: proc(c: ^Compiler, from, into: Type_Id) -> bool {
	return underlying_kind(c, from) == .String && underlying_kind(c, into) == .String_View
}

fallible_of :: proc(k: ^Checker, type: Type_Id) -> (Fallible, bool) {
	info := type_of(k.c, type_underlying(k.c, type))
	if info == nil || info.kind != .Union || !info.failure_designated {
		return Fallible{}, false
	}
	return Fallible {
		union_type = type,
		info = info,
		failure = info.failure_variant,
		success = 1 - info.failure_variant,
	}, true
}

// design.md "Anonymous unions": one carries no attributes, so no alternative
// is its failure.
note_anonymous_union_is_data :: proc(k: ^Checker, type: Type_Id, span: Span) {
	if info := type_of(k.c, type_underlying(k.c, type)); info != nil && info.anonymous_union {
		add_notef(
			k.c, span,
			"an anonymous union is plain data; a failure is a `Result`, an `Option`, or a named union with `@(failure=name)`",
		)
	}
}

note_optional_replacement :: proc(k: ^Checker, e: Expr) {
	#partial switch v in e {
	case ^Expr_Index:
		if v.operand != nil && type_is_map(k.c, expr_base(v.operand).type) && !v.map_inserts {
			add_notef(k.c, expr_span(e), "`m[key]` reads one value; `m.lookup_value(key)` yields `Option(V)`")
		}
	}
}

check_or_else :: proc(k: ^Checker, v: ^Expr_Or_Else) {
	v.value_category = .Value
	if check_expr(k, v.value) == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}
	shape, is_fallible := fallible_of(k, expr_base(v.value).type)
	if !is_fallible {
		errorf(
			k.c,
			expr_span(v.value),
			"L0428",
			"`or_else` needs a union with a designated failure variant on its left, found `%s`",
			type_name(k.c, expr_base(v.value).type),
		)
		note_optional_replacement(k, v.value)
		note_anonymous_union_is_data(k, expr_base(v.value).type, expr_span(v.value))
		v.type = INVALID_TYPE
		return
	}
	// design.md "or_else expression": a success that carries nothing yields
	// `Unit`, as it does for `or_return`.
	payload := shape.info.variants[shape.success]
	if payload == TYPE_VOID {
		payload = k.c.unit_type
	}
	v.borrows = expr_base(v.value).value_category == .Place
	if v.borrows && type_clone_disabled(k.c, payload) {
		errorf(
			k.c, expr_span(v.value), "L0503",
			"`%s` is move-only, so `or_else` cannot copy it out of a place; write `move(...)`",
			type_name(k.c, payload),
		)
		v.type = INVALID_TYPE
		return
	}
	if v.borrows {
		contribute_lifecycle_members(k, payload)
	}
	// design.md "or_else expression": a failure that leaves supplies no value.
	if v.exit != nil {
		if !check_or_else_exit(k, v) {
			v.type = INVALID_TYPE
			return
		}
		if v.borrows {
			report_copy_cost(k, .Or_Else, expr_span(v.value), v.value, payload)
		}
		v.type = payload
		return
	}
	if !check_value_expr(k, v.fallback, payload, "supply") {
		v.type = INVALID_TYPE
		return
	}
	classify_copy_cost(k, v.fallback, payload, .Or_Else_Fallback)
	v.fallback_clone = classify_copy(k, v.fallback, payload, .Or_Else_Fallback)
	if type_clone_disabled(k.c, payload) && expression_is_borrowed_place(v.fallback) {
		v.type = INVALID_TYPE
		return
	}
	// design.md "Operator ownership": a place operand's success payload is
	// copied out, and only that copy is reported.
	if v.borrows {
		report_copy_cost(k, .Or_Else, expr_span(v.value), v.value, payload)
	}
	v.type = payload
}

// ----------------------------------------------------------- or_return --

check_or_return :: proc(k: ^Checker, v: ^Expr_Postfix) {
	v.value_category = .Value
	if k.proc_literal == nil {
		errorf(k.c, v.op_span, "L0429", "`or_return` is only valid inside a procedure")
		v.type = INVALID_TYPE
		return
	}
	if k.in_defer {
		errorf(k.c, v.op_span, "L0429", "`or_return` cannot appear inside a deferred statement")
		v.type = INVALID_TYPE
		return
	}
	if check_expr(k, v.operand) == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}
	base := expr_base(v.operand)
	shape, is_fallible := fallible_of(k, base.type)
	if !is_fallible {
		errorf(
			k.c,
			v.op_span,
			"L0429",
			"`or_return` needs a union with a designated failure variant, found `%s`",
			type_name(k.c, base.type),
		)
		note_anonymous_union_is_data(k, base.type, v.op_span)
		v.type = INVALID_TYPE
		return
	}
	if v.failure != nil {
		if !check_or_return_failure(k, v, shape) {
			v.type = INVALID_TYPE
			return
		}
	} else if !check_or_return_target(k, v, shape) {
		v.type = INVALID_TYPE
		return
	}
	v.borrows = base.value_category == .Place
	if v.borrows {
		for candidate, index in ([2]Type_Id{shape.info.variants[shape.success], shape.info.variants[shape.failure]}) {
			// A replacement leaves the error in its place, so only a mapped or
			// propagated one is copied out.
			if candidate == TYPE_VOID || (index == 1 && v.failure != nil && !v.failure_maps) {
				continue
			}
			if type_clone_disabled(k.c, candidate) {
				errorf(
					k.c, v.op_span, "L0503",
					"`%s` is move-only, so `or_return` cannot copy it out of a place; write `move(...)`",
					type_name(k.c, candidate),
				)
				v.type = INVALID_TYPE
				return
			}
			contribute_lifecycle_members(k, candidate)
		}
		// Either payload may be copied out of a place, so the report names the
		// whole fallible union.
		report_copy_cost(k, .Or_Return, expr_span(v.operand), v.operand, base.type)
	}

	success := shape.info.variants[shape.success]
	v.type = success == TYPE_VOID ? k.c.unit_type : success
}

// design.md "or_return operator": `operand or_return failure` returns the
// procedure's failure variant built from `failure`, which runs only when the
// operand fails. A value of the failure payload type replaces the error; any
// other operand is a mapper called with it.
@(private = "file")
check_or_return_failure :: proc(k: ^Checker, v: ^Expr_Postfix, shape: Fallible) -> bool {
	if k.result_type == INVALID_TYPE {
		errorf(k.c, v.op_span, "L0429", "`or_return` needs a result to propagate the failure into")
		return false
	}
	target, target_fallible := fallible_of(k, k.result_type)
	if !target_fallible {
		errorf(
			k.c,
			v.op_span,
			"L0429",
			"`or_return` needs this procedure's result to be a union with a designated failure variant, found `%s`",
			type_name(k.c, k.result_type),
		)
		return false
	}
	into := target.info.variants[target.failure]
	if into == TYPE_VOID {
		errorf(
			k.c, expr_span(v.failure), "L0429",
			"`%s.%s` carries nothing, so this `or_return` takes no failure operand",
			type_name(k.c, k.result_type), union_variant_name(k.c, k.result_type, target.failure),
		)
		return false
	}
	from := shape.info.variants[shape.failure]
	span := expr_span(v.failure)
	value := v.failure
	maps := false
	switch {
	case or_return_constructs(k, v.failure, into):
		// `.io` names a variant of the failure payload type, whose constructor
		// wraps the error (design.md "Constructing a variant").
		selector := v.failure.(^Expr_Selector)
		payload := union_variant_payload(k.c, into, union_index_of(k.c, into, selector.name.text))
		if from == TYPE_VOID || !assignable(k.c, from, payload) {
			errorf(
				k.c, span, "L0429", "`.%s` wraps `%s`, but this failure carries %s",
				selector.name.text, type_name(k.c, payload),
				from == TYPE_VOID ? "nothing" : fmt.tprintf("`%s`", type_name(k.c, from)),
			)
			if from != TYPE_VOID {
				note_union_widening(k, span, from, payload)
			}
			return false
		}
		maps = true
	case or_return_replaces(k, v.failure, into):
	case:
		maps = true
	}
	if maps {
		if from == TYPE_VOID {
			errorf(
				k.c, span, "L0429",
				"`%s.%s` carries no error to map; write the failure to return instead",
				type_name(k.c, shape.union_type), union_variant_name(k.c, shape.union_type, shape.failure),
			)
			return false
		}
		error := new(Expr_Propagated_Error, k.c.semantic_allocator)
		error.span = span
		error.owner = v
		call := new(Expr_Call, k.c.semantic_allocator)
		call.span = span
		call.callee = v.failure
		call.args = make([]Argument, 1, k.c.semantic_allocator)
		call.args[0] = Argument{span = span, value = error}
		value = call
	}
	v.failure_maps = maps
	// `.err(value)`, checked as the `return` it is.
	name := union_variant_name(k.c, k.result_type, target.failure)
	variant := new(Expr_Selector, k.c.semantic_allocator)
	variant.span = span
	variant.name = Name{text = name, span = span, id = intern_identifier(k.c, name)}
	wrap := new(Expr_Call, k.c.semantic_allocator)
	wrap.span = span
	wrap.callee = variant
	wrap.args = make([]Argument, 1, k.c.semantic_allocator)
	wrap.args[0] = Argument{span = span, value = value}
	exit := new(Stmt_Return, k.c.semantic_allocator)
	exit.span = span
	exit.value = new(Return_Value, k.c.semantic_allocator)
	exit.value.span = span
	exit.value.expr = wrap
	v.failure_exit = exit
	errors := k.c.error_count
	check_stmt(k, exit)
	if k.c.error_count == errors {
		return true
	}
	// `f() or_return.len()` reads `.len()` as the operand.
	if operand := expr_span(v.operand); span.lo == v.op_span.hi && operand.file == span.file {
		text := k.c.sources[span.file].text
		add_notef(
			k.c, span, "after `or_return`, `%s` is its failure operand; to reach the success payload, write `(%s or_return)%s`",
			text[span.lo:span.hi], text[operand.lo:operand.hi], text[span.lo:span.hi],
		)
	}
	return false
}

// `.name` of a variant of the failure payload type that carries a payload.
@(private = "file")
or_return_constructs :: proc(k: ^Checker, failure: Expr, into: Type_Id) -> bool {
	selector, is_selector := failure.(^Expr_Selector)
	if !is_selector || selector.operand != nil || !type_is_union(k.c, into) {
		return false
	}
	index := union_index_of(k.c, into, selector.name.text)
	if index < 0 {
		return false
	}
	payload := union_variant_payload(k.c, into, index)
	return payload != TYPE_VOID && payload != k.c.unit_type
}

// Whether the failure operand is a value of the failure payload type, decided on
// a probe of a copy so the real operand is checked once, in its role.
@(private = "file")
or_return_replaces :: proc(k: ^Checker, failure: Expr, into: Type_Id) -> bool {
	#partial switch v in failure {
	case ^Expr_Proc:
		return false
	case ^Expr_Literal, ^Expr_Composite:
		return true
	case ^Expr_Selector:
		if v.operand == nil {
			return true
		}
	}
	probe := begin_probe(k.c)
	defer end_probe(k.c, probe)
	trial := clone_expr(k.c, failure)
	errors := k.c.error_count
	type := check_single_expr(k, trial, into)
	return k.c.error_count == errors && type != INVALID_TYPE && assignable(k.c, type, into)
}

@(private = "file")
check_or_return_target :: proc(k: ^Checker, v: ^Expr_Postfix, shape: Fallible) -> bool {
	if k.result_type == INVALID_TYPE {
		errorf(k.c, v.op_span, "L0429", "`or_return` needs a result to propagate the failure into")
		return false
	}
	target, target_fallible := fallible_of(k, k.result_type)
	if !target_fallible {
		errorf(
			k.c,
			v.op_span,
			"L0429",
			"`or_return` needs this procedure's result to be a union with a designated failure variant, found `%s`",
			type_name(k.c, k.result_type),
		)
		return false
	}
	from := shape.info.variants[shape.failure]
	into := target.info.variants[target.failure]
	if from != into && !(from != TYPE_VOID && into != TYPE_VOID && assignable(k.c, from, into)) {
		errorf(
			k.c,
			v.op_span,
			"L0429",
			"the failure payload `%s` cannot be returned as `%s`",
			from == TYPE_VOID ? "()" : type_name(k.c, from),
			into == TYPE_VOID ? "()" : type_name(k.c, into),
		)
		if from != TYPE_VOID && into != TYPE_VOID {
			note_union_widening(k, v.op_span, from, into)
		}
		return false
	}
	return true
}

// ---------------------------------------------------------- type switch --

// A union subject turns `.name(binding)` and `.name(&mut binding)` calls into
// branch patterns, and `.name(a, &mut b)` into field bindings.
adopt_branch_patterns :: proc(k: ^Checker, s: ^Stmt_Switch) {
	s.kind = .Pattern
	for &entry in s.cases {
		if len(entry.values) != 1 {
			continue
		}
		if pattern, leaves, ok := branch_variant_pattern(k, entry.values[0]); ok {
			entry.values[0] = pattern
			if len(leaves) == 1 {
				entry.binding = leaves[0].name
				entry.binding_ref = leaves[0].is_ref
				continue
			}
			entry.fields = leaves
			for leaf in leaves {
				entry.binding_ref ||= leaf.is_ref
			}
		}
	}
}

@(private = "file")
branch_variant_pattern :: proc(k: ^Checker, value: Expr) -> (Expr, []Case_Field, bool) {
	call, is_call := value.(^Expr_Call)
	if !is_call || len(call.args) == 0 {
		return nil, nil, false
	}
	// A union case names `.variant`.
	selector, is_selector := call.callee.(^Expr_Selector)
	if !is_selector || selector.operand != nil {
		return nil, nil, false
	}
	leaves := make([]Case_Field, len(call.args), k.c.semantic_allocator)
	for arg, index in call.args {
		written := arg.value
		ref := false
		plain: ^Expr_Unary
		if unary, is_unary := written.(^Expr_Unary); is_unary && unary.op == .Amp {
			written, ref = unary.operand, true
			if !unary.mutable {
				plain = unary
			}
		}
		ident, is_ident := written.(^Expr_Ident)
		if !is_ident || arg.name.text != "" || arg.mode != .Value {
			return nil, nil, false
		}
		// design.md "Inspecting a union": `&` alone would read as a read-only
		// pointer, but the binding is a writable place. Bound anyway, so the case
		// reports only its spelling.
		if plain != nil {
			errorf(k.c, plain.op_span, "L0367", "a writable payload binding is written `&mut name`")
		}
		leaves[index] = Case_Field {
			name   = Name{text = ident.name, span = ident.span, id = ident.name_id},
			is_ref = ref,
		}
	}
	return call.callee, leaves, true
}

// design.md "Switch ownership": a `.name(&mut binding)` case makes the switch work
// on its subject's storage rather than on a copy.
switch_binds_place :: proc(s: ^Stmt_Switch) -> bool {
	for entry in s.cases {
		if entry.binding_ref {
			return true
		}
	}
	return false
}

check_type_switch :: proc(k: ^Checker, s: ^Stmt_Switch) -> Flow_Info {
	enter_statement_header(k, s.init)
	subject := check_single_expr(k, s.subject)
	if subject == INVALID_TYPE {
		return Flow_Info{}
	}
	return check_variant_cases(k, s, subject)
}

check_variant_cases :: proc(k: ^Checker, s: ^Stmt_Switch, subject: Type_Id) -> Flow_Info {
	if type_is_dyn(k.c, subject) {
		errorf(
			k.c,
			expr_span(s.subject),
			"L0466",
			"`%s` is a borrowed view and cannot be matched by type; add a slot for the behavior, or hold the alternatives in a union",
			type_name(k.c, subject),
		)
		return Flow_Info{}
	}
	if !expand_variant_cases(k, s, subject) {
		return Flow_Info{}
	}
	borrows := expression_is_borrowed_place(s.subject)
	// design.md "@(packed)": over a place reached through a packed struct, a
	// binding names a packed field.
	packed_subject := ""
	if borrows {
		packed_subject, _ = packed_field_reached(k, s.subject)
	}
	// design.md "Switch ownership": a mutable payload binding writes the
	// subject's own storage.
	if switch_binds_place(s) && !expr_base(s.subject).assignable {
		report_not_assignable(k, expr_base(s.subject), "switched with a mutable payload binding")
		return Flow_Info{}
	}

	seen_variants := make([dynamic]int, 0, 8, context.temp_allocator)
	has_default := false
	flow := Flow_Info{}
	any_case_falls := false
	for &entry in s.cases {
		binding_type := subject
		payloadless := false
		if len(entry.values) == 0 {
			if has_default {
				errorf(k.c, entry.span, "L0367", "this switch already has a default case")
			}
			has_default = true
		}
		indices := make([dynamic]int, 0, len(entry.values), k.c.semantic_allocator)
		for value in entry.values {
			index := case_variant_index(k, subject, value)
			if index < 0 {
				continue
			}
			if slice.contains(seen_variants[:], index) {
				errorf(
					k.c, expr_span(value), "L0367",
					"`.%s` is already covered by an earlier case", union_variant_name(k.c, subject, index),
				)
				continue
			}
			append(&indices, index)
			append(&seen_variants, index)
		}
		entry.variant_indices = indices[:]
		// Grouped cases bind the union; singleton cases bind their payload.
		if len(entry.variant_indices) == 1 {
			payload := union_variant_payload(k.c, subject, entry.variant_indices[0])
			binding_type = payload == TYPE_VOID ? k.c.unit_type : payload
			if (entry.binding.text != "" || len(entry.fields) > 0) && payload == TYPE_VOID && entry.descriptor.aggregate == nil {
				span := entry.binding.span if entry.binding.text != "" else entry.fields[0].name.span
				errorf(
					k.c, span, "L0426",
					"the payloadless variant `.%s` has nothing to bind",
					union_variant_name(k.c, subject, entry.variant_indices[0]),
				)
				payloadless = true
			}
		}
		entry.binding_type = binding_type
		// Fields that cannot be bound are still declared, untyped, so the case
		// reports only its pattern.
		resolved := len(entry.fields) > 0 && len(entry.variant_indices) == 1 && !payloadless &&
			resolve_case_fields(k, &entry, binding_type, borrows)
		case_scope := k.scope
		k.scope = new_scope(k.c, case_scope, .Local)
		if entry.descriptor.aggregate != nil && len(entry.variant_indices) == 1 {
			bind_expanded_case(k, &entry, union_variant_payload(k.c, subject, entry.variant_indices[0]))
		}
		if len(entry.fields) == 0 {
			entry.binding_symbol = bind_case_name(k, case_scope, entry.binding, binding_type, entry.binding_ref, borrows)
			mark_packed_binding(k, entry.binding_symbol, entry.binding, entry.binding_ref, packed_subject)
		}
		packed_payload := resolved && underlying_info(k.c, binding_type).packed
		for &field in entry.fields {
			field.symbol = bind_case_name(k, case_scope, field.name, field.type, field.is_ref, borrows)
			origin := packed_subject
			if origin == "" && borrows && packed_payload {
				origin = field_name_at(k.c, binding_type, field.slot)
			}
			mark_packed_binding(k, field.symbol, field.name, field.is_ref, origin)
		}
		if !resolved {
			entry.fields = nil
		}
		before := len(k.c.diagnostics)
		case_flow := check_stmts(k, entry.stmts)
		if entry.arm != nil {
			check_expr(k, entry.arm, s.arm_expected)
		}
		note_expanded_case(k, entry, before)
		k.scope = case_scope

		flow.returns ||= case_flow.returns
		flow.breaks ||= case_flow.breaks
		flow.continues ||= case_flow.continues
		any_case_falls ||= case_flow.can_fall_through
	}

	exhaustive := has_default
	if !has_default {
		if variant_count(k.c, subject) == len(seen_variants) {
			exhaustive = true
		} else {
			report_uncovered_variants(k, s, subject, seen_variants[:])
		}
	}
	s.exhaustive = exhaustive
	return Flow_Info {
		can_fall_through = !exhaustive || any_case_falls || len(s.cases) == 0,
		returns          = flow.returns,
		breaks           = flow.breaks,
		continues        = flow.continues,
	}
}

// One name a case binds: the payload, or one of its fields. Over a place it
// names storage the subject still owns (design.md "Switch ownership").
@(private = "file")
bind_case_name :: proc(
	k: ^Checker, case_scope: ^Scope, binding: Name, type: Type_Id, is_ref, borrows: bool,
) -> Symbol_Id {
	if binding.text == "" || binding.text == "_" {
		return INVALID_SYMBOL
	}
	name := intern_identifier(k.c, binding.text)
	if _, declared := k.scope.names[name]; declared {
		errorf(k.c, binding.span, "L0304", "`%s` is already declared in this scope", binding.text)
		return INVALID_SYMBOL
	}
	outer, owner := lookup_symbol_with_scope(case_scope, name)
	if outer != INVALID_SYMBOL && (owner.kind == .Local || owner.kind == .Procedure) {
		errorf(k.c, binding.span, "L0305", "`%s` shadows an outer declaration", binding.text)
		note_shadowed_capture(k, outer)
	}
	reject_reserved_name(k, name, binding.span)
	symbol := new_symbol(k.c, Symbol {
		name       = name,
		span       = binding.span,
		kind       = .Var,
		type       = type,
		pkg        = k.pkg,
		owner_proc = k.proc_literal,
		immutable  = borrows && !is_ref,
		borrowed_binding = borrows ? .Switch_Payload : .None,
	})
	k.scope.names[name] = symbol
	return symbol
}

// design.md "@(packed)": a binding over a packed field is a copy that cannot
// be borrowed, so one that must be a writable place is rejected, and reported
// only there.
@(private = "file")
mark_packed_binding :: proc(k: ^Checker, symbol: Symbol_Id, binding: Name, is_ref: bool, field: string) {
	if field == "" {
		return
	}
	if is_ref {
		errorf(
			k.c, binding.span, "L0614",
			"cannot bind `%s` with `&mut`: it is reached through a packed struct", field,
		)
		return
	}
	if sym := symbol_of(k.c, symbol); sym != nil {
		sym.packed_field = field
	}
}

@(private = "file")
field_name_at :: proc(c: ^Compiler, record: Type_Id, slot: int) -> string {
	info := underlying_info(c, record)
	if info == nil || slot >= len(info.fields) {
		return ""
	}
	field := symbol_of(c, info.fields[slot])
	return field == nil ? "" : identifier_text(c, field.name)
}

// design.md "Inspecting a union": `.name(a, b)` destructures a record payload
// as a `foreach` header does an element, under the rules of design.md
// "Destructuring". Over a temporary the fields transfer, which a custom hook
// forbids.
@(private = "file")
resolve_case_fields :: proc(k: ^Checker, entry: ^Switch_Case, payload: Type_Id, borrows: bool) -> bool {
	span := entry.fields[0].name.span
	fields, eligible := destructure_fields(k, payload, len(entry.fields), span, "L0426", "bound by a case")
	if !eligible {
		return false
	}
	if !borrows && reject_hooked_destructure(k, payload, span) {
		return false
	}
	for &leaf, index in entry.fields {
		field := symbol_of(k.c, fields[index])
		if field == nil {
			return false
		}
		leaf.slot = int(field.index)
		leaf.type = field.type
	}
	return true
}

@(private = "file")
case_variant_index :: proc(k: ^Checker, subject: Type_Id, value: Expr) -> int {
	// A case the parser rejected has reported itself.
	if _, rejected := value.(^Expr_Error); rejected {
		return -1
	}
	sel, is_selector := value.(^Expr_Selector)
	if !is_selector || sel.operand != nil {
		errorf(k.c, expr_span(value), "L0426", "a union case names a variant: `case .name:`")
		return -1
	}
	index := union_variant_index(k.c, subject, intern_identifier(k.c, sel.name.text))
	if index < 0 {
		errorf(
			k.c, expr_span(value), "L0426",
			"`%s` has no variant `%s`", type_name(k.c, subject), sel.name.text,
		)
		return -1
	}
	sel.type = subject
	sel.variant_union = subject
	sel.variant_index = index
	sel.resolution = Resolution{kind = .Builtin_Operator}
	return index
}

@(private = "file")
report_uncovered_variants :: proc(k: ^Checker, s: ^Stmt_Switch, subject: Type_Id, covered: []int) {
	info := type_of(k.c, type_underlying(k.c, subject))
	if info == nil {
		return
	}
	missing := ""
	count := 0
	for _, index in info.variants {
		if slice.contains(covered, index) {
			continue
		}
		count += 1
		if count <= 3 {
			if missing != "" {
				missing = concat(k.c, missing, ", ")
			}
			missing = concat(k.c, missing, ".", union_variant_name(k.c, subject, index))
		}
	}
	if count == 0 {
		return
	}
	if count > 3 {
		missing = concat(k.c, missing, ", ...")
	}
	errorf(
		k.c,
		s.span,
		"L0427",
		"this switch over `%s` does not cover %s",
		type_name(k.c, subject),
		missing,
	)
}

// -------------------------------------------------------- success returns --

// design.md "One result": a body whose result is a fallible union whose
// success carries nothing or `Unit`, such as `Status(E)` or `Result(Unit, E)`,
// may reach its end, which returns that success. The `return` is appended, so
// every later phase sees the statement it means. Its span is empty, at the
// closing brace, so no query finds it.
implicit_success :: proc(k: ^Checker, literal: ^Expr_Proc, symbol: ^Symbol) -> bool {
	if literal.body == nil || !k.body.bare_success {
		return false
	}
	end := literal.body.span
	end.lo = max(end.hi, 1) - 1
	end.hi = end.lo
	exit := new(Stmt_Return, k.c.semantic_allocator)
	exit.span = end
	exit.value = bare_success_value(k, symbol.result, end)
	stmts := make([]Stmt, len(literal.body.stmts) + 1, k.c.semantic_allocator)
	copy(stmts, literal.body.stmts)
	stmts[len(stmts) - 1] = exit
	literal.body.stmts = stmts
	check_stmt(k, exit)
	return true
}

// The returned value that a body's bare success stands for, at an empty span.
bare_success_value :: proc(k: ^Checker, result: Type_Id, at: Span) -> ^Return_Value {
	shape, _ := fallible_of(k, result)
	value := new(Return_Value, k.c.semantic_allocator)
	value.span = at
	value.expr = success_selector(k, result, shape.success, at)
	return value
}

// The unchecked `.name` of `result`'s variant `index`, as a compiler-written
// statement spells it. An empty `at` keeps it out of every query.
@(private = "file")
success_selector :: proc(k: ^Checker, result: Type_Id, index: int, at: Span) -> ^Expr_Selector {
	name := union_variant_name(k.c, result, index)
	selector := new(Expr_Selector, k.c.semantic_allocator)
	selector.span = at
	selector.name = Name{text = name, span = at, id = intern_identifier(k.c, name)}
	return selector
}

// design.md "One result": whether a body may return its success by reaching
// its end or with `return;`. A payloadless success always may. A `Unit` one
// may when the result as written makes it `Unit`, so that a body generic over
// `Result(T, E)` means the same in an instance where `T` is `Unit` as in any
// other.
success_needs_no_value :: proc(k: ^Checker, scope: ^Scope, literal: ^Expr_Proc, symbol: ^Symbol) -> bool {
	if symbol.result_inout {
		return false
	}
	shape, fallible := fallible_of(k, symbol.result)
	if !fallible {
		return false
	}
	payload := shape.info.variants[shape.success]
	if payload == TYPE_VOID {
		return true
	}
	if payload != k.c.unit_type {
		return false
	}
	result := literal.signature.result
	return result == nil || !success_names_generic(k, scope, result.type, shape.success)
}

// Whether the success payload of a written fallible result depends on a
// generic argument bound in `scope`. `Result(Unit, E)` does not, though `E` is
// one; `Result(T, E)` and a bare `R` do.
@(private = "file")
success_names_generic :: proc(k: ^Checker, scope: ^Scope, syntax: Expr, success: int) -> bool {
	if !type_syntax_names_generic(k, scope, syntax) {
		return false
	}
	read_alias :: proc(k: ^Checker, id: Symbol_Id, success: int) -> (depends, is_alias: bool) {
		target, target_scope := local_alias_target(k, id)
		if target == nil {
			return false, false
		}
		saved := k.scope
		k.scope = target_scope
		defer k.scope = saved
		return success_names_generic(k, target_scope, target, success), true
	}
	#partial switch v in syntax {
	case ^Expr_Ident:
		// An alias means what it names, so `Outcome :: Result(Unit, E)` leaves the
		// success as `Unit` as written, and `Outcome :: Result(T, E)` does not.
		if depends, is_alias := read_alias(k, lookup_symbol(scope, identifier_of(k.c, v)), success); is_alias {
			return depends
		}
	case ^Expr_Selector:
		// `Local.Outcome` reads the same way. `T.Outcome` and `Box(T).Outcome` do
		// not, since which member they select depends on the argument.
		if type_syntax_names_generic(k, scope, v.operand) {
			return true
		}
		if depends, is_alias := read_alias(k, v.resolution.symbol, success); is_alias {
			return depends
		}
	case ^Expr_Call:
		template := generic_template_of_callee(k, v.callee, .Record)
		if template == nil {
			template = generic_template_of_callee(k, v.callee, .Alias)
		}
		if template == nil || len(v.args) != len(template.params) {
			return true
		}
		depends := success_parameters(k, template, success)
		for arg, i in v.args {
			if depends[i] && type_syntax_names_generic(k, scope, arg.value) {
				return true
			}
		}
		return false
	case ^Type_Record:
		if success < len(v.variants) {
			payload := v.variants[success].type
			return payload != nil && type_syntax_names_generic(k, scope, payload)
		}
	}
	return true
}

// Whether type syntax names a generic argument bound in `scope`, as
// `Result(T, Error)`, `Result($T, Error)`, or `[N + 1]int` does in an instance
// generic over `T` or `N`. Outside an instance nothing is bound, so nothing is
// walked.
type_syntax_names_generic :: proc(k: ^Checker, scope: ^Scope, e: Expr) -> bool {
	if !scope_in_instance(scope) {
		return false
	}
	lookup := Generic_Lookup{k = k, scope = scope, from = scope, followed = make([dynamic]Symbol_Id, context.temp_allocator)}
	return type_syntax_any_name(e, &lookup, names_generic_binding)
}

@(private = "file")
scope_in_instance :: proc(scope: ^Scope) -> bool {
	for enclosing := scope; enclosing != nil; enclosing = enclosing.parent {
		if enclosing.instance != nil {
			return true
		}
	}
	return false
}

// What a constant declared in a generic body stands for wherever it is named,
// and the scope that reads it: `Result(T, E)` for `Outcome :: Result(T, E)`, or
// `N * 2` for `Twice :: N * 2`. A package-scope constant cannot name a binding,
// and a declaration that defines something, such as `Local :: struct { x: T }`,
// is one type in each instance rather than a spelling of its arguments.
@(private = "file")
local_alias_target :: proc(k: ^Checker, id: Symbol_Id) -> (target: Expr, scope: ^Scope) {
	symbol := symbol_of(k.c, id)
	if symbol == nil || symbol.generic || symbol.decl == nil || symbol.decl.kind != .Const || !scope_in_instance(symbol.def_scope) {
		return nil, nil
	}
	// grammar.md "Declarations": a constant binds one name, and an incomplete
	// declaration may have no initializer.
	if len(symbol.decl.symbols) != 1 || symbol.decl.symbols[0] != id || len(symbol.decl.values) == 0 {
		return nil, nil
	}
	#partial switch _ in symbol.decl.values[0] {
	case ^Type_Record, ^Type_Enum, ^Type_Distinct, ^Type_Interface, ^Expr_Proc, ^Expr_Proc_Group, ^Expr_Operator:
		return nil, nil
	}
	return symbol.decl.values[0], symbol.def_scope
}

@(private = "file")
Generic_Lookup :: struct {
	k:        ^Checker,
	scope:    ^Scope,
	// Where the syntax is written. A selected member can name a binding this
	// scope does not bind: `B.Outcome` for `B :: Box(Unit)` reads `Box`'s own `$U`,
	// which is not a generic argument here.
	from:     ^Scope,
	// The aliases already read, since each answers once and a cyclic one, which
	// its declaration reports, must not be read forever.
	followed: [dynamic]Symbol_Id,
}

// A `$` name is a generic argument, and a local alias, named or selected from a
// type, depends on one through what it names (design.md "Success returns").
@(private = "file")
names_generic_binding :: proc(data: rawptr, node: Expr) -> bool {
	lookup := (^Generic_Lookup)(data)
	#partial switch v in node {
	case ^Expr_Ident:
		id := lookup_symbol(lookup.scope, identifier_of(lookup.k.c, v))
		symbol := symbol_of(lookup.k.c, id)
		if symbol == nil {
			return false
		}
		if symbol.generic_binding {
			return lookup_symbol(lookup.from, symbol.name) == id
		}
		return alias_names_generic(lookup, id)
	case ^Expr_Selector:
		return alias_names_generic(lookup, v.resolution.symbol)
	case ^Type_Poly:
		return true
	case ^Expr_Proc:
		return type_syntax_any_name(v.signature, data, names_generic_binding)
	}
	// A declaration defines its own type; its contents name no argument here.
	return false
}

// Whether the local alias `id`, if it is one, names a generic argument.
@(private = "file")
alias_names_generic :: proc(lookup: ^Generic_Lookup, id: Symbol_Id) -> bool {
	target, target_scope := local_alias_target(lookup.k, id)
	if target == nil || slice.contains(lookup.followed[:], id) {
		return false
	}
	append(&lookup.followed, id)
	saved := lookup.scope
	lookup.scope = target_scope
	defer lookup.scope = saved
	return type_syntax_any_name(target, lookup, names_generic_binding)
}

// What a returned expression's form says it builds (design.md "Success
// returns"), decided before it has a type.
@(private = "file")
Return_Target :: enum u8 {
	// A variant construction or implicit selector: the whole result.
	Result,
	// A composite literal or an unfixed constant, from which no union is built.
	Payload,
	// An expression with a type of its own: the result when it is assignable.
	Either,
}

@(private = "file")
return_target :: proc(e: Expr) -> Return_Target {
	#partial switch v in e {
	case ^Expr_Selector:
		if v.operand == nil {
			return .Result
		}
	case ^Expr_Call:
		if is_implicit_selector(v.callee) {
			return .Result
		}
	case ^Expr_Cond:
		if return_target(v.then) == .Result || return_target(v.otherwise) == .Result {
			return .Result
		}
	case ^Expr_Composite, ^Expr_Literal:
		return .Payload
	}
	return .Either
}

// Checks a returned value against the result. In a procedure whose result is
// a fallible union with a success payload, a value that is not the whole
// result is checked against the payload, and the statement becomes the
// `.ok(value)` it stands for (design.md "Success returns").
check_returned_value :: proc(k: ^Checker, value: ^Return_Value) -> bool {
	result := k.result_type
	e := value.expr
	target := return_target(e)
	shape, fallible := fallible_of(k, result)
	payload := fallible ? shape.info.variants[shape.success] : TYPE_VOID
	failure := fallible ? shape.info.variants[shape.failure] : TYPE_VOID
	// In a generic body the two payloads may be one type in some instance, so a
	// value meant as the error would become the success there.
	wraps := payload != TYPE_VOID && !(k.result_generic && failure != TYPE_VOID)
	if !wraps || target == .Result {
		errors := k.c.error_count
		if check_value_expr(k, e, result, "return") {
			return true
		}
		if fallible && k.c.error_count > errors {
			note_success_return(k, e, shape, target, wraps)
		}
		return false
	}

	type := check_single_expr(k, e, payload)
	if type == INVALID_TYPE {
		return false
	}
	untyped := type_is_untyped(k.c, type)
	// A call that never returns stands in for any value, the result included.
	if call_diverges(k.c, e) {
		expr_base(e).type = result
		return materialize_value_expr(k, e, result, "return")
	}
	if target == .Either && !untyped && assignable(k.c, type, result) {
		return materialize_value_expr(k, e, result, "return")
	}
	success := union_variant_name(k.c, result, shape.success)
	if type == TYPE_UNTYPED_NIL {
		report_returned_nil(k, e, shape)
		return false
	}
	if !untyped && !assignable(k.c, type, payload) {
		errorf(
			k.c, expr_span(e), "L0310",
			"cannot return `%s` from a procedure that returns `%s`: it is neither the result nor its `.%s` payload `%s`",
			type_name(k.c, type), type_name(k.c, result), success, type_name(k.c, payload),
		)
		note_success_return(k, e, shape, target, wraps)
		return false
	}
	if !materialize_value_expr(k, e, payload, "return") {
		return false
	}
	e = transfer_returned_local(k, e)
	if base := expr_base(e); base.value_category == .Place && type_clone_disabled(k.c, payload) {
		errorf(
			k.c, expr_span(e), "L0502",
			"`%s` is move-only, so a borrowed value of it cannot be returned by value; return a `move` parameter or a local instead",
			type_name(k.c, payload),
		)
		return false
	}
	value.expr = wrap_returned_success(k, e, shape)
	return true
}

// design.md "Success returns": `nil` is never an implicit success, so `return
// nil;` cannot be read as absence and silently be `.some(nil)`. Only an unchecked
// address takes `nil`, so only there is the success a fix to suggest.
@(private = "file")
report_returned_nil :: proc(k: ^Checker, e: Expr, shape: Fallible) {
	result := k.result_type
	payload := shape.info.variants[shape.success]
	success := union_variant_name(k.c, result, shape.success)
	failed := union_variant_name(k.c, result, shape.failure)
	if type_accepts_nil(k.c, payload) {
		errorf(
			k.c, expr_span(e), "L0310",
			"`nil` does not build `.%s` implicitly: write `.%s(nil)` for a success, or `.%s` for the failure",
			success, success, failed,
		)
	} else {
		errorf(
			k.c, expr_span(e), "L0310",
			"`nil` is not a value of `%s`, the `.%s` payload: write `.%s` for the failure",
			type_name(k.c, payload), success, failed,
		)
	}
}

// The checked `.ok(e)` a returned payload stands for.
@(private = "file")
wrap_returned_success :: proc(k: ^Checker, e: Expr, shape: Fallible) -> Expr {
	result := k.result_type
	at := expr_span(e)
	at.hi = at.lo
	call := new(Expr_Call, k.c.semantic_allocator)
	call.span = at
	callee := success_selector(k, result, shape.success, at)
	call.callee = callee
	call.args = make([]Argument, 1, k.c.semantic_allocator)
	call.args[0] = Argument{span = expr_span(e), value = e}
	check_union_variant_selector(k, callee, result, callee = true)
	finish_union_construct(k, call, result, shape.success, e)
	return call
}

// After a returned value fit nothing: name the variant that would take it.
@(private = "file")
note_success_return :: proc(k: ^Checker, e: Expr, shape: Fallible, target: Return_Target, wraps: bool) {
	result := k.result_type
	success := union_variant_name(k.c, result, shape.success)
	failure := union_variant_name(k.c, result, shape.failure)
	payload := shape.info.variants[shape.success]
	failure_payload := shape.info.variants[shape.failure]
	if selector, is_selector := e.(^Expr_Selector); is_selector && selector.operand == nil {
		// `return .Bad_Digit;` names a member of a payload, not a variant.
		id := intern_identifier(k.c, selector.name.text)
		switch {
		case type_has_member(k.c, failure_payload, id):
			add_notef(k.c, selector.span, "`.%s` belongs to the `.%s` payload: write `.%s(.%s)`", selector.name.text, failure, failure, selector.name.text)
		case type_has_member(k.c, payload, id):
			add_notef(k.c, selector.span, "`.%s` belongs to the `.%s` payload: write `.%s(.%s)`", selector.name.text, success, success, selector.name.text)
		}
		return
	}
	if target == .Result {
		return
	}
	type := expr_base(e).type
	switch {
	case type == INVALID_TYPE:
	case !wraps && payload != TYPE_VOID:
		add_notef(
			k.c, expr_span(e), "this result names a generic argument, so a returned value is never wrapped: write `.%s(value)` or `.%s(value)`",
			success, failure,
		)
	case failure_payload != TYPE_VOID && assignable(k.c, type, failure_payload):
		if payload == TYPE_VOID {
			add_notef(k.c, expr_span(e), "`.%s` carries nothing here; write `.%s(value)` to fail", success, failure)
		} else {
			add_notef(k.c, expr_span(e), "a returned value builds only `.%s`; write `.%s(value)` to fail", success, failure)
		}
	}
}

// Whether `type` is an enum with member `name` or a union with variant `name`.
@(private = "file")
type_has_member :: proc(c: ^Compiler, type: Type_Id, name: Identifier_Id) -> bool {
	if type == TYPE_VOID || type == INVALID_TYPE {
		return false
	}
	underlying := type_underlying(c, type)
	if type_is_enum(c, underlying) {
		return enum_member(c, underlying, name) != INVALID_SYMBOL
	}
	return union_variant_index(c, type, name) >= 0
}

// ------------------------------------------------------- or_else exits --

// design.md "or_else expression": `break`, `continue`, and `return value` in the
// fallback position are the statements, run where the failure is found.
@(private = "file")
check_or_else_exit :: proc(k: ^Checker, v: ^Expr_Or_Else) -> bool {
	exit_span := stmt_span(v.exit)
	_, is_return := v.exit.(^Stmt_Return)
	keyword := "return"
	if branch, is_branch := v.exit.(^Stmt_Branch); is_branch {
		keyword = branch.kind == .Break ? "break" : "continue"
	}
	if k.proc_literal == nil {
		errorf(k.c, exit_span, "L0718", "`or_else %s` is only valid inside a procedure", keyword)
		return false
	}
	if k.in_defer && (is_return || k.loop_depth <= k.defer_loop_depth) {
		errorf(k.c, exit_span, "L0369", "a deferred statement cannot leave the construct it is registered in")
		return false
	}
	if !is_return && k.loop_header {
		errorf(
			k.c, exit_span, "L0718",
			"`or_else %s` cannot appear in a loop's header; test the value in the body", keyword,
		)
		return false
	}
	errors := k.c.error_count
	flow := check_stmt(k, v.exit)
	if flow.breaks {
		k.loop_broken = true
	}
	return k.c.error_count == errors
}

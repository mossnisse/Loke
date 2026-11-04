// design.md "Static `foreach` expansion": the iterable folds to constants and
// one clone of the body is checked per element, so each copy may have its own
// static types. An expanded switch case and a union argument expansion clone
// per variant the same way: design.md "Per-variant switch cases" and
// design.md "Union argument expansion".
package lokec

import "core:slice"

check_static_foreach :: proc(k: ^Checker, s: ^Stmt_Foreach) -> Flow_Info {
	if len(s.bindings) == 0 {
		errorf(k.c, s.span, "L0454", "a `foreach` binds at least one name")
		return FLOWS
	}
	if !check_static_bindings(k, s.bindings, new_scope(k.c, k.scope, .Local)) { return FLOWS }

	// Reported once on the written body, not per copy. The copies are still
	// checked, so nothing else in the body goes unreported.
	outer_reported := k.branches_reported
	errors := k.c.error_count
	report_block_branches(k, s.body)
	k.branches_reported = k.c.error_count > errors
	defer k.branches_reported = outer_reported

	elements, element_type, folded := fold_static_iterable(k, s.iterable)
	if !folded {
		return FLOWS
	}

	blocks := make([dynamic]^Block, 0, len(elements), k.c.semantic_allocator)
	flow := FLOWS
	for element, index in elements {
		if copy_block, copy_flow := expand_one_element(k, s, element, element_type, index); copy_block != nil {
			append(&blocks, copy_block)
			flow_then(&flow, copy_flow)
		}
	}
	s.expansion = blocks[:]
	s.kind = .Static
	return flow
}

// The copy of the body for one element, and how it flows; a nil block when the
// element does not fit the bindings.
@(private = "file")
expand_one_element :: proc(
	k: ^Checker,
	s: ^Stmt_Foreach,
	element: Const_Value,
	element_type: Type_Id,
	index: int,
) -> (^Block, Flow_Info) {
	outer := k.scope
	k.scope = new_scope(k.c, outer, .Local)
	k.scope.expansion = index + 1
	defer k.scope = outer

	if !bind_static_pattern(k, s.bindings, element, element_type) {
		return nil, FLOWS
	}
	copy_block := clone_block(k.c, s.body)

	before := len(k.c.diagnostics)
	outer_loop, outer_expanded := k.loop_depth, k.expanded_in_loops
	k.loop_depth, k.expanded_in_loops = 0, outer_expanded + outer_loop
	flow := check_block(k, copy_block)
	k.loop_depth, k.expanded_in_loops = outer_loop, outer_expanded
	if len(k.c.diagnostics) > before {
		add_notef(
			k.c,
			s.span,
			"in static expansion %d, for `%s`",
			index,
			static_element_text(k.c, element, element_type),
		)
	}
	return copy_block, flow
}

// The `(element, index)` constant of an `.indexed()` iteration.
@(private = "file")
indexed_pair :: proc(c: ^Compiler, pair_type: Type_Id, element: Const_Value, index: int) -> Const_Value {
	parts := make([]Const_Value, 2, c.semantic_allocator)
	parts[ELEMENT_FIRST] = element
	parts[ELEMENT_SECOND] = int_const(c, i64(index))
	return aggregate_const(c, pair_type, parts)
}

// Checked once here, not per expanded element, so an empty iterable reports them
// too; `names` holds the header's names.
@(private = "file")
check_static_bindings :: proc(k: ^Checker, bindings: []Foreach_Binding, names: ^Scope) -> bool {
	for binding in bindings {
		if len(binding.group) > 0 {
			if !check_static_bindings(k, binding.group, names) { return false }
			continue
		}
		if !binding.is_static {
			errorf(
				k.c, binding.name.span, "L0454",
				"`%s` is a runtime binding in a static expansion; every binding carries `$`",
				binding.name.text,
			)
			return false
		}
		if binding.is_ref {
			errorf(k.c, binding.name.span, "L0454", "a static binding is immutable and cannot use `&`")
			return false
		}
		if !static_name_is_free(k, binding.name, names) {
			return false
		}
		if binding.name.text != "_" {
			names.names[name_identifier(k.c, binding.name)] = INVALID_SYMBOL
		}
	}
	return true
}

// The checks `declare_all` gives a local (design.md "Variable declarations"), for
// a static name going into `scope`. False when it cannot be declared.
@(private = "file")
static_name_is_free :: proc(k: ^Checker, name: Name, scope: ^Scope) -> bool {
	return name.text == "_" || name.text == "" || check_new_local(k, name, scope)
}

@(private = "file")
bind_static_pattern :: proc(
	k: ^Checker, bindings: []Foreach_Binding, value: Const_Value, type: Type_Id,
) -> bool {
	if len(bindings) == 1 {
		if len(bindings[0].group) > 0 {
			return bind_static_pattern(k, bindings[0].group, value, type)
		}
		bind_static(k, bindings[0].name, value, type)
		return true
	}
	fields, eligible := destructure_fields(k, type, len(bindings), bindings[0].name.span, "L0454", "bound by a `foreach`")
	if !eligible {
		return false
	}
	for slot in 0 ..< len(bindings) {
		field := symbol_of(k.c, fields[slot])
		part := value.aggregate.elements[field.index]
		if !bind_static_pattern(k, bindings[slot:][:1], part, field.type) { return false }
	}
	return true
}

@(private = "file")
bind_static :: proc(k: ^Checker, name: Name, value: Const_Value, type: Type_Id) {
	if name.text == "_" || name.text == "" {
		return
	}
	id := name_identifier(k.c, name)
	k.scope.names[id] = new_symbol(k.c, Symbol {
		name        = id,
		span        = name.span,
		kind        = .Const,
		type        = type,
		const_value = value,
		pkg         = k.pkg,
	})
}

// What a note says an element was: an `.indexed()` pair by its element, since the
// note gives the index, a descriptor by its name, and an enum member by its.
@(private = "file")
static_element_text :: proc(c: ^Compiler, value: Const_Value, type: Type_Id) -> string {
	info := underlying_info(c, type)
	if value.aggregate != nil && info != nil && info.kind == .Struct && len(info.fields) == 2 {
		element := symbol_of(c, info.fields[ELEMENT_FIRST]).type
		if type == indexed_element_type(c, element) {
			return static_element_text(c, value.aggregate.elements[ELEMENT_FIRST], element)
		}
	}
	// Every descriptor puts its name first.
	if type_is_descriptor(c, type) && value.aggregate != nil && len(value.aggregate.elements) > META_NAME {
		return value.aggregate.elements[META_NAME].text
	}
	if member := symbol_of(c, enum_member_by_value(c, type, value)); member != nil {
		return identifier_text(c, member.name)
	}
	return generic_value_text(c, value)
}

// design.md "Static `foreach` expansion": loops in the body own their branches,
// so they are not walked, and neither is a procedure literal, which has its own.
@(private = "file")
report_block_branches :: proc(k: ^Checker, block: ^Block) {
	if block != nil {
		report_stmts_branches(k, block.stmts)
	}
}

@(private = "file")
report_stmts_branches :: proc(k: ^Checker, stmts: []Stmt) {
	for stmt in stmts {
		report_stmt_branches(k, stmt)
	}
}

@(private = "file")
report_stmt_branches :: proc(k: ^Checker, stmt: Stmt) {
	#partial switch v in stmt {
	case ^Stmt_Branch:
		report_branch(k, v)
	case ^Block:
		report_block_branches(k, v)
	case ^Decl:
		report_expr_branches(k, v.declared_type)
		report_expr_branches(k, v.via)
		report_exprs_branches(k, v.values)
	case ^Stmt_Expr:
		report_exprs_branches(k, v.exprs)
	case ^Stmt_Assign:
		report_exprs_branches(k, v.lhs)
		report_exprs_branches(k, v.rhs)
	case ^Stmt_Return:
		if v.value != nil {
			report_expr_branches(k, v.value.expr)
		}
	case ^Stmt_Spawn:
		report_expr_branches(k, v.call)
	case ^Stmt_Defer:
		report_stmt_branches(k, v.stmt)
	case ^Stmt_Parallel:
		report_block_branches(k, v.body)
	case ^Stmt_If:
		report_stmt_branches(k, v.init)
		report_expr_branches(k, v.cond)
		report_block_branches(k, v.then)
		report_stmt_branches(k, v.otherwise)
	case ^Stmt_When:
		report_block_branches(k, v.then)
		report_stmt_branches(k, v.otherwise)
	case ^Stmt_Switch:
		report_stmt_branches(k, v.init)
		report_expr_branches(k, v.subject)
		for arm in v.cases {
			report_exprs_branches(k, arm.values)
			report_stmts_branches(k, arm.stmts)
		}
	}
}

@(private = "file")
report_branch :: proc(k: ^Checker, branch: ^Stmt_Branch) {
	errorf(
		k.c, branch.span, "L0455", "`%s` cannot target a static expansion; it is not a loop",
		branch.kind == .Break ? "break" : "continue",
	)
}

@(private = "file")
report_exprs_branches :: proc(k: ^Checker, exprs: []Expr) {
	for e in exprs {
		report_expr_branches(k, e)
	}
}

// The `or_else` exits an expression holds. A `return` exit's value is its child.
@(private = "file")
report_expr_branches :: proc(k: ^Checker, e: Expr) {
	if v, is_or_else := e.(^Expr_Or_Else); is_or_else {
		if branch, is_branch := v.exit.(^Stmt_Branch); is_branch {
			report_branch(k, branch)
		}
	}
	expr_children(e, k, proc(data: rawptr, child: Expr) -> bool {
		report_expr_branches((^Checker)(data), child)
		return false
	})
}

@(private = "file")
fold_static_iterable :: proc(k: ^Checker, iterable: Expr) -> ([]Const_Value, Type_Id, bool) {
	if named := resolve_type_syntax(k, iterable); named != INVALID_TYPE {
		errorf(
			k.c,
			expr_span(iterable),
			"L0454",
			"`%s` is a type, so it is not iterable%s",
			type_name(k.c, named),
			type_is_enum(k.c, named) ? "; write `.values()` for its members" : "",
		)
		return nil, INVALID_TYPE, false
	}

	type := check_single_expr(k, iterable)
	if type == INVALID_TYPE {
		return nil, INVALID_TYPE, false
	}
	if call, is_call := iterable.(^Expr_Call); is_call {
		if sym := symbol_of(k.c, call.resolution.chosen_overload); sym != nil && sym.synth == .Adapter_View {
			elements, _, ok := fold_static_iterable(k, call.bound[0])
			if !ok { return nil, INVALID_TYPE, false }
			element_type := associated_type_of(k, type, "Element")
			#partial switch type_of(k.c, type).adapter_kind {
			case .Reversed:
				slice.reverse(elements)
			case .Indexed:
				for &element, index in elements {
					element = indexed_pair(k.c, element_type, element, index)
				}
			}
			return elements, element_type, true
		}
	}
	if written, is_range := iterable.(^Expr_Range); is_range {
		return fold_static_range(k, written, type)
	}
	if written, is_slice := iterable.(^Expr_Slice); is_slice {
		return fold_static_slice(k, written)
	}
	info := underlying_info(k.c, type)
	if info == nil || (info.kind != .Array && info.kind != .Dynamic_Array && info.kind != .Slice) {
		errorf(
			k.c,
			expr_span(iterable),
			"L0454",
			"a static `foreach` needs a compile-time array or slice, subrange, `Enum.values()`, range, or descriptor array, found `%s`",
			type_name(k.c, type),
		)
		return nil, INVALID_TYPE, false
	}
	elements, evaluated := evaluate_static_elements(k, iterable, "a static `foreach` iterable")
	return elements, info.element, evaluated
}

@(private = "file")
fold_static_range :: proc(k: ^Checker, written: ^Expr_Range, type: Type_Id) -> ([]Const_Value, Type_Id, bool) {
	lo, lo_ok := require_const(k, written.lo, "a static `foreach` range endpoint", "L0454")
	hi, hi_ok := require_const(k, written.hi, "a static `foreach` range endpoint", "L0454")
	if !lo_ok || !hi_ok {
		return nil, INVALID_TYPE, false
	}
	element := underlying_info(k.c, type).element
	one := bi_from_i64(k.c, 1)
	count := bi_sub(k.c, hi.integer, lo.integer)
	if written.op == .Range_Incl {
		count = bi_add(k.c, count, one)
	}
	if bi_sign(count) <= 0 {
		return []Const_Value{}, element, true
	}
	n, fits := bi_to_i64(k.c, count)
	if !fits || n > EVAL_MAX_STEPS {
		errorf(k.c, written.op_span, "L0454", "a static `foreach` range expands to too many elements")
		return nil, INVALID_TYPE, false
	}
	elements := make([]Const_Value, int(n), k.c.semantic_allocator)
	current := lo.integer
	kind := type_is_rune(k.c, element) ? Const_Kind.Rune : Const_Kind.Integer
	for index in 0 ..< int(n) {
		elements[index] = Const_Value{kind = kind, integer = current}
		current = bi_add(k.c, current, one)
	}
	return elements, element, true
}

@(private = "file")
fold_static_slice :: proc(k: ^Checker, written: ^Expr_Slice) -> ([]Const_Value, Type_Id, bool) {
	elements, element, folded := fold_static_iterable(k, written.operand)
	if !folded {
		return nil, INVALID_TYPE, false
	}
	lo, lo_ok := static_slice_endpoint(k, written.lo, 0)
	hi, hi_ok := static_slice_endpoint(k, written.hi, i64(len(elements)))
	if !lo_ok || !hi_ok {
		return nil, INVALID_TYPE, false
	}
	if lo < 0 || hi < lo || hi > i64(len(elements)) {
		errorf(k.c, written.span, "L0454", "a static `foreach` slice is out of bounds")
		return nil, INVALID_TYPE, false
	}
	return elements[int(lo):int(hi)], element, true
}

@(private = "file")
static_slice_endpoint :: proc(k: ^Checker, endpoint: Expr, missing: i64) -> (i64, bool) {
	if endpoint == nil {
		return missing, true
	}
	value, ok := require_const(k, endpoint, "a static `foreach` slice endpoint", "L0454")
	if !ok {
		return 0, false
	}
	n, fits := bi_to_i64(k.c, value.integer)
	if !fits {
		errorf(k.c, expr_span(endpoint), "L0454", "a static `foreach` slice endpoint does not fit in `int`")
	}
	return n, fits
}

// ------------------------------------------------------- expanded cases --

// design.md "Per-variant switch cases": each copy is an ordinary case with its own
// clone of the body, so nothing after the checker sees an expanded case. False
// after a diagnostic.
expand_variant_cases :: proc(k: ^Checker, s: ^Stmt_Switch, subject: Type_Id) -> bool {
	position, valid := find_expanded_case(k, s, subject)
	if !valid {
		return false
	}
	if position < 0 {
		return true
	}
	written := s.cases[position]
	descriptor, payload, ok := expanded_case_bindings(k, written.values[0])
	if !ok {
		return false
	}

	covered := make([dynamic]int, 0, len(s.cases), context.temp_allocator)
	for entry in s.cases[:position] {
		for value in entry.values {
			if sel, is_selector := value.(^Expr_Selector); is_selector && sel.operand == nil {
				append(&covered, union_variant_index(k.c, subject, intern_identifier(k.c, sel.name.text)))
			}
		}
	}
	s.written = s.cases
	cases := make([dynamic]Switch_Case, 0, len(s.cases) + variant_count(k.c, subject), k.c.semantic_allocator)
	append(&cases, ..s.cases[:position])
	span := expr_span(written.values[0])
	for index in 0 ..< variant_count(k.c, subject) {
		if slice.contains(covered[:], index) {
			continue
		}
		append(&cases, Switch_Case {
			span        = written.span,
			values      = variant_case_values(k.c, union_variant_name(k.c, subject, index), span),
			stmts       = clone_stmts(k.c, written.stmts),
			binding     = payload.name,
			binding_ref = payload.is_ref,
			expanded    = descriptor,
			descriptor  = variant_descriptor(k.c, subject, index),
		})
	}
	s.cases = cases[:]
	return true
}

// The expanded case of a switch, -1 when it has none; false once one breaks the
// placement rules.
@(private = "file")
find_expanded_case :: proc(k: ^Checker, s: ^Stmt_Switch, subject: Type_Id) -> (position: int, valid: bool) {
	position = -1
	for entry, index in s.cases {
		for value in entry.values {
			if _, _, is_expanded := expanded_case_pattern(value); !is_expanded {
				continue
			}
			if position >= 0 {
				errorf(k.c, expr_span(value), "L0367", "a switch has at most one expanded case")
				return
			}
			if len(entry.values) != 1 {
				errorf(
					k.c, expr_span(value), "L0367",
					"an expanded case covers every remaining variant, so it names nothing else",
				)
				return
			}
			position = index
		}
	}
	if position < 0 {
		return position, true
	}
	// design.md "Distinct types": a distinct type over a union is not a subject here.
	if type_kind(k.c, subject) != .Union {
		errorf(
			k.c, expr_span(s.cases[position].values[0]), "L0426",
			"an expanded case needs a union subject, and this switch is over `%s`", type_name(k.c, subject),
		)
		return
	}
	if position != len(s.cases) - 1 {
		next := s.cases[position + 1]
		errorf(
			k.c, next.span, "L0367", "%s",
			len(next.values) == 0 ? "`default:` cannot follow an expanded case, which already covers every remaining variant" : "an expanded case covers every remaining variant, so it is the last case",
		)
		return
	}
	return position, true
}

// A per-variant case's one value, the selector `.label`.
@(private = "file")
variant_case_values :: proc(c: ^Compiler, label: string, span: Span) -> []Expr {
	values := make([]Expr, 1, c.semantic_allocator)
	values[0] = synth_selector(c, nil, label, span)
	return values
}

// `$variant` or `$variant(payload)`, as the parser reads either: a `$` name,
// alone or called.
@(private = "file")
expanded_case_pattern :: proc(value: Expr) -> (^Type_Poly, []Argument, bool) {
	if poly, is_poly := value.(^Type_Poly); is_poly {
		return poly, nil, true
	}
	if call, is_call := value.(^Expr_Call); is_call {
		if poly, is_poly := call.callee.(^Type_Poly); is_poly {
			return poly, call.args, true
		}
	}
	return nil, nil, false
}

// The descriptor's name and the payload binding of an expanded case. The names
// are checked here once rather than in every copy.
@(private = "file")
expanded_case_bindings :: proc(k: ^Checker, value: Expr) -> (descriptor: Name, payload: Case_Field, ok: bool) {
	poly, args, _ := expanded_case_pattern(value)
	descriptor = poly.name
	if !static_name_is_free(k, descriptor, new_scope(k.c, k.scope, .Local)) {
		return
	}
	if len(args) > 1 {
		errorf(
			k.c, args[1].span, "L0426",
			"an expanded case binds the whole payload, `$%s(payload)`: the payloads differ in shape, so it cannot bind their fields",
			descriptor.text,
		)
		return
	}
	if len(args) == 1 {
		written := args[0].value
		if unary, is_unary := written.(^Expr_Unary); is_unary && unary.op == .Amp && unary.mutable {
			written, payload.is_ref = unary.operand, true
		}
		ident, is_ident := written.(^Expr_Ident)
		if !is_ident || args[0].name.text != "" || args[0].mode != .Value {
			errorf(k.c, args[0].span, "L0426", "an expanded case binds its payload to a name, or to `&mut name`")
			return
		}
		payload.name = Name{text = ident.name, span = ident.span, id = ident.name_id}
	}
	ok = true
	return
}

// The `$variant` descriptor of an expanded case's copy, bound in its case
// scope, and for a payloadless variant the `Unit{}` its payload binding names
// (design.md "Per-variant switch cases").
bind_expanded_case :: proc(k: ^Checker, entry: ^Switch_Case, payload: Type_Id) {
	k.scope.expansion = entry.variant_indices[0] + 1
	bind_static(k, entry.expanded, entry.descriptor, meta_variant_type(k.c))
	if payload != TYPE_VOID || entry.binding.text == "" {
		return
	}
	if static_name_is_free(k, entry.binding, k.scope) {
		bind_static(k, entry.binding, aggregate_const(k.c, k.c.unit_type, nil), k.c.unit_type)
	}
	entry.binding = {}
	entry.binding_ref = false
}

// Reported after a copy's body, so a diagnostic says which variant it was
// checked for, as one in a static expansion names its element.
note_expanded_case :: proc(k: ^Checker, entry: Switch_Case, before: int) {
	if entry.descriptor.aggregate != nil && len(k.c.diagnostics) > before {
		add_notef(
			k.c, entry.values[0].(^Expr_Selector).span, "%s `.%s`",
			entry.arm != nil ? "in the union argument expansion for" : "in the expanded case for",
			entry.descriptor.aggregate.elements[META_NAME].text,
		)
	}
}

// ---------------------------------------------- union argument expansion --

// The payload binding of a union argument expansion's cases; `$` keeps it out
// of reach of written code. Overload notes recognize it.
DISPATCH_PAYLOAD :: "dispatch$payload"

// design.md "Union argument expansion": `show(..answer)` over a union is
//
//     switch (answer) { case $variant(payload): show(<label> = payload); }
//
// kept on the call as `dispatch`, one case per variant whose `arm` is that
// variant's call. The call's value is the arms' common result. False when the
// call spreads no union, which leaves `..` to the variadic path.
check_union_argument_expansion :: proc(k: ^Checker, v: ^Expr_Call, expected: Type_Id) -> bool {
	spread, subject, is_union := union_spread(k, v)
	if !is_union {
		return false
	}
	v.value_category = .Value
	if len(v.args) != 1 {
		errorf(k.c, v.args[spread].span, "L0371", "a union argument expansion is the call's only argument")
		return true
	}
	if v.args[0].name.text != "" {
		errorf(k.c, v.args[0].name.span, "L0371", "a union argument expansion names no parameter; each variant's label does")
		return true
	}
	v.dispatch = union_dispatch_switch(k, v, subject, expected)
	check_variant_cases(k, v.dispatch, subject)
	v.type = union_dispatch_result(k, v, subject)
	return true
}

// The spread argument of a call, when its operand is a union.
@(private = "file")
union_spread :: proc(k: ^Checker, v: ^Expr_Call) -> (spread: int, subject: Type_Id, is_union: bool) {
	spread = -1
	for arg, index in v.args {
		if arg.mode == .Spread {
			spread = index
			break
		}
	}
	if spread < 0 {
		return
	}
	// A union needing a destination type has none here, so it is left to the
	// variadic path. Any other operand is checked once: a recheck would double per
	// level of nested spreads.
	operand := v.args[spread].value
	if argument_needs_context(operand) {
		return
	}
	subject = check_expr(k, operand)
	// design.md "Distinct types": a distinct type over a union is not a subject here.
	if subject == INVALID_TYPE || subject == TYPE_VOID || type_kind(k.c, subject) != .Union {
		v.args[spread].checked = true
		return
	}
	return spread, subject, true
}

// One case per variant, whose `arm` is that variant's call.
@(private = "file")
union_dispatch_switch :: proc(k: ^Checker, v: ^Expr_Call, subject, expected: Type_Id) -> ^Stmt_Switch {
	// design.md "Switch ownership": a place lends its payload, and a temporary
	// or `move(answer)` gives it up, so its call takes it by `move`.
	operand := v.args[0].value
	consumes := !expression_is_borrowed_place(operand)
	s := new(Stmt_Switch, k.c.semantic_allocator)
	s.span = v.span
	s.kind = .Pattern
	s.subject = operand
	s.arm_expected = expected
	s.cases = make([]Switch_Case, variant_count(k.c, subject), k.c.semantic_allocator)
	span := v.args[0].span
	binding := synth_name(k.c, DISPATCH_PAYLOAD, span)
	for &entry, index in s.cases {
		label := union_variant_name(k.c, subject, index)
		entry.span = v.span
		entry.values = variant_case_values(k.c, label, span)
		entry.binding = binding
		entry.descriptor = variant_descriptor(k.c, subject, index)

		payload := synth_ident(k.c, DISPATCH_PAYLOAD, span)
		// A payloadless variant passes the `Unit{}` constant, which has no owner.
		argument: Expr = payload
		if consumes && union_variant_payload(k.c, subject, index) != TYPE_VOID {
			argument = synth_move(k.c, payload, span)
		}
		arm := synth_call(k.c, clone_expr(k.c, v.callee), {argument}, v.span)
		arm.args[0].span, arm.args[0].name = span, Name{text = label, span = span}
		entry.arm = arm
	}
	return s
}

// design.md "Union argument expansion": a call that never returns stands in for
// either. `INVALID_TYPE` when the arms do not agree, or one failed.
@(private = "file")
union_dispatch_result :: proc(k: ^Checker, v: ^Expr_Call, subject: Type_Id) -> Type_Id {
	result := TYPE_VOID
	decided := -1
	for entry, index in v.dispatch.cases {
		arm := expr_base(entry.arm)
		if arm.type == INVALID_TYPE {
			return INVALID_TYPE
		}
		if arm.value_category == .Place {
			errorf(
				k.c, v.span, "L0371",
				"a union argument expansion yields a value, and its call for `.%s` returns a place",
				union_variant_name(k.c, subject, index),
			)
			return INVALID_TYPE
		}
		if arm.type == TYPE_VOID && call_diverges(k.c, entry.arm) {
			continue
		}
		if decided < 0 {
			result, decided = arm.type, index
			continue
		}
		if arm.type != result {
			errorf(
				k.c, v.span, "L0354",
				"a union argument expansion has one result type, but its call for `.%s` returns `%s` and for `.%s` returns `%s`",
				union_variant_name(k.c, subject, decided), result == TYPE_VOID ? "nothing" : type_name(k.c, result),
				union_variant_name(k.c, subject, index), arm.type == TYPE_VOID ? "nothing" : type_name(k.c, arm.type),
			)
			return INVALID_TYPE
		}
	}
	return result
}

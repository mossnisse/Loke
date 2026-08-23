// Checked extractions, the type switch, and the optional-ok error protocol
// (m4a-plan step 4).
//
// design.md gives `v.(T)` one construct with two result shapes chosen by
// context: a single-value position traps on a mismatch, a comma-ok destination
// or an `or_else` left operand yields `(T, bool)` and never traps. The flag is
// set by whoever owns the destination, before the node is checked.
package lokec

// -------------------------------------------------- checked extractions --

// A comma-ok destination is what puts a checked extraction in its optional-ok
// phase. Called before the operand is checked, because the phase decides the
// node's own result shape.
mark_optional_ok :: proc(e: Expr) {
	if extraction, is_extract := e.(^Expr_Checked_Extract); is_extract {
		extraction.optional = true
	}
	// design.md "Maps": "`elem, ok := m[key]`" is "the **comma-ok** form". The
	// phase decides the node's result shape, exactly as it does for an extraction.
	if index, is_index := e.(^Expr_Index); is_index {
		index.map_optional = true
	}
}

check_checked_extract :: proc(k: ^Checker, v: ^Expr_Checked_Extract) {
	v.value_category = .Value
	operand := check_single_expr(k, v.operand)
	if operand == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}
	// design.md: a dynamic interface is a borrowed view and supports no type
	// checked extraction; add a slot for required behavior, or pass an `any_view`.
	if type_is_dyn(k.c, operand) {
		errorf(
			k.c,
			v.span,
			"L0466",
			"`%s` is a borrowed view and has no checked extraction; add a slot for the behavior, or pass an `any_view`",
			type_name(k.c, operand),
		)
		v.type = INVALID_TYPE
		return
	}
	// design.md "any_view type": it supports runtime checked extractions and type
	// switches. One construct, two result shapes, exactly as for a union.
	if operand == TYPE_ANY_VIEW {
		check_any_view_extract(k, v)
		return
	}
	if !type_is_union(k.c, operand) {
		errorf(
			k.c,
			v.span,
			"L0425",
			"`%s` is not a union, so it has no variant to extract",
			type_name(k.c, operand),
		)
		v.type = INVALID_TYPE
		return
	}
	// design.md: a checked extraction must name the requested type; the compiler does
	// not infer it from context.
	target := resolve_type_syntax(k, v.target)
	if target == INVALID_TYPE {
		errorf(k.c, expr_span(v.target), "L0425", "a checked extraction names the requested type")
		v.type = INVALID_TYPE
		return
	}
	if !union_holds(k.c, operand, target) {
		errorf(
			k.c,
			expr_span(v.target),
			"L0425",
			"`%s` is not a variant of `%s`",
			type_name(k.c, target),
			type_name(k.c, operand),
		)
		v.type = INVALID_TYPE
		return
	}
	v.type = target
	if v.optional {
		results := make([]Type_Id, 2, k.c.semantic_allocator)
		results[0], results[1] = target, TYPE_BOOL
		v.result_types = results
	}
}

// ---------------------------------------------------------- optional-ok --

// design.md "Status results": exactly two forms are admissible, a `bool` status
// that succeeds on `true` and a nil status that succeeds on `nil`. A union and
// `Allocator_Error` are the nil statuses. A pointer, multi-pointer, `rawptr`,
// slice, map, procedure, `typeid`, view, or `dyn` result compares against `nil`
// but is not a status, so a procedure returning `(int, ^Node)` returns two
// ordinary values rather than a value and an error.
type_is_status :: proc(k: ^Checker, status: Type_Id) -> bool {
	if type_is_boolean(k.c, status) {
		return true
	}
	#partial switch underlying_kind(k.c, status) {
	case .Union, .Allocator_Error:
		return true
	}
	return false
}

// design.md "Status results": an `or_else` operand is a status expression with
// at least one payload result. The `bool` case is the optional-ok shape a
// built-in producer uses; a union status is the error shape. A procedure
// returning only a status is an `or_return` operand, not an `or_else` one.
status_payloads :: proc(k: ^Checker, e: Expr) -> ([]Type_Id, bool) {
	base := expr_base(e)
	if base == nil || len(base.result_types) < 2 {
		return nil, false
	}
	if !type_is_status(k, base.result_types[len(base.result_types) - 1]) {
		return nil, false
	}
	return base.result_types[:len(base.result_types) - 1], true
}

// design.md "or_else expression": the fallback produces exactly the payload
// results and is evaluated only when the status is a failure.
check_or_else :: proc(k: ^Checker, v: ^Expr_Or_Else, expected: Type_Id) {
	v.value_category = .Value
	mark_optional_ok(v.value)
	if check_expr(k, v.value, expected) == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}
	payloads, has_payloads := status_payloads(k, v.value)
	if !has_payloads {
		errorf(
			k.c,
			expr_span(v.value),
			"L0428",
			"`or_else` needs a status expression with a payload on its left",
		)
		v.type = INVALID_TYPE
		return
	}

	if len(payloads) == 1 {
		if !check_value_expr(k, v.fallback, payloads[0], "supply") {
			v.type = INVALID_TYPE
			return
		}
		v.type = payloads[0]
		return
	}
	// Loke has no tuple literal, so a multiple-payload fallback is a call.
	if check_expr(k, v.fallback) == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}
	fallback := expr_base(v.fallback)
	if len(fallback.result_types) != len(payloads) {
		errorf(
			k.c,
			expr_span(v.fallback),
			"L0428",
			"this fallback produces %d value%s, but %d are wanted",
			max(len(fallback.result_types), 1),
			len(fallback.result_types) == 1 ? "" : "s",
			len(payloads),
		)
		v.type = INVALID_TYPE
		return
	}
	for payload, index in payloads {
		if !assignable(k.c, fallback.result_types[index], payload) {
			errorf(
				k.c,
				expr_span(v.fallback),
				"L0428",
				"cannot supply `%s` with `%s`",
				type_name(k.c, payload),
				type_name(k.c, fallback.result_types[index]),
			)
			v.type = INVALID_TYPE
			return
		}
	}
	v.type = payloads[0]
	v.result_types = payloads
}

// ----------------------------------------------------------- or_return --

// design.md "or_return operator": the operand is evaluated once; on success the
// final status is removed and the preceding values are yielded; on failure
// control returns from the innermost enclosing procedure.
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
	results := base.result_types
	if len(results) == 0 {
		single := make([]Type_Id, 1, k.c.semantic_allocator)
		single[0] = base.type
		results = single
	}
	status := results[len(results) - 1]
	// design.md "Status results": unlike `or_else` this places no lower bound on
	// the payload results, so an operand that returns only a status is admissible.
	if !type_is_status(k, status) {
		errorf(
			k.c,
			v.op_span,
			"L0429",
			"`or_return` needs a `bool`, union, or `Allocator_Error` final result, found `%s`",
			type_name(k.c, status),
		)
		v.type = INVALID_TYPE
		return
	}
	if !check_or_return_target(k, v, status) {
		v.type = INVALID_TYPE
		return
	}

	payloads := results[:len(results) - 1]
	switch len(payloads) {
	case 0:
		v.type = TYPE_VOID
	case 1:
		v.type = payloads[0]
	case:
		v.type = payloads[0]
		v.result_types = payloads
	}
}

// The enclosing procedure's side of the contract, including the
// definite-initialization requirement on earlier named results.
@(private = "file")
check_or_return_target :: proc(k: ^Checker, v: ^Expr_Postfix, status: Type_Id) -> bool {
	if len(k.result_types) == 0 {
		errorf(k.c, v.op_span, "L0429", "`or_return` needs a result to propagate the status into")
		return false
	}
	last := len(k.result_types) - 1
	if !assignable(k.c, status, k.result_types[last]) && status != k.result_types[last] {
		errorf(
			k.c,
			v.op_span,
			"L0429",
			"the failed status `%s` cannot be returned as `%s`",
			type_name(k.c, status),
			type_name(k.c, k.result_types[last]),
		)
		return false
	}
	if len(k.result_types) == 1 {
		return true
	}
	// With several results a bare `return` is performed, so every result must be
	// named and every earlier one must already carry a value.
	for symbol_id, index in k.result_symbols {
		if symbol_id == INVALID_SYMBOL {
			errorf(k.c, v.op_span, "L0429", "`or_return` needs every result of this procedure to be named")
			return false
		}
		if index == last {
			continue
		}
		if !k.assigned_results[symbol_id] {
			errorf(
				k.c,
				v.op_span,
				"L0430",
				"`%s` is not initialised yet, and `or_return` returns its current value",
				identifier_text(k.c, symbol_of(k.c, symbol_id).name),
			)
			return false
		}
	}
	return true
}

// Records that a named result has been written. Branching statements clone this
// state and intersect the paths that reach their join.
note_result_assigned :: proc(k: ^Checker, target: Expr) {
	ident, is_ident := target.(^Expr_Ident)
	if !is_ident || ident.symbol == INVALID_SYMBOL {
		return
	}
	if symbol := symbol_of(k.c, ident.symbol); symbol != nil && symbol.kind == .Result {
		if k.assigned_results == nil {
			k.assigned_results = make(map[Symbol_Id]bool, 4, k.c.semantic_allocator)
		}
		k.assigned_results[ident.symbol] = true
	}
}

clone_result_assignments :: proc(c: ^Compiler, source: map[Symbol_Id]bool) -> map[Symbol_Id]bool {
	out := make(map[Symbol_Id]bool, len(source), c.semantic_allocator)
	for symbol, assigned in source {
		if assigned {
			out[symbol] = true
		}
	}
	return out
}

intersect_result_assignments :: proc(
	c: ^Compiler,
	left, right: map[Symbol_Id]bool,
) -> map[Symbol_Id]bool {
	out := make(map[Symbol_Id]bool, min(len(left), len(right)), c.semantic_allocator)
	for symbol, assigned in left {
		if assigned && right[symbol] {
			out[symbol] = true
		}
	}
	return out
}

// ---------------------------------------------------------- type switch --

// design.md "Type switch statement": the cases are types, and for a union the
// only case types allowed are its own variants.
check_type_switch :: proc(k: ^Checker, s: ^Stmt_Switch) -> Flow_Info {
	outer := k.scope
	k.scope = new_scope(k.c, outer, .Local)
	defer k.scope = outer

	if s.init != nil {
		check_stmt(k, s.init)
	}
	subject := check_single_expr(k, s.subject)
	if subject == INVALID_TYPE {
		return Flow_Info{can_fall_through = true}
	}
	// design.md: a dynamic interface is a borrowed view and supports no type
	// switch in version 1.
	if type_is_dyn(k.c, subject) {
		errorf(
			k.c,
			expr_span(s.subject),
			"L0466",
			"`%s` is a borrowed view and has no type switch; add a slot for the behavior, or switch on an `any_view`",
			type_name(k.c, subject),
		)
		return Flow_Info{can_fall_through = true}
	}
	erased := subject == TYPE_ANY_VIEW
	if !erased && !type_is_union(k.c, subject) {
		errorf(
			k.c,
			expr_span(s.subject),
			"L0426",
			"a type switch needs a union or an `any_view`, found `%s`",
			type_name(k.c, subject),
		)
		return Flow_Info{can_fall_through = true}
	}

	covered := make(map[Type_Id]bool, 8, context.temp_allocator)
	has_default := false
	flow := Flow_Info{}
	any_case_falls := false
	incoming := clone_result_assignments(k.c, k.assigned_results)
	joined := make(map[Symbol_Id]bool, 0, k.c.semantic_allocator)
	have_join := false

	for &entry in s.cases {
		k.assigned_results = clone_result_assignments(k.c, incoming)
		binding_type := subject
		if len(entry.values) == 0 {
			if has_default {
				errorf(k.c, entry.span, "L0367", "this switch already has a default case")
			}
			has_default = true
		}
		for value in entry.values {
			variant := resolve_type_syntax(k, value)
			// An `any_view` case names any concrete type the view could hold; a
			// union case names one of its variants.
			if erased {
				if variant == INVALID_TYPE || !any_view_accepts(k.c, variant) {
					errorf(
						k.c,
						expr_span(value),
						"L0465",
						"`%s` is not a concrete type an `any_view` can hold",
						variant == INVALID_TYPE ? "this case" : type_name(k.c, variant),
					)
					continue
				}
				request_typeid(k.c, variant)
				if covered[variant] {
					errorf(k.c, expr_span(value), "L0367", "`%s` is already covered by an earlier case", type_name(k.c, variant))
					continue
				}
				covered[variant] = true
				continue
			}
			if variant == INVALID_TYPE || !union_holds(k.c, subject, variant) {
				errorf(
					k.c,
					expr_span(value),
					"L0426",
					"`%s` is not a variant of `%s`",
					variant == INVALID_TYPE ? "this case" : type_name(k.c, variant),
					type_name(k.c, subject),
				)
				continue
			}
			if covered[variant] {
				errorf(k.c, expr_span(value), "L0367", "`%s` is already covered by an earlier case", type_name(k.c, variant))
				continue
			}
			covered[variant] = true
		}
		// A case naming several types cannot know which one is active, so the
		// binding keeps the union type.
		if len(entry.values) == 1 {
			if variant := expr_base(entry.values[0]).denoted_type; variant != INVALID_TYPE {
				binding_type = variant
			}
		}
		entry.binding_type = binding_type

		case_scope := k.scope
		k.scope = new_scope(k.c, case_scope, .Local)
		if s.binding.text != "" && s.binding.text != "_" {
			name := intern_identifier(k.c, s.binding.text)
			entry.binding_symbol = new_symbol(k.c, Symbol {
				name       = name,
				span       = s.binding.span,
				kind       = .Var,
				type       = binding_type,
				pkg        = k.pkg,
				owner_proc = k.proc_literal,
			})
			k.scope.names[name] = entry.binding_symbol
		}
		k.switch_depth += 1
		case_flow := check_case_body(k, entry.stmts)
		k.switch_depth -= 1
		k.scope = case_scope

		flow.returns ||= case_flow.returns
		flow.continues ||= case_flow.continues
		any_case_falls ||= case_flow.can_fall_through || case_flow.breaks
		if case_flow.can_fall_through || case_flow.breaks {
			state := clone_result_assignments(k.c, k.assigned_results)
			joined = have_join ? intersect_result_assignments(k.c, joined, state) : state
			have_join = true
		}
	}

	if !has_default {
		if erased {
			// An `any_view` erases an open set, so no case list can be exhaustive.
			errorf(k.c, s.span, "L0465", "a type switch over `any_view` needs a default case")
		} else {
			report_uncovered_variants(k, s, subject, covered)
		}
		joined = have_join ? intersect_result_assignments(k.c, joined, incoming) : incoming
		have_join = true
	}
	k.assigned_results = have_join ? joined : incoming
	return Flow_Info {
		can_fall_through = !has_default || any_case_falls || len(s.cases) == 0,
		returns          = flow.returns,
		continues        = flow.continues,
	}
}

@(private = "file")
report_uncovered_variants :: proc(k: ^Checker, s: ^Stmt_Switch, subject: Type_Id, covered: map[Type_Id]bool) {
	info := type_of(k.c, subject)
	if info == nil {
		return
	}
	missing := ""
	count := 0
	for variant in info.variants {
		if covered[variant] {
			continue
		}
		count += 1
		if count <= 3 {
			if missing != "" {
				missing = concat(k.c, missing, ", ")
			}
			missing = concat(k.c, missing, type_name(k.c, variant))
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
		"this type switch over `%s` does not cover %s",
		type_name(k.c, subject),
		missing,
	)
}

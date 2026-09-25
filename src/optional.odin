// Checked extractions, variant switches, and the typed failure protocol.
package lokec

import "core:slice"

// -------------------------------------------------- checked extractions --

check_extract_of :: proc(k: ^Checker, v: ^Expr_Checked_Extract, operand: Type_Id) {
	v.value_category = .Value
	if operand == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}
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
	if operand == TYPE_ANY_VIEW {
		check_any_view_extract(k, v)
		return
	}
	if type_is_union(k.c, operand) {
		errorf(
			k.c,
			v.span,
			"L0425",
			"`%s` is a union: match its variants with a `switch (p in value)` whose cases are `.name`",
			type_name(k.c, operand),
		)
		v.type = INVALID_TYPE
		return
	}
	errorf(
		k.c,
		v.span,
		"L0425",
		"`%s` is not an `any_view`, so it has no runtime type to extract",
		type_name(k.c, operand),
	)
	v.type = INVALID_TYPE
}

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

note_optional_replacement :: proc(k: ^Checker, e: Expr) {
	#partial switch v in e {
	case ^Expr_Checked_Extract:
		if v.mode == .Trap {
			add_notef(k.c, expr_span(e), "`value.(T)` traps on a mismatch; `value.as(T)` yields `Option(T)`")
		}
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
		v.type = INVALID_TYPE
		return
	}
	payload := shape.info.variants[shape.success]
	if payload == TYPE_VOID {
		errorf(
			k.c,
			expr_span(v.value),
			"L0428",
			"`%s.%s` carries no payload, so there is nothing for `or_else` to produce",
			type_name(k.c, shape.union_type), union_variant_name(k.c, shape.union_type, shape.success),
		)
		v.type = INVALID_TYPE
		return
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
	if v.borrows && reject_allocating_copy(k, v.value, payload, .Or_Else) {
		v.type = INVALID_TYPE
		return
	}
	if v.borrows {
		contribute_lifecycle_members(k, payload)
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
		v.type = INVALID_TYPE
		return
	}
	if !check_or_return_target(k, v, shape) {
		v.type = INVALID_TYPE
		return
	}
	v.borrows = base.value_category == .Place
	if v.borrows {
		for candidate in ([2]Type_Id{shape.info.variants[shape.success], shape.info.variants[shape.failure]}) {
			if candidate == TYPE_VOID {
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
			if reject_allocating_copy(k, v.operand, candidate, .Or_Return) {
				v.type = INVALID_TYPE
				return
			}
			contribute_lifecycle_members(k, candidate)
		}
	}

	success := shape.info.variants[shape.success]
	v.type = success == TYPE_VOID ? k.c.unit_type : success
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
		return false
	}
	return true
}

// ---------------------------------------------------------- type switch --

// A union subject turns `.name(binding)` calls into branch patterns.
adopt_branch_patterns :: proc(s: ^Stmt_Switch) {
	s.kind = .Pattern
	for &entry in s.cases {
		if len(entry.values) != 1 {
			continue
		}
		if selector, binding, ok := branch_variant_pattern(entry.values[0]); ok {
			entry.values[0] = selector
			entry.binding = binding
		}
	}
}

@(private = "file")
branch_variant_pattern :: proc(value: Expr) -> (Expr, Name, bool) {
	call, is_call := value.(^Expr_Call)
	if !is_call || len(call.args) != 1 {
		return nil, Name{}, false
	}
	selector, is_selector := call.callee.(^Expr_Selector)
	arg := call.args[0]
	ident, is_ident := arg.value.(^Expr_Ident)
	if !is_selector || selector.operand != nil || !is_ident ||
	   arg.name.text != "" || arg.mode != .Value {
		return nil, Name{}, false
	}
	binding := Name{text = ident.name, span = ident.span, id = ident.name_id}
	return selector, binding, true
}

check_type_switch :: proc(k: ^Checker, s: ^Stmt_Switch) -> Flow_Info {
	outer := k.scope
	k.scope = new_scope(k.c, outer, .Local)
	defer k.scope = outer

	if s.init != nil {
		check_stmt(k, s.init)
	}
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
			"`%s` is a borrowed view and has no type switch; add a slot for the behavior, or switch on an `any_view`",
			type_name(k.c, subject),
		)
		return Flow_Info{}
	}
	erased := subject == TYPE_ANY_VIEW
	borrows := erased || expression_is_borrowed_place(s.subject)
	if !erased && !type_is_union(k.c, subject) {
		errorf(
			k.c,
			expr_span(s.subject),
			"L0426",
			"a type switch needs a union or an `any_view`, found `%s`",
			type_name(k.c, subject),
		)
		// A header binding is only ever written `name in expression`, which is
		// always a payload binding (design.md "switch statement"). A membership
		// test written there arrives here instead, and nothing above says why.
		if s.binding.text != "" {
			add_notef(
				k.c, s.binding.span,
				"`%s in ...` in a switch header binds a payload; the membership test is `switch ((%s in ...))`",
				s.binding.text, s.binding.text,
			)
		}
		return Flow_Info{}
	}

	covered := make(map[Type_Id]bool, 8, context.temp_allocator)
	seen_variants := make([dynamic]int, 0, 8, context.temp_allocator)
	has_default := false
	flow := Flow_Info{}
	any_case_falls := false
	for &entry in s.cases {
		binding_type := subject
		if len(entry.values) == 0 {
			if has_default {
				errorf(k.c, entry.span, "L0367", "this switch already has a default case")
			}
			has_default = true
		}
		indices := make([dynamic]int, 0, len(entry.values), k.c.semantic_allocator)
		for value in entry.values {
			if erased {
				variant := resolve_type_syntax(k, value)
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
			index := case_variant_index(k, subject, value)
			if index < 0 {
				continue
			}
			if slice.contains(indices[:], index) {
				errorf(
					k.c, expr_span(value), "L0367",
					"`.%s` is already covered by an earlier case", union_variant_name(k.c, subject, index),
				)
				continue
			}
			for existing in seen_variants {
				if existing == index {
					errorf(
						k.c, expr_span(value), "L0367",
						"`.%s` is already covered by an earlier case", union_variant_name(k.c, subject, index),
					)
					index = -1
					break
				}
			}
			if index < 0 {
				continue
			}
			append(&indices, index)
			append(&seen_variants, index)
		}
		entry.variant_indices = indices[:]
		// Grouped cases bind the union; singleton cases bind their payload.
		if erased {
			if len(entry.values) == 1 {
				if variant := expr_base(entry.values[0]).denoted_type; variant != INVALID_TYPE {
					binding_type = variant
				}
			}
		} else if len(entry.variant_indices) == 1 {
			payload := union_variant_payload(k.c, subject, entry.variant_indices[0])
			binding_type = payload == TYPE_VOID ? k.c.unit_type : payload
			if s.kind == .Pattern && entry.binding.text != "" && payload == TYPE_VOID {
				errorf(
					k.c, entry.binding.span, "L0426",
					"the payloadless variant `.%s` has nothing to bind",
					union_variant_name(k.c, subject, entry.variant_indices[0]),
				)
			}
		}
		entry.binding_type = binding_type

		case_scope := k.scope
		k.scope = new_scope(k.c, case_scope, .Local)
		binding := s.binding
		if s.kind == .Pattern {
			binding = entry.binding
		}
		if binding.text != "" && binding.text != "_" {
			name := intern_identifier(k.c, binding.text)
			outer, owner := lookup_symbol_with_scope(case_scope, name)
			if outer != INVALID_SYMBOL && (owner.kind == .Local || owner.kind == .Procedure) {
				errorf(k.c, binding.span, "L0305", "`%s` shadows an outer declaration", binding.text)
			}
			reject_reserved_name(k, name, binding.span)
			entry.binding_symbol = new_symbol(k.c, Symbol {
				name       = name,
				span       = binding.span,
				kind       = .Var,
				type       = binding_type,
				pkg        = k.pkg,
				owner_proc = k.proc_literal,
				immutable  = borrows,
				borrowed_binding = borrows ? .Switch_Payload : .None,
			})
			k.scope.names[name] = entry.binding_symbol
		}
		case_flow := check_stmts(k, entry.stmts)
		k.scope = case_scope

		flow.returns ||= case_flow.returns
		flow.breaks ||= case_flow.breaks
		flow.continues ||= case_flow.continues
		any_case_falls ||= case_flow.can_fall_through
	}

	exhaustive := has_default
	if !has_default {
		if erased {
			// An `any_view` erases an open set, so no case list can be exhaustive.
			errorf(k.c, s.span, "L0465", "a type switch over `any_view` needs a default case")
		} else if variant_count(k.c, subject) == len(seen_variants) {
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

@(private = "file")
case_variant_index :: proc(k: ^Checker, subject: Type_Id, value: Expr) -> int {
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
			missing = concat(k.c, missing, concat(k.c, ".", union_variant_name(k.c, subject, index)))
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

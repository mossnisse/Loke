// `switch` statements: a value switch over comparable values, and a union switch,
// whose cases name variants and bind their payloads.
package lokec

import "core:slice"
import "core:strings"

// --------------------------------------------------------- value switches --

// design.md "Inspecting a union": a case binds, never the header. `switch (name
// in subject)` with an unresolved name arrives as a membership test.
@(private = "file")
report_header_binding :: proc(k: ^Checker, s: ^Stmt_Switch) -> bool {
	test, is_binary := s.subject.(^Expr_Binary)
	if !is_binary || test.op != .In {
		return false
	}
	name, is_ident := test.lhs.(^Expr_Ident)
	if !is_ident || lookup_symbol(k.scope, identifier_of(k.c, name)) != INVALID_SYMBOL {
		return false
	}
	errorf(
		k.c, expr_span(s.subject), "L0426",
		"a switch binds in its cases: write `switch (subject)` with `case .variant(%s):`",
		name.name,
	)
	return true
}

check_switch :: proc(k: ^Checker, s: ^Stmt_Switch) -> Flow_Info {
	enter_statement_header(k, s.init)
	if report_header_binding(k, s) {
		return Flow_Info{}
	}
	subject := check_single_expr(k, s.subject)
	if subject == INVALID_TYPE {
		// Not falling through, so no missing return is blamed on it.
		return Flow_Info{}
	}
	// design.md "Inspecting a union": the subject's type decides.
	// A `dyn` subject arrives too, so it is told why it has no such switch.
	if type_is_union(k.c, subject) || type_is_dyn(k.c, subject) {
		adopt_branch_patterns(k, s)
		return check_variant_cases(k, s, subject)
	}
	if type_is_untyped(k.c, subject) {
		materialize(k, s.subject, default_type(k.c, subject))
		subject = expr_base(s.subject).type
	}
	if !type_is_comparable(k.c, subject) {
		errorf(k.c, expr_span(s.subject), "L0355", "`%s` is not comparable", type_name(k.c, subject))
		return Flow_Info{}
	}
	owned := make([dynamic]Type_Id, context.temp_allocator)
	own_equalities_within(k.c, subject, &owned)
	if !own_equalities_visible(k, owned[:], subject, expr_span(s.subject)) {
		return Flow_Info{}
	}

	// design.md "Per-variant switch cases": reported for any other subject.
	if !expand_variant_cases(k, s, subject) {
		return Flow_Info{}
	}
	cases := Case_Values {
		integers = new_integer_set(0, context.temp_allocator),
		others   = make([dynamic]Const_Value, 0, 8, context.temp_allocator),
		covered  = make(map[Symbol_Id]bool, 0, context.temp_allocator),
	}
	if type_is_enum(k.c, subject) {
		cases.members = enum_members_by_value(k.c, subject)
	}
	has_default := check_default_cases(k, s)
	flow := Flow_Info{}
	for &entry in s.cases {
		for value in entry.values {
			check_case_value(k, value, subject, &cases)
		}
		case_scope := k.scope
		k.scope = new_scope(k.c, case_scope, .Local)
		case_flow := check_stmts(k, entry.stmts)
		k.scope = case_scope
		flow_either(&flow, case_flow)
	}

	s.exhaustive = has_default || check_exhaustive(k, s, subject, cases.covered)
	flow.can_fall_through ||= !s.exhaustive
	return flow
}

// Whether a switch has a default case, of which it may have one.
@(private = "file")
check_default_cases :: proc(k: ^Checker, s: ^Stmt_Switch) -> (has_default: bool) {
	for entry in s.cases {
		if len(entry.values) == 0 {
			if has_default {
				errorf(k.c, entry.span, "L0367", "this switch already has a default case")
			}
			has_default = true
		}
	}
	return
}

// Names the first three of what a switch leaves out, as one diagnostic.
@(private = "file")
report_uncovered :: proc(k: ^Checker, s: ^Stmt_Switch, subject: Type_Id, code: string, missing: []string) {
	listed := strings.join(missing[:min(len(missing), 3)], ", ", k.c.semantic_allocator)
	more := len(missing) > 3 ? ", ..." : ""
	errorf(k.c, s.span, code, "this switch over `%s` does not cover %s%s", type_name(k.c, subject), listed, more)
}

// What a value switch's cases have named. A generated switch can have thousands,
// so an integer's repeat, and the enum member it covers, are looked up.
@(private = "file")
Case_Values :: struct {
	integers: Integer_Set,
	others:   [dynamic]Const_Value,
	covered:  map[Symbol_Id]bool,
	members:  map[i64]Symbol_Id,
}

@(private = "file")
check_case_value :: proc(k: ^Checker, value: Expr, subject: Type_Id, cases: ^Case_Values) {
	if range, is_range := value.(^Expr_Range); is_range {
		check_value_expr(k, range.lo, subject, "compare")
		check_value_expr(k, range.hi, subject, "compare")
		range.type = subject
		if !type_is_ordered(k.c, subject) {
			errorf(k.c, range.op_span, "L0355", "`%s` is not ordered, so a range case is not meaningful", type_name(k.c, subject))
		}
		return
	}
	// design.md "switch statement": a case names values, never types, so a
	// type is reported rather than compared.
	if _, is_call := value.(^Expr_Call); !is_call {
		if named := resolve_type_syntax(k, value); named != INVALID_TYPE {
			errorf(
				k.c, expr_span(value), "L0426",
				"`%s` is a type, and a switch matches values of its subject `%s`, not types; hold the alternatives in a union to match them",
				type_name(k.c, named), type_name(k.c, subject),
			)
			return
		}
	}
	if !check_value_expr(k, value, subject, "compare") {
		return
	}
	base := expr_base(value)
	if !base_is_const(base) {
		return // an ordered dynamic case, compared in source order
	}
	if case_value_repeats(k.c, cases, base.const_value) {
		errorf(k.c, expr_span(value), "L0367", "this value is already covered by an earlier case")
		return
	}
	if cases.members != nil && base.const_value.kind == .Integer {
		member := INVALID_SYMBOL
		if small, fits := bi_to_i64(k.c, base.const_value.integer); fits {
			member = cases.members[small]
		} else {
			member = enum_member_by_value(k.c, subject, base.const_value)
		}
		if member != INVALID_SYMBOL {
			cases.covered[member] = true
		}
	}
}

@(private = "file")
case_value_repeats :: proc(c: ^Compiler, cases: ^Case_Values, value: Const_Value) -> bool {
	if value.kind == .Integer || value.kind == .Rune {
		return !integer_set_add(c, &cases.integers, value.integer)
	}
	for previous in cases.others {
		if equal, ok := fold_comparison(c, .Eq_Eq, previous, value); ok && equal {
			return true
		}
	}
	append(&cases.others, value)
	return false
}

// design.md "Exhaustive switch": a switch over an enum with no default must
// name every member.
@(private = "file")
check_exhaustive :: proc(k: ^Checker, s: ^Stmt_Switch, subject: Type_Id, covered: map[Symbol_Id]bool) -> (complete: bool) {
	if !type_is_enum(k.c, subject) {
		errorf(k.c, s.span, "L0366", "a switch over `%s` needs a default case", type_name(k.c, subject))
		return false
	}
	missing := make([dynamic]string, context.temp_allocator)
	for member in underlying_info(k.c, subject).fields {
		if !covered[member] {
			append(&missing, identifier_text(k.c, symbol_of(k.c, member).name))
		}
	}
	if len(missing) == 0 {
		return true
	}
	report_uncovered(k, s, subject, "L0366", missing[:])
	return false
}

// --------------------------------------------------------- union switches --

// A union subject turns `.name(binding)` and `.name(&mut binding)` calls into
// branch patterns, and `.name(a, &mut b)` into field bindings.
@(private = "file")
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
	has_default := check_default_cases(k, s)
	flow := Flow_Info{}
	for &entry in s.cases {
		entry.variant_indices = case_variants(k, subject, entry.values, &seen_variants)
		case_scope := k.scope
		k.scope = new_scope(k.c, case_scope, .Local)
		before := len(k.c.diagnostics)
		bind_case(k, &entry, subject, borrows, packed_subject)
		case_flow := check_stmts(k, entry.stmts)
		if entry.arm != nil {
			check_expr(k, entry.arm, s.arm_expected)
		}
		note_expanded_case(k, entry, before)
		k.scope = case_scope
		flow_either(&flow, case_flow)
	}

	s.exhaustive = has_default || variant_count(k.c, subject) == len(seen_variants)
	if !s.exhaustive {
		report_uncovered_variants(k, s, subject, seen_variants[:])
	}
	flow.can_fall_through ||= !s.exhaustive
	return flow
}

// The variants a case names that no earlier case covers, each added to `seen`.
@(private = "file")
case_variants :: proc(k: ^Checker, subject: Type_Id, values: []Expr, seen: ^[dynamic]int) -> []int {
	indices := make([dynamic]int, 0, len(values), k.c.semantic_allocator)
	for value in values {
		index := case_variant_index(k, subject, value)
		if index < 0 {
			continue
		}
		if slice.contains(seen[:], index) {
			errorf(
				k.c, expr_span(value), "L0367",
				"`.%s` is already covered by an earlier case", union_variant_name(k.c, subject, index),
			)
			continue
		}
		append(&indices, index)
		append(seen, index)
	}
	return indices[:]
}

// Declares what a case binds, in its open scope. A case that named no variant
// has reported that, so its binding is untyped and its body reports nothing of it.
@(private = "file")
bind_case :: proc(k: ^Checker, entry: ^Switch_Case, subject: Type_Id, borrows: bool, packed_subject: string) {
	// Grouped cases bind the union; singleton cases bind their payload.
	binding_type := len(entry.values) > 0 && len(entry.variant_indices) == 0 ? INVALID_TYPE : subject
	payloadless := false
	if len(entry.variant_indices) == 1 {
		payload := union_variant_payload(k.c, subject, entry.variant_indices[0])
		binding_type = payload_value_type(k.c, payload)
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
		resolve_case_fields(k, entry, binding_type, borrows)
	if entry.descriptor.aggregate != nil && len(entry.variant_indices) == 1 {
		bind_expanded_case(k, entry, union_variant_payload(k.c, subject, entry.variant_indices[0]))
	}
	if len(entry.fields) == 0 {
		entry.binding_symbol = bind_case_name(k, entry.binding, binding_type, entry.binding_ref, borrows)
		mark_packed_binding(k, entry.binding_symbol, entry.binding, entry.binding_ref, packed_subject)
	}
	packed_payload := resolved && underlying_info(k.c, binding_type).packed
	for &field in entry.fields {
		field.symbol = bind_case_name(k, field.name, field.type, field.is_ref, borrows)
		origin := packed_subject
		if origin == "" && borrows && packed_payload {
			origin = identifier_text(k.c, symbol_of(k.c, underlying_info(k.c, binding_type).fields[field.slot]).name)
		}
		mark_packed_binding(k, field.symbol, field.name, field.is_ref, origin)
	}
	if !resolved {
		entry.fields = nil
	}
}

// One name a case binds, in its open scope: the payload, or one of its fields.
// Over a place it names storage the subject still owns (design.md "Switch
// ownership").
@(private = "file")
bind_case_name :: proc(k: ^Checker, binding: Name, type: Type_Id, is_ref, borrows: bool) -> Symbol_Id {
	if !check_new_local(k, binding, k.scope) {
		return INVALID_SYMBOL
	}
	name := name_identifier(k.c, binding)
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
	missing := make([dynamic]string, context.temp_allocator)
	for _, index in type_of(k.c, type_underlying(k.c, subject)).variants {
		if !slice.contains(covered, index) {
			append(&missing, concat(k.c, ".", union_variant_name(k.c, subject, index)))
		}
	}
	report_uncovered(k, s, subject, "L0427", missing[:])
}

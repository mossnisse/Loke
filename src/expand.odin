// design.md "Static `foreach` expansion": the iterable folds to constants and
// one clone of the body is checked per element, so each copy may have its own
// static types. An expanded switch case and a union argument expansion clone
// per variant the same way: design.md "Per-variant switch cases" and
// design.md "Union argument expansion".
package lokec

import "core:fmt"
import "core:slice"

check_static_foreach :: proc(k: ^Checker, s: ^Stmt_Foreach) -> Flow_Info {
	if len(s.bindings) == 0 {
		errorf(k.c, s.span, "L0454", "a `foreach` binds at least one name")
		return FLOWS
	}
	if !check_static_pattern_markers(k, s.bindings) { return FLOWS }

	// Reported once on the written body, not per copy. The copies are still
	// checked, so nothing else in the body goes unreported.
	outer_reported := k.branches_reported
	k.branches_reported = block_has_branch(k, s.body)
	defer k.branches_reported = outer_reported

	elements, element_type, folded := fold_static_iterable(k, s.iterable)
	if !folded {
		return FLOWS
	}

	blocks := make([dynamic]^Block, 0, len(elements), k.c.semantic_allocator)
	flow := FLOWS
	for index in 0 ..< len(elements) {
		at := s.adapter == .Reversed ? len(elements) - 1 - index : index
		copy_block, copy_flow, ok := expand_one_element(k, s, elements[at], element_type, index)
		if ok {
			append(&blocks, copy_block)
			flow.returns ||= copy_flow.returns
			flow.breaks ||= copy_flow.breaks
			flow.continues ||= copy_flow.continues
			flow.can_fall_through = flow.can_fall_through && copy_flow.can_fall_through
		}
	}
	s.expansion = blocks[:]
	s.kind = .Static
	return flow
}

@(private = "file")
expand_one_element :: proc(
	k: ^Checker,
	s: ^Stmt_Foreach,
	element: Const_Value,
	element_type: Type_Id,
	index: int,
) -> (^Block, Flow_Info, bool) {
	copy_block := clone_block(k.c, s.body)
	outer := k.scope
	k.scope = new_scope(k.c, outer, .Local)
	defer k.scope = outer

	if !bind_static_element(k, s, element, element_type, index) {
		return copy_block, FLOWS, false
	}

	before := len(k.c.diagnostics)
	outer_loop, outer_expanded := k.loop_depth, k.expanded_in_loops
	k.loop_depth, k.expanded_in_loops = 0, outer_expanded + outer_loop
	flow := check_block(k, copy_block)
	k.loop_depth, k.expanded_in_loops = outer_loop, outer_expanded
	if len(k.c.diagnostics) > before {
		add_notef(
			k.c,
			s.span,
			"in static expansion %d, for %s",
			index,
			static_element_text(k.c, element, element_type),
		)
	}
	return copy_block, flow, true
}

@(private = "file")
bind_static_element :: proc(
	k: ^Checker,
	s: ^Stmt_Foreach,
	element: Const_Value,
	element_type: Type_Id,
	index: int,
) -> bool {
	if s.indexed {
		pair_type := indexed_element_type(k.c, element_type)
		return bind_static_pattern(k, s.bindings, indexed_pair(k.c, pair_type, element, index), pair_type)
	}
	return bind_static_pattern(k, s.bindings, element, element_type)
}

// The `(element, index)` constant of an `.indexed()` iteration.
@(private = "file")
indexed_pair :: proc(c: ^Compiler, pair_type: Type_Id, element: Const_Value, index: int) -> Const_Value {
	pair := new(Const_Aggregate, c.semantic_allocator)
	pair.type = pair_type
	pair.elements = make([]Const_Value, 2, c.semantic_allocator)
	pair.elements[ELEMENT_FIRST] = element
	pair.elements[ELEMENT_SECOND] = int_const(c, i64(index))
	return Const_Value{kind = .Aggregate, aggregate = pair}
}

@(private = "file")
check_static_pattern_markers :: proc(k: ^Checker, bindings: []Foreach_Binding) -> bool {
	for binding in bindings {
		if len(binding.group) > 0 {
			if !check_static_pattern_markers(k, binding.group) { return false }
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
		// Checked once here, not per expanded element where `bind_static` runs.
		if binding.name.text != "_" && reject_reserved_name(k, name_identifier(k.c, binding.name), binding.name.span) {
			return false
		}
	}
	return true
}

@(private = "file")
bind_static_pattern :: proc(
	k: ^Checker, bindings: []Foreach_Binding, value: Const_Value, type: Type_Id,
) -> bool {
	if len(bindings) == 1 && len(bindings[0].group) > 0 {
		return bind_static_pattern(k, bindings[0].group, value, type)
	}
	if len(bindings) == 1 && len(bindings[0].group) == 0 {
		bind_static(k, bindings[0], value, type)
		return true
	}
	info := underlying_info(k.c, type)
	if info == nil || info.kind != .Struct || len(info.fields) != len(bindings) {
		count := info != nil && info.kind == .Struct ? len(info.fields) : 0
		errorf(
			k.c, bindings[0].name.span, "L0454",
			"`%s` has %d fields, so a static `foreach` over it binds 1 or %d names, not %d",
			type_name(k.c, type), count, count, len(bindings),
		)
		return false
	}
	for binding, slot in bindings {
		field := symbol_of(k.c, info.fields[slot])
		if field == nil || !require_visible_field(k, binding.name.span, type, info.fields[slot], "L0454", "bound by a `foreach`") {
			return false
		}
		part: Const_Value
		if value.aggregate != nil && slot < len(value.aggregate.elements) {
			part = value.aggregate.elements[slot]
		}
		if len(binding.group) > 0 {
			if !bind_static_pattern(k, binding.group, part, field.type) { return false }
		} else {
			bind_static(k, binding, part, field.type)
		}
	}
	return true
}

bind_static :: proc(k: ^Checker, binding: Foreach_Binding, value: Const_Value, type: Type_Id) {
	if binding.name.text == "_" || binding.name.text == "" {
		return
	}
	id := binding.name.id
	if id == INVALID_IDENTIFIER {
		id = intern_identifier(k.c, binding.name.text)
	}
	k.scope.names[id] = new_symbol(k.c, Symbol {
		name        = id,
		span        = binding.name.span,
		kind        = .Const,
		type        = type,
		const_value = value,
		pkg         = k.pkg,
	})
}

@(private = "file")
static_element_text :: proc(c: ^Compiler, value: Const_Value, type: Type_Id) -> string {
	// Both descriptors put the name first.
	if type_is_descriptor(c, type) && value.aggregate != nil && len(value.aggregate.elements) > META_FIELD_NAME {
		return fmt.aprintf(
			"`%s`", value.aggregate.elements[META_FIELD_NAME].text,
			allocator = c.semantic_allocator,
		)
	}
	return fmt.aprintf("`%s`", const_display_text(c, value), allocator = c.semantic_allocator)
}

const_display_text :: proc(c: ^Compiler, value: Const_Value) -> string {
	#partial switch value.kind {
	case .Integer, .Rune:
		return bi_text(c, value.integer)
	case .Boolean:
		return value.boolean ? "true" : "false"
	case .String:
		return value.text
	case .Type:
		return type_name(c, value.type_value)
	case .Float:
		return fmt.aprintf("%v", value.float, allocator = c.semantic_allocator)
	}
	return "<value>"
}

// design.md: `break` and `continue` cannot target a static expansion. Loops in
// the body own their branches, so they are not walked.
@(private = "file")
block_has_branch :: proc(k: ^Checker, block: ^Block) -> bool {
	return block != nil && stmts_have_branch(k, block.stmts)
}

@(private = "file")
stmts_have_branch :: proc(k: ^Checker, stmts: []Stmt) -> bool {
	found := false
	for stmt in stmts {
		found = stmt_has_branch(k, stmt) || found
	}
	return found
}

@(private = "file")
stmt_has_branch :: proc(k: ^Checker, stmt: Stmt) -> bool {
	#partial switch v in stmt {
	case ^Stmt_Branch:
		errorf(
			k.c, v.span, "L0455", "`%s` cannot target a static expansion; it is not a loop",
			v.kind == .Break ? "break" : "continue",
		)
		return true
	case ^Block:
		return block_has_branch(k, v)
	case ^Stmt_Parallel:
		return block_has_branch(k, v.body)
	case ^Stmt_If:
		found := block_has_branch(k, v.then)
		return v.otherwise != nil && stmt_has_branch(k, v.otherwise) || found
	case ^Stmt_When:
		found := block_has_branch(k, v.then)
		return v.otherwise != nil && stmt_has_branch(k, v.otherwise) || found
	case ^Stmt_Switch:
		found := false
		for arm in v.cases {
			found = stmts_have_branch(k, arm.stmts) || found
		}
		return found
	}
	return false
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
			kind := type_of(k.c, type).adapter_kind
			element_type := associated_type_of(k, type, "Element")
			out := make([]Const_Value, len(elements), k.c.semantic_allocator)
			for element, index in elements {
				if kind == .Reversed {
					out[len(elements) - 1 - index] = element
				} else {
					out[index] = indexed_pair(k.c, element_type, element, index)
				}
			}
			return out, element_type, true
		}
	}
	if written, is_range := iterable.(^Expr_Range); is_range {
		return fold_static_range(k, written, type)
	}
	if written, is_slice := iterable.(^Expr_Slice); is_slice {
		return fold_static_slice(k, written, type)
	}
	info := underlying_info(k.c, type)
	if info != nil && info.kind == .Dynamic_Array {
		elements, evaluated := evaluate_static_elements(k, iterable, "a static `foreach` iterable", "L0454")
		return elements, info.element, evaluated
	}
	folded, evaluated := require_const(k, iterable, "a static `foreach` iterable", "L0454")
	if !evaluated {
		return nil, INVALID_TYPE, false
	}
	if info == nil || info.kind != .Array {
		errorf(
			k.c,
			expr_span(iterable),
			"L0454",
			"a static `foreach` needs a compile-time array, subrange, `Enum.values()`, range, or descriptor array, found `%s`",
			type_name(k.c, type),
		)
		return nil, INVALID_TYPE, false
	}
	count := int(info.count)
	elements := make([]Const_Value, count, k.c.semantic_allocator)
	for index in 0 ..< count {
		if folded.aggregate != nil && index < len(folded.aggregate.elements) {
			elements[index] = folded.aggregate.elements[index]
		}
	}
	return elements, info.element, true
}

@(private = "file")
fold_static_range :: proc(k: ^Checker, written: ^Expr_Range, type: Type_Id) -> ([]Const_Value, Type_Id, bool) {
	lo, lo_ok := require_const(k, written.lo, "a static `foreach` range endpoint", "L0454")
	hi, hi_ok := require_const(k, written.hi, "a static `foreach` range endpoint", "L0454")
	if !lo_ok || !hi_ok {
		return nil, INVALID_TYPE, false
	}
	element := underlying_info(k.c, type).element
	distance := bi_sub(k.c, hi.integer, lo.integer)
	count := distance
	if written.op == .Range_Incl {
		count = bi_add(k.c, count, bi_from_i64(k.c, 1))
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
		current = bi_add(k.c, current, bi_from_i64(k.c, 1))
	}
	return elements, element, true
}

@(private = "file")
fold_static_slice :: proc(k: ^Checker, written: ^Expr_Slice, type: Type_Id) -> ([]Const_Value, Type_Id, bool) {
	elements, _, folded := fold_static_iterable(k, written.operand)
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
	out := make([]Const_Value, int(hi-lo), k.c.semantic_allocator)
	copy(out, elements[int(lo):int(hi)])
	return out, underlying_info(k.c, type).element, true
}

// A written subrange endpoint, or `missing` when it is omitted.
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

// design.md "Per-variant switch cases": `case $variant(payload):` stands for one
// case per variant no earlier case names, in declaration order. Each copy is an
// ordinary case `.name(payload)` whose body is a fresh clone of the written one,
// checked on its own as a static `foreach` body is, so nothing after the
// checker sees an expanded case. False after a diagnostic.
expand_variant_cases :: proc(k: ^Checker, s: ^Stmt_Switch, subject: Type_Id) -> bool {
	position := -1
	for entry, index in s.cases {
		for value in entry.values {
			if _, _, is_expanded := expanded_case_pattern(value); !is_expanded {
				continue
			}
			if position >= 0 {
				errorf(k.c, expr_span(value), "L0367", "a switch has at most one expanded case")
				return false
			}
			if len(entry.values) != 1 {
				errorf(
					k.c, expr_span(value), "L0367",
					"an expanded case covers every remaining variant, so it names nothing else",
				)
				return false
			}
			position = index
		}
	}
	if position < 0 {
		return true
	}
	written := s.cases[position]
	if subject == TYPE_ANY_VIEW || !type_is_union(k.c, subject) {
		errorf(
			k.c, expr_span(written.values[0]), "L0426",
			"an expanded case needs a union subject, and this switch is over `%s`", type_name(k.c, subject),
		)
		return false
	}
	if position != len(s.cases) - 1 {
		next := s.cases[position + 1]
		errorf(
			k.c, next.span, "L0367", "%s",
			len(next.values) == 0 ? "`default:` cannot follow an expanded case, which already covers every remaining variant" : "an expanded case covers every remaining variant, so it is the last case",
		)
		return false
	}
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
		label := new(Expr_Selector, k.c.semantic_allocator)
		label.span = span
		label.name = Name{text = union_variant_name(k.c, subject, index), span = span}
		values := make([]Expr, 1, k.c.semantic_allocator)
		values[0] = label
		body := Block{stmts = written.stmts}
		append(&cases, Switch_Case {
			span        = written.span,
			values      = values,
			stmts       = clone_block(k.c, &body).stmts,
			binding     = payload.name,
			binding_ref = payload.is_ref,
			expanded    = descriptor,
			descriptor  = variant_descriptor(k.c, subject, index),
		})
	}
	s.cases = cases[:]
	return true
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
	if descriptor.text != "_" && reject_reserved_name(k, name_identifier(k.c, descriptor), descriptor.span) {
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
	bind_static(k, Foreach_Binding{name = entry.expanded}, entry.descriptor, meta_variant_type(k.c))
	if payload != TYPE_VOID || entry.binding.text == "" {
		return
	}
	unit := new(Const_Aggregate, k.c.semantic_allocator)
	unit.type = k.c.unit_type
	bind_static(k, Foreach_Binding{name = entry.binding}, Const_Value{kind = .Aggregate, type_value = k.c.unit_type, aggregate = unit}, k.c.unit_type)
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
			entry.descriptor.aggregate.elements[META_VARIANT_NAME].text,
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
	spread := -1
	for arg, index in v.args {
		if arg.mode == .Spread {
			spread = index
			break
		}
	}
	if spread < 0 {
		return false
	}
	// The operand's type decides, and a union is never a sequence. One that
	// needs a destination type has none here, so it is left to the variadic
	// path. Any other operand is checked once, here: a variadic spread reuses
	// its type rather than checking it again, since a recheck of nested spreads
	// would double per level. A call that never returns waits for the pack's
	// type to stand in for.
	operand := v.args[spread].value
	if argument_needs_context(operand) {
		return false
	}
	subject := check_expr(k, operand)
	if subject == INVALID_TYPE || subject == TYPE_VOID || !type_is_union(k.c, subject) {
		v.args[spread].checked = true
		return false
	}
	v.value_category = .Value
	v.type = INVALID_TYPE
	if len(v.args) != 1 {
		errorf(k.c, v.args[spread].span, "L0371", "a union argument expansion is the call's only argument")
		return true
	}
	if v.args[0].name.text != "" {
		errorf(k.c, v.args[0].name.span, "L0371", "a union argument expansion names no parameter; each variant's label does")
		return true
	}

	// design.md "Switch ownership": a place lends its payload, and a temporary
	// or `move(answer)` gives it up, so its call takes it by `move`.
	consumes := !expression_is_borrowed_place(operand)
	s := new(Stmt_Switch, k.c.semantic_allocator)
	s.span = v.span
	s.kind = .Pattern
	s.subject = operand
	s.arm_expected = expected
	s.cases = make([]Switch_Case, variant_count(k.c, subject), k.c.semantic_allocator)
	span := v.args[0].span
	for &entry, index in s.cases {
		label := union_variant_name(k.c, subject, index)
		selector := new(Expr_Selector, k.c.semantic_allocator)
		selector.span = span
		selector.name = Name{text = label, span = span}
		entry.span = v.span
		entry.values = make([]Expr, 1, k.c.semantic_allocator)
		entry.values[0] = selector
		entry.binding = Name{text = DISPATCH_PAYLOAD, span = span, id = intern_identifier(k.c, DISPATCH_PAYLOAD)}
		entry.descriptor = variant_descriptor(k.c, subject, index)

		payload := new(Expr_Ident, k.c.semantic_allocator)
		payload.span = span
		payload.name = DISPATCH_PAYLOAD
		payload.name_id = entry.binding.id
		arm := new(Expr_Call, k.c.semantic_allocator)
		arm.span = v.span
		arm.callee = clone_expr(k.c, v.callee)
		arm.args = make([]Argument, 1, k.c.semantic_allocator)
		// A payloadless variant passes the `Unit{}` constant, which has no owner.
		argument: Expr = payload
		if consumes && union_variant_payload(k.c, subject, index) != TYPE_VOID {
			moved := new(Expr_Move, k.c.semantic_allocator)
			moved.span = span
			moved.value = payload
			argument = moved
		}
		arm.args[0] = Argument{span = span, name = Name{text = label, span = span}, value = argument}
		entry.arm = arm
	}
	v.dispatch = s
	check_variant_cases(k, s, subject)

	// Every expansion has the same result, or none has one; a call that never
	// returns stands in for either.
	result := TYPE_VOID
	decided := -1
	for entry, index in s.cases {
		arm := expr_base(entry.arm)
		if arm.type == INVALID_TYPE {
			return true
		}
		if arm.value_category == .Place {
			errorf(
				k.c, v.span, "L0371",
				"a union argument expansion yields a value, and its call for `.%s` returns a place",
				union_variant_name(k.c, subject, index),
			)
			return true
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
			return true
		}
	}
	v.type = result
	return true
}

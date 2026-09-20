// design.md "Static `foreach` expansion": the iterable folds to constants and
// one clone of the body is checked per element, so each copy may have its own
// static types.
package lokec

import "core:fmt"

check_static_foreach :: proc(k: ^Checker, s: ^Stmt_Foreach) -> Flow_Info {
	if len(s.bindings) == 0 {
		errorf(k.c, s.span, "L0454", "a `foreach` binds at least one name")
		return FLOWS
	}
	if !check_static_pattern_markers(k, s.bindings) { return FLOWS }

	// Checked once on the written body, not per copy.
	if block_has_branch(k, s.body) {
		return FLOWS
	}

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
	outer_loop := k.loop_depth
	k.loop_depth = 0
	flow := check_block(k, copy_block)
	k.loop_depth = outer_loop
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

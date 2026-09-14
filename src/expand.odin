// Static `foreach` expansion (design.md "Static `foreach` expansion").
//
// This is expansion, not a loop: the iterable is folded to a compile-time value,
// one copy of the body is cloned and checked per element, and the copies run in
// order. Sharing the cloning facility with generic instantiation is what lets
// `field.get(value)` have a different static result type in each copy.
package lokec

import "core:fmt"

// An empty iterable expands to nothing, just as an unselected `when` branch has
// no checked contents.
check_static_foreach :: proc(k: ^Checker, s: ^Stmt_Foreach) -> Flow_Info {
	if len(s.bindings) == 0 {
		errorf(k.c, s.span, "L0454", "a `foreach` binds at least one name")
		return FLOWS
	}
	// design.md: mixing a runtime and a compile-time binding in one header is an
	// error, and a static binding is immutable, so `&` cannot apply to one.
	for binding in s.bindings {
		if !binding.is_static {
			errorf(
				k.c,
				binding.name.span,
				"L0454",
				"`%s` is a runtime binding in a static expansion; every binding carries `$`",
				binding.name.text,
			)
			return FLOWS
		}
		if binding.is_ref {
			errorf(k.c, binding.name.span, "L0454", "a static binding is immutable and cannot use `&`")
			return FLOWS
		}
	}

	// design.md: `break` and `continue` cannot target a static expansion. Checked
	// on the written body once, so a rejected branch is not reported per copy.
	if expansion_has_branch(k, s.body) {
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

	// A diagnostic inside an expansion must show the element and its source
	// descriptor or index (design.md).
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

// design.md "Element bindings": one binding names the whole element and several
// name its fields, in an expansion exactly as in a loop. The only difference is
// that every value here is a constant.
@(private = "file")
bind_static_element :: proc(
	k: ^Checker,
	s: ^Stmt_Foreach,
	element: Const_Value,
	element_type: Type_Id,
	index: int,
) -> bool {
	effective_value := element
	effective_type := element_type
	if s.indexed {
		aggregate := new(Const_Aggregate, k.c.semantic_allocator)
		aggregate.type = indexed_element_type(k.c, element_type)
		aggregate.elements = make([]Const_Value, 2, k.c.semantic_allocator)
		aggregate.elements[ELEMENT_FIRST] = element
		aggregate.elements[ELEMENT_SECOND] = int_const(k.c, i64(index))
		effective_value = Const_Value{kind = .Aggregate, aggregate = aggregate}
		effective_type = aggregate.type
	}

	if len(s.bindings) == 1 {
		bind_static(k, s.bindings[0], effective_value, effective_type)
		return true
	}
	// Several names over one record element.
	info := underlying_info(k.c, effective_type)
	if info == nil || info.kind != .Struct || len(info.fields) != len(s.bindings) {
		count := info != nil && info.kind == .Struct ? len(info.fields) : 0
		errorf(
			k.c, s.bindings[1].name.span, "L0454",
			"`%s` has %d fields, so a static `foreach` over it binds 1 or %d names, not %d",
			type_name(k.c, effective_type), count, count, len(s.bindings),
		)
		return false
	}
	for binding, slot in s.bindings {
		field := symbol_of(k.c, info.fields[slot])
		if !require_visible_field(k, binding.name.span, effective_type, info.fields[slot], "L0454", "bound by a `foreach`") {
			return false
		}
		value: Const_Value
		if effective_value.aggregate != nil && slot < len(effective_value.aggregate.elements) {
			value = effective_value.aggregate.elements[slot]
		}
		bind_static(k, binding, value, field.type)
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

// A descriptor prints as its name; anything else prints as its value.
@(private = "file")
static_element_text :: proc(c: ^Compiler, value: Const_Value, type: Type_Id) -> string {
	if type_is_descriptor(c, type) && value.aggregate != nil && len(value.aggregate.elements) > 0 {
		return fmt.aprintf("`%s`", value.aggregate.elements[0].text, allocator = c.semantic_allocator)
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

// design.md: `break` and `continue` cannot target a static expansion. Ordinary
// runtime loops inside its body may use them normally, so this only walks the
// statements the expansion itself owns.
@(private = "file")
expansion_has_branch :: proc(k: ^Checker, block: ^Block) -> bool {
	if block == nil {
		return false
	}
	found := false
	for stmt in block.stmts {
		#partial switch v in stmt {
		case ^Stmt_Branch:
			errorf(
				k.c,
				v.span,
				"L0455",
				"`%s` cannot target a static expansion; it is not a loop",
				v.kind == .Break ? "break" : "continue",
			)
			found = true
		case ^Block:
			found = expansion_has_branch(k, v) || found
		case ^Stmt_If:
			found = expansion_has_branch(k, v.then) || found
			if otherwise, is_block := v.otherwise.(^Block); is_block {
				found = expansion_has_branch(k, otherwise) || found
			}
		case ^Stmt_When:
			found = expansion_has_branch(k, v.then) || found
			if otherwise, is_block := v.otherwise.(^Block); is_block {
				found = expansion_has_branch(k, otherwise) || found
			}
		}
	}
	return found
}

// ---------------------------------------------------------- the iterable --

// The iterable must be compile-time known, finite, and produce compile-time
// values; fixed arrays, evaluator-owned dynamic arrays, `Enum.values()`, ranges,
// and reflection descriptor arrays qualify (design.md).
@(private = "file")
fold_static_iterable :: proc(k: ^Checker, iterable: Expr) -> ([]Const_Value, Type_Id, bool) {
	// design.md: a *type* is never an iterable. An enumeration's members are a
	// value, `Enum.values()`, which folds to an ordinary constant array.
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
					pair := new(Const_Aggregate, k.c.semantic_allocator)
					pair.type = element_type
					pair.elements = make([]Const_Value, 2, k.c.semantic_allocator)
					pair.elements[0] = element
					pair.elements[1] = int_const(k.c, i64(index))
					out[index] = Const_Value{kind = .Aggregate, aggregate = pair}
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
	info = underlying_info(k.c, type)
	if info == nil || info.kind != .Array {
		errorf(
			k.c,
			expr_span(iterable),
			"L0454",
			"a static `foreach` needs a compile-time array or slice, `Enum.values()`, range, or descriptor array, found `%s`",
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
	lo, hi := i64(0), i64(len(elements))
	if written.lo != nil {
		value, ok := require_const(k, written.lo, "a static `foreach` slice endpoint", "L0454")
		if !ok {
			return nil, INVALID_TYPE, false
		}
		lo, ok = bi_to_i64(k.c, value.integer)
		if !ok {
			errorf(k.c, expr_span(written.lo), "L0454", "a static `foreach` slice endpoint does not fit in `int`")
			return nil, INVALID_TYPE, false
		}
	}
	if written.hi != nil {
		value, ok := require_const(k, written.hi, "a static `foreach` slice endpoint", "L0454")
		if !ok {
			return nil, INVALID_TYPE, false
		}
		hi, ok = bi_to_i64(k.c, value.integer)
		if !ok {
			errorf(k.c, expr_span(written.hi), "L0454", "a static `foreach` slice endpoint does not fit in `int`")
			return nil, INVALID_TYPE, false
		}
	}
	if lo < 0 || hi < lo || hi > i64(len(elements)) {
		errorf(k.c, written.span, "L0454", "a static `foreach` slice is out of bounds")
		return nil, INVALID_TYPE, false
	}
	out := make([]Const_Value, int(hi-lo), k.c.semantic_allocator)
	copy(out, elements[int(lo):int(hi)])
	return out, underlying_info(k.c, type).element, true
}

// design.md "Iterating an enumeration": `Enum.values()` is the declaration-ordered
// fixed array of its members, and the only way to iterate an enumeration. It is a
// constant, so it serves a runtime loop, a static expansion, and a `$` argument
// through the ordinary array paths rather than a `foreach` special case.
check_enum_values :: proc(k: ^Checker, v: ^Expr_Call, sel: ^Expr_Selector) -> bool {
	if sel.name.text != "values" {
		return false
	}
	subject := resolve_type_syntax(k, sel.operand)
	if subject == INVALID_TYPE || !type_is_enum(k.c, subject) {
		return false
	}
	v.value_category = .Value
	v.resolution = Resolution{kind = .Builtin_Operator}
	if len(v.args) != 0 {
		errorf(k.c, v.span, "L0460", "`%s.values` takes no arguments", type_name(k.c, subject))
		v.type = INVALID_TYPE
		return true
	}
	members, ok := enum_member_constants(k, subject)
	if !ok {
		v.type = INVALID_TYPE
		return true
	}
	aggregate := new(Const_Aggregate, k.c.semantic_allocator)
	aggregate.type = array_of(k.c, subject, u64(len(members)))
	aggregate.elements = members
	v.type = aggregate.type
	v.is_const = true
	v.const_value = Const_Value{kind = .Aggregate, aggregate = aggregate}
	v.immutable = .Constant
	return true
}

enum_member_constants :: proc(k: ^Checker, enum_type: Type_Id) -> ([]Const_Value, bool) {
	info := underlying_info(k.c, enum_type)
	if info == nil {
		return nil, false
	}
	out := make([]Const_Value, len(info.fields), k.c.semantic_allocator)
	for member, index in info.fields {
		if sym := symbol_of(k.c, member); sym != nil {
			out[index] = sym.const_value
		}
	}
	return out, true
}

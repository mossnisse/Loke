// Static `foreach` expansion (m4b-plan step 3, design.md "Static `foreach`
// expansion").
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
	if len(s.bindings) == 0 || len(s.bindings) > 2 {
		errorf(k.c, s.span, "L0454", "a `foreach` binds one or two names")
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
				"`%s` is a runtime binding in a static expansion; both bindings carry `$`",
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
	for element, index in elements {
		copy_block, copy_flow, ok := expand_one_element(k, s, element, element_type, index)
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

	bind_static(k, s.bindings[0], element, element_type)
	if len(s.bindings) == 2 {
		bind_static(k, s.bindings[1], int_const(k.c, i64(index)), TYPE_INT)
	}

	// design.md: "Diagnostics inside an expansion must show the element and its
	// source descriptor or index."
	before := len(k.c.diagnostics)
	outer_loop, outer_switch := k.loop_depth, k.switch_depth
	k.loop_depth, k.switch_depth = 0, 0
	flow := check_block(k, copy_block)
	k.loop_depth, k.switch_depth = outer_loop, outer_switch
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
		}
	}
	return found
}

// ---------------------------------------------------------- the iterable --

// design.md: "The iterable must be compile-time known, finite, and produce
// compile-time values. Fixed arrays, evaluator-owned arrays and slices, enum
// types, ranges, and reflection descriptor arrays qualify."
@(private = "file")
fold_static_iterable :: proc(k: ^Checker, iterable: Expr) -> ([]Const_Value, Type_Id, bool) {
	// An enum *type* expands to its members, which is what makes
	// `foreach ($member in Colour)` mean something.
	if enum_type := resolve_type_syntax(k, iterable); enum_type != INVALID_TYPE {
		if type_is_enum(k.c, enum_type) {
			return enum_member_constants(k, enum_type)
		}
		errorf(
			k.c,
			expr_span(iterable),
			"L0454",
			"`%s` is a type, and only an enum type expands element by element",
			type_name(k.c, enum_type),
		)
		return nil, INVALID_TYPE, false
	}

	type := check_single_expr(k, iterable)
	if type == INVALID_TYPE {
		return nil, INVALID_TYPE, false
	}
	folded, evaluated := require_const(k, iterable, "a static `foreach` iterable", "L0454")
	if !evaluated {
		return nil, INVALID_TYPE, false
	}
	info := underlying_info(k.c, type)
	if info == nil || info.kind != .Array {
		errorf(
			k.c,
			expr_span(iterable),
			"L0454",
			"a static `foreach` needs a compile-time array, enum type, or descriptor array, found `%s`",
			type_name(k.c, type),
		)
		return nil, INVALID_TYPE, false
	}
	elements := make([]Const_Value, int(info.count), k.c.semantic_allocator)
	for index in 0 ..< int(info.count) {
		if folded.aggregate != nil && index < len(folded.aggregate.elements) {
			elements[index] = folded.aggregate.elements[index]
		}
	}
	return elements, info.element, true
}

@(private = "file")
enum_member_constants :: proc(k: ^Checker, enum_type: Type_Id) -> ([]Const_Value, Type_Id, bool) {
	info := underlying_info(k.c, enum_type)
	if info == nil {
		return nil, INVALID_TYPE, false
	}
	out := make([]Const_Value, len(info.fields), k.c.semantic_allocator)
	for member, index in info.fields {
		if sym := symbol_of(k.c, member); sym != nil {
			out[index] = sym.const_value
		}
	}
	return out, enum_type, true
}

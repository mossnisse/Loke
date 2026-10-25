// The checked form of a value's origin, described once when the value is
// interned. Leaf queries choose their rule from it and read operands as
// values; they keep the origin node only as a key, a span or name, or checked
// metadata such as a resolution or a value category.
package lokec

Prov_Form_Symbol :: struct { symbol: Symbol_Id }
// `operand.name`; `step` is its projection when it selects a field.
Prov_Form_Selector :: struct { operand: Value_Id, step: Proj_Step, field: bool }
// `operator` is the call a user operator stands for.
Prov_Form_Index :: struct { operand: Value_Id, operator: ^Expr_Call }
Prov_Form_Slice :: struct { operand: Value_Id, operator: ^Expr_Call }
Prov_Form_Binary :: struct { operator: ^Expr_Call }
Prov_Form_Unary :: struct { operand: Value_Id, op: Token_Kind, operator: ^Expr_Call }
// `boxed` when the operand is a box, whose payload `operand^` names.
Prov_Form_Postfix :: struct { operand: Value_Id, op: Token_Kind, boxed: bool }
Prov_Form_Move :: struct { operand: Value_Id }
// The error an `or_return` propagates, from its fallible `operand`.
Prov_Form_Error :: struct { operand: Value_Id, borrows: bool }
// `arguments` are the values of its bound arguments, or of its written ones
// for a call without bound arguments.
Prov_Form_Call :: struct { call: ^Expr_Call, arguments: []Value_Id }
Prov_Form_Composite :: struct { elements: []Value_Id }
Prov_Form :: union {
	Prov_Form_Symbol, Prov_Form_Selector, Prov_Form_Index, Prov_Form_Slice, Prov_Form_Binary,
	Prov_Form_Unary, Prov_Form_Postfix, Prov_Form_Move, Prov_Form_Error, Prov_Form_Call, Prov_Form_Composite,
}

// An operand is read at its checked representation, in its parent's expansion;
// only the parent's own conversions select a value beneath it.
@(private)
prov_operand_value :: proc(graph: ^Flow_Graph, e: Expr, expansion: Defer_Expansion) -> Value_Id {
	if expr_base(e) == nil { return 0 }
	return prov_intern_value(graph, e, prov_checked_repr(e), expansion)
}

@(private)
prov_describe_form :: proc(graph: ^Flow_Graph, e: Expr, expansion: Defer_Expansion) -> Prov_Form {
	c := graph.k.c
	#partial switch v in e {
	case ^Expr_Ident:
		return Prov_Form_Symbol{v.symbol}
	case ^Expr_Selector:
		form := Prov_Form_Selector{operand = prov_operand_value(graph, v.operand, expansion), field = v.resolution.kind == .Field}
		if form.field && v.operand != nil { form.step = prov_field_step(graph, v) }
		return form
	case ^Expr_Index:
		return Prov_Form_Index{prov_operand_value(graph, v.operand, expansion), prov_form_operator(graph, v)}
	case ^Expr_Slice:
		return Prov_Form_Slice{prov_operand_value(graph, v.operand, expansion), prov_form_operator(graph, v)}
	case ^Expr_Binary:
		return Prov_Form_Binary{prov_form_operator(graph, v)}
	case ^Expr_Unary:
		return Prov_Form_Unary{prov_operand_value(graph, v.operand, expansion), v.op, prov_form_operator(graph, v)}
	case ^Expr_Postfix:
		boxed := v.operand != nil && type_is_box(c, expr_base(v.operand).type)
		return Prov_Form_Postfix{prov_operand_value(graph, v.operand, expansion), v.op, boxed}
	case ^Expr_Move:
		return Prov_Form_Move{prov_operand_value(graph, v.value, expansion)}
	case ^Expr_Propagated_Error:
		return prov_error_form(graph, v.owner, expansion)
	case ^Expr_Call:
		return Prov_Form_Call{v, prov_argument_values(graph, v, expansion)}
	case ^Expr_Composite:
		elements := make([]Value_Id, len(v.elements), graph.alloc)
		for element, index in v.elements { elements[index] = prov_operand_value(graph, element.value, expansion) }
		return Prov_Form_Composite{elements}
	}
	return nil
}

// The error `owner`, an `or_return`, propagates.
@(private)
prov_error_form :: proc(graph: ^Flow_Graph, owner: ^Expr_Postfix, expansion: Defer_Expansion) -> Prov_Form_Error {
	return Prov_Form_Error{prov_operand_value(graph, owner.operand, expansion), owner.borrows}
}

@(private = "file")
prov_form_operator :: proc(graph: ^Flow_Graph, e: Expr) -> ^Expr_Call {
	return expr_base(e).resolution.kind == .User_Operator ? prov_operator_call(graph, e) : nil
}

// The call a value stands for: its own, unless it dispatches through an
// interface, or a user operator's.
@(private)
prov_value_call :: proc(graph: ^Flow_Graph, id: Value_Id) -> ^Expr_Call {
	#partial switch form in prov_value(graph, id).form {
	case Prov_Form_Call:   return form.call.dispatch == nil ? form.call : nil
	case Prov_Form_Index:  return form.operator
	case Prov_Form_Slice:  return form.operator
	case Prov_Form_Binary: return form.operator
	case Prov_Form_Unary:  return form.operator
	}
	return nil
}

@(private)
prov_argument_values :: proc(graph: ^Flow_Graph, call: ^Expr_Call, expansion: Defer_Expansion) -> []Value_Id {
	count := len(call.bound) > 0 ? len(call.bound) : len(call.args)
	values := make([]Value_Id, count, graph.alloc)
	for index in 0 ..< count {
		argument := len(call.bound) > 0 ? call.bound[index] : call.args[index].value
		values[index] = prov_operand_value(graph, argument, expansion)
	}
	return values
}

// A method call's receiver: its first argument.
@(private)
prov_receiver_value :: proc(arguments: []Value_Id) -> Value_Id {
	return len(arguments) > 0 ? arguments[0] : 0
}

// The argument values of a call an event names, in the expansion of its site.
@(private)
prov_call_values :: proc(graph: ^Flow_Graph, call: ^Expr_Call) -> []Value_Id {
	return prov_input_call(graph, call).values
}

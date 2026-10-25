// Checked call inputs. Evaluation order and parameter order are separate;
// summaries and evaluated operand facts never belong to this description.
package lokec

import "core:mem"
import "core:slice"

Prov_Synthetic_Call_Key :: struct {
	callee: Symbol_Id,
	type: Type_Id,
	span: Span,
	expansion: Defer_Expansion,
	indexes: bool,
}

Prov_Call_Argument :: struct {
	type: Type_Id,
	mode: Param_Mode,
	place: bool,
}

Prov_Call_Input :: struct {
	signature: Type_Id,
	result_inout: bool,
	writes_facts: bool,
	arguments: []Prov_Call_Argument,
	order: []int,
	receiver: Param_Mode,
	has_receiver: bool,
	container: Container_Op,
	// The receiver is loaded at its argument point and lent after all operands.
	capture: Value_Id,
}

// design.md "Evaluation order", "Parameter semantics and ABI lowering",
// "Splitting a mutable slice".
// Keyed by the call node alone, as its capture is (`prov_input_capture`).
prov_input_call :: proc(graph: ^Flow_Graph, call: ^Expr_Call) -> Prov_Call_Input {
	key := Prov_Input_Key{node = &call.base, expansion = graph.expansion}
	if input, found := graph.input.calls[key]; found { return input }
	prov_writable_input(graph)
	c := graph.k.c
	input := Prov_Call_Input{signature = call_proc_type(c, call)}
	if member := symbol_of(c, call.resolution.chosen_overload); member != nil && member.has_receiver {
		input.receiver, input.has_receiver = member.receiver, true
		if member.synth == .Container_Op { input.container = member.container_op }
	}
	info := underlying_info(c, input.signature)
	if info != nil { input.result_inout = info.result_inout }
	input.arguments = make([]Prov_Call_Argument, len(call.bound), graph.alloc)
	input.order = make([]int, len(call.bound), graph.alloc)
	for argument, index in call.bound {
		part: Prov_Call_Argument
		// Freeze region-carrying operands before replay reads their facts. Scalar
		// computations keep their evaluation slot; their effects stay in source order.
		if argument != nil && prov_type_has_region(c, expr_base(argument).type) {
			_ = prov_input_value(graph, argument)
		}
		if info != nil && index < len(info.parameters) { part.type = info.parameters[index] }
		if info != nil && index < len(info.param_modes) { part.mode = info.param_modes[index] }
		part.place = part.mode == .Inout
		if index == 0 && input.has_receiver { part.place = input.receiver == .Inout }
		if part.type != INVALID_TYPE {
			input.writes_facts ||= part.place && prov_type_has_region(c, part.type) ||
			                     carrier_is_mutable(c, part.type) || prov_type_reaches_mutable(c, part.type)
		}
		input.arguments[index] = part
		input.order[index] = call_slot_at(call, index)
	}
	if prov_op_lends_receiver(input.container) && len(call.bound) > 0 && call.bound[0] != nil {
		input.capture = prov_input_capture(graph, call, call.bound[0])
	}
	graph.input.calls[key] = input
	return input
}

prov_clone_call_input :: proc(input: Prov_Call_Input, allocator: mem.Allocator) -> Prov_Call_Input {
	out := input
	out.arguments = slice.clone(input.arguments, allocator)
	out.order = slice.clone(input.order, allocator)
	return out
}

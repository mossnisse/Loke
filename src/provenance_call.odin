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
	// The procedure value a call through one evaluates before its arguments;
	// zero for a call to a named procedure or method.
	callee: Value_Id,
}

// What a container operation does to provenance that its signature does not say.
Container_Op_Effect :: enum {
	// Its arguments land in the receiver's content.
	Stores_Content,
	// A provider moved into it is stored there and carries its region along.
	Stores_Provider,
	// It may drop a provider the receiver holds.
	Drops_Provider,
	// It may allocate, resize, or free storage, or drop elements that own storage.
	Allocates,
	// It leaves the receiver's content empty.
	Empties,
	// It reorders the elements in place, storing none.
	Permutes,
	// A carrier in one element may end up in another.
	Moves_Elements,
	// It returns what an element held, not a borrow of the container.
	Removes_Element,
	// design.md "Iteration adapters": a map view read-borrows the map.
	Returns_View,
	// design.md "Splitting a mutable slice", "Chunks of a mutable slice": the
	// result views what the receiver views, so the receiver is lent as a mutable
	// carrier argument is.
	Lends_Receiver,
}

// One row per operation, and not `#partial`, so a new operation has to say.
@(rodata)
CONTAINER_OP_EFFECTS := [Container_Op]bit_set[Container_Op_Effect] {
	.None               = {},
	.Append             = {.Stores_Content, .Stores_Provider, .Allocates},
	.Insert             = {.Stores_Content, .Stores_Provider, .Allocates, .Moves_Elements},
	.Pop                = {.Drops_Provider, .Removes_Element},
	.Remove             = {.Drops_Provider, .Moves_Elements, .Removes_Element},
	.Remove_Unordered   = {.Drops_Provider, .Moves_Elements, .Removes_Element},
	.Clear              = {.Drops_Provider, .Allocates, .Empties},
	.Resize             = {.Drops_Provider, .Allocates},
	.Reserve            = {.Allocates},
	.Shrink             = {.Allocates},
	.Sort               = {.Permutes, .Moves_Elements},
	.Reverse_Sort       = {.Permutes, .Moves_Elements},
	.Swap               = {.Permutes, .Moves_Elements},
	.Split_At_Mut       = {.Lends_Receiver},
	.Chunks_Mut         = {.Lends_Receiver},
	.Map_Find           = {},
	.Map_Find_Or_Insert = {.Stores_Content, .Allocates},
	.Map_Lookup_Value   = {},
	.Map_Try_Insert     = {.Stores_Content, .Stores_Provider, .Allocates},
	.Map_Remove         = {.Drops_Provider, .Allocates, .Removes_Element},
	.Map_Clear          = {.Drops_Provider, .Allocates, .Empties},
	.Map_Reserve        = {.Allocates},
	.Map_Shrink         = {.Allocates},
	.Map_Entries        = {.Returns_View},
	.Map_Keys           = {.Returns_View},
	.Map_Values         = {.Returns_View},
}

// What a compiler-known procedure, which has no body to summarize, does with
// the receiver it is given.
Prov_Receiver_Contract :: enum u8 {
	// Nothing of its own: a summary says, or the receiver is borrowed for what the
	// call returns.
	Unwritten,
	// design.md "Borrowing iteration": its result is lent by the view the receiver
	// holds, not by the receiver.
	Lends_Held,
	// It measures or hashes, which only reads, and its plain result keeps nothing.
	Only_Reads,
	// Its result holds what the receiver holds, never a loan of the receiver.
	Copies,
}

@(private)
prov_receiver_contract :: proc(c: ^Compiler, callee: ^Symbol) -> Prov_Receiver_Contract {
	if callee == nil {
		return .Unwritten
	}
	#partial switch callee.synth {
	case .Slice_Ref_Next:
		return .Lends_Held
	case .Indexed_Next:
		// `indexed()` lends only while it wraps a lending source.
		return .Lends_Held if indexed_next_lends(c, callee) else .Unwritten
	case .Standard_Len, .Standard_Cap, .Standard_Hash:
		return .Only_Reads
	case .Adapter_Iter, .Iterator_Copy:
		return .Copies
	case .Adapter_View:
		return .Copies if type_of(c, callee.result).adapter_by_value else .Unwritten
	case .Clone, .Try_Clone:
		// design.md "Standard customization procedures": a clone is
		// ownership-recursive, so a generated one's result carries what its receiver
		// carries. A `hook(copy)` taking `self: ^` is the exception, since its body
		// could hand a loan of the receiver out.
		hook := symbol_of(c, lifecycle_of(c, callee.owner_type).custom_try_clone)
		return .Copies if hook == nil || !param_mode_is_pointer(symbol_param_mode(c, hook, 0)) else .Unwritten
	}
	return .Unwritten
}

// What an argument is to its call, which decides what it lends (`prov_call_argument`).
Prov_Argument_Kind :: enum u8 {
	// A bound slot no argument was written for.
	Absent,
	// A variadic pack built from separate arguments.
	Pack,
	Moved_Receiver,
	// A call whose result is `inout`, passed on `inout`.
	Inout_Result,
	Inout_Receiver,
	// The receiver of a call returning a view of a map (`Returns_View`).
	View_Receiver,
	// An `inout` argument naming a root's place, or one reached through carriers.
	Inout_Place,
	Inout_Through,
	// The receiver of a map's `lookup_value`.
	Lookup_Receiver,
	// A slice local of plain data given to what only reads its receiver.
	Only_Read_Slice,
	// A value borrowed from the caller by what only copies it (`Copies`).
	Copied_Receiver,
	// A value borrowed from the caller.
	Borrowed,
	// A carrier place given to a parameter that can write through nothing it
	// receives (`prov_argument_only_read`).
	Read_Only,
	// Anything else, walked as a value.
	Value,
}

// The first kind that applies, in this order: a receiver's declared mode decides
// before its parameter's, and an `inout` argument that is neither a place nor reached
// through carriers goes on as any other does.
@(private)
prov_argument_kind :: proc(graph: ^Flow_Graph, v: ^Expr_Call, index: int, input: Prov_Call_Input) -> Prov_Argument_Kind {
	c := graph.k.c
	if call_packs(v, index) {
		return .Pack
	}
	argument := v.bound[index]
	if argument == nil {
		return .Absent
	}
	inout := index < len(input.arguments) && input.arguments[index].mode == .Inout
	if index == 0 && input.receiver == .Move {
		return .Moved_Receiver
	}
	if inout && prov_names_inout_result(graph, argument) {
		return .Inout_Result
	}
	if index == 0 && input.receiver == .Inout {
		return .Inout_Receiver
	}
	if index == 0 && .Returns_View in CONTAINER_OP_EFFECTS[input.container] {
		return .View_Receiver
	}
	if inout {
		if _, _, place := prov_place_of(graph, argument); place {
			return .Inout_Place
		}
		if len(prov_place_hops(graph, argument)) > 0 {
			return .Inout_Through
		}
	}
	if index == 0 && input.container == .Map_Lookup_Value {
		return .Lookup_Receiver
	}
	if prov_argument_borrows_caller(graph, v, index, input.receiver, input.has_receiver) {
		#partial switch prov_receiver_contract(c, symbol_of(c, v.resolution.chosen_overload)) {
		case .Only_Reads:
			if _, plain := prov_plain_slice_local(graph, argument); plain {
				return .Only_Read_Slice
			}
		case .Copies:
			return .Copied_Receiver
		}
		return .Borrowed
	}
	if !(index == 0 && input.has_receiver) && prov_argument_only_read(graph, argument, prov_parameter_type(graph, v, index)) {
		return .Read_Only
	}
	return .Value
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
	if call_through_value(c, call) { input.callee = prov_input_value(graph, call.callee) }
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
	if .Lends_Receiver in CONTAINER_OP_EFFECTS[input.container] && len(call.bound) > 0 && call.bound[0] != nil {
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

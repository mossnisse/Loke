// Source syntax is interpreted here once. Target and region consumers use
// these checked transfers and explicit paths, never payload-depth guesses.
package lokec

import "core:slice"

Prov_Component :: struct {
	source: Value_Id,
	from, to: []Proj_Step,
	copy_from: []Proj_Step,
	copy_type: Type_Id, // what a clone copies; INVALID_TYPE when the source is read or moved
	allocator: Value_Id, // zero selects the default allocator
}

Prov_Backing :: struct { path: []Proj_Step, allocator: Value_Id }
// What a value takes from its operands: one forwarded, either of a choice, or
// the parts of an aggregate, with any allocation it makes.
Prov_Transfer_Parts :: struct { components: []Prov_Component, backing: []Prov_Backing }
// A named owner's storage holds its carriers; any other owner's, including one
// reached through a pointer, move into the hidden storage the view borrows.
Prov_Transfer_Borrow :: struct { storage: Storage_Id, path: []Proj_Step, owner: Value_Id, materialized: bool }
Prov_Transfer_Address :: struct { source: Value_Id, storage: bool }
Prov_Transfer :: union {
	Prov_Transfer_Parts,
	Prov_Transfer_Borrow,
	Prov_Transfer_Address,
}

@(private = "file")
prov_component :: proc(graph: ^Flow_Graph, source: Value_Id, from: []Proj_Step = nil, to: []Proj_Step = nil,
                       copy_type := INVALID_TYPE, allocator: Expr = nil) -> Prov_Component {
	component := Prov_Component{source = source, from = slice.clone(from, graph.alloc), to = slice.clone(to, graph.alloc),
	                           copy_type = copy_type}
	component.copy_from = component.from
	if allocator != nil { component.allocator = prov_operand_value(graph, allocator) }
	return component
}

@(private = "file")
prov_parts :: proc(graph: ^Flow_Graph, components: ..Prov_Component) -> Prov_Transfer {
	return Prov_Transfer_Parts{components = slice.clone(components, graph.alloc)}
}

// The step to a fallible type's success payload; nil for any other type.
@(private = "file")
prov_success_path :: proc(graph: ^Flow_Graph, type: Type_Id) -> []Proj_Step {
	shape, ok := fallible_of(graph.k.c, type)
	return ok ? prov_extend(graph, nil, proj_field(shape.success)) : nil
}

// design.md "Allocator regions and region provenance", "Widening by label".
prov_value_transfer :: proc(graph: ^Flow_Graph, id: Value_Id) -> Prov_Transfer {
	if id == 0 { return nil }
	entry := &graph.input.values[int(id)]
	// A value that is no transfer is also described only once.
	if entry.described { return entry.transfer }
	// What describing it interns is read where it was, in its expansion.
	expansion, reading := graph.expansion, graph.overwrites.reading
	graph.expansion, graph.overwrites.reading = entry.expansion, entry.read_at
	transfer := prov_describe_transfer(graph, id)
	graph.expansion, graph.overwrites.reading = expansion, reading
	prov_writable_input(graph)
	entry = &graph.input.values[int(id)]
	entry.transfer, entry.described = transfer, true
	return transfer
}

// Operands are read at their checked representation; only `id`'s own
// conversions select a value beneath it.
@(private = "file")
prov_describe_transfer :: proc(graph: ^Flow_Graph, id: Value_Id) -> Prov_Transfer {
	c := graph.k.c
	value := prov_value(graph, id)
	e := value.origin
	// The zero allocator denotes the default provider; its literal fields do
	// not describe an aggregate with no region dependencies.
	if is_const_expr(e) && type_is_allocator(c, value.type) { return nil }
	// A plain identifier names its storage; no transfer describes it.
	if _, named := value.form.(Prov_Form_Symbol); named && value.view_from == INVALID_TYPE && value.widened_from == INVALID_TYPE { return nil }
	if owner := value.view_from; owner != INVALID_TYPE {
		source := prov_value_beneath(graph, id, .View)
		place := prov_value(graph, source).place
		storage, direct := place.base.(Storage_Id)
		path := direct ? place.path : nil
		if !direct { storage = prov_storage_id(graph, Written_Storage{temporary = expr_base(e), type = owner}) }
		if type_is_box(c, owner) { path = prov_extend(graph, path, proj_wild()) }
		return Prov_Transfer_Borrow{storage, path, source, !direct}
	}
	if from := value.widened_from; union_widens_to(c, from, value.type) {
		return prov_widening_transfer(graph, prov_value_beneath(graph, id, .Widening), from, value.type)
	}
	#partial switch v in e {
	case ^Expr_Move:
		return prov_parts(graph, prov_component(graph, prov_operand_value(graph, v.value)))
	case ^Expr_Cond:
		return prov_parts(graph, prov_component(graph, prov_operand_value(graph, v.then)), prov_component(graph, prov_operand_value(graph, v.otherwise)))
	case ^Expr_Or_Else:
		parts := make([dynamic]Prov_Component, graph.alloc)
		if success := prov_success_path(graph, expr_base(v.value).type); success != nil {
			append(&parts, prov_component(graph, prov_operand_value(graph, v.value), success))
		}
		if v.fallback != nil { append(&parts, prov_component(graph, prov_operand_value(graph, v.fallback))) }
		return Prov_Transfer_Parts{components = parts[:]}
	case ^Expr_Postfix:
		if v.op == .Or_Return {
			return prov_parts(graph, prov_component(graph, prov_operand_value(graph, v.operand), prov_success_path(graph, expr_base(v.operand).type)))
		}
	case ^Expr_Unary:
		if v.op == .Amp { return Prov_Transfer_Address{prov_operand_value(graph, v.operand), true} }
	case ^Expr_Slice:
		if v.resolution.kind != .User_Operator {
			return Prov_Transfer_Address{prov_operand_value(graph, v.operand), !type_is_carrier(c, expr_base(v.operand).type)}
		}
	case ^Expr_Composite:
		return prov_composite_transfer(graph, id, v)
	case ^Expr_Call:
		return prov_call_transfer(graph, v, value.type)
	}
	return nil
}

// Each payload moves under the destination's tag for its label. A clone copies
// the whole source before that remapping.
@(private = "file")
prov_widening_transfer :: proc(graph: ^Flow_Graph, source: Value_Id, from, to: Type_Id, clones := false, allocator: Expr = nil) -> Prov_Transfer {
	c := graph.k.c
	parts := make([dynamic]Prov_Component, graph.alloc)
	for payload, index in type_of(c, from).variants {
		if payload == TYPE_VOID { continue }
		part := prov_component(graph, source, {proj_field(index)}, {proj_field(widened_variant(c, from, to, index))}, allocator = allocator)
		if clones { part.copy_type, part.copy_from = from, nil }
		append(&parts, part)
	}
	return Prov_Transfer_Parts{components = parts[:]}
}

@(private = "file")
prov_composite_transfer :: proc(graph: ^Flow_Graph, id: Value_Id, v: ^Expr_Composite) -> Prov_Transfer {
	value := prov_value(graph, id)
	if backing := value.backing; backing != INVALID_TYPE {
		storage := prov_storage_id(graph, Written_Storage{temporary = &v.base, type = backing}, .Slice_Literal)
		return Prov_Transfer_Borrow{storage = storage, owner = prov_value_beneath(graph, id, .Backing), materialized = true}
	}
	parts := make([dynamic]Prov_Component, graph.alloc)
	kind := underlying_kind(graph.k.c, value.type)
	for element, index in v.elements {
		if kind == .Map && element.key != nil {
			entry := prov_map_entry_step(graph, value.type, element.key)
			append(&parts, prov_component(graph, prov_operand_value(graph, element.key), nil, {entry, proj_field(PROJ_MAP_KEY)}))
		}
		if element.value == nil { continue }
		path, known := prov_element_prefix(graph, v, value.type, index)
		if !known { continue }
		clones := index < len(v.element_clones) && v.element_clones[index]
		append(&parts, prov_component(graph, prov_operand_value(graph, element.value), nil, path,
		                              copy_type = clones ? prov_element_type(graph, v, value.type, index) : INVALID_TYPE))
	}
	return Prov_Transfer_Parts{components = parts[:]}
}

@(private = "file")
prov_call_transfer :: proc(graph: ^Flow_Graph, v: ^Expr_Call, type: Type_Id) -> Prov_Transfer {
	c := graph.k.c
	if v.dispatch != nil {
		parts := make([dynamic]Prov_Component, graph.alloc)
		for arm in v.dispatch.cases { append(&parts, prov_component(graph, prov_operand_value(graph, arm.arm))) }
		return Prov_Transfer_Parts{components = parts[:]}
	}
	if len(v.bound) == 0 || v.bound[0] == nil {
		// make's optional counts can be absent; its allocator is the final
		// slot. A payloadless variant constructs a value with no dependencies.
		if _, variant := v.operation.(Call_Union_Construct); variant { return Prov_Transfer_Parts{} }
		if _, allocation := v.operation.(Call_Allocation); !allocation { return nil }
	}
	builtin := symbol_of(c, v.resolution.symbol)
	// design.md "Exchange": the destination's previous value is moved out,
	// keeping its regions and targets.
	if builtin != nil && builtin.builtin == .Exchange && len(v.bound) == 2 {
		return prov_parts(graph, prov_component(graph, prov_operand_value(graph, v.bound[0])))
	}
	// design.md "Uninitialized capacity": a taken value is the one the place held,
	// so it keeps that value's regions too.
	if builtin != nil && builtin.builtin == .Unsafe_Take && len(v.bound) == 1 {
		return prov_parts(graph, prov_component(graph, prov_operand_value(graph, v.bound[0])))
	}
	allocator := len(v.bound) > 1 ? v.bound[1] : nil
	#partial switch operation in v.operation {
	case Call_Box_Unbox:
		return prov_parts(graph, prov_component(graph, prov_operand_value(graph, v.bound[0]), {proj_wild()}))
	case Call_Union_As:
		payload := union_variant_payload(c, expr_base(v.bound[0]).type, operation.index)
		return prov_parts(graph, prov_component(graph, prov_operand_value(graph, v.bound[0]), {proj_field(operation.index)}, prov_success_path(graph, type),
		                  copy_type = payload, allocator = allocator))
	case Call_Union_Construct:
		copy_type := operation.clone ? union_variant_payload(c, type, operation.index) : INVALID_TYPE
		return prov_parts(graph, prov_component(graph, prov_operand_value(graph, v.bound[0]), nil, {proj_field(operation.index)},
		                  copy_type = copy_type, allocator = allocator))
	case Call_Allocation:
		prefix := operation.fallible ? prov_success_path(graph, type) : nil
		parts: []Prov_Component
		if builtin != nil && (builtin.builtin == .Box_New || builtin.builtin == .Try_Box) {
			copies := expression_is_borrowed_place(v.bound[0])
			parts = slice.clone([]Prov_Component{prov_component(graph, prov_operand_value(graph, v.bound[0]), nil, prov_extend(graph, prefix, proj_wild()),
			                    copy_type = copies ? operation.type : INVALID_TYPE, allocator = allocator)}, graph.alloc)
		} else if builtin != nil && (builtin.builtin == .Make || builtin.builtin == .Try_Make) {
			allocator = v.bound[len(v.bound) - 1]
		}
		backing := Prov_Backing{path = prefix}
		if allocator != nil { backing.allocator = prov_operand_value(graph, allocator) }
		return Prov_Transfer_Parts{parts, slice.clone([]Prov_Backing{backing}, graph.alloc)}
	case Call_Conversion:
		from := expr_base(v.bound[0]).type
		if union_widens_to(c, from, type) {
			return prov_widening_transfer(graph, prov_operand_value(graph, v.bound[0]), from, type, operation.clones, allocator)
		}
	}
	if contract := symbol_of(c, call_contract_declaration(c, v)); contract != nil && (contract.synth == .Clone || contract.synth == .Try_Clone) {
		prefix := contract.synth == .Try_Clone ? prov_success_path(graph, type) : nil
		return prov_parts(graph, prov_component(graph, prov_operand_value(graph, v.bound[0]), nil, prefix, copy_type = contract.owner_type,
		                  allocator = allocator))
	}
	return nil
}

// A checked store may clone one destructured field or clone before widening.
// Keep that copy root separate from the final selected source path.
prov_input_stored_copy :: proc(graph: ^Flow_Graph, id: Value_Id, path, copy_from: []Proj_Step) -> Prov_Component {
	c := graph.k.c
	value := prov_value(graph, id)
	source, type, selected := id, value.type, path
	if len(copy_from) == 0 && union_widens_to(c, value.widened_from, type) {
		expansion := graph.expansion
		defer graph.expansion = expansion
		graph.expansion = value.expansion
		source, type = prov_value_beneath(graph, id, .Widening), value.widened_from
		mapped, possible := prov_widened_region_path(graph, type, value.type, path)
		if !possible { return Prov_Component{} }
		selected = mapped
	}
	return Prov_Component{source = source, from = selected, copy_from = copy_from, copy_type = prov_type_at(c, type, copy_from)}
}

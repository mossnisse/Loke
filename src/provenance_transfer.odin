// Source syntax is interpreted here once. Target and region consumers use
// these checked transfers and explicit paths, never payload-depth guesses.
package lokec

import "core:mem"
import "core:slice"

Prov_Transfer_Mode :: enum { Read, Copy, Clone, Move }

Prov_Copy_Operation :: struct {
	type: Type_Id,
	hook: Symbol_Id,
}

Prov_Component :: struct {
	source: Value_Id,
	from, to: []Proj_Step,
	copy_from: []Proj_Step,
	type: Type_Id,
	mode: Prov_Transfer_Mode,
	copy: Prov_Copy_Operation,
	allocator: Value_Id, // zero selects the default allocator
	// The existing bounded target analysis cannot prove a copied payload has
	// only its source's targets. This is a transfer policy, not an alias set.
	uncertain_copy: bool,
}

Prov_Backing :: struct { path: []Proj_Step, allocator: Value_Id }
Prov_Transfer_Forward :: struct { component: Prov_Component }
Prov_Transfer_Join :: struct { alternatives: []Prov_Component }
Prov_Transfer_Aggregate :: struct { components: []Prov_Component, backing: []Prov_Backing }
// A materialized owner's carriers move into the hidden storage the view borrows;
// a named owner's place already holds them.
Prov_Transfer_Borrow :: struct { storage: Storage_Id, path: []Proj_Step, owner: Value_Id, materialized: bool }
Prov_Transfer_Address :: struct { source: Value_Id, storage: bool }
Prov_Transfer :: union {
	Prov_Transfer_Forward,
	Prov_Transfer_Join,
	Prov_Transfer_Aggregate,
	Prov_Transfer_Borrow,
	Prov_Transfer_Address,
}

prov_input_copy_operation :: proc(graph: ^Flow_Graph, type: Type_Id) -> Prov_Copy_Operation {
	if operation, found := graph.input.copy_operations[type]; found { return operation }
	prov_writable_input(graph)
	operation := Prov_Copy_Operation{type = type, hook = lifecycle_of(graph.k.c, type).custom_try_clone}
	graph.input.copy_operations[type] = operation
	return operation
}

@(private = "file")
prov_component :: proc(graph: ^Flow_Graph, source: Value_Id, from: []Proj_Step = nil, to: []Proj_Step = nil,
                       mode := Prov_Transfer_Mode.Read, type := INVALID_TYPE, allocator: Expr = nil,
                       uncertain_copy := false) -> Prov_Component {
	component := Prov_Component{source = source, from = slice.clone(from, graph.alloc), to = slice.clone(to, graph.alloc),
	                           mode = mode, type = type == INVALID_TYPE ? prov_type_at(graph.k.c, prov_value(graph, source).type, from) : type,
	                           uncertain_copy = uncertain_copy}
	component.copy_from = component.from
	if mode == .Clone || mode == .Copy { component.copy = prov_input_copy_operation(graph, component.type) }
	if allocator != nil { component.allocator = prov_input_value(graph, allocator) }
	// Normalize children now. In particular a hidden array's owner is distinct
	// from its slice value.
	_ = prov_value_transfer(graph, source)
	return component
}

@(private = "file")
prov_transfer_allocator :: proc(call: ^Expr_Call, index := 1) -> Expr {
	return index >= 0 && index < len(call.bound) ? call.bound[index] : nil
}

// design.md "Allocator regions and region provenance", "Widening by label".
prov_value_transfer :: proc(graph: ^Flow_Graph, id: Value_Id) -> Prov_Transfer {
	if id == 0 { return nil }
	value := prov_value(graph, id)
	// The zero allocator denotes the default provider; its literal fields do
	// not describe an aggregate with no region dependencies.
	if expr_base(value.origin).is_const && type_underlying(graph.k.c, value.type) == TYPE_ALLOCATOR { return nil }
	// A plain identifier names its storage; no transfer describes it.
	if _, named := value.form.(Prov_Form_Symbol); named && value.view_from == INVALID_TYPE && value.widened_from == INVALID_TYPE { return nil }
	// A nil entry records that the value is no transfer, so it is described once.
	if transfer, found := graph.input.transfers[id]; found { return transfer }
	transfer := prov_describe_transfer(graph, id)
	prov_writable_input(graph)
	graph.input.transfers[id] = transfer
	return transfer
}

// Operands are read at their checked representation; only `id`'s own
// conversions select a value beneath it.
@(private = "file")
prov_describe_transfer :: proc(graph: ^Flow_Graph, id: Value_Id) -> Prov_Transfer {
	c := graph.k.c
	value := prov_value(graph, id)
	e := value.origin
	if owner := value.view_from; owner != INVALID_TYPE {
		source := prov_value_beneath(graph, id, .View)
		place := prov_value(graph, source).place
		storage, direct := place.base.(Storage_Id)
		if !direct { storage = prov_storage_id(graph, Written_Storage{temporary = expr_base(e), type = owner}) }
		path := place.path
		if type_is_box(c, owner) { path = prov_extend(graph, path, proj_wild()) }
		_ = prov_value_transfer(graph, source)
		return Prov_Transfer_Borrow{storage, path, source, !direct}
	}
	if from := value.widened_from; union_widens_to(c, from, value.type) {
		to := value.type
		source := prov_value_beneath(graph, id, .Widening)
		components := make([dynamic]Prov_Component, graph.alloc)
		for payload, index in type_of(c, from).variants {
			if payload == TYPE_VOID { continue }
			append(&components, prov_component(graph, source, {proj_field(index)}, {proj_field(widened_variant(c, from, to, index))}, type = payload))
		}
		return Prov_Transfer_Aggregate{components = components[:]}
	}
	#partial switch v in e {
	case ^Expr_Move:
		return Prov_Transfer_Forward{prov_component(graph, prov_input_value(graph, v.value), mode = .Move)}
	case ^Expr_Cond:
		return Prov_Transfer_Join{slice.clone([]Prov_Component{
			prov_component(graph, prov_input_value(graph, v.then)), prov_component(graph, prov_input_value(graph, v.otherwise)),
		}, graph.alloc)}
	case ^Expr_Or_Else:
		parts := make([dynamic]Prov_Component, graph.alloc)
		if shape, ok := fallible_of(graph.k, expr_base(v.value).type); ok {
			append(&parts, prov_component(graph, prov_input_value(graph, v.value), {proj_field(shape.success)}))
		}
		if v.fallback != nil { append(&parts, prov_component(graph, prov_input_value(graph, v.fallback))) }
		return Prov_Transfer_Join{parts[:]}
	case ^Expr_Postfix:
		if v.op == .Or_Return {
			path: []Proj_Step
			if shape, ok := fallible_of(graph.k, expr_base(v.operand).type); ok { path = prov_extend(graph, nil, proj_field(shape.success)) }
			return Prov_Transfer_Forward{prov_component(graph, prov_input_value(graph, v.operand), path)}
		}
	case ^Expr_Unary:
		if v.op == .Amp { return Prov_Transfer_Address{prov_input_value(graph, v.operand), true} }
	case ^Expr_Slice:
		if v.resolution.kind != .User_Operator {
			return Prov_Transfer_Address{prov_input_value(graph, v.operand), !type_is_carrier(c, expr_base(v.operand).type)}
		}
	case ^Expr_Composite:
		if backing := value.backing; backing != INVALID_TYPE {
			storage := prov_storage_id(graph, Written_Storage{temporary = &v.base, type = backing}, .Slice_Literal)
			owner := prov_value_beneath(graph, id, .Backing)
			_ = prov_value_transfer(graph, owner)
			return Prov_Transfer_Borrow{storage = storage, owner = owner, materialized = true}
		}
		parts := make([dynamic]Prov_Component, graph.alloc)
		kind := underlying_kind(c, value.type)
		for element, index in v.elements {
			if kind == .Map && element.key != nil {
				entry := prov_map_entry_step(graph, value.type, element.key)
				append(&parts, prov_component(graph, prov_input_value(graph, element.key), nil, {entry, proj_field(PROJ_MAP_KEY)}))
			}
			if element.value == nil { continue }
			path, known := prov_element_prefix(graph, v, value.type, index)
			if kind == .Dynamic_Array { path, known = prov_extend(graph, nil, proj_wild()), true }
			if !known { continue }
			mode := Prov_Transfer_Mode.Read
			if index < len(v.element_clones) && v.element_clones[index] { mode = .Clone }
			append(&parts, prov_component(graph, prov_input_value(graph, element.value), nil, path, mode = mode,
			                              type = prov_element_type(graph, v, value.type, index)))
		}
		return Prov_Transfer_Aggregate{components = parts[:]}
	case ^Expr_Call:
		if v.dispatch != nil {
			parts := make([dynamic]Prov_Component, graph.alloc)
			for arm in v.dispatch.cases { append(&parts, prov_component(graph, prov_input_value(graph, arm.arm))) }
			return Prov_Transfer_Join{parts[:]}
		}
		if len(v.bound) == 0 || v.bound[0] == nil {
			// make's optional counts can be absent; its allocator is the final
			// slot. A payloadless variant constructs a value with no dependencies.
			if _, variant := v.operation.(Call_Union_Construct); variant { return Prov_Transfer_Aggregate{} }
			if _, allocation := v.operation.(Call_Allocation); !allocation { return nil }
		}
		allocator := prov_transfer_allocator(v)
		#partial switch operation in v.operation {
		case Call_Box_Unbox:
			return Prov_Transfer_Forward{prov_component(graph, prov_input_value(graph, v.bound[0]), {proj_wild()}, mode = .Move, type = value.type)}
		case Call_Union_As:
			shape, _ := fallible_of(graph.k, value.type)
			payload := union_variant_payload(c, expr_base(v.bound[0]).type, operation.index)
			return Prov_Transfer_Forward{prov_component(graph, prov_input_value(graph, v.bound[0]), {proj_field(operation.index)}, {proj_field(shape.success)},
			                            mode = .Clone, type = payload, allocator = allocator, uncertain_copy = true)}
		case Call_Union_Construct:
			mode := Prov_Transfer_Mode.Read
			if operation.clone { mode = .Clone }
			payload := union_variant_payload(c, value.type, operation.index)
			return Prov_Transfer_Forward{prov_component(graph, prov_input_value(graph, v.bound[0]), nil, {proj_field(operation.index)},
			                            mode = mode, type = payload, allocator = allocator, uncertain_copy = operation.clone)}
		case Call_Allocation:
			prefix: []Proj_Step
			if operation.fallible {
				shape, _ := fallible_of(graph.k, value.type)
				prefix = prov_extend(graph, nil, proj_field(shape.success))
			}
			backing := Prov_Backing{path = prefix}
			parts: []Prov_Component
			if sym := symbol_of(c, v.resolution.symbol); sym != nil && (sym.builtin == .Box_New || sym.builtin == .Try_Box) {
				mode := Prov_Transfer_Mode.Move
				copies := expression_is_borrowed_place(v.bound[0])
				if copies { mode = .Clone }
				parts = slice.clone([]Prov_Component{prov_component(graph, prov_input_value(graph, v.bound[0]), nil, prov_extend(graph, prefix, proj_wild()),
				                    mode = mode, type = operation.type, allocator = allocator, uncertain_copy = copies)}, graph.alloc)
			} else { allocator = prov_transfer_allocator(v, len(v.bound) - 1) }
			if allocator != nil { backing.allocator = prov_input_value(graph, allocator) }
			return Prov_Transfer_Aggregate{parts, slice.clone([]Prov_Backing{backing}, graph.alloc)}
		case Call_Conversion:
			from := expr_base(v.bound[0]).type
			if union_widens_to(c, from, value.type) {
				parts := make([dynamic]Prov_Component, graph.alloc)
				mode := Prov_Transfer_Mode.Read
				if operation.clones { mode = .Clone }
				for payload, index in type_of(c, from).variants {
					if payload == TYPE_VOID { continue }
					part := prov_component(graph, prov_input_value(graph, v.bound[0]), {proj_field(index)}, {proj_field(widened_variant(c, from, value.type, index))},
					                       mode = mode, type = payload, allocator = allocator)
					if operation.clones { part.copy, part.copy_from = prov_input_copy_operation(graph, from), nil }
					append(&parts, part)
				}
				return Prov_Transfer_Aggregate{components = parts[:]}
			}
		}
		if sym := symbol_of(c, call_contract_declaration(c, v)); sym != nil && (sym.synth == .Clone || sym.synth == .Try_Clone) {
			prefix: []Proj_Step
			if sym.synth == .Try_Clone {
				shape, _ := fallible_of(graph.k, value.type)
				prefix = prov_extend(graph, nil, proj_field(shape.success))
			}
			return Prov_Transfer_Forward{prov_component(graph, prov_input_value(graph, v.bound[0]), nil, prefix, mode = .Clone, type = sym.owner_type,
			                            allocator = allocator, uncertain_copy = true)}
		}
	}
	return nil
}

// A checked store may clone one destructured field or clone before widening.
// Keep that copy root separate from the final selected source path.
prov_input_stored_copy :: proc(graph: ^Flow_Graph, id: Value_Id, path, copy_from: []Proj_Step,
                               as_type: Type_Id) -> Prov_Component {
	value := prov_value(graph, id)
	type := as_type == INVALID_TYPE ? value.type : as_type
	source := id
	selected := path
	if len(copy_from) == 0 && union_widens_to(graph.k.c, value.widened_from, type) {
		transfer := prov_value_transfer(graph, id).(Prov_Transfer_Aggregate)
		if len(transfer.components) > 0 {
			source = transfer.components[0].source
			type = prov_value(graph, source).type
			if len(path) > 0 && path[0].kind == .Field {
				possible := false
				for component in transfer.components {
					if paths_overlap(component.to, path[:1]) {
						selected, possible = prov_concat_path(graph, component.from, path[1:]), true
						break
					}
				}
				if !possible { return Prov_Component{} }
			}
		}
	}
	return Prov_Component{source = source, from = selected, copy_from = copy_from, mode = .Clone,
	                      type = prov_type_at(graph.k.c, type, selected),
	                      copy = prov_input_copy_operation(graph, prov_type_at(graph.k.c, type, copy_from))}
}

prov_clone_transfer :: proc(source: Prov_Transfer, allocator: mem.Allocator) -> Prov_Transfer {
	clone_component :: proc(source: Prov_Component, allocator: mem.Allocator) -> Prov_Component {
		out := source
		out.from, out.to = slice.clone(source.from, allocator), slice.clone(source.to, allocator)
		out.copy_from = slice.clone(source.copy_from, allocator)
		return out
	}
	switch transfer in source {
	case Prov_Transfer_Forward:
		return Prov_Transfer_Forward{clone_component(transfer.component, allocator)}
	case Prov_Transfer_Join:
		out := slice.clone(transfer.alternatives, allocator)
		for &component in out { component = clone_component(component, allocator) }
		return Prov_Transfer_Join{out}
	case Prov_Transfer_Aggregate:
		parts := slice.clone(transfer.components, allocator)
		for &component in parts { component = clone_component(component, allocator) }
		backing := slice.clone(transfer.backing, allocator)
		for &allocation in backing { allocation.path = slice.clone(allocation.path, allocator) }
		return Prov_Transfer_Aggregate{parts, backing}
	case Prov_Transfer_Borrow:
		out := transfer
		out.path = slice.clone(transfer.path, allocator)
		return out
	case Prov_Transfer_Address:
		return transfer
	case:
		return nil
	}
}

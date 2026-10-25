// Checked storage and place descriptions shared by provenance consumers.
// This boundary has no target sets, loans, or allocator-region facts.
package lokec

import "core:mem"
import "core:slice"
import "core:strings"

Storage_Id :: distinct int
Value_Id :: distinct int

// Zero IDs denote unresolved storage or an absent value. Numeric IDs belong
// to one concrete body's graph build; keys provide correspondence on rebuild.
Written_Storage :: struct {
	symbol: Symbol_Id,
	temporary: ^Expr_Base,
	type: Type_Id,
	expansion: Defer_Expansion,
}

Storage_Lifetime :: enum { Expression, Scope, Process, Thread, Caller }

Prov_Storage :: struct {
	key: Written_Storage,
	type: Type_Id,
	span: Span,
	kind: Root_Kind,
	lifetime: Storage_Lifetime,
}

// A direct place starts at storage; an indirect place starts at an evaluated
// carrier, never at the storage holding that carrier's descriptor.
Prov_Place :: struct {
	base: union {Storage_Id, Value_Id},
	path: []Proj_Step,
	type: Type_Id,
}

Prov_Value :: struct {
	origin: Expr,
	type: Type_Id,
	view_from, erased_from, widened_from: Type_Id,
	place: Prov_Place,
	// A captured value keeps its source binding but is not a later reload of it.
	captured_from: Value_Id,
}

Prov_Input_Key :: struct {
	node: ^Expr_Base,
	type, view_from, erased_from: Type_Id,
	widened_from: Type_Id,
	expansion: Defer_Expansion,
	capture: bool,
}

Prov_Input :: struct {
	storages: [dynamic]Prov_Storage,
	storage_ids: map[Written_Storage]Storage_Id,
	values: [dynamic]Prov_Value,
	value_ids: map[Prov_Input_Key]Value_Id,
	places: map[Prov_Input_Key]Prov_Place,
	transfers: map[Value_Id]Prov_Transfer,
	copy_operations: map[Type_Id]Prov_Copy_Operation,
	// Preserve the bounded constant-map-key assignment along with cached paths.
	map_key_entries: map[string]int,
}

// Metadata travels with the existing carried facts until stage 4 can build a
// complete immutable operation body before replay. Clone every owned slice:
// no input may point into a discarded pass or the disposable carry arena.
new_prov_input :: proc(allocator: mem.Allocator, seed: ^Prov_Input = nil) -> ^Prov_Input {
	input := new(Prov_Input, allocator)
	input.storages = make([dynamic]Prov_Storage, allocator)
	input.storage_ids = make(map[Written_Storage]Storage_Id, 8, allocator)
	input.values = make([dynamic]Prov_Value, allocator)
	input.value_ids = make(map[Prov_Input_Key]Value_Id, 8, allocator)
	input.places = make(map[Prov_Input_Key]Prov_Place, 8, allocator)
	input.transfers = make(map[Value_Id]Prov_Transfer, 8, allocator)
	input.copy_operations = make(map[Type_Id]Prov_Copy_Operation, 4, allocator)
	input.map_key_entries = make(map[string]int, 4, allocator)
	if seed == nil {
		append(&input.storages, Prov_Storage{})
		append(&input.values, Prov_Value{})
		return input
	}
	append(&input.storages, ..seed.storages[:])
	for key, id in seed.storage_ids { input.storage_ids[key] = id }
	append(&input.values, ..seed.values[:])
	for &value in input.values { value.place.path = slice.clone(value.place.path, allocator) }
	for key, id in seed.value_ids { input.value_ids[key] = id }
	for key, place in seed.places {
		owned := place
		owned.path = slice.clone(place.path, allocator)
		input.places[key] = owned
	}
	for id, transfer in seed.transfers { input.transfers[id] = prov_clone_transfer(transfer, allocator) }
	for type, operation in seed.copy_operations { input.copy_operations[type] = operation }
	for key, entry in seed.map_key_entries { input.map_key_entries[strings.clone(key, allocator)] = entry }
	return input
}

// design.md "Storage roots and borrow carriers", "Temporaries and procedure boundaries".
prov_storage_id :: proc(graph: ^Flow_Graph, source: Written_Storage) -> Storage_Id {
	key := source
	if key == (Written_Storage{}) { return 0 }
	if key.temporary != nil { key.expansion = graph.expansion }
	if id, found := graph.input.storage_ids[key]; found { return id }
	entry := Prov_Storage{key = key, type = key.type, kind = .Temporary, lifetime = .Expression}
	if key.temporary != nil {
		entry.span = key.temporary.span
	} else {
		sym := symbol_of(graph.k.c, key.symbol)
		if sym == nil { return 0 }
		entry.type, entry.span, entry.kind, entry.lifetime = sym.type, sym.span, .Local, .Scope
		#partial switch sym.kind {
		case .Var:
			if sym.duration == .Thread_Local { entry.kind, entry.lifetime = .Thread_Local, .Thread
			} else if symbol_outlives_bodies(sym) { entry.kind, entry.lifetime = .Static, .Process }
		case .Parameter:
			if param_mode_is_pointer(sym.mode) { entry.kind, entry.lifetime = .Param, .Caller }
		case .Const:
			entry.kind, entry.lifetime = .Materialized, .Process
		case:
			return 0
		}
	}
	id := Storage_Id(len(graph.input.storages))
	append(&graph.input.storages, entry)
	graph.input.storage_ids[key] = id
	return id
}

prov_storage :: proc(graph: ^Flow_Graph, id: Storage_Id) -> Prov_Storage {
	return graph.input.storages[int(id)]
}

@(private = "file")
prov_input_key :: proc(graph: ^Flow_Graph, e: Expr) -> Prov_Input_Key {
	base := expr_base(e)
	if base == nil { return {} }
	return Prov_Input_Key{node = base, type = base.type, view_from = base.view_from,
	                      erased_from = base.erased_from, widened_from = base.widened_from, expansion = graph.expansion}
}

prov_input_value :: proc(graph: ^Flow_Graph, e: Expr) -> Value_Id {
	key := prov_input_key(graph, e)
	if key.node == nil { return 0 }
	if id, found := graph.input.value_ids[key]; found { return id }
	id := Value_Id(len(graph.input.values))
	append(&graph.input.values, Prov_Value{origin = e, type = key.type, view_from = key.view_from,
	                                    erased_from = key.erased_from, widened_from = key.widened_from})
	graph.input.value_ids[key] = id
	place := prov_input_place(graph, e)
	graph.input.values[int(id)].place = place
	return id
}

prov_input_capture :: proc(graph: ^Flow_Graph, call: ^Expr_Call, source: Expr) -> Value_Id {
	key := prov_input_key(graph, call)
	key.capture = true
	if id, found := graph.input.value_ids[key]; found { return id }
	from := prov_input_value(graph, source)
	value := graph.input.values[int(from)]
	value.captured_from = from
	id := Value_Id(len(graph.input.values))
	append(&graph.input.values, value)
	graph.input.value_ids[key] = id
	return id
}

// This is the only syntax walk that classifies direct and indirect places.
// Evaluation, alias resolution, and cleanup registration stay with consumers.
prov_input_place :: proc(graph: ^Flow_Graph, e: Expr) -> Prov_Place {
	key := prov_input_key(graph, e)
	if key.node == nil { return {} }
	// Reset queries manufacture stack-local identifiers. Resolve those through
	// their symbols rather than caching the address of a reusable scratch node.
	if ident, named := e.(^Expr_Ident); named {
		id := prov_storage_id(graph, Written_Storage{symbol = ident.symbol})
		if id != 0 { return Prov_Place{base = id, type = key.type} }
		return Prov_Place{type = key.type}
	}
	if place, found := graph.input.places[key]; found { return place }
	place := prov_describe_place(graph, e)
	place.type = key.type
	if place.base != nil { graph.input.places[key] = place }
	return place
}

@(private = "file")
prov_describe_place :: proc(graph: ^Flow_Graph, e: Expr) -> Prov_Place {
	c := graph.k.c
	#partial switch v in e {
	case ^Expr_Selector:
		if v.resolution.kind != .Field || v.operand == nil { return {} }
		place: Prov_Place
		if type_is_pointer(c, expr_base(v.operand).type) {
			place.base = prov_input_value(graph, v.operand)
		} else {
			place = prov_input_place(graph, v.operand)
		}
		if place.base == nil { return {} }
		place.path = prov_extend(graph, place.path, prov_field_step(graph, v))
		return place
	case ^Expr_Postfix:
		if v.op != .Caret { return {} }
		if !type_is_box(c, expr_base(v.operand).type) {
			return Prov_Place{base = prov_input_value(graph, v.operand)}
		}
		place := prov_input_place(graph, v.operand)
		if place.base == nil { return {} }
		place.path = prov_extend(graph, place.path, proj_wild())
		return place
	case ^Expr_Index:
		if len(v.bound) > 0 || v.operand == nil { return {} }
		#partial switch underlying_kind(c, expr_base(v.operand).type) {
		case .Array, .Dynamic_Array, .Map:
			place := prov_input_place(graph, v.operand)
			if place.base == nil { return {} }
			place.path = prov_concat_path(graph, place.path, prov_index_path(graph, v))
			return place
		}
		return Prov_Place{base = prov_input_value(graph, v.operand), path = prov_extend(graph, nil, proj_wild())}
	}
	return {}
}

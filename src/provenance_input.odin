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

Prov_Storage :: struct {
	key: Written_Storage,
	type: Type_Id,
	span: Span,
	kind: Root_Kind,
}

// A direct place starts at storage; an indirect place starts at an evaluated
// carrier, never at the storage holding that carrier's descriptor.
Prov_Place :: struct {
	base: union {Storage_Id, Value_Id},
	path: []Proj_Step,
	type: Type_Id,
}

// The representation an expression's value has: its checked one, or the
// source beneath one of its implicit conversions (`prov_value_beneath`).
Prov_Repr :: struct {
	type, view_from, erased_from, widened_from: Type_Id,
	// A slice literal's hidden array (design.md "Slice literals").
	backing: Type_Id,
}

// Queries read a value's representation from here, never from its origin node,
// which keeps its checked one.
Prov_Value :: struct {
	origin: Expr,
	using repr: Prov_Repr,
	expansion: Defer_Expansion,
	// A captured value copies its source's place but is not a later reload of it.
	place: Prov_Place,
	form: Prov_Form,
	// Its storage ends with its statement (`prov_expr_is_temporary`).
	temporary: bool,
	// A read through it may find targets no write named
	// (`prov_alias_source_is_unknown`).
	unknown_alias: bool,
}

Prov_Input_Key :: struct {
	node: ^Expr_Base,
	repr: Prov_Repr,
	expansion: Defer_Expansion,
	capture: bool,
}

// The implicit conversions a checked node can carry (design.md "string type
// conversions", "any_view type", "Widening by label", "Slice literals").
Prov_Conversion :: enum { View, Erasure, Widening, Backing }

Prov_Input :: struct {
	// Owns every table and inserted key; writes go through prov_writable_input.
	alloc: mem.Allocator,
	frozen: bool,
	storages: [dynamic]Prov_Storage,
	storage_ids: map[Written_Storage]Storage_Id,
	values: [dynamic]Prov_Value,
	value_ids: map[Prov_Input_Key]Value_Id,
	places: map[Prov_Input_Key]Prov_Place,
	transfers: map[Value_Id]Prov_Transfer,
	copy_operations: map[Type_Id]Prov_Copy_Operation,
	calls: map[Prov_Input_Key]Prov_Call_Input,
	synthetic_calls: map[Prov_Synthetic_Call_Key]^Expr_Call,
	// Preserve the bounded constant-map-key assignment along with cached paths.
	map_key_entries: map[string]int,
}

// Replay and event materialization have a fixed vocabulary: every input they
// read was recorded while the construction walk ran. A query of the finished
// graph may still add one; it gets a private copy on the first such addition.
prov_writable_input :: proc(graph: ^Flow_Graph) {
	if !graph.input.frozen { return }
	assert(!graph.replaying_facts, "fact replay discovered input absent from normalization")
	graph.input = new_prov_input(graph.alloc, graph.input)
}

// Fact replay and materialization share one frozen body input; a finished
// graph's query copies it before adding to it (`prov_writable_input`). The copy
// owns its slices, so its additions leave the frozen input as it was.
new_prov_input :: proc(allocator: mem.Allocator, seed: ^Prov_Input = nil) -> ^Prov_Input {
	input := new(Prov_Input, allocator)
	input.alloc = allocator
	input.storages = make([dynamic]Prov_Storage, allocator)
	input.storage_ids = make(map[Written_Storage]Storage_Id, 8, allocator)
	input.values = make([dynamic]Prov_Value, allocator)
	input.value_ids = make(map[Prov_Input_Key]Value_Id, 8, allocator)
	input.places = make(map[Prov_Input_Key]Prov_Place, 8, allocator)
	input.transfers = make(map[Value_Id]Prov_Transfer, 8, allocator)
	input.copy_operations = make(map[Type_Id]Prov_Copy_Operation, 4, allocator)
	input.calls = make(map[Prov_Input_Key]Prov_Call_Input, 4, allocator)
	input.synthetic_calls = make(map[Prov_Synthetic_Call_Key]^Expr_Call, 2, allocator)
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
	for key, input_call in seed.calls { input.calls[key] = prov_clone_call_input(input_call, allocator) }
	for key, call in seed.synthetic_calls { input.synthetic_calls[key] = call }
	for key, entry in seed.map_key_entries { input.map_key_entries[strings.clone(key, allocator)] = entry }
	return input
}

// design.md "Storage roots and borrow carriers", "Temporaries and procedure boundaries".
// `kind` classifies newly created anonymous storage; symbols carry their own.
prov_storage_id :: proc(graph: ^Flow_Graph, source: Written_Storage, kind := Root_Kind.Temporary) -> Storage_Id {
	key := source
	if key == (Written_Storage{}) { return 0 }
	if key.temporary != nil { key.expansion = graph.expansion }
	if id, found := graph.input.storage_ids[key]; found { return id }
	entry := Prov_Storage{key = key, type = key.type, kind = kind}
	if key.temporary != nil {
		entry.span = key.temporary.span
	} else {
		sym := symbol_of(graph.k.c, key.symbol)
		if sym == nil { return 0 }
		entry.type, entry.span, entry.kind = sym.type, sym.span, .Local
		#partial switch sym.kind {
		case .Var:
			if sym.duration == .Thread_Local { entry.kind = .Thread_Local
			} else if symbol_outlives_bodies(sym) { entry.kind = .Static }
		case .Parameter:
			if param_mode_is_pointer(sym.mode) { entry.kind = .Param }
		case .Const:
			entry.kind = .Materialized
		case:
			return 0
		}
	}
	prov_writable_input(graph)
	id := Storage_Id(len(graph.input.storages))
	append(&graph.input.storages, entry)
	graph.input.storage_ids[key] = id
	return id
}

prov_storage :: proc(graph: ^Flow_Graph, id: Storage_Id) -> Prov_Storage {
	return graph.input.storages[int(id)]
}

prov_value :: proc(graph: ^Flow_Graph, id: Value_Id) -> Prov_Value {
	return graph.input.values[int(id)]
}

prov_checked_repr :: proc(e: Expr) -> Prov_Repr {
	base := expr_base(e)
	if base == nil { return {} }
	repr := Prov_Repr{base.type, base.view_from, base.erased_from, base.widened_from, INVALID_TYPE}
	if literal, ok := e.(^Expr_Composite); ok { repr.backing = literal.backing }
	return repr
}

// The type `e` evaluates to before its implicit conversions, independent of the
// walk: what a user operator's procedure returns, for one.
prov_unconverted_type :: proc(e: Expr) -> Type_Id {
	repr := prov_checked_repr(e)
	if repr.erased_from != INVALID_TYPE { repr = prov_repr_beneath(repr, .Erasure) }
	if repr.widened_from != INVALID_TYPE { repr = prov_repr_beneath(repr, .Widening) }
	if repr.view_from != INVALID_TYPE { repr = prov_repr_beneath(repr, .View) }
	return repr.type
}

// A conversion whose source the walk is evaluating: until it ends, `node` is
// walked at `repr`, the representation beneath that conversion.
Prov_Converting :: struct {
	node: ^Expr_Base,
	repr: Prov_Repr,
}

// The representation the walk currently evaluates `e` at. The checked node is
// never rewritten; an open conversion overrides its representation instead.
prov_repr :: proc(graph: ^Flow_Graph, e: Expr) -> Prov_Repr {
	base := expr_base(e)
	if graph.prov != nil && base != nil {
		for index := len(graph.converting) - 1; index >= 0; index -= 1 {
			if graph.converting[index].node == base { return graph.converting[index].repr }
		}
	}
	return prov_checked_repr(e)
}

// Walks `e` beneath one of its implicit conversions until `prov_end_conversion`.
prov_begin_conversion :: proc(graph: ^Flow_Graph, e: Expr, conversion: Prov_Conversion) {
	append(&graph.converting, Prov_Converting{expr_base(e), prov_repr_beneath(prov_repr(graph, e), conversion)})
}

prov_end_conversion :: proc(graph: ^Flow_Graph) {
	pop(&graph.converting)
}

@(private = "file")
prov_repr_beneath :: proc(repr: Prov_Repr, conversion: Prov_Conversion) -> Prov_Repr {
	repr := repr
	switch conversion {
	case .View:     repr.type, repr.view_from = repr.view_from, INVALID_TYPE
	case .Erasure:  repr.type, repr.erased_from = repr.erased_from, INVALID_TYPE
	case .Widening: repr.type, repr.widened_from = repr.widened_from, INVALID_TYPE
	case .Backing:  repr.type, repr.backing = repr.backing, INVALID_TYPE
	}
	return repr
}

prov_type :: proc(graph: ^Flow_Graph, e: Expr) -> Type_Id {
	return prov_repr(graph, e).type
}

@(private)
prov_input_key :: proc(graph: ^Flow_Graph, e: Expr) -> Prov_Input_Key {
	base := expr_base(e)
	if base == nil { return {} }
	return Prov_Input_Key{node = base, repr = prov_repr(graph, e), expansion = graph.expansion}
}

prov_input_value :: proc(graph: ^Flow_Graph, e: Expr) -> Value_Id {
	if expr_base(e) == nil { return 0 }
	return prov_intern_value(graph, e, prov_repr(graph, e), graph.expansion)
}

@(private)
prov_intern_value :: proc(graph: ^Flow_Graph, e: Expr, repr: Prov_Repr, expansion: Defer_Expansion) -> Value_Id {
	key := Prov_Input_Key{node = expr_base(e), repr = repr, expansion = expansion}
	if id, found := graph.input.value_ids[key]; found { return id }
	prov_writable_input(graph)
	id := Value_Id(len(graph.input.values))
	append(&graph.input.values, Prov_Value{origin = e, repr = repr, expansion = expansion})
	graph.input.value_ids[key] = id
	place := prov_place_as(graph, e, key)
	form := prov_describe_form(graph, e, expansion)
	value := &graph.input.values[int(id)]
	value.place, value.form, value.temporary = place, form, prov_expr_is_temporary(e)
	value.unknown_alias = prov_alias_source_is_unknown(graph.k.c, repr.type, e)
	return id
}

// The value one implicit conversion of `id` converts: the owner beneath a view,
// the concrete value beneath an erasure, the smaller union beneath a widening,
// or a slice literal's hidden array.
prov_value_beneath :: proc(graph: ^Flow_Graph, id: Value_Id, conversion: Prov_Conversion) -> Value_Id {
	value := prov_value(graph, id)
	return prov_intern_value(graph, value.origin, prov_repr_beneath(value.repr, conversion), value.expansion)
}

// A call's capture is keyed by the call node alone: its checked inputs do not
// depend on the representation its result is converted to.
prov_input_capture :: proc(graph: ^Flow_Graph, call: ^Expr_Call, source: Expr) -> Value_Id {
	key := Prov_Input_Key{node = &call.base, expansion = graph.expansion, capture = true}
	if id, found := graph.input.value_ids[key]; found { return id }
	prov_writable_input(graph)
	from := prov_input_value(graph, source)
	value := graph.input.values[int(from)]
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
	return prov_place_as(graph, e, key)
}

@(private = "file")
prov_place_as :: proc(graph: ^Flow_Graph, e: Expr, key: Prov_Input_Key) -> Prov_Place {
	// An identifier's place is its symbol's storage, which needs no cache entry.
	if ident, named := e.(^Expr_Ident); named {
		id := prov_storage_id(graph, Written_Storage{symbol = ident.symbol})
		if id != 0 { return Prov_Place{base = id, type = key.repr.type} }
		return Prov_Place{type = key.repr.type}
	}
	if place, found := graph.input.places[key]; found { return place }
	place := prov_describe_place(graph, e)
	place.type = key.repr.type
	if place.base != nil {
		prov_writable_input(graph)
		graph.input.places[key] = place
	}
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

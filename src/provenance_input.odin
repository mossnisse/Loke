// Checked storage and place descriptions shared by provenance consumers.
// This boundary has no target sets, loans, or allocator-region facts.
package lokec

import "core:fmt"
import "core:mem"

// Body-local identities in `Prov_Input`; zero is unresolved storage or no value.
// Keys, not IDs, correspond across rebuilds.
Storage_Id :: distinct int
Value_Id :: distinct int

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
	// Where it is read, and the paths of its parameter storage written on every path
	// to there (`prov_overwritten_at`).
	read_at: Prov_Read_Point,
	replaced: [][]Proj_Step,
	// `prov_value_transfer`'s answer; nil when described as no transfer.
	transfer: Prov_Transfer,
	described: bool,
}

Prov_Synthetic_Call_Key :: struct {
	callee: Symbol_Id,
	type: Type_Id,
	span: Span,
	expansion: Defer_Expansion,
	indexes: bool,
}

Prov_Value_Key :: struct {
	node: ^Expr_Base,
	repr: Prov_Repr,
	expansion: Defer_Expansion,
}

// A call's inputs and capture do not depend on the representation its result is
// converted to.
Prov_Call_Key :: struct {
	node: ^Expr_Base,
	expansion: Defer_Expansion,
}

// The implicit conversions a checked node can carry (design.md "string type
// conversions", "Variadic parameters", "Widening by label", "Slice literals").
Prov_Conversion :: enum { View, Erasure, Widening, Backing }

// Writes go through prov_writable_input.
Prov_Input :: struct {
	storages: [dynamic]Prov_Storage,
	storage_ids: map[Written_Storage]Storage_Id,
	values: [dynamic]Prov_Value,
	value_ids: map[Prov_Value_Key]Value_Id,
	calls: map[Prov_Call_Key]Prov_Call_Input,
	captures: map[Prov_Call_Key]Value_Id,
	synthetic_calls: map[Prov_Synthetic_Call_Key]^Expr_Call,
	// A constant map key's entry slot, at most `MAP_KEY_SLOTS` of them; cached
	// paths name these.
	map_key_entries: map[string]int,
}

// Replay and event materialization have a fixed vocabulary: every input they
// read was recorded while the construction walk ran. A query of the finished
// graph may still add one.
prov_writable_input :: proc(graph: ^Flow_Graph) {
	assert(!graph.replaying_facts, "fact replay discovered input absent from normalization")
}

new_prov_input :: proc(allocator: mem.Allocator) -> ^Prov_Input {
	input := new(Prov_Input, allocator)
	input.storages = make([dynamic]Prov_Storage, allocator)
	input.storage_ids = make(map[Written_Storage]Storage_Id, allocator)
	input.values = make([dynamic]Prov_Value, allocator)
	input.value_ids = make(map[Prov_Value_Key]Value_Id, allocator)
	input.calls = make(map[Prov_Call_Key]Prov_Call_Input, allocator)
	input.captures = make(map[Prov_Call_Key]Value_Id, allocator)
	input.synthetic_calls = make(map[Prov_Synthetic_Call_Key]^Expr_Call, allocator)
	input.map_key_entries = make(map[string]int, allocator)
	append(&input.storages, Prov_Storage{})
	append(&input.values, Prov_Value{})
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
	if graph.prov != nil {
		base := expr_base(e)
		#reverse for open in graph.converting {
			if open.node == base { return open.repr }
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

prov_input_value :: proc(graph: ^Flow_Graph, e: Expr) -> Value_Id {
	if expr_base(e) == nil { return 0 }
	return prov_intern_value(graph, e, prov_repr(graph, e))
}

@(private)
prov_intern_value :: proc(graph: ^Flow_Graph, e: Expr, repr: Prov_Repr) -> Value_Id {
	key := Prov_Value_Key{expr_base(e), repr, graph.expansion}
	if id, found := graph.input.value_ids[key]; found { return id }
	prov_writable_input(graph)
	id := Value_Id(len(graph.input.values))
	append(&graph.input.values, Prov_Value{origin = e, repr = repr, expansion = graph.expansion})
	graph.input.value_ids[key] = id
	place := prov_describe_place(graph, e)
	form := prov_describe_form(graph, e)
	value := &graph.input.values[int(id)]
	value.place, value.form, value.temporary = place, form, prov_expr_is_temporary(e)
	value.unknown_alias = prov_alias_source_is_unknown(graph.k.c, repr.type, e)
	value.read_at = prov_read_point(graph)
	value.replaced = prov_overwritten_at(graph, place, value.read_at)
	return id
}

// The value one implicit conversion of `id` converts: the owner beneath a view,
// the concrete value beneath an erasure, the smaller union beneath a widening,
// or a slice literal's hidden array.
prov_value_beneath :: proc(graph: ^Flow_Graph, id: Value_Id, conversion: Prov_Conversion) -> Value_Id {
	value := prov_value(graph, id)
	assert(value.expansion == graph.expansion, "a value's conversion was read outside its expansion")
	return prov_intern_value(graph, value.origin, prov_repr_beneath(value.repr, conversion))
}

prov_input_capture :: proc(graph: ^Flow_Graph, call: ^Expr_Call, source: Expr) -> Value_Id {
	key := Prov_Call_Key{&call.base, graph.expansion}
	if id, found := graph.input.captures[key]; found { return id }
	prov_writable_input(graph)
	from := prov_input_value(graph, source)
	value := graph.input.values[int(from)]
	id := Value_Id(len(graph.input.values))
	append(&graph.input.values, value)
	graph.input.captures[key] = id
	return id
}

// This is the only syntax walk that classifies direct and indirect places.
// Evaluation, alias resolution, and cleanup registration stay with consumers.
prov_input_place :: proc(graph: ^Flow_Graph, e: Expr) -> Prov_Place {
	// An identifier's place is its symbol's storage, which needs no value.
	if _, named := e.(^Expr_Ident); named { return prov_describe_place(graph, e) }
	return prov_value(graph, prov_input_value(graph, e)).place
}

@(private = "file")
prov_describe_place :: proc(graph: ^Flow_Graph, e: Expr) -> Prov_Place {
	c := graph.k.c
	#partial switch v in e {
	case ^Expr_Ident:
		if id := prov_storage_id(graph, Written_Storage{symbol = v.symbol}); id != 0 { return Prov_Place{base = id} }
		return {}
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
		if !v.boxed {
			return Prov_Place{base = prov_input_value(graph, v.operand)}
		}
		place := prov_input_place(graph, v.operand)
		if place.base == nil { return {} }
		place.path = prov_extend(graph, place.path, proj_wild())
		return place
	case ^Expr_Index:
		if len(v.bound) > 0 || v.resolution.kind == .User_Operator { return {} }
		operand := expr_base(v.operand).type
		if type_indexes_through_view(c, operand) {
			return Prov_Place{base = prov_input_value(graph, v.operand), path = prov_extend(graph, nil, proj_wild())}
		}
		#partial switch underlying_kind(c, operand) {
		case .Array, .Dynamic_Array, .Map, .Simd:
			place := prov_input_place(graph, v.operand)
			if place.base == nil { return {} }
			place.path = prov_concat_path(graph, place.path, prov_index_path(graph, v))
			return place
		case .Pointer:
			// A pointer's loans name its whole pointee: `p[0].a` with
			// `p: ^[2]Pair` is `[0, a]` below `p`.
			path := prov_index_path_in(graph, v, underlying_info(c, operand).element)
			return Prov_Place{base = prov_input_value(graph, v.operand), path = path}
		}
	case ^Expr_Call:
		// `field.get(value)` is `field.pointer(value)^`.
		if reflect, ok := v.operation.(Call_Reflect); ok && reflect.op == .Field_Get && len(v.bound) > 0 {
			return Prov_Place{base = prov_input_value(graph, v.bound[0])}
		}
	}
	return {}
}

// A view's loans already name the elements it views, so an element sits one
// wildcard step below it in a place and at no step below its loans
// (`prov_place_hops`).
@(private)
type_indexes_through_view :: proc(c: ^Compiler, type: Type_Id) -> bool {
	kind := underlying_kind(c, type)
	return kind == .Slice || kind == .C_Pointer
}

@(private)
prov_field_step :: proc(graph: ^Flow_Graph, v: ^Expr_Selector) -> Proj_Step {
	if !type_is_union(graph.k.c, prov_type(graph, v.operand)) {
		if field := symbol_of(graph.k.c, v.resolution.symbol); field != nil {
			step := proj_field(int(field.index))
			step.synchronized = v.synchronized
			return step
		}
	}
	return proj_wild()
}

@(private)
prov_index_path :: proc(graph: ^Flow_Graph, v: ^Expr_Index) -> []Proj_Step {
	return prov_index_path_in(graph, v, prov_type(graph, v.operand))
}

@(private)
prov_index_path_in :: proc(graph: ^Flow_Graph, v: ^Expr_Index, type: Type_Id) -> []Proj_Step {
	#partial switch underlying_kind(graph.k.c, type) {
	case .Array:
		return prov_extend(graph, nil, prov_index_step(graph, v.indices))
	case .Dynamic_Array:
		step := prov_index_step(graph, v.indices)
		step.shifts = true
		if step.kind == .Range && step.lo >= CARRIER_ARRAY_ELEMENTS { step.precision = {.Array_Elements} }
		return prov_extend(graph, nil, step)
	case .Map:
		key: Expr
		if len(v.indices) == 1 {
			key = v.indices[0]
		}
		entry := prov_extend(graph, nil, prov_map_entry_step(graph, type, key))
		return prov_extend(graph, entry, proj_field(PROJ_MAP_VALUE))
	}
	return prov_extend(graph, nil, proj_wild())
}

@(private = "file")
prov_index_step :: proc(graph: ^Flow_Graph, indices: []Expr) -> Proj_Step {
	if len(indices) != 1 {
		return proj_wild()
	}
	value, ok := prov_const_int(graph, indices[0])
	if !ok {
		return proj_wild()
	}
	return proj_range(value, value + 1)
}

// A constant key's own entry while slots remain, else the wildcard, which
// overlaps every keyed entry.
@(private)
prov_map_entry_step :: proc(graph: ^Flow_Graph, map_type: Type_Id, key: Expr) -> Proj_Step {
	if key == nil || !map_shape_is_keyed(graph.k.c, map_type) {
		return proj_wild()
	}
	base := expr_base(key)
	if base == nil || !base_is_const(base) {
		return proj_wild()
	}
	name: string
	#partial switch base.const_value.kind {
	case .String:
		name = fmt.aprintf("s:%s", base.const_value.text, allocator = graph.alloc)
	case .Integer, .Rune:
		value, ok := bi_to_i64(graph.k.c, base.const_value.integer)
		if !ok {
			return proj_wild()
		}
		name = fmt.aprintf("%s:%d", base.const_value.kind == .Integer ? "i" : "r", value, allocator = graph.alloc)
	case .Boolean:
		name = fmt.aprintf("b:%v", base.const_value.boolean, allocator = graph.alloc)
	case:
		return proj_wild()
	}
	if entry, found := graph.input.map_key_entries[name]; found {
		return proj_range(i64(entry), i64(entry) + 1)
	}
	entry := len(graph.input.map_key_entries)
	if entry >= MAP_KEY_SLOTS {
		step := proj_wild()
		step.precision = {.Map_Keys}
		return step
	}
	prov_writable_input(graph)
	graph.input.map_key_entries[name] = entry
	return proj_range(i64(entry), i64(entry) + 1)
}

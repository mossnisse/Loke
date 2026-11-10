// Where a borrow can be inside a value: the vocabulary the provenance solver in
// `borrow.odin` shares with `check.odin`, `lifecycle.odin` and the emitter, which
// needs no solver state. The region lattice is in `region.odin`, and result
// summaries in `result_summary.odin`.
package lokec

// design.md "Storage roots and borrow carriers". `rawptr` and `[^]T` carry no
// checked provenance. An Allocator borrows its provider's control block.
// A region provider is a carrier because an arena over a
// caller's buffer holds that buffer; a compiler-known view (a map view or
// iterator) holds only a raw pointer, so its marker is what makes it followed.
type_is_carrier :: proc(c: ^Compiler, type: Type_Id) -> bool {
	if type == INVALID_TYPE {
		return false
	}
	if type_is_region_provider(c, type) || type_is_allocator(c, type) {
		return true
	}
	if info := underlying_info(c, type); info != nil && info.is_view {
		return true
	}
	#partial switch underlying_kind(c, type) {
	case .Pointer, .Slice, .String_View, .CString_View, .Dyn:
		return true
	}
	return false
}

// `^mut T`, `[]mut T`, `dyn mut I` and a mutable view are mutable borrows.
carrier_is_mutable :: proc(c: ^Compiler, type: Type_Id) -> bool {
	if type_is_region_provider(c, type) {
		return true // it writes into the buffer it was given
	}
	info := underlying_info(c, type)
	if info == nil {
		return false
	}
	// A view says so itself: a map's `iter_mut`, or an adapter over a mutable view
	// (design.md "Iteration adapters").
	if info.is_view {
		return info.mutable
	}
	#partial switch info.kind {
	case .Pointer, .Slice, .Dyn:
		return info.mutable
	}
	return false
}

// ----------------------------------------------------- carrier shapes --

// Where inside a value a borrow can be, as `Proj_Step` paths, kept finite by the
// budgets below (design.md "Minimum provenance precision").
CARRIER_DEPTH :: 4
CARRIER_WIDTH :: 64
// `Result_Dependencies.param_loads` keeps a bit per load depth in a `u8`.
#assert(CARRIER_DEPTH <= 8)
// A fixed array up to this length gets a path per element.
CARRIER_ARRAY_ELEMENTS :: 8

// A map entry's key and value are sibling fields of the entry step.
PROJ_MAP_KEY :: 0
PROJ_MAP_VALUE :: 1

// Constant keys per body that get an entry of their own; others use a wildcard
// step overlapping every entry.
MAP_KEY_SLOTS :: 4
// The widest entry (key plus value paths) worth replicating per key.
MAP_KEY_PATH_LIMIT :: 2

// Whether this map type's shape separates constant keys. The place code asks the
// same question, so both agree on how many entries exist.
map_shape_is_keyed :: proc(c: ^Compiler, type: Type_Id) -> bool {
	if cached, found := c.map_keyed[type]; found {
		return cached
	}
	// Provisionally unkeyed, so a map reaching itself keeps one wildcard entry.
	c.map_keyed[type] = false
	out := false
	if info := underlying_info(c, type); info != nil && info.kind == .Map {
		// Measured with one path per dynamic array, whose elements are replicated
		// after this is decided, as a map's entries are.
		paths := make([dynamic]Carrier_Path, 0, MAP_KEY_PATH_LIMIT + 1, context.temp_allocator)
		carrier_shape_walk(c, info.key, nil, 0, &paths, elements = false)
		carrier_shape_walk(c, info.element, nil, 0, &paths, elements = false)
		out = len(paths) > 0 && len(paths) <= MAP_KEY_PATH_LIMIT
	}
	c.map_keyed[type] = out
	return out
}

Carrier_Path :: struct {
	precision: Precision_Loss,
	steps:     []Proj_Step,
	type:      Type_Id, // the leaf carrier, or INVALID_TYPE when truncated
	mutable:   bool,    // for a truncated path, whether any carrier below is
	truncated: bool,    // cut at a limit; stands for every carrier below it
	cut:       Type_Id, // for a truncated path, the type of the value cut
}

Carrier_Reach :: struct {
	any:     bool,
	mutable: bool,
}

// Whether a carrier is reachable inside a type. Only the queried type is cached:
// an intermediate cut short by a visiting ancestor may be wrong on its own.
type_carries_borrow :: proc(c: ^Compiler, type: Type_Id) -> Carrier_Reach {
	if type == INVALID_TYPE {
		return {}
	}
	if cached, found := c.carrier_reach[type]; found {
		return cached
	}
	visiting := make(map[Type_Id]bool, context.temp_allocator)
	reach := carrier_reach_walk(c, type, &visiting)
	c.carrier_reach[type] = reach
	return reach
}

// Whether a callee receiving `type` can write a borrow through it: through a
// mutable carrier, at any depth, to storage that can hold one, as `p^.view =
// values` or `ctx.destination.view = values` does. Searched over the types
// reached, each once, so no depth hides one.
prov_type_reaches_destination :: proc(c: ^Compiler, type: Type_Id) -> bool {
	if cached, found := c.reaches_destination[type]; found {
		return cached
	}
	visited := make(map[Type_Id]bool, context.temp_allocator)
	reaches := type_reaches_destination(c, type, &visited)
	c.reaches_destination[type] = reaches
	return reaches
}

// design.md "Allocator regions and region provenance": whether a callee
// receiving `type` can write an owner through it: through a mutable carrier at
// any depth, whatever it points at, as `outs[0]^ = make(...)` does through
// `outs: ..^mut [dynamic]int`.
prov_type_reaches_mutable :: proc(c: ^Compiler, type: Type_Id) -> bool {
	if cached, found := c.reaches_mutable[type]; found {
		return cached
	}
	visited := make(map[Type_Id]bool, context.temp_allocator)
	reaches := type_reaches_destination(c, type, &visited, owners = true)
	c.reaches_mutable[type] = reaches
	return reaches
}

// With `owners`, any mutable carrier is a destination, not only one whose
// pointee can hold a borrow.
@(private = "file")
type_reaches_destination :: proc(c: ^Compiler, type: Type_Id, visited: ^map[Type_Id]bool, owners := false) -> bool {
	if visited[type] {
		return false
	}
	visited[type] = true
	for path in carrier_shape(c, type) {
		if path.truncated {
			if truncated_reaches_destination(c, path, visited, owners) {
				return true
			}
			continue
		}
		info := underlying_info(c, path.type)
		if info == nil {
			continue
		}
		if path.mutable && (owners || type_carries_borrow(c, info.element).any) {
			return true
		}
		if type_reaches_destination(c, info.element, visited, owners) {
			return true
		}
	}
	return false
}

// A truncated path names no carrier, so the value it cut is searched instead:
// a mutable carrier in it is a destination, and a read-only one leads to one
// when its pointee reaches one, as `ptr: ^Leaf` does with `Leaf{out: ^mut ^int}`
// below the depth budget.
@(private)
truncated_reaches_destination :: proc(c: ^Compiler, path: Carrier_Path, visited: ^map[Type_Id]bool, owners := false) -> bool {
	if path.mutable {
		return true
	}
	leaves := make([dynamic]Type_Id, 0, 4, context.temp_allocator)
	walking := make(map[Type_Id]bool, context.temp_allocator)
	carrier_leaves(c, path.cut, &leaves, &walking)
	for leaf in leaves {
		info := underlying_info(c, leaf)
		if info != nil && type_reaches_destination(c, info.element, visited, owners) {
			return true
		}
	}
	return false
}

// The carrier types in a value of `type`, without following any of them; the
// same walk `type_carries_borrow` takes.
@(private = "file")
carrier_leaves :: proc(c: ^Compiler, type: Type_Id, out: ^[dynamic]Type_Id, walking: ^map[Type_Id]bool) {
	if type == INVALID_TYPE || walking[type] {
		return
	}
	if type_is_carrier(c, type) {
		append(out, type)
		return
	}
	info := underlying_info(c, type)
	if info == nil || !type_carries_borrow(c, type).any {
		return
	}
	walking[type] = true
	if payload := shared_payload_type(c, type); payload != INVALID_TYPE {
		carrier_leaves(c, payload, out, walking)
		return
	}
	for part in type_owned_parts(c, info) {
		carrier_leaves(c, part, out, walking)
	}
}

@(private = "file")
carrier_reach_walk :: proc(c: ^Compiler, type: Type_Id, visiting: ^map[Type_Id]bool) -> Carrier_Reach {
	if type == INVALID_TYPE {
		return {}
	}
	if cached, found := c.carrier_reach[type]; found {
		return cached
	}
	if visiting[type] {
		return {} // the walk already went, or is going, through everything below this
	}
	if type_is_carrier(c, type) {
		return Carrier_Reach{any = true, mutable = carrier_is_mutable(c, type)}
	}
	info := underlying_info(c, type)
	if info == nil {
		return {}
	}
	visiting[type] = true
	out: Carrier_Reach
	if payload := shared_payload_type(c, type); payload != INVALID_TYPE {
		return carrier_reach_walk(c, payload, visiting)
	}
	for part in type_owned_parts(c, info) {
		carrier_reach_join(&out, carrier_reach_walk(c, part, visiting))
	}
	return out
}

@(private = "file")
carrier_reach_join :: proc(into: ^Carrier_Reach, from: Carrier_Reach) {
	into.any ||= from.any
	into.mutable ||= from.mutable
}

// How many loads through a value of this type can still read a borrow: 1 for
// `[]string_view`, 2 for `[]^string_view`. A shape it cannot follow, or one
// deeper than `CARRIER_DEPTH`, answers `CARRIER_DEPTH`.
load_depth :: proc(c: ^Compiler, type: Type_Id, depth := 0) -> int {
	if depth >= CARRIER_DEPTH {
		return CARRIER_DEPTH
	}
	most := 0
	for path in carrier_shape(c, type) {
		if path.truncated {
			return CARRIER_DEPTH
		}
		info := underlying_info(c, path.type)
		if info != nil && (info.kind == .Pointer || info.kind == .Slice) && type_carries_borrow(c, info.element).any {
			most = max(most, 1 + load_depth(c, info.element, depth + 1))
		}
	}
	return min(most, CARRIER_DEPTH)
}

// The carrier paths of what one load through a pointer or slice reads, as
// `[a]` and `[b]` for `[]Pair`; nil for any other carrier.
carrier_pointee_shape :: proc(c: ^Compiler, type: Type_Id) -> []Carrier_Path {
	info := underlying_info(c, type)
	if info == nil || (info.kind != .Pointer && info.kind != .Slice) {
		return nil
	}
	return carrier_shape(c, info.element)
}

// Every place inside a value of this type that can hold a borrow.
carrier_shape :: proc(c: ^Compiler, type: Type_Id) -> []Carrier_Path {
	if type == INVALID_TYPE {
		return nil
	}
	if cached, found := c.carrier_shapes[type]; found {
		return cached
	}
	out := make([dynamic]Carrier_Path, 0, 4, c.semantic_allocator)
	carrier_shape_walk(c, type, nil, 0, &out, elements = true)
	if len(out) > CARRIER_WIDTH {
		// Retry with one path per dynamic array before collapsing to one path.
		clear(&out)
		carrier_shape_walk(c, type, nil, 0, &out, elements = false)
	}
	shape := out[:]
	if len(shape) > CARRIER_WIDTH {
		whole := make([]Carrier_Path, 1, c.semantic_allocator)
		whole[0] = carrier_truncated(nil, type, type_carries_borrow(c, type), {.Width})
		shape = whole
	}
	c.carrier_shapes[type] = shape
	return shape
}

@(private = "file")
carrier_shape_walk :: proc(
	c: ^Compiler,
	type: Type_Id,
	prefix: []Proj_Step,
	depth: int,
	out: ^[dynamic]Carrier_Path,
	elements: bool,
) {
	// One path past the width already collapses the shape to its whole value,
	// so no more are collected (or allocated).
	if type == INVALID_TYPE || len(out) > CARRIER_WIDTH {
		return
	}
	if type_is_carrier(c, type) {
		append(out, Carrier_Path {
			precision = path_precision(prefix),
			steps   = prefix,
			type    = type,
			mutable = carrier_is_mutable(c, type),
		})
		return
	}
	reach := type_carries_borrow(c, type)
	if !reach.any {
		return // a scalar subtree, and the one place a cycle of scalars stops
	}
	if depth >= CARRIER_DEPTH {
		append(out, carrier_truncated(prefix, type, reach, {.Depth}))
		return
	}
	info := underlying_info(c, type)
	if info == nil {
		return
	}
	// A shared handle's payload is reached as a box's is.
	if payload := shared_payload_type(c, type); payload != INVALID_TYPE {
		carrier_shape_walk(c, payload, carrier_extend(c, prefix, proj_wild()), depth + 1, out, elements)
		return
	}
	#partial switch info.kind {
	case .Struct:
		for field in info.fields {
			sym := symbol_of(c, field)
			if sym == nil {
				continue
			}
			step := proj_field(int(sym.index))
			carrier_shape_walk(c, sym.type, carrier_extend(c, prefix, step), depth + 1, out, elements)
		}
	case .Union:
		for variant in info.variants {
			carrier_shape_walk(c, variant, carrier_extend(c, prefix, proj_wild()), depth + 1, out, elements)
		}
	case .Array:
		if info.count > 0 && info.count <= CARRIER_ARRAY_ELEMENTS {
			for index in 0 ..< i64(info.count) {
				step := proj_range(index, index + 1)
				carrier_shape_walk(c, info.element, carrier_extend(c, prefix, step), depth + 1, out, elements)
			}
			return
		}
		step := proj_wild()
		if info.count > CARRIER_ARRAY_ELEMENTS { step.precision = {.Array_Elements} }
		carrier_shape_walk(c, info.element, carrier_extend(c, prefix, step), depth + 1, out, elements)
	case .Dynamic_Array:
		if elements {
			for index in 0 ..< i64(CARRIER_ARRAY_ELEMENTS) {
				carrier_shape_walk(c, info.element, carrier_extend(c, prefix, proj_dynamic_element(index)), depth + 1, out, elements)
			}
			// Every element past those; an index that names one says it is merged
			// (`prov_index_path_in`).
			rest := proj_range(CARRIER_ARRAY_ELEMENTS, max(i64))
			rest.shifts = true
			carrier_shape_walk(c, info.element, carrier_extend(c, prefix, rest), depth + 1, out, elements)
			return
		}
		merged := proj_wild()
		merged.precision = {.Array_Elements}
		carrier_shape_walk(c, info.element, carrier_extend(c, prefix, merged), depth + 1, out, elements)
	case .Box:
		// A box's payload is reached by the same one wildcard step a place `b^` takes.
		carrier_shape_walk(c, info.element, carrier_extend(c, prefix, proj_wild()), depth + 1, out, elements)
	case .Map:
		// No separate wildcard entry: an unknown key uses a wildcard step, which
		// overlaps every keyed entry.
		entries := 1
		if map_shape_is_keyed(c, type) {
			entries = MAP_KEY_SLOTS
		}
		for entry in 0 ..< entries {
			step := entries == 1 ? proj_wild() : proj_range(i64(entry), i64(entry) + 1)
			if entries == 1 { step.precision = {.Map_Width} }
			base := carrier_extend(c, prefix, step)
			carrier_shape_walk(c, info.key, carrier_extend(c, base, proj_field(PROJ_MAP_KEY)), depth + 2, out, elements)
			carrier_shape_walk(c, info.element, carrier_extend(c, base, proj_field(PROJ_MAP_VALUE)), depth + 2, out, elements)
		}
	}
}

@(private = "file")
carrier_truncated :: proc(steps: []Proj_Step, cut: Type_Id, reach: Carrier_Reach, loss: Precision_Loss) -> Carrier_Path {
	return Carrier_Path{steps = steps, type = INVALID_TYPE, mutable = reach.mutable, truncated = true, cut = cut, precision = loss | path_precision(steps)}
}

@(private)
carrier_extend :: proc(c: ^Compiler, prefix: []Proj_Step, step: Proj_Step) -> []Proj_Step {
	return path_extend(prefix, step, c.semantic_allocator)
}

carrier_noun :: proc(c: ^Compiler, type: Type_Id) -> string {
	if type_is_region_provider(c, type) {
		return "region"
	}
	#partial switch underlying_kind(c, type) {
	case .Pointer:      return "pointer"
	case .Slice:        return "slice"
	case .String_View:  return "string view"
	case .CString_View: return "C string view"
	case .Dyn:          return "dyn view"
	}
	return "borrow"
}


// Where a borrow can be inside a value, which allocator regions a value may name,
// and what a procedure's result may depend on: the vocabulary the provenance
// solver in `borrow.odin` shares with `check.odin`, `lifecycle.odin` and the
// emitter, which needs no solver state.
package lokec

import "core:math/bits"
import "core:mem"
import "core:slice"

// design.md "Storage roots and borrow carriers". `rawptr` and `[^]T` carry no
// checked provenance. An Allocator borrows its provider's control block.
// A region provider is a carrier because an arena over a
// caller's buffer holds that buffer; a compiler-known view (a map view or
// iterator) holds only a raw pointer, so its marker is what makes it followed.
type_is_carrier :: proc(c: ^Compiler, type: Type_Id) -> bool {
	if type == INVALID_TYPE {
		return false
	}
	if type_is_region_provider(c, type) || type_underlying(c, type) == TYPE_ALLOCATOR {
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

@(private = "file")
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

// ---------------------------------------------------------- regions --

// The regions an allocator value may name (design.md "Allocator regions and
// region provenance"). Values not proven distinct may share a region.
//
// ponytail: flow-insensitive, one entry per allocator binding, so a reassigned
// allocator variable merges both identities. Make it flow-sensitive if that
// rejects real programs.
Region_Set :: struct {
	params:  u64,  // one bit per parameter of the enclosing body
	// Of `params`, those read at a load below what the parameter names, as
	// `p^.next^.allocator`: a call takes everything its argument's carriers lead to
	// for these, and only what the argument names for the rest
	// (`prov_substitute_region`).
	loaded:  u64,
	default: bool, // the default provider's region
	unknown: bool,
	locals:  u64,  // one bit per local `mem.Arena` or `mem.Scratch`
	crowded: bool, // more local providers than bits: may be any of them
	// `unknown` stands for a parameter past `REGION_PARAM_LIMIT`.
	crowded_params: bool,
}

// The widths of `Region_Set.locals` and `Region_Set.params`.
REGION_LOCAL_LIMIT :: 64
REGION_PARAM_LIMIT :: 64

region_add_param :: proc(set: ^Region_Set, index: int) {
	if index < REGION_PARAM_LIMIT {
		set.params |= u64(1) << uint(index)
	} else {
		set.unknown, set.crowded_params = true, true
	}
}

// A parameter's region read at a load below what it names (`Region_Set.loaded`).
region_add_loaded_param :: proc(set: ^Region_Set, index: int) {
	region_add_param(set, index)
	if index < REGION_PARAM_LIMIT {
		set.loaded |= u64(1) << uint(index)
	}
}

region_remove_param :: proc(set: ^Region_Set, index: int) {
	if index < REGION_PARAM_LIMIT {
		set.params &~= u64(1) << uint(index)
		set.loaded &~= u64(1) << uint(index)
	}
}

region_has_param :: proc(set: Region_Set, index: int) -> bool {
	return index < REGION_PARAM_LIMIT && set.params & (u64(1) << uint(index)) != 0
}

region_has_loaded_param :: proc(set: Region_Set, index: int) -> bool {
	return index < REGION_PARAM_LIMIT && set.loaded & (u64(1) << uint(index)) != 0
}

// Takes the lowest parameter out of `params`, to walk a set's parameters.
next_region_param :: proc(params: ^u64) -> (index: int, ok: bool) {
	if params^ == 0 {
		return 0, false
	}
	index = int(bits.count_trailing_zeros(params^))
	params^ &= params^ - 1
	return index, true
}

// Whether the set may name a region created in this procedure.
region_has_local :: proc(set: Region_Set) -> bool {
	return set.locals != 0 || set.crowded
}

// A region this body created and nothing outside it can name, which it may
// reset freely.
region_is_local_only :: proc(set: Region_Set) -> bool {
	return region_has_local(set) && !set.default && !set.unknown && !region_is_parameter_backed(set)
}

// Whether two sets may name the same region.
regions_may_overlap :: proc(a, b: Region_Set) -> bool {
	if a.unknown || b.unknown || a.crowded || b.crowded {
		return true
	}
	// Any two parameters may be the same handle, and a parameter may be the
	// default. A local region did not exist at entry, so it is distinct from both.
	a_parameter := region_is_parameter_backed(a)
	b_parameter := region_is_parameter_backed(b)
	if (a_parameter && (b_parameter || b.default)) || (b_parameter && a.default) {
		return true
	}
	return (a.default && b.default) || a.locals & b.locals != 0
}

region_is_parameter_backed :: proc(set: Region_Set) -> bool {
	return set.params != 0
}

region_is_empty :: proc(set: Region_Set) -> bool {
	return !set.default && !set.unknown && !region_has_local(set) && !region_is_parameter_backed(set)
}

// Merges `from` into `into`, reporting whether `into` gained anything.
region_merge :: proc(into: ^Region_Set, from: Region_Set) -> bool {
	before := into^
	into.params |= from.params
	into.loaded |= from.loaded
	into.default ||= from.default
	into.unknown ||= from.unknown
	into.locals |= from.locals
	into.crowded ||= from.crowded
	into.crowded_params ||= from.crowded_params
	return into^ != before
}

// design.md "Allocators and tasks": a procedure's allocator use is the regions it
// may allocate from, resize or free in, reset, or destroy. A parameter's is
// whatever each caller passes, and the call substitutes it; a region the body
// creates is its own, and only its provider's parent, where the provider draws and
// returns blocks, is a caller's concern (`prov_caller_region`). So a use never
// names a local: one in `set` is unknown here.
merge_allocator_use :: proc(into: ^Region_Set, set: Region_Set) -> bool {
	before := into^
	into.params |= set.params
	into.default ||= set.default
	into.unknown ||= set.unknown || set.crowded || set.locals != 0
	return into^ != before
}

// `set`, in a callee's terms, in its caller's: each parameter region as the region
// of the argument the call binds there, or an unknown one when the call's regions
// are not known. A call that is not `direct`, through a value or a `dyn` slot, may
// bind any argument to any parameter of the target. The callee's own local regions
// are unknown to its caller.
substituted_region :: proc(set: Region_Set, regions: []Region_Set, direct := true) -> Region_Set {
	out := Region_Set{default = set.default, unknown = set.unknown || set.crowded || set.locals != 0}
	params := set.params
	for parameter in next_region_param(&params) {
		switch {
		case regions == nil:
			out.unknown = true
		case !direct:
			for region in regions {
				region_merge(&out, region)
			}
		case parameter < len(regions):
			region_merge(&out, regions[parameter])
		}
	}
	return out
}

// A callback's allocator use at a call that passes it: every argument it is given
// is in `given`, the regions its callee passes it, in that callee's terms.
callback_allocator_use :: proc(use, given: Region_Set, regions: []Region_Set) -> Region_Set {
	return substituted_region(use, []Region_Set{substituted_region(given, regions)}, direct = false)
}

// `nil` is a call's regions not being known, which a clone keeps.
clone_regions :: proc(regions: []Region_Set, allocator: mem.Allocator) -> []Region_Set {
	if regions == nil {
		return nil
	}
	return slice.clone(regions, allocator)
}

// ------------------------------------------------------- result summaries --

// The root component of a result-provenance summary (design.md "Temporaries
// and procedure boundaries"). Every field is a possibility, so the join is a
// union and the whole-program fixed point terminates.
Result_Dependencies :: struct {
	precision: Precision_Loss,
	// Which borrowed parameters the result may name storage of.
	params: []bool,
	// Per parameter, which paths of its `carrier_shape` the result may borrow.
	// Nil means the whole parameter.
	param_paths:  [][]bool,
	// Per parameter, a bit per load depth at which the result may hold what is
	// read through it: bit 0 for an element copied out of a slice, not the slice.
	param_loads:  []u8,
	// Per parameter and load depth, which paths the first and the last of those
	// loads may go along (`Load_Paths`).
	param_load_paths: [][]Load_Paths,
	static:       bool,
	thread:       bool,
	// The globals the result may borrow, so a caller's write to one, or a call
	// that writes one, conflicts with the result (design.md "Global write
	// effects"). `static` and `thread` cover storage no symbol names.
	globals:      []Symbol_Id,
	local:        bool, // already an error in the callee
	unknown:      bool,
}

// design.md "Procedure result contracts": which paths a result's loads through a
// parameter go along. `first` is of the parameter's `carrier_pointee_shape`. `last`
// has a row per path of that shape, the paths of its `last_load_shape` the last
// load may go along below it, so `nest^.two^.q` names `q` and not `two^.p`, and a
// result that is `w^.two^.q` or `w^.other^.p` names neither `two^.p` nor `other^.q`.
// Nil, as `last` or as one of its rows, means every path. `last` is nil when the
// first load may go along any of several paths, and a row counts only for a path
// `first` includes (`load_goes_along`).
Load_Paths :: struct {
	first: []bool,
	last:  [][]bool,
}

// Whether a row of paths, where nil means every path, includes `along`.
load_goes_along :: proc(row: []bool, along: int) -> bool {
	return row == nil || (along < len(row) && row[along])
}

// The paths `depth` loads through parameter `index` may go along.
result_load_paths :: proc(dependencies: Result_Dependencies, index, depth: int) -> Load_Paths {
	if index >= len(dependencies.param_load_paths) {
		return {}
	}
	depths := dependencies.param_load_paths[index]
	return depth - 1 < len(depths) ? depths[depth - 1] : {}
}

// The carrier `depth` loads below one of `type`, when each storage on the way
// holds exactly one; INVALID_TYPE otherwise. `all_pointers` when each carrier on
// the way and the one found is a pointer, not a view of several elements, so they
// name one storage.
carrier_below :: proc(c: ^Compiler, type: Type_Id, depth: int) -> (carrier: Type_Id, all_pointers: bool) {
	at := type
	all_pointers = true
	for _ in 0 ..< depth {
		all_pointers &&= underlying_kind(c, at) == .Pointer
		inner := carrier_pointee_shape(c, at)
		if len(inner) != 1 || inner[0].truncated {
			return INVALID_TYPE, false
		}
		at = inner[0].type
	}
	return at, all_pointers && underlying_kind(c, at) == .Pointer
}

// The carrier paths of what the last of `depth` loads reads, the first along the
// pointee path `along` and each one between reading the one carrier its storage
// holds; nil when that is not one type, or `depth` is 1.
last_load_shape :: proc(c: ^Compiler, along: Carrier_Path, depth: int) -> []Carrier_Path {
	if depth < 2 || along.truncated {
		return nil
	}
	below, _ := carrier_below(c, along.type, depth - 2)
	if below == INVALID_TYPE {
		return nil
	}
	return carrier_pointee_shape(c, below)
}

// Which paths a caller's loads through one argument go along for a result
// `depth` loads down: the first load's and the last's, nil for every path.
Load_Route :: struct {
	first, last: []Proj_Step,
}

// The routes of `depth` loads through parameter `index`, whose pointee has the
// carrier paths `pointee`, as the summary's `Load_Paths` say.
result_load_routes :: proc(
	c: ^Compiler, dependencies: Result_Dependencies, index, depth: int, pointee: []Carrier_Path, allocator: mem.Allocator,
) -> []Load_Route {
	paths := result_load_paths(dependencies, index, depth)
	out := make([dynamic]Load_Route, 0, 2, allocator)
	whole := len(paths.first) == 0 || len(paths.first) != len(pointee)
	if whole && len(pointee) != 1 {
		append(&out, Load_Route{})
		return out[:]
	}
	for along, position in pointee {
		if !whole && !paths.first[position] {
			continue
		}
		first := whole ? nil : along.steps
		shape := last_load_shape(c, along, depth)
		row := position < len(paths.last) ? paths.last[position] : nil
		if len(row) == 0 || len(row) != len(shape) {
			append(&out, Load_Route{first, nil})
			continue
		}
		for named, last in row {
			if named {
				append(&out, Load_Route{first, shape[last].steps})
			}
		}
	}
	return out[:]
}

// Whether a result may depend on a parameter: borrow it, or hold what its
// storage holds.
result_uses_param :: proc(dependencies: Result_Dependencies, index: int) -> bool {
	return index < len(dependencies.params) && (dependencies.params[index] || dependencies.param_loads[index] != 0)
}

Result_Content_Provenance :: struct {
	path:         Carrier_Path,
	dependencies: Result_Dependencies,
}

Result_Provenance :: struct {
	// The union over the whole result.
	using dependencies: Result_Dependencies,
	// Per content path; only concrete body summaries have it.
	content_type: Type_Id,
	content:      []Result_Content_Provenance,
	// The region component, independent of the root one.
	region:         Region_Set,
	region_content: []Prov_Region_Content, // backing and payload facts, recursively
}

@(private = "file")
new_result_dependencies :: proc(param_count: int, allocator: mem.Allocator) -> Result_Dependencies {
	return Result_Dependencies {
		params      = make([]bool, param_count, allocator),
		param_paths = make([][]bool, param_count, allocator),
		param_loads = make([]u8, param_count, allocator),
		param_load_paths = make([][]Load_Paths, param_count, allocator),
	}
}

@(private)
new_result_provenance :: proc(c: ^Compiler, param_count: int, type: Type_Id, with_content: bool, allocator: mem.Allocator) -> Result_Provenance {
	out := Result_Provenance {
		dependencies = new_result_dependencies(param_count, allocator),
		content_type = type,
	}
	if !with_content {
		return out
	}
	if !type_is_carrier(c, type) {
		shape := carrier_shape(c, type)
		out.content = make([]Result_Content_Provenance, len(shape), allocator)
		for path, index in shape {
			summary_path := path
			summary_path.steps = slice.clone(path.steps, allocator)
			widen_summary_map_path(c, type, summary_path.steps)
			out.content[index] = Result_Content_Provenance {
				path = summary_path,
				dependencies = new_result_dependencies(param_count, allocator),
			}
			out.content[index].dependencies.precision = path_precision(summary_path.steps)
			out.precision |= out.content[index].dependencies.precision
		}
	}
	out.region_content = region_field_shape(c, type, allocator)
	return out
}

// Keep record fields separate so a handle's region does not back a sibling
// owner, including inside nested records (design.md "Allocator regions and
// region provenance"). A managed record also keeps its own dependency: a
// moved parameter's escape contract applies even with only scalar fields.
// Containers and shared handles separate their allocation from their payload.
// Union field steps name variant indices; root borrow paths remain unchanged.
// A shape wider than `REGION_SHAPE_WIDTH` collapses to one whole-value entry.
// The shape is kept per type, and each caller gets its own copy to fill in.
@(private)
region_field_shape :: proc(c: ^Compiler, type: Type_Id, allocator: mem.Allocator) -> []Prov_Region_Content {
	shape, found := c.region_shapes[type]
	if !found {
		out := make([dynamic]Prov_Region_Content, 0, 4, c.semantic_allocator)
		region_field_shape_into(c, type, nil, &out)
		shape = out[:]
		if len(shape) > REGION_SHAPE_WIDTH {
			shape = shape[:1]
			shape[0] = Prov_Region_Content{handle = !type_is_managed(c, type)}
		}
		c.region_shapes[type] = shape
	}
	return slice.clone(shape, allocator)
}

// The widest shape kept apart. A recursive union's entries multiply up to the
// depth limit, and later code joins them pairwise.
REGION_SHAPE_WIDTH :: 256
// How far a walk for regions follows a type before taking the rest as a whole.
REGION_SHAPE_DEPTH :: 8

@(private = "file")
region_field_shape_into :: proc(c: ^Compiler, type: Type_Id, prefix: []Proj_Step, out: ^[dynamic]Prov_Region_Content) {
	// One entry past the width already collapses the shape.
	if len(out) > REGION_SHAPE_WIDTH || !prov_type_has_region(c, type) { return }
	info := underlying_info(c, type)
	payload := shared_payload_type(c, type)
	compound := info != nil && (payload != INVALID_TYPE || info.kind == .Struct || info.kind == .Union ||
	            info.kind == .Array || info.kind == .Dynamic_Array || info.kind == .Map || info.kind == .Box)
	if !compound || type_is_region_provider(c, type) || len(prefix) >= REGION_SHAPE_DEPTH {
		append(out, Prov_Region_Content{path = prefix, handle = !type_is_managed(c, type)})
		return
	}
	if type_is_managed(c, type) {
		append(out, Prov_Region_Content{path = prefix, own = true})
	}
	switch {
	case payload != INVALID_TYPE:
		region_field_shape_into(c, payload, carrier_extend(c, prefix, proj_wild()), out)
	case info.kind == .Struct:
		for field_id, index in info.fields {
			field := symbol_of(c, field_id)
			region_field_shape_into(c, field == nil ? INVALID_TYPE : field.type, carrier_extend(c, prefix, proj_field(index)), out)
		}
	case info.kind == .Union:
		for variant, index in info.variants {
			region_field_shape_into(c, variant, carrier_extend(c, prefix, proj_field(index)), out)
		}
	case info.kind == .Map:
		entry := carrier_extend(c, prefix, proj_wild())
		region_field_shape_into(c, info.key, carrier_extend(c, entry, proj_field(PROJ_MAP_KEY)), out)
		region_field_shape_into(c, info.element, carrier_extend(c, entry, proj_field(PROJ_MAP_VALUE)), out)
	case:
		region_field_shape_into(c, info.element, carrier_extend(c, prefix, proj_wild()), out)
	}
}

// Constant map entries are numbered per body, so a summary path widens them to
// a wildcard step and keeps every other step.
@(private)
widen_summary_map_path :: proc(c: ^Compiler, type: Type_Id, path: []Proj_Step) {
	if len(path) == 0 {
		return
	}
	info := underlying_info(c, type)
	if info == nil {
		return
	}
	if payload := shared_payload_type(c, type); payload != INVALID_TYPE {
		widen_summary_map_path(c, payload, path[1:])
		return
	}
	#partial switch info.kind {
	case .Struct:
		for field in info.fields {
			if sym := symbol_of(c, field); sym != nil && steps_overlap(proj_field(int(sym.index)), path[0]) {
				widen_summary_map_path(c, sym.type, path[1:])
			}
		}
	case .Union:
		for variant in info.variants {
			widen_summary_map_path(c, variant, path[1:])
		}
	case .Array, .Dynamic_Array, .Box:
		widen_summary_map_path(c, info.element, path[1:])
	case .Map:
		loss := path[0].precision
		if path[0].kind == .Range { loss |= {.Map_Summary} }
		path[0] = proj_wild()
		path[0].precision = loss
		if len(path) > 1 {
			if steps_overlap(path[1], proj_field(PROJ_MAP_KEY)) {
				widen_summary_map_path(c, info.key, path[2:])
			}
			if steps_overlap(path[1], proj_field(PROJ_MAP_VALUE)) {
				widen_summary_map_path(c, info.element, path[2:])
			}
		}
	}
}

// A compiler-contributed member has no body, so its summary is written directly:
// a result holding borrows borrows through `param`, and an owned result is in
// `param`'s regions or the default allocator's. With `per_path`, each carrier path
// of a record result depends on `param` separately, as a body's summary would: the
// halves of `split_at_mut` destructure into two reborrows rather than two reads of
// one.
set_synth_result_summary :: proc(c: ^Compiler, declaration: Symbol_Id, param: int, per_path := false) {
	sym := symbol_of(c, declaration)
	if sym == nil || sym.result == INVALID_TYPE || param >= len(sym.params) {
		return
	}
	summary := new(Result_Provenance, c.semantic_allocator)
	summary^ = new_result_provenance(c, len(sym.params), sym.result, per_path, c.semantic_allocator)
	summary.params[param] = type_carries_borrow(c, sym.result).any
	for &content in summary.content {
		content.dependencies.params[param] = true
	}
	// design.md "Places and overlap": a removed element, or a copy sharing its
	// storage, is in the container's regions; `lookup_value`'s allocating copy is
	// the default provider's.
	if type_is_managed(c, sym.result) {
		if sym.container_op != .Map_Lookup_Value || !clone_may_allocate(c, sym.result) {
			region_add_param(&summary.region, param)
		}
		summary.region.default = true
	}
	c.result_summaries[declaration] = summary
}

result_summary :: proc(c: ^Compiler, declaration: Symbol_Id) -> (Result_Provenance, bool) {
	if is_contract_join(c, declaration) {
		return joined_result_summary(c, symbol_of(c, declaration).members)
	}
	if original, shifted := c.receiver_contract_of[declaration]; shifted {
		summary, found := result_summary(c, original)
		if !found {
			return Result_Provenance{}, false
		}
		return receiver_result_summary(c, summary), true
	}
	summary, found := c.result_summaries[declaration]
	if !found {
		return Result_Provenance{}, false
	}
	return summary^, true
}

// design.md "Borrowed callable views": the signature's summary behind a view
// added as parameter 0, which the result does not depend on: every `call` a
// view of the signature holds is checked to meet the contract, captures
// included. Rebuilt on each request, as a join's is, in `c.analysis_allocator`:
// a caller only reads it, and keeps what it needs in its graph.
@(private = "file")
receiver_result_summary :: proc(c: ^Compiler, from: Result_Provenance) -> Result_Provenance {
	out := from
	out.dependencies = receiver_dependencies(c, from.dependencies)
	out.content = make([]Result_Content_Provenance, len(from.content), c.analysis_allocator)
	for content, index in from.content {
		out.content[index] = Result_Content_Provenance{path = content.path, dependencies = receiver_dependencies(c, content.dependencies)}
	}
	out.region = receiver_region(from.region)
	out.region_content = make([]Prov_Region_Content, len(from.region_content), c.analysis_allocator)
	for content, index in from.region_content {
		out.region_content[index] = Prov_Region_Content{
			path = content.path, region = receiver_region(content.region), handle = content.handle, own = content.own,
		}
	}
	return out
}

@(private = "file")
receiver_dependencies :: proc(c: ^Compiler, from: Result_Dependencies) -> Result_Dependencies {
	out := from
	count := len(from.params) + 1
	out.params = make([]bool, count, c.analysis_allocator)
	out.param_paths = make([][]bool, count, c.analysis_allocator)
	out.param_loads = make([]u8, count, c.analysis_allocator)
	out.param_load_paths = make([][]Load_Paths, count, c.analysis_allocator)
	copy(out.params[1:], from.params)
	copy(out.param_paths[1:], from.param_paths)
	copy(out.param_loads[1:], from.param_loads)
	copy(out.param_load_paths[1:], from.param_load_paths)
	return out
}

// The view is no allocator, so it names no region of its own.
@(private)
receiver_region :: proc(from: Region_Set) -> Region_Set {
	out := from
	out.params, out.loaded = 0, 0
	params := from.params
	for index in next_region_param(&params) {
		if region_has_loaded_param(from, index) {
			region_add_loaded_param(&out, index + 1)
		} else {
			region_add_param(&out, index + 1)
		}
	}
	return out
}

// A join's members share a result type, so their summaries have one shape and
// the union goes entry by entry. Rebuilt on each request, since members may
// still be growing toward the fixed point, as `receiver_result_summary` is.
@(private = "file")
joined_result_summary :: proc(c: ^Compiler, members: []Symbol_Id) -> (Result_Provenance, bool) {
	out: Result_Provenance
	for member, index in members {
		summary, found := result_summary(c, member)
		if !found {
			return Result_Provenance{}, false
		}
		if index == 0 {
			out = new_result_provenance(c, len(summary.params), summary.content_type, len(summary.content) > 0, c.analysis_allocator)
		}
		merge_result_dependencies(&out.dependencies, summary.dependencies, c.analysis_allocator)
		region_merge(&out.region, summary.region)
		for &content, position in out.content {
			from := len(summary.content) == len(out.content) ? summary.content[position].dependencies : summary.dependencies
			merge_result_dependencies(&content.dependencies, from, c.analysis_allocator)
		}
		for &content, position in out.region_content {
			from := len(summary.region_content) == len(out.region_content) ? summary.region_content[position].region : summary.region
			region_merge(&content.region, from)
		}
	}
	return out, len(members) > 0
}

// Where parameter `index`'s paths at `depth` are kept, made on first use.
@(private)
load_paths_at :: proc(into: ^Result_Dependencies, index, depth: int, allocator: mem.Allocator) -> ^Load_Paths {
	if into.param_load_paths[index] == nil {
		into.param_load_paths[index] = make([]Load_Paths, CARRIER_DEPTH, allocator)
	}
	return &into.param_load_paths[index][depth - 1]
}

// Joins `from` into the paths of one depth. `fresh` says nothing has been joined
// yet. Each first path's last paths join only what reaches them along it.
@(private = "file")
join_load_paths :: proc(into: ^Load_Paths, from: Load_Paths, fresh: bool, allocator: mem.Allocator) {
	switch {
	case fresh:
		if from.last != nil {
			into.last = make([][]bool, len(from.last), allocator)
			for row, along in from.last {
				join_path_row(&into.last[along], row, true, allocator)
			}
		}
	case into.last == nil:
	case from.last == nil || len(from.last) != len(into.last):
		into.last = nil
	case:
		// Before `into.first` takes in `from.first`, it says which rows are new.
		for row, along in from.last {
			if load_goes_along(from.first, along) {
				join_path_row(&into.last[along], row, !load_goes_along(into.first, along), allocator)
			}
		}
	}
	join_path_row(&into.first, from.first, fresh, allocator)
	if into.first == nil && len(into.last) != 1 {
		into.last = nil // along every one of several paths
	}
}

// Joins `from` into a row of paths, where nil means every path. `fresh` says
// nothing has been joined yet.
@(private = "file")
join_path_row :: proc(into: ^[]bool, from: []bool, fresh: bool, allocator: mem.Allocator) {
	switch {
	case fresh:
		if from != nil {
			into^ = slice.clone(from, allocator)
		}
	case into^ == nil:
	case from == nil || len(from) != len(into^):
		into^ = nil
	case:
		for used, path in from {
			into[path] ||= used
		}
	}
}

@(private = "file")
merge_result_dependencies :: proc(into: ^Result_Dependencies, from: Result_Dependencies, allocator: mem.Allocator) {
	merge_provenance(into, from, allocator)
	into.precision |= from.precision
	for depths, index in from.param_loads {
		if index >= len(into.param_loads) {
			continue
		}
		for depth in 1 ..= CARRIER_DEPTH {
			bit := u8(1) << u8(depth - 1)
			if depths & bit == 0 {
				continue
			}
			fresh := into.param_loads[index] & bit == 0
			join_load_paths(load_paths_at(into, index, depth, allocator), result_load_paths(from, index, depth), fresh, allocator)
		}
		into.param_loads[index] |= depths
	}
	for wanted, index in from.params {
		if !wanted || index >= len(into.params) {
			continue
		}
		join_path_row(&into.param_paths[index], index < len(from.param_paths) ? from.param_paths[index] : nil, !into.params[index], allocator)
		into.params[index] = true
	}
}

// Adds `item` to a set kept as a slice; returns whether the set grew.
@(private)
set_add :: proc(set: ^[]$T, item: T, allocator: mem.Allocator) -> bool {
	if slice.contains(set^, item) {
		return false
	}
	grown := make([]T, len(set^) + 1, allocator)
	copy(grown, set^)
	grown[len(set^)] = item
	set^ = grown
	return true
}

// Joins the non-parameter components; returns whether `into` grew.
@(private)
merge_provenance :: proc(into: ^Result_Dependencies, from: Result_Dependencies, allocator: mem.Allocator) -> bool {
	changed := false
	for global in from.globals {
		changed = set_add(&into.globals, global, allocator) || changed
	}
	if from.static && !into.static   { into.static, changed  = true, true }
	if from.thread && !into.thread   { into.thread, changed  = true, true }
	if from.local && !into.local     { into.local, changed   = true, true }
	if from.unknown && !into.unknown { into.unknown, changed = true, true }
	return changed
}

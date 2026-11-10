// What a procedure's result may depend on (design.md "Temporaries and procedure
// boundaries", "Procedure result contracts"): the parameters, loads and paths it may
// borrow, the globals and regions it may name, and how a call substitutes, shifts
// or joins those summaries. Like the carrier shapes it is built on, it needs no
// solver state.
package lokec

import "core:mem"
import "core:slice"

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
	out.params, out.loaded, out.named, out.below = 0, 0, {}, {}
	params := from.params
	for index in next_region_param(&params) {
		region_add_param(&out, index + 1, param_read(from.named, index))
		if region_has_loaded_param(from, index) {
			region_add_loaded_param(&out, index + 1, param_read(from.below, index))
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

// Joins the non-parameter components; returns whether `into` grew.
@(private)
merge_provenance :: proc(into: ^Result_Dependencies, from: Result_Dependencies, allocator: mem.Allocator) -> bool {
	changed := false
	changed = set_join(&into.globals, from.globals, allocator) || changed
	if from.static && !into.static   { into.static, changed  = true, true }
	if from.thread && !into.thread   { into.thread, changed  = true, true }
	if from.local && !into.local     { into.local, changed   = true, true }
	if from.unknown && !into.unknown { into.unknown, changed = true, true }
	return changed
}

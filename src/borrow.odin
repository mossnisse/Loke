// Root and region provenance (design.md "Borrows and lifetimes" and "Allocator
// regions and region provenance"). Root provenance asks which storage a carrier
// borrows, whether it is still there, and whether competing accesses are
// compatible; region provenance asks which allocator region backs a value and
// whether anything survives a reset of it. Both run after every body is checked,
// over a disposable graph from `src/cfg.odin` built in a read-only mode.
//
// What is deliberately not checked is design.md's "What is not checked";
// `tests/run/m5b_trust_boundary.loke` keeps that list executable.
package lokec

import "core:fmt"
import "core:math/bits"
import "core:mem"
import "core:slice"

Root_Id :: distinct int
Loan_Id :: distinct int

NO_ROOT :: Root_Id(-1)
NO_LOAN :: Loan_Id(-1)

// design.md "Storage roots and borrow carriers". `Param` is the caller's
// storage reached through a borrowed parameter.
Root_Kind :: enum u8 {
	Local,
	Slice_Literal,
	Temporary,
	Static,       // `static` and file-scope storage
	Thread_Local, // outlives every frame on its own thread, nothing on another
	Materialized,
	Allocation,
	Param,
	Unknown,
}

// Whether the storage survives the procedure's return. Thread and process
// storage both do; `root_satisfies_retention` tells them apart.
root_outlives_body :: proc(kind: Root_Kind) -> bool {
	#partial switch kind {
	case .Local, .Slice_Literal, .Temporary:
		return false
	}
	return true
}

// How a diagnostic names a root: quoted source text, or the root's own
// description when the reader wrote no name.
root_label :: proc(root: Prov_Root) -> string {
	if root.symbol == INVALID_SYMBOL {
		return root.name
	}
	return fmt.tprintf("`%s`", root.name)
}

// The subject of a sentence about a root.
root_phrase :: proc(root: Prov_Root) -> string {
	if root.symbol != INVALID_SYMBOL {
		return root_label(root)
	}
	if (root.kind == .Unknown || root.kind == .Allocation) && root.name != "" {
		return root.name
	}
	return fmt.tprintf("the %s it borrows", root_kind_text(root.kind))
}

root_kind_text :: proc(kind: Root_Kind) -> string {
	switch kind {
	case .Local:         return "local"
	case .Slice_Literal: return "slice literal"
	case .Temporary:     return "temporary"
	case .Static:        return "static-duration storage"
	case .Thread_Local:  return "thread-duration storage"
	case .Materialized:  return "materialized constant"
	case .Allocation:    return "allocation"
	case .Param:         return "caller storage"
	case .Unknown:       return "unknown storage"
	}
	return "storage"
}

Prov_Root :: struct {
	kind:   Root_Kind,
	symbol: Symbol_Id,
	span:   Span,
	name:   string,
	// `Param`: which borrowed parameter, for substitution at a direct call.
	param_index: int,
	// `Allocation`: the region the storage came from. Empty means unrecorded,
	// which every reset reaches.
	region: Region_Set,
}

// ---------------------------------------------------------- projections --

Proj_Kind :: enum u8 {
	Field,
	Range, // half-open constant element range; an index `i` is [i, i+1)
	Deref,
	Wild,  // anything not statically distinct; overlaps every sibling
}

Proj_Step :: struct {
	precision: Precision_Loss,
	kind:      Proj_Kind,
	lo:        i64,
	hi:        i64,
}

proj_field :: proc(index: int) -> Proj_Step {
	return Proj_Step{kind = .Field, lo = i64(index)}
}

proj_range :: proc(lo, hi: i64) -> Proj_Step {
	return Proj_Step{kind = .Range, lo = lo, hi = hi}
}

proj_wild :: proc() -> Proj_Step {
	return Proj_Step{kind = .Wild}
}

// Two paths into one root overlap unless some step proves them disjoint, so a
// prefix overlaps everything below it.
paths_overlap :: proc(a, b: []Proj_Step) -> bool {
	shared := min(len(a), len(b))
	for index in 0 ..< shared {
		if !steps_overlap(a[index], b[index]) {
			return false
		}
	}
	return true
}

@(private = "file")
steps_overlap :: proc(a, b: Proj_Step) -> bool {
	if a.kind == .Wild || b.kind == .Wild || a.kind != b.kind {
		return true // nothing was proven distinct
	}
	switch a.kind {
	case .Field:
		return a.lo == b.lo
	case .Range:
		return a.lo < b.hi && b.lo < a.hi
	case .Deref:
		return true
	case .Wild:
		return true
	}
	return true
}

// ---------------------------------------------------------------- loans --

// One borrow. A `mutable` one excludes every competing access; an immutable one
// permits compatible reads.
Prov_Loan :: struct {
	root:    Root_Id,
	path:    []Proj_Step,
	mutable: bool,
	span:    Span,
	what:    string,
}

// A carrier value the analysis follows: a variable, parameter or expression
// temporary. Reaching loans are per slot, so overwriting one carrier ends only
// the value that was overwritten.
Prov_Slot :: struct {
	precision: Precision_Loss,
	symbol:    Symbol_Id,
	name:      string,
	span:      Span,
	// The place inside the value this slot holds, from `carrier_shape`; empty for
	// the whole value.
	path: []Proj_Step,
	// The leaf carrier's type at `path`, so a borrow published into it takes the
	// field's own capability. INVALID_TYPE for non-content and truncated paths.
	content_type: Type_Id,
	// The value type `path` belongs to; an unshaped dependency is not projected.
	content_shape: Type_Id,
	// `path` stands for every carrier below it, so a write joins rather than
	// replaces.
	content_truncated: bool,
	// The fresh borrow this temporary holds, weakened once its destination is
	// known, together with that borrow's own `.Access` event (so
	// `ro: []int = xs[0:2]` registers a read, not a write). The index is -1 when
	// there is none.
	fresh_loan:         Loan_Id,
	fresh_access_block: Block_Id,
	fresh_access_index: int,
	// A result held across its exit path's deferred statements.
	returned: bool,
}

// A slot holding no fresh borrow. Zero would name loan 0 and event 0.
empty_prov_slot :: proc(symbol: Symbol_Id) -> Prov_Slot {
	return Prov_Slot {
		symbol             = symbol,
		content_type       = INVALID_TYPE,
		content_shape      = INVALID_TYPE,
		fresh_loan         = NO_LOAN,
		fresh_access_block = NO_BLOCK,
		fresh_access_index = -1,
	}
}

// A carrier derived from an existing mutable carrier reborrows it, read-only or
// mutably: the source is suspended until the reborrow's last use (design.md
// "Weakening and reborrows").
Prov_Reborrow :: struct {
	source:  int,
	derived: int,
	span:    Span,
	mutable: bool,
}

// design.md "Storage roots and borrow carriers". `rawptr` and `[^]T` carry no
// checked provenance. A region provider is a carrier because an arena over a
// caller's buffer holds that buffer; a compiler-known view (a map view or
// iterator) holds only a raw pointer, so its marker is what makes it followed.
type_is_carrier :: proc(c: ^Compiler, type: Type_Id) -> bool {
	if type == INVALID_TYPE {
		return false
	}
	if type_is_region_provider(c, type) {
		return true
	}
	if info := underlying_info(c, type); info != nil && info.is_view {
		return true
	}
	#partial switch underlying_kind(c, type) {
	case .Pointer, .Slice, .String_View, .CString_View, .Any_View, .Dyn:
		return true
	}
	return false
}

// `^mut T`, `[]mut T` and `dyn mut I` are mutable borrows.
carrier_is_mutable :: proc(c: ^Compiler, type: Type_Id) -> bool {
	if type_is_region_provider(c, type) {
		return true // it writes into the buffer it was given
	}
	info := underlying_info(c, type)
	if info == nil {
		return false
	}
	// An adapter over a mutable view is one (design.md "Iteration adapters").
	if info.adapter_kind != .None && info.is_view {
		return info.mutable
	}
	#partial switch info.kind {
	case .Pointer, .Slice, .Dyn:
		return info.mutable
	}
	return false
}

// ---------------------------------------------------- retention targets --

// How long a destination that stores a borrow lives.
Retain_Kind :: enum u8 {
	None,
	Process,
	Thread,
	Caller,
}

// Whether a root's storage is still valid at a destination of this kind. An
// allocation may be released or reset first, a `Param` answers with its own
// `@(escape)` contract, and unknown provenance proves nothing.
root_satisfies_retention :: proc(kind: Root_Kind, into: Retain_Kind) -> bool {
	#partial switch kind {
	case .Local, .Slice_Literal, .Temporary, .Allocation:
		return false
	case .Static, .Materialized:
		return true
	case .Thread_Local:
		return into != .Process
	}
	return false
}

retain_kind_for_root :: proc(kind: Root_Kind) -> Retain_Kind {
	#partial switch kind {
	case .Static:       return .Process
	case .Thread_Local: return .Thread
	case .Param:        return .Caller
	}
	return .None
}

retain_kind_text :: proc(kind: Retain_Kind) -> string {
	switch kind {
	case .Process: return "process-lifetime storage"
	case .Thread:  return "thread-lifetime storage"
	case .Caller:  return "storage the caller owns"
	case .None:    return "storage"
	}
	return "storage"
}

// The level a parameter must be written at to be stored in this kind of place.
retain_kind_level :: proc(kind: Retain_Kind) -> Escape_Level {
	#partial switch kind {
	case .Process, .Thread:
		return .Static
	}
	return .Stored
}

// ------------------------------------------------------- escape levels --

// `@(escape=<level>)`: what a call may leave behind that depends on one
// parameter. Each level allows everything the one before it does.
Escape_Level :: enum u8 {
	None,   // nothing outlives the call, not even a result
	Result, // a result may borrow it (the default)
	Stored, // it may be retained in one of the call's mutable destinations
	Static, // it may be retained in process-lifetime storage
}

escape_level_name :: proc(level: Escape_Level) -> string {
	switch level {
	case .None:   return "none"
	case .Result: return "result"
	case .Stored: return "stored"
	case .Static: return "static"
	}
	return "result"
}

// The written `@(escape=<level>)`, a bare identifier. `valid` is false for any
// other value, which the caller reports.
attribute_escape_level :: proc(c: ^Compiler, attributes: []Attribute) -> (level: Escape_Level, written: bool, valid: bool) {
	for attribute in attributes {
		if len(attribute.path) != 1 || attribute.path[0].text != "escape" {
			continue
		}
		if attribute.value == nil {
			return .Result, true, false
		}
		ident, is_ident := attribute.value.(^Expr_Ident)
		if !is_ident {
			return .Result, true, false
		}
		switch ident.name {
		case "none":   return .None, true, true
		case "result": return .Result, true, true
		case "stored": return .Stored, true, true
		case "static": return .Static, true, true
		}
		return .Result, true, false
	}
	return .Result, false, true
}

// ----------------------------------------------------- carrier shapes --

// A carrier shape lists where inside a value a borrow can be, as `Proj_Step`
// paths. Shapes are finite: containers contribute one wildcard edge, depth past
// `CARRIER_DEPTH` becomes one truncated path, a shape wider than `CARRIER_WIDTH`
// collapses to one path, and a scalar subtree contributes nothing. Both queries
// run after all checking, so a cached answer never sees an incomplete type.
//
// design.md "Minimum provenance precision": these budgets are public guarantees.
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
		width := len(carrier_shape(c, info.key)) + len(carrier_shape(c, info.element))
		out = width > 0 && width <= MAP_KEY_PATH_LIMIT
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
	visiting := make(map[Type_Id]bool, 8, context.temp_allocator)
	reach := carrier_reach_walk(c, type, &visiting)
	c.carrier_reach[type] = reach
	return reach
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
		return {} // an ancestor is already exploring everything below this
	}
	if type_is_carrier(c, type) {
		return Carrier_Reach{any = true, mutable = carrier_is_mutable(c, type)}
	}
	info := underlying_info(c, type)
	if info == nil {
		return {}
	}
	visiting[type] = true
	defer delete_key(visiting, type)
	out: Carrier_Reach
	#partial switch info.kind {
	case .Struct:
		for field in info.fields {
			if sym := symbol_of(c, field); sym != nil {
				carrier_reach_join(&out, carrier_reach_walk(c, sym.type, visiting))
			}
		}
	case .Union:
		for variant in info.variants {
			carrier_reach_join(&out, carrier_reach_walk(c, variant, visiting))
		}
	case .Array, .Dynamic_Array:
		carrier_reach_join(&out, carrier_reach_walk(c, info.element, visiting))
	case .Map:
		carrier_reach_join(&out, carrier_reach_walk(c, info.key, visiting))
		carrier_reach_join(&out, carrier_reach_walk(c, info.element, visiting))
	}
	return out
}

@(private = "file")
carrier_reach_join :: proc(into: ^Carrier_Reach, from: Carrier_Reach) {
	into.any ||= from.any
	into.mutable ||= from.mutable
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
	carrier_shape_walk(c, type, nil, 0, &out)
	shape := out[:]
	if len(shape) > CARRIER_WIDTH {
		whole := make([]Carrier_Path, 1, c.semantic_allocator)
		whole[0] = carrier_truncated(nil, type_carries_borrow(c, type), {.Width})
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
) {
	if type == INVALID_TYPE {
		return
	}
	if type_is_carrier(c, type) {
		append(out, Carrier_Path {
			precision = path_precision(prefix),
			steps   = carrier_steps(c, prefix, nil),
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
		append(out, carrier_truncated(carrier_steps(c, prefix, nil), reach, {.Depth}))
		return
	}
	info := underlying_info(c, type)
	if info == nil {
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
			carrier_shape_walk(c, sym.type, carrier_steps(c, prefix, {step}), depth + 1, out)
		}
	case .Union:
		for variant in info.variants {
			carrier_shape_walk(c, variant, carrier_steps(c, prefix, {proj_wild()}), depth + 1, out)
		}
	case .Array:
		if info.count > 0 && info.count <= CARRIER_ARRAY_ELEMENTS {
			for index in 0 ..< i64(info.count) {
				step := proj_range(index, index + 1)
				carrier_shape_walk(c, info.element, carrier_steps(c, prefix, {step}), depth + 1, out)
			}
			return
		}
		step := proj_wild()
		if info.count > CARRIER_ARRAY_ELEMENTS { step.precision = {.Array_Elements} }
		carrier_shape_walk(c, info.element, carrier_steps(c, prefix, {step}), depth + 1, out)
	case .Dynamic_Array:
		carrier_shape_walk(c, info.element, carrier_steps(c, prefix, {proj_wild()}), depth + 1, out)
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
			base := carrier_steps(c, prefix, {step})
			carrier_shape_walk(c, info.key, carrier_steps(c, base, {proj_field(PROJ_MAP_KEY)}), depth + 2, out)
			carrier_shape_walk(c, info.element, carrier_steps(c, base, {proj_field(PROJ_MAP_VALUE)}), depth + 2, out)
		}
	}
}

@(private = "file")
carrier_truncated :: proc(steps: []Proj_Step, reach: Carrier_Reach, loss: Precision_Loss) -> Carrier_Path {
	return Carrier_Path{steps = steps, type = INVALID_TYPE, mutable = reach.mutable, truncated = true, precision = loss | path_precision(steps)}
}

@(private = "file")
carrier_steps :: proc(c: ^Compiler, prefix: []Proj_Step, extra: []Proj_Step) -> []Proj_Step {
	if len(prefix) == 0 && len(extra) == 0 {
		return nil
	}
	out := make([]Proj_Step, len(prefix) + len(extra), c.semantic_allocator)
	copy(out, prefix)
	copy(out[len(prefix):], extra)
	return out
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
	case .Any_View:     return "view"
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
	params:  []bool, // `Allocator` parameters of the enclosing body
	default: bool,   // the default provider's region
	unknown: bool,
	locals:  u64,    // one bit per local `mem.Arena` or `mem.Scratch`
	crowded: bool,   // more local providers than bits: may be any of them
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

// Whether both sets name exactly one region, and the same one.
regions_are_one :: proc(a, b: Region_Set) -> bool {
	if a.unknown || b.unknown || a.crowded || b.crowded || a.default != b.default || a.locals != b.locals {
		return false
	}
	count := int(a.default) + int(bits.count_ones(a.locals))
	for index in 0 ..< max(len(a.params), len(b.params)) {
		in_a := index < len(a.params) && a.params[index]
		if in_a != (index < len(b.params) && b.params[index]) {
			return false
		}
		count += int(in_a)
	}
	return count == 1
}

region_is_parameter_backed :: proc(set: Region_Set) -> bool {
	return slice.contains(set.params, true)
}

region_is_empty :: proc(set: Region_Set) -> bool {
	return !set.default && !set.unknown && !region_has_local(set) && !region_is_parameter_backed(set)
}

region_merge :: proc(into: ^Region_Set, from: Region_Set) {
	for value, index in from.params {
		if value && index < len(into.params) {
			into.params[index] = true
		}
	}
	into.default ||= from.default
	into.unknown ||= from.unknown
	into.locals |= from.locals
	into.crowded ||= from.crowded
}

@(private = "file")
merge_region_provenance :: proc(into: ^Region_Set, from: Region_Set) -> bool {
	changed := (!into.default && from.default) || (!into.unknown && from.unknown) ||
	           (from.locals & ~into.locals) != 0 || (!into.crowded && from.crowded)
	for value, index in from.params {
		if value && index < len(into.params) && !into.params[index] {
			changed = true
		}
	}
	region_merge(into, from)
	return changed
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
	static:       bool,
	thread:       bool,
	fresh:        bool, // a fresh allocation, which lets a returned pointer reach `free`
	fresh_region: Region_Set,
	local:        bool, // already an error in the callee
	unknown:      bool,
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
	region_content: []Prov_Region_Content, // per direct field
}

Proc_Summary :: struct {
	result: Result_Provenance,
}

@(private = "file")
new_result_dependencies :: proc(c: ^Compiler, param_count: int) -> Result_Dependencies {
	return Result_Dependencies {
		params      = make([]bool, param_count, c.semantic_allocator),
		param_paths = make([][]bool, param_count, c.semantic_allocator),
		fresh_region = Region_Set{params = make([]bool, param_count, c.semantic_allocator)},
	}
}

@(private = "file")
new_result_provenance :: proc(c: ^Compiler, param_count: int, type: Type_Id, with_content: bool) -> Result_Provenance {
	out := Result_Provenance {
		dependencies = new_result_dependencies(c, param_count),
		content_type = type,
		region = Region_Set{params = make([]bool, param_count, c.semantic_allocator)},
	}
	if !with_content {
		return out
	}
	if !type_is_carrier(c, type) {
		shape := carrier_shape(c, type)
		out.content = make([]Result_Content_Provenance, len(shape), c.semantic_allocator)
		for path, index in shape {
			summary_path := path
			summary_path.steps = make([]Proj_Step, len(path.steps), c.semantic_allocator)
			copy(summary_path.steps, path.steps)
			widen_summary_map_path(c, type, summary_path.steps)
			out.content[index] = Result_Content_Provenance {
				path = summary_path,
				dependencies = new_result_dependencies(c, param_count),
			}
			out.content[index].dependencies.precision = path_precision(summary_path.steps)
			out.precision |= out.content[index].dependencies.precision
		}
	}
	if info := underlying_info(c, type); info != nil && info.kind == .Struct {
		out.region_content = make([]Prov_Region_Content, len(info.fields), c.semantic_allocator)
		for _, index in info.fields {
			path := make([]Proj_Step, 1, c.semantic_allocator)
			path[0] = proj_field(index)
			out.region_content[index] = Prov_Region_Content {
				path = path,
				region = Region_Set{params = make([]bool, param_count, c.semantic_allocator)},
			}
		}
	}
	return out
}

// Constant map entries are numbered per body, so a summary path widens them to
// a wildcard step and keeps every other step.
@(private = "file")
widen_summary_map_path :: proc(c: ^Compiler, type: Type_Id, path: []Proj_Step) {
	if len(path) == 0 {
		return
	}
	info := underlying_info(c, type)
	if info == nil {
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
	case .Array, .Dynamic_Array:
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
// a result holding borrows borrows through `param`, and an owned result uses
// the default allocator.
set_synth_result_summary :: proc(c: ^Compiler, declaration: Symbol_Id, param: int) {
	sym := symbol_of(c, declaration)
	if sym == nil || sym.result == INVALID_TYPE || param >= len(sym.params) {
		return
	}
	summary := new(Proc_Summary, c.semantic_allocator)
	summary.result = new_result_provenance(c, len(sym.params), sym.result, false)
	summary.result.params[param] = type_carries_borrow(c, sym.result).any
	if type_is_managed(c, sym.result) {
		summary.result.region.default = true
	}
	c.result_summaries[declaration] = summary
}

result_summary :: proc(c: ^Compiler, declaration: Symbol_Id) -> (Result_Provenance, bool) {
	if is_contract_join(c, declaration) {
		return joined_result_summary(c, symbol_of(c, declaration).members)
	}
	summary, found := c.result_summaries[declaration]
	if !found {
		return Result_Provenance{}, false
	}
	return summary.result, true
}

// A join's members share a result type, so their summaries have one shape and
// the union goes entry by entry. Rebuilt on each request, since members may
// still be growing toward the fixed point.
@(private = "file")
joined_result_summary :: proc(c: ^Compiler, members: []Symbol_Id) -> (Result_Provenance, bool) {
	out: Result_Provenance
	for member, index in members {
		summary, found := result_summary(c, member)
		if !found {
			return Result_Provenance{}, false
		}
		if index == 0 {
			out = new_result_provenance(c, len(summary.params), summary.content_type, len(summary.content) > 0)
		}
		merge_result_dependencies(c, &out.dependencies, summary.dependencies)
		merge_region_provenance(&out.region, summary.region)
		for &content, position in out.content {
			from := position < len(summary.content) && len(summary.content) == len(out.content) ? summary.content[position].dependencies : summary.dependencies
			merge_result_dependencies(c, &content.dependencies, from)
		}
		for &content, position in out.region_content {
			from := position < len(summary.region_content) && len(summary.region_content) == len(out.region_content) ? summary.region_content[position].region : summary.region
			merge_region_provenance(&content.region, from)
		}
	}
	return out, len(members) > 0
}

@(private = "file")
merge_result_dependencies :: proc(c: ^Compiler, into: ^Result_Dependencies, from: Result_Dependencies) {
	merge_provenance(into, from)
	merge_precision(&into.precision, from.precision)
	for wanted, index in from.params {
		if !wanted || index >= len(into.params) {
			continue
		}
		paths := index < len(from.param_paths) ? from.param_paths[index] : nil
		if !into.params[index] {
			into.params[index] = true
			if paths != nil {
				into.param_paths[index] = make([]bool, len(paths), c.semantic_allocator)
				copy(into.param_paths[index], paths)
			}
		} else if into.param_paths[index] != nil {
			if paths == nil || len(paths) != len(into.param_paths[index]) {
				into.param_paths[index] = nil
			} else {
				for used, path in paths {
					into.param_paths[index][path] ||= used
				}
			}
		}
	}
}

// Joins the non-parameter components; returns whether `into` grew.
@(private = "file")
merge_provenance :: proc(into: ^Result_Dependencies, from: Result_Dependencies) -> bool {
	changed := false
	if from.static && !into.static   { into.static, changed  = true, true }
	if from.thread && !into.thread   { into.thread, changed  = true, true }
	if from.fresh && !into.fresh     { into.fresh, changed   = true, true }
	changed = merge_region_provenance(&into.fresh_region, from.fresh_region) || changed
	if from.local && !into.local     { into.local, changed   = true, true }
	if from.unknown && !into.unknown { into.unknown, changed = true, true }
	return changed
}

// ------------------------------------------------------------- the solver --

// Per-body solver state. `reach` (forward) is which loans each slot may hold,
// `live` (backward) which slots have a later use; a loan is live wherever a slot
// holding it is.
@(private = "file")
Prov_State :: struct {
	// Why a diagnostic may be imprecise; never consulted by the rules.
	precision:            []Precision_Loss,
	merged_precision:     Precision_Loss,
	diagnostic_precision: Precision_Loss,
	graph:   ^Flow_Graph,
	k:       ^Checker,
	slots:   int,
	loans:   int,
	// Bytes per slot row, one bit per loan. Bytes measured faster than 64-bit
	// words and than unpacked rows on the corpus.
	row_bytes: int,
	reach:   []u8,
	// A loan ended on some path to here, so `free` may release it twice. An
	// invalidation marks every loan of its root, even one another branch made,
	// so no check may skip a loan for being here.
	invalid: []bool,
	// A loan ended on every path to here. Checks skip only these, so an
	// invalidation that reaches its own loop head still meets the loan it ends.
	ended:   []bool,
	live:    []bool,
	uses:    []Span,
	merged:  []u8,
}

@(private = "file")
reach_row :: proc(state: ^Prov_State, buffer: []u8, slot: int) -> []u8 {
	return buffer[slot * state.row_bytes:(slot + 1) * state.row_bytes]
}

@(private = "file")
bit_get :: proc(row: []u8, index: int) -> bool {
	return row[index >> 3] & (1 << u8(index & 7)) != 0
}

// Iterates every still-valid loan held by a live slot, as (slot, loan index).
@(private = "file")
Live_Loans :: struct {
	state: ^Prov_State,
	slots: []int, // nil means every slot in `state`, filtered by `live`
	live:  []bool,
	at:    int,
	index: int,
	row:   []u8,
}

@(private = "file")
live_loans :: proc(state: ^Prov_State, live: []bool, slots: []int = nil) -> Live_Loans {
	return Live_Loans{state = state, live = live, slots = slots, at = -1, index = -1}
}

// `it.index < 0` means the next slot's row still has to be fetched.
@(private = "file")
next_live_loan :: proc(it: ^Live_Loans) -> (slot: int, index: int, ok: bool) {
	count := it.slots == nil ? it.state.slots : len(it.slots)
	for {
		if it.index < 0 {
			it.at += 1
			if it.at >= count {
				return 0, 0, false
			}
			if it.live != nil && !it.live[it.slots == nil ? it.at : it.slots[it.at]] {
				continue
			}
			it.row = reach_row(it.state, it.state.reach, it.slots == nil ? it.at : it.slots[it.at])
			it.index = 0
		}
		if it.index >= it.state.loans {
			it.index = -1
			continue
		}
		index = it.index
		it.index += 1
		if bit_get(it.row, index) && !it.state.ended[index] {
			return it.slots == nil ? it.at : it.slots[it.at], index, true
		}
	}
}

@(private = "file")
bit_mark :: proc(row: []u8, index: int) {
	row[index >> 3] |= 1 << u8(index & 7)
}

@(private = "file")
bytes_or :: proc(into: []u8, from: []u8) {
	for value, index in from {
		into[index] |= value
	}
}

// A body whose checking failed is skipped, so provenance adds no noise to it.
Checked_Body :: struct {
	literal: ^Expr_Proc,
	clean:   bool,
}

// The whole program's provenance, after every body is checked. Summaries settle
// first, over a worklist of direct callers, then each body's diagnostics run.
// One graph is built and released at a time.
analyze_program_provenance :: proc(k: ^Checker) {
	compute_global_writes(k)
	// Discovery records each body's callees. Source order may put a caller before
	// its callee, so every body is then visited once more before the worklist.
	for body in k.c.checked_bodies {
		if body.clean {
			_ = summarize_body(k, body.literal)
		}
	}
	queue := make([dynamic]^Expr_Proc, 0, len(k.c.checked_bodies), context.temp_allocator)
	queued := make([]bool, len(k.c.symbols), context.temp_allocator)
	callers := make(map[Symbol_Id][dynamic]^Expr_Proc, context.temp_allocator)
	for body in k.c.checked_bodies {
		if !body.clean {
			continue
		}
		append(&queue, body.literal)
		queued[int(body.literal.symbol)] = true
		for callee in k.c.result_summary_dependencies[body.literal.symbol] {
			if callee not_in callers {
				callers[callee] = make([dynamic]^Expr_Proc, 0, 4, context.temp_allocator)
			}
			append(&callers[callee], body.literal)
		}
	}
	for head := 0; head < len(queue); head += 1 {
		literal := queue[head]
		queued[int(literal.symbol)] = false
		if !summarize_body(k, literal) {
			continue
		}
		// Bound to a local first: iterating the map index directly miscompiles.
		affected := callers[literal.symbol]
		for caller in affected {
			index := int(caller.symbol)
			if !queued[index] {
				append(&queue, caller)
				queued[index] = true
			}
		}
	}
	check_proc_contracts(k)
	for body in k.c.checked_bodies {
		if body.clean {
			analyze_provenance(k, body.literal)
		}
	}
	for body in k.c.checked_bodies {
		if body.clean {
			check_declared_escape(k, body.literal)
		}
	}
}

// `@(escape=none)` contradicted by the body's own result summary.
@(private = "file")
check_declared_escape :: proc(k: ^Checker, literal: ^Expr_Proc) {
	sym := symbol_of(k.c, literal.symbol)
	if sym == nil {
		return
	}
	summary, found := k.c.result_summaries[literal.symbol]
	if !found {
		return
	}
	for id, index in sym.param_symbols {
		bound := symbol_of(k.c, id)
		if bound == nil || bound.escape != .None {
			continue
		}
		if index < len(summary.result.params) && summary.result.params[index] {
			errorf(
				k.c,
				bound.span,
				"L0644",
				"`%s` is written `@(escape=none)`, but the result of `%s` may borrow it",
				identifier_text(k.c, bound.name),
				identifier_text(k.c, sym.name),
			)
			add_precision_notes(k.c, bound.span, summary.result.precision)
		}
	}
}

// One round of one body's result equations; returns whether its summary grew.
@(private = "file")
summarize_body :: proc(k: ^Checker, literal: ^Expr_Proc) -> bool {
	sym := symbol_of(k.c, literal.symbol)
	if sym == nil || sym.result == INVALID_TYPE {
		return false
	}
	summary, found := k.c.result_summaries[literal.symbol]
	if !found {
		summary = new(Proc_Summary, k.c.semantic_allocator)
		summary.result = new_result_provenance(k.c, len(sym.param_symbols), sym.result, true)
		k.c.result_summaries[literal.symbol] = summary
	}
	defer free_all(k.c.analysis_allocator)
	graph := build_flow_graph(k, literal, k.c.analysis_allocator, .Prov_Summary)
	if graph == nil {
		return false
	}
	if _, known := k.c.result_summary_dependencies[literal.symbol]; !known {
		dependencies := make([]Symbol_Id, len(graph.summary_callees), k.c.semantic_allocator)
		copy(dependencies, graph.summary_callees[:])
		k.c.result_summary_dependencies[literal.symbol] = dependencies
	}
	state := Prov_State{graph = graph, k = k}
	if !prepare_state(&state) {
		return false
	}
	solve_reaching(&state)
	return collect_escape_provenance(&state, summary)
}

// Every loan that can reach a `return` becomes a possibility in the summary.
@(private = "file")
collect_escape_provenance :: proc(state: ^Prov_State, summary: ^Proc_Summary) -> bool {
	graph := state.graph
	changed := false
	for block in graph.blocks {
		if !block.prov_visited {
			continue
		}
		copy(state.reach, block.reach_entry)
		copy(state.precision, block.precision_entry)
		copy(state.invalid, block.invalid_entry)
		copy(state.ended, block.ended_entry)
		for event in block.prov {
			if event.kind == .Escape {
				into := &summary.result
				if !region_is_empty(event.region) {
					changed = merge_region_provenance(&into.region, event.region) || changed
				}
				for escaped in event.region_content {
					for &content in into.region_content {
						if !paths_equal(content.path, escaped.path) {
							continue
						}
						changed = merge_region_provenance(&content.region, escaped.region) || changed
					}
				}
				for source in event.sources {
					slot := graph.prov_slots[source]
					changed = merge_precision(&into.precision, state.precision[source]) || changed
					for &content in into.content {
						if slot.content_shape != into.content_type || paths_overlap(slot.path, content.path.steps) {
							changed = merge_precision(&content.dependencies.precision, state.precision[source]) || changed
						}
					}
					row := reach_row(state, state.reach, source)
					for index in 0 ..< state.loans {
						if !bit_get(row, index) {
							continue
						}
						loan := graph.loans[index]
						changed = merge_loan_provenance(state, &into.dependencies, loan) || changed
						for &content in into.content {
							if slot.content_shape == into.content_type && !paths_overlap(slot.path, content.path.steps) {
								continue
							}
							changed = merge_loan_provenance(state, &content.dependencies, loan) || changed
						}
					}
				}
			}
			run_prov_event(state, event, state.reach, state.invalid, state.ended)
		}
	}
	return changed
}

@(private = "file")
paths_equal :: proc(a, b: []Proj_Step) -> bool {
	if len(a) != len(b) {
		return false
	}
	for step, index in a {
		if step.kind != b[index].kind || step.lo != b[index].lo || step.hi != b[index].hi {
			return false
		}
	}
	return true
}

@(private = "file")
merge_loan_provenance :: proc(state: ^Prov_State, into: ^Result_Dependencies, loan: Prov_Loan) -> bool {
	root := state.graph.roots[int(loan.root)]
	one := Result_Dependencies{}
	switch root.kind {
	case .Param:
		if root.param_index >= 0 && root.param_index < len(into.params) {
			changed := merge_param_paths(state, into, root, loan)
			if !into.params[root.param_index] {
				into.params[root.param_index] = true
				changed = true
			}
			return changed
		}
		one.unknown = true
	case .Static, .Materialized:
		one.static = true
	case .Thread_Local:
		one.thread = true
	case .Allocation:
		one.fresh = true
		one.fresh_region = root.region
	case .Local, .Slice_Literal, .Temporary:
		one.local = true
	case .Unknown:
		one.unknown = true
	}
	return merge_provenance(into, one)
}

// Narrows a parameter dependency to the shape paths the loan overlaps, so a
// caller substitutes only those fields. Nil means the whole parameter.
@(private = "file")
merge_param_paths :: proc(
	state: ^Prov_State,
	into: ^Result_Dependencies,
	root: Prov_Root,
	loan: Prov_Loan,
) -> bool {
	index := root.param_index
	if index >= len(into.param_paths) {
		return false
	}
	sym := symbol_of(state.k.c, root.symbol)
	if sym == nil || type_is_carrier(state.k.c, sym.type) {
		changed := len(into.param_paths[index]) > 0
		into.param_paths[index] = nil
		return changed
	}
	shape := carrier_shape(state.k.c, sym.type)
	if len(shape) == 0 {
		changed := len(into.param_paths[index]) > 0
		into.param_paths[index] = nil
		return changed
	}
	if into.param_paths[index] == nil && into.params[index] {
		return false // already widened to the whole parameter
	}
	if into.param_paths[index] == nil {
		into.param_paths[index] = make([]bool, len(shape), state.k.c.semantic_allocator)
	}
	loan_path := make([]Proj_Step, len(loan.path), state.graph.alloc)
	copy(loan_path, loan.path)
	widen_summary_map_path(state.k.c, sym.type, loan_path)
	changed := merge_precision(&into.precision, path_precision(loan_path))
	matched := false
	for path, position in shape {
		if !paths_overlap(path.steps, loan_path) {
			continue
		}
		matched = true
		if !into.param_paths[index][position] {
			into.param_paths[index][position] = true
			changed = true
		}
	}
	if !matched {
		// The parameter's own storage (`&self.count`), which no carrier path
		// describes: depend on all of it.
		into.param_paths[index] = nil
		return true
	}
	return changed
}

// One concrete body's root and region diagnostics.
analyze_provenance :: proc(k: ^Checker, literal: ^Expr_Proc) {
	defer free_all(k.c.analysis_allocator)
	graph := build_flow_graph(k, literal, k.c.analysis_allocator, .Prov_Diagnose)
	if graph == nil {
		return
	}
	solve_provenance(k, graph)
}

@(private = "file")
solve_provenance :: proc(k: ^Checker, graph: ^Flow_Graph) {
	state := Prov_State{graph = graph, k = k}
	if !prepare_state(&state) {
		return
	}
	solve_reaching(&state)
	resolve_content_reads(&state)
	solve_loan_liveness(&state)
	report_provenance(&state)
}

// Sizes the per-block lattice storage; false when there is nothing to solve.
@(private = "file")
prepare_state :: proc(state: ^Prov_State) -> bool {
	graph := state.graph
	state.slots = len(graph.prov_slots)
	state.loans = len(graph.loans)
	if state.loans == 0 && !graph.has_region_event {
		return false
	}
	state.row_bytes = (state.loans + 7) / 8
	width := max(state.slots * state.row_bytes, 1)
	for block in graph.blocks {
		block.reach_entry = make([]u8, width, graph.alloc)
		block.precision_entry = make([]Precision_Loss, state.slots, graph.alloc)
		block.precision_exit = make([]Precision_Loss, state.slots, graph.alloc)
		block.reach_exit = make([]u8, width, graph.alloc)
		block.invalid_entry = make([]bool, state.loans, graph.alloc)
		block.invalid_exit = make([]bool, state.loans, graph.alloc)
		block.ended_entry = make([]bool, state.loans, graph.alloc)
		block.ended_exit = make([]bool, state.loans, graph.alloc)
		block.live_entry = make([]bool, max(state.slots, 1), graph.alloc)
		block.live_exit = make([]bool, max(state.slots, 1), graph.alloc)
		block.use_entry = make([]Span, max(state.slots, 1), graph.alloc)
		block.use_exit = make([]Span, max(state.slots, 1), graph.alloc)
		block.prov_visited = false
	}
	state.reach = make([]u8, width, graph.alloc)
	state.precision = make([]Precision_Loss, state.slots, graph.alloc)
	state.invalid = make([]bool, state.loans, graph.alloc)
	state.ended = make([]bool, state.loans, graph.alloc)
	state.live = make([]bool, max(state.slots, 1), graph.alloc)
	state.uses = make([]Span, max(state.slots, 1), graph.alloc)
	state.merged = make([]u8, max(state.row_bytes, 1), graph.alloc)
	return true
}

// Forward: which loans each carrier slot may hold, and which loans an earlier
// invalidation already ended.
@(private = "file")
solve_reaching :: proc(state: ^Prov_State) {
	graph := state.graph
	queue := make([dynamic]Block_Id, 0, len(graph.blocks), graph.alloc)
	queued := make([]bool, len(graph.blocks), graph.alloc)
	append(&queue, Block_Id(0))
	queued[0] = true
	for head := 0; head < len(queue); head += 1 {
		id := int(queue[head])
		block := graph.blocks[id]
		queued[id] = false
		mem.zero_slice(state.reach)
		mem.zero_slice(state.precision)
		mem.zero_slice(state.invalid)
		mem.zero_slice(state.ended)
		if id != 0 {
			seen := false
			for predecessor in block.preds {
				source := graph.blocks[predecessor]
				if !source.prov_visited {
					continue
				}
				bytes_or(state.reach, source.reach_exit)
				for loss, slot in source.precision_exit { state.precision[slot] |= loss }
				for value, index in source.invalid_exit {
					state.invalid[index] ||= value
				}
				// A predecessor not visited yet stays out of the meet.
				if seen {
					for value, index in source.ended_exit {
						state.ended[index] &&= value
					}
				} else {
					copy(state.ended, source.ended_exit)
				}
				seen = true
			}
			if !seen {
				continue
			}
		} else {
			// A borrowed parameter arrives already holding the caller's root.
			for entry in graph.entry_defs {
				bit_mark(reach_row(state, state.reach, entry.slot), int(entry.loan))
				state.precision[entry.slot] |= graph.prov_slots[entry.slot].precision
			}
		}
		copy(block.reach_entry, state.reach)
		copy(block.precision_entry, state.precision)
		copy(block.invalid_entry, state.invalid)
		copy(block.ended_entry, state.ended)
		for event in block.prov {
			run_prov_event(state, event, state.reach, state.invalid, state.ended)
		}
		if block.prov_visited &&
		   slice.equal(block.precision_exit, state.precision) &&
		   slice.equal(block.reach_exit, state.reach) &&
		   slice.equal(block.invalid_exit, state.invalid) &&
		   slice.equal(block.ended_exit, state.ended) {
			continue
		}
		copy(block.reach_exit, state.reach)
		copy(block.precision_exit, state.precision)
		copy(block.invalid_exit, state.invalid)
		copy(block.ended_exit, state.ended)
		block.prov_visited = true
		for successor in block.succs {
			if !queued[int(successor)] {
				append(&queue, successor)
				queued[int(successor)] = true
			}
		}
	}
}

@(private = "file")
run_prov_event :: proc(state: ^Prov_State, event: Prov_Event, reach: []u8, invalid, ended: []bool) {
	graph := state.graph
	end_loans(state, event, reach, invalid)
	end_loans(state, event, reach, ended)
	#partial switch event.kind {
	case .Def:
		mem.zero_slice(state.merged)
		loss := graph.prov_slots[event.slot].precision | path_precision(event.path) | event.precision
		for source in event.sources {
			loss |= state.precision[source]
			bytes_or(state.merged, reach_row(state, reach, source))
		}
		if event.loan != NO_LOAN {
			loss |= path_precision(graph.loans[int(event.loan)].path)
			bit_mark(state.merged, int(event.loan))
		}
		copy(reach_row(state, reach, event.slot), state.merged)
		state.precision[event.slot] = loss
	case .Load:
		load_pointee_content(state, event, reach)
	case .Publish:
		// Joins into every root the carrier may name.
		mem.zero_slice(state.merged)
		state.merged_precision = path_precision(event.path)
		for source in event.sources {
			state.merged_precision |= state.precision[source]
			bytes_or(state.merged, reach_row(state, reach, source))
		}
		for slot in event.into {
			row := reach_row(state, reach, slot)
			for index in 0 ..< state.loans {
				if !bit_get(row, index) || ended[index] {
					continue
				}
				publish_into_loan(state, reach, graph.loans[index])
			}
		}
	}
}

// Which loans an event ends or starts afresh. It runs over the loans ended on
// some path and over those ended on every path alike.
@(private = "file")
end_loans :: proc(state: ^Prov_State, event: Prov_Event, reach: []u8, invalid: []bool) {
	graph := state.graph
	#partial switch event.kind {
	case .Def:
		// A creation site that runs again starts a new, valid instance.
		if event.loan != NO_LOAN {
			invalid[int(event.loan)] = false
		}
	case .Live:
		// A loop head re-establishes the loans, so an invalidation inside the body
		// does not reach its entry through the back edge.
		if !event.revives {
			break
		}
		for source in event.sources {
			row := reach_row(state, reach, source)
			for index in 0 ..< state.loans {
				if bit_get(row, index) {
					invalid[index] = false
				}
			}
		}
	case .Access:
		if event.access != .Invalidate {
			break
		}
		for loan, index in graph.loans {
			if loan.root == event.root && paths_overlap(loan.path, event.path) {
				invalid[index] = true
			}
		}
	case .Root_End:
		for loan, index in graph.loans {
			if loan.root == event.root {
				invalid[index] = true
			}
		}
	case .Reset:
		for loan, index in graph.loans {
			if reset_ends_root(graph.roots[int(loan.root)], event) {
				invalid[index] = true
			}
		}
	case .Free:
		// Every loan of the released allocation ends.
		for source in event.sources {
			row := reach_row(state, reach, source)
			for index in 0 ..< state.loans {
				if !bit_get(row, index) {
					continue
				}
				root := graph.loans[index].root
				for loan, other in graph.loans {
					if loan.root == root {
						invalid[other] = true
					}
				}
			}
		}
	}
}

// A load reads the slots at the pointee path through the addressing loans and
// copies their dependencies. Storage with no local content keeps the loan.
@(private = "file")
load_pointee_content :: proc(state: ^Prov_State, event: Prov_Event, reach: []u8, reads: ^[dynamic]int = nil) {
	graph := state.graph
	mem.zero_slice(state.merged)
	loss := graph.prov_slots[event.slot].precision | path_precision(event.path)
	for carrier in event.into {
		row := reach_row(state, reach, carrier)
		for loan, loan_index in graph.loans {
			if !bit_get(row, loan_index) {
				continue
			}
			root := graph.roots[int(loan.root)]
			sym := symbol_of(graph.k.c, root.symbol)
			found := false
			if sym != nil && !(root.kind == .Param && type_is_carrier(graph.k.c, sym.type)) {
				slots := graph.content_by_symbol[root.symbol]
				bare: [1]int
				if index, exists := graph.slot_by_symbol[root.symbol]; exists {
					bare[0] = index
					slots = bare[:]
				}
				for index in slots {
					slot := graph.prov_slots[index]
					if !paths_overlap(slot.path, loan.path) {
						continue
					}
					suffix := slot.path[min(len(loan.path), len(slot.path)):]
					if !paths_overlap(suffix, event.path) {
						continue
					}
					found = true
					loss |= state.precision[index]
					bytes_or(state.merged, reach_row(state, reach, index))
					if reads != nil {
						seen := false
						for existing in reads^ {
							seen ||= existing == index
						}
						if !seen {
							append(reads, index)
						}
					}
				}
			}
			if !found {
				loss |= state.precision[carrier] | path_precision(loan.path)
				bit_mark(state.merged, loan_index)
			}
		}
	}
	copy(reach_row(state, reach, event.slot), state.merged)
	state.precision[event.slot] = loss
}

// Records which slots each indirect read uses before the backward pass, so a
// mutation before `p^.view` conflicts with the borrow held in the pointee.
@(private = "file")
resolve_content_reads :: proc(state: ^Prov_State) {
	if !state.graph.has_content_load {
		return
	}
	for block in state.graph.blocks {
		if !block.prov_visited {
			continue
		}
		copy(state.reach, block.reach_entry)
		copy(state.precision, block.precision_entry)
		copy(state.invalid, block.invalid_entry)
		copy(state.ended, block.ended_entry)
		for &event in block.prov {
			if event.kind == .Load {
				reads := make([dynamic]int, 0, 4, state.graph.alloc)
				load_pointee_content(state, event, state.reach, &reads)
				event.sources = reads[:]
			} else {
				run_prov_event(state, event, state.reach, state.invalid, state.ended)
			}
		}
	}
}

// Backward: which slots have a later use, and where. A loan lives until the
// last use of every copy.
@(private = "file")
solve_loan_liveness :: proc(state: ^Prov_State) {
	graph := state.graph
	queue := make([dynamic]Block_Id, 0, len(graph.blocks), graph.alloc)
	queued := make([]bool, len(graph.blocks), graph.alloc)
	for index := len(graph.blocks) - 1; index >= 0; index -= 1 {
		append(&queue, Block_Id(index))
		queued[index] = true
	}
	for head := 0; head < len(queue); head += 1 {
		id := int(queue[head])
		block := graph.blocks[id]
		queued[id] = false
		mem.zero_slice(state.live)
		slice.fill(state.uses, no_span())
		for successor in block.succs {
			target := graph.blocks[successor]
			for value, index in target.live_entry {
				if value && !state.live[index] {
					state.live[index] = true
					state.uses[index] = target.use_entry[index]
				}
			}
		}
		copy(block.live_exit, state.live)
		copy(block.use_exit, state.uses)
		for index := len(block.prov) - 1; index >= 0; index -= 1 {
			run_live_event(block.prov[index], state.live, state.uses)
		}
		if slice.equal(block.live_entry, state.live) {
			continue
		}
		copy(block.live_entry, state.live)
		copy(block.use_entry, state.uses)
		for predecessor in block.preds {
			if !queued[int(predecessor)] {
				append(&queue, predecessor)
				queued[int(predecessor)] = true
			}
		}
	}
}

// Joins `state.merged` into the slots holding what one loan's storage contains.
@(private = "file")
publish_into_loan :: proc(state: ^Prov_State, reach: []u8, loan: Prov_Loan) {
	graph := state.graph
	root := graph.roots[int(loan.root)]
	if root.symbol == INVALID_SYMBOL {
		return
	}
	for slot, index in graph.prov_slots {
		if slot.symbol != root.symbol {
			continue
		}
		if paths_overlap(slot.path, loan.path) {
			bytes_or(reach_row(state, reach, index), state.merged)
			state.precision[index] |= state.merged_precision | slot.precision | path_precision(loan.path)
		}
	}
}

@(private = "file")
run_live_event :: proc(event: Prov_Event, live: []bool, uses: []Span) {
	#partial switch event.kind {
	case .Def:
		live[event.slot] = false
	case .Load:
		live[event.slot] = false
		for source in event.sources {
			live[source] = true
			uses[source] = event.span
		}
	case .Live, .Escape, .Free:
		for source in event.sources {
			live[source] = true
			uses[source] = event.span
		}
	}
}

// ------------------------------------------------------------ reporting --

@(private = "file")
report_provenance :: proc(state: ^Prov_State) {
	graph := state.graph
	// One expression gets one borrow diagnostic: a receiver and the call it
	// starts, or two rules meeting the same mistake, report once.
	reported := make(map[[2]u32]bool, 8, graph.alloc)
	for block in graph.blocks {
		if !block.prov_visited || len(block.prov) == 0 {
			continue
		}
		count := len(block.prov)
		// Liveness after each event that consults it, replayed from the block exit.
		live_after := make([][]bool, count, graph.alloc)
		use_after := make([][]Span, count, graph.alloc)
		live := make([]bool, max(state.slots, 1), graph.alloc)
		uses := make([]Span, max(state.slots, 1), graph.alloc)
		copy(live, block.live_exit)
		copy(uses, block.use_exit)
		for index := count - 1; index >= 0; index -= 1 {
			#partial switch block.prov[index].kind {
			case .Access, .Root_End, .Reset, .Free, .Live, .Load:
				live_after[index] = slice.clone(live, graph.alloc)
				use_after[index] = slice.clone(uses, graph.alloc)
			}
			run_live_event(block.prov[index], live, uses)
		}

		copy(state.reach, block.reach_entry)
		copy(state.precision, block.precision_entry)
		copy(state.invalid, block.invalid_entry)
		copy(state.ended, block.ended_entry)
		for event, index in block.prov {
			// A temporary's end has no span of its own and is never merged.
			at := [2]u32{event.span.file, event.span.lo}
			placed := event.span != Span{}
			if !placed || !reported[at] {
				before := len(state.k.c.diagnostics)
				check_prov_event(state, event, live_after[index], use_after[index])
				if placed && len(state.k.c.diagnostics) > before {
					reported[at] = true
				}
			}
			run_prov_event(state, event, state.reach, state.invalid, state.ended)
		}
	}
}

// Whether a reset ends storage rooted here: an allocation in a region the reset
// may name, or one whose region was never recorded.
@(private = "file")
reset_ends_root :: proc(root: Prov_Root, event: Prov_Event) -> bool {
	if root.kind != .Allocation {
		return false
	}
	return region_is_empty(root.region) || regions_may_overlap(root.region, event.region)
}

// Whether an access conflicts with a live loan of its root.
@(private = "file")
access_conflicts :: proc(loan: Prov_Loan, event: Prov_Event) -> bool {
	if loan.root != event.root || !paths_overlap(loan.path, event.path) {
		return false
	}
	return event.access != .Read || loan.mutable
}

@(private = "file")
check_prov_event :: proc(state: ^Prov_State, event: Prov_Event, live: []bool, uses: []Span) {
	graph := state.graph
	before := len(state.k.c.diagnostics)
	state.diagnostic_precision = path_precision(event.path)
	for source in event.sources { state.diagnostic_precision |= state.precision[source] }
	defer {
		if len(state.k.c.diagnostics) > before {
			add_precision_notes(state.k.c, event.span, state.diagnostic_precision)
			if event.region.crowded {
				add_notef(state.k.c, event.span, "provenance precision limit: more than 64 local allocator regions merge region identities")
			}
		}
	}
	#partial switch event.kind {
	case .Access:
		it := live_loans(state, live)
		for slot, index in next_live_loan(&it) {
			loan := graph.loans[index]
			if !access_conflicts(loan, event) {
				continue
			}
			state.diagnostic_precision |= state.precision[slot]
			report_borrow_conflict(state, event, loan, uses[slot])
			return
		}
	case .Live, .Load:
		// A reborrow suspends its source until its own last use, and the last use
		// of whatever was reborrowed from it in turn.
		for source in event.sources {
			if reborrow, derived, found := live_reborrow_of(state, source, live); found {
				report_suspended_reborrow(state, event, reborrow, uses[derived])
				state.diagnostic_precision |= state.precision[derived]
				return
			}
		}
	case .Root_End:
		it := live_loans(state, live)
		for slot, index in next_live_loan(&it) {
			loan := graph.loans[index]
			// A result borrowing frame storage is the `Escape` event's error.
			if loan.root != event.root || graph.prov_slots[slot].returned {
				continue
			}
			state.diagnostic_precision |= state.precision[slot]
			report_root_outlived(state, event, loan, uses[slot])
			return
		}
	case .Escape:
		// A result backed by a region created here, as an owner or an allocation.
		escape_region := Region_Set{params = make([]bool, max(graph.param_count, 1), graph.alloc)}
		region_merge(&escape_region, event.region)
		for source in event.sources {
			row := reach_row(state, state.reach, source)
			for index in 0 ..< state.loans {
				if !bit_get(row, index) || state.ended[index] {
					continue
				}
				root := graph.roots[int(graph.loans[index].root)]
				if root.kind == .Allocation {
					region_merge(&escape_region, root.region)
				}
			}
		}
		if region_has_local(escape_region) {
			name := event.name
			if name == "" {
				name = prov_region_name(graph, escape_region)
			}
			if name != "" {
				errorf(
					state.k.c, event.span, "L0592",
					"this result is backed by `%s`, an allocator region that ends when this procedure returns",
					name,
				)
			} else {
				errorf(
					state.k.c, event.span, "L0592",
					"this result is backed by an allocator region created in this procedure, which ends when it returns",
				)
			}
			return
		}
		// A borrow of storage that ends with the frame.
		for source in event.sources {
			row := reach_row(state, state.reach, source)
			for index in 0 ..< state.loans {
				if !bit_get(row, index) || state.ended[index] {
					continue
				}
				loan := graph.loans[index]
				root := graph.roots[int(loan.root)]
				if root_outlives_body(root.kind) {
					continue
				}
				// The same hedge: with element provenance merged, the compiler
				// cannot tell that this result does not depend on the local.
				escaping := "this %s cannot be returned: %s ends when this procedure returns"
				if state.diagnostic_precision != {} {
					escaping = "this %s may depend on %s, which ends when this procedure returns"
				}
				errorf(
					state.k.c, event.span, "L0526", escaping,
					loan.what, root_phrase(root),
				)
				if root.symbol != INVALID_SYMBOL && root.span.file != NO_FILE {
					add_notef(state.k.c, root.span, "%s is declared here", root_label(root))
				}
				add_notef(state.k.c, loan.span, "the %s is created here", loan.what)
				add_plain_call_note(state, loan)
				return
			}
		}
	case .Retain:
		check_retention(state, event)
	case .Reset:
		check_region_reset(state, event, live, uses)
	case .Region_Escape:
		// An owner stored in longer-lived storage than its region.
		if region_has_local(event.region) {
			errorf(
				state.k.c,
				event.span,
				"L0536",
				"`%s` is backed by an allocator region created in this procedure, so it cannot be stored in %s, which outlives that region",
				event.verb,
				event.name,
			)
			return
		}
		errorf(
			state.k.c,
			event.span,
			"L0536",
			"`%s` is backed by an allocator region this procedure received, so it cannot be stored in %s, which outlives that region",
			event.verb,
			event.name,
		)
	case .Free:
		if roots, ok := check_free_provenance(state, event); ok {
			for root in roots {
				report_live_dependants(state, root, event.span, live, uses, "released")
			}
		}
	}
}

// The first reborrow of `source` that a live slot still depends on, directly or
// through reborrows of the reborrow, and that live slot.
@(private = "file")
live_reborrow_of :: proc(state: ^Prov_State, source: int, live: []bool) -> (Prov_Reborrow, int, bool) {
	graph := state.graph
	visited := make(map[int]bool, 8, context.temp_allocator)
	pending := make([dynamic]int, 0, 8, context.temp_allocator)
	for reborrow in graph.reborrows {
		if reborrow.source != source {
			continue
		}
		clear(&pending)
		clear(&visited)
		append(&pending, reborrow.derived)
		for len(pending) > 0 {
			slot := pop(&pending)
			if visited[slot] {
				continue
			}
			visited[slot] = true
			// An overwritten intermediate no longer overlaps `source`, but something
			// derived from its previous value still can.
			if live[slot] && prov_slots_overlap(state, source, slot) {
				return reborrow, slot, true
			}
			for next in graph.reborrows {
				if next.source == slot {
					append(&pending, next.derived)
				}
			}
		}
	}
	return {}, -1, false
}

// The source is suspended only while both slots' current values share a valid
// loan, so overwriting either one ends the reborrow.
@(private = "file")
prov_slots_overlap :: proc(state: ^Prov_State, source_slot, derived_slot: int) -> bool {
	source := reach_row(state, state.reach, source_slot)
	derived := reach_row(state, state.reach, derived_slot)
	for index in 0 ..< state.loans {
		if bit_get(source, index) && bit_get(derived, index) && !state.ended[index] {
			return true
		}
	}
	return false
}

// A reset is rejected when the body may not reset that region at all, or when an
// owner or borrow of the region is still live.
@(private = "file")
check_region_reset :: proc(state: ^Prov_State, event: Prov_Event, live: []bool, uses: []Span) {
	graph := state.graph
	if event.access == .Invalidate && !event.reset_covered {
		errorf(
			state.k.c,
			event.span,
			"L0538",
			"this resets a region that existed before the call, so the allocator must arrive through an `@(allocator_reset)` parameter",
		)
		return
	}
	if event.access == .Write && !event.reset_covered {
		// A reset-capable call given one of this body's own allocators.
		if event.name != "" {
			errorf(
				state.k.c,
				event.span,
				"L0538",
				"this call may reset `%s`, so `%s` must be marked `@(allocator_reset)`",
				event.name,
				event.name,
			)
		} else {
			errorf(
				state.k.c,
				event.span,
				"L0538",
				"this call may reset a pre-existing or unknown allocator region, so the reset cannot be hidden in this procedure",
			)
		}
		return
	}
	if event.verb != "" {
		errorf(
			state.k.c,
			event.span,
			"L0537",
			"%s would end the region backing `%s`, which is still live here",
			event.ends != "" ? event.ends : "this reset",
			event.verb,
		)
		add_notef(state.k.c, event.owner_span, "`%s` is declared here and is cleaned up after this point", event.verb)
		return
	}
	it := live_loans(state, live)
	for slot, index in next_live_loan(&it) {
		loan := graph.loans[index]
		if !reset_ends_root(graph.roots[int(loan.root)], event) {
			continue
		}
		errorf(
			state.k.c,
			event.span,
			"L0537",
			"this reset ends every allocation in the region, but a %s of one of them is still in use",
			loan.what,
		)
		state.diagnostic_precision |= state.precision[slot]
		add_notef(state.k.c, loan.span, "the %s is created here", loan.what)
		add_use_note(state, uses[slot])
		return
	}
}

// Any loan of `root` that still has a later use when `root` ends here.
@(private = "file")
report_live_dependants :: proc(
	state: ^Prov_State,
	root: Root_Id,
	span: Span,
	live: []bool,
	uses: []Span,
	verb: string,
) {
	graph := state.graph
	it := live_loans(state, live)
	for slot, index in next_live_loan(&it) {
		loan := graph.loans[index]
		if loan.root != root {
			continue
		}
		descriptor := graph.roots[int(root)]
		errorf(
			state.k.c,
			span,
			"L0512",
			"%s cannot be %s here: a %s of it is still in use",
			root_label(descriptor),
			verb,
			loan.what,
		)
		add_borrow_notes(state, descriptor, loan, uses[slot])
		state.diagnostic_precision |= state.precision[slot]
		return
	}
}

@(private = "file")
report_borrow_conflict :: proc(state: ^Prov_State, event: Prov_Event, loan: Prov_Loan, later: Span) {
	k := state.k
	root := state.graph.roots[int(loan.root)]
	// A merged dependency may be the only reason these two look like one place,
	// so the message claims no more than the analysis knows (design.md "Minimum
	// provenance precision"); the notes added after it say which budget merged
	// them and how to keep the two apart.
	merged := state.diagnostic_precision != {}
	invalidated := "%s cannot be %s here: a %s %s of it is still in use"
	conflicting := "this %s of %s is not compatible with the %s %s of it that is still in use"
	if merged {
		invalidated = "%s cannot be %s here: a %s %s of it may still be in use"
		conflicting = "this %s of %s may overlap the %s %s of it that is still in use"
	}
	if event.access == .Invalidate {
		errorf(
			k.c,
			event.span,
			"L0512",
			invalidated,
			root_label(root),
			event.verb == "" ? "invalidated" : event.verb,
			loan.mutable ? "mutable" : "read-only",
			loan.what,
		)
	} else {
		errorf(
			k.c,
			event.span,
			"L0511",
			conflicting,
			event.access == .Write ? "write" : "read",
			root_label(root),
			loan.mutable ? "mutable" : "read-only",
			loan.what,
		)
	}
	add_borrow_notes(state, root, loan, later)
}

@(private = "file")
report_suspended_reborrow :: proc(
	state: ^Prov_State,
	event: Prov_Event,
	reborrow: Prov_Reborrow,
	later: Span,
) {
	k := state.k
	source := state.graph.prov_slots[reborrow.source]
	derived := state.graph.prov_slots[reborrow.derived]
	capability := reborrow.mutable ? "mutable" : "read-only"
	errorf(
		k.c,
		event.span,
		"L0641",
		"`%s` cannot be used here: a %s reborrow of it is still in use",
		source.name,
		capability,
	)
	if derived.name != "" {
		add_notef(k.c, reborrow.span, "`%s` reborrows it %s here", derived.name, reborrow.mutable ? "mutably" : "read-only")
	} else {
		add_notef(k.c, reborrow.span, "the %s reborrow is taken here", capability)
	}
	add_notef(k.c, later, "and is still used here, which keeps the reborrow live")
}

@(private = "file")
report_root_outlived :: proc(state: ^Prov_State, event: Prov_Event, loan: Prov_Loan, later: Span) {
	k := state.k
	root := state.graph.roots[int(loan.root)]
	label := root_label(root)
	// As in `report_borrow_conflict`: a merged dependency may be the only reason
	// this value looks like a borrow of that storage.
	anonymous := "this %s is used after %s has ended"
	named := "this %s is used after %s, the %s it borrows, has ended"
	if state.diagnostic_precision != {} {
		anonymous = "this %s may be used after %s has ended"
		named = "this %s may be used after %s, the %s it borrows, has ended"
	}
	// Points at the later use: the storage ends at no written operation.
	if root.symbol == INVALID_SYMBOL {
		errorf(
			k.c,
			later.file == NO_FILE ? event.span : later,
			"L0513",
			anonymous,
			loan.what,
			label,
		)
	} else {
		errorf(
			k.c,
			later.file == NO_FILE ? event.span : later,
			"L0513",
			named,
			loan.what,
			label,
			root_kind_text(root.kind),
		)
	}
	if root.span.file != NO_FILE {
		if root.kind == .Temporary {
			add_notef(k.c, root.span, "%s ends with the statement that created it", label)
		} else {
			add_notef(k.c, root.span, "%s is declared here and ends with its scope", label)
		}
	}
	add_notef(k.c, loan.span, "the %s is created here", loan.what)
}

// design.md "Procedure result contracts": a loan created in the arguments of a
// call through a type with no result contract reached the result only because
// that type states no bound. Names the innermost such call.
@(private = "file")
add_plain_call_note :: proc(state: ^Prov_State, loan: Prov_Loan) {
	found: ^Expr_Call
	for call in state.graph.plain_calls {
		if call.span.file == loan.span.file && call.span.lo <= loan.span.lo && loan.span.hi <= call.span.hi &&
		   (found == nil || call.span.hi - call.span.lo < found.span.hi - found.span.lo) {
			found = call
		}
	}
	if found != nil {
		add_notef(
			state.k.c, found.span,
			"a call through `%s` may return a borrow of any argument, because that type states no result bound; `@(escape=none)` on a parameter excludes it",
			type_name(state.k.c, call_proc_type(state.k.c, found)),
		)
	}
}

// Notes for the root, the borrow's creation, and the later use keeping it live.
@(private = "file")
add_borrow_notes :: proc(state: ^Prov_State, root: Prov_Root, loan: Prov_Loan, later: Span) {
	k := state.k
	if root.symbol != INVALID_SYMBOL && root.span.file != NO_FILE {
		add_notef(
			k.c,
			root.span,
			"%s is the %s this %s borrows",
			root_label(root),
			root_kind_text(root.kind),
			loan.what,
		)
	}
	add_notef(k.c, loan.span, "the %s is created here", loan.what)
	add_use_note(state, later)
}

// The later use keeping a borrow live. One at a declaration is that local's
// `drop` hook, run when its scope ends.
@(private = "file")
add_use_note :: proc(state: ^Prov_State, later: Span) {
	if later.file == NO_FILE {
		return
	}
	if state.graph.scope_drops[later] {
		add_notef(state.k.c, later, "and is still used when this is dropped at the end of its scope, which keeps it live")
	} else {
		add_notef(state.k.c, later, "and is still used here, which keeps it live")
	}
}

// A stored borrow must still be valid for as long as its destination lives.
@(private = "file")
check_retention :: proc(state: ^Prov_State, event: Prov_Event) {
	graph := state.graph
	// Written through a carrier (`p^.view`): the destinations are its loans' roots,
	// live or not.
	if len(event.into) > 0 {
		seen := make(map[Root_Id]bool, 4, context.temp_allocator)
		it := live_loans(state, nil, event.into)
		for _, index in next_live_loan(&it) {
			target := graph.loans[index].root
			if seen[target] {
				continue
			}
			seen[target] = true
			destination := graph.roots[int(target)]
			into := retain_kind_for_root(destination.kind)
			if into != .None && report_retention(state, event, into, target, destination) {
				return
			}
		}
		return
	}
	destination := Prov_Root{symbol = INVALID_SYMBOL}
	if event.root != NO_ROOT {
		destination = graph.roots[int(event.root)]
	}
	report_retention(state, event, event.retain, event.root, destination)
}

// Reports the first loan of the stored value that does not reach the
// destination; returns whether it did.
@(private = "file")
report_retention :: proc(
	state: ^Prov_State,
	event: Prov_Event,
	into: Retain_Kind,
	target: Root_Id,
	destination: Prov_Root,
) -> bool {
	graph := state.graph
	for source in event.sources {
		row := reach_row(state, state.reach, source)
		for index in 0 ..< state.loans {
			if !bit_get(row, index) || state.ended[index] {
				continue
			}
			loan := graph.loans[index]
			root := graph.roots[int(loan.root)]
			// Storing into the same storage is not retention. A parameter has two
			// roots (entry loan and places), so compare the symbol too.
			if loan.root == target ||
			   (root.symbol != INVALID_SYMBOL && root.symbol == destination.symbol) {
				continue
			}
			if root.kind == .Param {
				if parameter_allows_retention(state, root, into) {
					continue
				}
				errorf(
					state.k.c,
					event.span,
					"L0646",
					"this %s borrows %s, which is not written `@(escape=%s)`, so it cannot reach %s",
					loan.what,
					root_phrase(root),
					escape_level_name(retain_kind_level(into)),
					retain_destination(event, destination),
				)
			} else {
				if root_satisfies_retention(root.kind, into) {
					continue
				}
				errorf(
					state.k.c,
					event.span,
					"L0647",
					"this %s borrows %s, which does not outlive %s: %s",
					loan.what,
					root_phrase(root),
					retain_destination(event, destination),
					retain_kind_text(into),
				)
			}
			if root.symbol != INVALID_SYMBOL && root.span.file != NO_FILE {
				add_notef(state.k.c, root.span, "%s is declared here", root_label(root))
			}
			add_notef(state.k.c, loan.span, "the %s is created here", loan.what)
			return true
		}
	}
	return false
}

// The destination place, or the callee parameter that may keep the borrow.
@(private = "file")
retain_destination :: proc(event: Prov_Event, destination: Prov_Root) -> string {
	if destination.symbol == INVALID_SYMBOL || destination.name == "" {
		return event.verb
	}
	return fmt.tprintf("`%s`", destination.name)
}

@(private = "file")
parameter_allows_retention :: proc(state: ^Prov_State, root: Prov_Root, into: Retain_Kind) -> bool {
	sym := symbol_of(state.k.c, root.symbol)
	if sym == nil {
		return false
	}
	return sym.escape >= retain_kind_level(into)
}

// The allocation roots `free` ends: every loan must be a still-valid base
// pointer from `new` or `new_clone`.
@(private = "file")
check_free_provenance :: proc(state: ^Prov_State, event: Prov_Event) -> ([]Root_Id, bool) {
	graph := state.graph
	found := 0
	roots := make([dynamic]Root_Id, graph.alloc)
	for source in event.sources {
		row := reach_row(state, state.reach, source)
		for index in 0 ..< state.loans {
			if !bit_get(row, index) {
				continue
			}
			found += 1
			base := graph.loans[index]
			root := graph.roots[int(base.root)]
			if root.kind != .Allocation {
				errorf(
					state.k.c,
					event.span,
					"L0514",
					"`free` releases an allocation from `new` or `new_clone`; this pointer may designate %s",
					root_kind_text(root.kind),
				)
				add_notef(state.k.c, base.span, "this possible pointer is created here")
				return nil, false
			}
			if len(base.path) != 0 {
				errorf(
					state.k.c,
					event.span,
					"L0514",
					"`free` takes the allocation base pointer, not a pointer that may be derived from it",
				)
				add_notef(state.k.c, base.span, "this possible pointer is created here")
				return nil, false
			}
			if !regions_are_one(root.region, event.region) {
				errorf(
					state.k.c,
					event.span,
					"L0514",
					"`free` must name the allocator this allocation came from; pass the allocator given to `new`, or use `unsafe.free` when the compiler cannot see it",
				)
				add_notef(state.k.c, root.span, "the allocation is created here")
				return nil, false
			}
			if state.invalid[index] {
				errorf(state.k.c, event.span, "L0514", "this allocation has already been released")
				add_notef(state.k.c, base.span, "the pointer is created here")
				return nil, false
			}
			already := false
			for candidate in roots {
				already ||= candidate == base.root
			}
			if !already {
				append(&roots, base.root)
			}
		}
	}
	if found == 0 {
		errorf(
			state.k.c,
			event.span,
			"L0514",
			"`free` needs a pointer whose allocation root the compiler can see; this one has unknown provenance",
		)
		return nil, false
	}
	return roots[:], true
}

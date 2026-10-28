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
	Provider, // stable control block; moving its owner does not end it
	Param,
	Unknown,
}

// Whether the storage survives the procedure's return. Thread and process
// storage both do; `root_satisfies_retention` tells them apart.
root_outlives_body :: proc(kind: Root_Kind) -> bool {
	#partial switch kind {
	case .Local, .Slice_Literal, .Temporary, .Provider:
		return false
	}
	return true
}

// Whether a root is a binding that names another owner's storage rather than
// a frame slot of its own, such as a switch payload bound over a place
// (design.md "Switch ownership"). A borrow of it also holds the source's loans
// (`prov_borrow`), and those decide where it may go. A binding whose loans end
// with its step, or whose source is unknown, stays a local.
root_names_source :: proc(graph: ^Flow_Graph, root: Prov_Root) -> bool {
	if root.kind != .Local || root.symbol == INVALID_SYMBOL {
		return false
	}
	loans, viewed := graph.view_loans[root.symbol]
	return viewed && len(loans) > 0 && !graph.step_views[root.symbol]
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
	#partial switch root.kind {
	case .Unknown, .Static, .Thread_Local:
		if root.name != "" {
			return root.name
		}
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
	case .Provider:      return "allocator control block"
	case .Param:         return "caller storage"
	case .Unknown:       return "unknown storage"
	}
	return "storage"
}

Prov_Root :: struct {
	kind:   Root_Kind,
	symbol: Symbol_Id,
	// Canonical storage identity, independent of this pass's root ID.
	storage: Storage_Id,
	span:   Span,
	name:   string,
	// `Param`: which borrowed parameter, for substitution at a direct call.
	param_index: int,
	// What another body may have stored in a global: that global, so the reach
	// effect can tell whose stored carriers a borrow came from.
	origin: Symbol_Id,
	// A `Param` that reaches caller storage: per load depth, the `content` loan
	// standing for what that many loads through it read. The last stands for
	// every depth from its own on.
	content_loans: []Loan_Id,
	// A carrier `Param` whose pointee has carrier paths: per path of
	// `carrier_pointee_shape`, and per load depth as `content_loans`, the
	// `content` loan standing for what that many loads read when the first goes
	// along that path, so a result read out of one field does not name its
	// siblings (design.md "Procedure result contracts").
	pointee_loans: [][]Loan_Id,
	// A `Static` stand-in, while a body is summarized, for what the callback in
	// parameter `param_index` may leave in its argument `argument`. Only the
	// `Callback_Write` and `Callback_Read` summaries read it; it constrains
	// nothing else.
	forwarded: bool,
	argument:  int,
	// `Provider`: the region the control block belongs to. Empty means
	// unrecorded, which every reset reaches.
	region: Region_Set,
	// `Temporary`: whether a local extended it to the block's end, its source
	// type, and the slot keeping its borrows live when its drop runs a hook.
	extended: bool,
	dropped:  Type_Id,
	content:  int,
	// The managed temporary lending this root, before a view or erasure.
	owner:    Expr,
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
	// design.md "@(synchronized)": the step selects a synchronized field from
	// outside its package, so reaching the place is exclusive access.
	synchronized: bool,
	lo:        i64,
	hi:        i64,
}

path_is_synchronized :: proc(path: []Proj_Step) -> bool {
	for step in path {
		if step.synchronized {
			return true
		}
	}
	return false
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
	// A `Param` loan of what the parameter already held when the call began, as
	// opposed to one of its own storage (design.md "Retaining a borrow").
	content: bool,
	// A `content_loans` entry: how many loads below the parameter it stands for.
	depth: int,
	// A `pointee_loans` entry: the position in `carrier_pointee_shape` of the
	// path its first load goes along, plus one; zero for every other loan.
	pointee: int,
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
	// Read out through a carrier, so what it copies is known only once the
	// `Load` is resolved.
	loaded: bool,
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
	// Only extends the reborrow `source` belongs to: its copies do not suspend it.
	passes_on: bool,
	// `derived` was read through `source` from storage no local holds, so they
	// name the same root rather than share a loan, as a parameter and what is
	// read through it do. `path` is where below the source's pointee.
	through: bool,
	path:    []Proj_Step,
}

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
	case .Local, .Slice_Literal, .Temporary, .Provider:
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
	if payload := shared_payload_type(c, type); payload != INVALID_TYPE {
		return carrier_reach_walk(c, payload, visiting)
	}
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
	case .Array, .Dynamic_Array, .Box:
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
	carrier_shape_walk(c, type, nil, 0, &out)
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
) {
	// One path past the width already collapses the shape to its whole value,
	// so no more are collected (or allocated).
	if type == INVALID_TYPE || len(out) > CARRIER_WIDTH {
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
		append(out, carrier_truncated(carrier_steps(c, prefix, nil), type, reach, {.Depth}))
		return
	}
	info := underlying_info(c, type)
	if info == nil {
		return
	}
	// A shared handle's payload is reached as a box's is.
	if payload := shared_payload_type(c, type); payload != INVALID_TYPE {
		carrier_shape_walk(c, payload, carrier_steps(c, prefix, {proj_wild()}), depth + 1, out)
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
	case .Dynamic_Array, .Box:
		// A box's payload is reached by the same one wildcard step a place `b^` takes.
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
carrier_truncated :: proc(steps: []Proj_Step, cut: Type_Id, reach: Carrier_Reach, loss: Precision_Loss) -> Carrier_Path {
	return Carrier_Path{steps = steps, type = INVALID_TYPE, mutable = reach.mutable, truncated = true, cut = cut, precision = loss | path_precision(steps)}
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

// Merges `from` into `into`, reporting whether `into` gained anything.
@(private)
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

// design.md "Allocators and tasks": the regions a
// procedure may allocate from, resize or free in, reset, or destroy. A
// parameter's is whatever each caller passes, and the call substitutes it; a
// region the body creates is its own, and only its provider's parent, where
// the provider draws and returns blocks, is a caller's concern
// (`prov_caller_region`). `regions` never names a local.
Allocator_Use :: struct {
	regions: Region_Set,
	// Where each part comes from: one per parameter, then the default
	// provider's region and an unknown one.
	param_sources:  []Effect_Source,
	default_source: Effect_Source,
	unknown_source: Effect_Source,
}

new_allocator_use :: proc(param_count: int, allocator: mem.Allocator) -> Allocator_Use {
	count := max(param_count, 1)
	return Allocator_Use {
		regions       = Region_Set{params = make([]bool, count, allocator)},
		param_sources = make([]Effect_Source, count, allocator),
	}
}

allocator_use_is_empty :: proc(use: Allocator_Use) -> bool {
	return use.regions.params == nil || region_is_empty(use.regions)
}

// Adds what `set` names, each part new to `into` attributed to `source`.
merge_allocator_use :: proc(into: ^Allocator_Use, set: Region_Set, source: Effect_Source) -> bool {
	grew := false
	for wanted, index in set.params {
		if wanted && index < len(into.regions.params) && !into.regions.params[index] {
			into.regions.params[index] = true
			into.param_sources[index] = source
			grew = true
		}
	}
	if set.default && !into.regions.default {
		into.regions.default = true
		into.default_source = source
		grew = true
	}
	if (set.unknown || set.crowded || set.locals != 0) && !into.regions.unknown {
		into.regions.unknown = true
		into.unknown_source = source
		grew = true
	}
	return grew
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
	// Per parameter and load depth, which paths of its `carrier_pointee_shape`
	// the first of those loads may go along. Nil means all of them.
	param_load_paths: [][][]bool,
	static:       bool,
	thread:       bool,
	// The globals the result may borrow, so a caller's write to one, or a call
	// that writes one, conflicts with the result (design.md "Global write
	// effects"). `static` and `thread` cover storage no symbol names.
	globals:      []Symbol_Id,
	local:        bool, // already an error in the callee
	unknown:      bool,
}

// The paths of parameter `index`'s pointee the first of `depth` loads through
// it may go along; nil means every path.
result_load_paths :: proc(dependencies: Result_Dependencies, index, depth: int) -> []bool {
	if index >= len(dependencies.param_load_paths) {
		return nil
	}
	depths := dependencies.param_load_paths[index]
	return depth - 1 < len(depths) ? depths[depth - 1] : nil
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

Proc_Summary :: struct {
	result: Result_Provenance,
}

@(private = "file")
new_result_dependencies :: proc(c: ^Compiler, param_count: int) -> Result_Dependencies {
	return Result_Dependencies {
		params      = make([]bool, param_count, c.semantic_allocator),
		param_paths = make([][]bool, param_count, c.semantic_allocator),
		param_loads = make([]u8, param_count, c.semantic_allocator),
		param_load_paths = make([][][]bool, param_count, c.semantic_allocator),
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
	out.region_content = region_field_shape(c, type, c.semantic_allocator)
	for &content in out.region_content {
		content.region.params = make([]bool, param_count, c.semantic_allocator)
	}
	return out
}

// Keep record fields separate so a handle's region does not back a sibling
// owner, including inside nested records (design.md "Allocator regions and
// region provenance"). A managed record also keeps its own dependency: a
// moved parameter's escape contract applies even with only scalar fields.
// Containers and shared handles separate their allocation from their payload.
// Union field steps name variant indices; root borrow paths remain unchanged.
@(private)
region_field_shape :: proc(c: ^Compiler, type: Type_Id, allocator: mem.Allocator) -> []Prov_Region_Content {
	out := make([dynamic]Prov_Region_Content, 0, 0, allocator)
	region_field_shape_into(c, type, nil, &out, allocator)
	return out[:]
}

@(private = "file")
region_field_shape_into :: proc(c: ^Compiler, type: Type_Id, prefix: []Proj_Step, out: ^[dynamic]Prov_Region_Content, allocator: mem.Allocator) {
	info := underlying_info(c, type)
	if !prov_type_has_region(c, type) { return }
	if info != nil && !type_is_region_provider(c, type) && len(prefix) < 8 {
		payload := shared_payload_type(c, type)
		compound := payload != INVALID_TYPE || info.kind == .Struct || info.kind == .Union ||
		            info.kind == .Array || info.kind == .Dynamic_Array || info.kind == .Map || info.kind == .Box
		if !compound {
			append(out, Prov_Region_Content{path = prefix, handle = !type_is_managed(c, type)})
			return
		}
		if type_is_managed(c, type) {
			append(out, Prov_Region_Content{path = prefix, own = true})
		}
		children := make([dynamic]Type_Id, 0, 0, allocator)
		if payload != INVALID_TYPE {
			append(&children, payload)
		} else if info.kind == .Struct {
			for field_id in info.fields {
				field := symbol_of(c, field_id)
				append(&children, field == nil ? INVALID_TYPE : field.type)
			}
		} else if info.kind == .Union {
			append(&children, ..info.variants)
		} else if info.kind == .Map {
			path := make([]Proj_Step, len(prefix) + 1, allocator)
			copy(path, prefix)
			path[len(prefix)] = proj_wild()
			region_field_shape_into(c, info.key, path_with_field(path, PROJ_MAP_KEY, allocator), out, allocator)
			region_field_shape_into(c, info.element, path_with_field(path, PROJ_MAP_VALUE, allocator), out, allocator)
			return
		} else {
			append(&children, info.element)
		}
		for child, index in children {
			path := make([]Proj_Step, len(prefix) + 1, allocator)
			copy(path, prefix)
			path[len(prefix)] = info.kind == .Struct && payload == INVALID_TYPE || info.kind == .Union ? proj_field(index) : proj_wild()
			region_field_shape_into(c, child, path, out, allocator)
		}
	} else {
		append(out, Prov_Region_Content{path = prefix, handle = !type_is_managed(c, type)})
	}
}

@(private = "file")
path_with_field :: proc(prefix: []Proj_Step, index: int, allocator: mem.Allocator) -> []Proj_Step {
	path := make([]Proj_Step, len(prefix) + 1, allocator)
	copy(path, prefix)
	path[len(prefix)] = proj_field(index)
	return path
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
// `param`'s regions or the default allocator's.
set_synth_result_summary :: proc(c: ^Compiler, declaration: Symbol_Id, param: int) {
	sym := symbol_of(c, declaration)
	if sym == nil || sym.result == INVALID_TYPE || param >= len(sym.params) {
		return
	}
	summary := new(Proc_Summary, c.semantic_allocator)
	summary.result = new_result_provenance(c, len(sym.params), sym.result, false)
	summary.result.params[param] = type_carries_borrow(c, sym.result).any
	// design.md "Places and overlap": a removed element, or a copy sharing its
	// storage, is in the container's regions; `lookup_value`'s allocating copy is
	// the default provider's.
	if type_is_managed(c, sym.result) {
		clones := sym.container_op == .Map_Lookup_Value && clone_may_allocate(c, sym.result)
		summary.result.region.params[param] = !clones
		summary.result.region.default = true
	}
	c.result_summaries[declaration] = summary
}

// As `set_synth_result_summary`, with each carrier path of a record result
// depending on `param` separately, as a body's summary would: the halves of
// `split_at_mut` destructure into two reborrows rather than two reads of one.
set_synth_content_summary :: proc(c: ^Compiler, declaration: Symbol_Id, param: int) {
	sym := symbol_of(c, declaration)
	if sym == nil || sym.result == INVALID_TYPE || param >= len(sym.params) {
		return
	}
	summary := new(Proc_Summary, c.semantic_allocator)
	summary.result = new_result_provenance(c, len(sym.params), sym.result, true)
	summary.result.params[param] = type_carries_borrow(c, sym.result).any
	for &content in summary.result.content {
		content.dependencies.params[param] = true
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
	return summary.result, true
}

// design.md "Borrowed callable views": the signature's summary behind a view
// added as parameter 0, which the result does not depend on: every `call` a
// view of the signature holds is checked to meet the contract, captures
// included. Rebuilt on each request, as a join's is.
@(private = "file")
receiver_result_summary :: proc(c: ^Compiler, from: Result_Provenance) -> Result_Provenance {
	out := from
	out.dependencies = receiver_dependencies(c, from.dependencies)
	out.content = make([]Result_Content_Provenance, len(from.content), c.semantic_allocator)
	for content, index in from.content {
		out.content[index] = Result_Content_Provenance{path = content.path, dependencies = receiver_dependencies(c, content.dependencies)}
	}
	out.region = receiver_region(c, from.region)
	out.region_content = make([]Prov_Region_Content, len(from.region_content), c.semantic_allocator)
	for content, index in from.region_content {
		out.region_content[index] = Prov_Region_Content{
			path = content.path, region = receiver_region(c, content.region), handle = content.handle, own = content.own,
		}
	}
	return out
}

@(private = "file")
receiver_dependencies :: proc(c: ^Compiler, from: Result_Dependencies) -> Result_Dependencies {
	out := from
	count := len(from.params) + 1
	out.params = make([]bool, count, c.semantic_allocator)
	out.param_paths = make([][]bool, count, c.semantic_allocator)
	out.param_loads = make([]u8, count, c.semantic_allocator)
	out.param_load_paths = make([][][]bool, count, c.semantic_allocator)
	copy(out.params[1:], from.params)
	copy(out.param_paths[1:], from.param_paths)
	copy(out.param_loads[1:], from.param_loads)
	copy(out.param_load_paths[1:], from.param_load_paths)
	return out
}

// The view is no allocator, so it names no region of its own.
@(private = "file")
receiver_region :: proc(c: ^Compiler, from: Region_Set) -> Region_Set {
	out := from
	out.params = make([]bool, len(from.params) + 1, c.semantic_allocator)
	copy(out.params[1:], from.params)
	return out
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

// Where parameter `index`'s paths at `depth` are kept, made on first use.
@(private = "file")
load_paths_at :: proc(c: ^Compiler, into: ^Result_Dependencies, index, depth: int) -> ^[]bool {
	if into.param_load_paths[index] == nil {
		into.param_load_paths[index] = make([][]bool, 8, c.semantic_allocator)
	}
	return &into.param_load_paths[index][depth - 1]
}

@(private = "file")
merge_result_dependencies :: proc(c: ^Compiler, into: ^Result_Dependencies, from: Result_Dependencies) {
	merge_provenance(c, into, from)
	merge_precision(&into.precision, from.precision)
	for depths, index in from.param_loads {
		if index >= len(into.param_loads) {
			continue
		}
		for depth in 1 ..= 8 {
			bit := u8(1) << u8(depth - 1)
			if depths & bit == 0 || index >= len(into.param_load_paths) {
				continue
			}
			paths := result_load_paths(from, index, depth)
			if into.param_loads[index] & bit == 0 {
				if paths != nil {
					into_paths := load_paths_at(c, into, index, depth)
					into_paths^ = make([]bool, len(paths), c.semantic_allocator)
					copy(into_paths^, paths)
				}
			} else if into_paths := result_load_paths(into^, index, depth); into_paths != nil {
				if paths == nil || len(paths) != len(into_paths) {
					load_paths_at(c, into, index, depth)^ = nil
				} else {
					for used, path in paths {
						into_paths[path] ||= used
					}
				}
			}
		}
		into.param_loads[index] |= depths
	}
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
merge_provenance :: proc(c: ^Compiler, into: ^Result_Dependencies, from: Result_Dependencies) -> bool {
	changed := false
	for global in from.globals {
		if slice.contains(into.globals, global) {
			continue
		}
		grown := make([]Symbol_Id, len(into.globals) + 1, c.semantic_allocator)
		copy(grown, into.globals)
		grown[len(into.globals)] = global
		into.globals, changed = grown, true
	}
	if from.static && !into.static   { into.static, changed  = true, true }
	if from.thread && !into.thread   { into.thread, changed  = true, true }
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
	// Bytes per slot row, two bits per loan. Bytes measured faster than 64-bit
	// words and than unpacked rows on the corpus. Bit `i` says the slot may hold
	// loan `i`; bit `loans + i` says it may hold it on a path that already ended
	// it, so `free` may release it twice. Kept per slot, a pointer reassigned
	// after its release is not confused with the released one, and the stale
	// bits travel with every copy of the row.
	row_bytes: int,
	reach:   []u8,
	// A loan ended on every path to here. Checks skip only these, so an
	// invalidation that reaches its own loop head still meets the loan it ends.
	ended:   []bool,
	// Per reborrow, severed on every path to here (`Flow_Block.severed_entry`).
	// Sized before `resolve_content_reads` adds reborrows of loaded carriers,
	// which are never severed.
	severed: []bool,
	// Scratch: the loans one event ends.
	released: []bool,
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
bit_clear :: proc(row: []u8, index: int) {
	row[index >> 3] &~= 1 << u8(index & 7)
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
	// How many of each body's dependencies `callers` has: a resolved callback
	// adds more on a later round, appended after them.
	registered := make([]int, len(k.c.symbols), context.temp_allocator)
	register :: proc(c: ^Compiler, callers: ^map[Symbol_Id][dynamic]^Expr_Proc, registered: []int, literal: ^Expr_Proc) {
		dependencies := c.result_summary_dependencies[literal.symbol]
		for callee in dependencies[registered[int(literal.symbol)]:] {
			if callee not_in callers^ {
				callers^[callee] = make([dynamic]^Expr_Proc, 0, 4, context.temp_allocator)
			}
			append(&callers^[callee], literal)
		}
		registered[int(literal.symbol)] = len(dependencies)
	}
	for body in k.c.checked_bodies {
		if !body.clean {
			continue
		}
		append(&queue, body.literal)
		queued[int(body.literal.symbol)] = true
		register(k.c, &callers, registered, body.literal)
	}
	for head := 0; head < len(queue); head += 1 {
		literal := queue[head]
		queued[int(literal.symbol)] = false
		grew := summarize_body(k, literal)
		register(k.c, &callers, registered, literal)
		if !grew {
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
	if k.c.thread_summaries_wanted {
		compute_thread_summaries(k)
	}
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
		if result_uses_param(summary.result, index) {
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
	if sym == nil {
		return false
	}
	writes := proc_may_write_owners(k.c, sym)
	if sym.result == INVALID_TYPE && !writes {
		return false
	}
	defer free_all(k.c.analysis_allocator)
	graph := build_flow_graph(k, literal, .Prov_Summary)
	if graph == nil {
		return false
	}
	changed := writes && collect_written_regions(k.c, graph, literal.symbol, sym)
	// What a body stores in caller storage needs solving only when it borrows
	// `thread_local` storage at all.
	stores_thread_local := writes && graph_borrows_thread_local(graph)
	if sym.result == INVALID_TYPE {
		record_summary_dependencies(k.c, literal.symbol, graph.summary_callees[:])
		if stores_thread_local {
			state := Prov_State{graph = graph, k = k}
			if prepare_state(&state) {
				solve_reaching(&state)
				changed = collect_thread_local_writes(&state, literal.symbol, len(sym.param_symbols)) || changed
			}
		}
		return changed
	}
	summary, found := k.c.result_summaries[literal.symbol]
	if !found {
		summary = new(Proc_Summary, k.c.semantic_allocator)
		summary.result = new_result_provenance(k.c, len(sym.param_symbols), sym.result, true)
		k.c.result_summaries[literal.symbol] = summary
	}
	record_summary_dependencies(k.c, literal.symbol, graph.summary_callees[:])
	state := Prov_State{graph = graph, k = k}
	if !prepare_state(&state) {
		return changed
	}
	solve_reaching(&state)
	if stores_thread_local {
		changed = collect_thread_local_writes(&state, literal.symbol, len(sym.param_symbols)) || changed
	}
	return collect_escape_provenance(&state, literal.symbol, summary) || changed
}

// The bodies whose summaries this one read. A callback's summary is read only
// once a callee is seen to call it, so the set may grow on a later round.
@(private = "file")
record_summary_dependencies :: proc(c: ^Compiler, declaration: Symbol_Id, callees: []Symbol_Id) {
	known := c.result_summary_dependencies[declaration]
	added := 0
	for callee in callees {
		if !slice.contains(known, callee) {
			added += 1
		}
	}
	if added == 0 && declaration in c.result_summary_dependencies {
		return
	}
	grown := make([dynamic]Symbol_Id, 0, len(known) + added, c.semantic_allocator)
	append(&grown, ..known)
	for callee in callees {
		if !slice.contains(grown[:], callee) {
			append(&grown, callee)
		}
	}
	c.result_summary_dependencies[declaration] = grown[:]
}

@(private = "file")
graph_borrows_thread_local :: proc(graph: ^Flow_Graph) -> bool {
	for root in graph.roots {
		if root.kind == .Thread_Local || root.forwarded {
			return true
		}
	}
	return false
}

// design.md "Borrows crossing between tasks": for each parameter, a
// `thread_local` global whose borrow the body may store in the caller storage
// it names, and what a callback it received may leave there, read off each
// store there. A call leaves the same borrow in its argument
// (`prov_call_thread_local_writes`), so a task's call that hands one back to
// its parent is seen at the spawn.
@(private = "file")
collect_thread_local_writes :: proc(state: ^Prov_State, declaration: Symbol_Id, count: int) -> bool {
	graph := state.graph
	c := state.k.c
	written, found := c.thread_local_writes[declaration]
	if !found {
		written = make([]Symbol_Id, count, c.semantic_allocator)
		for &global in written {
			global = INVALID_SYMBOL
		}
		c.thread_local_writes[declaration] = written
	}
	changed := false
	for block in graph.blocks {
		if !block.prov_visited {
			continue
		}
		copy(state.reach, block.reach_entry)
		copy(state.precision, block.precision_entry)
		copy(state.ended, block.ended_entry)
		for event in block.prov {
			if event.kind == .Retain {
				changed = note_thread_local_write(state, event, declaration, written) || changed
			}
			run_prov_event(state, event, state.reach, state.ended)
		}
	}
	return changed
}

// The first `thread_local` global a stored value borrows, and each callback's
// stand-in it holds, recorded for each parameter whose caller storage receives
// it: the stored place's root, or the roots of the carrier it was written
// through.
@(private = "file")
note_thread_local_write :: proc(state: ^Prov_State, event: Prov_Event, declaration: Symbol_Id, written: []Symbol_Id) -> bool {
	graph := state.graph
	global := stored_thread_local(state, event.sources)
	forwarded := stored_forwarded(state, event.sources)
	if global == INVALID_SYMBOL && len(forwarded) == 0 {
		return false
	}
	destinations := make([dynamic]Prov_Root, 0, 2, context.temp_allocator)
	if len(event.into) > 0 {
		it := live_loans(state, nil, event.into)
		for _, index in next_live_loan(&it) {
			append(&destinations, graph.roots[int(graph.loans[index].root)])
		}
	} else if event.root != NO_ROOT {
		append(&destinations, graph.roots[int(event.root)])
	}
	changed := false
	for root in destinations {
		if root.kind != .Param || root.param_index < 0 || root.param_index >= len(written) {
			continue
		}
		if global != INVALID_SYMBOL && written[root.param_index] == INVALID_SYMBOL {
			written[root.param_index] = global
			changed = true
		}
		for stand_in in forwarded {
			write := Callback_Write{callback = stand_in.param_index, argument = stand_in.argument, into = root.param_index}
			changed = add_callback_write(state.k.c, declaration, write) || changed
		}
	}
	return changed
}

@(private = "file")
stored_thread_local :: proc(state: ^Prov_State, sources: []int) -> Symbol_Id {
	graph := state.graph
	for source in sources {
		row := reach_row(state, state.reach, source)
		for index in 0 ..< state.loans {
			if !bit_get(row, index) || state.ended[index] {
				continue
			}
			root := graph.roots[int(graph.loans[index].root)]
			if root.kind != .Thread_Local {
				continue
			}
			if root.symbol != INVALID_SYMBOL {
				return root.symbol
			}
			if root.origin != INVALID_SYMBOL {
				return root.origin
			}
		}
	}
	return INVALID_SYMBOL
}

@(private = "file")
stored_forwarded :: proc(state: ^Prov_State, sources: []int) -> []Prov_Root {
	graph := state.graph
	out: [dynamic]Prov_Root
	for source in sources {
		row := reach_row(state, state.reach, source)
		for index in 0 ..< state.loans {
			if !bit_get(row, index) || state.ended[index] {
				continue
			}
			root := graph.roots[int(graph.loans[index].root)]
			if root.forwarded {
				if out == nil {
					out = make([dynamic]Prov_Root, 0, 2, context.temp_allocator)
				}
				append(&out, root)
			}
		}
	}
	return out[:]
}

// design.md "Borrows crossing between tasks": a body that calls a callback it
// received may leave in its parameter `into` what that callback leaves in its
// own argument `argument`, counted among the callback's parameters. Each call
// of the body substitutes the callback it passes (`call_thread_local_left`).
Callback_Write :: struct {
	callback, argument, into: int,
}

// A callback's own result, as the argument a `Callback_Write` or
// `Callback_Read` names: what a call through it returns.
CALLBACK_RESULT :: -1

// design.md "Borrows crossing between tasks": a body's result may hold what a
// callback it received, in parameter `callback`, leaves in its own argument
// `argument`. Each call of the body substitutes the callback it passes
// (`call_callback_reads`).
Callback_Read :: struct {
	callback, argument: int,
}

@(private = "file")
add_callback_read :: proc(c: ^Compiler, declaration: Symbol_Id, read: Callback_Read) -> bool {
	known := c.callback_result_reads[declaration]
	if slice.contains(known, read) {
		return false
	}
	grown := make([]Callback_Read, len(known) + 1, c.semantic_allocator)
	copy(grown, known)
	grown[len(known)] = read
	c.callback_result_reads[declaration] = grown
	return true
}

@(private = "file")
add_callback_write :: proc(c: ^Compiler, declaration: Symbol_Id, write: Callback_Write) -> bool {
	known := c.callback_thread_local_writes[declaration]
	if slice.contains(known, write) {
		return false
	}
	grown := make([]Callback_Write, len(known) + 1, c.semantic_allocator)
	copy(grown, known)
	grown[len(known)] = write
	c.callback_thread_local_writes[declaration] = grown
	return true
}

// What a call may leave in its argument `at`, by its position in the call's
// bound arguments: a borrow of `global`, or while a body is summarized, what
// the callback that body received in parameter `callback` leaves in its own
// argument `argument`.
Thread_Local_Left :: struct {
	at:       int,
	global:   Symbol_Id,
	callback: Symbol_Id,
	argument: int,
}

// What a call may leave in its arguments. A direct call substitutes the
// procedure it passes for each callback its callee calls; a call through a
// value or a `dyn` slot may run any body the global-write effects found for it
// (`indirect_call_targets`), whatever contract its type carries, since a
// contract bounds only what the result borrows. A summary with one parameter
// fewer than the call has arguments is a procedure a callable view holds,
// after the view itself; one with one more is a callable record's `call`,
// whose record the view hides. What a variable or argument of the calling
// `body` may hold is what the write effects resolved (`Compiler.called_values`,
// `Compiler.argument_values`), so a copy of a callback is still that callback.
// With `forward`, a callback the calling body received itself stays its own
// caller's to name. `consulted` gathers each summary read.
call_thread_local_left :: proc(
	c: ^Compiler, call: ^Expr_Call, body: Symbol_Id, forward: bool, consulted: ^[dynamic]Symbol_Id,
) -> []Thread_Local_Left {
	if !call_writes_caller(c, call) {
		return nil
	}
	count := len(call.bound)
	out := make([dynamic]Thread_Local_Left, 0, 2, context.temp_allocator)
	seen := make(map[[2]int]bool, context.temp_allocator)
	targets := make([dynamic]Symbol_Id, 0, 4, context.temp_allocator)
	stand_ins := make([dynamic]Symbol_Id, 0, 2, context.temp_allocator)
	if values, through := callee_values(c, call, body); through {
		unresolved := false
		for value in values {
			#partial switch value.kind {
			case .Procedure:
				append(&targets, value.symbol)
			case .Nil:
			case .Parameter:
				if callback := body_parameter(c, body, value.parameter); forward && callback != INVALID_SYMBOL {
					append(&stand_ins, callback)
				} else {
					unresolved = true
				}
			case:
				unresolved = true
			}
		}
		if unresolved {
			indirect, _ := indirect_call_targets(c, call)
			append(&targets, ..indirect)
		}
	} else {
		append(&targets, ..call_thread_local_targets(c, call))
	}
	info := underlying_info(c, call_proc_type(c, call))
	for callback in stand_ins {
		type := symbol_of(c, callback).type
		for argument, index in call.bound {
			if argument == nil || info == nil || index >= len(info.parameters) || !parameter_writes_caller(c, info, index) {
				continue
			}
			position := index - (count - callable_arity(c, type))
			// Only a type some procedure of which may leave one needs a stand-in.
			if type_left_at(c, type, position, consulted, &seen) != INVALID_SYMBOL {
				append(&out, Thread_Local_Left{at = index, global = INVALID_SYMBOL, callback = callback, argument = position})
			}
		}
	}
	site := Call_Site{body = body, span = call.span}
	for target in targets {
		append(consulted, target)
		sym := symbol_of(c, target)
		if sym == nil {
			continue
		}
		shift := count - len(sym.param_symbols)
		for global, index in c.thread_local_writes[target] {
			if global != INVALID_SYMBOL && index + shift >= 0 && index + shift < count {
				append(&out, Thread_Local_Left{at = index + shift, global = global, callback = INVALID_SYMBOL})
			}
		}
		for write in c.callback_thread_local_writes[target] {
			at, passed := write.into + shift, write.callback + shift
			if at < 0 || at >= count || write.callback >= len(sym.param_symbols) {
				continue
			}
			type := symbol_of(c, sym.param_symbols[write.callback]).type
			for value in passed_values(c, site, call, passed) {
				left := value_left(c, value, type, write.argument, body, forward, consulted, &seen)
				if left.global != INVALID_SYMBOL || left.callback != INVALID_SYMBOL {
					left.at = at
					append(&out, left)
				}
			}
		}
	}
	return out[:]
}

// The declarations a call's summary is read from: its callee, or every body a
// call through a value or a `dyn` slot may run.
@(private = "file")
call_thread_local_targets :: proc(c: ^Compiler, call: ^Expr_Call) -> []Symbol_Id {
	if targets, indirect := indirect_call_targets(c, call); indirect {
		return targets
	}
	declaration := call_contract_declaration(c, call)
	if declaration == INVALID_SYMBOL {
		return nil
	}
	single := make([]Symbol_Id, 1, context.temp_allocator)
	single[0] = declaration
	return single
}

// What the value a call goes through may be: what the write effects resolved
// for a procedure variable, or a callable view the calling body received.
@(private = "file")
callee_values :: proc(c: ^Compiler, call: ^Expr_Call, body: Symbol_Id) -> ([]Effect_Arg, bool) {
	if values, found := c.called_values[Call_Site{body = body, span = call.span}]; found {
		return values, true
	}
	if callback := called_parameter(c, call); callback != INVALID_SYMBOL {
		single := make([]Effect_Arg, 1, context.temp_allocator)
		single[0] = Effect_Arg{kind = .Parameter, parameter = int(symbol_of(c, callback).index)}
		return single, true
	}
	return nil, false
}

// What the argument a call passes at `passed` may be: what the write effects
// resolved for it, or else what the expression names.
@(private = "file")
passed_values :: proc(c: ^Compiler, site: Call_Site, call: ^Expr_Call, passed: int) -> []Effect_Arg {
	out := make([dynamic]Effect_Arg, 0, 2, context.temp_allocator)
	for value in c.argument_values[site] {
		if value.binding == passed {
			append(&out, value)
		}
	}
	if len(out) > 0 {
		return out[:]
	}
	value: Expr = passed >= 0 && passed < len(call.bound) ? call.bound[passed] : nil
	if moved, is_move := value.(^Expr_Move); is_move {
		value = moved.value
	}
	id := INVALID_SYMBOL
	#partial switch v in value {
	case ^Expr_Ident:
		id = v.symbol
	case ^Expr_Selector:
		id = v.resolution.symbol
	case ^Expr_Proc:
		id = v.symbol
	}
	named := Effect_Arg{}
	if sym := symbol_of(c, id); sym != nil && sym.kind == .Proc {
		named = Effect_Arg{kind = .Procedure, symbol = id}
	} else if sym != nil && sym.kind == .Parameter {
		named = Effect_Arg{kind = .Parameter, parameter = int(sym.index)}
	}
	append(&out, named)
	return out[:]
}

// The parameter of `body` at `index`, if it holds a callable.
@(private = "file")
body_parameter :: proc(c: ^Compiler, body: Symbol_Id, index: int) -> Symbol_Id {
	sym := symbol_of(c, body)
	if sym == nil {
		return INVALID_SYMBOL
	}
	for id in sym.param_symbols {
		if parameter := symbol_of(c, id); parameter != nil && int(parameter.index) == index && callable_arity(c, parameter.type) >= 0 {
			return id
		}
	}
	return INVALID_SYMBOL
}

// What a call's result may hold from the callbacks its callee calls
// (`Callback_Read`): the callback each passes resolved as for a write-back
// (`value_left`), `at` unused. A callable view's contract reads its
// original's, past the view.
call_callback_reads :: proc(
	c: ^Compiler, call: ^Expr_Call, declaration, body: Symbol_Id, forward: bool, consulted: ^[dynamic]Symbol_Id,
) -> []Thread_Local_Left {
	if declaration == INVALID_SYMBOL {
		return nil
	}
	contract := declaration
	if original, shifted := c.receiver_contract_of[declaration]; shifted {
		contract = original
	}
	out: [dynamic]Thread_Local_Left
	seen := make(map[[2]int]bool, context.temp_allocator)
	site := Call_Site{body = body, span = call.span}
	for member in contract_members(c, contract) {
		append(consulted, member)
		sym := symbol_of(c, member)
		if sym == nil {
			continue
		}
		shift := len(call.bound) - len(sym.param_symbols)
		for read in c.callback_result_reads[member] {
			if read.callback >= len(sym.param_symbols) {
				continue
			}
			type := symbol_of(c, sym.param_symbols[read.callback]).type
			for value in passed_values(c, site, call, read.callback + shift) {
				left := value_left(c, value, type, read.argument, body, forward, consulted, &seen)
				if left.global != INVALID_SYMBOL || left.callback != INVALID_SYMBOL {
					if out == nil {
						out = make([dynamic]Thread_Local_Left, 0, 2, context.temp_allocator)
					}
					append(&out, left)
				}
			}
		}
	}
	return out[:]
}

// design.md "Procedure result contracts": a call through a contract reads the
// callbacks its result may hold from the contract's own declaration, so a
// substitute may read no others. The first read of `from` that `to` lacks.
callback_reads_within :: proc(c: ^Compiler, from, to: Symbol_Id) -> (Callback_Read, bool) {
	for member in contract_members(c, from) {
		for read in c.callback_result_reads[member] {
			found := false
			for bound in contract_members(c, to) {
				found = found || slice.contains(c.callback_result_reads[bound], read)
			}
			if !found {
				return read, false
			}
		}
	}
	return {}, true
}

// The parameter of the calling body a call goes through: `f(out)`, or
// `f.call(out)` on a callable view.
@(private = "file")
called_parameter :: proc(c: ^Compiler, call: ^Expr_Call) -> Symbol_Id {
	callee := call.callee
	if selector, is_selector := callee.(^Expr_Selector); is_selector && selector.operand != nil {
		if base := expr_base(selector.operand); base == nil || dyn_proc_signature(c, base.type) == INVALID_TYPE {
			return INVALID_SYMBOL
		}
		callee = selector.operand
	}
	ident, is_ident := callee.(^Expr_Ident)
	if !is_ident {
		return INVALID_SYMBOL
	}
	sym := symbol_of(c, ident.symbol)
	if sym == nil || sym.kind != .Parameter || callable_arity(c, sym.type) < 0 {
		return INVALID_SYMBOL
	}
	return ident.symbol
}

// How many parameters a procedure type or a `dyn proc` view's signature has,
// or -1 for any other type.
@(private = "file")
callable_arity :: proc(c: ^Compiler, type: Type_Id) -> int {
	signature := type
	if underlying_kind(c, type) != .Proc {
		signature = dyn_proc_signature(c, type)
	}
	info := underlying_info(c, signature)
	if info == nil || info.kind != .Proc {
		return -1
	}
	return len(info.parameters)
}

// What a callback that may be `value`, of `type`, leaves in its argument
// `argument`: a named procedure's own summary; with `forward`, a callback the
// calling `body` received as a stand-in, where any procedure of the type may
// leave one at all; otherwise what any procedure of the type may leave.
@(private = "file")
value_left :: proc(
	c: ^Compiler, value: Effect_Arg, type: Type_Id, argument: int, body: Symbol_Id, forward: bool,
	consulted: ^[dynamic]Symbol_Id, seen: ^map[[2]int]bool,
) -> Thread_Local_Left {
	none := Thread_Local_Left{global = INVALID_SYMBOL, callback = INVALID_SYMBOL}
	arity := callable_arity(c, type)
	#partial switch value.kind {
	case .Nil:
		return none
	case .Procedure:
		if prov_has_direct_body(c, value.symbol) {
			return {global = procedure_left_at(c, value.symbol, arity, argument, consulted, seen), callback = INVALID_SYMBOL}
		}
	case .Parameter:
		callback := body_parameter(c, body, value.parameter)
		if forward && callback != INVALID_SYMBOL && callable_arity(c, symbol_of(c, callback).type) == arity {
			if type_left_at(c, type, argument, consulted, seen) == INVALID_SYMBOL {
				return none
			}
			return {global = INVALID_SYMBOL, callback = callback, argument = argument}
		}
	}
	return {global = type_left_at(c, type, argument, consulted, seen), callback = INVALID_SYMBOL}
}

// A `thread_local` global that procedure `id`, standing for a callback whose
// signature has `arity` parameters, may leave in that signature's argument
// `argument`. A callback it calls in turn may be any procedure of its type.
@(private = "file")
procedure_left_at :: proc(
	c: ^Compiler, id: Symbol_Id, arity, argument: int, consulted: ^[dynamic]Symbol_Id, seen: ^map[[2]int]bool,
) -> Symbol_Id {
	sym := symbol_of(c, id)
	if sym == nil || arity < 0 {
		return INVALID_SYMBOL
	}
	index := argument
	if argument != CALLBACK_RESULT {
		index += len(sym.param_symbols) - arity
	}
	// A cycle of callbacks adds nothing its first visit does not.
	key := [2]int{int(id), index}
	if seen[key] {
		return INVALID_SYMBOL
	}
	seen[key] = true
	append(consulted, id)
	if index == CALLBACK_RESULT {
		return returned_thread_local(c, id, consulted, seen)
	}
	if written := c.thread_local_writes[id]; index >= 0 && index < len(written) && written[index] != INVALID_SYMBOL {
		return written[index]
	}
	for write in c.callback_thread_local_writes[id] {
		if write.into != index || write.callback >= len(sym.param_symbols) {
			continue
		}
		type := symbol_of(c, sym.param_symbols[write.callback]).type
		if global := type_left_at(c, type, write.argument, consulted, seen); global != INVALID_SYMBOL {
			return global
		}
	}
	return INVALID_SYMBOL
}

// A `thread_local` global procedure `id` may return a borrow of: one its result
// summary names, or what a callback it calls may leave for its result.
@(private = "file")
returned_thread_local :: proc(c: ^Compiler, id: Symbol_Id, consulted: ^[dynamic]Symbol_Id, seen: ^map[[2]int]bool) -> Symbol_Id {
	if summary, found := result_summary(c, id); found {
		for global in summary.globals {
			if global_sym := symbol_of(c, global); global_sym != nil && global_sym.duration == .Thread_Local {
				return global
			}
		}
	}
	sym := symbol_of(c, id)
	for read in c.callback_result_reads[id] {
		if read.callback >= len(sym.param_symbols) {
			continue
		}
		type := symbol_of(c, sym.param_symbols[read.callback]).type
		if global := type_left_at(c, type, read.argument, consulted, seen); global != INVALID_SYMBOL {
			return global
		}
	}
	return INVALID_SYMBOL
}

// What a call through a value or a `dyn` slot may return of a callback's
// `thread_local` storage, which a call with no summary does not show: for each
// value it may go through (`callee_values`), as `value_left` resolves it, or
// with none resolved, what any body the global-write effects found for the
// call may return (`indirect_call_targets`), as for a write-back. `at` is
// unused.
call_callback_returns :: proc(
	c: ^Compiler, call: ^Expr_Call, body: Symbol_Id, forward: bool, consulted: ^[dynamic]Symbol_Id,
) -> []Thread_Local_Left {
	type := INVALID_TYPE
	callee := call.callee
	if selector, is_selector := callee.(^Expr_Selector); is_selector && selector.operand != nil {
		if base := expr_base(selector.operand); base != nil && dyn_proc_signature(c, base.type) != INVALID_TYPE {
			callee = selector.operand
		}
	}
	if base := expr_base(callee); base != nil {
		type = base.type
	}
	if callable_arity(c, type) < 0 {
		return nil
	}
	out: [dynamic]Thread_Local_Left
	seen := make(map[[2]int]bool, context.temp_allocator)
	values, through := callee_values(c, call, body)
	if !through {
		targets, _ := indirect_call_targets(c, call)
		for target in targets {
			if global := procedure_left_at(c, target, callable_arity(c, type), CALLBACK_RESULT, consulted, &seen); global != INVALID_SYMBOL {
				if out == nil {
					out = make([dynamic]Thread_Local_Left, 0, 2, context.temp_allocator)
				}
				append(&out, Thread_Local_Left{global = global, callback = INVALID_SYMBOL})
			}
		}
		return out[:]
	}
	for value in values {
		left := value_left(c, value, type, CALLBACK_RESULT, body, forward, consulted, &seen)
		if left.global != INVALID_SYMBOL || left.callback != INVALID_SYMBOL {
			if out == nil {
				out = make([dynamic]Thread_Local_Left, 0, 2, context.temp_allocator)
			}
			append(&out, left)
		}
	}
	return out[:]
}

// What any procedure a value of the callable `type` may hold leaves in its
// argument `argument`.
@(private = "file")
type_left_at :: proc(
	c: ^Compiler, type: Type_Id, argument: int, consulted: ^[dynamic]Symbol_Id, seen: ^map[[2]int]bool,
) -> Symbol_Id {
	arity := callable_arity(c, type)
	for target in callable_type_targets(c, type) {
		if global := procedure_left_at(c, target, arity, argument, consulted, seen); global != INVALID_SYMBOL {
			return global
		}
	}
	return INVALID_SYMBOL
}

// Whether a call's signature has a parameter its callee may write through.
@(private = "file")
call_writes_caller :: proc(c: ^Compiler, call: ^Expr_Call) -> bool {
	info := underlying_info(c, call_proc_type(c, call))
	if info == nil {
		return false
	}
	for _, index in info.parameters {
		if parameter_writes_caller(c, info, index) {
			return true
		}
	}
	return false
}

// design.md "Borrows crossing between tasks": also a read-only carrier that
// reaches a mutable one, such as `outs: []^mut ^int` or a variadic `..^mut ^int`,
// which a borrow can be written through.
@(private = "file")
parameter_writes_caller :: proc(c: ^Compiler, info: ^Type_Info, index: int) -> bool {
	type := info.parameters[index]
	return (index < len(info.param_modes) && info.param_modes[index] == .Inout) || carrier_is_mutable(c, type) ||
		prov_type_reaches_destination(c, type)
}

// Whether a parameter names caller storage the body may write: `inout`, a
// mutable pointer or slice, or a read-only carrier reaching one, such as a
// variadic `..^mut T` or a `^Box` whose field is `^mut T`.
param_writes_caller :: proc(c: ^Compiler, param: ^Symbol) -> bool {
	return param != nil && (param.mode == .Inout || carrier_is_mutable(c, param.type) || prov_type_reaches_mutable(c, param.type))
}

// Whether a body may leave anything in its caller's storage, through a
// parameter it may write.
@(private = "file")
proc_may_write_owners :: proc(c: ^Compiler, sym: ^Symbol) -> bool {
	for id in sym.param_symbols {
		if param_writes_caller(c, symbol_of(c, id)) {
			return true
		}
	}
	return false
}

// design.md "Allocator regions and region provenance": the regions of owners a
// body leaves in each argument it may write, read off its flow-insensitive
// region facts. A region local to the body is its own error there.
@(private = "file")
collect_written_regions :: proc(c: ^Compiler, graph: ^Flow_Graph, declaration: Symbol_Id, sym: ^Symbol) -> bool {
	count := len(sym.param_symbols)
	written, found := c.written_regions[declaration]
	if !found {
		written = make([]Region_Set, count, c.semantic_allocator)
		for &set in written {
			set.params = make([]bool, max(count, 1), c.semantic_allocator)
		}
		c.written_regions[declaration] = written
	}
	owners, owners_found := c.written_owner_regions[declaration]
	if !owners_found {
		owners = make([]Region_Set, count, c.semantic_allocator)
		for &set in owners {
			set.params = make([]bool, max(count, 1), c.semantic_allocator)
		}
		c.written_owner_regions[declaration] = owners
	}
	contents, contents_found := c.written_region_content[declaration]
	if !contents_found {
		contents = make([][]Prov_Region_Content, count, c.semantic_allocator)
		c.written_region_content[declaration] = contents
	}
	changed := false
	for id, index in sym.param_symbols {
		if !param_writes_caller(c, symbol_of(c, id)) {
			continue
		}
		// The whole-argument unions join the path-indexed row; there a copy
		// within the argument stands for the whole argument, and only what is
		// not an allocator handle backs an owner.
		content := prov_written_parameter_content(graph, id, index)
		for entry in content {
			region := entry.region
			if entry.from != nil {
				region = prov_empty_region(graph)
				region.params[index] = true
			}
			changed = merge_region_provenance(&written[index], region) || changed
			if !entry.handle {
				changed = merge_region_provenance(&owners[index], region) || changed
			}
		}
		changed = merge_written_content(c, &contents[index], content, count) || changed
	}
	return changed
}

// Merges a body's path-indexed content into a parameter's summary row. A
// region reaching a new path is growth even when the row's union is unchanged.
// Paths stop at the written-alias depth, as a recursive call can lengthen them
// on every round; a cut entry reaches every path below it.
@(private = "file")
merge_written_content :: proc(c: ^Compiler, row: ^[]Prov_Region_Content, from: []Prov_Region_Content, count: int) -> bool {
	changed := false
	next: for entry in from {
		entry := entry
		if len(entry.path) > WRITTEN_ALIAS_DEPTH {
			entry.path, entry.own = entry.path[:WRITTEN_ALIAS_DEPTH], false
		}
		if from, copied := entry.from.?; copied && len(from.path) > WRITTEN_ALIAS_DEPTH {
			entry.from = Prov_Region_Source{from.path[:WRITTEN_ALIAS_DEPTH], .All}
		}
		for &existing in row^ {
			if prov_same_region_content(existing, entry) {
				changed = merge_region_provenance(&existing.region, entry.region) || changed
				continue next
			}
		}
		region := Region_Set{params = make([]bool, max(count, 1), c.semantic_allocator)}
		region_merge(&region, entry.region)
		grown := make([]Prov_Region_Content, len(row^) + 1, c.semantic_allocator)
		copy(grown, row^)
		grown[len(row^)] = prov_clone_region_content(entry, region, c.semantic_allocator)
		row^ = grown
		changed = true
	}
	return changed
}

// The path-indexed written content of a call's declaration, or not found for a
// contract join, whose members a call takes together as whole regions.
written_content_summary :: proc(c: ^Compiler, declaration: Symbol_Id) -> ([][]Prov_Region_Content, bool) {
	if original, shifted := c.receiver_contract_of[declaration]; shifted {
		rows, found := written_content_summary(c, original)
		if !found {
			return nil, false
		}
		out := make([][]Prov_Region_Content, len(rows) + 1, c.semantic_allocator)
		for row, index in rows {
			shifted_row := make([]Prov_Region_Content, len(row), c.semantic_allocator)
			for entry, position in row {
				shifted_row[position] = entry
				shifted_row[position].region = receiver_region(c, entry.region)
			}
			out[index + 1] = shifted_row
		}
		return out, true
	}
	if is_contract_join(c, declaration) {
		return nil, false
	}
	rows, found := c.written_region_content[declaration]
	return rows, found
}

// The written regions of a call's declaration; a join's members are unioned.
// `owners` asks only for the regions backing owners left there, without an
// allocator handle's.
written_region_summary :: proc(c: ^Compiler, declaration: Symbol_Id, owners := false) -> ([]Region_Set, bool) {
	table := owners ? &c.written_owner_regions : &c.written_regions
	// A view's own row is empty: a plain receiver is not written.
	if original, shifted := c.receiver_contract_of[declaration]; shifted {
		written, found := written_region_summary(c, original, owners)
		if !found {
			return nil, false
		}
		out := make([]Region_Set, len(written) + 1, c.semantic_allocator)
		out[0].params = make([]bool, len(written) + 1, c.semantic_allocator)
		for set, index in written {
			out[index + 1] = receiver_region(c, set)
		}
		return out, true
	}
	if !is_contract_join(c, declaration) {
		written, found := table[declaration]
		return written, found
	}
	out: []Region_Set
	for member in symbol_of(c, declaration).members {
		written, found := table[member]
		if !found {
			continue
		}
		if out == nil {
			out = make([]Region_Set, len(written), c.semantic_allocator)
			for &set in out {
				set.params = make([]bool, max(len(written), 1), c.semantic_allocator)
			}
		}
		for set, index in written {
			if index < len(out) {
				region_merge(&out[index], set)
			}
		}
	}
	return out, out != nil
}

// Every loan that can reach a `return` becomes a possibility in the summary.
@(private = "file")
collect_escape_provenance :: proc(state: ^Prov_State, declaration: Symbol_Id, summary: ^Proc_Summary) -> bool {
	graph := state.graph
	changed := false
	for block in graph.blocks {
		if !block.prov_visited {
			continue
		}
		copy(state.reach, block.reach_entry)
		copy(state.precision, block.precision_entry)
		copy(state.ended, block.ended_entry)
		for event in block.prov {
			if event.kind == .Escape {
				into := &summary.result
				if !region_is_empty(event.region) {
					changed = merge_region_provenance(&into.region, event.region) || changed
				}
				for escaped in event.region_content {
					for &content in into.region_content {
						if !prov_same_path(content.path, escaped.path) {
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
						// What a callback leaves is the caller's to name.
						if stand_in := graph.roots[int(graph.loans[index].root)]; stand_in.forwarded {
							read := Callback_Read{callback = stand_in.param_index, argument = stand_in.argument}
							changed = add_callback_read(state.k.c, declaration, read) || changed
							continue
						}
						changed = merge_loan_provenance(state, &into.dependencies, index) || changed
						for &content in into.content {
							if slot.content_shape == into.content_type && !paths_overlap(slot.path, content.path.steps) {
								continue
							}
							changed = merge_loan_provenance(state, &content.dependencies, index) || changed
						}
					}
				}
			}
			run_prov_event(state, event, state.reach, state.ended)
		}
	}
	return changed
}

@(private = "file")
merge_loan_provenance :: proc(state: ^Prov_State, into: ^Result_Dependencies, index: int) -> bool {
	loan := state.graph.loans[index]
	root := state.graph.roots[int(loan.root)]
	if root.forwarded {
		return false
	}
	one := Result_Dependencies{}
	switch root.kind {
	case .Param:
		if loan.depth > 0 && root.param_index < len(into.param_loads) {
			bit := u8(1) << u8(loan.depth - 1)
			changed := into.param_loads[root.param_index] & bit == 0
			changed = merge_param_load_paths(state, into, root, loan) || changed
			into.param_loads[root.param_index] |= bit
			return changed
		}
		if root.param_index >= 0 && root.param_index < len(into.params) {
			changed := merge_param_paths(state, into, root, loan)
			if !into.params[root.param_index] {
				into.params[root.param_index] = true
				changed = true
			}
			return changed
		}
		one.unknown = true
	case .Static, .Thread_Local:
		if root.symbol != INVALID_SYMBOL {
			one.globals = []Symbol_Id{root.symbol}
		} else if root.kind == .Static {
			one.static = true
		} else {
			one.thread = true
		}
	case .Materialized:
		one.static = true
	case .Local, .Slice_Literal, .Temporary, .Provider:
		one.local = true
	case .Unknown:
		one.unknown = true
	}
	return merge_provenance(state.k.c, into, one)
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

// Narrows a load dependency to the pointee path the loan's first load goes
// along, so a caller loads only through those fields. Nil means every path.
// Runs before the load's bit is set, which is how a first narrowing tells
// itself apart from a dependency already widened to the whole pointee.
@(private = "file")
merge_param_load_paths :: proc(
	state: ^Prov_State,
	into: ^Result_Dependencies,
	root: Prov_Root,
	loan: Prov_Loan,
) -> bool {
	index := root.param_index
	if index >= len(into.param_load_paths) {
		return false
	}
	c := state.k.c
	first := into.param_loads[index] & (u8(1) << u8(loan.depth - 1)) == 0
	sym := symbol_of(c, root.symbol)
	shape := sym == nil ? nil : carrier_pointee_shape(c, sym.type)
	paths := result_load_paths(into^, index, loan.depth)
	if loan.pointee == 0 || loan.pointee > len(shape) {
		if paths == nil {
			return false
		}
		load_paths_at(c, into, index, loan.depth)^ = nil
		return true
	}
	if paths == nil {
		if !first {
			return false // already widened to the whole pointee
		}
		paths = make([]bool, len(shape), c.semantic_allocator)
		load_paths_at(c, into, index, loan.depth)^ = paths
	}
	if paths[loan.pointee - 1] {
		return false
	}
	paths[loan.pointee - 1] = true
	return true
}

// One concrete body's root and region diagnostics.
analyze_provenance :: proc(k: ^Checker, literal: ^Expr_Proc) {
	defer free_all(k.c.analysis_allocator)
	first := len(k.c.diagnostics)
	defer note_instance_sites(k, literal, first)
	graph := build_flow_graph(k, literal, .Prov_Diagnose)
	if graph == nil {
		return
	}
	solve_provenance(k, graph)
}

// An error in a generic instance's body names the call that selected it, as
// the checker's do, which run before this pass: the body may be a library's,
// and the call the caller's.
@(private = "file")
note_instance_sites :: proc(k: ^Checker, literal: ^Expr_Proc, first: int) {
	instance := k.c.procedure_instances[literal.symbol]
	if instance == nil || instance.selected_at.file == NO_FILE {
		return
	}
	append(&k.c.instantiation_stack, Instantiation_Frame {
		description = identifier_text(k.c, symbol_of(k.c, literal.symbol).name),
		span        = instance.selected_at,
	})
	defer pop(&k.c.instantiation_stack)
	note_instantiation_stack(k, first)
}

// design.md "Globals while tasks run": the globals whose
// stored carriers the body itself reaches, from each `Reach` event and from
// what it returns or stores where another body may reach through it. A
// global's stored carrier is a loan of its existing content, a loan of the
// global's own storage when that holds carriers, or the global's own slot,
// which another call may have refilled. A `@(synchronized)` variable's package
// vouches for every access through it.
body_global_reach :: proc(k: ^Checker, graph: ^Flow_Graph, out: ^[dynamic]Global_Effect) {
	state := Prov_State{graph = graph, k = k}
	if !prepare_state(&state) {
		return
	}
	solve_reaching(&state)
	for block in graph.blocks {
		if !block.prov_visited {
			continue
		}
		copy(state.reach, block.reach_entry)
		copy(state.precision, block.precision_entry)
		copy(state.ended, block.ended_entry)
		for event in block.prov {
			#partial switch event.kind {
			case .Reach, .Escape, .Retain, .Publish:
				for slot in event.sources {
					note_reached_globals(&state, slot, event.span, out)
				}
			}
			run_prov_event(&state, event, state.reach, state.ended)
		}
	}
}

@(private = "file")
note_reached_globals :: proc(state: ^Prov_State, slot: int, span: Span, out: ^[dynamic]Global_Effect) {
	graph := state.graph
	c := state.k.c
	source := Effect_Source{span = span, precision = state.precision[slot]}
	add_reached_global(c, out, graph.prov_slots[slot].symbol, source)
	row := reach_row(state, state.reach, slot)
	for index in 0 ..< state.loans {
		if !bit_get(row, index) {
			continue
		}
		root := graph.roots[int(graph.loans[index].root)]
		if root.origin != INVALID_SYMBOL {
			add_reached_global(c, out, root.origin, source)
		} else if root.kind == .Static || root.kind == .Thread_Local {
			add_reached_global(c, out, root.symbol, source)
		}
	}
}

@(private = "file")
add_reached_global :: proc(c: ^Compiler, out: ^[dynamic]Global_Effect, global: Symbol_Id, source: Effect_Source) {
	sym := symbol_of(c, global)
	if sym == nil || sym.kind != .Var || !symbol_outlives_bodies(sym) || sym.synchronized ||
	   !type_carries_borrow(c, sym.type).any {
		return
	}
	for existing in out {
		if existing.global == global {
			return
		}
	}
	append(out, Global_Effect{global = global, source = source})
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
	if state.loans == 0 && !graph.has_region_event && !graph.has_window_event {
		return false
	}
	state.row_bytes = (2 * state.loans + 7) / 8
	width := max(state.slots * state.row_bytes, 1)
	for block in graph.blocks {
		block.reach_entry = make([]u8, width, graph.alloc)
		block.precision_entry = make([]Precision_Loss, state.slots, graph.alloc)
		block.precision_exit = make([]Precision_Loss, state.slots, graph.alloc)
		block.reach_exit = make([]u8, width, graph.alloc)
		block.ended_entry = make([]bool, state.loans, graph.alloc)
		block.ended_exit = make([]bool, state.loans, graph.alloc)
		block.severed_entry = make([]bool, len(graph.reborrows), graph.alloc)
		block.severed_exit = make([]bool, len(graph.reborrows), graph.alloc)
		block.live_entry = make([]bool, max(state.slots, 1), graph.alloc)
		block.live_exit = make([]bool, max(state.slots, 1), graph.alloc)
		block.use_entry = make([]Span, max(state.slots, 1), graph.alloc)
		block.use_exit = make([]Span, max(state.slots, 1), graph.alloc)
		block.prov_visited = false
	}
	state.reach = make([]u8, width, graph.alloc)
	state.precision = make([]Precision_Loss, state.slots, graph.alloc)
	state.released = make([]bool, state.loans, graph.alloc)
	state.ended = make([]bool, state.loans, graph.alloc)
	state.severed = make([]bool, len(graph.reborrows), graph.alloc)
	state.live = make([]bool, max(state.slots, 1), graph.alloc)
	state.uses = make([]Span, max(state.slots, 1), graph.alloc)
	state.merged = make([]u8, max(state.row_bytes, 1), graph.alloc)
	settle_pool_joins(state)
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
		mem.zero_slice(state.ended)
		mem.zero_slice(state.severed)
		if id != 0 {
			seen := false
			for predecessor in block.preds {
				source := graph.blocks[predecessor]
				if !source.prov_visited {
					continue
				}
				bytes_or(state.reach, source.reach_exit)
				for loss, slot in source.precision_exit { state.precision[slot] |= loss }
				// A predecessor not visited yet stays out of the meet.
				if seen {
					for value, index in source.ended_exit {
						state.ended[index] &&= value
					}
					for value, index in source.severed_exit {
						state.severed[index] &&= value
					}
				} else {
					copy(state.ended, source.ended_exit)
					copy(state.severed, source.severed_exit)
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
		copy(block.ended_entry, state.ended)
		copy(block.severed_entry, state.severed)
		for event in block.prov {
			run_prov_event(state, event, state.reach, state.ended)
			run_severing_event(state, event)
		}
		if block.prov_visited &&
		   slice.equal(block.precision_exit, state.precision) &&
		   slice.equal(block.reach_exit, state.reach) &&
		   slice.equal(block.ended_exit, state.ended) &&
		   slice.equal(block.severed_exit, state.severed) {
			continue
		}
		copy(block.reach_exit, state.reach)
		copy(block.precision_exit, state.precision)
		copy(block.ended_exit, state.ended)
		copy(block.severed_exit, state.severed)
		block.prov_visited = true
		for successor in block.succs {
			if !queued[int(successor)] {
				append(&queue, successor)
				queued[int(successor)] = true
			}
		}
	}
}

// design.md "Chunks of a mutable slice": redefining a fresh slot severs the
// reborrows of its previous value, and redefining a reborrow's derived slot
// takes it afresh.
@(private = "file")
run_severing_event :: proc(state: ^Prov_State, event: Prov_Event) {
	graph := state.graph
	if event.kind != .Def || len(graph.fresh_slots) == 0 {
		return
	}
	for reborrow, index in graph.reborrows[:len(state.severed)] {
		if !graph.fresh_slots[reborrow.source] {
			continue
		}
		if reborrow.source == event.slot {
			state.severed[index] = true
		} else if reborrow.derived == event.slot {
			state.severed[index] = false
		}
	}
}

@(private = "file")
run_prov_event :: proc(state: ^Prov_State, event: Prov_Event, reach: []u8, ended: []bool) {
	graph := state.graph
	mark_released(state, event, reach)
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
			// A creation site that runs again starts a new, valid instance.
			loss |= path_precision(graph.loans[int(event.loan)].path)
			bit_mark(state.merged, int(event.loan))
			bit_clear(state.merged, state.loans + int(event.loan))
		}
		copy(reach_row(state, reach, event.slot), state.merged)
		state.precision[event.slot] = loss
	case .Load:
		load_pointee_content(state, event, reach)
	case .Rebind:
		for slot in 0 ..< state.slots {
			row := reach_row(state, reach, slot)
			for loan, index in graph.loans {
				if loan.root == event.root {
					bit_clear(row, index)
					bit_clear(row, state.loans + index)
				}
			}
		}
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
				publish_into_loan(state, reach, graph.loans[index], state.precision[slot])
			}
		}
	}
}

// Marks the loans an event ends as released in every slot that may hold them,
// and clears the mark where a loop head re-establishes them.
@(private = "file")
mark_released :: proc(state: ^Prov_State, event: Prov_Event, reach: []u8) {
	mem.zero_slice(state.released)
	revived := event.kind == .Live && event.revives
	#partial switch event.kind {
	case .Live:
		if !revived {
			return
		}
		for source in event.sources {
			row := reach_row(state, reach, source)
			for index in 0 ..< state.loans {
				state.released[index] ||= bit_get(row, index)
			}
		}
	case .Access, .Root_End, .Reset:
		end_loans(state, event, reach, state.released)
	case:
		return
	}
	for slot in 0 ..< state.slots {
		row := reach_row(state, reach, slot)
		for index in 0 ..< state.loans {
			if !state.released[index] {
				continue
			}
			if revived {
				bit_clear(row, state.loans + index)
			} else if bit_get(row, index) {
				bit_mark(row, state.loans + index)
			}
		}
	}
}

// Which loans an event ends or starts afresh, over the loans ended on every
// path, and once per event over the loans it releases.
@(private = "file")
end_loans :: proc(state: ^Prov_State, event: Prov_Event, reach: []u8, ended: []bool) {
	graph := state.graph
	#partial switch event.kind {
	case .Def:
		// A creation site that runs again starts a new, valid instance.
		if event.loan != NO_LOAN {
			ended[int(event.loan)] = false
		}
	case .Live:
		// A loop head re-establishes the loans, so an endedation inside the body
		// does not reach its entry through the back edge.
		if !event.revives {
			break
		}
		for source in event.sources {
			row := reach_row(state, reach, source)
			for index in 0 ..< state.loans {
				if bit_get(row, index) {
					ended[index] = false
				}
			}
		}
	case .Access:
		if event.access != .Invalidate {
			break
		}
		for loan, index in graph.loans {
			if loan.root == event.root && paths_overlap(loan.path, event.path) {
				ended[index] = true
			}
		}
	case .Root_End:
		for loan, index in graph.loans {
			if loan.root == event.root {
				ended[index] = true
			}
		}
	case .Reset:
		for loan, index in graph.loans {
			if reset_ends_root(graph.roots[int(loan.root)], event) {
				ended[index] = true
			}
		}
	}
}

// A load reads the slots at the pointee path through the addressing loans and
// copies their dependencies. Storage with no local content keeps the loan. A
// deep load goes on through what it read until nothing new turns up.
@(private = "file")
load_pointee_content :: proc(state: ^Prov_State, event: Prov_Event, reach: []u8, reads: ^[dynamic]int = nil) {
	graph := state.graph
	if event.writable {
		load_writable_content(state, event, reach, reads)
		return
	}
	mem.zero_slice(state.merged)
	loss := graph.prov_slots[event.slot].precision | path_precision(event.path)
	for carrier in event.into {
		row := reach_row(state, reach, carrier)
		for index in 0 ..< state.loans {
			if bit_get(row, index) && !load_through_loan(state, index, event.path, reach, &loss, reads) {
				loss |= state.precision[carrier]
			}
		}
	}
	if event.deep {
		expanded := make([]bool, state.loans, graph.alloc)
		for grew := true; grew; {
			grew = false
			for index in 0 ..< state.loans {
				if !expanded[index] && bit_get(state.merged, index) {
					expanded[index] = true
					grew = true
					load_through_loan(state, index, nil, reach, &loss, reads)
				}
			}
		}
	}
	copy(reach_row(state, reach, event.slot), state.merged)
	state.precision[event.slot] = loss
}

// A `writable` load: the loans of every mutable carrier reached from
// `event.into`, going on through those and through read-only carriers whose
// pointee reaches a destination (`prov_load_writable`). What `into` names is
// only read through, as `prov_mutable_reach` already kept the mutable ones.
@(private = "file")
load_writable_content :: proc(state: ^Prov_State, event: Prov_Event, reach: []u8, reads: ^[dynamic]int) {
	graph := state.graph
	mem.zero_slice(state.merged)
	loss := graph.prov_slots[event.slot].precision
	pending := make([]bool, state.loans, context.temp_allocator)
	for carrier in event.into {
		row := reach_row(state, reach, carrier)
		for index in 0 ..< state.loans {
			if bit_get(row, index) {
				pending[index] = true
			}
		}
	}
	expanded := make([]bool, state.loans, context.temp_allocator)
	for grew := true; grew; {
		grew = false
		for index in 0 ..< state.loans {
			if pending[index] && !expanded[index] {
				expanded[index] = true
				grew = true
				load_writable_through(state, index, reach, &loss, reads, pending)
			}
		}
	}
	copy(reach_row(state, reach, event.slot), state.merged)
	state.precision[event.slot] = loss
}

// The carriers in the storage one loan names, as `load_through_loan` finds
// them: a mutable one's loans join `state.merged`, and those of any carrier a
// write may go on through become `pending`. Storage with no local content
// stands for what it holds, unless its type holds nothing a write could reach.
@(private = "file")
load_writable_through :: proc(
	state: ^Prov_State,
	loan_index: int,
	reach: []u8,
	loss: ^Precision_Loss,
	reads: ^[dynamic]int,
	pending: []bool,
) {
	graph := state.graph
	c := graph.k.c
	loan := graph.loans[loan_index]
	root := graph.roots[int(loan.root)]
	sym := symbol_of(c, root.symbol)
	found := false
	if sym != nil && !(root.kind == .Param && (loan.content || type_is_carrier(c, sym.type))) {
		slots := graph.content_by_symbol[root.symbol]
		bare: [1]int
		bare_type := INVALID_TYPE
		if index, exists := graph.slot_by_symbol[root.symbol]; exists {
			bare[0] = index
			slots = bare[:]
			bare_type = sym.type
		}
		for index in slots {
			slot := graph.prov_slots[index]
			if !paths_overlap(slot.path, loan.path) {
				continue
			}
			found = true
			loss^ |= state.precision[index]
			if reads != nil && !slice.contains(reads[:], index) {
				append(reads, index)
			}
			// A truncated or unshaped slot stands for every carrier below it.
			destination, follow := true, true
			type := bare_type != INVALID_TYPE ? bare_type : slot.content_type
			if type != INVALID_TYPE && !slot.content_truncated {
				info := underlying_info(c, type)
				pointee := info != nil ? info.element : INVALID_TYPE
				destination = carrier_is_mutable(c, type) && type_carries_borrow(c, pointee).any
				// design.md "Slice literals": a slice also carries its elements'
				// loans, so a mutable element's are destinations as well.
				if info != nil && info.kind == .Slice {
					element := underlying_info(c, pointee)
					destination ||= carrier_is_mutable(c, pointee) && element != nil && type_carries_borrow(c, element.element).any
				}
				follow = destination || prov_type_reaches_destination(c, pointee)
			}
			row := reach_row(state, reach, index)
			if destination {
				bytes_or(state.merged, row)
			}
			if follow {
				for held in 0 ..< state.loans {
					if bit_get(row, held) {
						pending[held] = true
					}
				}
			}
		}
	}
	if found || sym != nil && root.kind != .Param && !type_carries_borrow(c, sym.type).any {
		return
	}
	loss^ |= path_precision(loan.path)
	bit_mark(state.merged, deeper_content_loan(root, loan, loan_index))
}

// The `content` loan standing for what one more load through a parameter's
// loan reads, the last standing for every depth from its own on. A pointee
// loan's keeps the path its first load went along.
@(private = "file")
deeper_content_loan :: proc(root: Prov_Root, loan: Prov_Loan, loan_index: int) -> int {
	count := len(root.content_loans)
	if count == 0 {
		return loan_index
	}
	next := min(loan.depth, count - 1)
	if loan.pointee > 0 {
		return int(root.pointee_loans[loan.pointee - 1][next])
	}
	return int(root.content_loans[next])
}

// Joins into `state.merged` what the storage one loan names holds at `path`;
// false when that storage has no local content, and the loan stands for it. A
// parameter's caller storage is never local: its `content_loans` stand for it.
@(private = "file")
load_through_loan :: proc(
	state: ^Prov_State,
	loan_index: int,
	path: []Proj_Step,
	reach: []u8,
	loss: ^Precision_Loss,
	reads: ^[dynamic]int,
) -> bool {
	graph := state.graph
	loan := graph.loans[loan_index]
	root := graph.roots[int(loan.root)]
	sym := symbol_of(graph.k.c, root.symbol)
	found := false
	if sym != nil && !(root.kind == .Param && (loan.content || type_is_carrier(graph.k.c, sym.type))) {
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
			if !paths_overlap(suffix, path) {
				continue
			}
			found = true
			loss^ |= state.precision[index]
			bytes_or(state.merged, reach_row(state, reach, index))
			if reads != nil && !slice.contains(reads[:], index) {
				append(reads, index)
			}
		}
	}
	if !found {
		loss^ |= path_precision(loan.path)
		if root.kind == .Param && !loan.content && load_pointee_paths(state, root, path) {
			return found
		}
		bit_mark(state.merged, deeper_content_loan(root, loan, loan_index))
	}
	return found
}

// A load along `path` through a carrier parameter's own loan reads only the
// pointee paths it overlaps. False when it names none of them, as a load of
// the whole pointee or of storage beside its carriers does.
@(private = "file")
load_pointee_paths :: proc(state: ^Prov_State, root: Prov_Root, path: []Proj_Step) -> bool {
	if len(path) == 0 || len(root.pointee_loans) == 0 {
		return false
	}
	graph := state.graph
	shape := carrier_pointee_shape(graph.k.c, symbol_of(graph.k.c, root.symbol).type)
	marked := false
	for loans, position in root.pointee_loans {
		if paths_overlap(shape[position].steps, path) {
			bit_mark(state.merged, int(loans[0]))
			marked = true
		}
	}
	return marked
}

// Records which slots each indirect read uses before the backward pass, so a
// mutation before `p^.view` conflicts with the borrow held in the pointee.
@(private = "file")
resolve_content_reads :: proc(state: ^Prov_State) {
	if !state.graph.has_content_load { return }
	loads := make([dynamic]Prov_Event, 0, 8, state.graph.alloc)
	defer prov_reborrow_loaded_through(state.graph, loads[:])
	for block in state.graph.blocks {
		if !block.prov_visited {
			continue
		}
		copy(state.reach, block.reach_entry)
		copy(state.precision, block.precision_entry)
		copy(state.ended, block.ended_entry)
		for &event in block.prov {
			if event.kind == .Load {
				reads := make([dynamic]int, 0, 4, state.graph.alloc)
				load_pointee_content(state, event, state.reach, &reads)
				event.sources = reads[:]
				prov_reborrow_loaded(state.graph, event)
				append(&loads, event)
			} else {
				run_prov_event(state, event, state.reach, state.ended)
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
// A carrier whose loans were merged may name storage the write never reaches,
// so what lands there carries the carrier's precision as well.
publish_into_loan :: proc(state: ^Prov_State, reach: []u8, loan: Prov_Loan, carrier_loss: Precision_Loss) {
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
			state.precision[index] |= state.merged_precision | carrier_loss | slot.precision | path_precision(loan.path)
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
	case .Live, .Escape:
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
	visited := make([]bool, len(graph.blocks), graph.alloc)
	for block, id in graph.blocks {
		visited[id] = block.prov_visited
	}
	window_entry := solve_window(state, visited)
	shared := Shared_Reports{
		seen   = make(map[Shared_Report]bool, 4, graph.alloc),
		scopes = make(map[int]bool, 2, graph.alloc),
	}
	for block, id in graph.blocks {
		if !block.prov_visited || len(block.prov) == 0 {
			continue
		}
		window := window_entry[id]
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
			case .Access, .Root_End, .Reset, .Live, .Load, .Task_Join:
				live_after[index] = slice.clone(live, graph.alloc)
				use_after[index] = slice.clone(uses, graph.alloc)
			}
			run_live_event(block.prov[index], live, uses)
		}

		copy(state.reach, block.reach_entry)
		copy(state.precision, block.precision_entry)
		copy(state.ended, block.ended_entry)
		copy(state.severed, block.severed_entry)
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
			check_shared_event(state, event, window, &shared)
			window = window_step(graph, window, event)
			run_prov_event(state, event, state.reach, state.ended)
			run_severing_event(state, event)
		}
	}
}

// --------------------------------------------------------- task window --
// design.md "Globals while tasks run": from a block's first spawn to its join,
// neither a task nor the parent may write a global every thread shares, or
// reach through one that stores mutable or erased state.

// The spawns whose tasks may be running on entry to each block, one bit per
// spawn site (`task_sites`): a spawn sets its own, and a join clears those of
// its block. A path through a loop that spawns returns to the head with the
// bit set. Past 64 sites, the last bit is shared and never cleared, which
// keeps the window open to the end of the body.
@(private = "file")
solve_window :: proc(state: ^Prov_State, reached: []bool) -> []u64 {
	graph := state.graph
	entry := make([]u64, len(graph.blocks), graph.alloc)
	if !graph.has_window_event {
		return entry
	}
	exit := make([]u64, len(graph.blocks), graph.alloc)
	for changed := true; changed; {
		changed = false
		for block, id in graph.blocks {
			if !reached[id] {
				continue
			}
			mask := u64(0)
			for predecessor in block.preds {
				mask |= exit[int(predecessor)]
			}
			entry[id] = mask
			for event in block.prov {
				mask = window_step(graph, mask, event)
			}
			if mask != exit[id] {
				exit[id] = mask
				changed = true
			}
		}
	}
	return entry
}

// design.md "Parallel blocks": a pooled join may run, on the joining thread,
// only tasks started on a path that reaches it. The walk emits the join's
// `thread_local` writes at every exit of the block, since a loop's back edge
// may start a task before an exit written above its spawn; here, before any
// solver reads them, those writes are dropped where no task of the block may
// have started.
@(private = "file")
settle_pool_joins :: proc(state: ^Prov_State) {
	graph := state.graph
	if len(graph.pool_tasks) == 0 {
		return
	}
	reached := make([]bool, len(graph.blocks), graph.alloc)
	queue := make([dynamic]Block_Id, 0, len(graph.blocks), graph.alloc)
	append(&queue, Block_Id(0))
	reached[0] = true
	for head := 0; head < len(queue); head += 1 {
		for successor in graph.blocks[int(queue[head])].succs {
			if !reached[int(successor)] {
				reached[int(successor)] = true
				append(&queue, successor)
			}
		}
	}
	window_entry := solve_window(state, reached)
	for block, id in graph.blocks {
		mask := window_entry[id]
		kept := 0
		for event in block.prov {
			if event.joins == 0 || block_running(graph, mask, event.joins - 1) {
				block.prov[kept] = event
				kept += 1
			}
			mask = window_step(graph, mask, event)
		}
		resize(&block.prov, kept)
	}
}

// Whether a task of the `parallel` block with window bit `index` may be
// running, by `mask`.
@(private = "file")
block_running :: proc(graph: ^Flow_Graph, mask: u64, index: int) -> bool {
	for site in running_sites(graph, mask) {
		if graph.task_sites[site].block == index {
			return true
		}
	}
	return false
}

@(private = "file")
window_step :: proc(graph: ^Flow_Graph, mask: u64, event: Prov_Event) -> u64 {
	#partial switch event.kind {
	case .Task_Start:
		return mask | site_bit(event.slot)
	case .Task_Join:
		out := mask
		for site, index in graph.task_sites {
			if site.block == event.slot && index < 63 {
				out &= ~site_bit(index)
			}
		}
		return out
	}
	return mask
}

@(private = "file")
site_bit :: proc(site: int) -> u64 {
	return u64(1) << uint(min(site, 63))
}

// The sites whose tasks may be running, by `mask`; the shared last bit stands
// for every site from 63 on.
@(private = "file")
running_sites :: proc(graph: ^Flow_Graph, mask: u64) -> []int {
	out := make([dynamic]int, 0, 2, graph.alloc)
	for index in 0 ..< len(graph.task_sites) {
		if mask & site_bit(index) != 0 {
			append(&out, index)
		}
	}
	return out[:]
}

@(private = "file")
Shared_Report :: struct {
	span:   Span,
	global: Symbol_Id,
}

// What has been reported, so a global met twice at one place, or a block's
// thread-exit drops, are reported once.
@(private = "file")
Shared_Reports :: struct {
	seen:   map[Shared_Report]bool,
	scopes: map[int]bool,
}

@(private = "file")
check_shared_event :: proc(state: ^Prov_State, event: Prov_Event, window: u64, shared: ^Shared_Reports) {
	#partial switch event.kind {
	case .Task_Start:
		check_task_globals(state, event, shared)
		check_task_reservation(state, event, window)
	case .Region_Use:
		check_parent_allocator_use(state, event, window)
	case .Shared_Effect:
		if window == 0 {
			return
		}
		if event.access == .Read {
			report_shared_reach(state, event.symbol, event.span, window, shared, event.name)
		} else {
			report_parent_write(state, event, window, shared)
		}
	case .Reach, .Escape, .Retain, .Publish:
		if window == 0 {
			return
		}
		reached := make([dynamic]Global_Effect, 0, 2, state.graph.alloc)
		for slot in event.sources {
			note_reached_globals(state, slot, event.span, &reached)
		}
		for global in reached {
			report_shared_reach(state, global.global, event.span, window, shared)
		}
	}
}

// What a global stores that a task sharing it could race on: a mutable
// carrier, through which any thread may write, or an erased one, which hides
// what it reaches. A read-only `dyn` view reaches what each type converted to
// it reaches. An allocator's operations are reserved instead
// (design.md "Allocators and tasks").
@(private = "file")
Shared_Hazard :: struct {
	type:   Type_Id,
	erased: bool,
	via:    Transfer_Via,
}

@(private = "file")
shared_carrier_hazard :: proc(c: ^Compiler, global: Symbol_Id) -> Shared_Hazard {
	none := Shared_Hazard{INVALID_TYPE, false, {INVALID_TYPE, INVALID_TYPE}}
	sym := symbol_of(c, global)
	if sym == nil || sym.synchronized || type_underlying(c, sym.type) == TYPE_ALLOCATOR ||
	   type_is_region_provider(c, sym.type) {
		return none
	}
	facts := transfer_facts(c, sym.type, through_views = true)
	if facts.mutable != INVALID_TYPE {
		return {facts.mutable, false, {INVALID_TYPE, INVALID_TYPE}}
	}
	if facts.viewed != INVALID_TYPE {
		return {facts.viewed, false, facts.viewed_via}
	}
	if facts.erased != INVALID_TYPE {
		return {facts.erased, true, facts.erased_via}
	}
	return none
}

@(private = "file")
shared_hazard_text :: proc(c: ^Compiler, global: Symbol_Id, hazard: Shared_Hazard) -> string {
	name := identifier_text(c, symbol_of(c, global).name)
	consequence := hazard.erased ? "which hides what it reaches" : "through which another thread may write as well"
	return fmt.tprintf("`%s` holds %s, %s", name, view_chain_text(c, hazard.type, hazard.via), consequence)
}

// How a transfer fact is reached: "`dyn I`, which may view a `W`, which
// reaches `T`" through the read-only view `via` names, or "`T`" without one.
view_chain_text :: proc(c: ^Compiler, reached: Type_Id, via: Transfer_Via) -> string {
	if via.view == INVALID_TYPE {
		return fmt.tprintf("`%s`", type_name(c, reached))
	}
	if via.witness == reached {
		return fmt.tprintf("`%s`, which may view a `%s`", type_name(c, via.view), type_name(c, reached))
	}
	return fmt.tprintf(
		"`%s`, which may view a `%s`, which reaches `%s`",
		type_name(c, via.view), type_name(c, via.witness), type_name(c, reached),
	)
}

// ----------------------------------------------------- join retention --
// design.md "Releasing before the join": a task may be waiting for the parent
// to drop a guard or endpoint, and the join waits for the task. At the join,
// after the block's own cleanup, a value the parent still holds that is or
// reaches an `@(wakes_on_drop)` type must borrow no storage a task of the block
// may borrow. The parent holds a local or result that is used or dropped
// later, and every parameter, which the caller holds past the join. This does
// not prove the task waits on that storage: it is conservative.
@(private = "file")
check_join_retention :: proc(state: ^Prov_State, event: Prov_Event, live: []bool) {
	graph := state.graph
	c := state.k.c
	if event.slot < 0 || event.slot >= len(graph.parallel_scopes) {
		return
	}
	scope := graph.parallel_scopes[event.slot]
	held := make([dynamic]int, 0, 4, graph.alloc)
	if slot, found := graph.task_slots[scope]; found {
		append(&held, slot)
	}
	if holds, found := graph.task_holds[scope]; found {
		append(&held, ..holds[:])
	}
	if len(held) == 0 {
		return
	}
	is_task_slot := make(map[int]bool, len(held), graph.alloc)
	for slot in held {
		is_task_slot[slot] = true
	}
	reported := make(map[Symbol_Id]bool, 2, graph.alloc)
	wakers := make(map[Symbol_Id]Type_Id, 8, graph.alloc)
	reached := make(map[Root_Id]Reached_Storage, 4, graph.alloc)
	for slot in 0 ..< min(state.slots, len(graph.prov_slots)) {
		info := graph.prov_slots[slot]
		sym := symbol_of(c, info.symbol)
		if sym == nil || is_task_slot[slot] || reported[info.symbol] {
			continue
		}
		if !live[slot] && !kept_by_caller(sym) {
			continue
		}
		waker, cached := wakers[info.symbol]
		if !cached {
			waker = type_reaches_waker(c, sym.type)
			wakers[info.symbol] = waker
		}
		if waker == INVALID_TYPE {
			continue
		}
		// Only the marked subvalue's carriers count: a wrapper's sibling field
		// may borrow what a task borrows without holding up its wait.
		if info.content_shape == sym.type {
			waker = path_waker(c, sym.type, info.path)
			if waker == INVALID_TYPE {
				continue
			}
		}
		row := reach_row(state, state.reach, slot)
		for index in 0 ..< state.loans {
			if !bit_get(row, index) || state.ended[index] {
				continue
			}
			if task, shared := task_loan_overlapping(state, held[:], graph.loans[index], &reached); shared {
				report_join_retention(state, event, sym, waker, graph.loans[index], task)
				reported[info.symbol] = true
				break
			}
		}
	}
}

// The `@(wakes_on_drop)` type the carrier at `path` in a `type` value belongs
// to: a marked type the path passes through, or one the carrier, or a
// truncated path's subtree, reaches. INVALID_TYPE for a carrier outside every
// marked subvalue. A generic record whose type argument reaches a marked type
// may hold one where no field shows it, behind a `rawptr`, so each of its
// carriers belongs to that type. A union's variants share one wildcard step,
// so any of them may be the one; a step this does not recognize answers for
// the whole place.
@(private = "file")
path_waker :: proc(c: ^Compiler, type: Type_Id, path: []Proj_Step) -> Type_Id {
	info := type_of(c, type)
	if info == nil {
		return INVALID_TYPE
	}
	if info.wakes_on_drop {
		return type
	}
	if len(path) == 0 || type_is_carrier(c, type) {
		return type_reaches_waker(c, type)
	}
	step, rest := path[0], path[1:]
	if payload := shared_payload_type(c, type); payload != INVALID_TYPE {
		return path_waker(c, payload, rest)
	}
	#partial switch info.kind {
	case .Distinct:
		return path_waker(c, info.element, path)
	case .Struct:
		for arg in info.instance_args {
			if arg.is_type {
				if found := type_reaches_waker(c, arg.type); found != INVALID_TYPE {
					return found
				}
			}
		}
		if step.kind == .Field {
			for field in info.fields {
				if sym := symbol_of(c, field); sym != nil && i64(sym.index) == step.lo {
					return path_waker(c, sym.type, rest)
				}
			}
		}
	case .Union:
		for variant in info.variants {
			if found := path_waker(c, variant, rest); found != INVALID_TYPE {
				return found
			}
		}
		return INVALID_TYPE
	case .Array, .Dynamic_Array, .Box:
		return path_waker(c, info.element, rest)
	case .Map:
		if len(rest) > 0 && rest[0].kind == .Field {
			return path_waker(c, rest[0].lo == PROJ_MAP_KEY ? info.key : info.element, rest[1:])
		}
	}
	return type_reaches_waker(c, type)
}

// A borrowed parameter: the caller keeps what it reaches past every join here.
// A `move` parameter is this procedure's own, kept only while a local would be.
@(private = "file")
kept_by_caller :: proc(sym: ^Symbol) -> bool {
	return sym.kind == .Parameter && sym.mode != .Move
}

// A loan a task of the block holds whose storage may overlap `retained`'s.
@(private = "file")
task_loan_overlapping :: proc(state: ^Prov_State, held: []int, retained: Prov_Loan, reached: ^map[Root_Id]Reached_Storage) -> (Prov_Loan, bool) {
	graph := state.graph
	for slot in held {
		row := reach_row(state, state.reach, slot)
		for index in 0 ..< state.loans {
			if !bit_get(row, index) || state.ended[index] {
				continue
			}
			task := graph.loans[index]
			if loans_may_share_storage(graph, retained, task, reached) {
				return task, true
			}
		}
	}
	return {}, false
}

// Two loans may borrow overlapping storage: one root and overlapping paths,
// or roots the body cannot tell apart. Unknown storage may be anything, and a
// parameter's may be the caller's storage another parameter or a global names,
// unless their types rule it out; a local of this body is neither.
@(private = "file")
loans_may_share_storage :: proc(graph: ^Flow_Graph, a, b: Prov_Loan, reached: ^map[Root_Id]Reached_Storage) -> bool {
	if a.root == b.root {
		return paths_overlap(a.path, b.path)
	}
	first, second := graph.roots[int(a.root)].kind, graph.roots[int(b.root)].kind
	if first == .Unknown || second == .Unknown {
		return true
	}
	external :: proc(kind: Root_Kind) -> bool {
		#partial switch kind {
		case .Param, .Static, .Thread_Local, .Materialized:
			return true
		}
		return false
	}
	if !((first == .Param && external(second)) || (second == .Param && external(first))) {
		return false
	}
	return roots_may_share_storage(graph, a.root, b.root, reached)
}

// What storage a root's symbol may borrow, by object type: `objects` holds the
// symbol's own type and the type of everything it reaches, `unknown` that it
// reaches storage of no known type.
@(private = "file")
Reached_Storage :: struct {
	objects: [dynamic]Type_Id,
	unknown: bool,
}

// design.md "Releasing before the join": two external roots share no storage
// when no object one reaches holds, inline, an object the other reaches, or
// is held by one. Storage of one type lies within storage of another only as a
// field, element, or variant, so two objects that overlap are nested.
@(private = "file")
roots_may_share_storage :: proc(graph: ^Flow_Graph, a, b: Root_Id, reached: ^map[Root_Id]Reached_Storage) -> bool {
	c := graph.k.c
	first, second := root_reached_storage(graph, a, reached), root_reached_storage(graph, b, reached)
	if first.unknown || second.unknown {
		return true
	}
	for outer in first.objects {
		for inner in second.objects {
			if type_holds_inline(c, outer, inner) || type_holds_inline(c, inner, outer) {
				return true
			}
		}
	}
	return false
}

@(private = "file")
root_reached_storage :: proc(graph: ^Flow_Graph, root: Root_Id, reached: ^map[Root_Id]Reached_Storage) -> Reached_Storage {
	if found, cached := reached[root]; cached {
		return found
	}
	c := graph.k.c
	result := Reached_Storage{objects = make([dynamic]Type_Id, 0, 8, graph.alloc)}
	if sym := symbol_of(c, graph.roots[int(root)].symbol); sym != nil && sym.type != INVALID_TYPE {
		append(&result.objects, sym.type)
		inside := make([dynamic]Type_Id, 0, 8, context.temp_allocator)
		for index := 0; index < len(result.objects) && !result.unknown; index += 1 {
			result.unknown = !collect_pointees(c, result.objects[index], &result.objects, &inside)
		}
	} else {
		result.unknown = true
	}
	reached[root] = result
	return result
}

// Appends to `objects` the type of each object a value of `type` points to,
// owns out of line, or views; false when it holds a raw or foreign pointer or
// an erased view, whose target may be storage of any type. An allocator's
// state is its own, and a procedure value holds no state. `inside` holds the
// types the walk is within, so a record already diagnosed as holding itself
// by value counts as unknown storage rather than recursing forever. A
// body-local type skips the package's finite-size phase, so `size_state`
// alone would miss its cycle, and a path rather than a visited set keeps two
// sibling fields of one type from looking like a cycle.
@(private = "file")
collect_pointees :: proc(c: ^Compiler, type: Type_Id, objects: ^[dynamic]Type_Id, inside: ^[dynamic]Type_Id) -> bool {
	add :: proc(objects: ^[dynamic]Type_Id, type: Type_Id) {
		if !slice.contains(objects[:], type) {
			append(objects, type)
		}
	}
	info := type_of(c, type)
	if info == nil || slice.contains(inside[:], type) {
		return false
	}
	append(inside, type)
	defer pop(inside)
	#partial switch info.kind {
	case .Raw_Pointer, .C_Pointer, .Any_View, .Dyn, .Interface, .Type, .Invalid:
		return false
	case .Distinct, .Array, .Simd:
		return collect_pointees(c, info.element, objects, inside)
	case .Pointer, .Slice, .Dynamic_Array, .Box:
		add(objects, info.element)
	case .Map:
		add(objects, info.key)
		add(objects, info.element)
	case .String, .String_View, .CString_View:
		add(objects, TYPE_U8)
	case .Struct:
		for field in info.fields {
			if sym := symbol_of(c, field); sym != nil && !collect_pointees(c, sym.type, objects, inside) {
				return false
			}
		}
	case .Union:
		for variant in info.variants {
			if !collect_pointees(c, variant, objects, inside) {
				return false
			}
		}
	}
	return true
}

// Whether storage of type `outer` holds storage of type `inner` within its own
// bytes: itself, or a field, element, or variant, at any depth. A distinct type
// shares its storage with what it wraps, and a view's mutability is not part
// of its storage. `outer` must be one `collect_pointees` walked without finding
// unknown storage, which rules out a record holding itself by value along the
// same edges this follows.
@(private = "file")
type_holds_inline :: proc(c: ^Compiler, outer, inner: Type_Id) -> bool {
	if same_storage_type(c, outer, inner) {
		return true
	}
	info := type_of(c, outer)
	if info == nil {
		return true
	}
	#partial switch info.kind {
	case .Distinct, .Array, .Simd:
		return type_holds_inline(c, info.element, inner)
	case .Struct:
		for field in info.fields {
			if sym := symbol_of(c, field); sym != nil && type_holds_inline(c, sym.type, inner) {
				return true
			}
		}
	case .Union:
		for variant in info.variants {
			if type_holds_inline(c, variant, inner) {
				return true
			}
		}
	}
	return false
}

// Two types share one storage layout: the same underlying type, or pointers or
// views of such. A distinct pointer to itself bounds the walk as
// `type_underlying` bounds its own.
@(private = "file")
same_storage_type :: proc(c: ^Compiler, a, b: Type_Id) -> bool {
	first, second := a, b
	for _ in 0 ..< len(c.types) + 1 {
		first, second = type_underlying(c, first), type_underlying(c, second)
		if first == second {
			return true
		}
		x, y := type_of(c, first), type_of(c, second)
		if x == nil || y == nil || x.kind != y.kind || x.kind != .Pointer && x.kind != .Slice {
			return false
		}
		first, second = x.element, y.element
	}
	return true
}

@(private = "file")
report_join_retention :: proc(state: ^Prov_State, event: Prov_Event, sym: ^Symbol, waker: Type_Id, retained, task: Prov_Loan) {
	c := state.k.c
	graph := state.graph
	name := identifier_text(c, sym.name)
	root := graph.roots[int(retained.root)]
	if kept_by_caller(sym) {
		errorf(
			c, event.span, "L0733",
			"the caller keeps `%s` past this join, and it may borrow storage a task of the block borrows too; dropping it may be what the task waits for",
			name,
		)
		if sym.span.file != NO_FILE {
			add_notef(c, sym.span, "`%s` is a parameter, so ending this procedure's borrow of it does not drop it", name)
		}
	} else {
		// An owned parameter's own borrows are of what its caller passed.
		borrowed := root_phrase(root)
		if root.kind == .Param && symbol_of(c, root.symbol) == sym {
			borrowed = "storage its caller passed"
		}
		errorf(
			c, event.span, "L0733",
			"`%s` is kept past this join while it borrows %s, which a task of the block borrows too; dropping it may be what the task waits for",
			name, borrowed,
		)
		if sym.span.file != NO_FILE {
			add_notef(c, sym.span, "`%s` is declared here, outside the block; drop it or move it to a task before the join", name)
		}
	}
	if waker != sym.type {
		add_notef(c, sym.span, "it holds or reaches `%s`, which is `@(wakes_on_drop)`", type_name(c, waker))
	}
	if task.span.file != NO_FILE {
		add_notef(c, task.span, "a task borrows it here")
	}
}

// The span of the innermost `parallel` keyword whose tasks may be running.
@(private = "file")
window_block_span :: proc(state: ^Prov_State, window: u64) -> Span {
	graph := state.graph
	innermost := -1
	for site in running_sites(graph, window) {
		innermost = max(innermost, graph.task_sites[site].block)
	}
	if innermost >= 0 {
		if scope := symbol_of(state.k.c, graph.parallel_scopes[innermost]); scope != nil {
			return scope.span
		}
	}
	return {}
}

// design.md "Allocators and tasks": two reserved sets conflict where they may
// name one region. A parameter may be any handle its caller passes, so two
// may be the same; a local region is distinct from any that existed at
// entry; an unknown region may be any of them.
@(private = "file")
reservations_conflict :: proc(a, b: Region_Set) -> bool {
	if region_is_empty(a) || region_is_empty(b) {
		return false
	}
	if a.unknown || b.unknown || a.crowded || b.crowded {
		return true
	}
	return (region_is_parameter_backed(a) && region_is_parameter_backed(b)) || a.locals & b.locals != 0
}

// The region two reserved sets may share, said as a diagnostic names it.
@(private = "file")
shared_region_text :: proc(state: ^Prov_State, a, b: Region_Set) -> string {
	graph := state.graph
	c := state.k.c
	common := a.locals & b.locals
	for position in 0 ..< 64 {
		if common & (u64(1) << uint(position)) != 0 && position < len(graph.provider_symbols) {
			if sym := symbol_of(c, graph.provider_symbols[position]); sym != nil {
				return fmt.tprintf("`%s`'s allocator", identifier_text(c, sym.name))
			}
		}
	}
	if region_is_parameter_backed(a) && region_is_parameter_backed(b) && graph.literal != nil {
		if owner := symbol_of(c, graph.literal.symbol); owner != nil {
			for wanted, index in a.params {
				if wanted && index < len(owner.param_symbols) {
					if sym := symbol_of(c, owner.param_symbols[index]); sym != nil {
						return fmt.tprintf("the allocator `%s` was given", identifier_text(c, sym.name))
					}
				}
			}
		}
	}
	return "an allocator region this procedure cannot tell apart from it"
}

// A task reserves the regions it may use until the join, so no other task
// that may be running uses them, nor another from the same spawn in a loop.
@(private = "file")
check_task_reservation :: proc(state: ^Prov_State, event: Prov_Event, window: u64) {
	graph := state.graph
	c := state.k.c
	site := graph.task_sites[event.slot]
	for other in running_sites(graph, window) {
		reserved := graph.task_sites[other]
		if !reservations_conflict(site.reserve, reserved.reserve) {
			continue
		}
		region := shared_region_text(state, site.reserve, reserved.reserve)
		if other == event.slot {
			errorf(
				c, event.span, "L0732",
				"this task may use %s, which the task this `spawn` started on an earlier iteration reserves until the join",
				region,
			)
			add_notef(c, event.span, "an allocator that is not the default provider serves one task at a time; give each task its own")
		} else {
			errorf(c, event.span, "L0732", "this task may use %s, which a task started earlier reserves until the join", region)
			add_notef(c, reserved.span, "that task is started here")
		}
		return
	}
}

// The parent may not use a region a running task reserves, cleanup included.
@(private = "file")
check_parent_allocator_use :: proc(state: ^Prov_State, event: Prov_Event, window: u64) {
	graph := state.graph
	c := state.k.c
	for other in running_sites(graph, window) {
		reserved := graph.task_sites[other]
		if !reservations_conflict(event.region, reserved.reserve) {
			continue
		}
		errorf(
			c, event.span, "L0732",
			"this uses %s, which a running task reserves until this `parallel` block joins",
			shared_region_text(state, event.region, reserved.reserve),
		)
		add_notef(c, reserved.span, "that task is started here")
		return
	}
}

@(private = "file")
first_report :: proc(shared: ^Shared_Reports, span: Span, global: Symbol_Id) -> bool {
	key := Shared_Report{span = span, global = global}
	if shared.seen[key] {
		return false
	}
	shared.seen[key] = true
	return true
}

@(private = "file")
report_parent_write :: proc(state: ^Prov_State, event: Prov_Event, window: u64, shared: ^Shared_Reports) {
	c := state.k.c
	if !first_report(shared, event.span, event.symbol) {
		return
	}
	sym := symbol_of(c, event.symbol)
	how := event.name if event.name != "" else "written"
	errorf(
		c, event.span, "L0731",
		"`%s` is %s while this `parallel` block's tasks may be running, and every thread shares it",
		identifier_text(c, sym.name), how,
	)
	add_notef(c, window_block_span(state, window), "a task runs from its `spawn` until this block ends")
	add_notef(c, sym.span, "declared here; write it before the first `spawn` or after the block, or make it an `Atomic` or a `thread.Mutex`")
}

@(private = "file")
report_shared_reach :: proc(
	state: ^Prov_State, global: Symbol_Id, span: Span, window: u64, shared: ^Shared_Reports, callee := "",
) {
	c := state.k.c
	hazard := shared_carrier_hazard(c, global)
	if hazard.type == INVALID_TYPE || !first_report(shared, span, global) {
		return
	}
	who := "this" if callee == "" else callee
	errorf(
		c, span, "L0731",
		"%s reaches through `%s` while this `parallel` block's tasks may be running: %s",
		who, identifier_text(c, symbol_of(c, global).name), shared_hazard_text(c, global, hazard),
	)
	add_notef(c, window_block_span(state, window), "a task runs from its `spawn` until this block ends")
}

// design.md "Spawn statements", "Global write effects": a task that calls a
// procedure value or through a `dyn` view may run any body its values or
// union hold, and a callee runs what the task passes for each callback it
// calls, so each body that writes, or reaches through, the reported global is
// named, a callback with the parameter it was passed for.
@(private = "file")
note_value_targets :: proc(state: ^Prov_State, call: ^Expr_Call, global: Symbol_Id, writes: bool) {
	c := state.k.c
	if call == nil || state.graph.literal == nil {
		return
	}
	verb := "writes" if writes else "reaches through"
	global_name := identifier_text(c, symbol_of(c, global).name)
	for origin in call_effect_origins(c, state.graph.literal.symbol, call, global, writes) {
		sym := symbol_of(c, origin.target)
		if sym == nil {
			continue
		}
		target_name := fmt.tprintf("`%s`", identifier_text(c, sym.name))
		if sym.proc_literal != nil {
			target_name = "the procedure literal here"
		} else if type_is_capture_record(c, sym.owner_type) {
			target_name = "the capture literal here"
		} else if sym.owner_type != INVALID_TYPE {
			target_name = fmt.tprintf("`%s.%s`", type_name(c, sym.owner_type), identifier_text(c, sym.name))
		}
		callee := symbol_of(c, origin.callee)
		if callee == nil || origin.parameter >= len(callee.param_symbols) {
			add_notef(c, sym.span, "`%s` may be %s, which %s `%s`", spawn_callee_name(c, call), target_name, verb, global_name)
			continue
		}
		parameter := symbol_of(c, callee.param_symbols[origin.parameter])
		add_notef(
			c, sym.span, "`%s` may call %s for `%s`, which %s `%s`", identifier_text(c, callee.name), target_name,
			identifier_text(c, parameter.name), verb, global_name,
		)
	}
}

// A task does what its procedure's settled summaries say, and reaches through
// what it is given; every task also runs each `thread_local` owner's drop when
// its thread exits, reported once per block.
@(private = "file")
check_task_globals :: proc(state: ^Prov_State, event: Prov_Event, shared: ^Shared_Reports) {
	c := state.k.c
	call := state.graph.task_sites[event.slot].call
	for global in c.global_writes[event.symbol] {
		sym := symbol_of(c, global)
		if sym == nil || sym.duration == .Thread_Local || sym.synchronized || !first_report(shared, event.span, global) {
			continue
		}
		errorf(
			c, event.span, "L0731",
			"`%s` may write `%s`, which every task and the parent share",
			event.name, identifier_text(c, sym.name),
		)
		add_notef(c, sym.span, "declared here; return what the task computes, or make it an `Atomic` or a `thread.Mutex`")
		note_value_targets(state, call, global, true)
	}
	for reached in c.reach_effects[event.symbol] {
		hazard := shared_carrier_hazard(c, reached.global)
		if hazard.type == INVALID_TYPE || !first_report(shared, event.span, reached.global) {
			continue
		}
		errorf(
			c, event.span, "L0731",
			"`%s` reaches through `%s`, which every task and the parent share: %s",
			event.name, identifier_text(c, symbol_of(c, reached.global).name),
			shared_hazard_text(c, reached.global, hazard),
		)
		note_reach_chain(c, reached)
		note_value_targets(state, call, reached.global, false)
	}
	given := make([dynamic]Global_Effect, 0, 2, state.graph.alloc)
	for slot in event.sources {
		note_reached_globals(state, slot, event.span, &given)
	}
	for reached in given {
		hazard := shared_carrier_hazard(c, reached.global)
		if hazard.type == INVALID_TYPE || !first_report(shared, event.span, reached.global) {
			continue
		}
		errorf(
			c, event.span, "L0731",
			"this task is given what `%s` stores, which every task and the parent share: %s",
			identifier_text(c, symbol_of(c, reached.global).name), shared_hazard_text(c, reached.global, hazard),
		)
	}
	index := state.graph.task_sites[event.slot].block
	if shared.scopes[index] {
		return
	}
	shared.scopes[index] = true
	block := event.span
	if scope := symbol_of(c, state.graph.parallel_scopes[index]); scope != nil {
		block = scope.span
	}
	for drop in c.thread_exit_drops {
		if drop.hook == INVALID_SYMBOL {
			continue
		}
		owner := symbol_of(c, drop.variable)
		hook := symbol_of(c, drop.hook)
		for global in drop.writes {
			sym := symbol_of(c, global)
			if sym == nil || sym.duration == .Thread_Local || sym.synchronized {
				continue
			}
			errorf(
				c, block, "L0731",
				"each task of this block drops `%s` when its thread exits, and its hook `%s` writes `%s`, which every thread shares",
				identifier_text(c, owner.name), identifier_text(c, hook.name), identifier_text(c, sym.name),
			)
			add_notef(c, owner.span, "`%s` is declared here", identifier_text(c, owner.name))
			add_notef(c, hook.span, "`%s` is declared here", identifier_text(c, hook.name))
		}
		for reached in drop.reach {
			hazard := shared_carrier_hazard(c, reached.global)
			if hazard.type == INVALID_TYPE {
				continue
			}
			errorf(
				c, block, "L0731",
				"each task of this block drops `%s` when its thread exits, and its hook `%s` reaches through `%s`: %s",
				identifier_text(c, owner.name), identifier_text(c, hook.name),
				identifier_text(c, symbol_of(c, reached.global).name), shared_hazard_text(c, reached.global, hazard),
			)
			add_notef(c, owner.span, "`%s` is declared here", identifier_text(c, owner.name))
		}
	}
}

// Where a task's summarized reach comes from: each call on the way, from the
// spawned procedure's, to the access itself. The run procedure's own call of
// the spawned one is the spawn, and is not repeated.
@(private = "file")
note_reach_chain :: proc(c: ^Compiler, reached: Global_Effect) {
	source := reached.source
	for step := 0; step < 8; step += 1 {
		via := symbol_of(c, source.via)
		if via == nil {
			if source.span != (Span{}) {
				add_notef(c, source.span, "reached here")
			}
			return
		}
		if step > 0 {
			add_notef(c, source.span, "through `%s`", identifier_text(c, via.name))
		}
		next, found := Effect_Source{}, false
		for entry in c.reach_effects[source.via] {
			if entry.global == reached.global {
				next, found = entry.source, true
				break
			}
		}
		if !found {
			return
		}
		source = next
	}
}

// design.md "Borrows crossing between tasks": each thread has its own
// `thread_local` storage, so no borrow of it crosses between a task and its
// parent, in either direction. A worker may use its own within itself.
@(private = "file")
check_crossing :: proc(state: ^Prov_State, event: Prov_Event) {
	graph := state.graph
	for source in event.sources {
		row := reach_row(state, state.reach, source)
		for index in 0 ..< state.loans {
			if !bit_get(row, index) || state.ended[index] {
				continue
			}
			loan := graph.loans[index]
			root := graph.roots[int(loan.root)]
			if root.kind != .Thread_Local || loan.what == WRITTEN_BACK_BORROW {
				continue
			}
			// design.md "Minimum provenance precision": with the dependency merged,
			// the borrow may only seem to be there.
			merged := state.diagnostic_precision != {}
			if event.verb == "result" {
				errorf(
					state.k.c, event.span, "L0730",
					"this task's result %s a %s of %s, which is the worker's own `thread_local` storage, so it cannot cross to the parent",
					merged ? "may hold" : "holds", loan.what, root_phrase(root),
				)
			} else {
				errorf(
					state.k.c, event.span, "L0730",
					"this task %s a %s of %s, which is the parent's own `thread_local` storage, so it cannot cross to the task",
					merged ? "may be handed" : "is handed", loan.what, root_phrase(root),
				)
			}
			if root.span.file != NO_FILE {
				add_notef(state.k.c, root.span, "each thread has its own `thread_local` storage, which ends with that thread")
			}
			return
		}
	}
}

// Whether a reset ends storage rooted here: a control block the provider's
// destruction ends, in a region it may name or one never recorded. `free_all`
// leaves handles usable.
@(private = "file")
reset_ends_root :: proc(root: Prov_Root, event: Prov_Event) -> bool {
	if root.kind != .Provider || !event.provider_end {
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
	case .Cross:
		check_crossing(state, event)
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
	case .Task_Join:
		check_join_retention(state, event, live)
	case .Live, .Load:
		// A reborrow suspends its source until its own last use, and the last use
		// of whatever was reborrowed from it in turn.
		for source in event.sources {
			if reborrow, derived, found := live_reborrow_of(state, source, live, event); found {
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
		sources := prov_join(graph, event.sources, event.into)
		// A result backed by a region created here, as an owner or an allocation.
		escape_region := Region_Set{params = make([]bool, max(graph.param_count, 1), graph.alloc)}
		region_merge(&escape_region, event.region)
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
		for source in sources {
			row := reach_row(state, state.reach, source)
			for index in 0 ..< state.loans {
				if !bit_get(row, index) || state.ended[index] {
					continue
				}
				loan := graph.loans[index]
				root := graph.roots[int(loan.root)]
				if root_outlives_body(root.kind) || root_names_source(graph, root) {
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
		if event.moved != "" {
			errorf(
				state.k.c,
				event.span,
				"L0536",
				"`%s` was received by `move`, and its `@(escape=...)` level does not let it be stored in %s",
				event.moved,
				event.name,
			)
			return
		}
		if region_has_local(event.region) {
			errorf(
				state.k.c,
				event.span,
				"L0536",
				"%s is backed by an allocator region created in this procedure, so it cannot be stored in %s, which outlives that region",
				event.verb,
				event.name,
			)
			return
		}
		errorf(
			state.k.c,
			event.span,
			"L0536",
			"%s is backed by an allocator region this procedure received, so it cannot be stored in %s, which outlives that region",
			event.verb,
			event.name,
		)
	}
}

// The first reborrow of `source` that a live slot still depends on, directly or
// through reborrows of the reborrow, and that live slot.
@(private = "file")
live_reborrow_of :: proc(state: ^Prov_State, source: int, live: []bool, use: Prov_Event) -> (Prov_Reborrow, int, bool) {
	graph := state.graph
	visited := make(map[int]bool, 8, context.temp_allocator)
	pending := make([dynamic]int, 0, 8, context.temp_allocator)
	for reborrow, index in graph.reborrows {
		// Only a mutable reborrow excludes a read; what is derived from a
		// read-only one is read-only too. A severed one was taken from an
		// earlier value of a fresh source.
		if reborrow.source != source || reborrow.passes_on || (use.reads_only && !reborrow.mutable) || (index < len(state.severed) && state.severed[index]) {
			continue
		}
		// A use going through the source elsewhere in its pointee, or replacing
		// what was copied out.
		if reborrow.through && use.kind == .Live && use.through && (use.stores || !paths_overlap(reborrow.path, use.through_path)) {
			continue
		}
		clear(&pending)
		clear(&visited)
		// What was derived from `source` and stored back into it, as `cur =
		// cur^.next`, is its current value, not a competing use.
		visited[source] = true
		append(&pending, reborrow.derived)
		for len(pending) > 0 {
			slot := pop(&pending)
			if visited[slot] {
				continue
			}
			visited[slot] = true
			// An overwritten intermediate no longer overlaps `source`, but something
			// derived from its previous value still can.
			if live[slot] && prov_slots_overlap(state, source, slot, reborrow.through) {
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
// loan, so overwriting either one ends the reborrow. Read `through` the source,
// the derived slot holds a loan of the root the source's names instead.
@(private = "file")
prov_slots_overlap :: proc(state: ^Prov_State, source_slot, derived_slot: int, through := false) -> bool {
	source := reach_row(state, state.reach, source_slot)
	derived := reach_row(state, state.reach, derived_slot)
	for index in 0 ..< state.loans {
		if !bit_get(source, index) || state.ended[index] {
			continue
		}
		if bit_get(derived, index) {
			return true
		}
		if !through {
			continue
		}
		root := state.graph.loans[index].root
		for other in 0 ..< state.loans {
			if bit_get(derived, other) && !state.ended[other] && state.graph.loans[other].root == root {
				return true
			}
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
	if event.ends_result {
		errorf(
			state.k.c,
			event.span,
			"L0537",
			"%s would end the region backing the returned value, which the caller already holds when deferred statements run",
			event.ends != "" ? event.ends : "this reset",
		)
		add_notef(state.k.c, event.owner_span, "the value is returned here")
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
		if from, unwinding := event.unwind_from.?; unwinding {
			add_notef(state.k.c, from, "a panic in this statement unwinds through the cleanup, before `%s` is dropped", event.verb)
		}
		return
	}
	it := live_loans(state, live)
	for slot, index in next_live_loan(&it) {
		loan := graph.loans[index]
		root := graph.roots[int(loan.root)]
		if !reset_ends_root(root, event) {
			continue
		}
		// A result backed by this frame's region is the `Escape` event's error.
		if graph.prov_slots[slot].returned && region_is_local_only(root.region) {
			continue
		}
		if root.kind == .Provider {
			errorf(state.k.c, event.span, "L0537", "%s would end an allocator control block whose handle is still in use", event.ends != "" ? event.ends : "this cleanup")
		} else {
			errorf(state.k.c, event.span, "L0537", "this reset ends every allocation in the region, but a %s of one of them is still in use", loan.what)
		}
		state.diagnostic_precision |= state.precision[slot]
		add_notef(state.k.c, loan.span, "the %s is created here", loan.what)
		add_use_note(state, uses[slot])
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
		// design.md "@(synchronized)": such an access counts as a write, and a
		// borrow of the field as a mutable one, whatever was written.
		access := event.access == .Write ? "write" : "read"
		if path_is_synchronized(event.path) {
			access = "access through a synchronized field"
		}
		errorf(
			k.c,
			event.span,
			"L0511",
			conflicting,
			access,
			root_label(root),
			path_is_synchronized(loan.path) ? "exclusive" : loan.mutable ? "mutable" : "read-only",
			loan.what,
		)
	}
	add_borrow_notes(state, root, loan, later)
	note_last_use_move(k.c, event.verb)
}

// A move the program did not write needs saying where it came from.
@(private = "file")
note_last_use_move :: proc(c: ^Compiler, verb: string) {
	if verb == LAST_USE_VERB {
		add_notef(c, no_span(), "a copy of a local that nothing reads afterwards moves it; write `.clone()` to copy it instead")
	}
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
	add_use_note(state, later)
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
		if root.kind == .Temporary && root.extended {
			add_notef(k.c, root.span, "%s is kept until the end of the block that created it", label)
		} else if root.kind == .Temporary {
			add_notef(k.c, root.span, "%s ends with the statement that created it", label)
		} else {
			add_notef(k.c, root.span, "%s is declared here and ends with its scope", label)
		}
	}
	add_notef(k.c, loan.span, "the %s is created here", loan.what)
	// design.md "Task borrows and the join": the block's own
	// locals end before its join.
	for scope in state.graph.task_slots {
		if sym := symbol_of(k.c, scope); sym != nil && sym.span == later {
			add_notef(
				k.c, later,
				"a task holds the %s until this `parallel` block joins, after its own locals end; declare the storage before the block, or spawn from a `parallel` block nested after it",
				loan.what,
			)
			break
		}
	}
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
	for scope in state.graph.task_slots {
		if sym := symbol_of(state.k.c, scope); sym != nil && sym.span == later {
			add_notef(state.k.c, later, "and a task holds it until this `parallel` block joins, which keeps it live")
			return
		}
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
		for slot, index in next_live_loan(&it) {
			target := graph.loans[index].root
			if seen[target] {
				continue
			}
			seen[target] = true
			destination := graph.roots[int(target)]
			into := retain_kind_for_root(destination.kind)
			if into != .None && report_retention(state, event, into, target, destination, state.precision[slot]) {
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
// destination; returns whether it did. `destination_loss` is the precision of
// the carrier that names the destination.
//
// design.md "Minimum provenance precision": a merged dependency may be the
// only reason the value looks like a borrow of that storage, or the carrier
// like one naming that destination, so the message says each may be so.
@(private = "file")
report_retention :: proc(
	state: ^Prov_State,
	event: Prov_Event,
	into: Retain_Kind,
	target: Root_Id,
	destination: Prov_Root,
	destination_loss: Precision_Loss = {},
) -> bool {
	graph := state.graph
	borrows := state.diagnostic_precision != {} ? "may borrow" : "borrows"
	stored := destination_loss != {} ? ", where it may be stored" : ""
	for source in event.sources {
		row := reach_row(state, state.reach, source)
		for index in 0 ..< state.loans {
			if !bit_get(row, index) || state.ended[index] {
				continue
			}
			loan := graph.loans[index]
			root := graph.roots[int(loan.root)]
			// Storing into the same storage is not retention. A parameter has two
			// roots (entry loan and places), so compare the symbol too. A new
			// borrow of a parameter's own storage is, since the caller's root would
			// then borrow itself.
			same := loan.root == target || (root.symbol != INVALID_SYMBOL && root.symbol == destination.symbol)
			if same && (root.kind != .Param || loan.content) {
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
					"this %s %s %s, which is not written `@(escape=%s)`, so it cannot reach %s%s",
					loan.what,
					borrows,
					root_phrase(root),
					escape_level_name(retain_kind_level(into)),
					retain_destination(event, destination),
					stored,
				)
			} else {
				if root_satisfies_retention(root.kind, into) || root_names_source(graph, root) {
					continue
				}
				errorf(
					state.k.c,
					event.span,
					"L0647",
					"this %s %s %s, which does not outlive %s%s: %s",
					loan.what,
					borrows,
					root_phrase(root),
					retain_destination(event, destination),
					stored,
					retain_kind_text(into),
				)
			}
			state.diagnostic_precision |= destination_loss
			if root.symbol != INVALID_SYMBOL && root.span.file != NO_FILE {
				add_notef(state.k.c, root.span, "%s is declared here", root_label(root))
			}
			add_notef(state.k.c, loan.span, "the %s is created here", loan.what)
			// design.md "@(cross_thread)": this is why one cannot reach a thread.
			if root.kind == .Thread_Local && into == .Process {
				add_notef(state.k.c, root.span, "each thread has its own `thread_local` storage, which ends with that thread")
			}
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


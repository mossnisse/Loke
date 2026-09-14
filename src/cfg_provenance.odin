// Provenance event vocabulary and construction for the disposable flow graph.
// cfg.odin owns traversal, control-flow topology, and lifecycle events;
// borrow.odin solves the root and region facts recorded here.
package lokec

import "core:fmt"
import "core:slice"

// ------------------------------------------------------ provenance events --

// Event vocabulary the root and region lattices read. Kept separate from the
// lifecycle events in cfg.odin: the two analyses share block topology and source
// order, not the facts they record.
Prov_Kind :: enum u8 {
	// A carrier slot receives a value: union of its source slots plus one fresh
	// loan.
	Def,
	// A carrier slot is read. This is what makes a loan live to its last use.
	Live,
	// Storage is reached through a name that is not a live borrow of it.
	Access,
	// A root's storage ends, so every loan of it does too.
	Root_End,
	// A value leaves the body through `return`.
	Escape,
	// `free`, which needs an allocation base and ends that allocation root.
	Free,
	// A borrow stored somewhere that outlives the statement: process/thread
	// storage, or caller-owned storage. `retain` says which.
	Retain,
	// An allocator region reset: `free_all`, or a call through a parameter marked
	// `@(allocator_reset)`.
	Reset,
	// An owner backed by a received allocator region is stored somewhere that
	// outlives that region.
	Region_Escape,
	// A value written through a carrier: `p^.view = values`, or an argument the
	// callee may keep. Unlike `Def`, the destination depends on the carrier's
	// own loans, so it resolves while solving — and joins rather than replaces,
	// since the carrier may name more than one root.
	Publish,
	// A value read through a carrier; like a Publish target, its content slots
	// are only known after reaching loans are solved.
	Load,
}

// design.md "Capabilities and the one rule": a read is compatible with a
// read-only borrow, a write is not, an invalidation ends the value outright.
Access_Kind :: enum u8 {
	Read,
	Write,
	Invalidate,
}

Prov_Event :: struct {
	precision: Precision_Loss,
	kind:    Prov_Kind,
	span:    Span,
	slot:    int,
	loan:    Loan_Id,
	sources: []int,
	root:    Root_Id,
	path:    []Proj_Step,
	access:  Access_Kind,
	verb:    string,
	name:    string,
	// `Retain`: what kind of storage the destination is. `name` is how a
	// diagnostic spells it and `verb` names the destination.
	retain: Retain_Kind,
	// `Retain`: the carrier the place was written through when it left lexical
	// storage (`p^.view`, `d[0].view`, a `^mut` argument). Its reaching loans
	// name the destination roots, so `retain`/`root` are resolved by the
	// solver, not here.
	// `Load`: `into` holds the addressing carriers, `path` the projection below
	// their pointees, `slot` the content. `sources` fills with resolved content
	// reads before solving liveness.
	into: []int,
	// `Escape`: the allocator region an owning result carries with it.
	region:         Region_Set,
	region_content: []Prov_Region_Content,
	// `Reset`: whether the promise this reset needs is already written. `access`
	// selects the form: `Invalidate` for a direct `free_all`, `Write` for
	// handing an allocator parameter onward.
	reset_covered: bool,
	owner_span:    Span,
	// `Live`: re-establishes the loans it names rather than just keeping them
	// alive. A loop head re-reads its iterable each iteration, so a body
	// invalidation must not travel the back edge and kill the next one's
	// iterator.
	revives:       bool,
}

// A borrowed parameter arrives holding the caller's storage, which the entry
// block installs before the first statement.
Prov_Entry_Def :: struct {
	slot: int,
	loan: Loan_Id,
}

// The one result of a call: what it borrows and the allocator region it
// carries.
Prov_Call_Result :: struct {
	loans:          []int,
	region:         Region_Set,
	region_content: []Prov_Region_Content,
}

// A root's allocator expression is resolved once while walking and once after
// the body-wide, flow-insensitive region map has seen every assignment. Direct
// call summaries use the same delayed substitution so a call in a loop widens
// when its allocator argument is reassigned on the back edge.
Prov_Allocation_Region_Source :: struct {
	root:    Root_Id,
	value:   Expr,
	call:    ^Expr_Call,
	summary: Region_Set,
}

// Allocator backing is independent of contained borrow loans. Aggregate field
// writes therefore keep a parallel path-indexed region fact even when the field
// type has no carrier shape (for example `[dynamic]int`).
Prov_Region_Content :: struct {
	path:   []Proj_Step,
	region: Region_Set,
}

// The payload read out from under a union's wildcard alternative. Unwrapping a
// borrow-carrying value — a case binding, `or_else`, `or_return` — keeps every
// borrow the wrapper carried. An `any_view` reads through its data pointer
// instead, which is the read the extraction itself performs.
@(private)
prov_payload_content :: proc(
	graph: ^Flow_Graph, loans: []int, subject_type, payload_type: Type_Id, span: Span,
) -> []int {
	if len(loans) == 0 || payload_type == INVALID_TYPE || payload_type == subject_type {
		return loans
	}
	if subject_type == TYPE_ANY_VIEW {
		return prov_load_content(graph, loans, nil, payload_type, span)
	}
	if !type_is_union(graph.k.c, subject_type) {
		return loans
	}
	return prov_project_content(graph, loans, subject_type, {proj_wild()}, payload_type, span)
}

// What a case binding holds: the subject's own content when the case binds the
// union type, and the active variant's payload when it binds one variant.
@(private)
prov_case_payload :: proc(
	graph: ^Flow_Graph, s: ^Stmt_Switch, entry: Switch_Case, subject: []int,
) -> []int {
	if entry.binding_symbol == INVALID_SYMBOL || s.subject == nil {
		return subject
	}
	return prov_payload_content(
		graph, subject, expr_base(s.subject).type, entry.binding_type, entry.span,
	)
}

// The loan a binding that views another place holds. Without it the binding's
// own frame slot would answer for `&binding`, and a pointer taken from a view
// would escape every invalidation rule that protects its source.
@(private)
prov_bind_view :: proc(graph: ^Flow_Graph, id: Symbol_Id, loans: []int) {
	if id == INVALID_SYMBOL || len(loans) == 0 {
		return
	}
	graph.view_loans[id] = loans
}

// The borrow a switch over a place holds on its subject, for the payload
// binding to view.
@(private)
prov_subject_view :: proc(graph: ^Flow_Graph, subject: Expr) -> []int {
	if subject == nil {
		return nil
	}
	root, path, ok := prov_place_of(graph, subject)
	if !ok {
		return nil
	}
	return prov_borrow(graph, root, path, false, expr_span(subject), "payload")
}

// A case binding names the payload its subject held, so it inherits that
// subject's region: unwrapping a handle does not lose which region it names.
@(private)
prov_bind_case_region :: proc(graph: ^Flow_Graph, id: Symbol_Id, subject: Expr) {
	if id == INVALID_SYMBOL || subject == nil {
		return
	}
	sym := symbol_of(graph.k.c, id)
	if sym == nil {
		return
	}
	if type_underlying(graph.k.c, sym.type) != TYPE_ALLOCATOR &&
	   !type_is_managed(graph.k.c, sym.type) {
		return
	}
	if set := prov_region_of(graph, subject); !region_is_empty(set) {
		graph.region_of[id] = set
	}
}

// ------------------------------------------------- provenance construction --

// The provenance modes record what the two lattices in `src/borrow.odin` read.
// Everything below is pure graph construction: it may allocate in the graph's
// own arena and may read the typed AST, but never writes to it and never
// reports.

@(private)
prov_emit :: proc(graph: ^Flow_Graph, event: Prov_Event) {
	if graph.current == NO_BLOCK {
		return // unreachable code borrows nothing observable
	}
	if event.kind == .Reset || event.kind == .Region_Escape {
		graph.has_region_event = true
	}
	// A body that borrows nothing can still return an owner backed by an
	// allocator parameter or local region. Its result summary (including field
	// projections) therefore needs the solver even with no root-provenance loan.
	if event.kind == .Escape {
		graph.has_region_event ||= !region_is_empty(event.region)
		for content in event.region_content {
			graph.has_region_event ||= !region_is_empty(content.region)
		}
	}
	append(&graph.blocks[graph.current].prov, event)
}

@(private = "file")
prov_one :: proc(graph: ^Flow_Graph, slot: int) -> []int {
	out := make([]int, 1, graph.alloc)
	out[0] = slot
	return out
}

@(private)
prov_join :: proc(graph: ^Flow_Graph, a, b: []int) -> []int {
	if len(a) == 0 {
		return b
	}
	if len(b) == 0 {
		return a
	}
	out := make([]int, len(a) + len(b), graph.alloc)
	copy(out, a)
	copy(out[len(a):], b)
	return out
}

// design.md "or_return operator": the operator removes the *final* status, so
// every earlier result keeps its index and the per-result provenance of the
// operand applies unchanged to the expression's own results.
@(private = "file")
prov_through_or_return :: proc(value: Expr) -> Expr {
	if postfix, ok := value.(^Expr_Postfix); ok && postfix.op == .Or_Return {
		return postfix.operand
	}
	return value
}


@(private = "file")
prov_result_region :: proc(graph: ^Flow_Graph, value: Expr) -> Region_Set {
	if call, ok := prov_through_or_return(value).(^Expr_Call); ok {
		if result, found := graph.call_results[call]; found {
			return result.region
		}
	}
	return prov_region_of(graph, value)
}

// The allocator region carried by one projected result field. Calls keep a
// path-indexed companion to their conservative whole-result union; literals and
// places can be projected directly without first joining sibling fields.
@(private = "file")
prov_result_region_at :: proc(graph: ^Flow_Graph, value: Expr, path: []Proj_Step) -> Region_Set {
	if len(path) == 0 {
		return prov_result_region(graph, value)
	}
	#partial switch v in prov_through_or_return(value) {
	case ^Expr_Move:
		return prov_result_region_at(graph, v.value, path)
	case ^Expr_Cond:
		out := prov_empty_region(graph)
		region_merge(&out, prov_result_region_at(graph, v.then, path))
		region_merge(&out, prov_result_region_at(graph, v.otherwise, path))
		return out
	case ^Expr_Or_Else:
		out := prov_empty_region(graph)
		region_merge(&out, prov_result_region_at(graph, v.value, path))
		region_merge(&out, prov_result_region_at(graph, v.fallback, path))
		return out
	case ^Expr_Call:
		if result, found := graph.call_results[v]; found && len(result.region_content) > 0 {
			out := prov_empty_region(graph)
			matched := false
			for content in result.region_content {
				if paths_overlap(content.path, path) {
					matched = true
					region_merge(&out, content.region)
				}
			}
			if matched { return out }
		}
	case ^Expr_Composite:
		value_type := v.type
		is_array := underlying_kind(graph.k.c, value_type) == .Array
		out := prov_empty_region(graph)
		for _, index in v.elements {
			step, known := prov_element_step(graph, v, value_type, is_array, index)
			if known && paths_overlap({step}, path[:1]) && v.elements[index].value != nil {
				region_merge(&out, prov_result_region_at(graph, v.elements[index].value, path[1:]))
			}
		}
		return out
	}
	if root, base, ok := prov_place_of(graph, value); ok {
		projected := make([]Proj_Step, len(base) + len(path), graph.alloc)
		copy(projected, base)
		copy(projected[len(base):], path)
		return prov_region_content_at(graph, root, projected)
	}
	return prov_result_region(graph, value)
}

@(private)
prov_result_region_fields :: proc(graph: ^Flow_Graph, value: Expr, type: Type_Id) -> []Prov_Region_Content {
	info := underlying_info(graph.k.c, type)
	if info == nil || info.kind != .Struct {
		return nil
	}
	out := make([]Prov_Region_Content, len(info.fields), graph.alloc)
	for _, index in info.fields {
		path := make([]Proj_Step, 1, graph.alloc)
		path[0] = proj_field(index)
		out[index] = Prov_Region_Content {
			path = path,
			region = prov_result_region_at(graph, value, path),
		}
	}
	return out
}

// Returning a region provider transfers the provider's dependency, not the
// callee-local token that identifies allocations made *by* that provider. The
// caller creates a fresh token for the returned owner and retains the parent
// edge represented here.
@(private)
prov_escape_region :: proc(graph: ^Flow_Graph, value: Expr) -> Region_Set {
	if expr_base(value) != nil && type_is_region_provider(graph.k.c, expr_base(value).type) {
		#partial switch v in value {
		case ^Expr_Ident:
			if parent, found := graph.provider_parents[v.symbol]; found {
				return parent
			}
			return Region_Set{}
		case ^Expr_Move:
			return prov_escape_region(graph, v.value)
		}
	}
	return prov_result_region(graph, value)
}

@(private = "file")
prov_new_root :: proc(graph: ^Flow_Graph, kind: Root_Kind, span: Span, name: string) -> Root_Id {
	append(&graph.roots, Prov_Root{kind = kind, span = span, name = name, param_index = -1})
	return Root_Id(len(graph.roots) - 1)
}

// design.md "Storage roots and borrow carriers": every ordinary variable owns
// its inline storage and is a root for borrows of it. Static-duration storage is
// a root that outlives every body, and an `inout` parameter names the caller's.
@(private)
prov_root_for_symbol :: proc(graph: ^Flow_Graph, id: Symbol_Id) -> Root_Id {
	if id == INVALID_SYMBOL {
		return NO_ROOT
	}
	if existing, found := graph.root_by_symbol[id]; found {
		return existing
	}
	sym := symbol_of(graph.k.c, id)
	if sym == nil {
		return NO_ROOT
	}
	kind := Root_Kind.Local
	#partial switch sym.kind {
	case .Var:
		// `thread_local` storage lives as long as its thread, not as long as the
		// process, so it is a root kind of its own even though both survive a
		// return (design.md "Storage modifiers").
		switch {
		case sym.duration == .Thread_Local:
			kind = .Thread_Local
		case sym.duration != .None || (sym.decl != nil && sym.decl.top_level):
			kind = .Static
		}
	case .Parameter:
		// An `inout` parameter and an immutable receiver both alias the caller's
		// root, while the default parameter binding is a callee-local read-only
		// value (design.md "Receiver forms", "Temporaries and procedure
		// boundaries"). This is what lets `proc(self) -> []T` return a slice of
		// the receiver's own inline storage.
		if param_mode_is_pointer(sym.mode) {
			kind = .Param
		}
	case .Const:
		// design.md "Materialization": a constant reached by a runtime index,
		// slice, or `&` gets one read-only object for the whole program.
		kind = .Materialized
	case:
		return NO_ROOT
	}
	root := prov_new_root(graph, kind, sym.span, identifier_text(graph.k.c, sym.name))
	graph.roots[int(root)].symbol = id
	if kind == .Param {
		graph.roots[int(root)].param_index = int(sym.index)
	}
	graph.root_by_symbol[id] = root
	return root
}

// A carrier variable gets one slot; its reaching loans are what the forward
// lattice follows. A static-duration carrier deliberately gets none: design.md
// lists storing a view in a global as one of the cases that are not checked.
@(private = "file")
prov_slot_for_symbol :: proc(graph: ^Flow_Graph, id: Symbol_Id) -> (int, bool) {
	if id == INVALID_SYMBOL {
		return 0, false
	}
	if existing, found := graph.slot_by_symbol[id]; found {
		return existing, true
	}
	sym := symbol_of(graph.k.c, id)
	if sym == nil {
		return 0, false
	}
	if !type_is_carrier(graph.k.c, sym.type) {
		// It may still carry a borrow inside it; that is a content slot, not one
		// of these.
		return 0, false
	}
	if sym.kind != .Var && sym.kind != .Parameter {
		return 0, false
	}
	if sym.duration != .None || (sym.decl != nil && sym.decl.top_level) {
		return 0, false
	}
	entry := empty_prov_slot(id)
	entry.name = identifier_text(graph.k.c, sym.name)
	entry.span = sym.span
	append(&graph.prov_slots, entry)
	slot := len(graph.prov_slots) - 1
	graph.slot_by_symbol[id] = slot
	return slot, true
}

// Constructing an aggregate puts each element's borrows at its own place: a
// positional element at its field or array index, a named field element at
// the field it names, and a keyed element whose slot can't be resolved here
// joins into every path rather than guessing. An array with a single wildcard
// element path joins into it via the same overlap test.
@(private)
prov_composite_content :: proc(graph: ^Flow_Graph, v: ^Expr_Composite, content: []int) -> []int {
	value_type := v.type
	is_array := underlying_kind(graph.k.c, value_type) == .Array
	per_element := make([][]int, len(v.elements), graph.alloc)
	// The slot each written element fills, and whether it is known at all. A
	// named field element resolves to the field's own index — the checker already
	// proved the name — so `Point{y = view}` is as precise as `Point{v, view}`.
	steps := make([]Proj_Step, len(v.elements), graph.alloc)
	known := make([]bool, len(v.elements), graph.alloc)
	joined: []int
	for element, index in v.elements {
		if element.value == nil {
			continue
		}
		loans := walk_flow_expr(graph, element.value)
		per_element[index] = loans
		joined = prov_join(graph, joined, loans)
		steps[index], known[index] = prov_element_step(graph, v, value_type, is_array, index)
	}
	for slot in content {
		sources: []int
		for loans, index in per_element {
			if len(loans) == 0 {
				continue
			}
			if !known[index] {
				// An unresolved slot could be any of them, so it contributes to all.
				sources = prov_join(graph, sources, loans)
				continue
			}
			prefix := prov_extend(graph, nil, steps[index])
			if paths_overlap(graph.prov_slots[slot].path, prefix) {
				path := graph.prov_slots[slot].path
				suffix := path[min(len(prefix), len(path)):]
				child_type := expr_base(v.elements[index].value).type
				sources = prov_join(graph, sources, prov_select_content(graph, loans, child_type, suffix))
			}
		}
		prov_define_one_content(graph, slot, sources, v.span)
	}
	return content
}

// Which slot one written literal element fills. An element is selected by index,
// a field by its own step, and the two kinds must not be compared:
// `steps_overlap` treats a mismatch as "nothing proven", which would join
// everything.
@(private = "file")
prov_element_step :: proc(
	graph: ^Flow_Graph,
	v: ^Expr_Composite,
	value_type: Type_Id,
	is_array: bool,
	index: int,
) -> (Proj_Step, bool) {
	key := v.elements[index].key
	if key == nil {
		if is_array {
			return proj_range(i64(index), i64(index) + 1), true
		}
		return proj_field(index), true
	}
	if is_array {
		if constant, ok := prov_const_int(graph, key); ok {
			return proj_range(constant, constant + 1), true
		}
		return proj_wild(), false
	}
	name, is_ident := key.(^Expr_Ident)
	if !is_ident {
		return proj_wild(), false
	}
	field := struct_field(graph.k.c, value_type, intern_identifier(graph.k.c, name.name))
	sym := symbol_of(graph.k.c, field)
	if sym == nil {
		return proj_wild(), false
	}
	return proj_field(int(sym.index)), true
}

// design.md "Unions": one variant's payload sits under the union's wildcard
// alternative, so constructing a variant puts the payload's borrows there.
@(private)
prov_variant_content :: proc(graph: ^Flow_Graph, v: ^Expr_Call, loans: []int) -> []int {
	content := prov_temp_content(graph, v.type)
	if len(content) == 0 {
		return nil
	}
	prefix := prov_extend(graph, nil, proj_wild())
	payload_type := INVALID_TYPE
	if len(v.bound) == 1 && v.bound[0] != nil {
		payload_type = expr_base(v.bound[0]).type
	}
	for slot in content {
		sources: []int
		if len(loans) > 0 && paths_overlap(graph.prov_slots[slot].path, prefix) {
			path := graph.prov_slots[slot].path
			suffix := path[min(len(prefix), len(path)):]
			sources = prov_select_content(graph, loans, payload_type, suffix)
		}
		prov_define_one_content(graph, slot, sources, v.span)
	}
	return content
}

// A value that is not itself a borrow
// can still hold one. Every place `carrier_shape` names gets its own slot, so a
// read of one field does not inherit what a sibling borrows, and a wrapped
// borrow keeps the obligations the bare one has.
@(private = "file")
prov_content_slots :: proc(graph: ^Flow_Graph, id: Symbol_Id) -> []int {
	if id == INVALID_SYMBOL {
		return nil
	}
	if existing, found := graph.content_by_symbol[id]; found {
		return existing
	}
	sym := symbol_of(graph.k.c, id)
	if sym == nil || type_is_carrier(graph.k.c, sym.type) {
		return nil // a bare carrier already has its own slot
	}
	if sym.kind != .Var && sym.kind != .Parameter {
		return nil
	}
	shape := carrier_shape(graph.k.c, sym.type)
	if len(shape) == 0 {
		return nil // an all-scalar value initializes no payload facts
	}
	external_duration := sym.duration != .None || (sym.decl != nil && sym.decl.top_level)
	unknown_root := NO_ROOT
	if external_duration {
		// Another body may have populated this storage. Starting empty would turn
		// missing cross-body content metadata into a proof that it borrows nothing;
		// a definite write in this body replaces these entry facts normally.
		unknown_root = prov_new_root(
			graph, .Unknown, sym.span,
			fmt.aprintf(
				"existing content of `%s`", identifier_text(graph.k.c, sym.name), allocator = graph.alloc,
			),
		)
	}
	slots := make([]int, len(shape), graph.alloc)
	for path, index in shape {
		entry := empty_prov_slot(id)
		entry.name = identifier_text(graph.k.c, sym.name)
		entry.span = sym.span
		entry.path = path.steps
		entry.content_type = path.truncated ? INVALID_TYPE : path.type
		entry.content_shape = sym.type
		entry.content_truncated = path.truncated
		entry.precision = path.precision
		append(&graph.prov_slots, entry)
		slots[index] = len(graph.prov_slots) - 1
		if unknown_root != NO_ROOT {
			loan := prov_new_loan(
				graph, unknown_root, nil, path.mutable, sym.span,
				path.truncated ? "borrow" : carrier_noun(graph.k.c, path.type),
			)
			append(&graph.entry_defs, Prov_Entry_Def{slot = slots[index], loan = loan})
		}
	}
	graph.content_by_symbol[id] = slots
	return slots
}

// The content slots of one place: those whose shape path overlaps the
// projection the place names. `paths_overlap` already treats a prefix as
// covering everything below it, so a truncated path still answers for a deeper
// read, and two distinct fields still answer separately.
@(private = "file")
prov_content_at :: proc(graph: ^Flow_Graph, root: Root_Id, path: []Proj_Step) -> []int {
	if root == NO_ROOT {
		return nil
	}
	slots := prov_content_slots(graph, graph.roots[int(root)].symbol)
	if len(slots) == 0 {
		return nil
	}
	if len(path) == 0 {
		return slots
	}
	out := make([dynamic]int, 0, len(slots), graph.alloc)
	for slot in slots {
		if paths_overlap(graph.prov_slots[slot].path, path) {
			append(&out, slot)
		}
	}
	return out[:]
}

// Slots for the content of a value with no name of its own: a literal, a call
// result, a temporary. Ordered by the same shape, so they pair by index with a
// destination of the same type.
@(private)
prov_temp_content :: proc(graph: ^Flow_Graph, type: Type_Id) -> []int {
	shape := carrier_shape(graph.k.c, type)
	if len(shape) == 0 {
		return nil
	}
	slots := make([]int, len(shape), graph.alloc)
	for path, index in shape {
		entry := empty_prov_slot(INVALID_SYMBOL)
		entry.path = path.steps
		entry.content_type = path.truncated ? INVALID_TYPE : path.type
		entry.content_shape = type
		entry.content_truncated = path.truncated
		entry.precision = path.precision
		append(&graph.prov_slots, entry)
		slots[index] = len(graph.prov_slots) - 1
	}
	return slots
}

// A path can select from slots only when they describe this value's shape.
// Unstructured dependencies contribute to every path, regardless of count.
@(private = "file")
prov_select_content :: proc(graph: ^Flow_Graph, sources: []int, type: Type_Id, path: []Proj_Step) -> []int {
	selected: []int
	for source in sources {
		entry := graph.prov_slots[source]
		if type == INVALID_TYPE || entry.content_shape != type || paths_overlap(entry.path, path) {
			selected = prov_join(graph, selected, prov_one(graph, source))
		}
	}
	return selected
}

// A read produces slots relative to the value being read, not the enclosing
// root. This lets a later projection of that value select its own fields.
@(private)
prov_project_content :: proc(
	graph: ^Flow_Graph,
	sources: []int,
	source_type: Type_Id,
	path: []Proj_Step,
	result_type: Type_Id,
	span: Span,
) -> []int {
	if len(sources) == 0 {
		return nil
	}
	content := prov_temp_content(graph, result_type)
	for slot in content {
		full := prov_concat_path(graph, path, graph.prov_slots[slot].path)
		graph.prov_slots[slot].precision |= path_precision(full)
		selected := prov_select_content(graph, sources, source_type, full)
		prov_emit(graph, Prov_Event{kind = .Live, sources = selected, span = span})
		prov_define_one_content(graph, slot, selected, span)
	}
	return content
}

@(private)
prov_read_content :: proc(graph: ^Flow_Graph, root: Root_Id, path: []Proj_Step, type: Type_Id, span: Span) -> []int {
	sym := symbol_of(graph.k.c, graph.roots[int(root)].symbol)
	if sym == nil {
		return nil
	}
	return prov_project_content(graph, prov_content_at(graph, root, path), sym.type, path, type, span)
}

// Without a result-field mapping, give every result path the whole dependency
// set so projecting a call temporary cannot silently drop a source.
@(private)
prov_value_content :: proc(graph: ^Flow_Graph, sources: []int, type: Type_Id, span: Span) -> []int {
	return prov_project_content(graph, sources, INVALID_TYPE, nil, type, span)
}

@(private)
prov_load_content :: proc(graph: ^Flow_Graph, carriers: []int, path: []Proj_Step, type: Type_Id, span: Span) -> []int {
	if len(carriers) == 0 {
		return nil
	}
	content := prov_temp_content(graph, type)
	graph.has_content_load ||= len(content) > 0
	for slot in content {
		prov_emit(graph, Prov_Event {
			kind = .Load,
			slot = slot,
			into = carriers,
			path = prov_concat_path(graph, path, graph.prov_slots[slot].path),
			span = span,
		})
	}
	prov_emit(graph, Prov_Event{kind = .Live, sources = content, span = span})
	return content
}

// Consuming a value: what it held travels to wherever it went, so read that
// before invalidating the source. The borrows inside it are of other roots and
// survive; only the source binding's own storage ends, which is exactly what
// the invalidation covers (design.md). An explicit `move` around the place is
// transparent here — the same consumption, just written twice.
@(private)
prov_consume :: proc(graph: ^Flow_Graph, place: Expr, span: Span, verb: string) -> []int {
	source := place
	if moved, is_move := place.(^Expr_Move); is_move {
		source = moved.value
	}
	consumed: []int
	if root, path, ok := prov_place_of(graph, source); ok {
		consumed = prov_content_at(graph, root, path)
	}
	prov_invalidate(graph, source, span, verb)
	return consumed
}

// Publishes a value into whatever slots a binding has: its own slot when it is
// a bare carrier, its content slots when it holds borrows inside it. Used where
// a name is bound to a value the walk already has loans for but no declaration
// runs — a `foreach` element and a type switch's per-case binding.
@(private)
prov_bind_value :: proc(graph: ^Flow_Graph, id: Symbol_Id, sources: []int, span: Span) {
	if id == INVALID_SYMBOL {
		return
	}
	if slot, is_carrier := prov_slot_for_symbol(graph, id); is_carrier {
		sym := symbol_of(graph.k.c, id)
		if sym != nil {
			prov_weaken(graph, sources, sym.type, slot, span)
		}
		prov_emit(graph, Prov_Event{kind = .Def, slot = slot, loan = NO_LOAN, sources = sources, span = span})
		return
	}
	if content := prov_content_slots(graph, id); len(content) > 0 {
		prov_define_content(graph, content, sources, span)
	}
}

// Publishes one value's content into another's by matching paths of the same
// value type. Equal slot counts alone never establish a correspondence.
@(private = "file")
prov_define_content :: proc(
	graph: ^Flow_Graph,
	into: []int,
	from: []int,
	span: Span,
	written: []Proj_Step = nil,
	value_type: Type_Id = INVALID_TYPE,
	preserve_previous := false,
) {
	// A write whose own path is indistinct — an unknown index, a union subject —
	// reaches one of the places it selected without saying which, so it may not
	// erase the others.
	indistinct := path_is_indistinct(written)
	for slot in into {
		entry := graph.prov_slots[slot]
		type := value_type
		if type == INVALID_TYPE && len(written) == 0 {
			type = entry.content_shape
		}
		path := entry.path[min(len(written), len(entry.path)):]
		sources := prov_select_content(graph, from, type, path)
		// One content path can stand for many places — every element of a
		// container, every alternative of a union — and a write reaches only one
		// of them. Replacing the path would erase what the others hold, so an
		// indistinguishable destination joins instead. A fallible synthesized
		// write also keeps the old value from its failure edge. A known field in a
		// write that must commit replaces.
		partial_truncated_write := entry.content_truncated && len(written) > len(entry.path)
		whole_replacement := !indistinct && path_has_exact_prefix(entry.path, written)
		if preserve_previous || (!whole_replacement &&
		   (indistinct || path_is_indistinct(entry.path) || partial_truncated_write)) {
			sources = prov_join(graph, prov_one(graph, slot), sources)
		}
		prov_define_one_content(graph, slot, sources, span, path_precision(written))
	}
}

// Whether a path stands for more than one place, which is exactly when a
// wildcard step appears in it.
@(private = "file")
path_is_indistinct :: proc(path: []Proj_Step) -> bool {
	for step in path {
		if step.kind == .Wild {
			return true
		}
	}
	return false
}

// A whole-value or whole-field write replaces every represented place below
// its path, including a wildcard container slot. A known element write into a
// wildcard slot is not a prefix match and therefore remains a partial join.
@(private = "file")
path_has_exact_prefix :: proc(path, prefix: []Proj_Step) -> bool {
	if len(prefix) > len(path) {
		return false
	}
	for step, index in prefix {
		other := path[index]
		if step.kind != other.kind || step.lo != other.lo || step.hi != other.hi {
			return false
		}
	}
	return true
}

// One content path takes its own capability from the leaf that lives there: a
// mutable borrow published into a read-only field weakens exactly as it would
// at a read-only local.
@(private = "file")
prov_define_one_content :: proc(graph: ^Flow_Graph, slot: int, sources: []int, span: Span, precision: Precision_Loss = {}) {
	prov_weaken(graph, sources, graph.prov_slots[slot].content_type, slot, span)
	prov_emit(graph, Prov_Event{kind = .Def, slot = slot, loan = NO_LOAN, sources = sources, span = span, precision = precision})
}

@(private = "file")
prov_temp_slot :: proc(graph: ^Flow_Graph) -> int {
	append(&graph.prov_slots, empty_prov_slot(INVALID_SYMBOL))
	return len(graph.prov_slots) - 1
}

// A mutable carrier implicitly weakens to a read-only one (design.md). The
// conversion is written at the destination, so a borrow created by an
// expression takes its final capability from what receives it — both the loan
// and the access the borrow registered on its root.
// `into` is the slot receiving the weakened value, or -1 where the destination
// has no slot of its own — a call argument, whose reborrow cannot outlive the
// call and so can suspend nothing.
@(private = "file")
prov_weaken :: proc(graph: ^Flow_Graph, slots: []int, destination: Type_Id, into := -1, span := Span{}) {
	if !type_is_carrier(graph.k.c, destination) || carrier_is_mutable(graph.k.c, destination) {
		return
	}
	for slot in slots {
		entry := graph.prov_slots[slot]
		if entry.fresh_loan != NO_LOAN {
			graph.loans[int(entry.fresh_loan)].mutable = false
			if entry.fresh_access_index >= 0 {
				graph.blocks[entry.fresh_access_block].prov[entry.fresh_access_index].access = .Read
			}
			continue
		}
		// No fresh loan: this slot already held its loans, so the weakening is a
		// reborrow of a carrier rather than the settling of a new one.
		if into < 0 || !prov_slot_is_mutable_carrier(graph, slot) {
			continue
		}
		append(&graph.reborrows, Prov_Reborrow{source = slot, derived = into, span = span})
	}
}

// Whether a slot names a mutable carrier. Only a slot bound to a declared name
// has a type to ask; an expression temporary that reached here without a fresh
// loan is left alone rather than guessed at.
@(private = "file")
prov_slot_is_mutable_carrier :: proc(graph: ^Flow_Graph, slot: int) -> bool {
	sym := symbol_of(graph.k.c, graph.prov_slots[slot].symbol)
	return sym != nil && carrier_is_mutable(graph.k.c, sym.type)
}

@(private = "file")
prov_new_loan :: proc(
	graph: ^Flow_Graph,
	root: Root_Id,
	path: []Proj_Step,
	mutable: bool,
	span: Span,
	what: string,
) -> Loan_Id {
	append(&graph.loans, Prov_Loan{root = root, path = path, mutable = mutable, span = span, what = what})
	return Loan_Id(len(graph.loans) - 1)
}

// A fresh borrow, parked in an expression temporary so that its consumer -- a
// declaration, an assignment, a call, or nothing at all -- decides how long it
// stays live.
@(private)
prov_borrow :: proc(
	graph: ^Flow_Graph,
	root: Root_Id,
	path: []Proj_Step,
	mutable: bool,
	span: Span,
	what: string,
	access_block := NO_BLOCK,
	access_index := -1,
) -> []int {
	loan := prov_new_loan(graph, root, path, mutable, span, what)
	slot := prov_temp_slot(graph)
	graph.prov_slots[slot].fresh_loan = loan
	graph.prov_slots[slot].fresh_access_block = access_block
	graph.prov_slots[slot].fresh_access_index = access_index
	prov_emit(graph, Prov_Event{kind = .Def, slot = slot, loan = loan, span = span})
	return prov_one(graph, slot)
}

// Returns where the event landed, so a caller that may have to revise it — a
// fresh borrow whose capability the destination settles — can find it again.
// `index` is -1 when nothing was emitted.
@(private)
prov_access :: proc(
	graph: ^Flow_Graph,
	root: Root_Id,
	path: []Proj_Step,
	kind: Access_Kind,
	span: Span,
	verb := "",
) -> (block: Block_Id, index: int) {
	if root == NO_ROOT {
		return NO_BLOCK, -1
	}
	prov_emit(graph, Prov_Event {
		kind   = .Access,
		root   = root,
		path   = path,
		access = kind,
		span   = span,
		verb   = verb,
	})
	if graph.current == NO_BLOCK {
		return NO_BLOCK, -1
	}
	return graph.current, len(graph.blocks[graph.current].prov) - 1
}

@(private = "file")
prov_extend :: proc(graph: ^Flow_Graph, path: []Proj_Step, step: Proj_Step) -> []Proj_Step {
	out := make([]Proj_Step, len(path) + 1, graph.alloc)
	copy(out, path)
	out[len(path)] = step
	return out
}

@(private = "file")
prov_concat_path :: proc(graph: ^Flow_Graph, prefix, path: []Proj_Step) -> []Proj_Step {
	out := make([]Proj_Step, len(prefix) + len(path), graph.alloc)
	copy(out, prefix)
	copy(out[len(prefix):], path)
	return out
}

// design.md: a borrowed parameter's storage belongs to the caller, so the body
// starts with one loan of a root it cannot see but can name in a summary.
@(private)
prov_bind_parameters :: proc(graph: ^Flow_Graph, literal: ^Expr_Proc) {
	if literal.signature == nil {
		return
	}
	position := 0
	for parameter in literal.signature.params {
		position += len(parameter.symbols)
	}
	graph.param_count = position
	position = 0
	for parameter in literal.signature.params {
		for id in parameter.symbols {
			index := position
			position += 1
			sym := symbol_of(graph.k.c, id)
			if sym == nil {
				continue
			}
			// An allocator value's region identity is what lets the compiler
			// recognise two values as the same region, and what an
			// `@(allocator_reset)` promise is written about (design.md).
			if type_underlying(graph.k.c, sym.type) == TYPE_ALLOCATOR {
				set := prov_empty_region(graph)
				set.params[index] = true
				graph.region_of[id] = set
			}
			slot, is_carrier := prov_slot_for_symbol(graph, id)
			// An aggregate parameter arrives holding one borrow per place its
			// shape names, seeded independently of the parameter binding itself.
			content := prov_content_slots(graph, id)
			if !is_carrier && len(content) == 0 {
				continue
			}
			name := identifier_text(graph.k.c, sym.name)
			root := prov_new_root(graph, .Param, sym.span, name)
			graph.roots[int(root)].symbol = id
			graph.roots[int(root)].param_index = index
			if !is_carrier {
				shape := carrier_shape(graph.k.c, sym.type)
				for path, path_index in shape {
					loan := prov_new_loan(
						graph,
						root,
						path.steps,
						path.mutable,
						sym.span,
						path.truncated ? "borrow" : carrier_noun(graph.k.c, path.type),
					)
					append(&graph.entry_defs, Prov_Entry_Def{slot = content[path_index], loan = loan})
				}
				continue
			}
			loan := prov_new_loan(
				graph,
				root,
				nil,
				carrier_is_mutable(graph.k.c, sym.type),
				sym.span,
				carrier_noun(graph.k.c, sym.type),
			)
			append(&graph.entry_defs, Prov_Entry_Def{slot = slot, loan = loan})
		}
	}
}



// Conversion to a built-in view and compiler-known iteration preserve the
// source root (design.md). An `any_view` reads its subject and never writes
// it, so the loan is a read-only one and other reads stay legal.
@(private)
prov_erase :: proc(graph: ^Flow_Graph, e: Expr) -> []int {
	span := expr_span(e)
	// Erasing a carrier borrows both its representation and the storage it
	// already refers to. Otherwise erasure (including a formatting argument)
	// hides a use of a previously invalidated view.
	loans := walk_flow_expr_erased(graph, e)
	if root, path, ok := prov_place_of(graph, e); ok {
		return prov_join(graph, loans, prov_borrow(graph, root, path, false, span, "view"))
	}
	// A carrier erased into a view keeps the loans it already held; anything else
	// is a temporary whose hidden storage ends with its statement.
	if len(loans) > 0 {
		return loans
	}
	// The storage the compiler creates to erase a value is a frame slot, not a
	// value temporary: like the hidden array behind a slice literal, it follows
	// the surrounding lexical scope.
	return prov_borrow(graph, prov_hidden_root(graph, span, "this erased value"), nil, false, span, "view")
}

// A root the compiler created rather than the reader, ending with the scope it
// was created in.
@(private = "file")
prov_hidden_root :: proc(graph: ^Flow_Graph, span: Span, name: string) -> Root_Id {
	root := prov_new_root(graph, .Temporary, span, name)
	append(&graph.in_scope, Flow_Cleanup{kind = .Prov_Root, root = root, span = span})
	return root
}

// The same walk with the erasure hook suppressed, so `prov_erase` can fall back
// to the node's ordinary meaning without recursing into itself.
@(private = "file")
walk_flow_expr_erased :: proc(graph: ^Flow_Graph, e: Expr) -> []int {
	base := expr_base(e)
	saved, saved_type := base.erased_from, base.type
	base.erased_from, base.type = INVALID_TYPE, saved
	defer { base.erased_from, base.type = saved, saved_type }
	return walk_flow_expr(graph, e)
}

// ------------------------------------------------------------- regions --

@(private = "file")
prov_empty_region :: proc(graph: ^Flow_Graph) -> Region_Set {
	return Region_Set{params = make([]bool, max(graph.param_count, 1), graph.alloc)}
}

// Every region dependency of one symbol, including managed values moved into
// aggregate fields after the symbol's declaration.
@(private)
prov_region_for_symbol :: proc(graph: ^Flow_Graph, id: Symbol_Id) -> Region_Set {
	out := prov_empty_region(graph)
	if direct, found := graph.region_of[id]; found {
		region_merge(&out, direct)
	}
	for content in graph.region_content[id] {
		region_merge(&out, content.region)
	}
	return out
}

// The region dependencies stored at one aggregate path. A whole-value fact has
// an empty path and therefore contributes to every projection conservatively.
@(private = "file")
prov_region_content_at :: proc(graph: ^Flow_Graph, root: Root_Id, path: []Proj_Step) -> Region_Set {
	out := prov_empty_region(graph)
	if root == NO_ROOT {
		return out
	}
	id := graph.roots[int(root)].symbol
	if direct, found := graph.region_of[id]; found {
		region_merge(&out, direct)
	}
	for content in graph.region_content[id] {
		if len(path) == 0 || len(content.path) == 0 || paths_overlap(content.path, path) {
			region_merge(&out, content.region)
		}
	}
	return out
}

// Record a managed value stored into a field or element. The region analysis is
// deliberately flow-insensitive, so repeated writes merge rather than erase a
// possibility; the path split still prevents an unrelated sibling read from
// inheriting the dependency.
@(private = "file")
prov_define_region_content :: proc(
	graph: ^Flow_Graph,
	root: Root_Id,
	path: []Proj_Step,
	region: Region_Set,
) {
	if root == NO_ROOT || region_is_empty(region) {
		return
	}
	id := graph.roots[int(root)].symbol
	if id == INVALID_SYMBOL {
		return
	}
	content := graph.region_content[id]
	for &entry in content {
		if len(entry.path) == len(path) && path_has_exact_prefix(entry.path, path) {
			region_merge(&entry.region, region)
			graph.region_content[id] = content
			return
		}
	}
	stored_path := make([]Proj_Step, len(path), graph.alloc)
	copy(stored_path, path)
	grown := make([dynamic]Prov_Region_Content, len(content), len(content) + 1, graph.alloc)
	copy(grown[:], content)
	append(&grown, Prov_Region_Content{path = stored_path, region = region})
	graph.region_content[id] = grown[:]
}

// The token for one local provider, made on first ask. Past 64 providers in one
// body the set degrades to `crowded`, which means "may be any of them" and only
// ever makes the answer more conservative.
@(private = "file")
prov_provider_region :: proc(graph: ^Flow_Graph, id: Symbol_Id) -> Region_Set {
	out := prov_empty_region(graph)
	if existing, found := graph.provider_bits[id]; found {
		out.locals = existing
		return out
	}
	index := len(graph.provider_symbols)
	if index >= 64 {
		out.crowded = true
		return out
	}
	append(&graph.provider_symbols, id)
	bit := u64(1) << u64(index)
	graph.provider_bits[id] = bit
	out.locals = bit
	return out
}

// The name a diagnostic gives one local region, or "" when the set names more
// than one -- in which case the sentence has to talk about the owner instead.
prov_region_name :: proc(graph: ^Flow_Graph, set: Region_Set) -> string {
	if set.crowded {
		return ""
	}
	found := ""
	for id, index in graph.provider_symbols {
		if set.locals & (u64(1) << u64(index)) == 0 {
			continue
		}
		if found != "" {
			return ""
		}
		if sym := symbol_of(graph.k.c, id); sym != nil {
			found = identifier_text(graph.k.c, sym.name)
		}
	}
	return found
}

// design.md "Allocators": a handle carries its region through every copy of it.
// An `Option` or `Result` around one is still that handle in transit, so the
// wrapper carries whatever its payload carries.
@(private = "file")
prov_carries_allocator :: proc(c: ^Compiler, type: Type_Id, depth := 0) -> bool {
	if type == INVALID_TYPE || depth > 8 {
		return false
	}
	if type_underlying(c, type) == TYPE_ALLOCATOR {
		return true
	}
	info := underlying_info(c, type)
	if info == nil || info.kind != .Union {
		return false
	}
	for payload in info.variants {
		if payload != TYPE_VOID && prov_carries_allocator(c, payload, depth + 1) {
			return true
		}
	}
	return false
}

// The allocator region an expression denotes, or an empty set when it denotes
// nothing region-shaped.
@(private = "file")
prov_region_of :: proc(graph: ^Flow_Graph, e: Expr) -> Region_Set {
	c := graph.k.c
	#partial switch v in e {
	case ^Expr_Ident:
		return prov_region_for_symbol(graph, v.symbol)
	case ^Expr_Move:
		// Moving an owner transfers, rather than erases, the region that backs it.
		return prov_region_of(graph, v.value)
	case ^Expr_Cond:
		out := prov_empty_region(graph)
		region_merge(&out, prov_region_of(graph, v.then))
		region_merge(&out, prov_region_of(graph, v.otherwise))
		return out
	case ^Expr_Or_Else:
		out := prov_empty_region(graph)
		region_merge(&out, prov_region_of(graph, v.value))
		region_merge(&out, prov_region_of(graph, v.fallback))
		return out
	case ^Expr_Selector, ^Expr_Index:
		if root, path, ok := prov_place_of(graph, e); ok {
			return prov_region_content_at(graph, root, path)
		}
	case ^Expr_Postfix:
		// Propagating a status does not change which region backs the value that
		// travels through it.
		if v.op == .Or_Return {
			return prov_region_of(graph, v.operand)
		}
	case ^Expr_Composite:
		// An owning aggregate keeps every region dependency of its owning fields.
		out := prov_empty_region(graph)
		for element in v.elements {
			if element.value != nil {
				region_merge(&out, prov_region_of(graph, element.value))
			}
		}
		return out
	case ^Expr_Call:
		if sym := symbol_of(c, v.resolution.symbol); sym != nil && sym.builtin == .Default_Allocator {
			set := prov_empty_region(graph)
			set.default = true
			return set
		}
		// `arena.allocator()`: the handle names the provider's own region, and
		// copying an allocator value preserves that identity (design.md), so it
		// carries through every copy of the handle for free.
		if set, ok := prov_handle_region(graph, v); ok {
			return set
		}
		if result, found := graph.call_results[v]; found {
			return result.region
		}
		return prov_call_region(graph, v, v.type)
	}
	if prov_carries_allocator(c, expr_base(e) == nil ? INVALID_TYPE : expr_base(e).type) {
		set := prov_empty_region(graph)
		set.unknown = true
		return set
	}
	return Region_Set{}
}

// The region an `arena.allocator()` names. The receiver has to be a lexical
// provider: a handle taken from a temporary provider would name a region that
// ended at the end of the statement, and there is nothing sensible to say about
// it beyond the conservative "unknown".
@(private = "file")
prov_handle_region :: proc(graph: ^Flow_Graph, v: ^Expr_Call) -> (Region_Set, bool) {
	if call_provider_op(graph.k.c, v) != .Handle || len(v.bound) == 0 {
		return Region_Set{}, false
	}
	ident, is_ident := v.bound[0].(^Expr_Ident)
	if !is_ident {
		set := prov_empty_region(graph)
		set.unknown = true
		return set, true
	}
	if set, found := graph.region_of[ident.symbol]; found {
		return set, true
	}
	set := prov_empty_region(graph)
	set.unknown = true
	return set, true
}

// The region component of one call result. Direct summaries are substituted by
// position. A plain procedure type has no result contract, so an owning result
// conservatively retains every moved-owner and allocator argument region.
@(private = "file")
prov_call_region :: proc(graph: ^Flow_Graph, v: ^Expr_Call, result_type: Type_Id) -> Region_Set {
	c := graph.k.c
	out := prov_empty_region(graph)
	allocator_result := prov_carries_allocator(c, result_type)
	if !type_is_managed(c, result_type) && !allocator_result {
		return out
	}
	// A union constructor wraps its payload; it is not an opaque procedure
	// returning an owner of an unknown region.
	if _, construction := v.operation.(Call_Union_Construct); construction {
		for argument in v.bound {
			if argument != nil {
				region_merge(&out, prov_region_of(graph, argument))
			}
		}
		return out
	}
	// These validating conversions copy into the default allocator and expose
	// no allocator argument (design.md "string type conversions").
	if operation, conversion := v.operation.(Call_Text_Conversion); conversion &&
	   (operation.op == .String_From_Bytes || operation.op == .String_From_C_View) {
		out.default = true
		return out
	}
	if _, extraction := v.operation.(Call_Extract); extraction && type_is_managed(c, result_type) {
		out.default = true
		return out
	}
	if sym := symbol_of(c, v.resolution.symbol); sym != nil && sym.builtin == .Default_Allocator {
		out.default = true
		return out
	}
	// `arena.allocator()`. Recorded here as well as in `prov_region_of`, because
	// a call's stored result summary is consulted before the expression walk.
	if set, ok := prov_handle_region(graph, v); ok {
		return set
	}
	// A fixed arena borrows its buffer but has no allocator-region parent. The
	// ordinary loan analysis carries that buffer lifetime; inventing an unknown
	// allocator dependency here would make unrelated resets spuriously overlap.
	if call_provider_op(c, v) == .Open_Fixed {
		return out
	}
	callee := call_contract_declaration(c, v)
	direct := prov_has_direct_body(c, callee)
	prov_note_summary_dependency(graph, callee, direct)
	if summary, found := result_summary(c, callee); found {
		for wanted, index in summary.region.params {
			if wanted && index < len(v.bound) && v.bound[index] != nil {
				region_merge(&out, prov_region_of(graph, v.bound[index]))
			}
		}
		out.default ||= summary.region.default
		out.unknown ||= summary.region.unknown
	}
	proc_type := INVALID_TYPE
	if sym := symbol_of(c, v.resolution.chosen_overload); sym != nil {
		proc_type = sym.proc_type
	} else if v.callee != nil {
		proc_type = expr_base(v.callee).type
	}
	info := underlying_info(c, proc_type)
	for argument, index in v.bound {
		if argument == nil {
			continue
		}
		if type_underlying(c, expr_base(argument).type) == TYPE_ALLOCATOR && (!allocator_result || !direct) {
			// An owning result constructed with an allocator argument derives that
			// allocator's region at the call site. A returned allocator handle has
			// no new owner: its known summary already identifies its region.
			region_merge(&out, prov_region_of(graph, argument))
			continue
		}
		if !direct && info != nil && index < len(info.param_modes) && info.param_modes[index] == .Move {
			region_merge(&out, prov_region_of(graph, argument))
		}
	}
	if !direct && region_is_empty(out) {
		out.unknown = true
	}
	return out
}

@(private = "file")
prov_substitute_region :: proc(graph: ^Flow_Graph, v: ^Expr_Call, summary: Region_Set) -> Region_Set {
	out := prov_empty_region(graph)
	for wanted, index in summary.params {
		if wanted && index < len(v.bound) && v.bound[index] != nil {
			region_merge(&out, prov_region_of(graph, v.bound[index]))
		}
	}
	out.default = summary.default
	out.unknown = summary.unknown
	// Summary-local identities cannot escape their body. The ordinary escape
	// diagnostic reports them there, so they are deliberately not substituted.
	return out
}

// Re-resolve allocation regions after the complete body has populated the
// flow-insensitive allocator map. The first result remains useful to statements
// later in the initial walk; merging the settled result makes allocation sites
// inside loops conservative across back edges as well.
@(private)
prov_finalize_allocation_regions :: proc(graph: ^Flow_Graph) {
	for source in graph.allocation_region_sources {
		if source.root == NO_ROOT || int(source.root) >= len(graph.roots) {
			continue
		}
		set := Region_Set{}
		if source.value != nil {
			set = prov_region_of(graph, source.value)
		} else if source.call != nil {
			set = prov_substitute_region(graph, source.call, source.summary)
		}
		region_merge(&graph.roots[int(source.root)].region, set)
	}
}

// Substitute each independently summarized result field at the call site.
// Missing content means the callee had no path mapping, and callers continue to
// use the conservative whole-result region in that case.
@(private = "file")
prov_call_region_content :: proc(graph: ^Flow_Graph, v: ^Expr_Call) -> []Prov_Region_Content {
	callee := call_contract_declaration(graph.k.c, v)
	summary, found := result_summary(graph.k.c, callee)
	if !found || len(summary.region_content) == 0 {
		return nil
	}
	out := make([]Prov_Region_Content, len(summary.region_content), graph.alloc)
	for content, index in summary.region_content {
		path := make([]Proj_Step, len(content.path), graph.alloc)
		copy(path, content.path)
		out[index] = Prov_Region_Content {
			path = path,
			region = prov_substitute_region(graph, v, content.region),
		}
	}
	return out
}

// Which of this body's own allocator parameters an expression may name, and
// whether every one of them already carries the reset promise.
@(private = "file")
prov_reset_promise :: proc(graph: ^Flow_Graph, set: Region_Set) -> (covered: bool, name: string) {
	covered, name = false, ""
	for wanted, index in set.params {
		if !wanted {
			continue
		}
		sym := prov_parameter_symbol(graph, index)
		if sym == nil {
			continue
		}
		if !sym.allocator_reset {
			return false, identifier_text(graph.k.c, sym.name)
		}
		covered = true
	}
	return covered, ""
}

@(private = "file")
prov_parameter_symbol :: proc(graph: ^Flow_Graph, index: int) -> ^Symbol {
	literal := graph.literal
	if literal == nil || literal.signature == nil {
		return nil
	}
	position := 0
	for parameter in literal.signature.params {
		for id in parameter.symbols {
			if position == index {
				return symbol_of(graph.k.c, id)
			}
			position += 1
		}
	}
	return nil
}

// A reset may end every allocation root in that allocator region (design.md),
// so it is checked both for the promise it needs and for what would survive it.
@(private)
prov_reset :: proc(graph: ^Flow_Graph, set: Region_Set, span: Span, direct: bool, at: ^Expr_Call, cleanup_dead: []Symbol_Id = nil) {
	covered, unmarked := prov_reset_promise(graph, set)
	if !direct && unmarked == "" && region_is_empty(set) {
		// Default and unknown regions are pre-existing and must not be hidden
		// merely because they are not this body's parameters.
		covered = true
	}
	// A procedure may reset a region it created locally, because no caller-owned
	// value can belong to it (design.md). No promise is needed, and none could
	// be written -- the region does not exist outside this body.
	if region_is_local_only(set) {
		covered, unmarked = true, ""
	}
	event := Prov_Event {
		kind          = .Reset,
		span          = span,
		access        = direct ? .Invalidate : .Write,
		name          = unmarked,
		region        = set,
		reset_covered = unmarked == "" && covered,
	}
	// A tracked owner whose backing region this may end is a blocker whatever its
	// carriers do, because its cleanup still has to run — but only an owner of a
	// region this reset can actually reach: a second arena's containers are none
	// of its business, the whole point of giving each local provider a token.
	//
	// An owner is live when it may be used later or still needs cleanup on some
	// outgoing path; an explicitly dropped owner is dead and no longer blocks a
	// reset (design.md). Scope presence can't answer that, so the answer is
	// lifecycle's, recorded at this call or cleanup expansion one pass earlier.
	dead := graph.k.c.reset_dead[at]
	if at == nil {
		dead = cleanup_dead
	}
	for id in graph.owners_in_scope {
		owner := symbol_of(graph.k.c, id)
		if owner == nil {
			continue
		}
		if slice.contains(dead, id) {
			continue
		}
		if type_is_region_provider(graph.k.c, owner.type) {
			// The provider being reset is not its own dependant, but a live child
			// provider is: releasing the parent would invalidate the child's blocks
			// and later cleanup.
			parent, found := graph.provider_parents[id]
			if found && regions_may_overlap(parent, set) {
				event.verb = identifier_text(graph.k.c, owner.name)
				event.owner_span = owner.span
				break
			}
			continue
		}
		owner_region := prov_region_for_symbol(graph, id)
		if region_is_empty(owner_region) {
			continue
		}
		if !regions_may_overlap(owner_region, set) {
			continue
		}
		event.verb = identifier_text(graph.k.c, owner.name)
		event.owner_span = owner.span
		break
	}
	prov_emit(graph, event)
}

// A borrow stored where it outlives the statement that stored it. The
// destination is resolved as a place, so a field, a nested container element,
// and a write through a tracked alias are all seen, not only a bare
// identifier. Only a destination that actually receives a borrow is reported,
// so ordinary global data costs nothing.
@(private = "file")
prov_retain_escape :: proc(graph: ^Flow_Graph, target: Expr, sources: []int, span: Span) {
	if len(sources) == 0 {
		return
	}
	root, _, ok := prov_place_of(graph, target)
	if !ok {
		// The place left lexical storage through a carrier, so which root it
		// names is a solved question rather than a syntactic one.
		if through := prov_retain_through_carrier(graph, target); len(through) > 0 {
			prov_emit(graph, Prov_Event {
				kind    = .Retain,
				span    = span,
				sources = sources,
				root    = NO_ROOT,
				into    = through,
			})
		}
		return
	}
	descriptor := graph.roots[int(root)]
	into := retain_kind_for_root(descriptor.kind)
	if into == .None {
		return
	}
	prov_emit(graph, Prov_Event {
		kind    = .Retain,
		span    = span,
		sources = sources,
		root    = root,
		retain  = into,
		verb    = descriptor.name,
	})
}

// The carrier a destination place was written through, as the slots holding it.
// `p^.view` and `d[0].view` are writes into whatever `p` and `d` point at, which
// is what the carrier's loans say; a chain that never leaves lexical storage has
// no carrier and is answered by `prov_place_of` instead.
@(private = "file")
prov_retain_through_carrier :: proc(graph: ^Flow_Graph, place: Expr) -> []int {
	c := graph.k.c
	#partial switch v in place {
	case ^Expr_Postfix:
		if v.op == .Caret {
			return prov_carrier_slots(graph, v.operand)
		}
	case ^Expr_Selector:
		if v.resolution.kind != .Field || v.operand == nil {
			return nil
		}
		if type_is_pointer(c, expr_base(v.operand).type) {
			return prov_carrier_slots(graph, v.operand) // an auto-deref
		}
		return prov_retain_through_carrier(graph, v.operand)
	case ^Expr_Index:
		if len(v.bound) > 0 || v.operand == nil {
			return nil // user-defined addressing
		}
		#partial switch underlying_kind(c, expr_base(v.operand).type) {
		case .Array, .Dynamic_Array, .Map:
			// An owner's element is a place in the owner, so the chain has not
			// left lexical storage yet.
			return prov_retain_through_carrier(graph, v.operand)
		}
		return prov_carrier_slots(graph, v.operand)
	}
	return nil
}

// The slots holding a carrier value, without reading it: a bare carrier has its
// own slot, and one inside a value has the content slot for its path.
@(private = "file")
prov_carrier_slots :: proc(graph: ^Flow_Graph, e: Expr) -> []int {
	if ident, is_ident := e.(^Expr_Ident); is_ident {
		if slot, is_carrier := prov_slot_for_symbol(graph, ident.symbol); is_carrier {
			return prov_one(graph, slot)
		}
	}
	if root, path, ok := prov_place_of(graph, e); ok {
		return prov_content_at(graph, root, path)
	}
	return prov_retain_through_carrier(graph, e)
}

// An owner backed by a region the procedure received may not be returned,
// assigned to `static`, `thread_local`, or file-scope storage (design.md).
@(private = "file")
prov_region_escape :: proc(graph: ^Flow_Graph, target: Expr, value: Expr) {
	// The destination is a *place*, not only a bare name: wrapping an owner in a
	// global's field must not lose the region obligation the bare form has,
	// which is the same rule aggregate provenance applies to borrows.
	if !type_is_managed(graph.k.c, expr_base(target).type) {
		return
	}
	root, _, ok := prov_place_of(graph, target)
	if !ok {
		return
	}
	sym := symbol_of(graph.k.c, graph.roots[int(root)].symbol)
	if sym == nil {
		return
	}
	storage := ""
	switch {
	case sym.duration == .Thread_Local: storage = "`thread_local` storage"
	case sym.duration == .Static:       storage = "`static` storage"
	case sym.decl != nil && sym.decl.top_level: storage = "file-scope storage"
	}
	if storage == "" {
		return
	}
	// An allocating clone receives the destination allocator's region provenance
	// (design.md). Assigning a place *copies* it, so the destination is built
	// with its own allocator and inherits nothing; only a `move`, a call result,
	// or a constructed aggregate carries a region into the destination.
	if type_is_managed(graph.k.c, expr_base(value).type) && expression_is_borrowed_place(graph.k.c, value) {
		return
	}
	set := prov_result_region(graph, value)
	if !region_is_parameter_backed(set) && !region_has_local(set) {
		return
	}
	prov_emit(graph, Prov_Event {
		kind   = .Region_Escape,
		span   = expr_span(target),
		verb   = identifier_text(graph.k.c, sym.name),
		name   = storage,
		region = set,
	})
}

// ------------------------------------------------------------- places --

@(private)
prov_field_step :: proc(graph: ^Flow_Graph, v: ^Expr_Selector) -> Proj_Step {
	if !type_is_union(graph.k.c, expr_base(v.operand).type) {
		if field := symbol_of(graph.k.c, v.resolution.symbol); field != nil {
			return proj_field(int(field.index))
		}
	}
	return proj_wild()
}

@(private)
prov_index_path :: proc(graph: ^Flow_Graph, v: ^Expr_Index) -> []Proj_Step {
	type := expr_base(v.operand).type
	#partial switch underlying_kind(graph.k.c, type) {
	case .Array:
		return prov_extend(graph, nil, prov_index_step(graph, v.indices))
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

// Find the carrier at which a place leaves lexical storage, evaluating it and
// each subscript once. Keep the rest of the projection together: `p^.left`
// reads left's content without making the contents of right live as well.
@(private)
prov_read_through_carrier :: proc(graph: ^Flow_Graph, place: Expr) -> ([]int, []Proj_Step, bool) {
	#partial switch v in place {
	case ^Expr_Postfix:
		if v.op == .Caret {
			return walk_flow_expr(graph, v.operand), nil, true
		}
	case ^Expr_Selector:
		if v.resolution.kind != .Field || v.operand == nil {
			return nil, nil, false
		}
		step := prov_field_step(graph, v)
		if type_is_pointer(graph.k.c, expr_base(v.operand).type) {
			return walk_flow_expr(graph, v.operand), prov_extend(graph, nil, step), true
		}
		if carriers, path, ok := prov_read_through_carrier(graph, v.operand); ok {
			return carriers, prov_extend(graph, path, step), true
		}
	case ^Expr_Index:
		if len(v.bound) > 0 || v.operand == nil {
			return nil, nil, false
		}
		kind := underlying_kind(graph.k.c, expr_base(v.operand).type)
		if kind == .Slice || kind == .Pointer || kind == .C_Pointer {
			carriers := walk_flow_expr(graph, v.operand)
			for index in v.indices {
				walk_flow_expr(graph, index)
			}
			// The carrier's loan already names its element range. Keeping that
			// range is conservative even after reslicing or an unknown index.
			return carriers, nil, true
		}
		if carriers, path, ok := prov_read_through_carrier(graph, v.operand); ok {
			for index in v.indices {
				walk_flow_expr(graph, index)
			}
			return carriers, prov_concat_path(graph, path, prov_index_path(graph, v)), true
		}
	}
	return nil, nil, false
}

// The root and normalized projection path a place expression names, or no root
// when the chain leaves lexical storage through a carrier. Reaching a pointee or
// a slice element is a *use of the carrier*, not a competing access to the root,
// which is what lets access through a live borrow stay legal.
@(private)
prov_place_of :: proc(graph: ^Flow_Graph, e: Expr) -> (Root_Id, []Proj_Step, bool) {
	c := graph.k.c
	#partial switch v in e {
	case ^Expr_Ident:
		root := prov_root_for_symbol(graph, v.symbol)
		return root, nil, root != NO_ROOT

	case ^Expr_Selector:
		// A bare `.Member` has no operand at all, and a non-field selection names
		// a package, an enum member, or a method rather than storage.
		if v.resolution.kind != .Field || v.operand == nil {
			return NO_ROOT, nil, false
		}
		operand_type := expr_base(v.operand).type
		if type_is_pointer(c, operand_type) {
			return NO_ROOT, nil, false // an auto-deref reaches another root
		}
		root, path, ok := prov_place_of(graph, v.operand)
		if !ok {
			return NO_ROOT, nil, false
		}
		return root, prov_extend(graph, path, prov_field_step(graph, v)), true

	case ^Expr_Index:
		if len(v.bound) > 0 || v.operand == nil {
			return NO_ROOT, nil, false // user-defined addressing
		}
		// A container element is a place in its owner's *current allocation*, so
		// the container is the root and every relocating operation on it ends the
		// pointer. Which slot is unknowable once the storage can move, so the
		// projection is the whole container.
		#partial switch underlying_kind(c, expr_base(v.operand).type) {
		case .Array, .Dynamic_Array, .Map:
			root, path, ok := prov_place_of(graph, v.operand)
			if !ok {
				return NO_ROOT, nil, false
			}
			return root, prov_concat_path(graph, path, prov_index_path(graph, v)), true
		}
		return NO_ROOT, nil, false
	}
	return NO_ROOT, nil, false
}

// Index expressions inside a place chain are ordinary values and still have to
// be walked; the place itself contributes one access, not one per link.
@(private)
prov_walk_subscripts :: proc(graph: ^Flow_Graph, e: Expr, publish_map_keys := false) {
	#partial switch v in e {
	case ^Expr_Selector:
		prov_walk_subscripts(graph, v.operand, publish_map_keys)
	case ^Expr_Index:
		prov_walk_subscripts(graph, v.operand, publish_map_keys)
		key_sources: []int
		for index, position in v.indices {
			loans := walk_flow_expr(graph, index)
			if position == 0 {
				key_sources = loans
			}
		}
		if !publish_map_keys || len(v.bound) > 0 || len(v.indices) != 1 || len(key_sources) == 0 ||
		   underlying_kind(graph.k.c, expr_base(v.operand).type) != .Map {
			return
		}
		info := underlying_info(graph.k.c, expr_base(v.operand).type)
		if info == nil {
			return
		}
		// An assignment through a map place inserts the key when absent. When an
		// equal key already exists its original representation remains, so even a
		// known key joins rather than replacing the previous key dependency.
		prov_retain_escape(graph, v.operand, key_sources, v.span)
		root, path, ok := prov_place_of(graph, v.operand)
		if !ok {
			// The map itself was reached through a carrier. Its precise entry path
			// is solver-owned, so publish conservatively to every content slot of
			// each root that carrier may name.
			if through := prov_retain_through_carrier(graph, v.operand); len(through) > 0 {
				prov_weaken(graph, key_sources, info.key)
				prov_emit(graph, Prov_Event {
					kind = .Publish, span = v.span, sources = key_sources, into = through,
				})
			}
			return
		}
		entry := prov_extend(graph, path, prov_map_entry_step(graph, expr_base(v.operand).type, v.indices[0]))
		written := prov_extend(graph, entry, proj_field(PROJ_MAP_KEY))
		if content := prov_content_at(graph, root, written); len(content) > 0 {
			prov_define_content(graph, content, key_sources, v.span, written, info.key, true)
		}
	}
}

@(private = "file")
prov_const_int :: proc(graph: ^Flow_Graph, e: Expr) -> (i64, bool) {
	base := expr_base(e)
	if base == nil || !base.is_const || base.const_value.kind != .Integer {
		return 0, false
	}
	return bi_to_i64(graph.k.c, base.const_value.integer)
}

// The entry step a map access uses: the key's own entry when the key is a
// constant this body has room for, and the wildcard otherwise. The wildcard
// overlaps every keyed entry, so an unknown key still reads all of them and
// still joins when it writes.
@(private = "file")
prov_map_entry_step :: proc(graph: ^Flow_Graph, map_type: Type_Id, key: Expr) -> Proj_Step {
	if key == nil || !map_shape_is_keyed(graph.k.c, map_type) {
		return proj_wild()
	}
	base := expr_base(key)
	if base == nil || !base.is_const {
		return proj_wild()
	}
	name: string
	#partial switch base.const_value.kind {
	case .String:
		name = fmt.aprintf("s:%s", base.const_value.text, allocator = graph.alloc)
	case .Integer:
		value, ok := bi_to_i64(graph.k.c, base.const_value.integer)
		if !ok {
			return proj_wild()
		}
		name = fmt.aprintf("i:%d", value, allocator = graph.alloc)
	case .Rune:
		value, ok := bi_to_i64(graph.k.c, base.const_value.integer)
		if !ok {
			return proj_wild()
		}
		name = fmt.aprintf("r:%d", value, allocator = graph.alloc)
	case .Boolean:
		name = fmt.aprintf("b:%v", base.const_value.boolean, allocator = graph.alloc)
	case:
		return proj_wild()
	}
	if entry, found := graph.map_key_entries[name]; found {
		return proj_range(i64(entry), i64(entry) + 1)
	}
	entry := len(graph.map_key_entries)
	if entry >= MAP_KEY_SLOTS {
		step := proj_wild()
		step.precision = {.Map_Keys}
		return step
	}
	graph.map_key_entries[name] = entry
	return proj_range(i64(entry), i64(entry) + 1)
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

@(private = "file")
prov_range_step :: proc(graph: ^Flow_Graph, v: ^Expr_Slice) -> Proj_Step {
	low, low_ok := i64(0), true
	if v.lo != nil {
		low, low_ok = prov_const_int(graph, v.lo)
	}
	high, high_ok := i64(0), false
	if v.hi != nil {
		high, high_ok = prov_const_int(graph, v.hi)
	} else if info := v.operand == nil ? nil : underlying_info(graph.k.c, expr_base(v.operand).type);
	   info != nil && info.kind == .Array {
		high, high_ok = i64(info.count), true
	}
	if !low_ok || !high_ok || high <= low {
		return proj_wild()
	}
	return proj_range(low, high)
}

// ------------------------------------------------------- statement hooks --

@(private)
prov_read_ident :: proc(graph: ^Flow_Graph, v: ^Expr_Ident, kind: Access_Kind) -> []int {
	if root := prov_root_for_symbol(graph, v.symbol); root != NO_ROOT {
		prov_access(graph, root, nil, kind, v.span)
	}
	if slot, is_carrier := prov_slot_for_symbol(graph, v.symbol); is_carrier {
		sources := prov_one(graph, slot)
		prov_emit(graph, Prov_Event{kind = .Live, sources = sources, span = v.span})
		return sources
	}
	// Reading a carrier that lives in static or thread storage yields a borrow of
	// that storage, which is what lets a later store ask whether it outlives its
	// destination — a `thread_local` view does not outlive the process.
	if sym := symbol_of(graph.k.c, v.symbol); sym != nil && sym.duration != .None {
		if type_is_carrier(graph.k.c, sym.type) {
			if root := prov_root_for_symbol(graph, v.symbol); root != NO_ROOT {
				return prov_borrow(
					graph, root, nil,
					carrier_is_mutable(graph.k.c, sym.type),
					v.span,
					carrier_noun(graph.k.c, sym.type),
				)
			}
		}
	}
	// Reading a whole aggregate reads everything it holds.
	if content := prov_content_slots(graph, v.symbol); len(content) > 0 {
		prov_emit(graph, Prov_Event{kind = .Live, sources = content, span = v.span})
		return content
	}
	return nil
}

@(private = "file")
prov_invalidate :: proc(graph: ^Flow_Graph, place: Expr, span: Span, verb: string) {
	if root, path, ok := prov_place_of(graph, place); ok {
		prov_walk_subscripts(graph, place)
		prov_access(graph, root, path, .Invalidate, span, verb)
		return
	}
	walk_flow_expr(graph, place)
}

@(private)
prov_address_of :: proc(graph: ^Flow_Graph, v: ^Expr_Unary) -> []int {
	// `&place` is an immutable loan and `&mut place` an exclusive one: several
	// `&` borrows of one place may be live together, while a `&mut` excludes
	// every competing name (design.md "Capabilities and the one rule").
	//
	// A binding that views storage another owner holds -- a `&` loop element, a
	// switch payload over a place -- is not its own root: the pointer names the
	// source, and outlives the binding exactly as long as the source stays valid.
	if ident, is_ident := v.operand.(^Expr_Ident); is_ident {
		if loans, viewed := graph.view_loans[ident.symbol]; viewed {
			return loans
		}
	}
	root, path, ok := prov_place_of(graph, v.operand)
	if !ok {
		// Taking an element's address borrows through its slice/pointer; it
		// does not load the element's value (which may carry no borrows).
		if carriers, _, through := prov_read_through_carrier(graph, v.operand); through {
			return carriers
		}
		loans := walk_flow_expr(graph, v.operand)
		if len(loans) > 0 || !prov_expr_is_temporary(v.operand) {
			return loans
		}
		// A borrow of a value temporary may be used during that expression,
		// including by a called procedure, but cannot escape it (design.md).
		return prov_borrow(graph, prov_temp_root(graph, expr_span(v.operand)), nil, v.mutable, v.span, "pointer")
	}
	prov_walk_subscripts(graph, v.operand)
	access_block, access_index := prov_access(graph, root, path, v.mutable ? .Write : .Read, v.span)
	return prov_borrow(graph, root, path, v.mutable, v.span, "pointer", access_block, access_index)
}

@(private)
prov_slice :: proc(graph: ^Flow_Graph, v: ^Expr_Slice) -> []int {
	if len(v.bound) > 0 {
		// A selected `operator([:])` result is a borrow of the receiver unless
		// its result type is owning (design.md). M4a deliberately postponed this
		// relationship because it needed provenance.
		receiver_loans := walk_flow_expr(graph, v.bound[0])
		for index in 1 ..< len(v.bound) {
			if v.bound[index] != nil {
				walk_flow_expr(graph, v.bound[index])
			}
		}
		if !type_is_carrier(graph.k.c, v.type) {
			return nil // an owning result carries no borrow edge at all
		}
		if len(receiver_loans) > 0 {
			return receiver_loans
		}
		if root, path, ok := prov_place_of(graph, v.bound[0]); ok {
			return prov_borrow(graph, root, path, slice_is_mutable(graph.k.c, v.type), v.span, "slice")
		}
		return nil
	}
	mutable := slice_is_mutable(graph.k.c, v.type)
	// A fixed array, string, or dynamic array is sliced out of its own root's
	// storage: `st[low:high]` borrows a subrange view exactly as slicing a fixed
	// array does, and a dynamic array's range is a borrow of its own root too,
	// which every relocating operation on it then invalidates (design.md
	// "Dynamic arrays"). Reslicing a slice or pointer instead keeps the loans
	// the carrier already holds.
	operand_kind := underlying_kind(graph.k.c, expr_base(v.operand).type)
	array := operand_kind == .Array || operand_kind == .String || operand_kind == .Dynamic_Array
	if root, path, ok := prov_place_of(graph, v.operand); ok && array {
		prov_walk_subscripts(graph, v.operand)
		if v.lo != nil {
			walk_flow_expr(graph, v.lo)
		}
		if v.hi != nil {
			walk_flow_expr(graph, v.hi)
		}
		full := prov_extend(graph, path, prov_range_step(graph, v))
		access_block, access_index := prov_access(graph, root, full, mutable ? .Write : .Read, v.span)
		return prov_borrow(
			graph, root, full, mutable, v.span, carrier_noun(graph.k.c, v.type),
			access_block, access_index,
		)
	}
	// Reslicing a carrier keeps the loans it already holds. Composing the two
	// ranges could only narrow the result, so the source loans are both the
	// conservative and the correct answer.
	source := walk_flow_expr(graph, v.operand)
	if v.lo != nil {
		walk_flow_expr(graph, v.lo)
	}
	if v.hi != nil {
		walk_flow_expr(graph, v.hi)
	}
	if len(source) > 0 {
		return source
	}
	// A slice literal borrows a hidden array, which follows the surrounding
	// lexical scope (design.md); any other temporary ends with its statement.
	// An unmanaged composite — a slice literal's hidden `[N]T`, or an array
	// literal sliced in place — is frame storage and lives for that scope. A
	// *managed* one such as `[dynamic]int{1, 2}[:]` owns an allocation instead,
	// and nothing keeps that alive past the statement that built it.
	_, is_literal := v.operand.(^Expr_Composite)
	if is_literal && !type_is_managed(graph.k.c, expr_base(v.operand).type) {
		root := prov_new_root(graph, .Slice_Literal, expr_span(v.operand), "this slice literal")
		append(&graph.in_scope, Flow_Cleanup{kind = .Prov_Root, root = root, span = expr_span(v.operand)})
		return prov_borrow(graph, root, nil, mutable, v.span, "slice")
	}
	if prov_expr_is_temporary(v.operand) {
		return prov_borrow(graph, prov_temp_root(graph, expr_span(v.operand)), nil, mutable, v.span, "slice")
	}
	return nil
}

// The borrow a `foreach` holds on its iterable. Iterating a carrier reuses the
// loans it already holds; iterating a place borrows that place, mutably when the
// binding is written `ref` over a mutable sequence.
@(private)
prov_iterate :: proc(graph: ^Flow_Graph, s: ^Stmt_Foreach, iterated: []int) -> []int {
	if iteration_lends_source(graph.k.c, expr_base(s.iterable).type) { return iterated }
	root, path, ok := prov_place_of(graph, s.iterable)
	if !ok {
		return iterated
	}
	mutable := false
	for binding in s.bindings {
		mutable ||= binding.is_ref
	}
	span := expr_span(s.iterable)
	prov_access(graph, root, path, mutable ? .Write : .Read, span)
	return prov_join(graph, iterated, prov_borrow(graph, root, path, mutable, span, "iterator"))
}

// A root that ends with the statement that created it.
@(private)
prov_temp_root :: proc(graph: ^Flow_Graph, span: Span) -> Root_Id {
	root := prov_new_root(graph, .Temporary, span, "this temporary")
	append(&graph.temp_roots, root)
	return root
}

// A field of a temporary, or an element of one, is part of that temporary: the
// whole ends with the statement that built it, so a borrow reaching in through a
// selector or an index has the same root a borrow of the whole does. Without
// this, `build().items[:]` had no root at all and escaped unchecked.
@(private = "file")
prov_expr_is_temporary :: proc(e: Expr) -> bool {
	#partial switch v in e {
	case ^Expr_Composite, ^Expr_Call:
		return true
	case ^Expr_Selector:
		// `pkg.name` is a whole global, not a field of its operand.
		return v.resolution.kind != .Value && prov_expr_is_temporary(v.operand)
	case ^Expr_Index:
		return prov_expr_is_temporary(v.operand)
	}
	return false
}

@(private)
prov_declare :: proc(graph: ^Flow_Graph, d: ^Decl, value_loans: [][]int) {
	for id, symbol_index in d.symbols {
		sym := symbol_of(graph.k.c, id)
		if sym == nil || sym.kind != .Var {
			continue
		}
		root := prov_root_for_symbol(graph, id)
		if root != NO_ROOT && graph.roots[int(root)].kind == .Local {
			append(&graph.in_scope, Flow_Cleanup{kind = .Prov_Root, root = root, span = sym.span})
		}
		initializer: Expr
		if d.destructure.active {
			// One record initializes every binding on the left, so its region
			// component is that one value's.
			initializer = d.values[0]
		} else if symbol_index < len(d.values) {
			initializer = d.values[symbol_index]
		}
		projected := d.destructure.active ? symbol_index : -1
		prov_declare_region(graph, id, sym, initializer, projected)
		slot, is_carrier := prov_slot_for_symbol(graph, id)
		content := prov_content_slots(graph, id)
		if !is_carrier && len(content) == 0 {
			continue
		}
		sources: []int
		if value_loans != nil {
			if d.destructure.active {
				// design.md "Destructuring": each binding takes its own field's root,
				// not the record's joined set.
				sources = prov_destructure_field(
					graph, value_loans[0], &d.destructure, symbol_index, sym.type, sym.span,
				)
			} else if symbol_index < len(value_loans) {
				sources = value_loans[symbol_index]
			}
		}
		if !is_carrier {
			prov_define_content(graph, content, sources, sym.span)
			continue
		}
		prov_weaken(graph, sources, sym.type, slot, sym.span)
		prov_emit(graph, Prov_Event {
			kind    = .Def,
			slot    = slot,
			loan    = NO_LOAN,
			sources = sources,
			span    = sym.span,
		})
	}
}


// An allocator binding inherits the identity it was initialised from; a managed
// owner inherits the region its constructing call named.
@(private = "file")
prov_declare_region :: proc(
	graph: ^Flow_Graph,
	id: Symbol_Id,
	sym: ^Symbol,
	initializer: Expr,
	projected: int = -1,
) {
	initializer_region := Region_Set{}
	if initializer != nil {
		if projected >= 0 {
			initializer_region = prov_result_region_at(graph, initializer, {proj_field(projected)})
		} else {
			initializer_region = prov_result_region(graph, initializer)
		}
	}
	// design.md: a local `mem.Arena`/`mem.Scratch` *is* a region this body
	// created, so it gets its own token rather than merging into anything.
	if type_is_region_provider(graph.k.c, sym.type) && sym.duration == .None {
		graph.region_of[id] = prov_provider_region(graph, id)
		if initializer != nil {
			parent := initializer_region
			if !region_is_empty(parent) {
				graph.provider_parents[id] = parent
			}
		}
		append(&graph.owners_in_scope, id)
		return
	}
	if type_underlying(graph.k.c, sym.type) == TYPE_ALLOCATOR {
		if initializer != nil {
			graph.region_of[id] = initializer_region
		}
		return
	}
	if !type_is_managed(graph.k.c, sym.type) {
		return
	}
	set := prov_empty_region(graph)
	// An explicit `via` allocator is bound at the declaration (design.md). That
	// binding, not the initialiser, is what decides an owner's region -- a literal
	// `{}` names no region at all, and `via arena.allocator()` names one exactly.
	if written := symbol_via_allocator(graph.k.c, id); written != nil {
		region_merge(&set, prov_region_of(graph, written))
	}
	if initializer != nil {
		region_merge(&set, initializer_region)
	}
	if !region_is_empty(set) {
		graph.region_of[id] = set
		if sym.duration != .None && (region_is_parameter_backed(set) || region_has_local(set)) {
			storage := sym.duration == .Thread_Local ? "`thread_local` storage" : "`static` storage"
			prov_emit(graph, Prov_Event {
				kind   = .Region_Escape,
				span   = sym.span,
				verb   = identifier_text(graph.k.c, sym.name),
				name   = storage,
				region = set,
			})
		}
	}
	// Resetting a region is rejected while a live owning value, or a borrow,
	// still refers to storage from that allocator (design.md). All
	// lexical owners register once; the flow-insensitive region map may learn a
	// dependency from a later assignment.
	if sym.duration == .None {
		append(&graph.owners_in_scope, id)
	}
}

// One destructured binding's provenance: the record's own sources projected
// through that field, so a borrow reaching one field does not become a borrow
// reaching its siblings.
@(private = "file")
prov_destructure_field :: proc(
	graph: ^Flow_Graph,
	sources: []int,
	plan: ^Destructure,
	index: int,
	field_type: Type_Id,
	span: Span,
) -> []int {
	if len(sources) == 0 {
		return nil
	}
	return prov_project_content(graph, sources, plan.record, {proj_field(index)}, field_type, span)
}

@(private)
prov_assign :: proc(graph: ^Flow_Graph, s: ^Stmt_Assign, value_loans: [][]int) {
	for target, index in s.lhs {
		sources: []int
		value: Expr
		if s.destructure.active {
			value = s.rhs[0]
			if value_loans != nil && len(value_loans) > 0 {
				sources = prov_destructure_field(
					graph, value_loans[0], &s.destructure, index, expr_base(target).type, expr_span(target),
				)
			}
		} else if index < len(s.rhs) {
			value = s.rhs[index]
			if value_loans != nil && index < len(value_loans) {
				sources = value_loans[index]
			}
		}
		if value != nil && s.op == .Assign {
			prov_region_escape(graph, target, value)
		}
		value_region := Region_Set{}
		if value != nil {
			if s.destructure.active {
				value_region = prov_result_region_at(graph, value, {proj_field(index)})
			} else {
				value_region = prov_result_region(graph, value)
			}
		}
		if ident, is_ident := target.(^Expr_Ident); is_ident && s.op == .Assign {
			if value != nil {
				if type_underlying(graph.k.c, expr_base(target).type) == TYPE_ALLOCATOR {
					existing, found := graph.region_of[ident.symbol]
					if !found {
						existing = prov_empty_region(graph)
					}
					region_merge(&existing, value_region)
					graph.region_of[ident.symbol] = existing
				} else if type_is_managed(graph.k.c, expr_base(target).type) {
					existing, found := graph.region_of[ident.symbol]
					if !found {
						existing = prov_empty_region(graph)
					}
					region_merge(&existing, value_region)
					graph.region_of[ident.symbol] = existing
				}
			}
			prov_retain_escape(graph, target, sources, expr_span(target))
			// Moving, dropping, freeing, fully assigning, or exchanging a root
			// invalidates borrows of its previous value (design.md).
			prov_invalidate(graph, target, expr_span(target), "assigned")
			if slot, is_carrier := prov_slot_for_symbol(graph, ident.symbol); is_carrier {
				prov_weaken(graph, sources, expr_base(target).type, slot, expr_span(target))
				prov_emit(graph, Prov_Event {
					kind    = .Def,
					slot    = slot,
					loan    = NO_LOAN,
					sources = sources,
					span    = expr_span(target),
				})
			} else if content := prov_content_slots(graph, ident.symbol); len(content) > 0 {
				// Replacing the whole value replaces everything it held.
				prov_define_content(graph, content, sources, expr_span(target))
			}
			continue
		}
		// A write through a field or an element touches only that path.
		prov_retain_escape(graph, target, sources, expr_span(target))
		root, path, place_ok := prov_place_of(graph, target)
		if !place_ok && s.op == .Assign {
			// The destination is reached through a carrier, so what it names is
			// solved rather than written out.
			if through := prov_retain_through_carrier(graph, target); len(through) > 0 {
				prov_walk_subscripts(graph, target, true)
				// The destination's own type still decides the capability, exactly
				// as it would if the place had been written out: a fresh mutable
				// borrow written into a read-only field is simply created
				// read-only (design.md "Weakening and read-only reborrows").
				if len(sources) > 0 {
					prov_weaken(graph, sources, expr_base(target).type)
					prov_emit(graph, Prov_Event {
						kind    = .Publish,
						span    = expr_span(target),
						sources = sources,
						into    = through,
					})
				}
				prov_emit(graph, Prov_Event{kind = .Live, sources = through, span = expr_span(target)})
				continue
			}
		}
		if place_ok {
			if value != nil && s.op == .Assign &&
			   (type_is_managed(graph.k.c, expr_base(target).type) ||
			    type_underlying(graph.k.c, expr_base(target).type) == TYPE_ALLOCATOR) {
				prov_define_region_content(
					graph, root, path, value_region,
				)
			}
			prov_walk_subscripts(graph, target, s.op == .Assign)
			prov_access(graph, root, path, .Write, expr_span(target))
			// Only the written path is replaced; the surviving fields keep what
			// they held.
			if written := prov_content_at(graph, root, path); len(written) > 0 && s.op == .Assign {
				prov_define_content(graph, written, sources, expr_span(target), path, expr_base(target).type)
			}
			continue
		}
		walk_flow_expr(graph, target)
	}
}

// The procedure type a call goes through: the chosen overload's when the callee
// is a declaration, and the callee expression's own when it is a value. The
// second is the one that matters for `@(escape=...)`, because an indirect call
// is exactly where there is no body to infer from.
@(private = "file")
prov_call_proc_type :: proc(graph: ^Flow_Graph, v: ^Expr_Call) -> Type_Id {
	if sym := symbol_of(graph.k.c, v.resolution.chosen_overload); sym != nil {
		return sym.proc_type
	}
	if base := expr_base(v.callee); base != nil {
		return base.type
	}
	return INVALID_TYPE
}

// The loans of every argument whose parameter may still be named after the call.
// A parameter written `@(escape=none)` promises nothing survives, which is what
// keeps a scratch argument out of an indirect call's conservative result.
@(private = "file")
prov_escaping_actuals :: proc(graph: ^Flow_Graph, v: ^Expr_Call, actuals: [][]int) -> []int {
	proc_type := prov_call_proc_type(graph, v)
	out: []int
	for slots, index in actuals {
		if proc_param_escape(graph.k.c, proc_type, index) == .None {
			continue
		}
		out = prov_join(graph, out, slots)
	}
	return out
}

prov_parameter_type :: proc(graph: ^Flow_Graph, v: ^Expr_Call, index: int) -> Type_Id {
	info := underlying_info(graph.k.c, prov_call_proc_type(graph, v))
	if info == nil || index >= len(info.parameters) {
		return INVALID_TYPE
	}
	return info.parameters[index]
}

@(private = "file")
prov_has_direct_body :: proc(c: ^Compiler, id: Symbol_Id) -> bool {
	sym := symbol_of(c, id)
	if sym == nil || sym.kind != .Proc {
		return false
	}
	if sym.proc_literal != nil {
		return sym.proc_literal.body != nil
	}
	if sym.decl != nil {
		literal := decl_proc(sym.decl)
		return literal != nil && literal.body != nil
	}
	return false
}

@(private = "file")
prov_result_is_inout :: proc(graph: ^Flow_Graph, v: ^Expr_Call) -> bool {
	info := underlying_info(graph.k.c, prov_call_proc_type(graph, v))
	return info != nil && info.result_inout
}

@(private = "file")
prov_argument_is_inout :: proc(graph: ^Flow_Graph, v: ^Expr_Call, index: int) -> bool {
	// The declaration's type when there is one, the callee value's otherwise: a
	// parameter mode is part of procedure-type compatibility, so an indirect call
	// answers this question as well as a direct one does.
	info := underlying_info(graph.k.c, prov_call_proc_type(graph, v))
	if info == nil || index >= len(info.param_modes) {
		return false
	}
	return info.param_modes[index] == .Inout
}

@(private)
prov_call :: proc(graph: ^Flow_Graph, v: ^Expr_Call) -> []int {
	c := graph.k.c
	#partial switch _ in v.operation {
	case Call_Text, Call_Text_Conversion:
		return prov_text_call(graph, v)
	}
	if sym := symbol_of(c, v.resolution.symbol); sym != nil && sym.kind == .Builtin {
		#partial switch sym.builtin {
		case .New, .New_Clone:
			for argument in v.bound {
				if argument != nil {
					walk_flow_expr(graph, argument)
				}
			}
			// `new` creates a new allocation root and returns a checked pointer to
			// its first value (design.md).
			root := prov_new_root(graph, .Allocation, v.span, "this allocation")
			graph.roots[int(root)].symbol = INVALID_SYMBOL
			// design.md `new`: "the allocation root has region provenance
			// identifying its allocator region". The written allocator is bound
			// past the operands; without one the call took the default provider.
			region := prov_empty_region(graph)
			region.default = true
			operands := sym.builtin == .New ? 0 : 1
			if len(v.bound) > operands {
				allocator := v.bound[operands]
				region = prov_region_of(graph, allocator)
				append(&graph.allocation_region_sources, Prov_Allocation_Region_Source {
					root = root,
					value = allocator,
				})
			}
			graph.roots[int(root)].region = region
			return prov_borrow(graph, root, nil, true, v.span, "pointer")
		case .Unsafe_Free:
			// The unchecked release: no allocation root to end, and nothing to
			// invalidate, because the pointer's provenance is exactly what the
			// caller is promising instead of proving (design.md "What is not
			// checked"). The operands are still read.
			for bound in v.bound {
				walk_flow_expr(graph, bound)
			}
			return nil
		case .Free:
			if len(v.bound) >= 1 {
				sources := walk_flow_expr(graph, v.bound[0])
				// A written allocator is read like any other operand; only the
				// pointer names what the release ends.
				for bound in v.bound[1:] {
					walk_flow_expr(graph, bound)
				}
				prov_emit(graph, Prov_Event{kind = .Free, sources = sources, span = v.span})
			}
			return nil
		case .Free_All:
			if len(v.bound) >= 1 {
				region := prov_region_of(graph, v.bound[0])
				walk_flow_expr(graph, v.bound[0])
				prov_reset(graph, region, v.span, true, v)
			}
			return nil
		case .Drop:
			if len(v.bound) == 1 {
				prov_invalidate(graph, v.bound[0], v.span, "dropped")
			}
			return nil
		case .Exchange:
			if len(v.bound) == 2 {
				prov_invalidate(graph, v.bound[0], v.span, "exchanged")
				walk_flow_expr(graph, v.bound[1])
			}
			return nil
		case .Atomic_Load, .Atomic_Store, .Atomic_Exchange, .Atomic_Compare_Exchange,
		     .Atomic_Add, .Atomic_Sub, .Atomic_And, .Atomic_Or, .Atomic_Xor, .Atomic_Fence:
			// An atomic reads and writes *through* its address operand; what it hands
			// back is the value in that storage, not a borrow of it. Without this, an
			// `Atomic(^T)` could never load, because the coarse rule would derive the
			// loaded pointer from the address of the atomic itself and then reject it
			// for outliving the receiver.
			for argument in v.bound {
				if argument != nil {
					walk_flow_expr(graph, argument)
				}
			}
			return nil
		case .Unsafe_Take, .Unsafe_Write:
			// Both replace what the place holds, so a borrow of it ends here exactly
			// as at an `exchange`.
			if len(v.bound) >= 1 {
				prov_invalidate(graph, v.bound[0], v.span, sym.builtin == .Unsafe_Take ? "taken" : "overwritten")
				for bound in v.bound[1:] {
					walk_flow_expr(graph, bound)
				}
			}
			return nil
		case .Unsafe_Forget:
			if len(v.bound) == 1 {
				// The carriers the operand held go nowhere: nothing binds the
				// forgotten value, so every loan inside it ends here. Invalidating
				// the source root is what keeps `forget` from reading as a lifetime
				// extension — a borrow of it dies here exactly as at a `drop`.
				prov_consume(graph, v.bound[0], v.span, "forgotten")
			}
			return nil
		}
	}
	receiver := Param_Mode.Value
	has_receiver := false
	container_op := Container_Op.None
	if sym := symbol_of(c, v.resolution.chosen_overload); sym != nil && sym.has_receiver {
		receiver, has_receiver = sym.receiver, true
		if sym.synth == .Container_Op {
			container_op = sym.container_op
		}
	}
	// Method-call syntax puts the receiver in `bound[0]`; walking the callee
	// selector as well would count one access twice.
	if !(has_receiver && len(v.bound) > 0) {
		walk_flow_expr(graph, v.callee)
	}
	if len(v.bound) == 0 {
		actuals := make([][]int, max(len(v.args), 1), graph.alloc)
		borrowed: []int
		for argument, index in v.args {
			actuals[index] = walk_flow_expr(graph, argument.value)
			borrowed = prov_join(graph, borrowed, actuals[index])
		}
		// A reset happens during the call, after argument evaluation, while every
		// borrow handed to the callee is still live. Put the reset before the call
		// boundary use so backward liveness sees those actuals at the reset.
		prov_call_resets(graph, v)
		if len(borrowed) > 0 {
			prov_emit(graph, Prov_Event{kind = .Live, sources = borrowed, span = v.span})
		}
			return prov_store_call_results(graph, v, actuals, borrowed)
	}
	// The loans each actual argument carried, so a direct call can substitute
	// them into the callee's result summary.
	actuals := make([][]int, len(v.bound), graph.alloc)
	borrowed: []int
	for argument, index in v.bound {
		// design.md "Variadic parameters": the pack slot holds no single written
		// expression unless a sole spread is forwarded. Its operands are walked
		// here so each one's borrows still reach the call boundary.
		if v.is_variadic && index == v.variadic_slot && !v.variadic_forwards {
			actuals[index] = prov_variadic_pack(graph, v)
			borrowed = prov_join(graph, borrowed, actuals[index])
			continue
		}
		if argument == nil {
			continue
		}
		if index == 0 && receiver == .Move {
			// A consumed receiver hands its contents to the callee, so a result
			// derived from it depends on what the receiver held.
			// The move expression's own span, not the whole call's: what conflicts
			// is the consumption of the receiver.
			actuals[index] = prov_consume(graph, argument, expr_span(argument), "moved")
			borrowed = prov_join(graph, borrowed, actuals[index])
			continue
		}
		// Any user operation whose `self` parameter is `inout` also invalidates
		// element and view borrows of the receiver (design.md).
		if index == 0 && receiver == .Inout {
			// The callee can read borrows held inside its mutable receiver, as
			// `iterator.next()` reads its slice. Keep those sources live through
			// the call separately from the borrow of the receiver's own storage
			// used by result substitution below.
			borrowed = prov_join(graph, borrowed, prov_carrier_slots(graph, argument))
			prov_invalidate(graph, argument, v.span, "modified")
			// design.md "Borrowing iteration": a result derived from a view the
			// receiver holds names that view's source, never the receiver's own
			// storage, so advancing or dropping the receiver cannot invalidate an
			// element already handed back. The callee's summary is what tells the
			// two apart -- a dependency reaching the receiver's own storage widens
			// to the whole parameter, while one that only reads through what it
			// carries stays narrowed to those paths.
			//
			// The two iteration synths have no body to summarize, so they keep
			// naming themselves until step 4 of the iteration unification gives
			// every lending iterator a summary of its own.
			lends := prov_result_reads_through_receiver(c, v, index)
			if callee := symbol_of(c, v.resolution.chosen_overload); callee != nil {
				lends ||= callee.synth == .Slice_Ref_Next ||
					(callee.synth == .Indexed_Next && iteration_lends_source(c, expr_base(argument).type))
			}
			if lends {
				actuals[index] = prov_carrier_slots(graph, argument)
				continue
			}
			if root, path, ok := prov_place_of(graph, argument); ok {
				if prov_op_removes_element(container_op) {
					// What a removal hands back is what that element held, not a
					// borrow of the container it came out of. The invalidation
					// above is still what ends the borrows the container's own
					// storage was carrying.
					actuals[index] = prov_content_at(
						graph, root, prov_element_path(graph, v, path, container_op),
					)
				} else {
					actuals[index] = prov_join(graph, prov_carrier_slots(graph, argument),
						prov_borrow(graph, root, path, true, expr_span(argument), "borrow"))
				}
				borrowed = prov_join(graph, borrowed, actuals[index])
			}
			continue
		}
		if index == 0 && prov_op_returns_view(container_op) {
			// design.md "Iteration adapters": a view holds the map's table, so it
			// borrows the map for as long as it lives -- exactly as the `[]T` a
			// dynamic array hands out borrows that container. The borrow is
			// read-only: a view yields copies, and a live one is what stops the map
			// being mutated under it.
			//
			// The two components are separate. What the *stored elements* borrow
			// travels with the view as well: a `map[K]string_view` yields views of
			// someone else's bytes, and an owned copy of one still obeys that
			// source's lifetime, not the map's.
			held := walk_flow_expr(graph, argument)
			if root, path, ok := prov_place_of(graph, argument); ok {
				prov_access(graph, root, path, .Read, expr_span(argument))
				held = prov_join(
					graph, held, prov_borrow(graph, root, path, false, expr_span(argument), "view"),
				)
			} else if prov_expr_is_temporary(argument) {
				// A view of a temporary map borrows storage that ends with the
				// statement that built it, exactly as slicing one does.
				held = prov_join(
					graph, held,
					prov_borrow(graph, prov_temp_root(graph, expr_span(argument)), nil, false, v.span, "view"),
				)
			}
			actuals[index] = held
			borrowed = prov_join(graph, borrowed, held)
			continue
		}
		if prov_argument_is_inout(graph, v, index) {
			if root, path, ok := prov_place_of(graph, argument); ok {
				// An explicit `inout` argument has the same read capability as a
				// mutable receiver, including when it forwards an iterator.
				borrowed = prov_join(graph, borrowed, prov_carrier_slots(graph, argument))
				prov_walk_subscripts(graph, argument)
				prov_access(graph, root, path, .Write, expr_span(argument))
				// An `inout` parameter aliases the caller's root, so a borrow returned
				// from it is derived from that root (design.md).
				actuals[index] = prov_join(graph, prov_carrier_slots(graph, argument),
					prov_borrow(graph, root, path, true, expr_span(argument), "borrow"))
				borrowed = prov_join(graph, borrowed, actuals[index])
				continue
			}
		}
		if index == 0 && container_op == .Map_Lookup_Value {
			// `lookup_value` copies the selected payload. Its result carries the
			// payload's stored dependencies, including when the payload is itself
			// a bare carrier; only entry addresses borrow the map's storage.
			result_type := v.type
			entry_step := prov_map_call_step(graph, v)
			if root, path, ok := prov_place_of(graph, argument); ok {
				prov_walk_subscripts(graph, argument)
				prov_access(graph, root, path, .Read, expr_span(argument))
				entry := prov_extend(graph, path, entry_step)
				value := prov_extend(graph, entry, proj_field(PROJ_MAP_VALUE))
				actuals[index] = prov_read_content(graph, root, value, result_type, v.span)
			} else {
				receiver := walk_flow_expr(graph, argument)
				entry := prov_extend(graph, nil, entry_step)
				value := prov_extend(graph, entry, proj_field(PROJ_MAP_VALUE))
				actuals[index] = prov_project_content(
					graph, receiver, expr_base(argument).type, value, result_type, v.span,
				)
			}
		} else if (index == 0 && receiver == .Borrow) ||
		          proc_parameter_mode(c, prov_call_proc_type(graph, v), index) == .Borrow {
			// design.md "Receiver forms": an immutable receiver designates the
			// caller's value, so a borrow the method returns derives from the
			// caller's root just as an `inout` receiver's does. The difference is
			// only the capability: this loan is read-only and invalidates nothing,
			// which is what lets several of them be live at once.
			//
			// What the receiver itself carries travels with the result as well —
			// a method on a record of views can hand one of those views back, and
			// that copy obeys the view's own source, not the receiver's storage.
			held := walk_flow_expr(graph, argument)
			callee := symbol_of(c, v.resolution.chosen_overload)
			if callee != nil && (callee.synth == .Adapter_Iter || callee.synth == .Iterator_Copy ||
			   callee.synth == .Refs_Iter || callee.synth == .Refs_Iter_Reverse ||
			   ((callee.synth == .Adapter_View || callee.synth == .Refs_View) && type_of(c, callee.result).adapter_by_value)) {
				actuals[index] = held
				borrowed = prov_join(graph, borrowed, held)
				continue
			}
			if root, path, ok := prov_place_of(graph, argument); ok && !expression_converts_storage(argument) {
				prov_walk_subscripts(graph, argument)
				prov_access(graph, root, path, .Read, expr_span(argument))
				held = prov_join(
					graph, held, prov_borrow(graph, root, path, false, expr_span(argument), "borrow"),
				)
			} else {
				// A method on a temporary borrows storage that ends with the
				// statement that built it, exactly as slicing one does.
				held = prov_join(
					graph, held,
					prov_borrow(graph, prov_temp_root(graph, expr_span(argument)), nil, false, v.span, "borrow"),
				)
			}
			actuals[index] = held
		} else {
			actuals[index] = walk_flow_expr(graph, argument)
		}
		prov_weaken(graph, actuals[index], prov_parameter_type(graph, v, index))
		borrowed = prov_join(graph, borrowed, actuals[index])
	}
	prov_call_resets(graph, v)
	prov_call_retention(graph, v, actuals)
	prov_container_content(graph, v, container_op, actuals)
	if len(borrowed) > 0 {
		prov_emit(graph, Prov_Event{kind = .Live, sources = borrowed, span = v.span})
	}
	return prov_store_call_results(graph, v, actuals, borrowed)
}

// The caller's half of `@(escape=...)`, which the callee's body check cannot
// answer: only the caller knows how long the storage behind an argument lives.
//
// `static` is direct — the argument must still exist when the process ends.
// `stored` means the callee may write the argument into a destination this
// call hands it, so the call is modelled as that assignment: same duration
// check, same flow — the destination carries what the argument borrowed, and
// existing scope rules handle the rest. Modelling the flow lets a caller-local
// destination work without proving one local outlives another: the loan just
// travels, and using it after its root ends is already an error.
@(private = "file")
prov_call_retention :: proc(graph: ^Flow_Graph, v: ^Expr_Call, actuals: [][]int) {
	proc_type := prov_call_proc_type(graph, v)
	if underlying_info(graph.k.c, proc_type) == nil {
		return
	}
	destinations: []int
	for slots, index in actuals {
		if len(slots) == 0 {
			continue
		}
		level := proc_param_escape(graph.k.c, proc_type, index)
		if level == .Static {
			prov_emit(graph, Prov_Event {
				kind    = .Retain,
				span    = v.span,
				sources = slots,
				root    = NO_ROOT,
				retain  = .Process,
				verb    = prov_parameter_label(graph, v, index),
			})
		}
		if level < .Stored {
			continue
		}
		if destinations == nil {
			destinations = prov_writable_arguments(graph, v, proc_type)
		}
		for target in destinations {
			if target != index {
				prov_retain_into_argument(graph, v, target, actuals[target], slots)
			}
		}
	}
}

// The arguments a call can write through, which is where a `stored` parameter
// may end up: an `inout` parameter or receiver, and a mutable carrier whose
// pointee or element could hold the borrow. These are the destinations the body
// check recognises, so caller and callee agree on the set.
//
// A destination that cannot hold a borrow at all is not one: `inout int` names
// caller storage, but nothing a call retains can land in it.
@(private = "file")
prov_writable_arguments :: proc(graph: ^Flow_Graph, v: ^Expr_Call, proc_type: Type_Id) -> []int {
	c := graph.k.c
	out := make([dynamic]int, 0, len(v.bound), graph.alloc)
	sym := symbol_of(c, v.resolution.chosen_overload)
	// A receiver is `bound[0]` and answers with its own mode; an ordinary
	// parameter answers with the procedure type's.
	start := 0
	if sym != nil && sym.has_receiver {
		start = 1
		if sym.receiver == .Inout && len(v.bound) > 0 && v.bound[0] != nil {
			if type_carries_borrow(c, expr_base(v.bound[0]).type).any {
				append(&out, 0)
			}
		}
	}
	info := underlying_info(c, proc_type)
	for index in start ..< len(v.bound) {
		if info == nil || index >= len(info.parameters) {
			break
		}
		if prov_argument_is_inout(graph, v, index) {
			if type_carries_borrow(c, info.parameters[index]).any {
				append(&out, index)
			}
			continue
		}
		// Writing through the parameter itself: `p^.view = values`. What can be
		// retained is what the pointee or element holds, not the pointer.
		if !carrier_is_mutable(c, info.parameters[index]) {
			continue
		}
		element := underlying_info(c, info.parameters[index])
		if element != nil && type_carries_borrow(c, element.element).any {
			append(&out, index)
		}
	}
	return out[:]
}

// One argument receiving what another may leave in it. The duration question is
// the assignment's — a destination in static, thread, or the caller's own
// storage needs a source that outlives it — and the flow is the assignment's
// too, joined rather than replaced because the callee may also leave it alone.
//
// Which storage the argument names depends on how it was passed. An `inout`
// argument *is* the destination place. A `^mut`/`[]mut` argument is a carrier
// pointing at the destination, so both halves go through its loans instead:
// `carrier` is what it borrows, and the solver reads the roots off it.
@(private = "file")
prov_retain_into_argument :: proc(
	graph: ^Flow_Graph,
	v: ^Expr_Call,
	index: int,
	carrier: []int,
	sources: []int,
) {
	argument := v.bound[index]
	if argument == nil {
		return
	}
	if !prov_argument_is_place(graph, v, index) {
		if len(carrier) == 0 {
			return
		}
		prov_emit(graph, Prov_Event {
			kind    = .Retain,
			span    = v.span,
			sources = sources,
			root    = NO_ROOT,
			into    = carrier,
		})
		prov_emit(graph, Prov_Event {
			kind    = .Publish,
			span    = v.span,
			sources = sources,
			into    = carrier,
		})
		return
	}
	root, path, ok := prov_place_of(graph, argument)
	if !ok {
		return
	}
	prov_retain_escape(graph, argument, sources, v.span)
	slots := prov_content_at(graph, root, path)
	if len(slots) == 0 {
		ident, is_ident := argument.(^Expr_Ident)
		if !is_ident {
			return
		}
		slot, is_carrier := prov_slot_for_symbol(graph, ident.symbol)
		if !is_carrier {
			return
		}
		slots = prov_one(graph, slot)
	}
	for slot in slots {
		prov_define_one_content(graph, slot, prov_join(graph, prov_one(graph, slot), sources), v.span)
	}
}

// Whether this argument names the destination itself rather than pointing at it.
@(private = "file")
prov_argument_is_place :: proc(graph: ^Flow_Graph, v: ^Expr_Call, index: int) -> bool {
	if index == 0 {
		if sym := symbol_of(graph.k.c, v.resolution.chosen_overload); sym != nil && sym.has_receiver {
			return sym.receiver == .Inout
		}
	}
	return prov_argument_is_inout(graph, v, index)
}

@(private = "file")
prov_parameter_label :: proc(graph: ^Flow_Graph, v: ^Expr_Call, index: int) -> string {
	sym := symbol_of(graph.k.c, v.resolution.chosen_overload)
	if sym == nil || index >= len(sym.param_symbols) {
		return "a parameter this call may keep"
	}
	bound := symbol_of(graph.k.c, sym.param_symbols[index])
	if bound == nil {
		return "a parameter this call may keep"
	}
	return fmt.aprintf(
		"`%s`, which `%s` may keep",
		identifier_text(graph.k.c, bound.name),
		identifier_text(graph.k.c, sym.name),
		allocator = graph.k.c.semantic_allocator,
	)
}

// Which operations hand back a borrowed view of the container rather than a
// value out of it.
@(private = "file")
prov_op_returns_view :: proc(op: Container_Op) -> bool {
	#partial switch op {
	case .Map_Entries, .Map_Keys, .Map_Values:
		return true
	}
	return false
}

// Which operations hand an element back out. Their result is the element, so it
// carries what the element held rather than a borrow of the container.
@(private = "file")
prov_op_removes_element :: proc(op: Container_Op) -> bool {
	#partial switch op {
	case .Pop, .Remove, .Remove_Unordered, .Map_Remove:
		return true
	}
	return false
}

// The content path a removal reads from. A map entry's key and value are
// separate storage, so removing a value does not hand back what a key borrows.
@(private = "file")
prov_element_path :: proc(
	graph: ^Flow_Graph,
	v: ^Expr_Call,
	path: []Proj_Step,
	op: Container_Op,
) -> []Proj_Step {
	if op != .Map_Remove {
		return prov_extend(graph, path, proj_wild())
	}
	entry := prov_extend(graph, path, prov_map_call_step(graph, v))
	return prov_extend(graph, entry, proj_field(PROJ_MAP_VALUE))
}

// The entry step for a map operation that takes its key as an argument.
@(private = "file")
prov_map_call_step :: proc(graph: ^Flow_Graph, v: ^Expr_Call) -> Proj_Step {
	if len(v.bound) < 2 || v.bound[0] == nil {
		return proj_wild()
	}
	return prov_map_entry_step(graph, expr_base(v.bound[0]).type, v.bound[1])
}

// A container operation is resolved before this point, so the solver asks
// `Container_Op` rather than recognising a member name. Stored key/value
// borrows become the receiver's and must satisfy its duration just like an
// indexed assignment. A fallible write joins the matching previous content
// because its failure edge changes nothing.
@(private = "file")
prov_container_content :: proc(graph: ^Flow_Graph, v: ^Expr_Call, op: Container_Op, actuals: [][]int) {
	#partial switch op {
	case .Append, .Insert, .Map_Try_Insert, .Map_Find_Or_Insert, .Clear, .Map_Clear:
	case:
		return
	}
	if len(v.bound) == 0 || v.bound[0] == nil {
		return
	}
	info := underlying_info(graph.k.c, expr_base(v.bound[0]).type)
	if info == nil {
		return
	}
	if op == .Clear || op == .Map_Clear {
		// A successful clear is a known whole-content replacement. Existing
		// copies have their own slots and keep their dependencies; only the
		// receiver's removed contents become empty.
		if root, path, ok := prov_place_of(graph, v.bound[0]); ok {
			if content := prov_content_at(graph, root, path); len(content) > 0 {
				prov_define_content(
					graph, content, nil, v.span, path, expr_base(v.bound[0]).type,
				)
			}
		}
		return
	}
	stored: []int
	#partial switch op {
	case .Append:
		if type_carries_borrow(graph.k.c, info.element).any && len(actuals) > 1 {
			stored = actuals[1]
		}
	case .Insert:
		if type_carries_borrow(graph.k.c, info.element).any && len(actuals) > 2 {
			stored = actuals[2]
		}
	// `find_or_insert` stores the same two halves `try_insert` does; only its
	// result differs (design.md "Map container operations").
	case .Map_Try_Insert, .Map_Find_Or_Insert:
		if type_carries_borrow(graph.k.c, info.key).any && len(actuals) > 1 {
			stored = actuals[1]
		}
		if type_carries_borrow(graph.k.c, info.element).any && len(actuals) > 2 {
			stored = prov_join(graph, stored, actuals[2])
		}
	}
	if len(stored) == 0 {
		return
	}
	// This also resolves a receiver reached through a pointer or slice carrier,
	// so synthesized mutation cannot bypass caller/static retention through an
	// alias even when no lexical root is available for the content update below.
	prov_retain_escape(graph, v.bound[0], stored, v.span)
	root, path, ok := prov_place_of(graph, v.bound[0])
	if !ok {
		return
	}
	if op == .Map_Try_Insert || op == .Map_Find_Or_Insert {
		entry := prov_extend(graph, path, prov_map_call_step(graph, v))
		if len(actuals) > 1 && len(actuals[1]) > 0 {
			written := prov_extend(graph, entry, proj_field(PROJ_MAP_KEY))
			if content := prov_content_at(graph, root, written); len(content) > 0 {
				prov_define_content(graph, content, actuals[1], v.span, written, info.key, true)
			}
		}
		if len(actuals) > 2 && len(actuals[2]) > 0 {
			written := prov_extend(graph, entry, proj_field(PROJ_MAP_VALUE))
			if content := prov_content_at(graph, root, written); len(content) > 0 {
				prov_define_content(graph, content, actuals[2], v.span, written, info.element, true)
			}
		}
		return
	}
	// A dynamic array's wildcard element path represents every existing element
	// plus the inserted one, so the write naturally joins instead of replacing.
	written := prov_extend(graph, path, proj_wild())
	if content := prov_content_at(graph, root, written); len(content) > 0 {
		prov_define_content(graph, content, stored, v.span, written, info.element)
	}
}

// Every operand of an unforwarded variadic pack, in written order. The pack
// itself is compiler-owned stack storage, so its loans are exactly the union of
// what its elements and spreads carry.
@(private = "file")
prov_variadic_pack :: proc(graph: ^Flow_Graph, v: ^Expr_Call) -> []int {
	joined: []int
	next_element, next_spread := 0, 0
	for is_spread in v.variadic_order {
		operand: Expr
		if is_spread {
			operand = v.variadic_spreads[next_spread]
			next_spread += 1
		} else {
			operand = v.variadic_elements[next_element]
			next_element += 1
		}
		joined = prov_join(graph, joined, walk_flow_expr(graph, operand))
	}
	return joined
}

// design.md "string type conversions": every text operation is either a borrow
// of its operand or a fresh owner, and which it is follows from the result type
// alone. A borrow carries the operand's loans; an owner carries none, so the
// analysis stops there rather than pretending the result outlives its source.
@(private = "file")
prov_text_call :: proc(graph: ^Flow_Graph, v: ^Expr_Call) -> []int {
	source: []int
	for argument, index in v.bound {
		if argument == nil {
			continue
		}
		loans := walk_flow_expr(graph, argument)
		if index == 0 {
			source = loans
			// `text.bytes()`, `text[lo:hi]`, and `to_c_view()` all borrow the
			// receiver's own storage, so a receiver that is itself a root — an owning
			// `string` local — lends it here.
			if len(source) == 0 && text_result_borrows(graph.k.c, v) {
				if root, path, ok := prov_place_of(graph, argument); ok {
					source = prov_borrow(graph, root, path, false, v.span, "view")
				}
			}
		}
	}
	if !text_result_borrows(graph.k.c, v) {
		return nil
	}
	return source
}

// Whether this text operation's result is a borrow of its operand rather than a
// fresh owner. `clone`, `+`, and every validating conversion that copies produce
// owners; the views do not.
@(private = "file")
text_result_borrows :: proc(c: ^Compiler, v: ^Expr_Call) -> bool {
	#partial switch operation in v.operation {
	case Call_Text:
		if operation.op == .Copy || operation.op == .From_Runes { return false }
	case Call_Text_Conversion:
		if operation.op == .String_From_Bytes || operation.op == .String_From_C_View { return false }
	}
	return prov_carries_borrow(c, v.type)
}

// A carrier, or an `Option`/`Result` around one: the wrapper travels with the
// borrow its payload holds, and unwrapping it hands that borrow on.
@(private = "file")
prov_carries_borrow :: proc(c: ^Compiler, type: Type_Id, depth := 0) -> bool {
	if type == INVALID_TYPE || depth > 8 {
		return false
	}
	if type_is_carrier(c, type) {
		return true
	}
	info := underlying_info(c, type)
	if info == nil || info.kind != .Union {
		return false
	}
	for payload in info.variants {
		if payload != TYPE_VOID && prov_carries_borrow(c, payload, depth + 1) {
			return true
		}
	}
	return false
}

@(private = "file")
prov_store_call_results :: proc(graph: ^Flow_Graph, v: ^Expr_Call, actuals: [][]int, borrowed: []int) -> []int {
	if v.type == TYPE_VOID || v.type == INVALID_TYPE {
		return nil
	}
	result := Prov_Call_Result {
		loans          = prov_call_result(graph, v, actuals, borrowed, v.type),
		region         = prov_call_region(graph, v, v.type),
		region_content = prov_call_region_content(graph, v),
	}
	graph.call_results[v] = result
	return result.loans
}

// design.md "Temporaries and procedure boundaries". At a direct call the actual
// argument roots are substituted into the callee's result summary. At a call
// through a plain procedure type there is no summary, so a returned carrier is
// conservatively derived from every borrowed argument, and fresh-allocation
// provenance is erased -- which is what keeps an indirect result away from
// checked `free`.

// Allocator-wide invalidation is the one effect propagated through arbitrary
// ordinary procedure wrappers (design.md), and it survives an indirect call
// because the attribute is part of the procedure type.
@(private = "file")
prov_call_resets :: proc(graph: ^Flow_Graph, v: ^Expr_Call) {
	proc_type := INVALID_TYPE
	if sym := symbol_of(graph.k.c, v.resolution.chosen_overload); sym != nil {
		proc_type = sym.proc_type
	} else if v.callee != nil {
		proc_type = expr_base(v.callee).type
	}
	if proc_type == INVALID_TYPE {
		return
	}
	arguments := v.bound
	if len(arguments) == 0 {
		return
	}
	for argument, index in arguments {
		if argument == nil || !proc_param_resets(graph.k.c, proc_type, index) {
			continue
		}
		prov_reset(graph, prov_region_of(graph, argument), v.span, false, v)
	}
}

@(private = "file")
prov_call_result :: proc(
	graph: ^Flow_Graph,
	v: ^Expr_Call,
	actuals: [][]int,
	borrowed: []int,
	result_type: Type_Id,
) -> []int {
	c := graph.k.c
	// design.md "`inout` results": an `inout` result is the caller's storage, so
	// the call is a place aliasing whatever the `inout` arguments named. It is not
	// a carrier type, which is why it is answered before the carrier test.
	if prov_result_is_inout(graph, v) {
		out: []int
		for slots, index in actuals {
			if prov_argument_is_inout(graph, v, index) {
				out = prov_join(graph, out, slots)
			}
		}
		return type_is_carrier(c, result_type) ? out : prov_value_content(graph, out, result_type, v.span)
	}
	// design.md "Shared ownership": "`handle.get()` returns a non-owning `^T`
	// whose root provenance derives from that handle", and "the borrow may not
	// outlive the handle used to obtain it". The body cannot show that — the
	// payload address comes out of a `rawptr` control block — so the language
	// asserts it here instead of inferring it.
	if len(actuals) > 0 && prov_receiver_is_shared_handle(graph, v) {
		if type_is_carrier(c, result_type) {
			return actuals[0]
		}
		return prov_value_content(graph, actuals[0], result_type, v.span)
	}
	// A result that is not itself a borrow can still hold one, and its summary is
	// about the same dependency either way (step 6: reading a container value out
	// yields what that value borrows).
	if !type_is_carrier(c, result_type) && !type_carries_borrow(c, result_type).any {
		return nil
	}
	callee := call_contract_declaration(c, v)
	direct := prov_has_direct_body(c, callee)
	prov_note_summary_dependency(graph, callee, direct)
	out: []int
	if summary, found := result_summary(c, callee); found {
		// Sibling fields may alias the same synthesized root. Keep that root
		// shared even though each path has its own dependencies and capability.
		synthetic := make(map[Root_Kind]Root_Id, graph.alloc)
		if summary.content_type == result_type && len(summary.content) > 0 {
			content := prov_temp_content(graph, result_type)
			for slot in content {
				sources: []int
				for path in summary.content {
					if paths_overlap(graph.prov_slots[slot].path, path.path.steps) {
						leaf_type := path.path.truncated ? result_type : path.path.type
						sources = prov_join(graph, sources, prov_substitute_result(graph, v, actuals, path.dependencies, leaf_type, &synthetic))
					}
				}
				prov_define_one_content(graph, slot, sources, v.span)
			}
			return content
		}
		out = prov_substitute_result(graph, v, actuals, summary.dependencies, result_type, &synthetic)
	} else if direct {
		// No summary yet is a forward fixed-point edge, not erased metadata.
		return nil
	} else {
		// Without a mapping every escaping argument can reach every result path.
		out = prov_escaping_actuals(graph, v, actuals)
		if len(out) == 0 && len(borrowed) == 0 {
			out = prov_synthetic_borrow(graph, v, .Unknown, result_type)
		}
	}
	return type_is_carrier(c, result_type) ? out : prov_value_content(graph, out, result_type, v.span)
}


// Whether this call's receiver is a `shared(T)` or `weak(T)` handle. Only the
// receiver is asked about: what the language promises is about the handle a
// borrow was taken from, not about the method that took it.
@(private = "file")
prov_receiver_is_shared_handle :: proc(graph: ^Flow_Graph, v: ^Expr_Call) -> bool {
	sym := symbol_of(graph.k.c, v.resolution.chosen_overload)
	if sym == nil || !sym.has_receiver {
		return false
	}
	return type_is_shared_handle(graph.k.c, sym.owner_type)
}

// Substitute one result path's parameter dependencies. Parameter paths are
// matched against the actual value's shape, never against its slot count.
@(private = "file")
prov_substitute_result :: proc(
	graph: ^Flow_Graph,
	v: ^Expr_Call,
	actuals: [][]int,
	dependencies: Result_Dependencies,
	type: Type_Id,
	synthetic: ^map[Root_Kind]Root_Id,
) -> []int {
	out: []int
	for wanted, index in dependencies.params {
		if !wanted || index >= len(actuals) {
			continue
		}
		paths := index < len(dependencies.param_paths) ? dependencies.param_paths[index] : nil
		param_type := prov_parameter_type(graph, v, index)
		shape := carrier_shape(graph.k.c, param_type)
		if len(paths) == 0 || len(paths) != len(shape) {
			out = prov_join(graph, out, actuals[index])
			continue
		}
		for named, position in paths {
			if named {
				out = prov_join(graph, out, prov_select_content(graph, actuals[index], param_type, shape[position].steps))
			}
		}
	}
	kinds := [4]Root_Kind{.Static, .Thread_Local, .Allocation, .Unknown}
	wanted := [4]bool{dependencies.static, dependencies.thread, dependencies.fresh, dependencies.unknown || dependencies.local}
	for needed, index in wanted {
		if !needed {
			continue
		}
		kind := kinds[index]
		root, found := synthetic^[kind]
		if !found {
			root = prov_synthetic_root(graph, v, kind)
			synthetic^[kind] = root
		}
		if kind == .Allocation {
			region := prov_substitute_region(graph, v, dependencies.fresh_region)
			region_merge(&graph.roots[int(root)].region, region)
			append(&graph.allocation_region_sources, Prov_Allocation_Region_Source {
				root = root,
				call = v,
				summary = dependencies.fresh_region,
			})
		}
		out = prov_join(graph, out, prov_borrow(
			graph, root, nil, type_carries_borrow(graph.k.c, type).mutable,
			v.span, carrier_noun(graph.k.c, type),
		))
	}
	if dependencies.precision != {} && len(out) > 0 {
		slot := prov_temp_slot(graph)
		graph.prov_slots[slot].precision = dependencies.precision
		prov_define_one_content(graph, slot, out, v.span)
		return prov_one(graph, slot)
	}
	return out
}

@(private = "file")
prov_note_summary_dependency :: proc(graph: ^Flow_Graph, callee: Symbol_Id, direct: bool) {
	if graph.mode != .Prov_Summary || !direct || callee == INVALID_SYMBOL {
		return
	}
	for existing in graph.summary_callees {
		if existing == callee {
			return
		}
	}
	append(&graph.summary_callees, callee)
}

@(private = "file")
prov_synthetic_root :: proc(graph: ^Flow_Graph, v: ^Expr_Call, kind: Root_Kind) -> Root_Id {
	name: string
	#partial switch kind {
	case .Allocation:   name = "this allocation"
	case .Static:       name = "static storage"
	case .Thread_Local: name = "`thread_local` storage"
	case:               name = "unknown storage"
	}
	return prov_new_root(graph, kind, v.span, name)
}

@(private = "file")
prov_synthetic_borrow :: proc(graph: ^Flow_Graph, v: ^Expr_Call, kind: Root_Kind, type: Type_Id) -> []int {
	root := prov_synthetic_root(graph, v, kind)
	return prov_borrow(
		graph,
		root,
		nil,
		carrier_is_mutable(graph.k.c, type),
		v.span,
		carrier_noun(graph.k.c, type),
	)
}

// Whether the callee's result reaches this parameter only through what the
// parameter carries -- a view it holds -- rather than through its own storage.
// A summary narrowed to carrier paths says exactly that: `merge_param_paths`
// widens the entry to the whole parameter as soon as one loan names the
// parameter's own storage, so a surviving narrowing cannot hide one.
@(private = "file")
prov_result_reads_through_receiver :: proc(c: ^Compiler, v: ^Expr_Call, index: int) -> bool {
	// A mutable yield is an exclusive loan: it ends before the receiver is
	// advanced or dropped, so it keeps naming the receiver however it was
	// derived (design.md "By-reference iteration"). Only a read-only result may
	// outlive the call that produced it.
	if type_carries_borrow(c, v.type).mutable {
		return false
	}
	summary, found := result_summary(c, call_contract_declaration(c, v))
	if !found || index >= len(summary.param_paths) {
		return false
	}
	for named in summary.param_paths[index] {
		if named {
			return true
		}
	}
	return false
}

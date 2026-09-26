// Provenance event vocabulary and construction for the disposable flow graph.
// cfg.odin owns traversal, control-flow topology, and lifecycle events;
// borrow.odin solves the root and region facts recorded here.
package lokec

import "core:fmt"
import "core:slice"

// ------------------------------------------------------ provenance events --

// Kept apart from cfg.odin's lifecycle events: the analyses share block topology,
// not the facts they record.
Prov_Kind :: enum u8 {
	// A carrier slot receives its source slots plus one fresh loan.
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
	// A value written through a carrier (`p^.view = values`, or an argument the
	// callee may keep). The destination resolves while solving, and joins because
	// the carrier may name more than one root.
	Publish,
	// A value read through a carrier; its content slots resolve while solving.
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
	// `Retain`: the destination's storage kind; `verb` names it.
	retain: Retain_Kind,
	// `Retain`/`Publish`: the carrier a destination was written through, whose
	// loans the solver resolves to roots. `Load`: the addressing carriers, with
	// `path` below their pointees and `slot` the content.
	into: []int,
	// `Escape`: the allocator region an owning result carries with it.
	region:         Region_Set,
	region_content: []Prov_Region_Content,
	// `Reset`: whether its promise is written. `access` is `Invalidate` for a
	// direct `free_all`, `Write` for handing an allocator onward.
	reset_covered: bool,
	owner_span:    Span,
	// `Reset`: the written operation ending a provider, such as "dropping `a`".
	ends:          string,
	// `Live`: re-establishes its loans. A loop head re-reads its iterable, so a
	// body invalidation must not cross the back edge.
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

// Resolved once while walking and again once the flow-insensitive region map
// has seen every assignment, so a loop's back-edge reassignment widens it.
Prov_Allocation_Region_Source :: struct {
	root:    Root_Id,
	value:   Expr,
	call:    ^Expr_Call,
	summary: Region_Set,
}

// A path-indexed region fact, kept even where the field has no carrier shape
// (for example `[dynamic]int`).
Prov_Region_Content :: struct {
	path:   []Proj_Step,
	region: Region_Set,
}

// The payload under a union's wildcard alternative: unwrapping keeps every borrow
// the wrapper carried. An `any_view` reads through its data pointer instead.
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

// A case binding holds the subject's content, or one variant's payload.
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

// The loan a binding that views another place holds. A lending binding's
// `&binding` names the source rather than the binding's frame slot; one whose
// loans end with its step names both.
@(private)
prov_bind_view :: proc(graph: ^Flow_Graph, id: Symbol_Id, loans: []int, lends := true) {
	if id == INVALID_SYMBOL || len(loans) == 0 {
		return
	}
	graph.view_loans[id] = loans
	if !lends {
		graph.step_views[id] = true
	}
}

// What a view binding's root stands for: every access through it, and every
// borrow of it, also uses the source it views (design.md "Borrowing iteration").
@(private)
prov_root_view :: proc(graph: ^Flow_Graph, root: Root_Id) -> []int {
	if root == NO_ROOT {
		return nil
	}
	symbol := graph.roots[int(root)].symbol
	if symbol == INVALID_SYMBOL {
		return nil
	}
	return graph.view_loans[symbol]
}

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

// A case binding inherits its subject's region.
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

// Pure graph construction for the lattices in `src/borrow.odin`: allocates in
// the graph's arena and reads the typed AST, but never writes it or reports.

@(private)
prov_emit :: proc(graph: ^Flow_Graph, event: Prov_Event) {
	if graph.current == NO_BLOCK {
		return // unreachable code borrows nothing observable
	}
	if event.kind == .Reset || event.kind == .Region_Escape {
		graph.has_region_event = true
	}
	// An owner backed by an allocator region needs the solver even with no loan.
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

// design.md "or_return operator": only the final status is removed, so the
// operand's per-result provenance applies unchanged.
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

// The allocator region of one projected result field, without joining siblings.
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
		return prov_region_content_at(graph, root, prov_concat_path(graph, base, path))
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

// Returning a region provider transfers its parent dependency, not its local
// token; the caller makes a fresh token for the returned owner.
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

// Static, thread-local, or file-scope storage: it outlives every procedure body.
@(private)
symbol_outlives_bodies :: proc(sym: ^Symbol) -> bool {
	return sym.duration != .None || (sym.decl != nil && sym.decl.top_level)
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
		// design.md "Storage modifiers": `thread_local` ends with its thread.
		switch {
		case sym.duration == .Thread_Local:
			kind = .Thread_Local
		case symbol_outlives_bodies(sym):
			kind = .Static
		}
	case .Parameter:
		// A pointer-mode parameter aliases the caller's root (design.md "Receiver
		// forms"), which lets `proc(self) -> []T` return a slice of it. A
		// `value: T` is a value: nothing borrowed from it outlives the call.
		if param_mode_is_pointer(sym.mode) {
			kind = .Param
		}
	case .Const:
		// design.md "Materialization": one read-only object for the program.
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

// A carrier variable's slot. A static-duration carrier gets none: design.md lists
// a view stored in a global as unchecked.
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
		return 0, false // a borrow inside it is a content slot instead
	}
	if sym.kind != .Var && sym.kind != .Parameter {
		return 0, false
	}
	if symbol_outlives_bodies(sym) {
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

// Each literal element's borrows go to its own place; an element whose slot
// can't be resolved joins into every path.
@(private)
prov_composite_content :: proc(graph: ^Flow_Graph, v: ^Expr_Composite, content: []int) -> []int {
	value_type := v.type
	is_array := underlying_kind(graph.k.c, value_type) == .Array
	per_element := make([][]int, len(v.elements), graph.alloc)
	steps := make([]Proj_Step, len(v.elements), graph.alloc)
	known := make([]bool, len(v.elements), graph.alloc)
	joined: []int
	is_map := underlying_kind(graph.k.c, value_type) == .Map
	for element, index in v.elements {
		if is_map {
			walk_flow_expr(graph, element.key)
		}
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

// Which slot one literal element fills. Array elements and fields use different
// step kinds, which must never be compared with each other.
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

// design.md "Unions": a variant's payload sits under the wildcard alternative.
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

// A value that is not itself a borrow can still hold one. Every place
// `carrier_shape` names gets its own slot, so a field read does not inherit
// what a sibling borrows.
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
	external_duration := symbol_outlives_bodies(sym)
	unknown_root := NO_ROOT
	if external_duration {
		// Another body may have filled this storage, so it starts as unknown.
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

// The content slots whose shape path overlaps the place's projection.
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

// Content slots for an unnamed value, ordered by its carrier shape.
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

// Sources describing this shape are selected by path; others reach every path.
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

// A read's slots are relative to the value read, so a later projection can
// select its own fields.
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

// Without a field mapping, every result path gets every source.
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

// Consuming a value: read what it held, then end the source's own storage. The
// borrows inside it are of other roots and survive (design.md).
@(private)
prov_consume :: proc(graph: ^Flow_Graph, place: Expr, span: Span, verb: string) -> []int {
	source := place
	if moved, is_move := place.(^Expr_Move); is_move {
		provider_move_end(graph, moved)
		source = moved.value
	}
	consumed: []int
	if root, path, ok := prov_place_of(graph, source); ok {
		consumed = prov_content_at(graph, root, path)
	}
	// A bare carrier holds its loans in its own slot rather than as content, and
	// they move with it.
	if ident, is_ident := source.(^Expr_Ident); is_ident && len(consumed) == 0 {
		if slot, is_carrier := prov_slot_for_symbol(graph, ident.symbol); is_carrier {
			consumed = prov_one(graph, slot)
			prov_emit(graph, Prov_Event{kind = .Live, sources = consumed, span = span})
		}
	} else if is_ident && prov_drop_reads(graph, ident.symbol) {
		// The destination takes the borrows, and the local gives them up, or the
		// drop its scope exit still reaches would keep them in use.
		sym := symbol_of(graph.k.c, ident.symbol)
		consumed = prov_project_content(graph, consumed, sym.type, nil, sym.type, span)
		prov_clear_content(graph, ident.symbol, span)
	}
	prov_invalidate(graph, source, span, verb)
	return consumed
}

// design.md "Owners and `drop`": dropping a local runs its `drop` hooks, which
// may read what it borrows, so the drop uses those borrows. A container's own
// drop reads none, so a local without a hand-written hook is not asked.
@(private)
prov_drop_reads :: proc(graph: ^Flow_Graph, id: Symbol_Id) -> bool {
	sym := symbol_of(graph.k.c, id)
	return sym != nil && type_drop_runs_hook(graph.k.c, sym.type) && len(prov_content_slots(graph, id)) > 0
}

@(private)
prov_drop_use :: proc(graph: ^Flow_Graph, id: Symbol_Id, span: Span, at_scope_exit := false) {
	if !prov_drop_reads(graph, id) {
		return
	}
	prov_emit(graph, Prov_Event{kind = .Live, sources = prov_content_slots(graph, id), span = span})
	if at_scope_exit {
		if graph.scope_drops == nil {
			graph.scope_drops = make(map[Span]bool, 4, graph.alloc)
		}
		graph.scope_drops[span] = true
	}
}

// A dropped or moved-out local holds no borrows until it is assigned again.
@(private)
prov_clear_content :: proc(graph: ^Flow_Graph, id: Symbol_Id, span: Span) {
	for slot in prov_content_slots(graph, id) {
		prov_define_one_content(graph, slot, nil, span)
	}
}

// Binds loans to a name no declaration defines: a `foreach` element or a case
// binding.
@(private)
prov_bind_value :: proc(graph: ^Flow_Graph, id: Symbol_Id, sources: []int, span: Span) {
	if id == INVALID_SYMBOL {
		return
	}
	if slot, is_carrier := prov_slot_for_symbol(graph, id); is_carrier {
		sym := symbol_of(graph.k.c, id)
		if sym != nil {
			prov_reborrow(graph, sources, sym.type, slot, span)
		}
		prov_emit(graph, Prov_Event{kind = .Def, slot = slot, loan = NO_LOAN, sources = sources, span = span})
		return
	}
	if content := prov_content_slots(graph, id); len(content) > 0 {
		prov_define_content(graph, content, sources, span)
	}
}

// Publishes content into another value's slots by matching paths.
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
	indistinct := path_is_indistinct(written)
	for slot in into {
		entry := graph.prov_slots[slot]
		type := value_type
		if type == INVALID_TYPE && len(written) == 0 {
			type = entry.content_shape
		}
		path := entry.path[min(len(written), len(entry.path)):]
		sources := prov_select_content(graph, from, type, path)
		// A path standing for many places (container elements, union alternatives)
		// joins, as does a fallible write; a known whole-path write replaces.
		partial_truncated_write := entry.content_truncated && len(written) > len(entry.path)
		whole_replacement := !indistinct && path_has_exact_prefix(entry.path, written)
		if preserve_previous || (!whole_replacement &&
		   (indistinct || path_is_indistinct(entry.path) || partial_truncated_write)) {
			sources = prov_join(graph, prov_one(graph, slot), sources)
		}
		prov_define_one_content(graph, slot, sources, span, path_precision(written))
	}
}

@(private = "file")
path_is_indistinct :: proc(path: []Proj_Step) -> bool {
	for step in path {
		if step.kind == .Wild {
			return true
		}
	}
	return false
}

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

// A mutable borrow published into a read-only field weakens as at a local.
@(private = "file")
prov_define_one_content :: proc(graph: ^Flow_Graph, slot: int, sources: []int, span: Span, precision: Precision_Loss = {}) {
	prov_reborrow(graph, sources, graph.prov_slots[slot].content_type, slot, span)
	prov_emit(graph, Prov_Event{kind = .Def, slot = slot, loan = NO_LOAN, sources = sources, span = span, precision = precision})
}

@(private = "file")
prov_temp_slot :: proc(graph: ^Flow_Graph) -> int {
	append(&graph.prov_slots, empty_prov_slot(INVALID_SYMBOL))
	return len(graph.prov_slots) - 1
}

// A carrier stored into `into` from `slots` (design.md "Weakening and
// reborrows"). A fresh mutable loan weakens to a read-only destination, which
// settles both the loan and its access. An existing mutable carrier is instead
// reborrowed, read-only or mutably, and suspended while `into` is live. `into`
// is -1 for a call argument, whose reborrow cannot outlive the call.
@(private = "file")
prov_reborrow :: proc(graph: ^Flow_Graph, slots: []int, destination: Type_Id, into := -1, span := Span{}) {
	if !type_is_carrier(graph.k.c, destination) {
		return
	}
	weakens := !carrier_is_mutable(graph.k.c, destination)
	for slot in slots {
		entry := graph.prov_slots[slot]
		if entry.fresh_loan != NO_LOAN {
			if weakens {
				graph.loans[int(entry.fresh_loan)].mutable = false
				if entry.fresh_access_index >= 0 {
					graph.blocks[entry.fresh_access_block].prov[entry.fresh_access_index].access = .Read
				}
			}
			continue
		}
		// Storing a carrier into itself, as `xs = xs[1:]`, suspends nothing. A
		// traversal's reborrow passes on to what is taken from its elements.
		if into < 0 || into == slot ||
		   !(prov_slot_is_mutable_carrier(graph, slot) || prov_slot_is_reborrow(graph, slot)) {
			continue
		}
		append(&graph.reborrows, Prov_Reborrow{source = slot, derived = into, span = span, mutable = !weakens})
	}
}

// A traversal of a mutable carrier reborrows it for as long as the traversal,
// or anything taken from an element, is used: the carrier is suspended, as a
// local source is by its loop loan.
@(private)
prov_reborrow_traversal :: proc(graph: ^Flow_Graph, sources: []int, span: Span, mutable: bool) -> []int {
	out := make([dynamic]int, 0, len(sources), graph.alloc)
	for slot in sources {
		if !prov_slot_is_mutable_carrier(graph, slot) {
			append(&out, slot)
			continue
		}
		derived := prov_temp_slot(graph)
		prov_emit(graph, Prov_Event{kind = .Def, slot = derived, loan = NO_LOAN, sources = prov_one(graph, slot), span = span})
		append(&graph.reborrows, Prov_Reborrow{source = slot, derived = derived, span = span, mutable = mutable})
		append(&out, derived)
	}
	return out[:]
}

// A traversal's unnamed reborrow of a carrier.
@(private = "file")
prov_slot_is_reborrow :: proc(graph: ^Flow_Graph, slot: int) -> bool {
	if graph.prov_slots[slot].symbol != INVALID_SYMBOL {
		return false
	}
	for reborrow in graph.reborrows {
		if reborrow.derived == slot {
			return true
		}
	}
	return false
}

// A named slot, or a field of one, holding a mutable view (`^mut T`, `[]mut T`,
// `dyn mut I`); a temporary is left alone. A region provider is not one: copies
// of an allocator share it by design.
@(private = "file")
prov_slot_is_mutable_carrier :: proc(graph: ^Flow_Graph, slot: int) -> bool {
	entry := graph.prov_slots[slot]
	type := entry.content_type
	if type == INVALID_TYPE {
		sym := symbol_of(graph.k.c, entry.symbol)
		if sym == nil {
			return false
		}
		type = sym.type
	}
	c := graph.k.c
	return entry.symbol != INVALID_SYMBOL && !type_is_region_provider(c, type) && carrier_is_mutable(c, type)
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
	if mutable {
		prov_note_static_write(graph, root)
	}
	append(&graph.loans, Prov_Loan{root = root, path = path, mutable = mutable, span = span, what = what})
	return Loan_Id(len(graph.loans) - 1)
}

// A fresh borrow in a temporary slot; its consumer decides how long it lives.
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
	return prov_join(graph, prov_one(graph, slot), prov_root_view(graph, root))
}

// Returns where the event landed so weakening can revise it; `index` is -1 when
// nothing was emitted.
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
	if kind != .Read {
		prov_note_static_write(graph, root)
	}
	if viewed := prov_root_view(graph, root); len(viewed) > 0 {
		prov_emit(graph, Prov_Event{kind = .Live, sources = viewed, span = span})
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

// design.md: a borrowed parameter starts with one loan of the caller's root.
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
			if type_underlying(graph.k.c, sym.type) == TYPE_ALLOCATOR {
				set := prov_empty_region(graph)
				set.params[index] = true
				graph.region_of[id] = set
			}
			slot, is_carrier := prov_slot_for_symbol(graph, id)
			// An aggregate parameter gets one loan per shape path.
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

// Erasing into an `any_view` keeps the source root with a read-only loan
// (design.md).
@(private)
prov_erase :: proc(graph: ^Flow_Graph, e: Expr) -> []int {
	span := expr_span(e)
	// Also a use of what a carrier already refers to, so erasure cannot hide
	// a stale view.
	loans := walk_flow_expr_erased(graph, e)
	if root, path, ok := prov_place_of(graph, e); ok {
		return prov_join(graph, loans, prov_borrow(graph, root, path, false, span, "view"))
	}
	// A managed temporary is dropped when its statement ends (design.md
	// "Temporaries and procedure boundaries"), so the view ends there too.
	if base := expr_base(e); !base.is_const && type_is_managed(graph.k.c, base.erased_from) {
		return prov_join(graph, loans, prov_borrow(graph, prov_temp_root(graph, span), nil, false, span, "view"))
	}
	if len(loans) > 0 {
		return loans
	}
	// Other hidden storage is a frame slot that follows the lexical scope.
	return prov_borrow(graph, prov_hidden_root(graph, span, "this erased value"), nil, false, span, "view")
}

// design.md "string type conversions" and "Dynamic arrays": a `string` read as
// a `string_view`, or a `[dynamic]T` as a `[]T`, borrows the owner it came
// from, or the temporary that holds it. A constant's storage is static.
@(private)
prov_owner_view :: proc(graph: ^Flow_Graph, e: Expr) -> []int {
	base := expr_base(e)
	saved, saved_type := base.view_from, base.type
	base.view_from, base.type = INVALID_TYPE, saved
	defer base.view_from, base.type = saved, saved_type
	noun := underlying_kind(graph.k.c, saved_type) == .Slice ? "slice" : "string view"
	span := expr_span(e)
	if root, path, ok := prov_place_of(graph, e); ok {
		loans := walk_flow_expr(graph, e)
		if base.is_const {
			return loans
		}
		return prov_join(graph, loans, prov_borrow(graph, root, path, false, span, noun))
	}
	// Reached through a pointer or view: the view borrows what that names.
	if carriers, _, through := prov_read_through_carrier(graph, e); through {
		return carriers
	}
	loans := walk_flow_expr(graph, e)
	if base.is_const || len(loans) > 0 || !prov_expr_is_temporary(e) {
		return loans
	}
	return prov_borrow(graph, prov_temp_root(graph, span), nil, false, span, noun)
}

// A compiler-created root ending with its scope.
@(private = "file")
prov_hidden_root :: proc(graph: ^Flow_Graph, span: Span, name: string) -> Root_Id {
	root := prov_new_root(graph, .Temporary, span, name)
	append(&graph.in_scope, Flow_Cleanup{kind = .Prov_Root, root = root, span = span})
	return root
}

// The ordinary walk with the erasure hook suppressed.
@(private = "file")
walk_flow_expr_erased :: proc(graph: ^Flow_Graph, e: Expr) -> []int {
	base := expr_base(e)
	saved, saved_type := base.erased_from, base.type
	base.erased_from, base.type = INVALID_TYPE, saved
	defer { base.erased_from, base.type = saved, saved_type }
	return walk_flow_expr(graph, e)
}

// ------------------------------------------------------------- regions --

@(private)
prov_empty_region :: proc(graph: ^Flow_Graph) -> Region_Set {
	return Region_Set{params = make([]bool, max(graph.param_count, 1), graph.alloc)}
}

// Every region dependency of a symbol, including its field facts.
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

// The region dependencies at one path; a whole-value fact reaches every path.
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

// Records a managed value stored at a path. Flow-insensitive, so writes merge.
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

// The token for one local provider. Past 64 providers the set is `crowded`,
// meaning "may be any of them".
@(private)
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

// Ending a provider reads its control block, which a fixed arena keeps in the
// caller's buffer, so the buffer stays borrowed until then — and with it, until
// every owner the region backs is gone, since those must end first.
@(private)
prov_provider_use :: proc(graph: ^Flow_Graph, id: Symbol_Id, span: Span) {
	sources := make([dynamic]int, 0, 1, graph.alloc)
	if slot, is_carrier := prov_slot_for_symbol(graph, id); is_carrier {
		append(&sources, slot)
	}
	for slot in prov_content_slots(graph, id) {
		if type_is_region_provider(graph.k.c, graph.prov_slots[slot].content_type) {
			append(&sources, slot)
		}
	}
	if len(sources) > 0 {
		prov_emit(graph, Prov_Event{kind = .Live, sources = sources[:], span = span})
	}
}

// The provider tokens a value moved out of locals carries, through composite
// literals and `exchange`, or 0.
@(private = "file")
prov_moved_bits :: proc(graph: ^Flow_Graph, e: Expr) -> u64 {
	source: Expr
	#partial switch v in e {
	case ^Expr_Move:
		source = v.value
	case ^Expr_Call:
		if sym := symbol_of(graph.k.c, v.resolution.symbol); sym != nil && sym.builtin == .Exchange && len(v.bound) == 2 {
			source = v.bound[0]
		}
	case ^Expr_Composite:
		bits: u64
		for element in v.elements {
			if element.value != nil {
				bits |= prov_moved_bits(graph, element.value)
			}
		}
		return bits
	}
	if source != nil {
		if root, _, ok := prov_place_of(graph, source); ok && graph.roots[int(root)].kind == .Local {
			return graph.provider_bits[graph.roots[int(root)].symbol]
		}
	}
	return 0
}

// A provider moved into a local's existing storage joins that local's tokens.
@(private)
prov_merge_moved_bits :: proc(graph: ^Flow_Graph, root: Symbol_Id, value: Expr) {
	bits := prov_moved_bits(graph, value)
	if bits == 0 {
		return
	}
	existing := prov_provider_region(graph, root)
	if existing.crowded {
		return // already "may be any of them"
	}
	graph.provider_bits[root] = existing.locals | bits
	if set, found := graph.region_of[root]; found && type_is_region_provider(graph.k.c, symbol_of(graph.k.c, root).type) {
		set.locals |= bits
		graph.region_of[root] = set
	}
}

// The name of the one local region a set names, or "".
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

// A `leaf` type, or an `Option`/`Result`-style union around one: the wrapper
// carries what its payload carries (design.md "Allocators").
@(private = "file")
prov_type_or_wrapped :: proc(
	c: ^Compiler,
	type: Type_Id,
	leaf: proc(c: ^Compiler, type: Type_Id) -> bool,
	depth := 0,
) -> bool {
	if type == INVALID_TYPE || depth > 8 {
		return false
	}
	if leaf(c, type) {
		return true
	}
	info := underlying_info(c, type)
	if info == nil || info.kind != .Union {
		return false
	}
	for payload in info.variants {
		if payload != TYPE_VOID && prov_type_or_wrapped(c, payload, leaf, depth + 1) {
			return true
		}
	}
	return false
}

@(private = "file")
prov_carries_allocator :: proc(c: ^Compiler, type: Type_Id) -> bool {
	return prov_type_or_wrapped(c, type, proc(c: ^Compiler, type: Type_Id) -> bool {
		return type_underlying(c, type) == TYPE_ALLOCATOR
	})
}

@(private = "file")
prov_region_of :: proc(graph: ^Flow_Graph, e: Expr) -> Region_Set {
	c := graph.k.c
	// design.md "Allocators": a nil `Allocator` is the default provider.
	if base := expr_base(e); base != nil && base.is_const && base.const_value.kind == .Nil &&
	   type_underlying(c, base.type) == TYPE_ALLOCATOR {
		set := prov_empty_region(graph)
		set.default = true
		return set
	}
	#partial switch v in e {
	case ^Expr_Ident:
		// A provider as a value is backed by its parent; the region it provides is
		// reached through its handle.
		if type_is_region_provider(c, expr_base(e).type) {
			return graph.provider_parents[v.symbol] or_else Region_Set{}
		}
		return prov_region_for_symbol(graph, v.symbol)
	case ^Expr_Move:
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
		if v.op == .Or_Return {
			return prov_region_of(graph, v.operand)
		}
	case ^Expr_Composite:
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
		// `arena.allocator()` names the provider's own region.
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

// The region an `arena.allocator()` names; unknown unless the receiver is a
// named provider.
@(private = "file")
prov_handle_region :: proc(graph: ^Flow_Graph, v: ^Expr_Call) -> (Region_Set, bool) {
	if call_provider_op(graph.k.c, v) != .Handle || len(v.bound) == 0 {
		return Region_Set{}, false
	}
	ident, is_ident := v.bound[0].(^Expr_Ident)
	if !is_ident {
		// A provider inside a local record or container: one token for that local.
		if root, _, ok := prov_place_of(graph, v.bound[0]); ok {
			if descriptor := graph.roots[int(root)]; descriptor.kind == .Local && descriptor.symbol != INVALID_SYMBOL {
				return prov_provider_region(graph, descriptor.symbol), true
			}
		}
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

// The region of a call result: a direct summary substituted by position, or for
// an indirect call every moved-owner and allocator argument region.
@(private = "file")
prov_call_region :: proc(graph: ^Flow_Graph, v: ^Expr_Call, result_type: Type_Id) -> Region_Set {
	c := graph.k.c
	out := prov_empty_region(graph)
	allocator_result := prov_carries_allocator(c, result_type)
	// A diverging call's value is never produced, so it is in no region.
	if (!type_is_managed(c, result_type) && !allocator_result) || call_diverges(c, v) {
		return out
	}
	if _, construction := v.operation.(Call_Union_Construct); construction {
		for argument in v.bound {
			if argument != nil {
				region_merge(&out, prov_region_of(graph, argument))
			}
		}
		return out
	}
	// design.md "string type conversions": these copy into the default allocator.
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
	// Also here, because a stored call result is consulted before `prov_region_of`.
	if set, ok := prov_handle_region(graph, v); ok {
		return set
	}
	// A fixed arena has no region parent; its buffer is an ordinary loan.
	if call_provider_op(c, v) == .Open_Fixed {
		return out
	}
	callee := call_contract_declaration(c, v)
	direct := prov_has_direct_body(c, callee)
	prov_note_summary_dependency(graph, callee, direct)
	if summary, found := result_summary(c, callee); found {
		region_merge(&out, prov_substitute_region(graph, v, summary.region))
	}
	info := underlying_info(c, call_proc_type(c, v))
	for argument, index in v.bound {
		if argument == nil {
			continue
		}
		if type_underlying(c, expr_base(argument).type) == TYPE_ALLOCATOR && (!allocator_result || !direct) {
			// An owner built with an allocator argument takes its region; a returned
			// handle's summary already names one.
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
	out.default ||= summary.default
	out.unknown ||= summary.unknown
	// Summary-local regions are reported in their own body, not substituted.
	return out
}

// Re-resolves allocation regions once the whole body has filled the allocator
// map, so allocations in loops stay conservative across back edges.
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

// Each summarized result field's region at the call site, or nil to use the
// whole-result region.
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

// Whether every allocator parameter the set names carries the reset promise,
// or the name of one that does not.
@(private = "file")
prov_reset_promise :: proc(graph: ^Flow_Graph, set: Region_Set) -> (covered: bool, name: string) {
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

// A reset may end every allocation in its region (design.md): checked for its
// promise and for live owners it would strand.
@(private)
prov_reset :: proc(
	graph: ^Flow_Graph,
	set: Region_Set,
	span: Span,
	direct: bool,
	at: ^Expr_Call,
	cleanup_dead: []Symbol_Id = nil,
	ends := "",
	ending := INVALID_SYMBOL,
) {
	// A region the analysis cannot name, such as an allocator in a received
	// record's field, is pre-existing: it stays uncovered.
	covered, unmarked := prov_reset_promise(graph, set)
	// A locally created region needs no promise (design.md).
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
		ends          = ends,
	}
	// A live owner in an overlapping region blocks the reset, since its cleanup
	// still runs. Liveness is lifecycle's answer, recorded one pass earlier; a
	// dropped owner no longer blocks (design.md).
	dead := at == nil ? cleanup_dead : graph.k.c.reset_dead[at]
	for id in graph.owners_in_scope {
		owner := symbol_of(graph.k.c, id)
		if owner == nil {
			continue
		}
		// The local being ended is what ends the region, not a dependant of it.
		if slice.contains(dead, id) || id == ending {
			continue
		}
		if type_is_region_provider(graph.k.c, owner.type) {
			// A live child provider depends on its parent's region.
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

// A borrow stored where it outlives the statement, resolved as a place so fields,
// elements, and writes through an alias are all seen.
@(private = "file")
prov_retain_escape :: proc(graph: ^Flow_Graph, target: Expr, sources: []int, span: Span) {
	if len(sources) == 0 {
		return
	}
	root, _, ok := prov_place_of(graph, target)
	if !ok {
		// Reached through a carrier: the solver resolves the root.
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

// The slots of the carrier a destination is written through (`p^.view`,
// `d[0].view`), or nil when the chain stays in lexical storage.
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
			return prov_retain_through_carrier(graph, v.operand)
		}
		return prov_carrier_slots(graph, v.operand)
	}
	return nil
}

// The slots holding a carrier value, without reading it.
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
	// An implicit copy of a place never allocates (design.md "Value semantics and
	// the ownership rule"), so only a move, a call result, or a literal carries a
	// region in.
	if type_is_managed(graph.k.c, expr_base(value).type) && expression_is_borrowed_place(value) {
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

// The carrier where a place leaves lexical storage and the projection below it,
// so `p^.left` does not make `right` live.
@(private)
prov_read_through_carrier :: proc(graph: ^Flow_Graph, place: Expr) -> ([]int, []Proj_Step, bool) {
	#partial switch v in place {
	case ^Expr_Postfix:
		if v.op == .Caret {
			return walk_flow_expr(graph, v.operand), nil, true
		}
	case ^Expr_Call:
		// `field.get(value)` is `field.pointer(value)^`.
		if reflect, ok := v.operation.(Call_Reflect); ok && reflect.op == .Field_Get {
			return walk_flow_expr(graph, v.bound[0]), nil, true
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

// The root and projection a place names, or none when it goes through a carrier;
// that is a use of the carrier, not a competing access to a root.
@(private)
prov_place_of :: proc(graph: ^Flow_Graph, e: Expr) -> (Root_Id, []Proj_Step, bool) {
	c := graph.k.c
	#partial switch v in e {
	case ^Expr_Ident:
		root := prov_root_for_symbol(graph, v.symbol)
		return root, nil, root != NO_ROOT

	case ^Expr_Selector:
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
		// An element lives in its container's current allocation, so the container
		// is the root and relocation ends the borrow.
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

// Walks a place chain's index expressions; the place is one access, not one per
// link.
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
		// Assigning through a map place may insert its key; an existing equal key
		// stays, so the key dependency joins.
		prov_retain_escape(graph, v.operand, key_sources, v.span)
		root, path, ok := prov_place_of(graph, v.operand)
		if !ok {
			// Reached through a carrier: publish to what it may name.
			if through := prov_retain_through_carrier(graph, v.operand); len(through) > 0 {
				prov_reborrow(graph, key_sources, info.key)
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

// A constant key's own entry while slots remain, else the wildcard, which
// overlaps every keyed entry.
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
	// A carrier in static or thread storage reads as a borrow of that storage.
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
	return prov_borrow_place(graph, v.operand, v.mutable, v.span, "pointer")
}

// A borrow of `operand` as a place, for `&operand` and `return inout operand`.
prov_borrow_place :: proc(graph: ^Flow_Graph, operand: Expr, mutable: bool, span: Span, what: string) -> []int {
	// design.md "Capabilities and the one rule". A binding that views another
	// owner's storage is not its own root: the pointer names the source.
	if ident, is_ident := operand.(^Expr_Ident); is_ident {
		if loans, viewed := graph.view_loans[ident.symbol]; viewed && !graph.step_views[ident.symbol] {
			return loans
		}
	}
	root, path, ok := prov_place_of(graph, operand)
	if !ok {
		if carriers, _, through := prov_read_through_carrier(graph, operand); through {
			return carriers
		}
		loans := walk_flow_expr(graph, operand)
		if len(loans) > 0 || !prov_expr_is_temporary(operand) {
			return loans
		}
		// A borrow of a temporary cannot escape its expression (design.md).
		return prov_borrow(graph, prov_temp_root(graph, expr_span(operand)), nil, mutable, span, what)
	}
	prov_walk_subscripts(graph, operand)
	access_block, access_index := prov_access(graph, root, path, mutable ? .Write : .Read, span)
	return prov_borrow(graph, root, path, mutable, span, what, access_block, access_index)
}

@(private)
prov_slice :: proc(graph: ^Flow_Graph, v: ^Expr_Slice) -> []int {
	if len(v.bound) > 0 {
		// A selected `operator([:])` result borrows the receiver unless its result
		// type is owning (design.md).
		receiver_loans := walk_flow_expr(graph, v.bound[0])
		borrowed := receiver_loans
		for index in 1 ..< len(v.bound) {
			if v.bound[index] != nil {
				borrowed = prov_join(graph, borrowed, walk_flow_expr(graph, v.bound[index]))
			}
		}
		prov_operator_effects(graph, v.resolution, v.span, borrowed)
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
	// An array, string, or dynamic array is sliced out of its own root (design.md
	// "Dynamic arrays"); reslicing a carrier keeps its loans.
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
	// Storage reached through a pointer or view borrows what that carrier names,
	// as `&p.items` does.
	if array {
		if carriers, _, through := prov_read_through_carrier(graph, v.operand); through {
			if v.lo != nil { walk_flow_expr(graph, v.lo) }
			if v.hi != nil { walk_flow_expr(graph, v.hi) }
			return carriers
		}
	}
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
	// An unmanaged literal's hidden array follows the lexical scope (design.md);
	// a managed one such as `[dynamic]int{1, 2}[:]` ends with its statement.
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

// Iterating a place borrows it, mutably for a `ref` binding.
@(private)
prov_iterate :: proc(graph: ^Flow_Graph, s: ^Stmt_Foreach, iterated: []int) -> []int {
	iterable := s.iterable
	mutable := foreach_is_place_loop(s)
	// A mutable carrier is reborrowed by the traversal instead: the elements live
	// in what it views, not in the variable.
	if type := expr_base(iterable).type; carrier_is_mutable(graph.k.c, type) && !type_is_region_provider(graph.k.c, type) {
		return iterated
	}
	root, path, ok := prov_place_of(graph, iterable)
	if !ok {
		return iterated
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

// A field or element of a temporary is part of it, so `build().items[:]` ends
// with its statement.
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
		prov_reborrow(graph, sources, sym.type, slot, sym.span)
		prov_emit(graph, Prov_Event {
			kind    = .Def,
			slot    = slot,
			loan    = NO_LOAN,
			sources = sources,
			span    = sym.span,
		})
	}
}

// An allocator binding takes its initializer's region; a managed owner takes
// its constructing call's.
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
	// A provider moved in keeps its region, and so its token.
	if initializer != nil && sym.duration == .None && projected < 0 {
		if _, found := graph.provider_bits[id]; !found {
			if bits := prov_moved_bits(graph, initializer); bits != 0 {
				graph.provider_bits[id] = bits
			}
		}
	}
	// design.md: a local `mem.Arena`/`mem.Scratch` is a region of its own.
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
	// An explicit `via` allocator decides the region (design.md).
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
	// Every lexical owner registers for reset checks (design.md); its region may
	// be learned from a later assignment.
	if sym.duration == .None {
		append(&graph.owners_in_scope, id)
	}
}

// A destructured binding takes only its own field's sources.
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
		if s.op == .Assign {
			// The old value ends first; a provider moved in then joins the local.
			if ident, is_ident := target.(^Expr_Ident); is_ident {
				provider_assign_end(graph, ident)
			} else {
				provider_field_assign_end(graph, target)
			}
			if root := provider_place_root(graph, target); root != INVALID_SYMBOL && value != nil {
				prov_merge_moved_bits(graph, root, value)
			}
		}
		if ident, is_ident := target.(^Expr_Ident); is_ident && s.op == .Assign {
			target_type := expr_base(target).type
			if value != nil && type_is_region_provider(graph.k.c, target_type) {
				// A provider's own region stays its token; the new value's parent joins
				// the parents it depends on.
				parent := graph.provider_parents[ident.symbol] or_else prov_empty_region(graph)
				region_merge(&parent, value_region)
				graph.provider_parents[ident.symbol] = parent
			} else if value != nil &&
			   (type_underlying(graph.k.c, target_type) == TYPE_ALLOCATOR || type_is_managed(graph.k.c, target_type)) {
				existing, found := graph.region_of[ident.symbol]
				if !found {
					existing = prov_empty_region(graph)
				}
				region_merge(&existing, value_region)
				graph.region_of[ident.symbol] = existing
			}
			prov_retain_escape(graph, target, sources, expr_span(target))
			// The old value is dropped here.
			prov_drop_use(graph, ident.symbol, expr_span(target))
			prov_invalidate(graph, target, expr_span(target), "assigned")
			if slot, is_carrier := prov_slot_for_symbol(graph, ident.symbol); is_carrier {
				prov_reborrow(graph, sources, expr_base(target).type, slot, expr_span(target))
				prov_emit(graph, Prov_Event {
					kind    = .Def,
					slot    = slot,
					loan    = NO_LOAN,
					sources = sources,
					span    = expr_span(target),
				})
			} else if content := prov_content_slots(graph, ident.symbol); len(content) > 0 {
				prov_define_content(graph, content, sources, expr_span(target))
			}
			continue
		}
		prov_retain_escape(graph, target, sources, expr_span(target))
		root, path, place_ok := prov_place_of(graph, target)
		if !place_ok && s.op == .Assign {
			if through := prov_retain_through_carrier(graph, target); len(through) > 0 {
				prov_walk_subscripts(graph, target, true)
				// design.md "Weakening and reborrows".
				if len(sources) > 0 {
					prov_reborrow(graph, sources, expr_base(target).type)
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
			if written := prov_content_at(graph, root, path); len(written) > 0 && s.op == .Assign {
				prov_define_content(graph, written, sources, expr_span(target), path, expr_base(target).type)
			}
			continue
		}
		walk_flow_expr(graph, target)
	}
}

// The procedure type a call goes through: the chosen overload's, or the callee
// value's for an indirect call, which is where `@(escape=...)` matters most.
@(private)
call_proc_type :: proc(c: ^Compiler, v: ^Expr_Call) -> Type_Id {
	if sym := symbol_of(c, v.resolution.chosen_overload); sym != nil {
		return sym.proc_type
	}
	if base := expr_base(v.callee); base != nil {
		return base.type
	}
	return INVALID_TYPE
}

// The loans of every argument not marked `@(escape=none)`.
@(private = "file")
prov_escaping_actuals :: proc(graph: ^Flow_Graph, v: ^Expr_Call, actuals: [][]int) -> []int {
	proc_type := call_proc_type(graph.k.c, v)
	out: []int
	for slots, index in actuals {
		if proc_param_escape(graph.k.c, proc_type, index) == .None {
			continue
		}
		out = prov_join(graph, out, slots)
	}
	return out
}

// Whether an argument names the caller's storage. A receiver answers with its
// declared mode: a provider handle takes a managed receiver by value.
@(private = "file")
prov_argument_borrows_caller :: proc(
	graph: ^Flow_Graph,
	v: ^Expr_Call,
	index: int,
	receiver: Param_Mode,
	has_receiver: bool,
) -> bool {
	if index == 0 && has_receiver {
		return receiver == .Borrow
	}
	c := graph.k.c
	return param_borrows_caller_storage(
		c,
		proc_parameter_mode(c, call_proc_type(graph.k.c, v), index),
		prov_parameter_type(graph, v, index),
	)
}

@(private = "file")
prov_parameter_type :: proc(graph: ^Flow_Graph, v: ^Expr_Call, index: int) -> Type_Id {
	info := underlying_info(graph.k.c, call_proc_type(graph.k.c, v))
	if info == nil || index >= len(info.parameters) {
		return INVALID_TYPE
	}
	return info.parameters[index]
}

@(private = "file")
prov_has_direct_body :: proc(c: ^Compiler, id: Symbol_Id) -> bool {
	if is_contract_join(c, id) {
		for member in symbol_of(c, id).members {
			if !prov_has_direct_body(c, member) {
				return false
			}
		}
		return true
	}
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
	info := underlying_info(graph.k.c, call_proc_type(graph.k.c, v))
	return info != nil && info.result_inout
}

@(private = "file")
prov_argument_is_inout :: proc(graph: ^Flow_Graph, v: ^Expr_Call, index: int) -> bool {
	info := underlying_info(graph.k.c, call_proc_type(graph.k.c, v))
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
			root := prov_new_root(graph, .Allocation, v.span, "this allocation")
			graph.roots[int(root)].symbol = INVALID_SYMBOL
			// design.md `new`: the root's region is the written allocator's, or
			// the default provider's.
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
			// design.md "What is not checked": the operands are only read.
			for bound in v.bound {
				walk_flow_expr(graph, bound)
			}
			return nil
		case .Free:
			if len(v.bound) >= 1 {
				sources := walk_flow_expr(graph, v.bound[0])
				for bound in v.bound[1:] {
					walk_flow_expr(graph, bound)
				}
				// design.md `free`: the allocator it releases through, the
				// default provider's unless one is written.
				region := prov_empty_region(graph)
				region.default = true
				if len(v.bound) > 1 {
					region = prov_region_of(graph, v.bound[1])
				}
				prov_emit(graph, Prov_Event{kind = .Free, sources = sources, span = v.span, region = region})
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
				provider_drop_end(graph, v)
				if ident, is_ident := v.bound[0].(^Expr_Ident); is_ident {
					prov_drop_use(graph, ident.symbol, v.span)
					prov_clear_content(graph, ident.symbol, v.span)
				}
				prov_invalidate(graph, v.bound[0], v.span, "dropped")
			}
			return nil
		case .Exchange:
			if len(v.bound) == 2 {
				provider_exchange_end(graph, v)
				prov_invalidate(graph, v.bound[0], v.span, "exchanged")
				walk_flow_expr(graph, v.bound[1])
			}
			return nil
		case .Atomic_Load, .Atomic_Store, .Atomic_Exchange, .Atomic_Compare_Exchange,
		     .Atomic_Add, .Atomic_Sub, .Atomic_And, .Atomic_Or, .Atomic_Xor, .Atomic_Fence:
			// An atomic returns the stored value, not a borrow of its address, or an
			// `Atomic(^T)` could never load.
			for argument in v.bound {
				if argument != nil {
					walk_flow_expr(graph, argument)
				}
			}
			return nil
		case .Unsafe_Take, .Unsafe_Write:
			if len(v.bound) >= 1 {
				prov_invalidate(graph, v.bound[0], v.span, sym.builtin == .Unsafe_Take ? "taken" : "overwritten")
				for bound in v.bound[1:] {
					walk_flow_expr(graph, bound)
				}
			}
			return nil
		case .Unsafe_Forget:
			if len(v.bound) == 1 {
				// A borrow of the forgotten value dies here, as at a `drop`.
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
	// The receiver is `bound[0]`; don't walk it again through the callee.
	if !(has_receiver && len(v.bound) > 0) {
		graph.callee_expr = v.callee
		walk_flow_expr(graph, v.callee)
	}
	if len(v.bound) == 0 {
		actuals := make([][]int, max(len(v.args), 1), graph.alloc)
		borrowed: []int
		for argument, index in v.args {
			actuals[index] = walk_flow_expr(graph, argument.value)
			borrowed = prov_join(graph, borrowed, actuals[index])
		}
		// The reset precedes the boundary use, so the actuals are live at it.
		prov_call_resets(graph, v)
		prov_call_effects(graph, v)
		if len(borrowed) > 0 {
			prov_emit(graph, Prov_Event{kind = .Live, sources = borrowed, span = v.span})
		}
		return prov_store_call_results(graph, v, actuals, borrowed)
	}
	actuals := make([][]int, len(v.bound), graph.alloc)
	borrowed: []int
	// Evaluation order, not parameter order: a named argument written first
	// borrows before a later one invalidates.
	for step in 0 ..< len(v.bound) {
		index := call_slot_at(v, step)
		argument := v.bound[index]
		// design.md "Variadic parameters": the pack slot holds no written
		// expression unless a sole spread is forwarded.
		if v.is_variadic && index == v.variadic_slot && !v.variadic_forwards {
			actuals[index] = walk_variadic_pack(graph, v)
			borrowed = prov_join(graph, borrowed, actuals[index])
			continue
		}
		if argument == nil {
			continue
		}
		if index == 0 && receiver == .Move {
			actuals[index] = prov_consume(graph, argument, expr_span(argument), "moved")
			borrowed = prov_join(graph, borrowed, actuals[index])
			continue
		}
		if index == 0 && receiver == .Inout {
			// An `inout` receiver invalidates borrows of it (design.md), and its held
			// borrows stay live through the call, as `iterator.next()` reads its slice.
			borrowed = prov_join(graph, borrowed, prov_carrier_slots(graph, argument))
			prov_invalidate(graph, argument, v.span, "modified")
			// design.md "Borrowing iteration": a result derived from a view the
			// receiver holds names that view's source, not the receiver, so
			// advancing the receiver cannot invalidate an element already handed
			// back. The summary tells the two apart. The two lending synths have no
			// body to summarize, so they are named here; `indexed()` lends only
			// while it wraps a lending source.
			lends := prov_result_reads_through_receiver(c, v, index)
			if callee := symbol_of(c, v.resolution.chosen_overload); callee != nil {
				lends ||= callee.synth == .Slice_Ref_Next || indexed_next_lends(c, callee)
			}
			if lends {
				actuals[index] = prov_carrier_slots(graph, argument)
				continue
			}
			if root, path, ok := prov_place_of(graph, argument); ok {
				if prov_op_removes_element(container_op) {
					// A removal returns what the element held, not a container borrow.
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
			// design.md "Iteration adapters": a map view read-borrows the map, and
			// also carries what the stored elements borrow.
			held := walk_flow_expr(graph, argument)
			if root, path, ok := prov_place_of(graph, argument); ok {
				prov_access(graph, root, path, .Read, expr_span(argument))
				held = prov_join(
					graph, held, prov_borrow(graph, root, path, false, expr_span(argument), "view"),
				)
			} else if prov_expr_is_temporary(argument) {
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
				borrowed = prov_join(graph, borrowed, prov_carrier_slots(graph, argument))
				prov_walk_subscripts(graph, argument)
				prov_access(graph, root, path, .Write, expr_span(argument))
				actuals[index] = prov_join(graph, prov_carrier_slots(graph, argument),
					prov_borrow(graph, root, path, true, expr_span(argument), "borrow"))
				borrowed = prov_join(graph, borrowed, actuals[index])
				continue
			}
		}
		if index == 0 && container_op == .Map_Lookup_Value {
			// `lookup_value` copies the payload, carrying its stored dependencies.
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
		} else if prov_argument_borrows_caller(graph, v, index, receiver, has_receiver) {
			// design.md "Receiver forms": a read-only borrow of the caller's value,
			// plus whatever borrows the receiver itself carries.
			held := walk_flow_expr(graph, argument)
			callee := symbol_of(c, v.resolution.chosen_overload)
			if callee != nil && (callee.synth == .Adapter_Iter || callee.synth == .Iterator_Copy ||
			   (callee.synth == .Adapter_View && type_of(c, callee.result).adapter_by_value) ||
			   clone_copies_receiver(c, callee)) {
				actuals[index] = held
				borrowed = prov_join(graph, borrowed, held)
				continue
			}
			loan: []int
			// Walking the argument above already read the place.
			if root, path, ok := prov_place_of(graph, argument); ok && !expression_converts_storage(argument) {
				loan = prov_borrow(graph, root, path, false, expr_span(argument), "borrow")
			} else if carriers, _, through := prov_read_through_carrier(graph, argument); through {
				loan = carriers // `Type.method(&value)`, or a place behind a pointer
			} else {
				loan = prov_borrow(graph, prov_temp_root(graph, expr_span(argument)), nil, false, v.span, "borrow")
			}
			// A `value: T` callee shares the owner's allocations only for the call
			// (design.md "Parameter semantics and ABI lowering"): the argument stays
			// borrowed until it returns, but the result cannot derive from it.
			if !(index == 0 && has_receiver) && proc_parameter_mode(c, call_proc_type(c, v), index) == .Value {
				borrowed = prov_join(graph, borrowed, loan)
			} else {
				held = prov_join(graph, held, loan)
			}
			actuals[index] = held
		} else {
			actuals[index] = walk_flow_expr(graph, argument)
		}
		prov_reborrow(graph, actuals[index], prov_parameter_type(graph, v, index))
		borrowed = prov_join(graph, borrowed, actuals[index])
	}
	prov_call_resets(graph, v)
	prov_call_retention(graph, v, actuals)
	prov_container_content(graph, v, container_op, actuals)
	prov_call_effects(graph, v)
	if len(borrowed) > 0 {
		prov_emit(graph, Prov_Event{kind = .Live, sources = borrowed, span = v.span})
	}
	return prov_store_call_results(graph, v, actuals, borrowed)
}

// The caller's half of `@(escape=...)`. `static` must outlive the process;
// `stored` is modelled as an assignment into each writable argument, so the loan
// travels and ordinary scope rules handle the rest.
@(private = "file")
prov_call_retention :: proc(graph: ^Flow_Graph, v: ^Expr_Call, actuals: [][]int) {
	proc_type := call_proc_type(graph.k.c, v)
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

// Where a `stored` argument may land: an `inout` parameter or receiver, or a
// mutable carrier, each only when it can hold a borrow. Matches the body check.
@(private = "file")
prov_writable_arguments :: proc(graph: ^Flow_Graph, v: ^Expr_Call, proc_type: Type_Id) -> []int {
	c := graph.k.c
	out := make([dynamic]int, 0, len(v.bound), graph.alloc)
	sym := symbol_of(c, v.resolution.chosen_overload)
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
	if info == nil {
		return out[:]
	}
	for index in start ..< min(len(v.bound), len(info.parameters)) {
		if prov_argument_is_inout(graph, v, index) {
			if type_carries_borrow(c, info.parameters[index]).any {
				append(&out, index)
			}
			continue
		}
		// `p^.view = values`: what the pointee holds, not the pointer.
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

// One argument receiving what another may leave in it, joined since the callee
// may leave it alone. An `inout` argument is the place; a `^mut`/`[]mut` one
// goes through its `carrier` loans.
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

@(private = "file")
prov_op_returns_view :: proc(op: Container_Op) -> bool {
	#partial switch op {
	case .Map_Entries, .Map_Keys, .Map_Values:
		return true
	}
	return false
}

@(private = "file")
prov_op_removes_element :: proc(op: Container_Op) -> bool {
	#partial switch op {
	case .Pop, .Remove, .Remove_Unordered, .Map_Remove:
		return true
	}
	return false
}

// The content path a removal reads; a map removal reads only the value.
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

// Stored key/value borrows become the container's, checked like an indexed
// assignment. A fallible write joins, since its failure edge changes nothing.
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
	// Also covers a receiver reached through a carrier.
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
	written := prov_extend(graph, path, proj_wild())
	if content := prov_content_at(graph, root, written); len(content) > 0 {
		prov_define_content(graph, content, stored, v.span, written, info.element)
	}
}

// design.md "string type conversions": a text operation either borrows its
// operand or returns a fresh owner with no loans.
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
			// An owning `string` receiver lends its own storage.
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

// design.md "Standard customization procedures": a clone is ownership-recursive,
// so a generated `try_clone`/`clone` result carries what its receiver carries,
// never a loan of the receiver's own storage. A `hook(copy)` taking `self: ^`
// is the exception, since its body could hand one out.
@(private = "file")
clone_copies_receiver :: proc(c: ^Compiler, callee: ^Symbol) -> bool {
	if callee.synth != .Clone && callee.synth != .Try_Clone {
		return false
	}
	hook := symbol_of(c, lifecycle_of(c, callee.owner_type).custom_try_clone)
	return hook == nil || !param_mode_is_pointer(symbol_param_mode(c, hook, 0))
}

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

@(private = "file")
prov_carries_borrow :: proc(c: ^Compiler, type: Type_Id) -> bool {
	return prov_type_or_wrapped(c, type, type_is_carrier)
}

@(private = "file")
prov_store_call_results :: proc(graph: ^Flow_Graph, v: ^Expr_Call, actuals: [][]int, borrowed: []int) -> []int {
	// A diverging call's value is never produced (design.md "Diverging
	// procedures"), so it contributes no sources.
	if v.type == TYPE_VOID || v.type == INVALID_TYPE || call_diverges(graph.k.c, v) {
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

// Resets propagate through wrappers and indirect calls (design.md).
@(private = "file")
prov_call_resets :: proc(graph: ^Flow_Graph, v: ^Expr_Call) {
	proc_type := call_proc_type(graph.k.c, v)
	if proc_type == INVALID_TYPE {
		return
	}
	for argument, index in v.bound {
		if argument == nil || !proc_param_resets(graph.k.c, proc_type, index) {
			continue
		}
		prov_reset(graph, prov_region_of(graph, argument), v.span, false, v)
	}
}

// design.md "Temporaries and procedure boundaries": a direct call substitutes
// argument roots into the callee's result summary. An indirect call has none,
// so its result derives from every escaping argument and loses fresh-allocation
// provenance, which keeps it away from checked `free`.
@(private = "file")
prov_call_result :: proc(
	graph: ^Flow_Graph,
	v: ^Expr_Call,
	actuals: [][]int,
	borrowed: []int,
	result_type: Type_Id,
) -> []int {
	c := graph.k.c
	// design.md "`inout` results": the result aliases the `inout` arguments.
	if prov_result_is_inout(graph, v) {
		out: []int
		for slots, index in actuals {
			if prov_argument_is_inout(graph, v, index) {
				out = prov_join(graph, out, slots)
			}
		}
		return type_is_carrier(c, result_type) ? out : prov_value_content(graph, out, result_type, v.span)
	}
	// design.md "Shared ownership": a borrow from a handle derives from it. The
	// body can't show that through its `rawptr`, so it is asserted here.
	if len(actuals) > 0 && prov_receiver_is_shared_handle(graph, v) {
		if type_is_carrier(c, result_type) {
			return actuals[0]
		}
		return prov_value_content(graph, actuals[0], result_type, v.span)
	}
	// A result that is not itself a borrow can still hold one.
	if !type_is_carrier(c, result_type) && !type_carries_borrow(c, result_type).any {
		return nil
	}
	callee := call_contract_declaration(c, v)
	direct := prov_has_direct_body(c, callee)
	prov_note_summary_dependency(graph, callee, direct)
	out: []int
	if summary, found := result_summary(c, callee); found {
		// Sibling fields share one synthesized root per kind.
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
		if _, is_call := v.operation.(Call_Procedure); is_call && symbol_of(c, callee) == nil {
			append(&graph.plain_calls, v)
		}
		if len(out) == 0 && len(borrowed) == 0 {
			out = prov_synthetic_borrow(graph, v, .Unknown, result_type)
		}
	}
	return type_is_carrier(c, result_type) ? out : prov_value_content(graph, out, result_type, v.span)
}

@(private = "file")
prov_receiver_is_shared_handle :: proc(graph: ^Flow_Graph, v: ^Expr_Call) -> bool {
	sym := symbol_of(graph.k.c, v.resolution.chosen_overload)
	if sym == nil || !sym.has_receiver {
		return false
	}
	return type_is_shared_handle(graph.k.c, sym.owner_type)
}

// Substitutes one result path's dependencies, matching parameter paths by shape.
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
	if is_contract_join(graph.k.c, callee) {
		for member in symbol_of(graph.k.c, callee).members {
			prov_note_summary_dependency(graph, member, direct)
		}
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

// Whether the result reaches this parameter only through a view it holds: a
// narrowed summary entry means exactly that, since `merge_param_paths` widens
// on any loan of the parameter's own storage.
@(private = "file")
prov_result_reads_through_receiver :: proc(c: ^Compiler, v: ^Expr_Call, index: int) -> bool {
	// A mutable yield keeps naming the receiver (design.md "By-reference
	// iteration").
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

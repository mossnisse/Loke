// Provenance construction for the disposable flow graph: events, carrier slots
// and their content, loans and accesses, captures, temporaries, and the statement
// hooks. cfg.odin owns traversal, control-flow topology, and lifecycle events;
// provenance_state.odin holds the state and event vocabulary, and borrow.odin
// solves the root and region facts recorded here.
package lokec

import "core:fmt"
import "core:slice"

// ------------------------------------------------- provenance construction --

// Graph construction for the lattices in `src/borrow.odin`: allocates in the
// graph's arena and reads the typed AST without reporting or changing it.
// Conversion walkers record the conversion they walk beneath in
// `graph.converting`; `prov_repr` and `prov_type` read the representation there.
// Leaf queries take values, which carry their own representation.

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
	emitted := event
	if event.kind == .Def {
		prov_note_offset(graph, event.slot, event.sources)
		prov_note_element_pointer(graph, event)
		emitted.view_def = prov_note_view(graph, event)
	}
	if event.kind == .Load && event.load != .Writable {
		emitted.load_places = prov_load_places(graph, event.into, event.path)
	}
	append(&graph.blocks[graph.current].prov, emitted)
}

// Records how a definition of a named slot relates its view to a fresh
// borrow (`Prov_View_Def`), so a constant subscript of a view held there
// names one element of the range that borrow lends
// (`prov_local_view_element`): the borrow itself, the reslice
// `prov_note_reslice` announced, or anything else. One more than the
// definition's index among the slot's (`Prov_Event.view_def`), or 0, as for
// an event a fact graph emits into the graph it materializes, whose
// definitions it does not record.
@(private)
prov_note_view :: proc(graph: ^Flow_Graph, event: Prov_Event) -> int {
	reslice := graph.view_reslice
	graph.view_reslice = {}
	if graph.prov_slots[event.slot].symbol == INVALID_SYMBOL || graph.materialized != nil {
		return 0
	}
	fresh := NO_LOAN
	if event.place_loan == 0 && event.loan == NO_LOAN && len(event.sources) == 1 {
		fresh = prov_slot_fresh_loan(graph, event.sources[0])
	}
	reslices := reslice.slot == event.slot + 1
	def := Prov_View_Def{loan = NO_LOAN, unknown = true}
	switch {
	case reslices && reslice.open:
		if fresh != NO_LOAN {
			def = Prov_View_Def{loan = fresh, lo = reslice.lo, open = true}
		}
	case reslices && event.place_loan == 0 && event.loan == NO_LOAN:
		def = reslice
		def.slot = 0
	case event.place_loan == 0 && event.loan != NO_LOAN && len(event.sources) == 0:
		def = Prov_View_Def{loan = event.loan}
	case fresh != NO_LOAN:
		def = Prov_View_Def{loan = fresh}
	}
	if event.slot not_in graph.view_defs {
		graph.view_defs[event.slot] = make([dynamic]Prov_View_Def, 0, 1, graph.alloc)
	}
	append(&graph.view_defs[event.slot], def)
	return len(graph.view_defs[event.slot])
}

// Announces that the next definition of `slot` takes `value`, when that is a
// constant reslice of a local view, as `&mut s[1:]` or `s[0:2]`, or a fresh
// borrow of elements from a constant start to an end that is not constant,
// as `&mut d[:]` of a dynamic array, which is `open` (`prov_note_view`).
@(private)
prov_note_reslice :: proc(graph: ^Flow_Graph, slot: int, value: Expr) {
	graph.view_reslice = {}
	c := graph.k.c
	slice_expr, is_slice := value.(^Expr_Slice)
	if !is_slice || len(slice_expr.bound) > 0 {
		return
	}
	if prov_note_open_borrow(graph, slot, slice_expr) {
		return
	}
	ident, named := slice_expr.operand.(^Expr_Ident)
	if !named {
		return
	}
	sym := symbol_of(c, ident.symbol)
	if sym == nil || sym.kind == .Parameter || underlying_kind(c, sym.type) != .Slice {
		return
	}
	from, found := prov_slot_for_symbol(graph, ident.symbol)
	if !found {
		return
	}
	lo, lo_constant := prov_const_bound(graph, slice_expr.lo, 0)
	hi, hi_constant := prov_const_bound(graph, slice_expr.hi, -1)
	if !lo_constant || !hi_constant || slice_expr.hi != nil && hi < 0 {
		return
	}
	graph.view_reslice = Prov_View_Def{slot = slot + 1, loan = NO_LOAN, from = from + 1, lo = lo, hi = hi}
}

// `prov_note_reslice` for a slice of an array or dynamic array in a local
// place whose range step is a wildcard (`prov_range_step`) though it starts
// at a constant element, as `&mut d[:]` or `&mut a[1:n]`: the borrow it makes
// lends the elements from there on (`Prov_View_Def.open`).
@(private = "file")
prov_note_open_borrow :: proc(graph: ^Flow_Graph, slot: int, slice_expr: ^Expr_Slice) -> bool {
	kind := underlying_kind(graph.k.c, prov_type(graph, slice_expr.operand))
	if kind != .Array && kind != .Dynamic_Array || prov_range_step(graph, slice_expr).kind != .Wild {
		return false
	}
	if _, _, local := prov_place_of(graph, slice_expr.operand); !local {
		return false
	}
	lo, constant := prov_const_bound(graph, slice_expr.lo, 0)
	if !constant || lo < 0 {
		return false
	}
	if slice_expr.hi != nil {
		if _, hi_constant := prov_const_int(graph, slice_expr.hi); hi_constant {
			return false
		}
	}
	graph.view_reslice = Prov_View_Def{slot = slot + 1, loan = NO_LOAN, lo = lo, hi = -1, open = true}
	return true
}

@(private)
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

@(private)
prov_new_root :: proc(graph: ^Flow_Graph, kind: Root_Kind, span: Span, name: string) -> Root_Id {
	append(&graph.roots, Prov_Root{kind = kind, span = span, name = name, param_index = -1, content = -1})
	return Root_Id(len(graph.roots) - 1)
}

// design.md "Storage roots and borrow carriers": every ordinary variable owns
// its inline storage and is a root for borrows of it. Static-duration storage is
// a root that outlives every body, and an `inout` parameter names the caller's.
@(private)
prov_root_for_symbol :: proc(graph: ^Flow_Graph, id: Symbol_Id) -> Root_Id {
	if existing, found := graph.root_by_symbol[id]; found {
		return existing
	}
	sym := symbol_of(graph.k.c, id)
	if sym == nil {
		return NO_ROOT
	}
	storage := prov_storage_id(graph, Written_Storage{symbol = id})
	if storage == 0 { return NO_ROOT }
	kind := prov_storage(graph, storage).kind
	root := prov_new_root(graph, kind, sym.span, identifier_text(graph.k.c, sym.name))
	graph.roots[int(root)].symbol = id
	graph.roots[int(root)].storage = storage
	graph.root_by_storage[storage] = root
	if kind == .Param {
		graph.roots[int(root)].param_index = int(sym.index)
	}
	graph.root_by_symbol[id] = root
	return root
}

// A carrier variable's slot. A static-duration one starts holding whatever
// another body may have stored there, as a global's content slots do.
@(private)
prov_slot_for_symbol :: proc(graph: ^Flow_Graph, id: Symbol_Id) -> (int, bool) {
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
	entry := empty_prov_slot(id)
	entry.name = identifier_text(graph.k.c, sym.name)
	entry.span = sym.span
	slot := prov_add_slot(graph, entry)
	graph.slot_by_symbol[id] = slot
	graph.own_slots[id] = prov_one(graph, slot)
	if symbol_outlives_bodies(sym) {
		loan := prov_new_loan(
			graph, prov_existing_content_root(graph, id, sym), nil,
			carrier_is_mutable(graph.k.c, sym.type), sym.span, carrier_noun(graph.k.c, sym.type),
		)
		append(&graph.entry_defs, Prov_Entry_Def{slot = slot, loan = loan})
	}
	return slot, true
}

// Another body may have filled static storage, with borrows that outlive the
// process, or the thread for a `thread_local` (design.md "Retaining a borrow").
@(private = "file")
prov_existing_content_root :: proc(graph: ^Flow_Graph, id: Symbol_Id, sym: ^Symbol) -> Root_Id {
	root := prov_new_root(
		graph, sym.duration == .Thread_Local ? .Thread_Local : .Static, sym.span,
		fmt.aprintf("existing content of `%s`", identifier_text(graph.k.c, sym.name), allocator = graph.alloc),
	)
	graph.roots[int(root)].origin = id
	return root
}

// Each literal element's borrows go to its own place; an element whose slot
// can't be resolved joins into every path.
@(private)
prov_composite_content :: proc(graph: ^Flow_Graph, v: ^Expr_Composite, content: []int, literal_type: Type_Id) -> []int {
	// One part per element value, and for a map one more per key (design.md
	// "Values that contain borrows": a map carries its keys' borrows too).
	Part :: struct {
		loans:  []int,
		prefix: []Proj_Step,
		type:   Type_Id,
		known:  bool,
	}
	parts := make([dynamic]Part, 0, 2 * len(v.elements), graph.alloc)
	is_map := underlying_kind(graph.k.c, literal_type) == .Map
	// What earlier elements hold, used again as each later mutable carrier is
	// lent, as `prov_call` does for arguments.
	held := make([dynamic]int, 0, len(v.elements), graph.alloc)
	// A borrow an element takes, which lasts until the literal is built.
	borrows := make([dynamic]int, 0, len(v.elements), graph.alloc)
	last_write := -1
	for element, index in v.elements {
		if prov_expr_may_write(graph.k.c, element.key) || prov_expr_may_write(graph.k.c, element.value) {
			last_write = index
		}
	}
	for element, index in v.elements {
		if is_map {
			loans := walk_flow_expr(graph, element.key)
			prov_hold_owner(graph, element.key)
			// The key is evaluated before its own value, which may write what it
			// read, as may a later element.
			if len(loans) > 0 && (prov_expr_may_write(graph.k.c, element.value) || index < last_write) {
				loans = prov_capture(graph, loans, expr_span(element.key))
			}
			entry := prov_extend(graph, nil, prov_map_entry_step(graph, literal_type, element.key))
			key_type := prov_type(graph, element.key)
			append(&parts, Part{loans, prov_extend(graph, entry, proj_field(PROJ_MAP_KEY)), key_type, true})
		}
		if element.value == nil {
			continue
		}
		element_type := prov_element_type(graph, v, literal_type, index)
		loans := prov_walk_stored(graph, element.value, element_type)
		prov_hold_owner(graph, element.value)
		prov_repeated_element_effects(graph, v, literal_type, index, loans)
		// design.md "Weakening and reborrows": a mutable carrier stored in an
		// element, or in a record there, is a reborrow of it, live until the literal
		// is built: `Pair{xs, xs}` would hold two mutable views of one sequence.
		for slot in loans {
			if graph.prov_slots[slot].borrow != nil {
				append(&borrows, slot)
			}
		}
		lent := type_carries_borrow(graph.k.c, element_type).mutable
		if lent {
			prov_use_copied(graph, loans, element_type, expr_span(element.value), true)
			loans = prov_lend_carrier(graph, loans, held[:], expr_span(element.value))
		}
		// design.md "Evaluation order": a later element may write what this one
		// read. A lent carrier is suspended, so it needs no copy.
		if len(loans) > 0 && index < last_write {
			loans = prov_capture(graph, loans, expr_span(element.value), keep_reborrows = lent)
		}
		append(&held, ..loans)
		prefix, known := prov_element_prefix(graph, v, literal_type, index)
		append(&parts, Part{loans, prefix, prov_type(graph, element.value), known})
	}
	// Building the literal uses each borrow and reborrow its elements took, so what
	// they lend stays lent through every later element, not only the lent ones:
	// `Pair{xs, g(xs)}` uses `xs` while the pair's view is live.
	for slot in held {
		if prov_slot_is_reborrow(graph, slot) || prov_slot_is_pending(graph, slot) {
			append(&borrows, slot)
		}
	}
	if len(borrows) > 0 {
		prov_emit(graph, Prov_Event{kind = .Live, sources = borrows[:], span = v.span})
	}
	for slot in content {
		sources := make([dynamic]int, 0, len(parts), graph.alloc)
		for part in parts {
			if part.known {
				append(&sources, ..prov_part_sources(graph, slot, part.prefix, part.loans, part.type))
			} else {
				append(&sources, ..part.loans)
			}
		}
		prov_define_one_content(graph, slot, sources[:], v.span)
	}
	return content
}

// The type one literal element is stored as, after any weakening: a `[]mut T`
// stored in a `[]T` field is only read.
@(private)
prov_element_type :: proc(graph: ^Flow_Graph, v: ^Expr_Composite, type: Type_Id, index: int) -> Type_Id {
	c := graph.k.c
	info := underlying_info(c, type)
	if info == nil {
		return prov_type(graph, v.elements[index].value)
	}
	#partial switch info.kind {
	case .Array, .Dynamic_Array, .Map:
		return info.element
	case .Struct:
		if field := prov_element_field(v, index); field >= 0 && field < len(info.fields) {
			return symbol_of(c, info.fields[field]).type
		}
	}
	return prov_type(graph, v.elements[index].value)
}

// Whether evaluating `e` may run a program's code, which could write a carrier read
// beside it. A constant and a plain read of a place run nothing, and neither does a
// built-in operation on scalars, whose values copy as plain bits: `xs[x - 1]` and
// `xs[xs.len() - 1]` only read. A read of anything else may run a hook, and a map's
// key a hash.
@(private)
prov_expr_may_write :: proc(c: ^Compiler, e: Expr) -> bool {
	if e == nil || is_const_expr(e) {
		return false
	}
	scalar :: proc(c: ^Compiler, e: Expr) -> bool {
		base := expr_base(e)
		return base != nil && type_is_panic_free_scalar(c, base.type)
	}
	#partial switch v in e {
	case ^Expr_Ident:
		return false
	case ^Expr_Selector:
		return prov_expr_may_write(c, v.operand)
	case ^Expr_Postfix:
		return v.op != .Caret || prov_expr_may_write(c, v.operand)
	case ^Expr_Unary:
		return v.op == .Amp || v.resolution.kind == .User_Operator || !scalar(c, v) || !scalar(c, v.operand) ||
		       prov_expr_may_write(c, v.operand)
	case ^Expr_Binary:
		return v.resolution.kind != .Builtin_Operator || !scalar(c, v) || !scalar(c, v.lhs) || !scalar(c, v.rhs) ||
		       prov_expr_may_write(c, v.lhs) || prov_expr_may_write(c, v.rhs)
	case ^Expr_Cond:
		return !scalar(c, v) || prov_expr_may_write(c, v.cond) || prov_expr_may_write(c, v.then) ||
		       prov_expr_may_write(c, v.otherwise)
	case ^Expr_Index:
		if v.resolution.kind == .User_Operator || len(v.bound) != 0 || !scalar(c, v) ||
		   underlying_kind(c, expr_base(v.operand).type) == .Map {
			return true
		}
		return prov_expr_may_write(c, v.operand) || prov_indices_may_write(c, v.indices)
	case ^Expr_Call:
		// A numeric conversion, as `int(x)`.
		if _, converts := v.operation.(Call_Conversion); converts && len(v.args) == 1 && scalar(c, v) && scalar(c, v.args[0].value) {
			return prov_expr_may_write(c, v.args[0].value)
		}
		// A built-in container's `len()` or `cap()` only reads its header.
		if chosen := symbol_of(c, v.resolution.chosen_overload); chosen != nil && (chosen.synth == .Standard_Len || chosen.synth == .Standard_Cap) && len(v.bound) == 1 {
			return prov_expr_may_write(c, v.bound[0])
		}
	}
	return true
}

// The path one literal element's value fills: a field, an index range, or a
// map entry's value under its key's entry.
@(private)
prov_element_prefix :: proc(graph: ^Flow_Graph, v: ^Expr_Composite, type: Type_Id, index: int) -> ([]Proj_Step, bool) {
	#partial switch underlying_kind(graph.k.c, type) {
	case .Map:
		entry := prov_extend(graph, nil, prov_map_entry_step(graph, type, v.elements[index].key))
		return prov_extend(graph, entry, proj_field(PROJ_MAP_VALUE)), true
	case .Array, .Dynamic_Array:
		return prov_extend(graph, nil, prov_array_element_step(v, index)), true
	}
	field := prov_element_field(v, index)
	if field < 0 {
		return prov_extend(graph, nil, proj_wild()), false
	}
	return prov_extend(graph, nil, proj_field(field)), true
}

// design.md "Fixed arrays": a designated element fills its index range.
@(private = "file")
prov_array_element_step :: proc(v: ^Expr_Composite, index: int) -> Proj_Step {
	lo, hi := composite_element_slots(v, index)
	return proj_range(i64(lo), i64(hi))
}

// The field one element of a record literal fills, as the checker resolved it,
// or -1.
@(private = "file")
prov_element_field :: proc(v: ^Expr_Composite, index: int) -> int {
	return index < len(v.field_indices) ? v.field_indices[index] : -1
}

// design.md "Unions": a variant's payload sits under the wildcard alternative.
@(private)
prov_variant_content :: proc(graph: ^Flow_Graph, v: ^Expr_Call, loans: []int) -> []int {
	content := prov_temp_content(graph, prov_type(graph, v))
	if len(content) == 0 {
		return nil
	}
	prefix := prov_extend(graph, nil, proj_wild())
	payload_type := INVALID_TYPE
	if len(v.bound) == 1 && v.bound[0] != nil {
		payload_type = prov_type(graph, v.bound[0])
	}
	for slot in content {
		prov_define_one_content(graph, slot, prov_part_sources(graph, slot, prefix, loans, payload_type), v.span)
	}
	return content
}

// A value that is not itself a borrow can still hold one. Every place
// `carrier_shape` names gets its own slot, so a field read does not inherit
// what a sibling borrows.
@(private)
prov_content_slots :: proc(graph: ^Flow_Graph, id: Symbol_Id) -> []int {
	if _, bare := graph.slot_by_symbol[id]; bare {
		return nil // a bare carrier already has its own slot
	}
	if existing, found := graph.own_slots[id]; found {
		return existing
	}
	sym := symbol_of(graph.k.c, id)
	if sym == nil || type_is_carrier(graph.k.c, sym.type) {
		return nil
	}
	if sym.kind != .Var && sym.kind != .Parameter {
		return nil
	}
	shape := carrier_shape(graph.k.c, sym.type)
	if len(shape) == 0 {
		return nil // an all-scalar value initializes no payload facts
	}
	unknown_root := NO_ROOT
	if symbol_outlives_bodies(sym) {
		unknown_root = prov_existing_content_root(graph, id, sym)
	}
	slots := make([]int, len(shape), graph.alloc)
	for path, index in shape {
		entry := prov_content_entry(id, path, sym.type)
		entry.name = identifier_text(graph.k.c, sym.name)
		entry.span = sym.span
		slots[index] = prov_add_slot(graph, entry)
		if unknown_root != NO_ROOT {
			loan := prov_new_loan(graph, unknown_root, nil, path.mutable, sym.span, carrier_path_noun(graph.k.c, path))
			append(&graph.entry_defs, Prov_Entry_Def{slot = slots[index], loan = loan})
		}
	}
	graph.own_slots[id] = slots
	return slots
}

// The content slots whose shape path overlaps the place's projection.
@(private)
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
		slots[index] = prov_add_slot(graph, prov_content_entry(INVALID_SYMBOL, path, type))
	}
	return slots
}

// A slot for the place `path` names in a value of type `shape`.
@(private = "file")
prov_content_entry :: proc(symbol: Symbol_Id, path: Carrier_Path, shape: Type_Id) -> Prov_Slot {
	entry := empty_prov_slot(symbol)
	entry.path = path.steps
	entry.content_type = path.truncated ? INVALID_TYPE : path.type
	entry.content_shape = shape
	entry.content_truncated = path.truncated
	entry.precision = path.precision
	return entry
}

// Sources describing this shape are selected by path; others reach every path.
// A distinct type has its underlying type's carrier shape, so a conversion
// between them keeps each carrier's own sources.
@(private)
prov_select_content :: proc(graph: ^Flow_Graph, sources: []int, type: Type_Id, path: []Proj_Step) -> []int {
	c := graph.k.c
	selected := make([dynamic]int, 0, len(sources), graph.alloc)
	for source in sources {
		entry := graph.prov_slots[source]
		if type == INVALID_TYPE || entry.content_shape == INVALID_TYPE ||
		   type_underlying(c, entry.content_shape) != type_underlying(c, type) || paths_overlap(entry.path, path) {
			append(&selected, source)
		}
	}
	return selected[:]
}

// What of `loans`, a part of type `type` filling `prefix`, `slot` holds.
@(private = "file")
prov_part_sources :: proc(graph: ^Flow_Graph, slot: int, prefix: []Proj_Step, loans: []int, type: Type_Id) -> []int {
	path := graph.prov_slots[slot].path
	if !paths_overlap(path, prefix) {
		return nil
	}
	return prov_select_content(graph, loans, type, path[min(len(prefix), len(path)):])
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
	reads_only := false,
) -> []int {
	if len(sources) == 0 {
		return nil
	}
	content := prov_temp_content(graph, result_type)
	for slot in content {
		full := prov_concat_path(graph, path, graph.prov_slots[slot].path)
		graph.prov_slots[slot].precision |= path_precision(full)
		selected := prov_select_content(graph, sources, source_type, full)
		prov_emit(graph, Prov_Event{kind = .Live, sources = selected, span = span, reads_only = reads_only})
		taken := len(graph.reborrows)
		prov_define_one_content(graph, slot, selected, span)
		// design.md "Weakening and reborrows": what is only read reborrows
		// read-only, whatever the carrier's capability.
		if reads_only {
			for &reborrow in graph.reborrows[taken:] {
				reborrow.mutable = false
			}
		}
	}
	return content
}

@(private)
prov_read_content :: proc(graph: ^Flow_Graph, root: Root_Id, path: []Proj_Step, type: Type_Id, span: Span, reads_only := false) -> []int {
	sym := symbol_of(graph.k.c, graph.roots[int(root)].symbol)
	if sym == nil {
		return nil
	}
	return prov_project_content(graph, prov_content_at(graph, root, path), sym.type, path, type, span, reads_only)
}

// Without a field mapping, every result path gets every source.
@(private)
prov_value_content :: proc(graph: ^Flow_Graph, sources: []int, type: Type_Id, span: Span) -> []int {
	return prov_project_content(graph, sources, INVALID_TYPE, nil, type, span)
}

@(private)
prov_load_content :: proc(
	graph: ^Flow_Graph, carriers: []int, path: []Proj_Step, type: Type_Id, span: Span, reads_only := false, place: Expr = nil,
) -> []int {
	if len(carriers) == 0 {
		return nil
	}
	prov_reach(graph, carriers, span)
	content := prov_temp_content(graph, type)
	graph.has_content_load ||= len(content) > 0
	// One element of a view parameter is read alone (`prov_view_element`),
	// and so is one of a local view where the solve knows where it starts
	// (`Prov_Event.element`).
	load_element: Prov_Element_Slots
	element: Prov_View_At
	if place != nil && len(content) > 0 {
		load_element, _ = prov_view_element(graph, place)
		if at := prov_view_at(graph, place, carriers); at.loan == 0 {
			element = at
		}
	}
	through_element := len(load_element.slots) == 0 && prov_may_point_at_element(graph, carriers)
	for slot in content {
		graph.prov_slots[slot].loaded = true
		prov_emit(graph, Prov_Event {
			kind            = .Load,
			slot            = slot,
			into            = carriers,
			path            = prov_concat_path(graph, path, graph.prov_slots[slot].path),
			span            = span,
			reads_only      = reads_only,
			load_element    = load_element,
			element         = element,
			through_element = through_element,
		})
	}
	prov_emit(graph, Prov_Event{kind = .Live, sources = content, span = span, reads_only = reads_only})
	prov_name_loaded(graph, content, carriers)
	return content
}

// design.md "Weakening and reborrows": a value read out through a carrier only
// reads it when the value carries no mutable borrow, so a read-only reborrow
// of the carrier does not suspend it.
@(private)
prov_read_is_reads_only :: proc(c: ^Compiler, type: Type_Id) -> bool {
	return !type_carries_borrow(c, type).mutable
}

// design.md "Weakening and reborrows": a carrier stored where a read-only one
// is wanted is only read, so `Views{xs, xs}` is accepted. An erased value is not:
// a stored `dyn proc` borrows the place it views (design.md "Borrowed callable
// views").
@(private)
prov_walk_stored :: proc(graph: ^Flow_Graph, value: Expr, destination: Type_Id) -> []int {
	if expr_base(value) != nil && prov_repr(graph, value).erased_from == INVALID_TYPE &&
	   prov_argument_only_read(graph, value, destination) {
		return prov_read_carrier(graph, value, true)
	}
	return walk_flow_expr(graph, value)
}

// A field, element, or pointee that `walk_flow_expr` would read by loading it
// through the carriers it is reached by, with no box, operator, or conversion
// of its own.
@(private)
prov_reads_plainly_through :: proc(graph: ^Flow_Graph, e: Expr) -> bool {
	if base := expr_base(e); base == nil || prov_repr(graph, e).erased_from != INVALID_TYPE || prov_repr(graph, e).view_from != INVALID_TYPE {
		return false
	}
	#partial switch v in e {
	case ^Expr_Postfix:
		return v.op == .Caret && !v.boxed
	case ^Expr_Selector:
		return true
	case ^Expr_Index:
		return v.resolution.kind != .User_Operator
	}
	return false
}

// The carriers `operand` holds, for a read through them.
@(private)
prov_read_carrier :: proc(graph: ^Flow_Graph, operand: Expr, reads_only: bool) -> []int {
	if reads_only {
		if ident, is_ident := operand.(^Expr_Ident); is_ident {
			return prov_read_ident(graph, ident, reads_only = true)
		}
		if root, path, ok := prov_place_of(graph, operand); ok {
			prov_walk_subscripts(graph, operand)
			prov_access(graph, root, path, .Read, expr_span(operand), reads_only = true)
			return prov_read_content(graph, root, path, prov_type(graph, operand), expr_span(operand), reads_only = true)
		}
		// Copied out through a carrier, as `p^` passed to a `^T` parameter, the
		// stored carrier is only read too.
		if prov_reads_plainly_through(graph, operand) {
			if carriers, path, through := prov_read_through_carrier(graph, operand, reads_only = true); through {
				return prov_load_content(graph, carriers, path, prov_type(graph, operand), expr_span(operand), reads_only = true, place = operand)
			}
		}
	}
	return walk_flow_expr(graph, operand)
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
// drop reads none, so a local without a hand-written hook is not asked. One
// that is or reaches an `@(wakes_on_drop)` type is, hook or not: its drop is
// what the join check asks about (design.md "Releasing before the join").
@(private)
prov_drop_reads :: proc(graph: ^Flow_Graph, id: Symbol_Id) -> bool {
	sym := symbol_of(graph.k.c, id)
	if sym == nil || len(prov_content_slots(graph, id)) == 0 {
		return false
	}
	return type_drop_runs_hook(graph.k.c, sym.type) || type_reaches_waker(graph.k.c, sym.type) != INVALID_TYPE
}

@(private)
prov_drop_use :: proc(graph: ^Flow_Graph, id: Symbol_Id, span: Span, at_scope_exit := false) {
	// A `parallel` block's join uses what its tasks hold.
	if held, joins := graph.task_slots[id]; joins {
		sources := prov_one(graph, held)
		if holds, reborrowed := graph.task_holds[id]; reborrowed {
			sources = prov_join(graph, sources, holds)
		}
		prov_emit(graph, Prov_Event{kind = .Live, sources = sources, span = span})
		bit := prov_window_bit(graph, id)
		if tasks, pooled := graph.pool_tasks[id]; pooled && graph.current != NO_BLOCK {
			// Before the join closes the window, which decides where they apply.
			events := &graph.blocks[graph.current].prov
			first := len(events)
			prov_pool_join_effects(graph, tasks, span)
			for &event in events[first:] {
				event.joins = bit + 1
			}
		}
		prov_emit(graph, Prov_Event{kind = .Task_Join, slot = bit, span = span})
		// The tasks are done, so a block entered again, as a loop body's is,
		// starts holding nothing.
		for slot in sources {
			prov_emit(graph, Prov_Event{kind = .Def, slot = slot, loan = NO_LOAN, span = span})
		}
	}
	if !prov_drop_reads(graph, id) {
		return
	}
	prov_emit(graph, Prov_Event{kind = .Live, sources = prov_content_slots(graph, id), span = span})
	// The hook may read or write through what the value holds.
	prov_reach(graph, prov_content_slots(graph, id), span)
	if at_scope_exit {
		graph.scope_drops[span] = true
	}
}

// design.md "Temporaries and procedure boundaries": an extended temporary is
// dropped with its block's locals. Nothing can name it, so nothing moves it
// first: its drop hooks always run there, and what they read stays live.
@(private)
prov_extended_drop :: proc(graph: ^Flow_Graph, root: Prov_Root, effects_at, span: Span) {
	prov_drop_effects(graph, root.dropped, effects_at, root.name, unnamed = true)
	held := root.slots if root.content < 0 else prov_one(graph, root.content)
	if len(held) == 0 || !type_drop_runs_hook(graph.k.c, root.dropped) {
		return
	}
	prov_emit(graph, Prov_Event{kind = .Live, sources = held, span = span})
	graph.scope_drops[span] = true
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
prov_bind_value :: proc(graph: ^Flow_Graph, id: Symbol_Id, sources: []int, span: Span, copies := true) {
	if id == INVALID_SYMBOL {
		return
	}
	if slot, is_carrier := prov_slot_for_symbol(graph, id); is_carrier {
		if copies {
			prov_reborrow(graph, sources, symbol_of(graph.k.c, id).type, slot, span, copies = true)
		} else {
			graph.lent_aliases[slot] = sources
		}
		prov_emit(graph, Prov_Event{kind = .Def, slot = slot, loan = NO_LOAN, sources = sources, span = span})
		return
	}
	if content := prov_content_slots(graph, id); len(content) > 0 {
		prov_define_content(graph, content, sources, span, copies = copies)
	}
}

// standard-library.md "Chunks of a mutable slice": a chunk is a reborrow of the view that
// does not suspend the view, so the view advances while earlier chunks are
// held, and through it the chunk keeps the sliced carrier suspended. Each step
// binds a value disjoint from the last, so redefining the binding ends the
// reborrows taken from the chunk before. A borrow of a place in the chunk, as
// `&mut rows[0]`, is of that chunk too, so the step empties the slot holding
// the place loans taken through the binding (`Flow_Graph.chunk_loans`): one
// taken on an earlier step is of storage the new chunk does not reach. False
// when the binding is not a carrier slot.
@(private)
prov_bind_chunk :: proc(graph: ^Flow_Graph, id: Symbol_Id, sources: []int, span: Span) -> bool {
	slot, is_carrier := prov_slot_for_symbol(graph, id)
	if !is_carrier {
		return false
	}
	for source in sources {
		prov_add_reborrow(graph, Prov_Reborrow{source = source, derived = slot, span = span, mutable = true, passes_on = true})
	}
	prov_emit(graph, Prov_Event{kind = .Def, slot = slot, loan = NO_LOAN, sources = sources, span = span})
	taken, found := graph.chunk_loans[slot]
	if !found {
		taken = prov_temp_slot(graph)
		graph.chunk_loans[slot] = taken
	}
	prov_emit(graph, Prov_Event{kind = .Def, slot = taken, loan = NO_LOAN, span = span})
	return true
}

// Publishes content into another value's slots by matching paths.
@(private)
prov_define_content :: proc(
	graph: ^Flow_Graph,
	into: []int,
	from: []int,
	span: Span,
	written: []Proj_Step = nil,
	value_type: Type_Id = INVALID_TYPE,
	preserve_previous := false,
	copies := true,
	replace_matching := false,
	reborrows := true,
	replaces_read := false,
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
		whole_replacement := (!indistinct && path_has_exact_prefix(entry.path, written)) ||
		                     (replace_matching && prov_same_path(entry.path, written))
		if preserve_previous || (!whole_replacement &&
		   (indistinct || path_is_indistinct(entry.path) || partial_truncated_write)) {
			sources = prov_join(graph, prov_one(graph, slot), sources)
		}
		prov_define_one_content(graph, slot, sources, span, path_precision(written), copies, reborrows, replaces_read)
	}
}

// A mutable borrow published into a read-only field weakens as at a local.
@(private)
prov_define_one_content :: proc(
	graph: ^Flow_Graph, slot: int, sources: []int, span: Span, precision: Precision_Loss = {}, copies := true,
	reborrows := true, replaces_read := false,
) {
	entry := graph.prov_slots[slot]
	type := entry.content_type
	if type == INVALID_TYPE && entry.content_shape == INVALID_TYPE {
		if sym := symbol_of(graph.k.c, entry.symbol); sym != nil { type = sym.type }
	}
	if !copies {
		graph.lent_aliases[slot] = sources
	} else if reborrows {
		// A value read below the place it replaces was used by that read
		// (`prov_publish_store`).
		prov_reborrow(graph, sources, type, slot, span, copies = !replaces_read)
	}
	prov_emit(graph, Prov_Event{kind = .Def, slot = slot, loan = NO_LOAN, sources = sources, span = span, precision = precision, replaces_read = replaces_read})
	if traversal, traversed := graph.traversals[entry.symbol]; traversed {
		prov_publish_traversal(graph, traversal, slot, sources, span, type, reborrows, replaces_read)
	} else if len(graph.region_aliases[entry.symbol]) > 0 {
		prov_event(graph, Prov_Event_View_Publish {
			symbol = entry.symbol, path = entry.path, sources = sources, span = span,
			type = type, through = graph.view_loans[entry.symbol],
		})
	}
}

// Where a store through a `foreach (&mut x in source)` binding lands: the
// element it names, in a named place at `path` of `root`, or else in what the
// slots `into` name, along `path` when `known` says it is one place.
Prov_Traversal :: struct {
	root:  Root_Id,
	path:  []Proj_Step,
	into:  []int,
	known: bool,
	// A user's iterator lends it: `root` and `path` are the source, and `into`
	// the storage it may reach through carriers.
	lent:  bool,
}

// design.md "Values that contain borrows": a `&mut` binding names an element
// of the source, so a carrier stored through it is in the source too. `below`
// is where the binding is inside the element, and `element` where it is below
// the source, nil for a user's iterator, which says nothing of where it lends,
// so a store lands anywhere a carrier of its type may be: in the source or
// where its mutable carriers lead. Which element is not known, so what is
// stored joins what every element holds.
@(private)
prov_note_traversal :: proc(
	graph: ^Flow_Graph, s: ^Stmt_Foreach, id: Symbol_Id, below, element: []Proj_Step, iterated, elements, through: []int,
) {
	if id == INVALID_SYMBOL {
		return
	}
	protocol := s.kind == .Protocol
	carrier := type_is_carrier(graph.k.c, prov_type(graph, s.iterable))
	traversal := Prov_Traversal{root = NO_ROOT, lent = protocol}
	if carrier && !protocol && len(elements) > 0 {
		// What a view lends is below its loans, at no step of its own.
		traversal.into, traversal.path, traversal.known = elements, below, true
	} else if len(through) > 0 {
		traversal.into = through
		entry := graph.prov_slots[through[0]]
		if paths := prov_offset_paths(graph, entry.offsets); !protocol && len(through) == 1 && !entry.offsets_merged && len(paths) == 1 {
			traversal.path, traversal.known = prov_concat_path(graph, paths[0], element), true
		}
		if protocol {
			traversal.into = prov_join(graph, through, prov_load_writable(graph, through, expr_span(s.iterable)))
		}
	} else if root, path, named := prov_place_of(graph, s.iterable); named && !carrier {
		traversal.root, traversal.path = root, prov_concat_path(graph, path, element)
		if protocol {
			traversal.into = prov_mutable_reach(graph, prov_content_at(graph, root, path), prov_type(graph, s.iterable), expr_span(s.iterable))
		}
	} else {
		traversal.into = iterated
	}
	graph.traversals[id] = traversal
}

// What `slot`, of a `&mut` binding, was just set to, also in the source
// (`prov_note_traversal`). What the slot already held is there already.
@(private = "file")
prov_publish_traversal :: proc(
	graph: ^Flow_Graph, traversal: Prov_Traversal, slot: int, sources: []int, span: Span, type: Type_Id, reborrows, replaces_read: bool,
) {
	stored := make([dynamic]int, 0, len(sources), graph.alloc)
	for source in sources {
		if source != slot {
			append(&stored, source)
		}
	}
	if len(stored) == 0 {
		return
	}
	at := graph.prov_slots[slot].path
	if traversal.root != NO_ROOT && traversal.lent {
		for held in prov_content_at(graph, traversal.root, traversal.path) {
			if carrier_may_land_in(graph.k.c, slot_carrier_type(graph, held), type) {
				prov_define_one_content(graph, held, prov_join(graph, prov_one(graph, held), stored[:]), span, reborrows = reborrows, replaces_read = replaces_read)
			}
		}
	} else if traversal.root != NO_ROOT {
		written := prov_concat_path(graph, traversal.path, at)
		prov_define_content(graph, prov_content_at(graph, traversal.root, written), stored[:], span, written, type, preserve_previous = true, reborrows = reborrows, replaces_read = replaces_read)
		return
	}
	if len(traversal.into) == 0 {
		return
	}
	publish := Prov_Event{
		kind = .Publish, span = span, sources = stored[:], into = traversal.into, strips = true, carried = type, lands_by_type = traversal.lent,
		replaces_read = replaces_read,
	}
	if traversal.known {
		publish.path = prov_concat_path(graph, traversal.path, at)
	}
	if type != INVALID_TYPE && type_is_carrier(graph.k.c, type) {
		publish.linked = true
		if reborrows {
			if !replaces_read {
				prov_reborrow(graph, stored[:], type, span = span, copies = true)
			}
			publish.links_copies = true
			graph.has_linked_store = true
		}
	}
	prov_emit(graph, publish)
}

// The storage a borrowed binding names can grow as the facts settle, so its
// write is published into the construction graph's slots with the aliases
// `graph` has at the site.
@(private)
prov_materialize_view_publish :: proc(graph: ^Flow_Graph, op: Prov_Event_View_Publish) {
	output := prov_output(graph)
	if output == graph {
		prov_publish_view_content(graph, prov_root_for_symbol(graph, op.symbol), nil, op.path, op.sources, op.span, op.type, op.through)
		return
	}
	aliases, current, expansion := output.region_aliases, output.current, output.expansion
	output.region_aliases, output.current, output.expansion = graph.region_aliases, graph.current, graph.expansion
	defer output.region_aliases, output.current, output.expansion = aliases, current, expansion
	first := prov_next_event(output)
	prov_publish_view_content(output, prov_root_for_symbol(output, op.symbol), nil, op.path, op.sources, op.span, op.type, op.through)
	if graph.current == NO_BLOCK { return }
	// The events are the materialization's, which replaces the site's.
	emitted := &output.blocks[graph.current].prov
	append(&graph.blocks[graph.current].prov, ..emitted[first:])
	resize(emitted, first)
}

// A borrowed case binding is a name for the subject's payload. Keep its
// carrier writes in that storage as well, so later reads and scope exits see
// them (design.md "Values that contain borrows"). Resolve known aliases before
// publishing; only unresolved storage needs the solver's carrier fallback.
@(private = "file")
prov_publish_view_content :: proc(
	graph: ^Flow_Graph, root: Root_Id, prefix, path: []Proj_Step,
	sources: []int, span: Span, type: Type_Id, through: []int, unique := true,
) {
	if root != NO_ROOT {
		id := graph.roots[int(root)].symbol
		if aliases := graph.region_aliases[id]; len(aliases) > 0 {
			for alias in aliases {
				prov_publish_view_content(graph, alias.root, prov_concat_path(graph, alias.path, prefix),
				                          path, sources, span, type, through, unique && len(aliases) == 1)
			}
			return
		}
		if sym := symbol_of(graph.k.c, id); sym != nil && !type_is_carrier(graph.k.c, sym.type) {
			// Region paths distinguish union tags; carrier shapes use a wildcard
			// for the payload. Convert only the alias prefix, not the leaf path.
			borrowed := make([]Proj_Step, len(prefix), graph.alloc)
			current := sym.type
			exact := unique && path_precision(prefix) == {}
			for step, index in prefix {
				kind := underlying_kind(graph.k.c, current)
				borrowed[index] = kind == .Union ? proj_wild() : step
				if step.kind == .Wild && kind != .Box { exact = false }
				current = prov_type_at(graph.k.c, current, {step})
			}
			written := prov_concat_path(graph, borrowed, path)
			// This is the binding slot's complete content, including any join
			// for a partial write. A selected tag does not make that leaf partial.
			// design.md "Values that contain borrows": a possible target keeps
			// its old borrows, since the write may reach another alias instead.
			prov_define_content(graph, prov_content_at(graph, root, written), sources, span, written, type,
			                    preserve_previous = !exact, replace_matching = exact)
			return
		}
	}
	prov_emit(graph, Prov_Event{kind = .Publish, span = span, sources = sources, into = through, carried = type})
}

// design.md "defer statement": a result is taken before its exit path's
// deferred statements run, and what it borrows must survive them. The caller
// emits a `Live` of the hold after the cleanups.
@(private)
prov_hold_result :: proc(graph: ^Flow_Graph, sources: []int, result_type: Type_Id, span: Span) -> []int {
	if len(sources) == 0 {
		return nil
	}
	held := prov_temp_slot(graph)
	graph.prov_slots[held].returned = true
	prov_reborrow(graph, sources, result_type, held, span)
	prov_emit(graph, Prov_Event{kind = .Def, slot = held, loan = NO_LOAN, sources = sources, span = span})
	return prov_one(graph, held)
}

// design.md "Evaluation order": a value keeps what its carriers held when it
// was evaluated. A mutable carrier is reborrowed, others copied. With
// `keep_reborrows`, a slot that is already a mutable reborrow is kept as it is,
// since the carrier it suspends cannot be written meanwhile.
@(private)
prov_capture :: proc(graph: ^Flow_Graph, slots: []int, span: Span, keep_reborrows := false) -> []int {
	out := make([dynamic]int, 0, len(slots), graph.alloc)
	for slot in slots {
		if keep_reborrows && prov_slot_is_reborrow(graph, slot, mutable_only = true) {
			append(&out, slot)
			continue
		}
		if prov_slot_is_mutable_carrier(graph, slot) {
			append(&out, ..prov_reborrow_traversal(graph, prov_one(graph, slot), span, true))
			continue
		}
		held := prov_hold_slot(graph, slot, span)
		deriving := prov_reborrows_deriving(graph, slot)
		for taken in prov_next_reborrow(graph, &deriving) {
			reborrow := taken^
			reborrow.derived = held
			reborrow.span = span
			prov_add_reborrow(graph, reborrow)
		}
		if prov_slot_may_come_to_reborrow(graph, slot) {
			prov_add_reborrow(graph, Prov_Reborrow{source = slot, derived = held, span = span, passes_on = true, pending = true})
		}
		append(&out, held)
	}
	return out[:]
}

// The slots among `slots` that a later write in the same evaluation will
// redefine, each replaced by a temporary holding what it holds now.
@(private)
prov_capture_slots :: proc(graph: ^Flow_Graph, slots: []int, rewritten: []int, span: Span) -> []int {
	out := make([dynamic]int, 0, len(slots), graph.alloc)
	for slot in slots {
		if !slice.contains(rewritten, slot) {
			append(&out, slot)
			continue
		}
		append(&out, prov_hold_slot(graph, slot, span))
	}
	return out[:]
}

// A temporary holding what `slot` holds now. It keeps the place in a value's
// shape that `slot` stands for, so a later field selection still tells it
// apart from its siblings (design.md "Minimum provenance precision"): the
// first element of `[2]Pair{{"static", source}, {"x", other}}` is captured
// while the second is built, and its `a` must not take `b`'s borrow.
@(private = "file")
prov_hold_slot :: proc(graph: ^Flow_Graph, slot: int, span: Span) -> int {
	held := prov_temp_slot(graph)
	source := graph.prov_slots[slot]
	entry := &graph.prov_slots[held]
	entry.path = source.path
	entry.content_type = source.content_type
	entry.content_shape = source.content_shape
	entry.content_truncated = source.content_truncated
	entry.precision = source.precision
	prov_def_copy(graph, held, slot, span)
	return held
}

// A carrier local read as itself: a conversion such as `[dynamic]T` to `[]T`
// borrows an owner instead. An erased operand's own type is a `dyn` view.
@(private)
prov_view_local :: proc(graph: ^Flow_Graph, e: Expr) -> (ident: ^Expr_Ident, type: Type_Id, ok: bool) {
	named, is_ident := e.(^Expr_Ident)
	if !is_ident {
		return nil, INVALID_TYPE, false
	}
	repr := prov_repr(graph, named)
	if repr.view_from != INVALID_TYPE {
		return nil, INVALID_TYPE, false
	}
	if _, is_carrier := prov_slot_for_symbol(graph, named.symbol); !is_carrier {
		return nil, INVALID_TYPE, false
	}
	return named, repr.erased_from != INVALID_TYPE ? repr.erased_from : repr.type, true
}

// A slice local whose elements are plain data, which reading cannot turn into
// a way to write (design.md "Weakening and reborrows").
@(private)
prov_plain_slice_local :: proc(graph: ^Flow_Graph, e: Expr) -> (^Expr_Ident, bool) {
	ident, type, ok := prov_view_local(graph, e)
	if !ok || underlying_kind(graph.k.c, type) != .Slice {
		return nil, false
	}
	return ident, !type_carries_borrow(graph.k.c, underlying_info(graph.k.c, type).element).any
}

// A place, named or reached through carriers, whose value can be read where it is.
// A conversion such as `[dynamic]T` to `[]T` borrows an owner instead.
@(private)
prov_reads_as_place :: proc(graph: ^Flow_Graph, argument: Expr) -> bool {
	if expr_base(argument) == nil || prov_repr(graph, argument).view_from != INVALID_TYPE {
		return false
	}
	if _, is_ident := argument.(^Expr_Ident); is_ident {
		return true
	}
	_, _, place := prov_place_of(graph, argument)
	if place { return true }
	_, through := prov_input_place(graph, argument).base.(Value_Id)
	return through && prov_reads_plainly_through(graph, argument)
}

// A carrier place passed to a parameter that can write through nothing it
// receives, as `held.items` passed to a `[]int`, or one read out through a
// carrier, as `p^` passed to a `^T`: the call only reads it.
@(private)
prov_argument_only_read :: proc(graph: ^Flow_Graph, argument: Expr, parameter: Type_Id) -> bool {
	c := graph.k.c
	if expr_base(argument) == nil {
		return false
	}
	repr := prov_repr(graph, argument)
	if type_carries_borrow(c, parameter).mutable {
		return false
	}
	// An erased operand's own type is a `dyn` view.
	type := repr.erased_from != INVALID_TYPE ? repr.erased_from : repr.type
	return type_is_carrier(c, type) && prov_reads_as_place(graph, argument)
}

@(private)
prov_temp_slot :: proc(graph: ^Flow_Graph) -> int {
	return prov_add_slot(graph, empty_prov_slot(INVALID_SYMBOL))
}

// Adds a slot and answers its index.
@(private)
prov_add_slot :: proc(graph: ^Flow_Graph, entry: Prov_Slot) -> int {
	append(&graph.prov_slots, entry)
	return len(graph.prov_slots) - 1
}

@(private)
prov_new_loan :: proc(
	graph: ^Flow_Graph,
	root: Root_Id,
	path: []Proj_Step,
	mutable: bool,
	span: Span,
	what: string,
) -> Loan_Id {
	if mutable {
		prov_note_static_write(graph, root, span)
		descriptor := graph.roots[int(root)]
		if descriptor.kind == .Local && descriptor.symbol != INVALID_SYMBOL {
			graph.lent_locals[descriptor.symbol] = true
		}
		// Whatever is written through the loan, the variable may now hold.
		prov_note_proc_store(graph, descriptor.symbol, nil)
	} else {
		prov_note_static_read(graph, root)
	}
	append(&graph.loans, Prov_Loan{root = root, path = path, mutable = mutable, span = span, what = what})
	return Loan_Id(len(graph.loans) - 1)
}

// A loan standing for what caller storage holds, `depth` loads down, of the
// `pointee`th pointee path when that is above zero.
@(private)
prov_new_content_loan :: proc(graph: ^Flow_Graph, root: Root_Id, path: []Proj_Step, mutable: bool, span: Span, what: string, depth: int, pointee := 0) -> Loan_Id {
	loan := prov_new_loan(graph, root, path, mutable, span, what)
	entry := &graph.loans[int(loan)]
	entry.content, entry.depth, entry.pointee = true, depth, pointee
	return loan
}

@(private)
carrier_path_noun :: proc(c: ^Compiler, path: Carrier_Path) -> string {
	return path.truncated ? "borrow" : carrier_noun(c, path.type)
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
	slot, loan := prov_new_borrow_slot(graph, root, path, mutable, span, what, access_block, access_index)
	prov_emit(graph, Prov_Event{kind = .Def, slot = slot, loan = loan, span = span})
	return prov_join(graph, prov_one(graph, slot), prov_root_view(graph, root))
}

// The loan and slot of a fresh borrow, before anything defines the slot.
@(private)
prov_new_borrow_slot :: proc(
	graph: ^Flow_Graph,
	root: Root_Id,
	path: []Proj_Step,
	mutable: bool,
	span: Span,
	what: string,
	access_block := NO_BLOCK,
	access_index := -1,
) -> (slot: int, loan: Loan_Id) {
	// design.md "@(synchronized)": even a read-only borrow of a synchronized
	// field excludes every other access while it lasts.
	loan = prov_new_loan(graph, root, path, mutable || path_is_synchronized(path), span, what)
	slot = prov_temp_slot(graph)
	graph.prov_slots[slot].borrow = Prov_Fresh_Borrow{loan, Prov_Event_At{access_block, access_index}}
	return
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
	reads_only := false,
) -> (block: Block_Id, index: int) {
	if root == NO_ROOT {
		return NO_BLOCK, -1
	}
	if kind != .Read {
		prov_note_static_write(graph, root, span)
	} else {
		prov_note_static_read(graph, root)
	}
	// design.md "@(synchronized)": a synchronizing operation may write the
	// field through any read-only borrow, so even reading it conflicts with one.
	// It is still no write to a global's effect.
	access := kind
	if kind == .Read && path_is_synchronized(path) {
		access = .Write
	}
	// A use through a view binding is reported under the binding's name.
	// Reached through carriers, it uses them only for the payload, as reading
	// it there would.
	name := graph.roots[int(root)].name
	use, found := graph.view_uses[graph.roots[int(root)].symbol]
	if viewed := prov_root_view(graph, root); len(viewed) > 0 {
		event := Prov_Event{kind = .Live, sources = viewed, span = span, name = name}
		if found && use.load {
			event.reads_only = reads_only
		}
		prov_emit(graph, event)
	}
	if found && use.load {
		graph.has_content_load = true
		prov_emit(graph, Prov_Event {
			kind = .Load, slot = prov_temp_slot(graph), into = use.slots, path = use.path, span = span,
			name = name, reads_only = reads_only,
		})
	} else if found {
		prov_emit(graph, Prov_Event{kind = .Live, sources = use.slots, span = span, name = name, reads_only = reads_only})
	}
	prov_emit(graph, Prov_Event {
		kind   = .Access,
		root   = root,
		path   = path,
		access = access,
		span   = span,
		verb   = verb,
	})
	if graph.current == NO_BLOCK {
		return NO_BLOCK, -1
	}
	return graph.current, len(graph.blocks[graph.current].prov) - 1
}

@(private)
prov_extend :: proc(graph: ^Flow_Graph, path: []Proj_Step, step: Proj_Step) -> []Proj_Step {
	return path_extend(path, step, graph.alloc)
}

@(private)
prov_concat_path :: proc(graph: ^Flow_Graph, prefix, path: []Proj_Step) -> []Proj_Step {
	return path_concat(prefix, path, graph.alloc)
}

// A place read by its root, when it has one.
@(private = "file")
prov_read_rooted :: proc(graph: ^Flow_Graph, e: Expr) -> (content: []int, ok: bool) {
	root, path, rooted := prov_place_of(graph, e)
	if !rooted {
		return nil, false
	}
	prov_walk_subscripts(graph, e)
	prov_access(graph, root, path, .Read, expr_span(e))
	// The read yields the place's content, with no lasting borrow.
	return prov_read_content(graph, root, path, prov_type(graph, e), expr_span(e)), true
}

// A place read through the carriers reaching it, when it has any.
@(private = "file")
prov_read_carried :: proc(graph: ^Flow_Graph, e: Expr) -> (content: []int, ok: bool) {
	only := prov_read_is_reads_only(graph.k.c, prov_type(graph, e))
	carriers, path, through := prov_read_through_carrier(graph, e, only)
	if !through {
		return nil, false
	}
	return prov_load_content(graph, carriers, path, prov_type(graph, e), expr_span(e), only, place = e), true
}

@(private)
prov_read_deref :: proc(graph: ^Flow_Graph, v: ^Expr_Postfix) -> []int {
	// design.md "Owned values": reading `b^` reads the box, as reading `xs[i]`
	// reads a dynamic array.
	if v.boxed {
		if content, ok := prov_read_rooted(graph, v); ok {
			return content
		}
		if content, ok := prov_read_carried(graph, v); ok {
			return content
		}
		loans := walk_flow_expr(graph, v.operand)
		return prov_project_content(graph, loans, prov_type(graph, v.operand), {proj_wild()}, prov_type(graph, v), v.span)
	}
	only := prov_read_is_reads_only(graph.k.c, prov_type(graph, v))
	carriers, _, _ := prov_read_through_carrier(graph, v, only)
	return prov_load_content(graph, carriers, nil, prov_type(graph, v), v.span, only)
}

@(private)
prov_read_selector :: proc(graph: ^Flow_Graph, v: ^Expr_Selector) -> []int {
	if content, ok := prov_read_rooted(graph, v); ok {
		return content
	}
	if content, ok := prov_read_carried(graph, v); ok {
		return content
	}
	loans := walk_flow_expr(graph, v.operand)
	if v.resolution.kind == .Field && v.operand != nil {
		return prov_project_content(
			graph, loans, prov_type(graph, v.operand), {prov_field_step(graph, v)}, prov_type(graph, v), v.span,
		)
	}
	return nil
}

@(private)
prov_read_index :: proc(graph: ^Flow_Graph, v: ^Expr_Index) -> []int {
	if v.resolution.kind == .User_Operator {
		return prov_call(graph, prov_operator_call(graph, v))
	}
	// Reading a map's element clones it out, which writing one does not.
	if len(v.bound) == 0 && underlying_kind(graph.k.c, prov_type(graph, v.operand)) == .Map {
		prov_copy_effects(graph, prov_type(graph, v), v.span)
	}
	if content, ok := prov_read_rooted(graph, v); ok {
		return content
	}
	// An element of plain data read out of a slice local only reads the
	// carrier (design.md "Weakening and reborrows").
	if ident, plain := prov_plain_slice_local(graph, v.operand); plain && len(v.bound) == 0 &&
	   !prov_indices_may_write(graph.k.c, v.indices) {
		carriers := prov_read_ident(graph, ident, reads_only = true)
		for index in v.indices {
			walk_flow_expr(graph, index)
		}
		return prov_load_content(graph, carriers, nil, prov_type(graph, v), v.span)
	}
	if content, ok := prov_read_carried(graph, v); ok {
		return content
	}
	loans := walk_flow_expr(graph, v.operand)
	for index in v.indices {
		loans = prov_join(graph, loans, walk_flow_expr(graph, index))
	}
	return prov_project_content(
		graph, loans, prov_type(graph, v.operand), prov_index_path(graph, v), prov_type(graph, v), v.span,
	)
}

// What a `return` hands back: the borrows it carries and what they reach escape,
// and the slots holding them stay live through the cleanups. `graph.returning`
// names the value while they run, which the caller restores.
@(private)
prov_return_value :: proc(graph: ^Flow_Graph, value: ^Return_Value) -> []int {
	// design.md "`inout` results": `return inout place` hands back a
	// borrow of the place, which must outlive the frame.
	sources: []int
	if value.is_inout {
		sources = prov_borrow_place(graph, value.expr, true, expr_span(value.expr), "`inout` result")
	} else {
		sources = walk_flow_expr(graph, value.expr)
	}
	returned := prov_input_value(graph, value.expr)
	if !value.is_inout {
		graph.returning = new_clone(Prov_Returning{value = returned, span = expr_span(value.expr)}, graph.alloc)
	}
	result_type := prov_type(graph, value.expr)
	if sym := symbol_of(graph.k.c, graph.literal.symbol); sym != nil {
		result_type = sym.result
	}
	contents := prov_load_deep(graph, sources, expr_span(value.expr))
	prov_event(graph, Prov_Event_Escape{sources = sources, into = contents, returning = {value = returned, result = result_type, span = expr_span(value.expr)}})
	return prov_hold_result(graph, prov_join(graph, sources, contents), result_type, expr_span(value.expr))
}

// What an `or_return` propagates, as `prov_return_value` for a `return`.
@(private)
prov_or_return_escape :: proc(graph: ^Flow_Graph, v: ^Expr_Postfix, operand_loans: []int) -> []int {
	proc_symbol := symbol_of(graph.k.c, graph.literal.symbol)
	if proc_symbol == nil || proc_symbol.result == INVALID_TYPE {
		return nil
	}
	shape, operand_fallible := fallible_of(graph.k.c, prov_type(graph, v.operand))
	target, target_fallible := fallible_of(graph.k.c, proc_symbol.result)
	if !operand_fallible || !target_fallible {
		return nil
	}
	from := shape.failure_type
	into := target.failure_type
	escaping := prov_payload_content(graph, operand_loans, prov_type(graph, v.operand), from, v.span)
	if failure_assignment_borrows(graph.k.c, from, into) {
		if root, path, is_place := prov_place_of(graph, v.operand); is_place {
			block, index := prov_access(graph, root, path, .Read, v.span)
			escaping = prov_join(graph, escaping, prov_borrow(graph, root, path, false, v.span, "view", block, index))
		} else {
			escaping = prov_join(graph, escaping, prov_borrow(graph, prov_temp_root(graph, v.span), nil, false, v.span, "view"))
		}
	}
	contents := prov_load_deep(graph, escaping, v.span)
	propagated := prov_error_form(graph, v)
	graph.returning = new_clone(Prov_Returning{propagated = propagated, result = proc_symbol.result, span = v.span}, graph.alloc)
	prov_event(graph, Prov_Event_Escape{sources = escaping, into = contents, returning = graph.returning^})
	return prov_hold_result(graph, prov_join(graph, escaping, contents), proc_symbol.result, v.span)
}

// What a level of a `foreach` pattern takes apart: a map entry's and an
// `indexed()` pair's fields are no fields of what the source stores.
@(private = "file")
Foreach_Pattern :: enum { Value, Map_Entry, Indexed_Pair }

@(private = "file")
foreach_element_pattern :: proc(s: ^Stmt_Foreach) -> Foreach_Pattern {
	if s.indexed {
		return .Indexed_Pair
	}
	return s.kind == .Map ? .Map_Entry : .Value
}

// Binds what each of a `foreach`'s bindings holds at a step.
@(private)
prov_bind_foreach :: proc(graph: ^Flow_Graph, s: ^Stmt_Foreach, iterated, elements, through: []int) {
	walk_foreach_binding_provenance(graph, s, s.bindings, iterated, elements, through, s.element_type, foreach_element_pattern(s), nil)
}

// `below` is where this level of the pattern is inside the element, which
// a `&mut` leaf names (`prov_note_traversal`).
@(private = "file")
walk_foreach_binding_provenance :: proc(
	graph: ^Flow_Graph, s: ^Stmt_Foreach, bindings: []Foreach_Binding, iterated, elements, through: []int,
	logical: Type_Id, pattern: Foreach_Pattern, below: []Proj_Step,
) {
	if len(bindings) == 1 && len(bindings[0].group) > 0 {
		walk_foreach_binding_provenance(graph, s, bindings[0].group, iterated, elements, through, logical, pattern, below)
		return
	}
	// design.md "Destructuring": a padding field fills no binding.
	fields: []Symbol_Id
	if info := underlying_info(graph.k.c, logical); len(bindings) > 1 && info != nil && info.kind == .Struct {
		fields = named_fields(graph.k.c, info)
	}
	for binding, position in bindings {
		part, part_pattern, at := logical, pattern, below
		if position < len(fields) {
			field := symbol_of(graph.k.c, fields[position])
			part, part_pattern = field.type, .Value
			switch pattern {
			case .Value:
				at = prov_extend(graph, below, proj_field(int(field.index)))
			case .Map_Entry:
				at = prov_extend(graph, below, proj_field(position == 0 ? PROJ_MAP_KEY : PROJ_MAP_VALUE))
			case .Indexed_Pair:
				if s.kind == .Map { part_pattern = .Map_Entry }
			}
		}
		if len(binding.group) > 0 {
			walk_foreach_binding_provenance(graph, s, binding.group, iterated, elements, through, part, part_pattern, at)
			continue
		}
		// What a leaf holds is what the element holds. Only a borrow of it takes
		// the traversal's own loans, which the view below gives it.
		loans := iterated
		if s.kind != .Protocol && len(elements) > 0 {
			loans = elements
		}
		// standard-library.md "Chunks of a mutable slice": a chunk takes the view's loans
		// without reborrowing the view, so the view advances while earlier
		// chunks are held. The chunks are disjoint by construction.
		if foreach_yields_chunks(graph.k.c, s) && prov_bind_chunk(graph, binding.symbol, loans, expr_span(s.iterable)) {
			// A chunk views the storage the sliced view does, so it is in that
			// storage's regions (design.md "Allocator regions and region provenance").
			prov_bind_element_region(graph, binding.symbol, prov_input_value(graph, s.iterable))
			continue
		}
		// A lent element is the stored carrier, not a copy of it, so it does not
		// reborrow what the container holds (design.md "Borrowing iteration"):
		// reading it reads that carrier, which the iterator loan already guards.
		sym := symbol_of(graph.k.c, binding.symbol)
		lent := sym != nil && sym.borrowed_binding != .None
		carrier := s.kind != .Protocol && len(elements) > 0 && type_is_carrier(graph.k.c, prov_type(graph, s.iterable))
		// design.md "Procedure result contracts": the value of a carrier's lent
		// element is what `values[i]` would load through the carrier, so a copy
		// of it keeps only the element's own borrows; reading the binding still
		// uses the carrier through the view below.
		if lent && carrier {
			loans = prov_load_content(
				graph, elements, binding.is_ref ? at : nil, sym.type, expr_span(s.iterable),
				reads_only = prov_read_is_reads_only(graph.k.c, sym.type),
			)
			if binding.is_ref {
				for slot in loans {
					graph.prov_slots[slot].names_element = true
				}
			}
		}
		// The leaf starts as what the element holds, which only a store through
		// it afterwards adds to.
		delete_key(&graph.traversals, binding.symbol)
		prov_forget_region_binding(graph, binding.symbol)
		prov_bind_value(graph, binding.symbol, loans, expr_span(s.iterable), copies = !lent)
		// A user's iterator says nothing of where in the source it lends.
		element := s.kind == .Protocol ? nil : prov_concat_path(graph, prov_extend(graph, nil, proj_wild()), at)
		prov_bind_element_region(graph, binding.symbol, prov_input_value(graph, s.iterable), element, binding.is_ref)
		// A lent or mutable element is the source's storage (design.md "Borrowing
		// iteration"), so the binding views what `&iterable` would; the loop's own
		// reads already hold that.
		if lent {
			viewed := iterated
			if carrier {
				viewed = elements
			} else if len(through) > 0 {
				viewed = through
			} else if s.kind != .Protocol {
				if carriers, _, reached := prov_read_through_carrier(graph, s.iterable); reached && len(carriers) > 0 {
					viewed = carriers
				}
			}
			prov_bind_view(graph, binding.symbol, viewed, lends = !foreach_is_place_loop(s))
		}
		if binding.is_ref {
			prov_note_traversal(graph, s, binding.symbol, at, element, iterated, elements, through)
		}
	}
}

@(private = "file")
foreach_yields_chunks :: proc(c: ^Compiler, s: ^Stmt_Foreach) -> bool {
	next := symbol_of(c, s.next_symbol)
	return s.kind == .Protocol && next != nil && next.synth == .Chunks_Next
}

// One name a case binds: the payload, or with `slot` one of its fields.
@(private)
prov_bind_case_name :: proc(
	graph: ^Flow_Graph, s: ^Stmt_Switch, symbol: Symbol_Id, is_ref: bool, sources: []int, span: Span,
	consumes: bool, variants: []int, shared_view: ^Prov_Case_View, slot := -1,
) {
	// Over a place, the binding is the stored payload, not a copy of it.
	// A deferred switch can be expanded more than once in the same graph.
	prov_forget_region_binding(graph, symbol)
	prov_bind_value(graph, symbol, sources, span, copies = consumes)
	prov_bind_case_region(graph, symbol, prov_input_value(graph, s.subject), variants, slot)
	// A place subject keeps its payload, so the binding views its storage;
	// a consumed one is the binding's own, which ends with its case
	// (design.md "Switch ownership").
	if !consumes {
		// design.md "Switch ownership": `cursor = &mut node.next` keeps a
		// loan of this case's `node`, which the next pass binds afresh.
		if is_ref {
			prov_emit(graph, Prov_Event{kind = .Rebind, root = prov_root_for_symbol(graph, symbol), span = span})
		}
		prov_bind_view(graph, symbol, prov_subject_view(graph, s.subject, is_ref, slot, shared_view))
		if !is_ref {
			prov_note_view_use(graph, symbol, s.subject, slot)
		}
	} else {
		root := prov_root_for_symbol(graph, symbol)
		append(&graph.in_scope, Flow_Cleanup{kind = .Prov_Root, root = root, span = span})
	}
}

// ------------------------------------------------------- statement hooks --

@(private)
prov_read_ident :: proc(graph: ^Flow_Graph, v: ^Expr_Ident, reads_only := false) -> []int {
	if root := prov_root_for_symbol(graph, v.symbol); root != NO_ROOT {
		prov_access(graph, root, nil, .Read, v.span, reads_only = reads_only)
	}
	if slot, is_carrier := prov_slot_for_symbol(graph, v.symbol); is_carrier {
		sources := prov_one(graph, slot)
		prov_emit(graph, Prov_Event {
			kind = .Live, sources = sources, span = v.span, reads_only = reads_only,
		})
		return sources
	}
	if content := prov_content_slots(graph, v.symbol); len(content) > 0 {
		prov_emit(graph, Prov_Event{kind = .Live, sources = content, span = v.span, reads_only = reads_only})
		return content
	}
	return nil
}

@(private)
prov_invalidate :: proc(graph: ^Flow_Graph, place: Expr, span: Span, verb: string) -> (carriers: []int, below: []Proj_Step, through: bool) {
	if root, path, ok := prov_place_of(graph, place); ok {
		prov_walk_subscripts(graph, place)
		prov_access(graph, root, path, .Invalidate, span, verb)
		return
	}
	walk_flow_expr(graph, place)
	return prov_write_through_place(graph, place, span)
}

// A borrow of `operand` as a place, for `&operand` and `return inout operand`.
@(private)
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
		if loans, through := prov_borrow_through(graph, operand, mutable, span, what); through {
			return loans
		}
		if place, is_inout := prov_inout_result_place(graph, operand); is_inout {
			return place
		}
		loans := walk_flow_expr(graph, operand)
		if !prov_expr_is_temporary(operand) {
			return loans
		}
		// A borrow of a temporary cannot escape its expression (design.md), even
		// when the temporary also holds borrows, as `&box(view)^` does.
		temporary := prov_borrow(graph, prov_temp_root_of(graph, operand, loans), nil, mutable, span, what)
		return prov_join(graph, loans, temporary)
	}
	prov_walk_subscripts(graph, operand)
	access_block, access_index := prov_access(graph, root, path, mutable ? .Write : .Read, span)
	if held := prov_carrier_slots(graph, operand); len(held) > 0 {
		prov_emit(graph, Prov_Event{kind = .Live, sources = held, span = span, reads_only = !mutable})
	}
	return prov_borrow(graph, root, path, mutable, span, what, access_block, access_index)
}

// design.md "Weakening and reborrows": a borrow of a place reached through
// carriers is a place loan of it, read-only or mutable, which an access through
// any carrier naming that storage at an overlapping place conflicts with while
// the borrow is in use. A read-only borrow only reads the carriers it goes
// through, which another read-only reborrow of them allows; a mutable one writes
// what it borrows, which covers the read. A read-only destination weakens a
// mutable one (`prov_through_marker`). A slice, given as `bounds`, has its
// bounds evaluated after the carriers. False when `place` is reached through no
// carrier.
@(private = "file")
prov_borrow_through :: proc(graph: ^Flow_Graph, place: Expr, mutable: bool, span: Span, what: string, bounds: ^Expr_Slice = nil) -> (loans: []int, through: bool) {
	walk := make([dynamic]Prov_Event_At, 0, 0, graph.alloc)
	carriers, below, reached := prov_read_through_carrier(graph, place, reads_only = !mutable, walk = &walk, reads = !mutable)
	if !reached {
		return nil, false
	}
	if bounds != nil {
		prov_walk_slice_bounds(graph, bounds)
	}
	at, end := -1, -1
	if mutable {
		at = prov_write_through(graph, carriers, below, span, "mutable borrow", place)
		end = at < 0 ? -1 : prov_next_event(graph)
	}
	held := prov_next_event(graph)
	prov_use_held(graph, carriers, below, prov_type(graph, place), span, !mutable)
	prov_note_walk_reads(graph, &walk, held)
	marker := prov_through_marker(graph, at, end, walk[:])
	return prov_join(graph, prov_place_loan(graph, carriers, below, mutable, what, place, borrows = true), marker), true
}

// A slot standing for a borrow through carriers (`Prov_Through_Borrow`):
// its `.Through` events from `at` up to `end`, -1 for both when it writes
// nothing, and the reads of the carriers it went through. Weakened to a read-only
// destination, as `look(&mut p[0])` passes it, the borrow writes nothing and only
// reads the carriers, which the slot lets `prov_reborrow` settle.
@(private = "file")
prov_through_marker :: proc(graph: ^Flow_Graph, at, end: int, walk: []Prov_Event_At) -> []int {
	if graph.current == NO_BLOCK {
		return nil
	}
	marker := prov_temp_slot(graph)
	graph.prov_slots[marker].borrow = Prov_Through_Borrow{Prov_Event_At{graph.current, at}, end, walk}
	return prov_one(graph, marker)
}

// design.md "Weakening and reborrows": a borrow of a place reaches the
// carriers it holds, so it uses them, and `both(held, &mut held)` cannot hand
// on `held` while it is reborrowed for the call, nor `&mut list^.head` the
// carrier a copy of `list^.head` reborrows. Through `carriers`, those are
// loaded from `path` below their pointee.
@(private = "file")
prov_use_held :: proc(graph: ^Flow_Graph, carriers: []int, path: []Proj_Step, type: Type_Id, span: Span, reads_only: bool) {
	if len(carriers) == 0 || !type_carries_borrow(graph.k.c, type).mutable {
		return
	}
	graph.has_content_load = true
	prov_emit(graph, Prov_Event{kind = .Load, slot = prov_temp_slot(graph), into = carriers, path = path, span = span, reads_only = reads_only})
}

@(private = "file")
prov_walk_slice_bounds :: proc(graph: ^Flow_Graph, v: ^Expr_Slice) {
	if v.lo != nil {
		walk_flow_expr(graph, v.lo)
	}
	if v.hi != nil {
		walk_flow_expr(graph, v.hi)
	}
}

@(private)
prov_slice :: proc(graph: ^Flow_Graph, v: ^Expr_Slice) -> []int {
	if v.resolution.kind == .User_Operator {
		return prov_call(graph, prov_operator_call(graph, v))
	}
	mutable := slice_is_mutable(graph.k.c, prov_type(graph, v))
	// An array, string, or dynamic array is sliced out of its own root (design.md
	// "Dynamic arrays"); reslicing a carrier keeps its loans.
	operand_kind := underlying_kind(graph.k.c, prov_type(graph, v.operand))
	array := operand_kind == .Array || operand_kind == .String || operand_kind == .Dynamic_Array
	if root, path, ok := prov_place_of(graph, v.operand); ok && array {
		prov_walk_subscripts(graph, v.operand)
		prov_walk_slice_bounds(graph, v)
		full := prov_extend(graph, path, prov_range_step(graph, v))
		access_block, access_index := prov_access(graph, root, full, mutable ? .Write : .Read, v.span)
		return prov_borrow(
			graph, root, full, mutable, v.span, carrier_noun(graph.k.c, prov_type(graph, v)),
			access_block, access_index,
		)
	}
	// Storage reached through a pointer or view borrows what that carrier names,
	// as `&p.items` does.
	if array {
		what := carrier_noun(graph.k.c, prov_type(graph, v))
		if loans, through := prov_borrow_through(graph, v.operand, mutable, v.span, what, v); through {
			return loans
		}
	}
	source: []int
	if ident, plain := prov_plain_slice_local(graph, v.operand); plain && !mutable {
		source = prov_read_ident(graph, ident, reads_only = true) // a read-only view only reads
	} else {
		source = walk_flow_expr(graph, v.operand)
	}
	prov_walk_slice_bounds(graph, v)
	// Reslicing a carrier keeps its loans; slicing an owner also borrows it, and
	// a temporary owner such as `[dynamic]int{1, 2}` ends with its statement
	// unless a local's value extends it.
	if array && prov_expr_is_temporary(v.operand) {
		temporary := prov_borrow(graph, prov_temp_root_of(graph, v.operand, source), nil, mutable, v.span, "slice")
		return prov_join(graph, source, temporary)
	}
	return source
}

// design.md "Slice literals": the hidden array is always extended, an owner
// ending with its block, and a named array's `&mut a[:]` lends as this literal
// lends it. Its content is held by slots of the array's shape, so a store through
// the slice lands in or replaces one element's, and a load reads what it holds
// now. A slice of it holds only its loan.
@(private)
prov_slice_literal :: proc(graph: ^Flow_Graph, literal: ^Expr_Composite, mutable: bool) -> []int {
	span := literal.span
	backing := prov_repr(graph, literal).backing
	storage := prov_storage_id(graph, Written_Storage{temporary = &literal.base, type = backing}, .Slice_Literal)
	root := prov_root_for_storage(graph, storage)
	graph.roots[int(root)].kind = .Slice_Literal
	graph.roots[int(root)].name = "this slice literal"
	slots := graph.roots[int(root)].slots
	if slots == nil {
		slots = prov_temp_content(graph, backing)
		for slot in slots {
			graph.prov_slots[slot].kind = .Literal
			graph.prov_slots[slot].name = "this slice literal's element"
		}
		graph.roots[int(root)].slots = slots
		graph.has_content_load ||= len(slots) > 0
	}
	prov_composite_content(graph, literal, slots, backing)
	// Its elements are dropped with the block's locals, so their drop hooks run
	// there and read what the elements borrow then, even after the slice
	// that viewed them was overwritten (design.md "Temporaries and procedure
	// boundaries").
	graph.roots[int(root)].extended = true
	graph.roots[int(root)].dropped = backing
	for element, index in literal.elements {
		if element.value == nil { continue }
		copies := index < len(literal.element_clones) && literal.element_clones[index]
		prov_define_value_regions(graph, root, {prov_array_element_step(literal, index)}, prov_input_value(graph, element.value), copies = copies)
	}
	append(&graph.in_scope, Flow_Cleanup{kind = .Prov_Root, root = root, span = span})
	// All of the array, as `a[:]` lends it, which tells the elements apart.
	count := underlying_info(graph.k.c, backing).count
	path := count > 0 ? prov_extend(graph, nil, proj_range(0, i64(count))) : nil
	return prov_borrow(graph, root, path, mutable, span, "slice")
}

// Iterating a place borrows it, mutably for a `ref` binding.
@(private)
prov_iterate :: proc(graph: ^Flow_Graph, s: ^Stmt_Foreach, iterated: []int) -> []int {
	iterable := s.iterable
	if type_is_carrier(graph.k.c, prov_type(graph, iterable)) {
		prov_reach(graph, iterated, expr_span(iterable))
	}
	mutable := foreach_is_place_loop(s)
	// A mutable carrier is reborrowed by the traversal instead: the elements live
	// in what it views, not in the variable.
	if type := prov_type(graph, iterable); carrier_is_mutable(graph.k.c, type) && !type_is_region_provider(graph.k.c, type) {
		return iterated
	}
	span := expr_span(s.iterable)
	root, path, ok := prov_place_of(graph, iterable)
	if !ok {
		// design.md "Temporary roots": a temporary owner lives for the whole
		// statement and lends its elements like any other source.
		if (s.borrows || mutable) && prov_expr_is_temporary(iterable) && !type_is_carrier(graph.k.c, prov_type(graph, iterable)) {
			return prov_join(graph, iterated, prov_borrow(graph, prov_temp_root(graph, span), nil, mutable, span, "iterator"))
		}
		return iterated
	}
	prov_access(graph, root, path, mutable ? .Write : .Read, span)
	return prov_join(graph, iterated, prov_borrow(graph, root, path, mutable, span, "iterator"))
}

// A protocol loop's iterator is dropped with the loop, like an extended temporary
// nothing can name.
@(private)
prov_note_iterator_drop :: proc(graph: ^Flow_Graph, s: ^Stmt_Foreach) {
	span := expr_span(s.iterable)
	root := prov_new_root(graph, .Temporary, span, "this iterator")
	graph.roots[int(root)].extended = true
	graph.roots[int(root)].dropped = s.iterator_type
	append(&graph.in_scope, Flow_Cleanup{kind = .Prov_Root, root = root, span = span})
}

// A root that ends with the statement that created it.
@(private)
prov_temp_root :: proc(graph: ^Flow_Graph, span: Span) -> Root_Id {
	root := prov_new_root(graph, .Temporary, span, "this temporary")
	append(&graph.temp_roots, root)
	return root
}

// The root of the temporary `e` holds: one ending with its block when the
// statement extends it (design.md "Temporaries and procedure boundaries"), and
// with the statement otherwise. `content` is what the borrowed value carries.
@(private)
prov_temp_root_of :: proc(graph: ^Flow_Graph, e: Expr, content: []int) -> Root_Id {
	span := expr_span(e)
	extends := expr_base(e).extended
	storage := prov_storage_id(graph, Written_Storage{temporary = expr_base(e), type = prov_type(graph, e)})
	root := prov_root_for_storage(graph, storage)
	if extends {
		append(&graph.in_scope, Flow_Cleanup{kind = .Prov_Root, root = root, span = span})
	} else {
		append(&graph.temp_roots, root)
	}
	extended := &graph.roots[int(root)]
	extended.extended = extends
	// Dropped with the block's locals, so its drop hooks run there and read
	// what it borrows then, as a named local's would (design.md "Global write
	// effects", "Capabilities and the one rule").
	holder := extended_temporary(e)
	extended.dropped = prov_type(graph, holder)
	if erased := prov_repr(graph, holder).erased_from; erased != INVALID_TYPE {
		extended.dropped = erased
	}
	if type_is_managed(graph.k.c, extended.dropped) && !expression_is_borrowed_place(holder) {
		extended.owner = holder
	}
	prov_temp_root_content(graph, root, prov_type(graph, e), content, span)
	if extends {
		held := content
		if holder != e {
			held = prov_join(graph, held, graph.extended_content[expr_base(holder)])
		}
		if len(held) > 0 && type_drop_runs_hook(graph.k.c, extended.dropped) {
			slot := prov_temp_slot(graph)
			prov_emit(graph, Prov_Event{kind = .Def, slot = slot, loan = NO_LOAN, sources = held, span = span})
			graph.roots[int(root)].content = slot
		}
	}
	prov_define_value_regions(graph, root, nil, prov_input_value(graph, e))
	return root
}

// design.md "Procedure result contracts": a load through a borrow of a temporary
// reads what the temporary holds, as one through a borrow of a named local reads
// the local's content, and never stands for the temporary itself. Its root holds
// `content`, what walking the value gave, in slots of its type's carrier shape, as
// a slice literal's root does (`prov_slice_literal`), so `name(&View{text})`
// borrows what `text` lends and not the `View` that ends with the statement.
@(private = "file")
prov_temp_root_content :: proc(graph: ^Flow_Graph, root: Root_Id, type: Type_Id, content: []int, span: Span) {
	if len(content) == 0 {
		return
	}
	slots := graph.roots[int(root)].slots
	if slots == nil {
		slots = prov_temp_content(graph, type)
		if len(slots) == 0 {
			return
		}
		graph.roots[int(root)].slots = slots
		graph.has_content_load = true
	}
	prov_define_content(graph, slots, content, span, value_type = type)
}

// The temporary that holds the borrowed value `e`: a field, an element, or a
// box's payload is part of it. An erased value's own type is its source's.
@(private = "file")
extended_temporary :: proc(e: Expr) -> Expr {
	node := e
	for {
		#partial switch v in node {
		case ^Expr_Selector:
			if v.resolution.kind == .Field {
				node = v.operand
				continue
			}
		case ^Expr_Index:
			if v.resolution.kind != .User_Operator {
				node = v.operand
				continue
			}
		case ^Expr_Postfix:
			if v.boxed {
				node = v.operand
				continue
			}
		}
		break
	}
	return node
}

// A value no name holds, which ends with its statement: a call or literal
// result, an operator's (`a + "yz"`), a conditional's or `or_else`'s, or a
// moved value. A field or element of one is part of it, so `build().items[:]`
// ends with its statement too.
@(private)
prov_expr_is_temporary :: proc(e: Expr) -> bool {
	#partial switch v in e {
	case ^Expr_Composite, ^Expr_Call, ^Expr_Cond, ^Expr_Or_Else, ^Expr_Move, ^Expr_Propagated_Error:
		return true
	case ^Expr_Binary:
		return v.value_category != .Place // a user operator may return a place
	case ^Expr_Unary:
		return v.resolution.kind == .User_Operator && v.value_category != .Place
	case ^Expr_Slice:
		return v.resolution.kind == .User_Operator && v.value_category != .Place
	case ^Expr_Postfix:
		// A temporary box's payload ends with the box.
		return v.op == .Or_Return || (v.boxed && prov_expr_is_temporary(v.operand))
	case ^Expr_Selector:
		// `pkg.name` is a whole global, not a field of its operand.
		return v.resolution.kind != .Value && prov_expr_is_temporary(v.operand)
	case ^Expr_Index:
		if v.resolution.kind == .User_Operator {
			return v.value_category != .Place
		}
		return prov_expr_is_temporary(v.operand)
	}
	return false
}

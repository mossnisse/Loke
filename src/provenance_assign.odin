// Declarations and assignments: what a local or a place is given, and the
// stores through carriers an assignment publishes.
package lokec

import "core:fmt"

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
		projected := -1
		source: []Proj_Step
		if d.destructure.active {
			projected = prov_destructure_index(graph.k.c, &d.destructure, symbol_index)
			source = prov_extend(graph, nil, proj_field(projected))
		}
		clones := d.destructure.active ? d.destructure.clones : d.value_clones
		prov_declare_region(graph, id, sym, prov_input_value(graph, initializer), projected, symbol_index < len(clones) && clones[symbol_index])
		prov_note_written_alias(graph, id, initializer, source = source)
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
		prov_reborrow(graph, sources, sym.type, slot, expr_span(initializer) if initializer != nil else sym.span, copies = true)
		if !d.destructure.active && initializer != nil {
			prov_note_reslice(graph, slot, initializer)
		}
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
@(private)
prov_declare_region :: proc(
	graph: ^Flow_Graph,
	id: Symbol_Id,
	sym: ^Symbol,
	value: Value_Id,
	projected: int,
	copies: bool,
) {
	prov_effect_scope(
		graph, prov_effect_active(graph) && prov_effect_symbol_relevant(graph, id),
		Prov_Effect_Declare{id, value, projected, copies},
	)
	initializer := prov_value(graph, value).origin
	source: []Proj_Step
	if projected >= 0 {
		source = prov_extend(graph, nil, proj_field(projected))
	}
	initializer_region := Region_Set{}
	if initializer != nil && type_is_carrier(graph.k.c, sym.type) && !type_is_region_provider(graph.k.c, sym.type) {
		initializer_region = prov_storage_region(graph, value)
	} else if initializer != nil {
		initializer_region = prov_result_region_at(graph, value, source)
	}
	// A provider moved in keeps its region, and so its token.
	if initializer != nil && sym.duration == .None && projected < 0 {
		prov_declare_moved_providers(graph, id, value)
	}
	if type_is_region_provider(graph.k.c, sym.type) && sym.duration == .None {
		prov_declare_provider(graph, id, initializer != nil, initializer_region)
		return
	}
	if type_is_carrier(graph.k.c, sym.type) {
		if initializer != nil {
			prov_merge_region_of(graph, id, initializer_region)
		}
		return
	}
	// A record holding an allocator handle keeps its region as an owner does
	// (design.md "Allocator regions and region provenance"), but owns nothing a
	// reset would strand.
	if !prov_type_has_region(graph.k.c, sym.type) {
		return
	}
	set := Region_Set{}
	// An explicit `via` allocator decides the region (design.md).
	if written := symbol_via_allocator(graph.k.c, id); written != nil {
		// An incoming owner keeps its allocator. Only an eager binding of an
		// empty container needs a policy fact of its own; copies and nonempty
		// literals already query the allocator they actually use.
		empty := initializer == nil
		if literal, ok := prov_value(graph, value).form.(Prov_Form_Composite); ok { empty = len(literal.elements) == 0 }
		if empty && type_is_container(graph.k.c, sym.type) { region_merge(&set, prov_region_of(graph, prov_input_value(graph, written))) }
	}
	if initializer != nil {
		// A record's handles and owners keep their own field regions rather
		// than making every field depend on the whole initializer.
		prov_define_value_regions(graph, prov_root_for_symbol(graph, id), nil, value, source, copies, id)
	}
	// An owner copied from a place may be cloned.
	if initializer != nil && clone_may_allocate(graph.k.c, sym.type) && expression_is_borrowed_place(initializer) {
		cloned := prov_destination_allocator(graph, id)
		region_merge(&cloned, initializer_region)
		prov_note_allocator_use(graph, cloned, sym.span, owned = true)
	}
	if !region_is_empty(set) {
		prov_define_region_content(graph, prov_root_for_symbol(graph, id), nil, set, own = true)
	}
	if sym.duration != .None {
		owned := prov_copied_owner_region(graph, value, source, copies, prov_destination_allocator(graph, id))
		region_merge(&owned, set)
		prov_check_lasting_storage(graph, sym, owned)
	}
}

// design.md "Allocator regions and region provenance": a local `mem.Arena` or
// `mem.Scratch` is a region of its own, with what it was initialized from as a
// parent.
@(private = "file")
prov_declare_provider :: proc(graph: ^Flow_Graph, id: Symbol_Id, initialized: bool, initializer_region: Region_Set) {
	prov_merge_region_of(graph, id, prov_provider_region(graph, id))
	if initialized && !region_is_empty(initializer_region) {
		prov_merge_parent(graph, id, initializer_region)
	}
}

// A `static` or `thread_local` local outlives a region the body received or made.
@(private = "file")
prov_check_lasting_storage :: proc(graph: ^Flow_Graph, sym: ^Symbol, owned: Region_Set) {
	if region_is_parameter_backed(owned) || region_has_local(owned) {
		prov_emit(graph, Prov_Event {
			kind   = .Region_Escape,
			span   = sym.span,
			verb   = fmt.aprintf("`%s`", identifier_text(graph.k.c, sym.name), allocator = graph.alloc),
			name   = storage_phrase(sym.duration),
			region = owned,
		})
	}
}

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
	// A padding field fills no binding, so the field's own slot is projected.
	slot := prov_destructure_index(graph.k.c, plan, index)
	return prov_project_content(graph, sources, plan.record, {proj_field(slot)}, field_type, span)
}

@(private = "file")
prov_destructure_index :: proc(c: ^Compiler, plan: ^Destructure, index: int) -> int {
	if field := symbol_of(c, plan.fields[index]); field != nil { return int(field.index) }
	return index
}

// A destination of a multiple assignment stored through a carrier, read before
// any target is written (`prov_assign`): what `prov_read_through_carrier`
// returned, with each carrier another target redefines held as it was.
@(private = "file")
Prov_Destination :: struct {
	through: []int,
	below:   []Proj_Step,
	reached: bool,
	read:    bool,
}

@(private)
prov_assign :: proc(graph: ^Flow_Graph, s: ^Stmt_Assign, value_loans: [][]int) {
	value_loans := value_loans
	written := prov_assign_redefines(graph, s)
	if len(written) > 0 && value_loans != nil {
		captured := make([][]int, len(value_loans), graph.alloc)
		for loans, index in value_loans {
			captured[index] = prov_capture_slots(graph, loans, written, s.op_span)
		}
		value_loans = captured
	}
	destinations := prov_assign_destinations(graph, s, written)
	permutes := prov_assign_permutes(graph, s)
	clones := s.destructure.active ? s.destructure.clones : s.rhs_clones
	for target, index in s.lhs {
		copies := index < len(clones) && clones[index]
		source: []Proj_Step
		if s.destructure.active { source = {proj_field(prov_destructure_index(graph.k.c, &s.destructure, index))} }
		sources: []int
		value: Expr
		if s.destructure.active {
			value = s.rhs[0]
			if len(value_loans) > 0 {
				sources = prov_destructure_field(
					graph, value_loans[0], &s.destructure, index, prov_type(graph, target), expr_span(target),
				)
			}
		} else if index < len(s.rhs) {
			value = s.rhs[index]
			if index < len(value_loans) {
				sources = value_loans[index]
			}
		}
		if value != nil && s.op == .Assign {
			prov_region_escape(graph, target, prov_input_value(graph, value), source, copies)
			// An owner copied from a place may be cloned.
			if prov_tracks_allocator_use(graph) && clone_may_allocate(graph.k.c, prov_type(graph, target)) &&
			   expression_is_borrowed_place(value) {
				prov_event(graph, Prov_Event_Allocator_Use{prov_input_value(graph, value), expr_span(value), true})
			}
		}
		// design.md "Weakening and reborrows": a reordering leaves each carrier in one
		// place, so what it reads is moved out rather than copied.
		first_reborrow := len(graph.reborrows)
		defer if permutes {
			for slot in sources {
				if graph.prov_slots[slot].kind == .Temporary {
					read := prov_reborrows_deriving(graph, slot)
					for reborrow in prov_next_reborrow(graph, &read) {
						reborrow.moved = true
					}
				}
				taken := prov_reborrows_from(graph, slot)
				for reborrow, at in prov_next_reborrow(graph, &taken) {
					reborrow.moved ||= at >= first_reborrow
				}
			}
			for slot in sources {
				graph.prov_slots[slot].moved_out = true
			}
		}
		target_type := prov_type(graph, target)
		if s.op == .Assign {
			// The old value ends first; a provider moved in then joins the local.
			// A destination already moved out holds nothing to drop.
			if index >= len(s.destination_live) || s.destination_live[index] != .Dead {
				prov_drop_effects(graph, target_type, expr_span(target), region = prov_drop_region(graph, target))
			}
			provider_assign_end(graph, target)
			if root := provider_place_root(graph, target); root != INVALID_SYMBOL && value != nil {
				_, path, _ := prov_place_of(graph, target)
				prov_merge_moved_providers(graph, root, prov_input_value(graph, value), path)
			}
		}
		destination := index < len(destinations) ? destinations[index] : Prov_Destination{}
		if ident, is_ident := target.(^Expr_Ident); is_ident && s.op == .Assign {
			prov_assign_local(graph, s, ident, value, sources, source, copies, target_type)
		} else {
			prov_assign_place(graph, s, target, value, sources, source, copies, target_type, destination, permutes)
		}
	}
}

// `prov_assign` of `value` to the local `ident`.
@(private = "file")
prov_assign_local :: proc(
	graph: ^Flow_Graph, s: ^Stmt_Assign, ident: ^Expr_Ident, value: Expr, sources: []int, source: []Proj_Step, copies: bool, target_type: Type_Id,
) {
	target := Expr(ident)
	if value != nil && type_is_region_provider(graph.k.c, target_type) {
		// A provider's own region stays its token; the new value's parent joins
		// the parents it depends on.
		prov_merge_value_region(graph, ident.symbol, prov_input_value(graph, value), source, storage = !s.destructure.active && type_is_carrier(graph.k.c, target_type), provider = true)
	} else if value != nil && prov_type_has_region(graph.k.c, target_type) {
		if !type_is_carrier(graph.k.c, target_type) {
			prov_define_value_regions(graph, prov_root_for_symbol(graph, ident.symbol), nil, prov_input_value(graph, value), source, copies, ident.symbol)
		} else {
			prov_merge_value_region(graph, ident.symbol, prov_input_value(graph, value), source, storage = !s.destructure.active, provider = false)
		}
	}
	prov_note_written_alias(graph, ident.symbol, value, source = source)
	prov_retain_escape(graph, target, sources, expr_span(target))
	prov_drop_use(graph, ident.symbol, expr_span(target))
	prov_invalidate(graph, target, expr_span(target), "assigned")
	if slot, is_carrier := prov_slot_for_symbol(graph, ident.symbol); is_carrier {
		if !s.destructure.active && value != nil {
			prov_note_reslice(graph, slot, value)
		}
		prov_define_one_content(graph, slot, sources, expr_span(target))
	} else if content := prov_content_slots(graph, ident.symbol); len(content) > 0 {
		prov_define_content(graph, content, sources, expr_span(target))
	}
}

// `prov_assign` to a place, rooted or reached through carriers, or with an
// operator such as `+=`.
@(private = "file")
prov_assign_place :: proc(
	graph: ^Flow_Graph, s: ^Stmt_Assign, target, value: Expr, sources: []int, source: []Proj_Step, copies: bool, target_type: Type_Id,
	destination: Prov_Destination, permutes: bool,
) {
	prov_retain_escape(graph, target, sources, expr_span(target))
	replaces_read := value != nil && len(s.lhs) == 1 && prov_reads_below(graph.k.c, value, target)
	root, path, place_ok := prov_place_of(graph, target)
	if place_ok && s.op == .Assign {
		prov_note_written_alias(graph, graph.roots[int(root)].symbol, value, path, target_type, source)
	}
	if !place_ok && s.op == .Assign {
		if prov_assign_through_carrier(graph, s, target, value, sources, destination, permutes, replaces_read) {
			return
		}
	}
	if place_ok {
		// As for a whole local: a record holding only handles keeps their
		// regions too (design.md "Allocator regions and region provenance").
		if value != nil && s.op == .Assign && prov_store_keeps_region(graph.k.c, target_type) {
			prov_define_value_regions(graph, root, path, prov_input_value(graph, value), source, copies, place_root_symbol(target))
		}
		prov_walk_subscripts(graph, target, s.op == .Assign)
		prov_access(graph, root, path, .Write, expr_span(target))
		// design.md "Weakening and reborrows": storing a carrier into itself
		// suspends nothing, and leaves what the place holds as it is.
		stored_back := value != nil && len(s.lhs) == 1 && prov_names_same_place(graph.k.c, value, target)
		if content := prov_content_at(graph, root, path); len(content) > 0 && s.op == .Assign && !stored_back {
			prov_define_content(graph, content, sources, expr_span(target), path, target_type, replaces_read = replaces_read)
		}
		return
	}
	walk_flow_expr(graph, target)
	if s.op != .Assign {
		prov_write_through_place(graph, target, expr_span(target))
	}
}

// The slots a multiple assignment's targets redefine: a carrier local's own, or
// the content slots of a record local. design.md "Evaluation order": every value
// is evaluated before any write, so a value read from a variable this statement
// also writes, as in `a, b = b, a`, keeps what the variable held then.
@(private = "file")
prov_assign_redefines :: proc(graph: ^Flow_Graph, s: ^Stmt_Assign) -> []int {
	written := make([dynamic]int, 0, len(s.lhs), graph.alloc)
	if len(s.lhs) == 1 {
		return written[:]
	}
	for target in s.lhs {
		if ident, is_ident := target.(^Expr_Ident); is_ident {
			if slot, is_carrier := prov_slot_for_symbol(graph, ident.symbol); is_carrier {
				append(&written, slot)
			} else {
				append(&written, ..prov_content_slots(graph, ident.symbol))
			}
		} else if root, path, place_ok := prov_place_of(graph, target); place_ok {
			append(&written, ..prov_content_at(graph, root, path))
		}
	}
	return written[:]
}

// The destinations are evaluated all before the first write, so a store through a
// carrier another target of this statement redefines, as `p^.head` in
// `p, p^.head = &mut y, p^.tail`, goes where the carrier pointed then (design.md
// "Values that contain borrows").
@(private = "file")
prov_assign_destinations :: proc(graph: ^Flow_Graph, s: ^Stmt_Assign, written: []int) -> []Prov_Destination {
	if len(s.lhs) == 1 || s.op != .Assign {
		return nil
	}
	destinations := make([]Prov_Destination, len(s.lhs), graph.alloc)
	for target, index in s.lhs {
		if _, is_ident := target.(^Expr_Ident); is_ident {
			continue
		}
		if _, _, place_ok := prov_place_of(graph, target); place_ok {
			continue
		}
		through, below, reached := prov_read_through_carrier(graph, target, store = true)
		if reached {
			held := prov_capture_slots(graph, through, written, expr_span(target))
			// A diagnostic about the store names the carrier it went through.
			for slot, at in held {
				if slot != through[at] && graph.prov_slots[slot].name == "" {
					graph.prov_slots[slot].name = graph.prov_slots[through[at]].name
				}
			}
			through = held
		}
		destinations[index] = Prov_Destination{through, below, reached, true}
	}
	return destinations
}

// A store through a carrier, or into what an `inout` result names; false when
// `target` is neither. design.md "Weakening and reborrows": the store reads each
// carrier it goes through, so one read out of another, as `p^^.a` in
// `p^^.a^.value = 3`, uses what a copy of it, as `node := p^^.a`, suspends.
@(private = "file")
prov_assign_through_carrier :: proc(
	graph: ^Flow_Graph, s: ^Stmt_Assign, target, value: Expr, sources: []int, evaluated: Prov_Destination, permutes, replaces_read: bool,
) -> bool {
	destination := evaluated
	if !destination.read {
		destination.through, destination.below, destination.reached = prov_read_through_carrier(graph, target, store = true)
	}
	through, below, reached := destination.through, destination.below, destination.reached
	walked := false
	if !reached {
		through, walked = prov_inout_result_place(graph, target)
	}
	if reached && len(through) == 0 {
		prov_walk_subscripts(graph, target, true)
		return true
	}
	if len(through) == 0 && !walked {
		return false
	}
	if !walked {
		prov_write_through(graph, through, below, expr_span(target), "write", target)
	}
	prov_store_region(graph, prov_input_value(graph, target), prov_input_value(graph, value))
	if !walked {
		prov_walk_subscripts(graph, target, true)
	}
	if len(through) > 0 {
		prov_publish_store(graph, s, target, sources, through, below, permutes, replaces_read)
	}
	if walked {
		prov_emit(graph, Prov_Event{kind = .Live, sources = through, span = expr_span(target)})
		prov_reach(graph, through, expr_span(target))
	}
	return true
}

// design.md "Weakening and reborrows": what a store through the carriers `through`
// leaves where they point.
@(private = "file")
prov_publish_store :: proc(graph: ^Flow_Graph, s: ^Stmt_Assign, target: Expr, sources, through: []int, below: []Proj_Step, permutes, replaces_read: bool) {
	target_type := prov_type(graph, target)
	links := len(sources) > 0
	lands: Prov_Store_Target
	if element, found := prov_view_element_store(graph, target, target_type); found {
		lands = element
	}
	if links {
		// What it read below its target was used by that read, which reports a copy of it
		// in use, so it does not use it again.
		if !replaces_read {
			prov_use_stored(graph, sources, target_type, expr_span(target))
		}
		graph.has_linked_store = true
	}
	publish := Prov_Event {
		kind = .Publish, span = expr_span(target), sources = sources, into = through,
		linked = prov_store_linked(graph.k.c, target_type), store = lands, carried = target_type, links_copies = links,
		replaces_read = replaces_read,
		permutes = permutes, element = prov_local_view_element(graph, target),
		through_element = lands == nil && prov_may_point_at_element(graph, through),
	}
	// design.md "Evaluation order": a destination is evaluated before an
	// earlier target of the same statement is written, so the view it
	// went through is not the one the definitions reaching here made.
	for other in s.lhs {
		if ident, is_ident := other.(^Expr_Ident); is_ident && publish.element.slot > 0 {
			if slot, found := prov_slot_for_symbol(graph, ident.symbol); found && slot + 1 == publish.element.slot {
				publish.element = {}
			}
		}
	}
	// design.md "Values that contain borrows": carriers pointing at
	// one place replace what it holds wherever they name one storage
	// (`publish_into_loan`); a prefix places were merged into is not one.
	offsets, found, merged := prov_value_offset(graph, through)
	paths := prov_offset_paths(graph, offsets) if found && !merged else nil
	if len(paths) == 1 && prov_offsets_agree(graph, through, offsets) && path_is_exact(paths[0]) {
		if path_is_exact(below) {
			publish.path, publish.one_place, publish.place_path = prov_concat_path(graph, paths[0], below), true, paths[0]
			graph.has_replacing_store = true
		} else if lands == nil && publish.linked {
			// It lands only in the slots along the place it names, whose
			// copy is linked to them.
			publish.path, publish.place_path = prov_concat_path(graph, paths[0], below), paths[0]
		}
	}
	if len(sources) > 0 || publish.one_place {
		prov_emit(graph, publish)
	}
}

// A store of `type` that keeps regions in the place it lands in: an owner, an
// allocator handle, or a value holding either, though a carrier's regions are
// what it points at.
@(private = "file")
prov_store_keeps_region :: proc(c: ^Compiler, type: Type_Id) -> bool {
	return type_is_managed(c, type) || type_is_allocator(c, type) ||
		prov_type_has_region(c, type) && !type_is_carrier(c, type)
}

// Whether a multiple assignment only reorders its targets' values, as
// `a[0], a[1] = a[1], a[0]`: each value ends in one place, so nothing is copied
// (`Carrier_Move`).
@(private)
prov_assign_permutes :: proc(graph: ^Flow_Graph, s: ^Stmt_Assign) -> bool {
	if len(s.lhs) < 2 || len(s.lhs) != len(s.rhs) || s.op != .Assign {
		return false
	}
	used := make([]bool, len(s.lhs), graph.alloc)
	next: for value in s.rhs {
		for target, index in s.lhs {
			if !used[index] && prov_names_same_place(graph.k.c, value, target) {
				used[index] = true
				continue next
			}
		}
		return false
	}
	return true
}

// Whether `value` is read out through what `place` holds, as `list.next^.next` for
// `list.next`, so storing it there replaces the carrier it was read through
// (design.md "Weakening and reborrows").
@(private = "file")
prov_reads_below :: proc(c: ^Compiler, value, place: Expr) -> bool {
	at := value
	through := false
	for at != nil {
		if through && prov_names_same_place(c, at, place) {
			return true
		}
		#partial switch v in at {
		case ^Expr_Selector:
			at = v.operand
		case ^Expr_Postfix:
			if v.op != .Caret {
				return false
			}
			at = v.operand
			through = true
		case:
			return false
		}
	}
	return false
}

// Whether two expressions of one assignment name one place. Each is evaluated
// before any write (design.md "Evaluation order"), so the variables they read
// hold one value for both; what could change that between the evaluations is a
// call, an operator, or a map's indexing, none of which this accepts. Two
// expressions it cannot tell the same are taken to be different.
@(private = "file")
prov_names_same_place :: proc(c: ^Compiler, a, b: Expr) -> bool {
	x, y := expr_base(a), expr_base(b)
	if x == nil || y == nil || x.type != y.type {
		return false
	}
	if base_is_const(x) != base_is_const(y) {
		return false
	}
	if base_is_const(x) {
		equal, comparable := fold_comparison(c, .Eq_Eq, x.const_value, y.const_value)
		return comparable && equal
	}
	if conversion_source(x) != INVALID_TYPE || conversion_source(y) != INVALID_TYPE {
		return false
	}
	#partial switch first in a {
	case ^Expr_Ident:
		second, same := b.(^Expr_Ident)
		return same && first.symbol != INVALID_SYMBOL && first.symbol == second.symbol
	case ^Expr_Selector:
		second, same := b.(^Expr_Selector)
		return same && first.resolution.kind == .Field && second.resolution.kind == .Field && first.name.id == second.name.id &&
		       first.operand != nil && second.operand != nil && prov_names_same_place(c, first.operand, second.operand)
	case ^Expr_Postfix:
		second, same := b.(^Expr_Postfix)
		return same && first.op == .Caret && second.op == .Caret && prov_names_same_place(c, first.operand, second.operand)
	case ^Expr_Index:
		second, same := b.(^Expr_Index)
		if !same || len(first.bound) != 0 || len(second.bound) != 0 || len(first.indices) != len(second.indices) ||
		   first.resolution.kind == .User_Operator || second.resolution.kind == .User_Operator ||
		   underlying_kind(c, expr_base(first.operand).type) == .Map ||
		   !prov_names_same_place(c, first.operand, second.operand) {
			return false
		}
		for index, at in first.indices {
			if !prov_names_same_place(c, index, second.indices[at]) {
				return false
			}
		}
		return true
	}
	return false
}

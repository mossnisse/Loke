// Views: a switch payload or case binding over a place, and an erased, printed,
// or read-only view of a value, with what each keeps borrowed.
package lokec

// The payload under a union's wildcard alternative: unwrapping keeps every borrow
// the wrapper carried.
@(private)
prov_payload_content :: proc(
	graph: ^Flow_Graph, loans: []int, subject_type, payload_type: Type_Id, span: Span,
) -> []int {
	if len(loans) == 0 || payload_type == INVALID_TYPE || payload_type == subject_type {
		return loans
	}
	if !type_is_union(graph.k.c, subject_type) {
		return loans
	}
	return prov_project_content(graph, loans, subject_type, {proj_wild()}, payload_type, span)
}

@(private)
prov_case_payload :: proc(
	graph: ^Flow_Graph, s: ^Stmt_Switch, entry: Switch_Case, subject: []int,
) -> []int {
	if entry.binding_symbol == INVALID_SYMBOL || s.subject == nil {
		return subject
	}
	return prov_payload_content(
		graph, subject, prov_type(graph, s.subject), entry.binding_type, entry.span,
	)
}

// One field of the payload a case binds (design.md "Inspecting a union").
@(private)
prov_case_field :: proc(
	graph: ^Flow_Graph, s: ^Stmt_Switch, field: Case_Field, subject: []int, span: Span,
) -> []int {
	if len(subject) == 0 || s.subject == nil {
		return subject
	}
	path := []Proj_Step{proj_wild(), proj_field(field.slot)}
	return prov_project_content(graph, subject, prov_type(graph, s.subject), path, field.type, span)
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
	return graph.view_loans[graph.roots[int(root)].symbol]
}

// design.md "Switch ownership": a payload binding over a place names the
// payload where the subject stores it, so a use of the binding uses the
// carrier stored there, and a mutable copy of that carrier, as `b := opt` or
// `b := cur^.next` beside `case .some(a):`, suspends the binding as it does
// the place. Reached through carriers, a use loads the payload through the
// carriers the subject view holds. A field binding, `slot` at or above zero,
// uses only its field.
@(private)
prov_note_view_use :: proc(graph: ^Flow_Graph, id: Symbol_Id, subject: Expr, slot := -1) {
	sym := symbol_of(graph.k.c, id)
	if sym == nil || subject == nil || !type_carries_borrow(graph.k.c, sym.type).mutable {
		return
	}
	payload := prov_payload_path(graph, nil, slot)
	if root, path, ok := prov_place_of(graph, subject); ok {
		if slots := prov_content_at(graph, root, prov_concat_path(graph, path, payload)); len(slots) > 0 {
			graph.view_uses[id] = Prov_View_Use{slots = slots}
		}
		return
	}
	hops := prov_place_hops(graph, subject)
	if carriers := graph.view_loans[id]; len(hops) > 0 && len(carriers) > 0 {
		graph.view_uses[id] = Prov_View_Use{slots = carriers, path = prov_concat_path(graph, hops[0].path, payload), load = true}
	}
}

// Where a case's binding is below `base`, where the subject is: the payload, or
// with `slot` one of its fields.
@(private = "file")
prov_payload_path :: proc(graph: ^Flow_Graph, base: []Proj_Step, slot: int) -> []Proj_Step {
	path := prov_extend(graph, base, proj_wild())
	return slot >= 0 ? prov_extend(graph, path, proj_field(slot)) : path
}

// The read-only view of a place subject that a switch's whole-payload bindings
// share. Its cases exclude each other and each runs the view's `Def` afresh, as
// a creation site that runs again does, so one loan and slot stand for them all:
// the solver's tables grow with loans and blocks together, and a loan per case
// is one per block.
@(private)
Prov_Case_View :: struct {
	sources: []int,
	slot:    int,
	loan:    Loan_Id,
}

// A `.name(&mut binding)` case borrows the subject exclusively for the case, as
// `&mut subject` would (design.md "Switch ownership"). A field binding, `slot`
// at or above zero, borrows only its field of the payload where the subject is
// a place with a path, or is reached through carriers.
@(private)
prov_subject_view :: proc(graph: ^Flow_Graph, subject: Expr, mutable: bool, slot: int, shared: ^Prov_Case_View) -> []int {
	if subject == nil {
		return nil
	}
	span := expr_span(subject)
	root, path, ok := prov_place_of(graph, subject)
	if ok && !mutable {
		if slot >= 0 {
			return prov_borrow(graph, root, prov_payload_path(graph, path, slot), false, span, "payload")
		}
		if shared.sources == nil {
			shared.slot, shared.loan = prov_new_borrow_slot(graph, root, path, false, span, "payload")
			shared.sources = prov_join(graph, prov_one(graph, shared.slot), prov_root_view(graph, root))
		}
		prov_emit(graph, Prov_Event{kind = .Def, slot = shared.slot, loan = shared.loan, span = span})
		return shared.sources
	}
	if mutable && slot >= 0 && ok {
		if ident, is_ident := subject.(^Expr_Ident); is_ident {
			if loans, viewed := graph.view_loans[ident.symbol]; viewed && !graph.step_views[ident.symbol] {
				return loans
			}
		}
		path = prov_payload_path(graph, path, slot)
		prov_walk_subscripts(graph, subject)
		access_block, access_index := prov_access(graph, root, path, .Write, span)
		return prov_borrow(graph, root, path, true, span, "payload", access_block, access_index)
	}
	if mutable && slot >= 0 {
		if carriers, below, through := prov_read_through_carrier(graph, subject, reads = false); through {
			below = prov_payload_path(graph, below, slot)
			prov_write_through(graph, carriers, below, span, "mutable borrow", subject)
			return prov_place_loan(graph, carriers, below, true, "payload", subject, borrows = true)
		}
	}
	if mutable {
		return prov_borrow_place(graph, subject, true, span, "payload")
	}
	// A subject reached through a pointer or view, as in `switch (p^)`, is
	// storage that carrier names, so the binding views what `&subject`
	// would borrow. A carrier loaded on the way, as `p^` for `p^^.first`,
	// only holds that storage's loans for the view: it no more suspends
	// what it was loaded out of than `p` does for `p^.first`.
	carriers, below, through := prov_read_through_carrier(graph, subject, reads = false)
	if !through {
		return nil
	}
	for carrier in carriers {
		graph.prov_slots[carrier].viewed = graph.prov_slots[carrier].loaded
	}
	if slot >= 0 {
		below = prov_payload_path(graph, below, slot)
	}
	prov_read_through(graph, carriers, below, span, subject)
	return prov_join(graph, carriers, prov_place_loan(graph, carriers, below, false, "payload", subject))
}

// A case binding keeps its selected payload's fields, including owner/handle
// separation (design.md "Inspecting a union").
@(private)
prov_bind_case_region :: proc(graph: ^Flow_Graph, id: Symbol_Id, subject: Value_Id, variants: []int, slot: int) {
	prov_effect_scope(
		graph, prov_effect_active(graph) && prov_effect_symbol_relevant(graph, id),
		Prov_Effect_Case{id, subject, prov_effect_copy(graph, variants), slot},
	)
	if id == INVALID_SYMBOL || subject == 0 {
		return
	}
	subject_type := prov_value(graph, subject).type
	sym := symbol_of(graph.k.c, id)
	if sym == nil {
		return
	}
	if !prov_type_has_region(graph.k.c, sym.type) {
		return
	}
	// design.md "Inspecting a union": a borrowed binding names the subject's
	// payload. Region writes through it must reach the same storage too.
	if sym.borrowed_binding != .None && underlying_kind(graph.k.c, subject_type) == .Union && len(variants) > 0 {
		aliases, uncertain := prov_case_region_aliases(graph, id, subject, variants, slot)
		graph.region_aliases[id] = aliases
		if !uncertain { return }
	}
	if underlying_kind(graph.k.c, subject_type) == .Union && len(variants) == 1 {
		path := prov_extend(graph, nil, proj_field(variants[0]))
		if slot >= 0 { path = prov_extend(graph, path, proj_field(slot)) }
		if type_is_carrier(graph.k.c, sym.type) || type_is_allocator(graph.k.c, sym.type) ||
		   type_is_region_provider(graph.k.c, sym.type) {
			prov_merge_region_of(graph, id, prov_result_region_at(graph, subject, path))
		} else {
			prov_define_value_regions(graph, prov_root_for_symbol(graph, id), nil, subject, path)
		}
		return
	}
	if set := prov_region_of(graph, subject); !region_is_empty(set) {
		prov_merge_region_of(graph, id, set)
	}
}

// The storage a borrowed case binding names. Unknown storage, including a
// recursive cursor's next node, retains the escape restriction and a snapshot for
// reads. Keep known targets too: uncertainty cannot remove their lifetime
// constraints (design.md "Allocator regions and region provenance"). NO_ROOT is
// always last.
@(private = "file")
prov_case_region_aliases :: proc(
	graph: ^Flow_Graph, id: Symbol_Id, subject: Value_Id, variants: []int, slot: int,
) -> (aliases: []Prov_Region_Alias, uncertain: bool) {
	places := make([dynamic]Prov_Region_Alias, graph.alloc)
	if root, at, ok := prov_value_place_of(graph, subject); ok {
		append(&places, Prov_Region_Alias{root = root, path = at, from = subject})
	} else {
		below := prov_path_below_carrier(graph, subject)
		for target in prov_written_targets(graph, subject, as_place = true) {
			target_root := prov_root_for_storage(graph, target.target)
			if target_root == NO_ROOT { uncertain = true; continue }
			append(&places, Prov_Region_Alias{root = target_root, path = prov_concat_path(graph, target.at, below)})
		}
	}
	out := make([dynamic]Prov_Region_Alias, graph.alloc)
	for place in places {
		if prov_region_alias_reaches(graph, place.root, id) {
			uncertain = true
			continue
		}
		for variant in variants {
			path := prov_extend(graph, place.path, proj_field(variant))
			if slot >= 0 { path = prov_extend(graph, path, proj_field(slot)) }
			append(&out, Prov_Region_Alias{root = place.root, path = path, from = place.from})
		}
	}
	uncertain ||= len(out) == 0
	if uncertain { append(&out, Prov_Region_Alias{root = NO_ROOT}) }
	return out[:], uncertain
}

// Written carrier targets grow across loop passes. A cursor set from its own
// payload can refer back to the binding about to be installed; such storage
// needs the unresolved-carrier fallback, not a recursive region alias.
@(private)
prov_region_alias_reaches :: proc(graph: ^Flow_Graph, root: Root_Id, id: Symbol_Id) -> bool {
	if root == NO_ROOT { return false }
	target := graph.roots[int(root)].symbol
	if target == id { return true }
	for alias in graph.region_aliases[target] {
		if prov_region_alias_reaches(graph, alias.root, id) { return true }
	}
	return false
}

// An implicit `dyn` view keeps the source root with a read-only loan
// (design.md "Variadic parameters", "Borrowed callable views").
@(private)
prov_erase :: proc(graph: ^Flow_Graph, e: Expr) -> []int {
	span := expr_span(e)
	// design.md "Borrowed callable views": a procedure is the view's data word
	// itself, so holding one borrows nothing.
	repr := prov_repr(graph, e)
	if dyn_proc_signature(graph.k.c, repr.type) != INVALID_TYPE && underlying_kind(graph.k.c, repr.erased_from) == .Proc {
		return walk_flow_expr_erased(graph, e)
	}
	// Also a use of what a carrier already refers to, so erasure cannot hide
	// a stale view.
	held, lent := prov_read_only_view(graph, e, span)
	if lent || len(held) > 0 {
		return held
	}
	// A constant's hidden storage is a frame slot that follows the lexical scope.
	root := prov_new_root(graph, .Temporary, span, "this erased value")
	append(&graph.in_scope, Flow_Cleanup{kind = .Prov_Root, root = root, span = span})
	graph.roots[int(root)].extended = true
	return prov_borrow(graph, root, nil, false, span, "view")
}

// What a read-only view of `e` holds, as an erased `dyn` view does; `lent` when
// that is more than what it read, which for a constant it is not. A view of a slice
// or pointer local only reads it, so it holds a read-only reborrow, as a `[]T`
// parameter would. A field or element holding one is read the same way, so two views
// of `held.items` may be live together.
@(private = "file")
prov_read_only_view :: proc(graph: ^Flow_Graph, e: Expr, span: Span) -> (held: []int, lent: bool) {
	if ident, plain := prov_plain_view_local(graph, e); plain {
		return prov_lend_read_only(graph, e, prov_reborrow_traversal(graph, prov_read_ident(graph, ident, reads_only = true), span, false), span)
	}
	loans: []int
	plain_place := prov_plain_view_place(graph, e, prov_repr(graph, e).erased_from)
	{
		prov_begin_conversion(graph, e, .Erasure)
		defer prov_end_conversion(graph)
		if plain_place {
			loans = prov_read_carrier(graph, e, true)
		} else {
			if content, kept, through := prov_view_parts_through_carrier(graph, e, span); through {
				return prov_join(graph, content, kept), true
			}
			loans = walk_flow_expr(graph, e)
		}
	}
	if plain_place {
		loans = prov_reborrow_traversal(graph, loans, span, false)
	}
	return prov_lend_read_only(graph, e, loans, span)
}

// What a read-only view of `e` holds beside the `loans` it read: a loan of the
// place, or of the temporary holding the value. A constant has neither, and
// holds the `loans` alone.
@(private = "file")
prov_lend_read_only :: proc(graph: ^Flow_Graph, e: Expr, loans: []int, span: Span) -> (held: []int, lent: bool) {
	if root, path, ok := prov_place_of(graph, e); ok {
		return prov_join(graph, loans, prov_borrow(graph, root, path, false, span, "view")), true
	}
	// A temporary ends with its statement unless a local's value extends it
	// (design.md "Temporaries and procedure boundaries"), and the view with it.
	if !is_const_expr(e) {
		return prov_join(graph, loans, prov_borrow(graph, prov_temp_root_of(graph, e, loans), nil, false, span, "view")), true
	}
	return loans, false
}

// design.md "Built-in procedures": an argument an `assert` or `panic` report
// prints keeps its type, and the report borrows it until it has printed the last.
// What it holds is suspended that long, so a later argument cannot write what it
// reaches, and printing only reads, so two arguments may name the same place. A
// written `format` may instead write through a mutable carrier it is handed.
@(private)
prov_printed_argument :: proc(graph: ^Flow_Graph, e: Expr) -> (held: []int, printed: []int) {
	type := prov_type(graph, e)
	span := expr_span(e)
	writes := prov_print_may_write(graph.k.c, type)
	if content, kept, through := prov_view_parts_through_carrier(graph, e, span, !writes); through {
		return prov_join(graph, content, kept), content
	}
	loans := prov_reborrow_traversal(graph, prov_read_carrier(graph, e, !writes), span, false)
	held, _ = prov_lend_read_only(graph, e, loans, span)
	return held, loans
}

// Whether printing a `type` hands a written `format` a mutable carrier. A pointer or
// slice prints what it views, and the slot gets that by a read-only `self: ^`, so the
// mutable carrier that matters is one held in what is viewed. A distinct one may have
// a `format` that takes it by value.
@(private = "file")
prov_print_may_write :: proc(c: ^Compiler, type: Type_Id) -> bool {
	if !type_prints_through_method(c, type) {
		return false
	}
	viewed := type
	for {
		kind := underlying_kind(c, viewed)
		if type_underlying(c, viewed) != viewed || (kind != .Pointer && kind != .Slice) {
			break
		}
		viewed = underlying_info(c, viewed).element
	}
	return type_carries_borrow(c, viewed).mutable
}

// standard-library.md "Printed forms": printing reads what a pointer points to, and
// so on down, once a report has evaluated its last argument. `printed` is what each
// argument holds of that, which the read may go through.
@(private)
prov_read_printed_reach :: proc(graph: ^Flow_Graph, printed: []int, span: Span) {
	if len(printed) == 0 {
		return
	}
	graph.has_content_load = true
	prov_emit(graph, Prov_Event{kind = .Load, slot = prov_temp_slot(graph), into = printed, load = .Deep, span = span, reads_only = true})
}

// A read-only view of a field, element, or pointee reached through a pointer or
// a slice, as `s[0]` or `p^.x`, is an address in what the carrier names, so it
// keeps that in use whatever later happens to the carrier. A carrier it reborrows
// is suspended for as long. By parts: what the place holds, and the snapshot of the
// carriers it is reached through.
@(private = "file")
prov_view_parts_through_carrier :: proc(graph: ^Flow_Graph, e: Expr, span: Span, reads_only := false) -> (content: []int, kept: []int, through: bool) {
	if !prov_reads_plainly_through(graph, e) {
		return nil, nil, false
	}
	if _, _, named := prov_place_of(graph, e); named {
		return nil, nil, false
	}
	// A mutable call result holds its source's mutable loan, but a view of what it
	// names only needs that kept valid: a read of the source does not touch it.
	read_only_hold := false
	if hops := prov_place_hops(graph, e); len(hops) > 0 {
		carrier := prov_value(graph, hops[len(hops) - 1].carrier).origin
		read_only_hold = prov_expr_is_temporary(carrier) && type_carries_borrow(graph.k.c, prov_type(graph, carrier)).mutable
	}
	type := prov_type(graph, e)
	only := reads_only || prov_read_is_reads_only(graph.k.c, type) || prov_type_is_plain_view(graph.k.c, type)
	carriers, path, reached := prov_read_through_carrier(graph, e, only)
	if !reached {
		return nil, nil, false
	}
	content = prov_load_content(graph, carriers, path, type, span, only, place = e)
	kept = prov_snapshot(graph, carriers, span)
	for slot, index in carriers {
		if read_only_hold || prov_slot_is_mutable_carrier(graph, slot) {
			prov_add_reborrow(graph, Prov_Reborrow{source = slot, derived = kept[index], span = span, mutable = false})
		}
	}
	if read_only_hold {
		for slot in prov_join(graph, content, kept) {
			graph.prov_slots[slot].read_only_hold = true
		}
	}
	return content, kept, true
}

// design.md "string type conversions", "Dynamic arrays", "Fixed arrays", and
// "Variadic parameters": a `string` read as a `string_view`, a `[dynamic]T` or
// `[N]T` as a `[]T`, or a `T` a `..^T` pack lends as a `^T`, borrows the owner it
// came from, or the temporary that holds it. A constant viewed in its read-only
// storage borrows nothing, which a `..^T` pack's is only when it is materialized:
// an unnamed one is lent from a temporary of its call.
@(private)
prov_owner_view :: proc(graph: ^Flow_Graph, e: Expr) -> []int {
	base := expr_base(e)
	viewed := prov_type(graph, e)
	prov_begin_conversion(graph, e, .View)
	defer prov_end_conversion(graph)
	noun := "string view"
	#partial switch underlying_kind(graph.k.c, viewed) {
	case .Slice:   noun = "slice"
	case .Pointer: noun = "pointer"
	}
	span := expr_span(e)
	if root, path, ok := prov_place_of(graph, e); ok {
		loans := walk_flow_expr(graph, e)
		if base_is_const(base) {
			return loans
		}
		return prov_join(graph, loans, prov_borrow(graph, root, path, false, span, noun))
	}
	// Reached through a pointer or view: the view borrows what that names.
	if carriers, _, through := prov_read_through_carrier(graph, e); through {
		return carriers
	}
	loans := walk_flow_expr(graph, e)
	static :=base_is_const(base) && (underlying_kind(graph.k.c, viewed) != .Pointer || materialization_of(graph.k.c, e) != nil)
	if static || !base_is_const(base) && !prov_expr_is_temporary(e) {
		return loans
	}
	return prov_join(graph, loans, prov_borrow(graph, prov_temp_root_of(graph, e, loans), nil, false, span, noun))
}

// A slice whose elements hold no borrows, or a pointer to such a value, which
// printing it, or a read-only `dyn` view of it, reads as a `[]T` or `^T` is read:
// nothing it calls can write through it. A distinct type's own `format` is left out,
// as it takes the value and may write what it names; what it generates only reads.
@(private = "file")
prov_type_is_plain_view :: proc(c: ^Compiler, type: Type_Id) -> bool {
	#partial switch underlying_kind(c, type) {
	case .Slice, .Pointer:
	case:
		return false
	}
	return !type_has_written_format(c, type) && !type_carries_borrow(c, underlying_info(c, type).element).any
}

// A plain view converted to a read-only carrier, as `(dyn Shape)(b)`, only reads it, as
// one erased implicitly does (`prov_read_only_view`), so two such views of a mutable
// carrier may be live together. False when `v` is no such conversion.
@(private)
prov_read_only_conversion :: proc(graph: ^Flow_Graph, v: ^Expr_Call) -> ([]int, bool) {
	c := graph.k.c
	type := prov_type(graph, v)
	if len(v.bound) != 1 || v.bound[0] == nil || !type_is_carrier(c, type) || type_carries_borrow(c, type).mutable {
		return nil, false
	}
	e := v.bound[0]
	span := expr_span(e)
	if ident, plain := prov_plain_view_local(graph, e); plain {
		return prov_reborrow_traversal(graph, prov_read_ident(graph, ident, reads_only = true), span, false), true
	}
	if prov_plain_view_place(graph, e, prov_type(graph, e)) {
		return prov_reborrow_traversal(graph, prov_read_carrier(graph, e, true), span, false), true
	}
	return nil, false
}

// A local holding a plain view (`prov_type_is_plain_view`).
@(private = "file")
prov_plain_view_local :: proc(graph: ^Flow_Graph, e: Expr) -> (^Expr_Ident, bool) {
	ident, type, ok := prov_view_local(graph, e)
	if !ok {
		return nil, false
	}
	return ident, prov_type_is_plain_view(graph.k.c, type)
}

// A field or element of a local read as `type`, a plain view
// (`prov_type_is_plain_view`).
@(private = "file")
prov_plain_view_place :: proc(graph: ^Flow_Graph, e: Expr, type: Type_Id) -> bool {
	if expr_base(e) == nil || prov_repr(graph, e).view_from != INVALID_TYPE || type == INVALID_TYPE {
		return false
	}
	if _, is_ident := e.(^Expr_Ident); is_ident {
		return false
	}
	if !prov_type_is_plain_view(graph.k.c, type) {
		return false
	}
	_, _, place := prov_place_of(graph, e)
	return place
}

// The ordinary walk with the erasure hook suppressed.
@(private = "file")
walk_flow_expr_erased :: proc(graph: ^Flow_Graph, e: Expr) -> []int {
	prov_begin_conversion(graph, e, .Erasure)
	defer prov_end_conversion(graph)
	return walk_flow_expr(graph, e)
}

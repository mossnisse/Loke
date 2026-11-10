// Parameters: the roots and loans a body's parameters bind, the caller slots
// standing for what the caller's storage holds, and the elements of a view
// parameter.
package lokec

import "core:slice"

// design.md "Procedure result contracts": a borrowed parameter starts with one
// loan of the caller's root.
// A parameter that keeps its argument's region names it by its position. One that is or
// holds view carriers and no allocator handle stands for what those carriers view, which
// only a read through them says the read of (`Region_Read`).
@(private = "file")
prov_seed_parameter_region :: proc(graph: ^Flow_Graph, id: Symbol_Id, sym: ^Symbol, index: int) {
	c := graph.k.c
	if prov_type_keeps_argument_region(c, sym.type) {
		set: Region_Set
		region_add_param(&set, index, prov_parameter_read(c, sym.type))
		graph.region_of[id] = set
	}
}

// An aggregate parameter gets one loan per shape path.
@(private = "file")
prov_bind_shape_loans :: proc(graph: ^Flow_Graph, root: Root_Id, sym: ^Symbol, content: []int) {
	for path, path_index in carrier_shape(graph.k.c, sym.type) {
		loan := prov_new_content_loan(graph, root, path.steps, path.mutable, sym.span, carrier_path_noun(graph.k.c, path), 0)
		append(&graph.entry_defs, Prov_Entry_Def{slot = content[path_index], loan = loan})
	}
}

// design.md "Procedure result contracts": a load along one path of the pointee
// reads only that path, and so do the loads below it, so a field read out of
// `[]Pair` or `d.pair.a` names none of its siblings. One path tells nothing apart.
@(private = "file")
prov_bind_pointee_loans :: proc(graph: ^Flow_Graph, root: Root_Id, sym: ^Symbol, depths: []Loan_Id) {
	pointee := carrier_pointee_shape(graph.k.c, sym.type)
	if len(pointee) <= 1 {
		return
	}
	paths := make([][]Loan_Id, len(pointee), graph.alloc)
	for path, at in pointee {
		paths[at] = make([]Loan_Id, len(depths), graph.alloc)
		for &deeper, depth in paths[at] {
			first := depth == 0
			deeper = prov_new_content_loan(
				graph, root, nil, first ? path.mutable : graph.loans[int(depths[depth])].mutable, sym.span,
				first ? carrier_path_noun(graph.k.c, path) : carrier_noun(graph.k.c, sym.type), depth + 1, at + 1,
			)
		}
	}
	graph.roots[int(root)].pointee_loans = paths
}

@(private)
prov_bind_parameters :: proc(graph: ^Flow_Graph, literal: ^Expr_Proc) {
	if literal.signature == nil {
		return
	}
	index := 0
	for parameter in literal.signature.params {
		for id in parameter.symbols {
			defer index += 1
			sym := symbol_of(graph.k.c, id)
			if sym == nil {
				continue
			}
			prov_seed_parameter_region(graph, id, sym, index)
			// A `move` parameter is dropped when the body returns; callers see
			// that write through this body's effect, and its release frees in
			// the argument's region.
			if parameter.mode == .Move {
				prov_scope_drop_effects(graph, id, sym.span)
				// A provider moved in is this body's to end, as a local's is: what it
				// backs must end first. Its own parents are still the argument's.
				if provider_local(graph.k.c, id) {
					if type_is_region_provider(graph.k.c, sym.type) {
						graph.provider_parents[id] = graph.region_of[id]
						graph.region_of[id] = prov_provider_region(graph, id)
					}
					append(&graph.in_scope, Flow_Cleanup{kind = .Prov_Root, root = prov_root_for_symbol(graph, id), span = sym.span})
				}
			}
			slot, is_carrier := prov_slot_for_symbol(graph, id)
			content := prov_content_slots(graph, id)
			if !is_carrier && len(content) == 0 {
				continue
			}
			name := identifier_text(graph.k.c, sym.name)
			// The root of what the caller lent, apart from the root of the binding
			// itself, which `prov_root_for_symbol` makes once the body names the
			// parameter as a place. It is registered in neither map, so
			// `prov_view_parameter_loan` finds it as the symbol's first `.Param` root.
			root := prov_new_root(graph, .Param, sym.span, name)
			first_loan := len(graph.loans)
			graph.roots[int(root)].symbol = id
			graph.roots[int(root)].storage = prov_storage_id(graph, Written_Storage{symbol = id})
			graph.roots[int(root)].param_index = index
			// What the caller storage it reaches holds, which loads through it yield. A
			// `..^T` pack's lent values have a loan apart from what they hold, which a
			// call may keep, even where they hold no borrow (design.md "Variadic
			// parameters").
			least := 1
			if lending, packs := param_symbol_pack_lending(graph.k.c, sym); packs {
				least = lending.depth + 1
			}
			depths := make([]Loan_Id, max(least, load_depth(graph.k.c, sym.type)), graph.alloc)
			for &loan, depth in depths {
				loan = prov_new_content_loan(graph, root, nil, type_carries_borrow(graph.k.c, sym.type).mutable, sym.span, carrier_noun(graph.k.c, sym.type), depth + 1)
			}
			graph.roots[int(root)].content_loans = depths
			if !is_carrier {
				prov_bind_shape_loans(graph, root, sym, content)
				prov_caller_slots(graph, root, first_loan, name)
				continue
			}
			loan := prov_new_loan(graph, root, nil, carrier_is_mutable(graph.k.c, sym.type), sym.span, carrier_noun(graph.k.c, sym.type))
			append(&graph.entry_defs, Prov_Entry_Def{slot = slot, loan = loan})
			prov_bind_pointee_loans(graph, root, sym, depths)
			prov_caller_slots(graph, root, first_loan, name)
		}
	}
}

// design.md "Weakening and reborrows": the caller storage a parameter's loan
// names has no content here, so a slot stands for what it holds, holding the
// loan one more load through it reads. A load through the parameter reads these
// slots; `publish_into_caller` says where a store lands. Slots of different loans
// are taken to name different storage.
@(private)
prov_caller_slots :: proc(graph: ^Flow_Graph, root: Root_Id, first: int, name: string) {
	c := graph.k.c
	descriptor := graph.roots[int(root)]
	type := symbol_of(c, descriptor.symbol).type
	pointee: []Carrier_Path
	if len(descriptor.pointee_loans) > 0 {
		pointee = carrier_pointee_shape(c, type)
	}
	shape := carrier_shape(c, type)
	reaches_mutable := type_carries_borrow(c, type).mutable
	last := len(graph.loans)
	for index in first ..< last {
		loan := graph.loans[index]
		if !loan.content && len(pointee) > 0 {
			one := underlying_kind(c, type) == .Pointer
			for loans, position in descriptor.pointee_loans {
				prov_caller_slot(graph, Loan_Id(index), pointee[position], loans[0], name, pointee[position].mutable, one)
			}
			continue
		}
		held := Loan_Id(deeper_content_loan(descriptor, loan, index))
		// The carrier type holding this loan, followed down from the parameter
		// while each storage holds one carrier; the last content loan stands
		// for every depth below it, so its storage is not one type.
		holder := INVALID_TYPE
		one := false
		switch {
		case loan.pointee > 0:
			at := pointee[loan.pointee - 1]
			below, pointers := carrier_below(c, at.type, loan.depth - 1)
			holder = below
			one = underlying_kind(c, type) == .Pointer && path_is_exact(at.steps) && pointers
		case !loan.content:
			holder = type
			one = underlying_kind(c, type) == .Pointer
		case loan.depth == 0:
			for path in shape {
				if slice.equal(path.steps, loan.path) && !path.truncated {
					holder = path.type
				}
			}
			one = holder != INVALID_TYPE && path_is_exact(loan.path) && underlying_kind(c, holder) == .Pointer
		case loan.depth < len(descriptor.content_loans):
			below, pointers := carrier_below(c, type, loan.depth)
			holder = below
			one = pointers
		}
		paths: []Carrier_Path
		if element := prov_pointee_type(c, holder); element != INVALID_TYPE {
			paths = carrier_shape(c, element)
		}
		if len(paths) < 2 {
			// One carrier path in the storage is the slot's content, kept with
			// its place and type so a store of exactly that carrier replaces it
			// (`caller_replaces`), as `p^.head` with `p: ^mut One` and
			// `One :: struct { head: ^mut Node, count: int }`.
			whole := Carrier_Path{type = INVALID_TYPE}
			if len(paths) == 1 {
				whole = paths[0]
			}
			mutable := len(paths) == 1 ? paths[0].mutable : graph.loans[int(held)].mutable || reaches_mutable
			prov_caller_slot(graph, Loan_Id(index), whole, held, name, mutable, one)
			continue
		}
		// `paths` are what a load one below this loan's reads, its `last_load_shape`
		// at `held`'s depth, unless `held` is this loan: the last content loan,
		// standing for every depth below it.
		names_last := graph.loans[int(held)].depth == loan.depth + 1
		for path, position in paths {
			// Each carrier in one storage holds a loan of its own, as each
			// pointee path's does, so what `p^^.head` and `p^^.tail` point at
			// are told apart, and a result's contract says which it holds. Loads
			// below it read what `held` stands for.
			own := held
			if one {
				own = prov_new_content_loan(
					graph, root, nil, path.mutable, descriptor.span, carrier_path_noun(c, path),
					graph.loans[int(held)].depth, graph.loans[int(held)].pointee,
				)
				if names_last {
					graph.loans[int(own)].last = position + 1
				}
			}
			prov_caller_slot(graph, Loan_Id(index), path, own, name, path.mutable, one)
		}
	}
}

// What a pointer or slice of `type` points at, or INVALID_TYPE.
@(private = "file")
prov_pointee_type :: proc(c: ^Compiler, type: Type_Id) -> Type_Id {
	if info := underlying_info(c, type); type != INVALID_TYPE && info != nil && (info.kind == .Pointer || info.kind == .Slice) {
		return info.element
	}
	return INVALID_TYPE
}

@(private = "file")
prov_caller_slot :: proc(
	graph: ^Flow_Graph, loan: Loan_Id, path: Carrier_Path, held: Loan_Id, name: string, mutable: bool, one: bool,
) {
	entry := empty_prov_slot(INVALID_SYMBOL)
	entry.kind = .Caller
	entry.name = name
	entry.path = path.steps
	entry.content_type = path.truncated ? INVALID_TYPE : path.type
	entry.content_truncated = path.truncated
	entry.caller_mutable = mutable
	entry.caller_one = one
	slot := prov_add_slot(graph, entry)
	if loan not_in graph.caller_slots {
		graph.caller_slots[loan] = make([dynamic]int, 0, 4, graph.alloc)
	}
	append(&graph.caller_slots[loan], slot)
	append(&graph.entry_defs, Prov_Entry_Def{slot = slot, loan = held})
}

// One element of a view parameter's caller storage (`prov_view_element`).
Prov_View_Element :: struct {
	loan:  Loan_Id,
	index: i64,
}

// design.md "Values that contain borrows": a parameter binding is read-only, so
// `s[k]`, with `s` a view parameter and `k` a constant, always names one element of
// the caller's view (`caller_replaces`). It gets slots of its own beside those for
// every element (`prov_caller_slots`). False when `place` names no such element.
@(private)
prov_view_element :: proc(graph: ^Flow_Graph, place: Expr) -> (Prov_Element_Slots, bool) {
	c := graph.k.c
	view, element, found_element := prov_constant_view_element(graph, place)
	if !found_element {
		return {}, false
	}
	root, own := prov_view_parameter_loan(graph, view)
	if own == NO_LOAN {
		return {}, false
	}
	key := Prov_View_Element{loan = own, index = element}
	slots, found := graph.view_elements[key]
	if !found {
		// As `prov_caller_slots` makes the slots standing for every element.
		descriptor := graph.roots[int(root)]
		pointee := carrier_pointee_shape(c, symbol_of(c, view).type)
		first := len(graph.prov_slots)
		if len(descriptor.pointee_loans) > 0 {
			for loans, position in descriptor.pointee_loans {
				prov_caller_slot(graph, own, pointee[position], loans[0], descriptor.name, pointee[position].mutable, false)
			}
		} else if len(pointee) == 1 {
			held := Loan_Id(deeper_content_loan(descriptor, graph.loans[int(own)], int(own)))
			prov_caller_slot(graph, own, pointee[0], held, descriptor.name, pointee[0].mutable, false)
		}
		slots = make([]int, len(graph.prov_slots) - first, graph.alloc)
		for &slot, at in slots {
			slot = first + at
			graph.prov_slots[slot].caller_element = true
		}
		graph.view_elements[key] = slots
	}
	if len(slots) == 0 {
		return {}, false
	}
	return Prov_Element_Slots{own, slots}, true
}

// design.md "Places and overlap": whether `carriers` have only been defined to point into
// an element of a view parameter, as `p` is by `p := &mut s[0]`, so far as the walk has
// seen. Which element, and whether a definition it has yet to meet says otherwise, is for
// the solve (`carriers_element`).
@(private)
prov_may_point_at_element :: proc(graph: ^Flow_Graph, carriers: []int) -> bool {
	for slot in carriers {
		entry := graph.prov_slots[slot]
		if !entry.element_defs || entry.other_defs {
			return false
		}
	}
	return len(carriers) > 0
}

// Records whether a definition of `slot` points it into an element of a view parameter
// (`Prov_Slot.element_defs`): a borrow of that itself, or a copy of what only has been.
@(private)
prov_note_element_pointer :: proc(graph: ^Flow_Graph, event: Prov_Event) {
	if event.place_loan > 0 {
		return
	}
	elements := false
	for source in event.sources {
		if prov_slot_is_through(graph, source) {
			continue
		}
		entry := graph.prov_slots[source]
		if !entry.element_defs || entry.other_defs {
			elements = false
			break
		}
		elements = true
	}
	slot := &graph.prov_slots[event.slot]
	if elements {
		slot.element_defs = true
	} else {
		slot.other_defs = true
	}
}

// design.md "Values that contain borrows": `s[k]`, with `s` a local view and `k` a
// constant, names one element of the storage a fresh `&mut a[lo:hi]` lends, when
// where `s` starts is known (`Prov_View_Def`) and nothing else writes `s`. The solve
// checks both (`publish_view_loan`). None when `place` names no such element.
@(private)
prov_local_view_element :: proc(graph: ^Flow_Graph, place: Expr) -> Prov_View_At {
	view, element, found_element := prov_constant_view_element(graph, place)
	if !found_element || symbol_of(graph.k.c, view).kind == .Parameter {
		return {}
	}
	slot, found := prov_slot_for_symbol(graph, view)
	if !found {
		return {}
	}
	return Prov_View_At{slot = slot + 1, index = element}
}

// The named view `s` and the constant `k` when `place` is `s[k]`, or a place
// inside it reached through selectors, with `k` nonnegative and `s`'s pointee
// holding the place: `s` is the one carrier it is reached through.
@(private)
prov_constant_view_element :: proc(graph: ^Flow_Graph, place: Expr) -> (Symbol_Id, i64, bool) {
	c := graph.k.c
	// The subscript applied to a named view, found before the hops.
	index, operand: Expr
	for e := place; e != nil && index == nil; {
		#partial switch v in e {
		case ^Expr_Selector:
			e = v.operand
		case ^Expr_Index:
			if _, named := v.operand.(^Expr_Ident); named && len(v.indices) == 1 {
				index, operand = v.indices[0], v.operand
			}
			e = v.operand
		case:
			e = nil
		}
	}
	if index == nil {
		return INVALID_SYMBOL, 0, false
	}
	element, is_constant := prov_const_int(graph, index)
	ident := operand.(^Expr_Ident)
	sym := symbol_of(c, ident.symbol)
	if !is_constant || element < 0 || sym == nil || underlying_kind(c, sym.type) != .Slice {
		return INVALID_SYMBOL, 0, false
	}
	hops := prov_place_hops(graph, place)
	if len(hops) != 1 || expr_base(prov_value(graph, hops[0].carrier).origin) != expr_base(operand) {
		return INVALID_SYMBOL, 0, false
	}
	return ident.symbol, element, true
}

// The root of `view` when it is a view parameter, whose binding is read-only,
// and its own loan, the first not standing for content; NO_LOAN otherwise.
@(private)
prov_view_parameter_loan :: proc(graph: ^Flow_Graph, view: Symbol_Id) -> (Root_Id, Loan_Id) {
	if found, cached := graph.view_parameter_loans[view]; cached {
		return found.root, found.own
	}
	sym := symbol_of(graph.k.c, view)
	if sym == nil || sym.kind != .Parameter || !sym.immutable {
		return NO_ROOT, NO_LOAN
	}
	root := NO_ROOT
	for entry, at in graph.roots {
		if entry.kind == .Param && entry.symbol == view {
			root = Root_Id(at)
			break
		}
	}
	if root == NO_ROOT {
		return NO_ROOT, NO_LOAN
	}
	for loan, at in graph.loans {
		if loan.root == root && !loan.content {
			graph.view_parameter_loans[view] = {root, Loan_Id(at)}
			return root, Loan_Id(at)
		}
	}
	return NO_ROOT, NO_LOAN
}

Prov_View_Parameter_Loan :: struct {
	root: Root_Id,
	own:  Loan_Id,
}

// `prov_view_element` for a store of `stored` at `target`, whose copies reborrow
// the slots of that element it lands in (`prov_link_landed`).
@(private)
prov_view_element_store :: proc(graph: ^Flow_Graph, target: Expr, stored: Type_Id) -> (Prov_Element_Slots, bool) {
	if !prov_store_linked(graph.k.c, stored) {
		return {}, false
	}
	element, found := prov_view_element(graph, target)
	if !found {
		return {}, false
	}
	below := prov_place_hops(graph, target)[0].path
	if !path_is_exact(below) {
		return {}, false
	}
	return element, true
}

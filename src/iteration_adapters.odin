// Fallback iterable adapters used when the source has no matching member.
package lokec

import "core:fmt"

Adapter_Kind :: enum { None, Indexed, Reversed, Copied }
Adapter_Key :: struct { source: Type_Id, kind: Adapter_Kind, pkg: Package_Id }

// Peel contributed adapters so foreach can use direct loop lowering.
peel_resolved_adapter :: proc(k: ^Checker, s: ^Stmt_Foreach) -> Name {
	source := s.iterable
	indexed, reversed := false, false
	reported: Name
	for {
		call, ok := source.(^Expr_Call)
		if !ok { break }
		sym := symbol_of(k.c, call.resolution.chosen_overload)
		if sym == nil || sym.synth != .Adapter_View || len(call.bound) != 1 { break }
		// design.md "Iteration protocol": `&` asks the adapter's value, never its
		// root, so only a mutable view is peeled for a by-reference loop. Text and
		// ranges still peel, to be refused for producing values.
		if foreach_is_place_loop(s) && iteration_member(k, call.type, "iter_mut") == INVALID_SYMBOL &&
		   !adapter_source_produces_values(k.c, call.bound[0]) {
			break
		}
		kind := type_of(k.c, call.type).adapter_kind
		if kind == .Indexed {
			if indexed || reversed { return Name{} }
			indexed = true
		} else if kind == .Reversed {
			if reversed { return Name{} }
			reversed = true
		} else {
			break // copied() is a real protocol view, not a direct-header hint
		}
		if selector, selected := call.callee.(^Expr_Selector); selected { reported = selector.name }
		source = call.bound[0]
	}
	s.iterable, s.indexed = source, indexed
	if reversed { s.adapter = .Reversed }
	return reported
}

@(private = "file")
adapter_source_produces_values :: proc(c: ^Compiler, source: Expr) -> bool {
	if _, written := source.(^Expr_Range); written { return true }
	info := underlying_info(c, expr_base(source).type)
	return info != nil && (info.is_range || info.kind == .String || info.kind == .String_View)
}

// Whether indexed() preserves a pointer lent by its source.
indexed_next_lends :: proc(c: ^Compiler, callee: ^Symbol) -> bool {
	if callee.synth != .Indexed_Next || len(callee.params) == 0 {
		return false
	}
	handed := underlying_info(c, option_payload(c, callee.result))
	element := underlying_info(c, type_of(c, type_underlying(c, callee.params[0])).element)
	if handed == nil || element == nil || len(handed.fields) == 0 || len(element.fields) == 0 {
		return false
	}
	lent, held := symbol_of(c, handed.fields[ELEMENT_FIRST]), symbol_of(c, element.fields[ELEMENT_FIRST])
	// A mutable part is lent by the iterator, and ends before it advances.
	return lent != nil && held != nil && lent.type != held.type && !type_carries_borrow(c, lent.type).mutable
}

iteration_adapter_member :: proc(k: ^Checker, source: Type_Id, name: Identifier_Id) -> Symbol_Id {
	kind := Adapter_Kind.None
	switch identifier_text(k.c, name) {
	case "indexed": kind = .Indexed
	case "reversed": kind = .Reversed
	case "copied": kind = .Copied
	case: return INVALID_SYMBOL
	}
	key := Adapter_Key{source, kind, lookup_package(k)}
	if existing, found := k.c.adapter_members[key]; found { return existing }
	element := associated_type_of(k, source, "Element")
	iterator := associated_type_of(k, source, "Iterator")
	iter := iteration_member(k, source, "iter")
	if !iteration_proc_matches(k, symbol_of(k.c, iter), source, .Borrow, iterator) ||
	   element == INVALID_TYPE || iterator == INVALID_TYPE { return INVALID_SYMBOL }
	next := iteration_member(k, iterator, "next")
	source_yield, described := iterator_yield(k, iterator, no_span(), report = false)
	if !described {
		return INVALID_SYMBOL
	}
	item := yield_item_type(k, element, source_yield, no_span(), report = false)
	if item == INVALID_TYPE ||
	   !iteration_proc_matches(k, symbol_of(k.c, next), iterator, .Inout, option_type(k, item)) {
		return INVALID_SYMBOL
	}
	// indexed() preserves the source yield and owns only its counter.
	lends := kind == .Indexed && !yield_is_owned(source_yield)
	if kind == .Copied && !yield_borrowed_parts_copyable(k.c, element, source_yield) {
		return INVALID_SYMBOL
	}
	forward, backward := iter, INVALID_SYMBOL
	if kind == .Reversed {
		forward = iteration_member(k, source, "iter_reverse")
		if !iteration_proc_matches(k, symbol_of(k.c, forward), source, .Borrow, iterator) {
			return INVALID_SYMBOL
		}
		backward = iter
	} else if kind == .Copied {
		reverse := iteration_member(k, source, "iter_reverse")
		if iteration_proc_matches(k, symbol_of(k.c, reverse), source, .Borrow, iterator) {
			backward = reverse
		}
	}
	c := k.c
	label := kind == .Indexed ? "Indexed" : kind == .Copied ? "Copied" : "Reversed"
	view := new_type(c, Type_Info{
		kind = .Struct, name = intern_identifier(c, fmt.aprintf("%s(%s)", label, type_name(c, source), allocator = c.semantic_allocator)),
		key = source, element = element, is_view = true, adapter_kind = kind,
	})
	// Nested views own their small source descriptor, and so does a mutable
	// view, whose capability is in the value rather than in a place.
	source_info := underlying_info(c, source)
	by_value := source_info.is_view || source_info.is_range || source_info.kind == .Slice ||
	            source_info.kind == .String_View || is_mutable_view(k, source)
	held := by_value ? source : TYPE_RAWPTR
	fields := make([]Symbol_Id, 1, c.semantic_allocator)
	fields[0] = new_field(c, "source", held, 0, public = false)
	view_info := type_of(c, view)
	view_info.fields = fields
	view_info.adapter_by_value = by_value
	view_info.descriptor = type_is_compile_time_only(c, source)
	view_info.contributed += {.Iteration}
	view_info.mangled = fmt.aprintf("%s.%d.%d", label, source, key.pkg, allocator = c.semantic_allocator)
	result_iterator := iterator
	if kind == .Indexed {
		element = indexed_element_type(c, element)
		result_iterator = new_type(c, Type_Info{
			kind = .Struct, name = intern_identifier(c, fmt.aprintf("Indexed_Iterator(%s)", type_name(c, iterator), allocator = c.semantic_allocator)),
			key = iterator, element = element, adapter_kind = .Indexed,
		})
		iterator_fields := make([]Symbol_Id, 2, c.semantic_allocator)
		iterator_fields[0] = new_field(c, "iterator", iterator, 0, public = false)
		iterator_fields[1] = new_field(c, "index", TYPE_INT, 1, public = false)
		result_info := type_of(c, result_iterator)
		result_info.fields = iterator_fields
		result_info.descriptor = type_is_compile_time_only(c, source)
		result_info.mangled = fmt.aprintf("Indexed_Iterator.%d", view, allocator = c.semantic_allocator)
		result_info.contributed += {.Iteration}
		yielded := element
		indexed_yield := Yield_Desc{}
		if lends {
			lent := []Yield_Desc{source_yield, {kind = .Owned}}
			indexed_yield = Yield_Desc{kind = .Record, fields = lent}
			yielded = yield_item_type(
				k, element, indexed_yield, no_span(), report = false,
			)
			if yielded == INVALID_TYPE {
				return INVALID_SYMBOL
			}
		}
		next_member := adapter_proc(k, "next", .Indexed_Next, result_iterator, .Inout, option_type(k, yielded), next)
		copy_member := adapter_proc(k, "iter", .Iterator_Copy, result_iterator, .Borrow, result_iterator)
		members := make([dynamic]Symbol_Id, 0, 5, context.temp_allocator)
		append(&members, new_associated_type(c, "Element", element, result_iterator))
		append(&members, new_associated_type(c, "Iterator", result_iterator, result_iterator))
		append(&members, next_member, copy_member)
		if lends {
			descriptor := yield_desc_type(c, element, indexed_yield)
			if descriptor == INVALID_TYPE { return INVALID_SYMBOL }
			append(&members, new_associated_type(c, "Yield", descriptor, result_iterator))
		}
		add_members(c, result_iterator, members[:])
		if type_is_managed(c, result_iterator) { contribute_lifecycle_members(k, result_iterator) }
	} else if kind == .Copied {
		result_iterator = new_type(c, Type_Info{
			kind = .Struct, name = intern_identifier(c, fmt.aprintf("Copied_Iterator(%s)", type_name(c, iterator), allocator = c.semantic_allocator)),
			key = iterator, element = element, adapter_kind = .Copied,
		})
		copied_fields := make([]Symbol_Id, 1, c.semantic_allocator)
		copied_fields[0] = new_field(c, "iterator", iterator, 0, public = false)
		result_info := type_of(c, result_iterator)
		result_info.fields = copied_fields
		result_info.descriptor = type_is_compile_time_only(c, source)
		result_info.mangled = fmt.aprintf("Copied_Iterator.%d", view, allocator = c.semantic_allocator)
		result_info.contributed += {.Iteration}
		next_member := adapter_proc(k, "next", .Copied_Next, result_iterator, .Inout, option_type(k, element), next)
		copy_member := adapter_proc(k, "iter", .Iterator_Copy, result_iterator, .Borrow, result_iterator)
		add_members(c, result_iterator, []Symbol_Id{
			new_associated_type(c, "Element", element, result_iterator),
			new_associated_type(c, "Iterator", result_iterator, result_iterator),
			next_member, copy_member,
		})
		if type_is_managed(c, result_iterator) { contribute_lifecycle_members(k, result_iterator) }
	}
	iter_member := adapter_proc(k, "iter", .Adapter_Iter, view, .Borrow, result_iterator, forward)
	add_members(c, view, []Symbol_Id{
		new_associated_type(c, "Element", element, view),
		new_associated_type(c, "Iterator", result_iterator, view), iter_member,
	})
	if backward != INVALID_SYMBOL {
		add_members(c, view, []Symbol_Id{adapter_proc(k, "iter_reverse", .Adapter_Iter, view, .Borrow, result_iterator, backward)})
	}
	if by_value && kind != .Copied {
		add_mutable_adapter_members(k, view, source, kind)
	}
	member := adapter_proc(k, identifier_text(c, name), .Adapter_View, source, .Borrow, view)
	c.adapter_members[key] = member
	return member
}

// A type whose `iter_mut` takes no `inout` receiver: any value of it walks
// mutably (design.md "By-reference iteration").
is_mutable_view :: proc(k: ^Checker, type: Type_Id) -> bool {
	iterator := associated_type_of(k, type, "Mut_Iterator")
	if iterator == INVALID_TYPE { return false }
	receiver, found := mutable_iteration_receiver(k, iteration_member(k, type, "iter_mut"), type, iterator)
	return found && receiver != .Inout
}

// design.md "Iteration adapters": over a mutable view the adapter is a mutable
// view too, holding its source by value and walking it through the source's own
// `iter_mut`. Over a container it stays a read view.
@(private = "file")
add_mutable_adapter_members :: proc(k: ^Checker, view, source: Type_Id, kind: Adapter_Kind) {
	c := k.c
	element := associated_type_of(k, source, "Element")
	iterator := associated_type_of(k, source, "Mut_Iterator")
	iter := iteration_member(k, source, "iter_mut")
	receiver, found := mutable_iteration_receiver(k, iter, source, iterator)
	if element == INVALID_TYPE || iterator == INVALID_TYPE || !found || receiver == .Inout {
		return
	}
	yield, described := mutable_iterator_yield(k, iterator, no_span())
	if !described { return }
	item := yield_item_type(k, element, yield, no_span(), report = false)
	next := iteration_member(k, iterator, "next")
	if item == INVALID_TYPE || !iteration_proc_matches(k, symbol_of(c, next), iterator, .Inout, option_type(k, item)) {
		return
	}
	if kind == .Reversed {
		reverse := iteration_member(k, source, "iter_mut_reverse")
		if _, reversible := mutable_iteration_receiver(k, reverse, source, iterator); !reversible { return }
		add_members(c, view, []Symbol_Id{
			new_associated_type(c, "Mut_Iterator", iterator, view),
			adapter_proc(k, "iter_mut", .Adapter_Iter, view, .Borrow, iterator, reverse),
			adapter_proc(k, "iter_mut_reverse", .Adapter_Iter, view, .Borrow, iterator, iter),
		})
		type_of(c, view).mutable = true
		return
	}
	// `indexed()` lends the source's parts as the source does and owns its counter.
	indexed := indexed_element_type(c, element)
	parts := make([]Yield_Desc, 2, c.semantic_allocator)
	parts[0], parts[1] = yield, Yield_Desc{kind = .Owned}
	numbered := Yield_Desc{kind = .Record, fields = parts}
	yielded := yield_item_type(k, indexed, numbered, no_span(), report = false)
	descriptor := yield_desc_type(c, indexed, numbered)
	if yielded == INVALID_TYPE || descriptor == INVALID_TYPE { return }
	walker := new_type(c, Type_Info{
		kind = .Struct, name = intern_identifier(c, fmt.aprintf("Indexed_Iterator(%s)", type_name(c, iterator), allocator = c.semantic_allocator)),
		key = iterator, element = indexed, adapter_kind = .Indexed,
	})
	fields := make([]Symbol_Id, 2, c.semantic_allocator)
	fields[0] = new_field(c, "iterator", iterator, 0, public = false)
	fields[1] = new_field(c, "index", TYPE_INT, 1, public = false)
	walker_info := type_of(c, walker)
	walker_info.fields = fields
	walker_info.mangled = fmt.aprintf("Indexed_Mut_Iterator.%d", view, allocator = c.semantic_allocator)
	walker_info.contributed += {.Iteration}
	add_members(c, walker, []Symbol_Id{
		adapter_proc(k, "next", .Indexed_Next, walker, .Inout, option_type(k, yielded), next),
		new_associated_type(c, "Yield", descriptor, walker),
	})
	add_members(c, view, []Symbol_Id{
		new_associated_type(c, "Mut_Iterator", walker, view),
		adapter_proc(k, "iter_mut", .Adapter_Iter, view, .Borrow, walker, iter),
	})
	type_of(c, view).mutable = true
}

// copied() clones lent leaves and passes owned leaves through.
yield_borrowed_parts_copyable :: proc(c: ^Compiler, element: Type_Id, desc: Yield_Desc) -> bool {
	switch desc.kind {
	case .Owned:
		return true
	case .Borrowed, .Mutable:
		return !type_clone_disabled(c, element)
	case .Record:
	}
	info := underlying_info(c, element)
	if info == nil || info.kind != .Struct || len(info.fields) != len(desc.fields) { return false }
	for field_id, index in info.fields {
		field := symbol_of(c, field_id)
		if field == nil || !yield_borrowed_parts_copyable(c, field.type, desc.fields[index]) { return false }
	}
	return true
}

adapter_proc :: proc(k: ^Checker, name: string, kind: Synth_Kind, owner: Type_Id, mode: Param_Mode, result: Type_Id, target := INVALID_SYMBOL) -> Symbol_Id {
	id := synth_proc(k.c, name, kind, owner, []Type_Id{owner}, []Param_Mode{mode}, result)
	sym := symbol_of(k.c, id)
	sym.has_receiver, sym.receiver, sym.iteration_target = true, mode, target
	set_synth_result_summary(k.c, id, 0)
	return id
}

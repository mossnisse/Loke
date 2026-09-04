// Ordinary borrowed iterable adapters. Lookup supplies these only when the
// source has no visible member of its own with the requested name.
package lokec

import "core:fmt"

Adapter_Kind :: enum { None, Indexed, Reversed }
Adapter_Key :: struct { source: Type_Id, kind: Adapter_Kind, pkg: Package_Id }

// Preserve the existing direct loop lowering only after ordinary member
// resolution has proved this is a contributed adapter chain.
peel_resolved_adapter :: proc(k: ^Checker, s: ^Stmt_Foreach) -> Name {
	source := s.iterable
	indexed, reversed := false, false
	reported: Name
	for {
		call, ok := source.(^Expr_Call)
		if !ok { break }
		sym := symbol_of(k.c, call.resolution.chosen_overload)
		if sym == nil || sym.synth != .Adapter_View || len(call.bound) != 1 { break }
		kind := type_of(k.c, call.type).adapter_kind
		if kind == .Indexed {
			if indexed || reversed { return Name{} }
			indexed = true
		} else {
			if reversed { return Name{} }
			reversed = true
		}
		if selector, selected := call.callee.(^Expr_Selector); selected { reported = selector.name }
		source = call.bound[0]
	}
	s.iterable, s.indexed = source, indexed
	if reversed { s.adapter = .Reversed }
	return reported
}

iteration_adapter_member :: proc(k: ^Checker, source: Type_Id, name: Identifier_Id) -> Symbol_Id {
	kind := Adapter_Kind.None
	switch identifier_text(k.c, name) {
	case "indexed": kind = .Indexed
	case "reversed": kind = .Reversed
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
	if !iteration_proc_matches(k, symbol_of(k.c, next), iterator, .Inout, option_type(k, element)) {
		return INVALID_SYMBOL
	}
	forward, backward := iter, INVALID_SYMBOL
	if kind == .Reversed {
		forward = iteration_member(k, source, "iter_reverse")
		if !iteration_proc_matches(k, symbol_of(k.c, forward), source, .Borrow, iterator) {
			return INVALID_SYMBOL
		}
		backward = iter
	}
	c := k.c
	label := kind == .Indexed ? "Indexed" : "Reversed"
	view := new_type(c, Type_Info{
		kind = .Struct, name = intern_identifier(c, fmt.aprintf("%s(%s)", label, type_name(c, source), allocator = c.semantic_allocator)),
		key = source, element = element, is_view = true, adapter_kind = kind,
	})
	// A view of another view owns its small descriptor. This makes chains like
	// `xs.reversed().indexed()` independent of intermediate temporary storage.
	source_info := underlying_info(c, source)
	by_value := source_info.is_view || source_info.is_range || source_info.kind == .Slice || source_info.kind == .String_View
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
			key = iterator, element = element,
		})
		iterator_fields := make([]Symbol_Id, 2, c.semantic_allocator)
		iterator_fields[0] = new_field(c, "iterator", iterator, 0, public = false)
		iterator_fields[1] = new_field(c, "index", TYPE_INT, 1, public = false)
		result_info := type_of(c, result_iterator)
		result_info.fields = iterator_fields
		result_info.descriptor = type_is_compile_time_only(c, source)
		result_info.mangled = fmt.aprintf("Indexed_Iterator.%d", view, allocator = c.semantic_allocator)
		result_info.contributed += {.Iteration}
		next_member := adapter_proc(k, "next", .Indexed_Next, result_iterator, .Inout, option_type(k, element), next)
		copy_member := adapter_proc(k, "iter", .Iterator_Copy, result_iterator, .Borrow, result_iterator)
		add_members(c, result_iterator, []Symbol_Id{
			new_associated_type(c, "Element", element, result_iterator),
			new_associated_type(c, "Iterator", result_iterator, result_iterator), next_member, copy_member,
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
	member := adapter_proc(k, identifier_text(c, name), .Adapter_View, source, .Borrow, view)
	c.adapter_members[key] = member
	return member
}

adapter_proc :: proc(k: ^Checker, name: string, kind: Synth_Kind, owner: Type_Id, mode: Param_Mode, result: Type_Id, target := INVALID_SYMBOL) -> Symbol_Id {
	id := synth_proc(k.c, name, kind, owner, []Type_Id{owner}, []Param_Mode{mode}, result)
	sym := symbol_of(k.c, id)
	sym.has_receiver, sym.receiver, sym.iteration_target = true, mode, target
	set_synth_result_summary(k.c, id, 0)
	return id
}

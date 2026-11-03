// Fallback iterable adapters used when the source has no matching member.
package lokec

import "core:fmt"

Adapter_Kind :: enum { None, Indexed, Reversed, Copied }
Adapter_Key :: struct { source: Type_Id, kind: Adapter_Kind, pkg: Package_Id }

// Peel contributed adapters so foreach can use direct loop lowering.
peel_resolved_adapter :: proc(k: ^Checker, s: ^Stmt_Foreach) {
	source := s.iterable
	indexed, reversed := false, false
	for {
		call, ok := source.(^Expr_Call)
		if !ok { break }
		sym := symbol_of(k.c, call.resolution.chosen_overload)
		if sym == nil || sym.synth != .Adapter_View || len(call.bound) != 1 { break }
		// design.md "Iteration protocol": `&mut` asks the adapter's value, never its
		// root, so only a mutable view is peeled for a by-reference loop. Text and
		// ranges still peel, to be refused for producing values, and a mutable view
		// too valuable to copy, which the adapter only borrows, walks in its place.
		if foreach_is_place_loop(s) && iteration_member(k, call.type, "iter_mut") == INVALID_SYMBOL &&
		   !adapter_source_produces_values(k.c, call.bound[0]) && !is_mutable_view(k, expr_base(call.bound[0]).type) {
			break
		}
		kind := type_of(k.c, call.type).adapter_kind
		if kind == .Indexed {
			if indexed || reversed { return }
			indexed = true
		} else if kind == .Reversed {
			if reversed { return }
			reversed = true
		} else {
			break // copied() is a real protocol view, not a direct-header hint
		}
		source = call.bound[0]
	}
	s.iterable, s.indexed = source, indexed
	if reversed { s.adapter = .Reversed }
}

@(private = "file")
adapter_source_produces_values :: proc(c: ^Compiler, source: Expr) -> bool {
	info := underlying_info(c, expr_base(source).type)
	return info != nil && (info.is_range || info.kind == .String || info.kind == .String_View)
}

// Whether indexed() preserves a pointer lent by its source.
indexed_next_lends :: proc(c: ^Compiler, callee: ^Symbol) -> bool {
	handed := underlying_info(c, option_payload(c, callee.result))
	element := underlying_info(c, type_of(c, type_underlying(c, callee.params[0])).element)
	lent, held := symbol_of(c, handed.fields[ELEMENT_FIRST]), symbol_of(c, element.fields[ELEMENT_FIRST])
	// A mutable part is lent by the iterator, and ends before it advances.
	return lent.type != held.type && !type_carries_borrow(c, lent.type).mutable
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
	next, source_yield, item, usable := adapter_source_next(k, iterator, element, .Owned)
	if !usable || (kind == .Copied && !yield_borrowed_parts_copyable(k.c, element, source_yield)) {
		return INVALID_SYMBOL
	}
	reverse := iteration_member(k, source, "iter_reverse")
	reversible := iteration_proc_matches(k, symbol_of(k.c, reverse), source, .Borrow, iterator)
	if kind == .Reversed && !reversible { return INVALID_SYMBOL }
	forward, backward := iter, INVALID_SYMBOL
	if kind == .Reversed {
		forward, backward = reverse, iter
	} else if kind == .Copied && reversible {
		backward = reverse
	}
	c := k.c
	label := kind == .Indexed ? "Indexed" : kind == .Copied ? "Copied" : "Reversed"
	// Nested views own their small source descriptor, and so does a mutable
	// view, whose capability is in the value rather than in a place. Holding
	// one copies it, so one that cannot be copied stays borrowed.
	source_info := underlying_info(c, source)
	by_value := source_info.is_view || source_info.is_range || source_info.kind == .Slice ||
	            source_info.kind == .String_View || (is_mutable_view(k, source) && !type_clone_disabled(c, source))
	fields := make([]Symbol_Id, 1, c.semantic_allocator)
	fields[0] = new_field(c, "source", by_value ? source : TYPE_RAWPTR, 0, public = false)
	view := new_type(c, Type_Info{
		kind = .Struct, name = intern_identifier(c, fmt.tprintf("%s(%s)", label, type_name(c, source))),
		key = source, element = element, is_view = true, adapter_kind = kind,
		fields = fields, adapter_by_value = by_value, descriptor = type_is_compile_time_only(c, source),
		contributed = {.Iteration},
		backend_label = fmt.aprintf("%s.%d.%d", label, source, key.pkg, allocator = c.semantic_allocator),
	})
	result_iterator := iterator
	if kind == .Indexed {
		element, item = indexed_element_type(c, element), indexed_element_type(c, item)
	}
	if kind != .Reversed {
		result_iterator = new_wrapping_iterator(k, kind, source, iterator, element, item, next, view)
	}
	iter_member := synth_self_member(k.c, "iter", .Adapter_Iter, view, .Borrow, result_iterator, forward)
	add_members(c, view, []Symbol_Id{
		new_associated_type(c, "Element", element, view),
		new_associated_type(c, "Iterator", result_iterator, view), iter_member,
	})
	if backward != INVALID_SYMBOL {
		add_members(c, view, []Symbol_Id{synth_self_member(k.c, "iter_reverse", .Adapter_Iter, view, .Borrow, result_iterator, backward)})
	}
	if by_value && kind != .Copied {
		add_mutable_adapter_members(k, view, source, kind)
	}
	// The view keeps its own copy of a source that owns something.
	if by_value && type_is_managed(c, source) { contribute_lifecycle_members(k, source) }
	member := synth_self_member(k.c, identifier_text(c, name), .Adapter_View, source, .Borrow, view)
	c.adapter_members[key] = member
	return member
}

// The iterator's `next`, how it yields against `element`, and what it hands back,
// when it is a `next` the protocol can call.
@(private = "file")
adapter_source_next :: proc(k: ^Checker, iterator, element: Type_Id, fallback: Yield_Kind) -> (next: Symbol_Id, yield: Yield_Desc, item: Type_Id, ok: bool) {
	next = iteration_member(k, iterator, "next")
	yield = iterator_yield(k, iterator, element, fallback)
	item = iterator_item_type(k, iterator, element, yield, no_span(), report = false)
	ok = item != INVALID_TYPE && iteration_proc_matches(k, symbol_of(k.c, next), iterator, .Inout, option_type(k, item))
	return
}

// The iterator `indexed()` or `copied()` wraps around its source's, named for the
// view it serves. `indexed()` adds the counter.
@(private = "file")
new_adapter_iterator :: proc(k: ^Checker, backend_label: string, kind: Adapter_Kind, source, iterator, element, view: Type_Id) -> Type_Id {
	c := k.c
	fields := make([]Symbol_Id, kind == .Indexed ? 2 : 1, c.semantic_allocator)
	fields[0] = new_field(c, "iterator", iterator, 0, public = false)
	if kind == .Indexed { fields[1] = new_field(c, "index", TYPE_INT, 1, public = false) }
	return new_type(c, Type_Info{
		kind = .Struct,
		name = intern_identifier(c, fmt.tprintf("%s_Iterator(%s)", kind == .Indexed ? "Indexed" : "Copied", type_name(c, iterator))),
		key = iterator, element = element, adapter_kind = kind, fields = fields,
		descriptor = type_is_compile_time_only(c, source), contributed = {.Iteration},
		backend_label = fmt.aprintf("%s.%d", backend_label, view, allocator = c.semantic_allocator),
	})
}

// The self-iterable iterator of a read-only `indexed()` or `copied()`. A `copied()`
// hands back its `Element`, and an `indexed()` what `item` says.
@(private = "file")
new_wrapping_iterator :: proc(k: ^Checker, kind: Adapter_Kind, source, iterator, element, item: Type_Id, next: Symbol_Id, view: Type_Id) -> Type_Id {
	c := k.c
	indexed := kind == .Indexed
	wrapper := new_adapter_iterator(k, indexed ? "Indexed_Iterator" : "Copied_Iterator", kind, source, iterator, element, view)
	yielded := indexed ? item : element
	add_members(c, wrapper, []Symbol_Id{
		new_associated_type(c, "Element", element, wrapper),
		new_associated_type(c, "Iterator", wrapper, wrapper),
		synth_self_member(k.c, "next", indexed ? .Indexed_Next : .Copied_Next, wrapper, .Inout, option_type(k, yielded), next),
		synth_self_member(k.c, "iter", .Iterator_Copy, wrapper, .Borrow, wrapper),
	})
	if type_is_managed(c, wrapper) { contribute_lifecycle_members(k, wrapper) }
	return wrapper
}

// A type whose `iter_mut` takes no `inout` receiver: any value of it walks
// mutably (design.md "By-reference iteration").
is_mutable_view :: proc(k: ^Checker, type: Type_Id) -> bool {
	protocol, found := mutable_protocol(k, type)
	return found && protocol.receiver != .Inout
}

// design.md "Iteration adapters": over a mutable view, an adapter walks its
// source through the source's own `iter_mut`.
@(private = "file")
add_mutable_adapter_members :: proc(k: ^Checker, view, source: Type_Id, kind: Adapter_Kind) {
	protocol, found := mutable_protocol(k, source)
	if !found || protocol.receiver == .Inout { return }
	c := k.c
	element, iterator, iter := protocol.element, protocol.iterator, protocol.iter
	next, _, item, usable := adapter_source_next(k, iterator, element, .Mutable)
	if !usable { return }
	if kind == .Reversed {
		reverse := iteration_member(k, source, "iter_mut_reverse")
		if _, reversible := mutable_iteration_receiver(k, reverse, source, iterator); !reversible { return }
		add_members(c, view, []Symbol_Id{
			new_associated_type(c, "Mut_Iterator", iterator, view),
			synth_self_member(k.c, "iter_mut", .Adapter_Iter, view, .Borrow, iterator, reverse),
			synth_self_member(k.c, "iter_mut_reverse", .Adapter_Iter, view, .Borrow, iterator, iter),
		})
		type_of(c, view).mutable = true
		return
	}
	walker := new_adapter_iterator(k, "Indexed_Mut_Iterator", .Indexed, source, iterator, indexed_element_type(c, element), view)
	add_members(c, walker, []Symbol_Id{
		synth_self_member(k.c, "next", .Indexed_Next, walker, .Inout, option_type(k, indexed_element_type(c, item)), next),
	})
	add_members(c, view, []Symbol_Id{
		new_associated_type(c, "Mut_Iterator", walker, view),
		synth_self_member(k.c, "iter_mut", .Adapter_Iter, view, .Borrow, walker, iter),
	})
	type_of(c, view).mutable = true
}

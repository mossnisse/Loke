// Fallback iterable adapters used when the source has no matching member.
package lokec

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
	for at := s.iterable; at != source; {
		call := at.(^Expr_Call)
		call.adapter_peeled = true
		at = call.bound[0]
	}
	s.iterable, s.indexed, s.reversed = source, indexed, reversed
}

@(private = "file")
adapter_source_produces_values :: proc(c: ^Compiler, source: Expr) -> bool {
	info := underlying_info(c, expr_base(source).type)
	return info != nil && (info.is_range || info.kind == .String || info.kind == .String_View)
}

// Whether indexed() preserves a pointer lent by its source.
indexed_next_lends :: proc(c: ^Compiler, callee: ^Symbol) -> bool {
	handed := underlying_info(c, option_payload(c, callee.result))
	element := underlying_info(c, underlying_info(c, callee.params[0]).element)
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
	protocol, found := read_protocol(k, source)
	if !found { return INVALID_SYMBOL }
	element, iterator, iter := protocol.element, protocol.iterator, protocol.iter
	next, source_yield, item, usable := protocol_next(k, iterator, element, .Owned, NO_SPAN, report = false)
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
	// A range, slice, or text view is its own small descriptor, and the adapter
	// holds it. A mutable view's capability is in the value rather than in a
	// place, so an adapter that walks it mutably, and is a mutable view itself,
	// holds a copy of it unless it cannot be copied. Any other adapter borrows a
	// mutable view, as it does a container: `copied()` and a `reversed()` without
	// the source's `iter_mut_reverse` walk it only through `iter(self: ^)`, and a
	// copy would buy them nothing. A read-only view another adapter made holds only
	// such descriptors and borrows, so holding it copies nothing either.
	source_info := underlying_info(c, source)
	walk, walks_mutably := mutable_adapter_walk(k, source, kind)
	by_value := source_info.is_range || source_info.kind == .Slice || source_info.kind == .String_View
	if is_mutable_view(k, source) {
		by_value ||= walks_mutably && (source_info.is_view || !type_clone_disabled(c, source))
	} else {
		by_value ||= source_info.is_view
	}
	view := new_owned_record(c, label, source, {ADAPTER_SOURCE = {"source", by_value ? source : TYPE_RAWPTR, false}}, {
		key = source, element = element, is_view = true, adapter_kind = kind,
		adapter_by_value = by_value, descriptor = type_is_compile_time_only(c, source),
		contributed = {.Iteration}, site = Type_Site{pkg = key.pkg},
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
	if by_value && walks_mutably {
		add_mutable_adapter_members(k, view, source, kind, walk)
	}
	// The view keeps its own copy of a source that owns something.
	if by_value && type_is_managed(c, source) { contribute_lifecycle_members(k, source) }
	member := synth_self_member(k.c, identifier_text(c, name), .Adapter_View, source, .Borrow, view)
	c.adapter_members[key] = member
	return member
}

// The iterator `indexed()` or `copied()` wraps around its source's, named for the
// view it serves. `indexed()` adds the counter.
@(private = "file")
new_adapter_iterator :: proc(k: ^Checker, kind: Adapter_Kind, source, iterator, element, view: Type_Id) -> Type_Id {
	fields := []Owned_Field{ITER_ADAPTER_INNER = {"iterator", iterator, false}, ITER_ADAPTER_INDEX = {"index", TYPE_INT, false}}
	return new_owned_record(k.c, kind == .Indexed ? "Indexed_Iterator" : "Copied_Iterator", iterator, fields[:kind == .Indexed ? 2 : 1], {
		key = iterator, element = element, adapter_kind = kind,
		descriptor = type_is_compile_time_only(k.c, source), contributed = {.Iteration},
		site = type_of(k.c, view).site,
	})
}

// The self-iterable iterator of a read-only `indexed()` or `copied()`. A `copied()`
// hands back its `Element`, and an `indexed()` what `item` says.
@(private = "file")
new_wrapping_iterator :: proc(k: ^Checker, kind: Adapter_Kind, source, iterator, element, item: Type_Id, next: Symbol_Id, view: Type_Id) -> Type_Id {
	c := k.c
	indexed := kind == .Indexed
	wrapper := new_adapter_iterator(k, kind, source, iterator, element, view)
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

// How an adapter of `kind` walks a mutable-view source mutably: the source's
// `iter_mut`, its iterator's `next`, and for `reversed()` its `iter_mut_reverse`.
@(private = "file")
Mutable_Adapter_Walk :: struct {
	protocol: Mutable_Protocol,
	next:     Symbol_Id,
	item:     Type_Id,
	reverse:  Symbol_Id,
}

// design.md "Iteration adapters": whether an adapter of `kind` over `source`
// walks it mutably, which makes the adapter a mutable view. `copied()` never
// does, and `reversed()` needs the source's `iter_mut_reverse`.
@(private = "file")
mutable_adapter_walk :: proc(k: ^Checker, source: Type_Id, kind: Adapter_Kind) -> (walk: Mutable_Adapter_Walk, ok: bool) {
	if kind == .Copied { return }
	found: bool
	walk.protocol, found = mutable_protocol(k, source)
	if !found || walk.protocol.receiver == .Inout { return }
	walk.next, _, walk.item, ok = protocol_next(k, walk.protocol.iterator, walk.protocol.element, .Mutable, NO_SPAN, report = false)
	if !ok || kind != .Reversed { return }
	walk.reverse = iteration_member(k, source, "iter_mut_reverse")
	_, ok = mutable_iteration_receiver(k, walk.reverse, source, walk.protocol.iterator)
	return
}

// design.md "Iteration adapters": over a mutable view, an adapter walks its
// source through the source's own `iter_mut`.
@(private = "file")
add_mutable_adapter_members :: proc(k: ^Checker, view, source: Type_Id, kind: Adapter_Kind, walk: Mutable_Adapter_Walk) {
	c := k.c
	element, iterator, iter := walk.protocol.element, walk.protocol.iterator, walk.protocol.iter
	next, item, reverse := walk.next, walk.item, walk.reverse
	if kind == .Reversed {
		add_members(c, view, []Symbol_Id{
			new_associated_type(c, "Mut_Iterator", iterator, view),
			synth_self_member(k.c, "iter_mut", .Adapter_Iter, view, .Borrow, iterator, reverse),
			synth_self_member(k.c, "iter_mut_reverse", .Adapter_Iter, view, .Borrow, iterator, iter),
		})
		type_of(c, view).mutable = true
		return
	}
	walker := new_adapter_iterator(k, .Indexed, source, iterator, indexed_element_type(c, element), view)
	add_members(c, walker, []Symbol_Id{
		synth_self_member(k.c, "next", .Indexed_Next, walker, .Inout, option_type(k, indexed_element_type(c, item)), next),
	})
	add_members(c, view, []Symbol_Id{
		new_associated_type(c, "Mut_Iterator", walker, view),
		synth_self_member(k.c, "iter_mut", .Adapter_Iter, view, .Borrow, walker, iter),
	})
	type_of(c, view).mutable = true
}

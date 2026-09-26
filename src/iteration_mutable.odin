package lokec

import "core:fmt"

ensure_mutable_iteration_members :: proc(k: ^Checker, subject: Type_Id) {
	c := k.c
	info := type_of(c, subject)
	if info == nil || .Mutable_Iteration in info.contributed { return }
	info.contributed += {.Mutable_Iteration}
	if type_is_compile_time_only(c, subject) { return }
	if info.kind == .Map {
		// design.md "By-reference iteration": an entry lends its key read-only and
		// its value mutably, so the map is walked as `key, &value`.
		entry := map_entry_type(c, subject)
		iterator := new_type(c, Type_Info{
			kind = .Struct,
			name = intern_identifier(c, fmt.aprintf("Mutable_Map_Iterator(%s)", type_name(c, subject), allocator = c.semantic_allocator)),
			element = entry,
			key = subject, // `next` needs the map's operation table
			is_view = true,
		})
		fields := make([]Symbol_Id, 2, c.semantic_allocator)
		fields[ITER_MAP_TABLE] = new_field(c, "table", TYPE_RAWPTR, ITER_MAP_TABLE)
		fields[ITER_MAP_CURSOR] = new_field(c, "cursor", TYPE_INT, ITER_MAP_CURSOR)
		iterator_info := type_of(c, iterator)
		iterator_info.fields = fields
		iterator_info.mangled = fmt.aprintf("Mutable_Map_Iterator.%d", subject, allocator = c.semantic_allocator)
		parts := make([]Yield_Desc, 2, c.semantic_allocator)
		parts[0], parts[1] = Yield_Desc{kind = .Borrowed}, Yield_Desc{kind = .Mutable}
		lent := Yield_Desc{kind = .Record, fields = parts}
		item := yield_item_type(k, entry, lent, no_span(), report = false)
		next := adapter_proc(k, "next", .Map_Next, iterator, .Inout, option_type(k, item))
		add_members(c, iterator, []Symbol_Id{next})
		iter := adapter_proc(k, "iter_mut", .Map_Iter, subject, .Inout, iterator)
		add_members(c, subject, []Symbol_Id{new_associated_type(c, "Mut_Iterator", iterator, subject), iter})
		return
	}
	if info.kind != .Array && info.kind != .Dynamic_Array && !(info.kind == .Slice && info.mutable) { return }
	element := info.element
	constructor := info.kind == .Dynamic_Array ? Synth_Kind.Dynamic_Iter : Synth_Kind.Array_Iter
	iterator := new_type(c, Type_Info{kind = .Struct,
		name = intern_identifier(c, fmt.aprintf("Mutable_Iterator(%s)", type_name(c, subject), allocator = c.semantic_allocator)),
		element = element,
	})
	held := slice_of(c, element, true)
	fields := make([]Symbol_Id, 3, c.semantic_allocator)
	fields[0] = new_field(c, "items", held, 0, public = false)
	fields[1] = new_field(c, "index", TYPE_INT, 1, public = false)
	fields[2] = new_field(c, "reversed", TYPE_BOOL, 2, public = false)
	type_of(c, iterator).fields = fields
	type_of(c, iterator).mangled = fmt.aprintf("Mutable_Iterator.%d", subject, allocator = c.semantic_allocator)
	next := adapter_proc(k, "next", .Slice_Mut_Next, iterator, .Inout, option_type(k, pointer_to(c, element, true)))
	add_members(c, iterator, []Symbol_Id{next})
	// A `[]mut T` is a mutable view: any value of it walks mutably, so its
	// receiver is a value. A container needs its own mutable place.
	receiver := info.kind == .Slice ? Param_Mode.Value : Param_Mode.Inout
	iter := adapter_proc(k, "iter_mut", constructor, subject, receiver, iterator)
	reverse_kind := info.kind == .Dynamic_Array ? Synth_Kind.Dynamic_Iter_Reverse : Synth_Kind.Array_Iter_Reverse
	reverse := adapter_proc(k, "iter_mut_reverse", reverse_kind, subject, receiver, iterator)
	add_members(c, subject, []Symbol_Id{new_associated_type(c, "Mut_Iterator", iterator, subject), iter, reverse})
}

// design.md "By-reference iteration": `iter_mut` starts a mutable traversal and
// its iterator's `Yield` says which parts are lent mutably. An `iter_mut` taking
// `self: inout` belongs to a container, which must be a mutable place; any other
// receiver belongs to a mutable view, which any value of it is.
check_mutable_protocol_foreach :: proc(k: ^Checker, s: ^Stmt_Foreach, subject: Type_Id) -> Flow_Info {
	element := associated_type_of(k, subject, "Element")
	iterator := associated_type_of(k, subject, "Mut_Iterator")
	iter := iteration_member(k, subject, "iter_mut")
	receiver, found := mutable_iteration_receiver(k, iter, subject, iterator)
	if element == INVALID_TYPE || iterator == INVALID_TYPE || !found {
		report_not_mutably_iterable(k, s, subject)
		return FLOWS
	}
	if receiver == .Inout && !expr_base(s.iterable).assignable {
		report_not_assignable(k, expr_base(s.iterable), "a by-reference `foreach`")
		return FLOWS
	}
	if s.adapter == .Reversed {
		reverse := iteration_member(k, subject, "iter_mut_reverse")
		if _, reversible := mutable_iteration_receiver(k, reverse, subject, iterator); !reversible {
			errorf(k.c, expr_span(s.iterable), "L0460", "`%s` cannot be reversed mutably: it needs `iter_mut_reverse`", type_name(k.c, subject))
			return FLOWS
		}
		iter = reverse
	}
	yield := iterator_yield(k, iterator, element, .Mutable)
	item := yield_item_type(k, element, yield, expr_span(s.iterable))
	if item == INVALID_TYPE { return FLOWS }
	next := iteration_member(k, iterator, "next")
	if !iteration_proc_matches(k, symbol_of(k.c, next), iterator, .Inout, option_type(k, item)) {
		errorf(k.c, expr_span(s.iterable), "L0456", "`%s` needs `next :: proc(self: inout %s) -> Option(%s)`", type_name(k.c, iterator), type_name(k.c, iterator), type_name(k.c, item))
		note_excluded_member(k, iterator, "next")
		return FLOWS
	}
	if !gate_type(k, element, s.span) { return FLOWS }
	logical, handed := element, yield
	if s.indexed {
		fields := make([]Yield_Desc, 2, k.c.semantic_allocator)
		fields[0], fields[1] = yield, Yield_Desc{kind = .Owned}
		handed = Yield_Desc{kind = .Record, fields = fields}
		logical = indexed_element_type(k.c, element)
	}
	// A record of lent parts binds through its projection, as a lending loop's does.
	if yield.kind == .Record {
		s.item_type = yield_item_type(k, logical, handed, expr_span(s.iterable))
		if s.item_type == INVALID_TYPE { return FLOWS }
	}
	s.kind, s.element_type, s.iterator_type = .Protocol, logical, iterator
	s.iter_symbol, s.next_symbol = iter, next
	if !check_foreach_pattern(k, s, s.bindings, s.element_type, s.item_type, handed) { return FLOWS }
	return check_foreach_block(k, s)
}

// The receiver of a well-formed `iter_mut` or `iter_mut_reverse`.
mutable_iteration_receiver :: proc(k: ^Checker, member: Symbol_Id, subject, iterator: Type_Id) -> (Param_Mode, bool) {
	sym := symbol_of(k.c, member)
	for mode in ([]Param_Mode{.Inout, .Borrow}) {
		if iteration_proc_matches(k, sym, subject, mode, iterator) {
			info := type_of(k.c, sym.proc_type)
			return info.param_modes[0], true
		}
	}
	return .Inout, false
}

// A read view over a container, stored or written in the header, says how to
// ask for a mutable one (design.md "Iteration adapters").
@(private = "file")
report_not_mutably_iterable :: proc(k: ^Checker, s: ^Stmt_Foreach, subject: Type_Id) {
	info := underlying_info(k.c, subject)
	if info != nil && info.adapter_kind == .Reversed {
		source := info.key
		iterator := associated_type_of(k, source, "Mut_Iterator")
		if receiver, found := mutable_iteration_receiver(k, iteration_member(k, source, "iter_mut"), source, iterator); found && receiver != .Inout {
			errorf(k.c, expr_span(s.iterable), "L0460", "`%s` cannot be reversed mutably: it needs `iter_mut_reverse`", type_name(k.c, source))
			return
		}
	}
	if info != nil && (info.adapter_kind == .Indexed || info.adapter_kind == .Reversed) {
		name := info.adapter_kind == .Indexed ? "indexed" : "reversed"
		errorf(
			k.c, ref_span(s), "L0457",
			"`%s()` over `%s` is a read-only view, so it cannot be iterated by reference",
			name, type_name(k.c, info.key),
		)
		add_notef(
			k.c, expr_span(s.iterable),
			"apply `%s()` to a mutable view instead, such as `values[:].%s()` for an array or `items.slice().%s()` for a `Small_Array`",
			name, name, name,
		)
		return
	}
	if info != nil && info.view_kind != .None && info.view_kind != .Rune_Offsets {
		errorf(k.c, ref_span(s), "L0457", "a map view is read-only, so it cannot be iterated by reference")
		add_notef(k.c, expr_span(s.iterable), "mutate a map's values with `foreach (key, &value in table)`")
		return
	}
	errorf(
		k.c, ref_span(s), "L0457",
		"`%s` cannot be iterated by reference: it needs `Element`, `Mut_Iterator`, and an `iter_mut` returning it",
		type_name(k.c, subject),
	)
}

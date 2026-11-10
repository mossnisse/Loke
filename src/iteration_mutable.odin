// By-reference iteration (design.md "By-reference iteration"): the `iter_mut`
// members and `Mut_Iterator` types the compiler contributes to arrays, slices and
// maps, and the checking of a `foreach` that binds its elements mutably.
package lokec

import "core:fmt"

ensure_mutable_iteration_members :: proc(k: ^Checker, subject: Type_Id) {
	c := k.c
	info := type_of(c, subject)
	if info == nil || .Mutable_Iteration in info.contributed { return }
	info.contributed += {.Mutable_Iteration}
	if type_is_compile_time_only(c, subject) { return }
	#partial switch info.kind {
	case .Map:
		add_mutable_map_members(k, subject)
	case .Array, .Dynamic_Array:
		add_mutable_sequence_members(k, subject, info)
	case .Slice:
		if info.mutable { add_mutable_sequence_members(k, subject, info) }
	}
}

// design.md "By-reference iteration": an entry lends its key read-only and its
// value mutably.
@(private = "file")
add_mutable_map_members :: proc(k: ^Checker, subject: Type_Id) {
	c := k.c
	entry := map_entry_type(c, subject)
	iterator := new_map_cursor_type(c, subject, entry, "Mutable_Map_Iterator")
	type_of(c, iterator).mutable = true
	lent := yield_pair(c, Yield_Desc{kind = .Borrowed}, Yield_Desc{kind = .Mutable})
	item := yield_item_type(k, entry, lent, NO_SPAN, report = false)
	next := synth_self_member(c, "next", .Map_Next, iterator, .Inout, option_type(k, item))
	add_members(c, iterator, []Symbol_Id{next})
	iter := synth_self_member(c, "iter_mut", .Map_Iter, subject, .Inout, iterator)
	add_members(c, subject, []Symbol_Id{new_associated_type(c, "Mut_Iterator", iterator, subject), iter})
}

@(private = "file")
add_mutable_sequence_members :: proc(k: ^Checker, subject: Type_Id, info: ^Type_Info) {
	c := k.c
	element := info.element
	fields := make([]Symbol_Id, 3, c.semantic_allocator)
	fields[ITER_ARRAY_DATA] = new_field(c, "items", slice_of(c, element, true), ITER_ARRAY_DATA)
	fields[ITER_ARRAY_INDEX] = new_field(c, "index", TYPE_INT, ITER_ARRAY_INDEX)
	fields[ITER_ARRAY_REVERSED] = new_field(c, "reversed", TYPE_BOOL, ITER_ARRAY_REVERSED)
	iterator := new_type(c, Type_Info{
		kind = .Struct, element = element, fields = fields,
		name = intern_identifier(c, fmt.tprintf("Mutable_Iterator(%s)", type_name(c, subject))),
		backend_label = fmt.aprintf("Mutable_Iterator.%d", subject, allocator = c.semantic_allocator),
	})
	next := synth_self_member(c, "next", .Slice_Mut_Next, iterator, .Inout, option_type(k, pointer_to(c, element, true)))
	add_members(c, iterator, []Symbol_Id{next})
	// A view walks as any value; a container needs a mutable place.
	receiver := info.kind == .Slice ? Param_Mode.Value : Param_Mode.Inout
	constructor := info.kind == .Dynamic_Array ? Synth_Kind.Dynamic_Iter : Synth_Kind.Array_Iter
	iter := synth_self_member(c, "iter_mut", constructor, subject, receiver, iterator)
	reverse_kind := info.kind == .Dynamic_Array ? Synth_Kind.Dynamic_Iter_Reverse : Synth_Kind.Array_Iter_Reverse
	reverse := synth_self_member(c, "iter_mut_reverse", reverse_kind, subject, receiver, iterator)
	add_members(c, subject, []Symbol_Id{new_associated_type(c, "Mut_Iterator", iterator, subject), iter, reverse})
}

// design.md "By-reference iteration": an `inout` `iter_mut` belongs to a container,
// which must be a mutable place; any other receiver to a mutable view.
check_mutable_protocol_foreach :: proc(k: ^Checker, s: ^Stmt_Foreach, subject: Type_Id) -> Flow_Info {
	protocol, found := mutable_protocol(k, subject)
	if !found {
		report_not_mutably_iterable(k, s, subject)
		return FLOWS
	}
	if protocol.receiver == .Inout && !expr_base(s.iterable).assignable {
		report_not_assignable(k, expr_base(s.iterable), "a by-reference `foreach`")
		return FLOWS
	}
	element, iterator, iter := protocol.element, protocol.iterator, protocol.iter
	if s.reversed {
		iter = iteration_member(k, subject, "iter_mut_reverse")
		if _, reversible := mutable_iteration_receiver(k, iter, subject, iterator); !reversible {
			errorf(k.c, expr_span(s.iterable), "L0460", "`%s` cannot be reversed mutably: it needs `iter_mut_reverse`", type_name(k.c, subject))
			return FLOWS
		}
	}
	next, yield, item, usable := protocol_next(k, iterator, element, .Mutable, expr_span(s.iterable))
	if !usable { return FLOWS }
	if !gate_type(k, element, expr_span(s.iterable)) { return FLOWS }
	logical, projected, handed := foreach_numbered(k.c, s, element, item, yield)
	// A record of lent parts binds through its projection, as a lending loop's does.
	if yield.kind == .Record {
		s.item_type = projected
	}
	bind_protocol_loop(k, s, logical, iterator, iter, next)
	return check_foreach_pattern_and_block(k, s, s.item_type, handed)
}

// What a type's mutable traversal is made of.
Mutable_Protocol :: struct {
	element, iterator: Type_Id,
	iter:              Symbol_Id,
	receiver:          Param_Mode,
}

// False when the type has no well-formed mutable traversal.
mutable_protocol :: proc(k: ^Checker, type: Type_Id) -> (protocol: Mutable_Protocol, ok: bool) {
	protocol.element = associated_type_of(k, type, "Element")
	protocol.iterator = associated_type_of(k, type, "Mut_Iterator")
	protocol.iter = iteration_member(k, type, "iter_mut")
	if protocol.element == INVALID_TYPE || protocol.iterator == INVALID_TYPE { return }
	protocol.receiver, ok = mutable_iteration_receiver(k, protocol.iter, type, protocol.iterator)
	return
}

// The receiver of a well-formed `iter_mut` or `iter_mut_reverse`.
mutable_iteration_receiver :: proc(k: ^Checker, member: Symbol_Id, subject, iterator: Type_Id) -> (Param_Mode, bool) {
	sym := symbol_of(k.c, member)
	if iteration_proc_matches(k, sym, subject, .Inout, iterator) { return .Inout, true }
	return .Borrow, iteration_proc_matches(k, sym, subject, .Borrow, iterator)
}

// A read view over a container, stored or written in the header, says how to
// ask for a mutable one (design.md "Iteration adapters").
@(private = "file")
report_not_mutably_iterable :: proc(k: ^Checker, s: ^Stmt_Foreach, subject: Type_Id) {
	info := underlying_info(k.c, subject)
	if info.adapter_kind == .Reversed && is_mutable_view(k, info.key) {
		errorf(k.c, expr_span(s.iterable), "L0460", "`%s` cannot be reversed mutably: it needs `iter_mut_reverse`", type_name(k.c, info.key))
		return
	}
	if info.adapter_kind == .Indexed && underlying_kind(k.c, info.key) == .Map {
		errorf(k.c, ref_span(s), "L0457", "`indexed()` over a map entry is not a mutable traversal; count with a variable")
		return
	}
	if info.adapter_kind == .Indexed || info.adapter_kind == .Reversed {
		name := info.adapter_kind == .Indexed ? "indexed" : "reversed"
		errorf(
			k.c, ref_span(s), "L0457",
			"`%s()` over `%s` is a read-only view, so it cannot be iterated by reference",
			name, type_name(k.c, info.key),
		)
		add_notef(
			k.c, expr_span(s.iterable),
			"apply `%s()` to a mutable view instead, such as `(&mut values[:]).%s()` for an array or `items.slice().%s()` for a `Small_Array`",
			name, name, name,
		)
		return
	}
	if info.view_kind != .None && info.view_kind != .Rune_Offsets {
		errorf(k.c, ref_span(s), "L0457", "a map view is read-only, so it cannot be iterated by reference")
		add_notef(k.c, expr_span(s.iterable), "mutate a map's values with `foreach (key, &mut value in table)`")
		return
	}
	errorf(
		k.c, ref_span(s), "L0457",
		"`%s` cannot be iterated by reference: it needs `Element`, `Mut_Iterator`, and an `iter_mut` returning it",
		type_name(k.c, subject),
	)
}

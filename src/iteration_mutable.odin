package lokec

import "core:fmt"

ensure_mutable_iteration_members :: proc(k: ^Checker, subject: Type_Id) {
	c := k.c
	info := type_of(c, subject)
	if info == nil || .Mutable_Iteration in info.contributed { return }
	info.contributed += {.Mutable_Iteration}
	if type_is_compile_time_only(c, subject) { return }
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
	iter := adapter_proc(k, "iter_mut", constructor, subject, .Inout, iterator)
	add_members(c, subject, []Symbol_Id{new_associated_type(c, "Mut_Iterator", iterator, subject), iter})
}

// A mutable iterator lends one element until its next call. `foreach` confines
// that loan to the body of the current iteration and borrows the source for
// the whole traversal.
check_mutable_protocol_foreach :: proc(k: ^Checker, s: ^Stmt_Foreach, subject: Type_Id) -> Flow_Info {
	if s.adapter != .None {
		errorf(k.c, s.span, "L0460", "`reversed()` yields values, so it cannot be iterated by reference; drop the `&`")
		return FLOWS
	}
	if len(s.bindings) > 2 || !s.bindings[0].is_ref || (len(s.bindings) == 2 && s.bindings[1].is_ref) {
		errorf(k.c, s.span, "L0459", "a by-reference `foreach` binds `&value`, or `&value, index` over `indexed()`")
		return FLOWS
	}
	// `indexed()` numbers the `iter_mut` walk this already performs: the counter
	// is the traversal's, so the header spells it the same way a value loop does.
	if !check_place_index_binding(k, s) {
		return FLOWS
	}
	element := associated_type_of(k, subject, "Element")
	iterator := associated_type_of(k, subject, "Mut_Iterator")
	iter := iteration_member(k, subject, "iter_mut")
	if element == INVALID_TYPE || iterator == INVALID_TYPE ||
	   !iteration_proc_matches(k, symbol_of(k.c, iter), subject, .Inout, iterator) {
		errorf(k.c, s.bindings[0].name.span, "L0457", "`%s` cannot be iterated by reference: it needs `Element`, `Mut_Iterator`, and `iter_mut :: proc(self: inout %s) -> Mut_Iterator`", type_name(k.c, subject), type_name(k.c, subject))
		return FLOWS
	}
	if !expr_base(s.iterable).assignable {
		report_not_assignable(k, expr_base(s.iterable), "a by-reference `foreach`")
		return FLOWS
	}
	next := iteration_member(k, iterator, "next")
	if !iteration_proc_matches(k, symbol_of(k.c, next), iterator, .Inout, option_type(k, pointer_to(k.c, element, true))) {
		errorf(k.c, expr_span(s.iterable), "L0456", "`%s` needs `next :: proc(self: inout %s) -> Option(^mut %s)`", type_name(k.c, iterator), type_name(k.c, iterator), type_name(k.c, element))
		return FLOWS
	}
	if !gate_type(k, element, s.span) { return FLOWS }
	s.kind, s.element_type, s.iterator_type = .Protocol, element, iterator
	s.iter_symbol, s.next_symbol = iter, next
	s.bindings[0].symbol = bind_loop_name(k, s.bindings[0], element, true)
	if len(s.bindings) == 2 { s.bindings[1].symbol = bind_loop_name(k, s.bindings[1], TYPE_INT, false) }
	return check_foreach_block(k, s)
}

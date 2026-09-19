package lokec

import "core:fmt"

ensure_mutable_iteration_members :: proc(k: ^Checker, subject: Type_Id) {
	c := k.c
	info := type_of(c, subject)
	if info == nil || .Mutable_Iteration in info.contributed { return }
	info.contributed += {.Mutable_Iteration}
	if type_is_compile_time_only(c, subject) { return }
	if info.view_kind == .Values {
		element := info.element
		iterator := new_type(c, Type_Info{
			kind = .Struct,
			name = intern_identifier(c, fmt.aprintf("Mutable_Map_Values_Iterator(%s)", type_name(c, info.key), allocator = c.semantic_allocator)),
			element = element,
			key = info.key,
			is_view = true,
		})
		fields := make([]Symbol_Id, 2, c.semantic_allocator)
		fields[ITER_MAP_TABLE] = new_field(c, "table", TYPE_RAWPTR, ITER_MAP_TABLE)
		fields[ITER_MAP_CURSOR] = new_field(c, "cursor", TYPE_INT, ITER_MAP_CURSOR)
		iterator_info := type_of(c, iterator)
		iterator_info.fields = fields
		iterator_info.mangled = fmt.aprintf("Mutable_Map_Values_Iterator.%d", subject, allocator = c.semantic_allocator)
		next := adapter_proc(k, "next", .Map_Values_Next, iterator, .Inout, option_type(k, pointer_to(c, element, true)))
		iter := adapter_proc(k, "iter_mut", .Map_View_Iter, subject, .Inout, iterator)
		add_members(c, iterator, []Symbol_Id{next})
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
	iter := adapter_proc(k, "iter_mut", constructor, subject, .Inout, iterator)
	reverse_kind := info.kind == .Dynamic_Array ? Synth_Kind.Dynamic_Iter_Reverse : Synth_Kind.Array_Iter_Reverse
	reverse := adapter_proc(k, "iter_mut_reverse", reverse_kind, subject, .Inout, iterator)
	add_members(c, subject, []Symbol_Id{new_associated_type(c, "Mut_Iterator", iterator, subject), iter, reverse})
}

check_mutable_protocol_foreach :: proc(k: ^Checker, s: ^Stmt_Foreach, subject: Type_Id) -> Flow_Info {
	element := associated_type_of(k, subject, "Element")
	iterator := associated_type_of(k, subject, "Mut_Iterator")
	iter := iteration_member(k, subject, "iter_mut")
	if element == INVALID_TYPE || iterator == INVALID_TYPE ||
	   !iteration_proc_matches(k, symbol_of(k.c, iter), subject, .Inout, iterator) {
		errorf(k.c, ref_span(s), "L0457", "`%s` cannot be iterated by reference: it needs `Element`, `Mut_Iterator`, and `iter_mut :: proc(self: inout %s) -> Mut_Iterator`", type_name(k.c, subject), type_name(k.c, subject))
		return FLOWS
	}
	root := mutable_foreach_root(k.c, s)
	if info := underlying_info(k.c, subject); info != nil && info.view_kind == .Values {
		if _, direct := direct_mutable_map_values_root(k.c, s); !direct {
			errorf(
				k.c, expr_span(s.iterable), "L0457",
				"a stored map values view cannot be iterated by reference; iterate `map.values()` directly",
			)
			return FLOWS
		}
	}
	if !expr_base(root).assignable {
		report_not_assignable(k, expr_base(root), "a by-reference `foreach`")
		return FLOWS
	}
	if s.adapter == .Reversed {
		reverse := iteration_member(k, subject, "iter_mut_reverse")
		if !iteration_proc_matches(k, symbol_of(k.c, reverse), subject, .Inout, iterator) {
			errorf(k.c, expr_span(s.iterable), "L0460", "`%s` cannot be reversed mutably: it needs `iter_mut_reverse`", type_name(k.c, subject))
			return FLOWS
		}
		iter = reverse
	}
	next := iteration_member(k, iterator, "next")
	if !iteration_proc_matches(k, symbol_of(k.c, next), iterator, .Inout, option_type(k, pointer_to(k.c, element, true))) {
		errorf(k.c, expr_span(s.iterable), "L0456", "`%s` needs `next :: proc(self: inout %s) -> Option(^mut %s)`", type_name(k.c, iterator), type_name(k.c, iterator), type_name(k.c, element))
		return FLOWS
	}
	if !gate_type(k, element, s.span) { return FLOWS }
	s.kind, s.element_type, s.iterator_type = .Protocol, s.indexed ? indexed_element_type(k.c, element) : element, iterator
	s.iter_symbol, s.next_symbol = iter, next
	if !check_foreach_pattern(k, s, s.bindings, s.element_type, INVALID_TYPE) { return FLOWS }
	return check_foreach_block(k, s)
}

mutable_foreach_root :: proc(c: ^Compiler, s: ^Stmt_Foreach) -> Expr {
	if root, direct := direct_mutable_map_values_root(c, s); direct { return root }
	return s.iterable
}

direct_mutable_map_values_root :: proc(c: ^Compiler, s: ^Stmt_Foreach) -> (Expr, bool) {
	call, ok := s.iterable.(^Expr_Call)
	if !ok || len(call.bound) == 0 { return nil, false }
	sym := symbol_of(c, call.resolution.chosen_overload)
	if sym == nil || sym.container_op != .Map_Values { return nil, false }
	return call.bound[0], true
}

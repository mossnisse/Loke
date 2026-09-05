// Read-only element borrowing over contiguous storage (design.md "Borrowing
// iteration"). A view stores a read-only slice, never a copy of its elements.
package lokec

import "core:fmt"

sequence_refs_member :: proc(k: ^Checker, source: Type_Id) -> Symbol_Id {
	c := k.c
	info := underlying_info(c, source)
	if info == nil || (info.kind != .Array && info.kind != .Slice && info.kind != .Dynamic_Array) ||
	   type_is_compile_time_only(c, info.element) { return INVALID_SYMBOL }
	// Unlike generic adapters, no package-local protocol lookup participates
	// in this built-in traversal. Its type is identical across packages.
	key := Adapter_Key{source, .Refs, INVALID_PACKAGE}
	if existing, found := c.adapter_members[key]; found { return existing }
	element := pointer_to(c, info.element, false)
	held := slice_of(c, info.element, false)
	by_value := info.kind == .Slice
	view := new_type(c, Type_Info{
		kind = .Struct, name = intern_identifier(c, fmt.aprintf("Refs(%s)", type_name(c, source), allocator = c.semantic_allocator)),
		element = element, key = source, is_view = true, adapter_kind = .Refs, adapter_by_value = by_value,
	})
	fields := make([]Symbol_Id, 1, c.semantic_allocator)
	fields[0] = new_field(c, "items", held, 0, public = false)
	type_of(c, view).fields = fields
	type_of(c, view).mangled = fmt.aprintf("Refs.%d", source, allocator = c.semantic_allocator)
	type_of(c, view).contributed += {.Iteration}
	iterator := new_type(c, Type_Info{
		kind = .Struct, name = intern_identifier(c, fmt.aprintf("Ref_Iterator(%s)", type_name(c, source), allocator = c.semantic_allocator)),
		element = element, is_view = true, adapter_kind = .Refs,
	})
	iterator_fields := make([]Symbol_Id, 3, c.semantic_allocator)
	iterator_fields[ITER_ARRAY_DATA] = new_field(c, "items", held, ITER_ARRAY_DATA, public = false)
	iterator_fields[ITER_ARRAY_INDEX] = new_field(c, "index", TYPE_INT, ITER_ARRAY_INDEX, public = false)
	iterator_fields[ITER_ARRAY_REVERSED] = new_field(c, "reversed", TYPE_BOOL, ITER_ARRAY_REVERSED, public = false)
	type_of(c, iterator).fields = iterator_fields
	type_of(c, iterator).mangled = fmt.aprintf("Ref_Iterator.%d", view, allocator = c.semantic_allocator)
	type_of(c, iterator).contributed += {.Iteration}
	add_members(c, iterator, []Symbol_Id{
		new_associated_type(c, "Element", element, iterator),
		new_associated_type(c, "Iterator", iterator, iterator),
		adapter_proc(k, "iter", .Iterator_Copy, iterator, .Borrow, iterator),
		adapter_proc(k, "next", .Slice_Ref_Next, iterator, .Inout, option_type(k, element)),
	})
	add_members(c, view, []Symbol_Id{
		new_associated_type(c, "Element", element, view),
		new_associated_type(c, "Iterator", iterator, view),
		adapter_proc(k, "iter", .Refs_Iter, view, .Borrow, iterator),
		adapter_proc(k, "iter_reverse", .Refs_Iter_Reverse, view, .Borrow, iterator),
	})
	member := adapter_proc(k, "refs", .Refs_View, source, .Borrow, view)
	c.adapter_members[key] = member
	return member
}

// These traversals lend source elements, never their own descriptor storage.
// Keep that fact through the ordinary adapter chain for foreach provenance.
iteration_lends_source :: proc(c: ^Compiler, subject: Type_Id) -> bool {
	info := underlying_info(c, subject)
	if info == nil { return false }
	switch info.adapter_kind {
	case .Refs: return true
	case .Indexed, .Reversed: return iteration_lends_source(c, info.key)
	case .None: return false
	}
	return false
}

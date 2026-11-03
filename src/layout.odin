// Cached target layout shared by the checker and backend.
package lokec

MAX_LAYOUT_SIZE :: u64(max(i64))

type_size :: proc(c: ^Compiler, type: Type_Id, span := Span{file = NO_FILE}) -> u64 {
	compute_layout(c, type, span)
	info := type_of(c, type)
	return info == nil ? 0 : info.size
}

type_align :: proc(c: ^Compiler, type: Type_Id, span := Span{file = NO_FILE}) -> u64 {
	compute_layout(c, type, span)
	info := type_of(c, type)
	return info == nil || info.align == 0 ? 1 : info.align
}

type_field_offset :: proc(c: ^Compiler, type: Type_Id, index: int, span := Span{file = NO_FILE}) -> u64 {
	under := type_underlying(c, type)
	compute_layout(c, under, span)
	info := type_of(c, under)
	if info == nil || index < 0 || index >= len(info.offsets) {
		return 0
	}
	return info.offsets[index]
}

@(private = "file")
layout_product :: proc(left, right: u64) -> (u64, bool) {
	if left != 0 && right > MAX_LAYOUT_SIZE / left {
		return 0, false
	}
	return left * right, true
}

@(private = "file")
layout_sum :: proc(left, right: u64) -> (u64, bool) {
	if left > MAX_LAYOUT_SIZE || right > MAX_LAYOUT_SIZE-left {
		return 0, false
	}
	return left + right, true
}

// Every alignment is a power of two, and every value stays near `MAX_LAYOUT_SIZE`
// at most.
align_to :: proc(value, alignment: u64) -> u64 {
	return (value + alignment - 1) &~ (alignment - 1)
}

@(private = "file")
layout_overflow :: proc(c: ^Compiler, type: Type_Id, span: Span) {
	info := type_of(c, type)
	location := span
	if location.file == NO_FILE {
		if sym := symbol_of(c, info.symbol); sym != nil {
			location = sym.span
		}
	}
	errorf(
		c, location, "L0364", "the layout of `%s` exceeds the maximum supported size of %d bytes",
		type_name(c, type), MAX_LAYOUT_SIZE,
	)
	info.layout_state = .Finite
}

@(private = "file")
compute_layout :: proc(c: ^Compiler, type: Type_Id, span: Span) {
	info := type_of(c, type)
	if info == nil || info.layout_state != .Unchecked {
		return
	}
	// source.odin `committing`: a probe may roll back the diagnostic this answer
	// cost, so it is not kept, here or in a record measured over this one.
	errors := c.error_count
	defer if !committing(c) && c.error_count > errors {
		info.layout_state = .Unchecked
	}
	// Fields are incomplete while their declaration signature is resolving.
	if info.kind == .Struct || info.kind == .Union {
		if record_resolving(c, info) {
			errorf(c, symbol_of(c, info.symbol).span, "L0364", "the layout of `%s` is written in terms of its own layout", type_name(c, type))
			info.layout_state = .Finite
			return
		}
	}
	info.layout_state = .Checking

	word := u64(c.target.pointer_bits) / 8
	size, alignment, natural_align := u64(0), u64(1), u64(1)
	offsets: []u64
	valid := true
	switch info.kind {
	case .Void, .Invalid, .Untyped_Int, .Untyped_Float, .Untyped_Bool, .Untyped_Rune, .Untyped_Nil,
	     .Untyped_String, .Interface, .Type:

	case .Bool, .Int, .Float, .Rune, .Enum, .Typeid, .Allocator_Error:
		size = u64(type_bits(c, type) + 7) / 8
		alignment = min(size, u64(c.target.max_align))

	case .Pointer, .C_Pointer, .Raw_Pointer, .Proc, .Allocator, .CString_View, .Box:
		// A box is the address of its allocation, which records the allocator.
		size, alignment = word, word

	case .String_View:
		size, alignment = 2 * word, word

	case .String:
		size, alignment = 3 * word, word

	case .Distinct:
		size, alignment = type_size(c, info.element, span), type_align(c, info.element, span)

	case .Array:
		element := type_size(c, info.element, span)
		alignment = type_align(c, info.element, span)
		size, valid = layout_product(element, info.count)

	case .Simd:
		size, valid = layout_product(type_size(c, info.element, span), info.count)
		alignment = size

	case .Union:
		shape := union_layout(c, type, span)
		size, alignment = shape.size, shape.align
		valid = size <= MAX_LAYOUT_SIZE

	case .Struct, .Dyn, .Slice, .Dynamic_Array, .Map:
		offsets = make([]u64, len(info.fields), c.semantic_allocator)
		cursor := u64(0)
		for field, index in info.fields {
			symbol := symbol_of(c, field)
			field_size := type_size(c, symbol.type, span)
			field_align := info.packed ? u64(1) : type_align(c, symbol.type, span)
			cursor = align_to(cursor, field_align)
			offsets[index] = cursor
			cursor, valid = layout_sum(cursor, field_size)
			if !valid { break }
			alignment = max(alignment, field_align)
		}
		natural_align = alignment
		alignment = max(alignment, info.written_align)
		size = align_to(cursor, alignment)
		valid = valid && size <= MAX_LAYOUT_SIZE
	}

	if !valid {
		layout_overflow(c, type, span)
		return
	}
	info.size = size
	info.align = max(alignment, 1)
	info.natural_align = natural_align
	info.offsets = offsets
	info.layout_state = .Finite
}

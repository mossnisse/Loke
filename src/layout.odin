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

align_to :: proc(value, alignment: u64) -> u64 {
	if alignment <= 1 {
		return value
	}
	remainder := value % alignment
	if remainder == 0 {
		return value
	}
	padding := alignment - remainder
	return value > max(u64)-padding ? max(u64) : value + padding
}

@(private = "file")
layout_overflow :: proc(c: ^Compiler, type: Type_Id, span: Span) {
	info := type_of(c, type)
	if info == nil {
		return
	}
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
	info = type_of(c, type)
	info.size, info.align, info.offsets, info.layout_state = 0, 1, nil, .Finite
}

@(private = "file")
compute_layout :: proc(c: ^Compiler, type: Type_Id, span: Span) {
	info := type_of(c, type)
	if info == nil || info.layout_state != .Unchecked {
		return
	}
	// Fields are incomplete while their declaration signature is resolving.
	if info.kind == .Struct || info.kind == .Union {
		if sym := symbol_of(c, info.symbol); sym != nil && sym.decl != nil && sym.decl.sig_state == .Checking {
			errorf(c, sym.span, "L0364", "the layout of `%s` is written in terms of its own layout", type_name(c, type))
			info.size, info.align, info.layout_state = 0, 1, .Finite
			return
		}
	}
	info.layout_state = .Checking

	size, alignment := u64(0), u64(1)
	offsets: []u64
	valid := true
	switch info.kind {
	case .Void, .Invalid:
		size, alignment = 0, 1

	case .Untyped_Int, .Untyped_Float, .Untyped_Bool, .Untyped_Rune, .Untyped_Nil,
	     .Untyped_String, .Interface, .Type:

	case .Bool:
		size, alignment = 1, 1

	case .Int, .Float, .Rune, .Enum, .Typeid:
		size = u64(type_bits(c, type) + 7) / 8
		alignment = min(size, u64(c.target.max_align))

	case .Pointer, .C_Pointer, .Raw_Pointer, .Proc, .Allocator, .CString_View:
		size = u64(c.target.pointer_bits) / 8
		alignment = size

	case .String_View:
		alignment = u64(c.target.pointer_bits) / 8
		size = 2 * alignment

	case .String:
		alignment = u64(c.target.pointer_bits) / 8
		size = 3 * alignment

	case .Allocator_Error:
		size = u64(type_bits(c, type) + 7) / 8
		alignment = min(size, u64(c.target.max_align))

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
		offsets = make([]u64, 2, c.semantic_allocator)
		offsets[0] = 0
		offsets[1] = shape.tag_offset

	case .Struct, .Any_View, .Dyn, .Slice, .Dynamic_Array, .Map:
		if info.kind == .Any_View {
			ensure_any_view_fields(c)
		}
		ensure_slice_fields(c, type)
		ensure_container_fields(c, type)
		info = type_of(c, type)
		offsets = make([]u64, len(info.fields), c.semantic_allocator)
		cursor := u64(0)
		for field, index in info.fields {
			symbol := symbol_of(c, field)
			if symbol == nil { continue }
			field_size := type_size(c, symbol.type, span)
			field_align := info.packed ? u64(1) : type_align(c, symbol.type, span)
			cursor = align_to(cursor, field_align)
			if cursor > MAX_LAYOUT_SIZE {
				valid = false
				break
			}
			offsets[index] = cursor
			cursor, valid = layout_sum(cursor, field_size)
			if !valid { break }
			alignment = max(alignment, field_align)
		}
		alignment = max(alignment, info.written_align)
		size = align_to(cursor, alignment)
		valid = valid && size <= MAX_LAYOUT_SIZE
	}

	if !valid {
		layout_overflow(c, type, span)
		return
	}
	info = type_of(c, type)
	info.size = size
	info.align = max(alignment, 1)
	info.offsets = offsets
	info.layout_state = .Finite
}

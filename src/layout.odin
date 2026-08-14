// Natural target layout (m3-plan step 2, decision "Layout ownership").
//
// One model, cached on `Type_Info`, read by the checker's layout built-ins and
// by the backend. Target-specific scalar and pointer widths come from
// `Target_Info`; aggregate layout is computed from those cached facts, so the
// checker and the emitter cannot develop independent ideas about where a field
// lives.
//
// This is the *natural* Loke layout only. `@(packed)` and the foreign ABI
// arrive with M7 (B15).
package lokec

// The size in bytes a value of this type occupies, including the tail padding
// that makes an array of it work.
type_size :: proc(c: ^Compiler, type: Type_Id) -> u64 {
	compute_layout(c, type)
	info := type_of(c, type)
	return info == nil ? 0 : info.size
}

type_align :: proc(c: ^Compiler, type: Type_Id) -> u64 {
	compute_layout(c, type)
	info := type_of(c, type)
	return info == nil || info.align == 0 ? 1 : info.align
}

// The byte offset of one field of a struct, by its position in declaration
// order.
type_field_offset :: proc(c: ^Compiler, type: Type_Id, index: int) -> u64 {
	under := type_underlying(c, type)
	compute_layout(c, under)
	info := type_of(c, under)
	if info == nil || index < 0 || index >= len(info.offsets) {
		return 0
	}
	return info.offsets[index]
}

@(private = "file")
align_up :: proc(value, alignment: u64) -> u64 {
	if alignment <= 1 {
		return value
	}
	return (value + alignment - 1) / alignment * alignment
}

@(private = "file")
compute_layout :: proc(c: ^Compiler, type: Type_Id) {
	info := type_of(c, type)
	if info == nil || info.layout_state != .Unchecked {
		return // computed, or on the stack below this call
	}
	info.layout_state = .Checking

	size, alignment := u64(0), u64(1)
	offsets: []u64
	#partial switch info.kind {
	case .Void, .Invalid:
		size, alignment = 0, 1

	case .Bool:
		size, alignment = 1, 1

	case .Int, .Float, .Rune, .Enum, .Typeid:
		// A scalar is aligned to its own width, up to the target's ceiling: on
		// x86-64 that is what makes `i128` 16-aligned and nothing wider exist.
		size = u64(type_bits(c, type) + 7) / 8
		alignment = min(size, u64(c.target.max_align))

	case .Pointer, .Multi_Pointer, .Raw_Pointer, .Proc, .Allocator:
		// An `Allocator` is a one-word provider handle.
		size = u64(c.target.pointer_bits) / 8
		alignment = size

	case .Allocator_Error:
		size = u64(type_bits(c, type) + 7) / 8
		alignment = min(size, u64(c.target.max_align))

	case .Distinct:
		// A fresh identity with the shape of what it wraps.
		size, alignment = type_size(c, info.element), type_align(c, info.element)

	case .Array:
		element := type_size(c, info.element)
		alignment = type_align(c, info.element)
		size = element * info.count

	case .Union:
		// One model, shared with the emitter: a payload region carrying the widest
		// variant's alignment, then the tag, then tail padding.
		shape := union_layout(c, type)
		size, alignment = shape.size, shape.align
		offsets = make([]u64, 2, c.semantic_allocator)
		offsets[0] = 0
		offsets[1] = shape.tag_offset

	case .Struct, .Any_View, .Dyn, .Slice:
		// A slice's two words are ordinary fields, so it lays out here rather than
		// carrying a second hand-written shape (m5a-plan decision "Slice
		// representation").
		ensure_slice_fields(c, type)
		info = type_of(c, type)
		offsets = make([]u64, len(info.fields), c.semantic_allocator)
		cursor := u64(0)
		for field, index in info.fields {
			symbol := symbol_of(c, field)
			if symbol == nil {
				continue
			}
			field_size := type_size(c, symbol.type)
			field_align := type_align(c, symbol.type)
			cursor = align_up(cursor, field_align)
			offsets[index] = cursor
			cursor += field_size
			alignment = max(alignment, field_align)
		}
		// Tail padding, so `[2]T` puts the second element on T's alignment.
		size = align_up(cursor, alignment)
	}

	// Computing a field's layout may have grown the type store; reacquire.
	info = type_of(c, type)
	info.size = size
	info.align = max(alignment, 1)
	info.offsets = offsets
	info.layout_state = .Finite
}

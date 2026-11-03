// Slices: `[]T` and `[]mut T`.
//
// design.md "Slices": both capabilities share one `{ ptr data, int len }`, so
// mutability never reaches the ABI.
//
// Layout: `src/layout.odin`. Indexing and slicing: `src/check_expr.odin`.
// Members: `src/container.odin`. Borrow root: `prov_slice`.
package lokec

SLICE_DATA :: 0
SLICE_LEN :: 1

slice_of :: proc(c: ^Compiler, element: Type_Id, mutable: bool) -> Type_Id {
	if element == INVALID_TYPE {
		return INVALID_TYPE
	}
	// The read-only variant always exists, because it is the ABI type both
	// capabilities share, and `carrier_abi_type` asks for it by shape.
	readonly := intern_slice(c, element, false)
	return mutable ? intern_slice(c, element, true) : readonly
}

@(private = "file")
intern_slice :: proc(c: ^Compiler, element: Type_Id, mutable: bool) -> Type_Id {
	type := intern_type(c, Type_Key{kind = .Slice, element = element, mutable = mutable})
	if info := type_of(c, type); len(info.fields) == 0 {
		info.fields = make([]Symbol_Id, 2, c.semantic_allocator)
		info.fields[SLICE_DATA] = new_field(c, "data", TYPE_RAWPTR, SLICE_DATA)
		info.fields[SLICE_LEN] = new_field(c, "len", TYPE_INT, SLICE_LEN)
	}
	return type
}

// Structural: a `distinct []T` shares the representation but inherits none of
// the operations (design.md "Distinct types").
type_is_slice :: proc(c: ^Compiler, id: Type_Id) -> bool {
	return underlying_kind(c, id) == .Slice
}

// The element type of a slice, or INVALID_TYPE.
slice_element :: proc(c: ^Compiler, id: Type_Id) -> Type_Id {
	info := underlying_info(c, id)
	return info != nil && info.kind == .Slice ? info.element : INVALID_TYPE
}

// design.md "Dynamic arrays" and "Fixed arrays": a `[dynamic]T` or `[N]T` reads
// as a `[]T` of its elements, as a `string` reads as a `string_view`. A writable
// view stays explicit.
array_views_as :: proc(c: ^Compiler, from, to: Type_Id) -> bool {
	source, view := type_of(c, from), type_of(c, to)
	return source != nil && view != nil && (source.kind == .Dynamic_Array || source.kind == .Array) &&
		view.kind == .Slice && !view.mutable && source.element == view.element
}

// design.md "Implicit type conversions": what reads as a view of itself, with
// the value unchanged. Nominal: a distinct type converts only as written.
type_views_as :: proc(c: ^Compiler, from, to: Type_Id) -> bool {
	return (from == TYPE_STRING && to == TYPE_STRING_VIEW) || array_views_as(c, from, to) || box_views_as(c, from, to)
}

slice_is_mutable :: proc(c: ^Compiler, id: Type_Id) -> bool {
	info := underlying_info(c, id)
	return info != nil && info.kind == .Slice && info.mutable
}

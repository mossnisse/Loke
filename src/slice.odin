// Slices: `[]T` and `[]mut T`.
//
// design.md "Slices": a slice is a non-owning view of a sequence, and both
// capabilities share one representation —
//
//   []T / []mut T   { ptr data, int len }
//
// — so mutability is a static capability that never reaches the ABI.
//
// Here: the one interning point, the ABI type the two capabilities share, and
// the structural queries. Layout is `src/layout.odin`'s, indexing and slicing
// `src/check_expr.odin`'s, the members `src/container.odin`'s, and the root a
// slice borrows `src/borrow.odin`'s.
package lokec

SLICE_DATA :: 0
SLICE_LEN :: 1

// The one place a slice type is created. Interning keys on the element *and* the
// capability, so `[]T` and `[]mut T` are distinct types over one representation.
slice_of :: proc(c: ^Compiler, element: Type_Id, mutable: bool) -> Type_Id {
	if element == INVALID_TYPE {
		return INVALID_TYPE
	}
	// The read-only variant always exists, because it is the ABI type both
	// capabilities share, and `slice_abi_type` asks for it by shape.
	readonly := intern_slice(c, element, false)
	return mutable ? intern_slice(c, element, true) : readonly
}

@(private = "file")
intern_slice :: proc(c: ^Compiler, element: Type_Id, mutable: bool) -> Type_Id {
	type := intern_type(
		c,
		Type_Key{kind = .Slice, element = element, mutable = mutable},
		Type_Info{kind = .Slice, element = element, mutable = mutable},
	)
	ensure_slice_fields(c, type)
	return type
}

slice_abi_type :: proc(c: ^Compiler, id: Type_Id) -> Type_Id {
	under := type_underlying(c, id)
	info := type_of(c, under)
	if info == nil || info.kind != .Slice || !info.mutable {
		return under
	}
	readonly, found := lookup_type(c, Type_Key{kind = .Slice, element = info.element, mutable = false})
	assert(found, "a `[]mut T` was interned without the read-only variant it shares an ABI with")
	return readonly
}

// Installed on first use rather than at intern time, same as `any_view`'s: a
// field is a symbol, and interning runs where making one isn't yet safe.
// Idempotent, so every entry point may ask.
ensure_slice_fields :: proc(c: ^Compiler, type: Type_Id) {
	if info := type_of(c, type); info == nil || info.kind != .Slice || len(info.fields) > 0 {
		return
	}
	fields := make([]Symbol_Id, 2, c.semantic_allocator)
	fields[SLICE_DATA] = new_field(c, "data", TYPE_RAWPTR, SLICE_DATA)
	fields[SLICE_LEN] = new_field(c, "len", TYPE_INT, SLICE_LEN)
	// A `^Type_Info` points into the growing type store, so it is never held
	// across the field symbols being made.
	type_of(c, type).fields = fields
}

// Structural, unlike the dispatch that decides whether a *written* type carries
// the built-in slice operations: a `distinct []T` shares the representation
// these answer for, but inherits none of the operations (design.md "Distinct
// types").
type_is_slice :: proc(c: ^Compiler, id: Type_Id) -> bool {
	return underlying_kind(c, id) == .Slice
}

// The element type of a slice, or INVALID_TYPE.
slice_element :: proc(c: ^Compiler, id: Type_Id) -> Type_Id {
	info := underlying_info(c, id)
	return info != nil && info.kind == .Slice ? info.element : INVALID_TYPE
}

slice_is_mutable :: proc(c: ^Compiler, id: Type_Id) -> bool {
	info := underlying_info(c, id)
	return info != nil && info.kind == .Slice && info.mutable
}

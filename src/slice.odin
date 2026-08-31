// Slices: `[]T` and `[]mut T`.
//
// design.md "Slices": a slice is a non-owning view of a sequence whose runtime
// value is a pointer and a length. Both capabilities share one representation —
//
//   []T / []mut T   { ptr data, int len }
//
// — so mutability is a static capability only, never reaching the ABI. Like
// `any_view` and `dyn`, a slice is a compiler-owned struct-shaped type, letting
// it reuse the existing layout, parameter-passing, and emission paths instead
// of growing a second aggregate mechanism.
//
// A slice is a *borrow*: no allocator, no cleanup, owns nothing. Its value,
// layout, bounds, and capability behavior are here; the root it borrows, its
// last use, and what may touch that root meanwhile are `src/borrow.odin`'s.
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
	// capabilities share (`slice_abi_type`). Interning it here keeps the backend
	// from having to create a type while it walks the type store.
	readonly := intern_type(
		c,
		Type_Key{kind = .Slice, element = element, mutable = false},
		Type_Info{kind = .Slice, element = element, mutable = false},
	)
	ensure_slice_fields(c, readonly)
	if !mutable {
		return readonly
	}
	type := intern_type(
		c,
		Type_Key{kind = .Slice, element = element, mutable = true},
		Type_Info{kind = .Slice, element = element, mutable = true},
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
	return found ? readonly : under
}

// Installed on first use rather than at intern time, same as `any_view`'s: a
// field is a symbol, and interning runs where making one isn't yet safe.
// Idempotent, so every entry point may ask.
ensure_slice_fields :: proc(c: ^Compiler, type: Type_Id) {
	info := type_of(c, type)
	if info == nil || info.kind != .Slice || len(info.fields) > 0 {
		return
	}
	fields := make([]Symbol_Id, 2, c.semantic_allocator)
	fields[SLICE_DATA] = new_field(c, "data", TYPE_RAWPTR, SLICE_DATA)
	fields[SLICE_LEN] = new_field(c, "len", TYPE_INT, SLICE_LEN)
	// The store may have grown while the field symbols were made.
	info = type_of(c, type)
	info.fields = fields
}

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

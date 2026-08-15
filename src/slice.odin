// Slices: `[]T` and `[]mut T` (m5a-plan step 2).
//
// design.md "Slices": a slice is a non-owning view of a sequence whose runtime
// value is a pointer and a length. Both capabilities share one representation —
//
//   []T / []mut T   { ptr data, int len }
//
// — so mutability is a static capability only and never reaches the ABI. Like
// `any_view` and `dyn`, a slice is a compiler-owned struct-shaped type, which is
// what lets it reuse the existing layout, parameter-passing, and emission paths
// instead of growing a second aggregate mechanism.
//
// A slice is a *borrow*: it has no allocator, no cleanup, and cannot be a
// `manual` owner. Its value, layout, bounds and capability behavior are here;
// the root it borrows, its last use, and what may touch that root meanwhile are
// `src/borrow.odin`'s (m5b-plan step 1).
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
		Type_Key{kind = .Slice, element = element, count = 0},
		Type_Info{kind = .Slice, element = element, mutable = false},
	)
	ensure_slice_fields(c, readonly)
	if !mutable {
		return readonly
	}
	type := intern_type(
		c,
		Type_Key{kind = .Slice, element = element, count = 1},
		Type_Info{kind = .Slice, element = element, mutable = true},
	)
	ensure_slice_fields(c, type)
	return type
}

// design.md: "Both types have the same runtime representation. Mutability is a
// static capability and does not change the ABI." The backend therefore gives
// both capabilities one LLVM type, which is what makes weakening a no-op at the
// value level instead of a copy through a second shape.
slice_abi_type :: proc(c: ^Compiler, id: Type_Id) -> Type_Id {
	under := type_underlying(c, id)
	info := type_of(c, under)
	if info == nil || info.kind != .Slice || !info.mutable {
		return under
	}
	readonly, found := lookup_type(c, Type_Key{kind = .Slice, element = info.element, count = 0})
	return found ? readonly : under
}

// Installed on first use rather than at intern time for the same reason
// `any_view`'s are: a field is a symbol, and interning runs in places where
// making one is not yet safe. Idempotent, so every entry point may ask.
ensure_slice_fields :: proc(c: ^Compiler, type: Type_Id) {
	info := type_of(c, type)
	if info == nil || info.kind != .Slice || len(info.fields) > 0 {
		return
	}
	fields := make([]Symbol_Id, 2, c.semantic_allocator)
	fields[SLICE_DATA] = new_slice_field(c, "data", TYPE_RAWPTR, SLICE_DATA)
	fields[SLICE_LEN] = new_slice_field(c, "len", TYPE_INT, SLICE_LEN)
	// The store may have grown while the field symbols were made.
	info = type_of(c, type)
	info.fields = fields
}

@(private = "file")
new_slice_field :: proc(c: ^Compiler, name: string, type: Type_Id, index: int) -> Symbol_Id {
	return new_symbol(c, Symbol {
		name  = intern_identifier(c, name),
		span  = no_span(),
		kind  = .Field,
		type  = type,
		index = u32(index),
	})
}

type_is_slice :: proc(c: ^Compiler, id: Type_Id) -> bool {
	info := type_of(c, type_underlying(c, id))
	return info != nil && info.kind == .Slice
}

// The element type of a slice, or INVALID_TYPE.
slice_element :: proc(c: ^Compiler, id: Type_Id) -> Type_Id {
	info := type_of(c, type_underlying(c, id))
	return info != nil && info.kind == .Slice ? info.element : INVALID_TYPE
}

slice_is_mutable :: proc(c: ^Compiler, id: Type_Id) -> bool {
	info := type_of(c, type_underlying(c, id))
	return info != nil && info.kind == .Slice && info.mutable
}

// design.md: "A mutable slice implicitly weakens to a read-only slice. A
// read-only slice never converts to a mutable slice, including when its original
// owner happens to be mutable."
slice_weakens_to :: proc(c: ^Compiler, from: Type_Id, to: Type_Id) -> bool {
	from_info := type_of(c, type_underlying(c, from))
	to_info := type_of(c, type_underlying(c, to))
	if from_info == nil || to_info == nil {
		return false
	}
	if from_info.kind != .Slice || to_info.kind != .Slice {
		return false
	}
	return from_info.mutable && !to_info.mutable && from_info.element == to_info.element
}

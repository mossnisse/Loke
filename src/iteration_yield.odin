// How an iterator hands its elements back (design.md "Iteration protocol").
//
// An iterator may declare an associated `Yield` describing what `next` returns
// relative to the logical `Element`: the element itself, a pointer lending it,
// or — for a record element — a record of descriptors, one per field. The
// descriptor is what tells a loop whether a binding owns its element or merely
// borrows it, so it is checked against the element's shape here and against
// `next`'s signature at the loop.
//
// An iterator declaring no `Yield` is owned with `Item = Element`, which is
// every iterator written before `Yield` existed.
package lokec

Yield_Kind :: enum {
	Owned,
	Borrowed,
	Mutable,
	Record,
}

// One node of a descriptor. `fields` is populated for `.Record` only, and holds
// one node per field of the record element.
Yield_Desc :: struct {
	kind:   Yield_Kind,
	fields: []Yield_Desc,
}

// The descriptor `iterator` declares, defaulting to owned. `ok` is false when
// the declaration is not a descriptor at all, which has been reported.
iterator_yield :: proc(k: ^Checker, iterator: Type_Id, span: Span) -> (Yield_Desc, bool) {
	written := associated_type_of(k, iterator, "Yield")
	if written == INVALID_TYPE {
		return Yield_Desc{kind = .Owned}, true
	}
	return yield_desc_of(k, written, span)
}

@(private = "file")
yield_desc_of :: proc(k: ^Checker, written: Type_Id, span: Span) -> (Yield_Desc, bool) {
	if kind, is_marker := yield_marker_kind_of(k, written); is_marker {
		return Yield_Desc{kind = kind}, true
	}
	info := underlying_info(k.c, written)
	if info == nil || info.kind != .Struct || len(info.fields) == 0 {
		errorf(
			k.c, span, "L0694",
			"`%s` is not a yield descriptor: write `Yield_Owned`, `Yield_Borrowed`, `Yield_Mutable`, or a record of those",
			type_name(k.c, written),
		)
		return {}, false
	}
	fields := make([]Yield_Desc, len(info.fields), k.c.semantic_allocator)
	for field_id, index in info.fields {
		field := symbol_of(k.c, field_id)
		if field == nil {
			return {}, false
		}
		desc, ok := yield_desc_of(k, field.type, span)
		if !ok {
			return {}, false
		}
		fields[index] = desc
	}
	return Yield_Desc{kind = .Record, fields = fields}, true
}

// The three descriptor types are ordinary declarations in `base:runtime`, bound
// into the universe with `Option` and `Result`, so naming one needs no import
// and the compiler can contribute a `Yield` to a built-in iterator.
yield_marker_kind_of :: proc(k: ^Checker, type: Type_Id) -> (Yield_Kind, bool) {
	for marker, index in k.c.yield_markers {
		if marker != INVALID_TYPE && marker == type {
			return Yield_Kind(index), true
		}
	}
	return .Owned, false
}

// The `Item` this descriptor makes of `element`: what `next` must return, and
// what a manual call receives. INVALID_TYPE when the descriptor and the element
// disagree, which has been reported.
yield_item_type :: proc(k: ^Checker, element: Type_Id, desc: Yield_Desc, span: Span) -> Type_Id {
	switch desc.kind {
	case .Owned:
		return element
	case .Borrowed:
		return pointer_to(k.c, element, false)
	case .Mutable:
		return pointer_to(k.c, element, true)
	case .Record:
	}
	info := underlying_info(k.c, element)
	if info == nil || info.kind != .Struct || len(info.fields) != len(desc.fields) {
		errorf(
			k.c, span, "L0694",
			"a record `Yield` of %d fields needs a record element with %d fields, and `%s` is not one",
			len(desc.fields), len(desc.fields), type_name(k.c, element),
		)
		return INVALID_TYPE
	}
	// The restriction a consuming destructure already carries: a type with a
	// custom hook decides for itself how it comes apart (design.md
	// "Iteration protocol").
	if life := lifecycle_of(k.c, element); life != nil &&
	   (life.custom_drop != INVALID_SYMBOL || life.custom_try_clone != INVALID_SYMBOL) {
		errorf(
			k.c, span, "L0694",
			"`%s` has a custom `hook(copy)` or `hook(drop)`, so a record `Yield` cannot describe it field by field",
			type_name(k.c, element),
		)
		return INVALID_TYPE
	}
	fields := make([]Anon_Record_Field, len(desc.fields), k.c.semantic_allocator)
	for field_id, index in info.fields {
		field := symbol_of(k.c, field_id)
		if field == nil {
			return INVALID_TYPE
		}
		projected := yield_item_type(k, field.type, desc.fields[index], span)
		if projected == INVALID_TYPE {
			return INVALID_TYPE
		}
		fields[index] = {name = field.name, type = projected}
	}
	return anon_record_type(k.c, fields)
}

// Whether every leaf hands the element over rather than lending it.
yield_is_owned :: proc(desc: Yield_Desc) -> bool {
	if desc.kind != .Record {
		return desc.kind == .Owned
	}
	for field in desc.fields {
		if !yield_is_owned(field) {
			return false
		}
	}
	return true
}

// design.md "Iteration protocol": `Item` is what `next` hands back, which is the
// element itself unless a `Yield` says otherwise. An iterator that declares its
// own `Item` keeps it; every other one — a user iterator written before `Yield`
// existed, or a compiler-contributed one — gets the payload of its own `next`.
// That is what lets `Self.Iterator.Item` name something on every iterator, and
// so what lets one `Iterable` cover both yield modes.
ensure_item_member :: proc(k: ^Checker, type: Type_Id) {
	under := type_underlying(k.c, type)
	info := type_of(k.c, under)
	if info == nil || .Iteration_Item in info.contributed {
		return
	}
	// Set before the lookup below, which reaches member contribution again.
	info.contributed += {.Iteration_Item}
	if find_member(k, under, intern_identifier(k.c, "Item")) != INVALID_SYMBOL {
		return
	}
	next := symbol_of(k.c, iteration_member(k, under, "next"))
	if next == nil || next.result == INVALID_TYPE {
		return // not an iterator at all
	}
	payload := option_payload(k.c, next.result)
	if payload == INVALID_TYPE {
		return
	}
	add_members(k.c, under, []Symbol_Id{new_associated_type(k.c, "Item", payload, under)})
}

// What `iterator` hands back for `element`, for a caller that is deciding
// whether something applies rather than checking a written program: a leaf
// descriptor answers, and anything else is INVALID_TYPE with nothing reported.
iterator_item_or_invalid :: proc(k: ^Checker, iterator: Type_Id, element: Type_Id) -> Type_Id {
	written := associated_type_of(k, iterator, "Yield")
	if written == INVALID_TYPE {
		return element
	}
	kind, is_marker := yield_marker_kind_of(k, written)
	if !is_marker {
		return INVALID_TYPE
	}
	switch kind {
	case .Owned:    return element
	case .Borrowed: return pointer_to(k.c, element, false)
	case .Mutable:  return pointer_to(k.c, element, true)
	case .Record:
	}
	return INVALID_TYPE
}

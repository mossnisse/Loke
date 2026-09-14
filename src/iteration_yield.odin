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
	if kind, is_marker := yield_marker_kind(k, written); is_marker {
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

// The three descriptor types are ordinary declarations in the standard
// catalogue, found by name the way `runtime.Memory_Order` is. A program that
// never imports the catalogue cannot name one, and so never asks.
// Not one of `stdlib.odin`'s contributed packages: the compiler adds nothing to
// the catalogue, it only reads three declarations out of it.
@(private = "file")
STD_INTERFACES :: "base:interfaces"

@(private = "file")
yield_marker_kind :: proc(k: ^Checker, type: Type_Id) -> (Yield_Kind, bool) {
	markers := [?]struct{name: string, kind: Yield_Kind} {
		{"Yield_Owned", .Owned},
		{"Yield_Borrowed", .Borrowed},
		{"Yield_Mutable", .Mutable},
	}
	for index in 1 ..< len(k.c.packages) {
		pkg := &k.c.packages[index]
		if pkg.key != STD_INTERFACES || pkg.scope == nil {
			continue
		}
		for marker in markers {
			id := pkg.scope.names[intern_identifier(k.c, marker.name)] or_else INVALID_SYMBOL
			sym := symbol_of(k.c, id)
			if sym == nil || sym.kind != .Type {
				continue
			}
			resolve_symbol_signature_in_place(k, id)
			if symbol_of(k.c, id).type == type {
				return marker.kind, true
			}
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

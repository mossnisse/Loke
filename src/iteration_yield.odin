// Iterator yield modes, derived from `next`, and their projected item types.
package lokec

// One derived associated type: `Item` from `next`, `Iterator` from `iter`, and
// `Mut_Iterator` from `iter_mut` (design.md "Iteration protocol").
Item_Key :: struct { iterator: Type_Id, pkg: Package_Id, member: Derived_Member }
Derived_Member :: enum u8 { Item, Iterator, Mut_Iterator }
Item_State :: enum { None, Checking, Complete }

Yield_Kind :: enum {
	Owned,
	Borrowed,
	Mutable,
	Record,
}

Yield_Desc :: struct {
	kind:   Yield_Kind,
	fields: []Yield_Desc,
}

// design.md "Yield modes": what `next` hands back, read against `Element`. An
// iterator without a `next` the element explains reads as `fallback`, so the
// caller's signature check names the `next` it expected.
iterator_yield :: proc(k: ^Checker, iterator, element: Type_Id, fallback := Yield_Kind.Owned) -> Yield_Desc {
	next := symbol_of(k.c, iteration_member(k, iterator, "next"))
	if next != nil && next.result != INVALID_TYPE {
		if item := option_payload(k.c, next.result); item != INVALID_TYPE {
			if desc, derived := yield_of(k.c, element, item); derived {
				return desc
			}
		}
	}
	return Yield_Desc{kind = fallback}
}

// The element itself is owned, a pointer to it lent, and a record of the same
// field names lent field by field. A record lending nothing is not the element.
@(private = "file")
yield_of :: proc(c: ^Compiler, element, item: Type_Id) -> (Yield_Desc, bool) {
	switch item {
	case element:
		return Yield_Desc{kind = .Owned}, true
	case pointer_to(c, element, false):
		return Yield_Desc{kind = .Borrowed}, true
	case pointer_to(c, element, true):
		return Yield_Desc{kind = .Mutable}, true
	}
	from, to := underlying_info(c, element), underlying_info(c, item)
	if from == nil || to == nil || from.kind != .Struct || to.kind != .Struct ||
	   len(from.fields) == 0 || len(from.fields) != len(to.fields) {
		return {}, false
	}
	fields := make([]Yield_Desc, len(from.fields), c.semantic_allocator)
	for field_id, index in from.fields {
		have, want := symbol_of(c, field_id), symbol_of(c, to.fields[index])
		if have == nil || want == nil || have.name != want.name {
			return {}, false
		}
		derived: bool
		fields[index], derived = yield_of(c, have.type, want.type)
		if !derived {
			return {}, false
		}
	}
	desc := Yield_Desc{kind = .Record, fields = fields}
	return desc, !yield_is_owned(desc)
}

yield_item_type :: proc(k: ^Checker, element: Type_Id, desc: Yield_Desc, span: Span, report := true) -> Type_Id {
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
		if report {
			errorf(
				k.c, span, "L0694",
				"`next` lends %d fields, and `%s` is not a record of %d fields",
				len(desc.fields), type_name(k.c, element), len(desc.fields),
			)
		}
		return INVALID_TYPE
	}
	// Custom lifecycle hooks make field-wise ownership ambiguous.
	if life := lifecycle_of(k.c, element); life != nil &&
	   (life.custom_drop != INVALID_SYMBOL || life.custom_try_clone != INVALID_SYMBOL) {
		if report {
			errorf(
				k.c, span, "L0694",
				"`%s` has a custom `hook(copy)` or `hook(drop)`, so `next` cannot lend it field by field",
				type_name(k.c, element),
			)
		}
		return INVALID_TYPE
	}
	fields := make([]Anon_Record_Field, len(desc.fields), k.c.semantic_allocator)
	for field_id, index in info.fields {
		field := symbol_of(k.c, field_id)
		if field == nil {
			return INVALID_TYPE
		}
		projected := yield_item_type(k, field.type, desc.fields[index], span, report)
		if projected == INVALID_TYPE {
			return INVALID_TYPE
		}
		fields[index] = {name = field.name, type = projected}
	}
	return anon_record_type(k.c, fields)
}

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

ensure_item_member :: proc(k: ^Checker, type: Type_Id) {
	under := type_underlying(k.c, type)
	info := type_of(k.c, under)
	if info == nil { return }
	key := Item_Key{under, lookup_package(k), .Item}
	switch k.c.item_states[key] {
	case .Checking, .Complete: return
	case .None:
	}
	k.c.item_states[key] = .Checking
	defer k.c.item_states[key] = .Complete

	item_member := iteration_member(k, under, "Item")
	item := INVALID_TYPE
	if item_member != INVALID_SYMBOL {
		item = associated_type_of(k, under, "Item")
		if item == INVALID_TYPE {
			sym := symbol_of(k.c, item_member)
			errorf(k.c, sym.span, "L0694", "the `Item` member of `%s` must name a type", type_name(k.c, under))
			return
		}
	}
	next := symbol_of(k.c, iteration_member(k, under, "next"))
	if next == nil || next.result == INVALID_TYPE { return }
	payload := option_payload(k.c, next.result)
	if payload == INVALID_TYPE { return }
	if item != INVALID_TYPE {
		if item != payload {
			errorf(
				k.c, symbol_of(k.c, item_member).span, "L0694",
				"`%s.Item` is `%s`, but `next` returns `Option(%s)`",
				type_name(k.c, under), type_name(k.c, item), type_name(k.c, payload),
			)
		}
		return
	}
	generated := new_associated_type(k.c, "Item", payload, under)
	symbol_of(k.c, generated).pkg = key.pkg
	install_impl_members(k, .Extend, under, []Symbol_Id{generated}, key.pkg)
}

// `Iterator` and `Mut_Iterator` are what `iter` and `iter_mut` return, so a type
// need not declare them; one that does must agree.
ensure_iterator_members :: proc(k: ^Checker, type: Type_Id, name: Identifier_Id) {
	switch identifier_text(k.c, name) {
	case "Iterator":
		derive_iterator_member(k, type, .Iterator, "Iterator", "iter")
	case "Mut_Iterator":
		derive_iterator_member(k, type, .Mut_Iterator, "Mut_Iterator", "iter_mut")
	}
}

@(private = "file")
derive_iterator_member :: proc(k: ^Checker, type: Type_Id, member: Derived_Member, associated, entry: string) {
	under := type_underlying(k.c, type)
	if type_of(k.c, under) == nil { return }
	key := Item_Key{under, lookup_package(k), member}
	switch k.c.item_states[key] {
	case .Checking, .Complete: return
	case .None:
	}
	k.c.item_states[key] = .Checking
	defer k.c.item_states[key] = .Complete

	start := symbol_of(k.c, iteration_member(k, under, entry))
	if start == nil || start.kind != .Proc || start.result == INVALID_TYPE || !start.has_receiver { return }
	declared := iteration_member(k, under, associated)
	if declared == INVALID_SYMBOL {
		generated := new_associated_type(k.c, associated, start.result, under)
		symbol_of(k.c, generated).pkg = key.pkg
		install_impl_members(k, .Extend, under, []Symbol_Id{generated}, key.pkg)
		return
	}
	written := associated_type_of(k, under, associated)
	if written == INVALID_TYPE {
		errorf(k.c, symbol_of(k.c, declared).span, "L0694", "`%s.%s` must name a type", type_name(k.c, under), associated)
	} else if written != start.result {
		errorf(
			k.c, symbol_of(k.c, declared).span, "L0694",
			"`%s.%s` is `%s`, but `%s` returns `%s`",
			type_name(k.c, under), associated, type_name(k.c, written), entry, type_name(k.c, start.result),
		)
	}
}

// Iterator yield modes, derived from `next`, and their projected item types; and
// the associated types that follow from protocol signatures.
package lokec

// The associated types a protocol signature derives.
Derived_Member :: enum u8 { Item, Iterator, Mut_Iterator }

@(private = "file", rodata)
DERIVED_MEMBER_NAMES := [Derived_Member]string {
	.Item         = "Item",
	.Iterator     = "Iterator",
	.Mut_Iterator = "Mut_Iterator",
}

// One associated type derived in one package.
Derived_Key :: struct { type: Type_Id, pkg: Package_Id, member: Derived_Member }

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
	if next != nil {
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
	fields := make([]Anon_Member, len(desc.fields), k.c.semantic_allocator)
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

// `Item` as a binding receives it: for a record mode, the record `next` hands back,
// which may be a named one (design.md "Yield modes"). The projection still rules
// on whether `element` can be taken apart.
iterator_item_type :: proc(k: ^Checker, iterator, element: Type_Id, desc: Yield_Desc, span: Span, report := true) -> Type_Id {
	item := yield_item_type(k, element, desc, span, report)
	if item == INVALID_TYPE || desc.kind != .Record { return item }
	return option_payload(k.c, symbol_of(k.c, iteration_member(k, iterator, "next")).result)
}

// A record of two parts, each lent or owned by its own mode.
yield_pair :: proc(c: ^Compiler, first, second: Yield_Desc) -> Yield_Desc {
	fields := make([]Yield_Desc, 2, c.semantic_allocator)
	fields[0], fields[1] = first, second
	return Yield_Desc{kind = .Record, fields = fields}
}

// `indexed()` lends what its source lends and owns its counter.
indexed_yield :: proc(c: ^Compiler, yield: Yield_Desc) -> Yield_Desc {
	return yield_pair(c, yield, Yield_Desc{kind = .Owned})
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

// copied() clones lent leaves and passes owned leaves through.
yield_borrowed_parts_copyable :: proc(c: ^Compiler, element: Type_Id, desc: Yield_Desc) -> bool {
	switch desc.kind {
	case .Owned:
		return true
	case .Borrowed, .Mutable:
		return !type_clone_disabled(c, element)
	case .Record:
	}
	for field_id, index in underlying_info(c, element).fields {
		if !yield_borrowed_parts_copyable(c, symbol_of(c, field_id).type, desc.fields[index]) { return false }
	}
	return true
}

// `Item`, `Iterator`, and `Mut_Iterator` follow from the signatures of `next`,
// `iter`, and `iter_mut`, so a type need not declare them; one that does must
// agree (design.md "Iteration protocol").
ensure_derived_members :: proc(k: ^Checker, type: Type_Id) {
	if type_of(k.c, type) == nil { return }
	derive_member(k, type, .Item, "next")
	derive_member(k, type, .Iterator, "iter")
	derive_member(k, type, .Mut_Iterator, "iter_mut")
}

@(private = "file")
derive_member :: proc(k: ^Checker, type: Type_Id, which: Derived_Member, entry: string) {
	associated := DERIVED_MEMBER_NAMES[which]
	key := Derived_Key{type, lookup_package(k), which}
	if key in k.c.derived_members { return }
	k.c.derived_members[key] = {}

	member := iteration_member(k, type, entry)
	resolve_symbol_signature_in_place(k, member, type)
	start := symbol_of(k.c, member)
	// An overload is chosen by its signature.
	if start != nil && start.kind == .Proc_Group {
		for candidate in start.members { resolve_symbol_signature_in_place(k, candidate, type) }
		start = symbol_of(k.c, iteration_member(k, type, entry))
	}
	if start == nil || start.generic { return }
	// A signature still on the stack below this lookup can answer a later one.
	if start.kind == .Proc_Group || (start.kind == .Proc && start.result == INVALID_TYPE) {
		delete_key(&k.c.derived_members, key)
		return
	}
	if start.kind != .Proc || !start.has_receiver || len(start.params) != 1 { return }
	derived := which == .Item ? option_payload(k.c, start.result) : start.result
	if derived == INVALID_TYPE { return }
	declared := iteration_member(k, type, associated)
	if declared == INVALID_SYMBOL {
		generated := new_associated_type(k.c, associated, derived, type)
		symbol_of(k.c, generated).pkg = key.pkg
		install_impl_members(k, .Extend, type, []Symbol_Id{generated}, key.pkg)
		return
	}
	written := associated_type_of(k, type, associated)
	if written == INVALID_TYPE {
		errorf(k.c, symbol_of(k.c, declared).span, "L0694", "`%s.%s` must name a type", type_name(k.c, type), associated)
	} else if written != derived {
		errorf(
			k.c, symbol_of(k.c, declared).span, "L0694",
			"`%s.%s` is `%s`, but `%s` returns `%s`",
			type_name(k.c, type), associated, type_name(k.c, written), entry, type_name(k.c, start.result),
		)
	}
}

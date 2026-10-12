// design.md "Standard customization procedures": the built-in `len`, `cap`, and
// `hash` receiver members. There is no free `len(x)` or `hash(x, seed)`.
package lokec

// Installed lazily, so built-in types meet interface requirements as user types do.
ensure_standard_customization_members :: proc(k: ^Checker, type: Type_Id) {
	under := type_underlying(k.c, type)
	info := type_of(k.c, under)
	if info == nil || .Standard_Customization in info.contributed {
		return
	}
	info.contributed += {.Standard_Customization}

	members := make([dynamic]Symbol_Id, 0, 3, k.c.semantic_allocator)
	if standard_len_type(k.c, under) {
		append(&members, standard_receiver_member(k.c, "len", .Standard_Len, under, []Type_Id{under}, TYPE_INT))
	}
	if type_is_container(k.c, under) {
		append(&members, standard_receiver_member(k.c, "cap", .Standard_Cap, under, []Type_Id{under}, TYPE_INT))
	}
	if settle_part_hashes(k, under); standard_hash_type(k.c, under) {
		append(&members, standard_receiver_member(
			k.c, "hash", .Standard_Hash, under,
			[]Type_Id{under, TYPE_UINT}, TYPE_UINT,
		))
	}
	add_members(k.c, under, members[:])
}

@(private = "file")
standard_len_type :: proc(c: ^Compiler, type: Type_Id) -> bool {
	#partial switch underlying_kind(c, type) {
	// A vector's `len` is its lane count.
	case .Array, .Slice, .Dynamic_Array, .Map, .String, .String_View, .Simd:
		return true
	}
	return false
}

@(private = "file")
standard_hash_type :: proc(c: ^Compiler, type: Type_Id) -> bool {
	// An untyped type has no receiver for a member to live on, and a record's
	// is contributed by name, below.
	if type_is_untyped(c, type) {
		return false
	}
	#partial switch underlying_kind(c, type) {
	case .Struct, .Union:
		return false
	}
	return type_is_hashable(c, type)
}

// design.md "Maps": a record or union that keeps its generated `==` hashes
// structurally, and a `distinct` type that declares neither half keys a map by
// its underlying type's policy, so each has that `hash` as a member. As with a
// generated `format`, the member appears only when `hash` is looked up and the
// type has no member of that name, so it never stands beside one an `impl`
// declares.
ensure_record_hash_member :: proc(k: ^Checker, type: Type_Id, name: Identifier_Id) {
	if identifier_text(k.c, name) != "hash" {
		return
	}
	info := type_of(k.c, type)
	if info == nil || (info.kind != .Struct && info.kind != .Union && info.kind != .Distinct) {
		return
	}
	for member in info.members {
		if sym := symbol_of(k.c, member); sym != nil && sym.name == name {
			return
		}
	}
	if type_own_equality(k.c, type) != INVALID_SYMBOL {
		return
	}
	settle_part_hashes(k, type)
	if !type_is_hashable(k.c, type) {
		return
	}
	add_members(k.c, type, []Symbol_Id{
		standard_receiver_member(k.c, "hash", .Standard_Hash, type, []Type_Id{type, TYPE_UINT}, TYPE_UINT),
	})
}

// design.md "Maps": a part with its own `==` is hashed by its own `hash`,
// called with the protocol's shape, so that signature is resolved before
// `type_is_hashable` reads it.
settle_part_hashes :: proc(k: ^Checker, type: Type_Id) {
	parts: [dynamic]Type_Id
	defer delete(parts)
	own_equalities_within(k.c, type, &parts)
	for part in parts {
		if own, _ := part_hash_member(k.c, part); own != INVALID_SYMBOL {
			resolve_symbol_signature_in_place(k, own)
		}
	}
}

@(private = "file")
standard_receiver_member :: proc(
	c: ^Compiler,
	name: string,
	kind: Synth_Kind,
	owner: Type_Id,
	params: []Type_Id,
	result: Type_Id,
) -> Symbol_Id {
	modes := make([]Param_Mode, len(params), c.semantic_allocator)
	// design.md "Receiver forms": a read-only receiver is taken by address, as
	// `self: ^` is.
	if len(modes) > 0 { modes[0] = .Borrow }
	id := synth_proc(c, name, kind, owner, params, modes, result)
	if sym := symbol_of(c, id); sym != nil {
		sym.has_receiver = true
		sym.receiver = .Borrow
	}
	return id
}

// design.md "Standard customization procedures": the built-in `len`, `cap`, and
// `hash` receiver members. There is no free `len(x)` or `hash(x, seed)`.
package lokec

ensure_standard_customization_members :: proc(k: ^Checker, type: Type_Id) {
	under := type_underlying(k.c, type)
	info := type_of(k.c, under)
	if info == nil || .Standard_Customization in info.contributed {
		return
	}
	info.contributed += {.Standard_Customization}

	#partial switch info.kind {
	// A vector's `len` is its lane count.
	case .Array, .Slice, .Dynamic_Array, .Map, .String, .String_View, .Simd:
		add_members(k.c, under, []Symbol_Id{standard_receiver_member(k.c, "len", .Standard_Len, under, []Type_Id{under}, TYPE_INT)})
	}
	if type_is_container(k.c, under) {
		add_members(k.c, under, []Symbol_Id{standard_receiver_member(k.c, "cap", .Standard_Cap, under, []Type_Id{under}, TYPE_INT)})
	}
}

// A fixed array's or vector's `len()` is constant, though the receiver is still
// evaluated once for its effects.
fold_standard_customization_call :: proc(k: ^Checker, v: ^Expr_Call, chosen: ^Symbol) {
	if chosen == nil || chosen.synth != .Standard_Len || len(chosen.params) == 0 {
		return
	}
	info := underlying_info(k.c, chosen.params[0])
	if info == nil || (info.kind != .Array && info.kind != .Simd) {
		return
	}
	v.const_value = int_const(k.c, i64(info.count))
}

// design.md "Maps": a type that keeps its generated `==` and declares no `hash`
// has that `hash` as a member, as a `distinct` type that declares neither half has
// its underlying type's. As with a generated `format`, it appears only when `hash`
// is looked up and the name is free.
ensure_hash_member :: proc(k: ^Checker, type: Type_Id, name: Identifier_Id) {
	if identifier_text(k.c, name) != "hash" || type_is_untyped(k.c, type) {
		return
	}
	info := type_of(k.c, type)
	if info == nil || member_named(k.c, info.members, name) != INVALID_SYMBOL {
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

// design.md "Receiver forms": a read-only receiver is taken by address, as
// `self: ^` is.
@(private = "file")
standard_receiver_member :: proc(
	c: ^Compiler,
	name: string,
	kind: Synth_Kind,
	owner: Type_Id,
	params: []Type_Id,
	result: Type_Id,
) -> Symbol_Id {
	modes := []Param_Mode{.Borrow, .Value}
	return synth_receiver_proc(c, name, kind, owner, params, modes[:len(params)], result)
}

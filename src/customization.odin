// design.md "Standard customization procedures": the built-in `len`, `cap`, and
// `hash` receiver members. There is no free `len(x)` or `hash(x, seed)`.
package lokec

// design.md "Receiver forms": a read-only receiver is taken by address, as
// `self: ^` is.
ensure_standard_customization_members :: proc(k: ^Checker, type: Type_Id) {
	under := type_underlying(k.c, type)
	info := type_of(k.c, under)
	if info == nil || .Standard_Customization in info.contributed {
		return
	}
	info.contributed += {.Standard_Customization}

	receiver := []Type_Id{under}
	modes := []Param_Mode{.Borrow}
	#partial switch info.kind {
	// A vector's `len` is its lane count.
	case .Array, .Slice, .String, .String_View, .Simd:
		add_members(k.c, under, []Symbol_Id{synth_receiver_proc(k.c, "len", .Standard_Len, under, receiver, modes, TYPE_INT)})
	case .Dynamic_Array, .Map:
		add_members(k.c, under, []Symbol_Id{
			synth_receiver_proc(k.c, "len", .Standard_Len, under, receiver, modes, TYPE_INT),
			synth_receiver_proc(k.c, "cap", .Standard_Cap, under, receiver, modes, TYPE_INT),
		})
	}
}

// A fixed array's or vector's `len()` is constant. It folds only where folding
// skips nothing: a receiver that is a name or a constant, as anything else is
// evaluated once for its effects, by the call.
fold_standard_customization_call :: proc(k: ^Checker, v: ^Expr_Call, chosen: ^Symbol) {
	if chosen == nil || chosen.synth != .Standard_Len || len(chosen.params) == 0 || len(v.bound) == 0 {
		return
	}
	info := underlying_info(k.c, chosen.params[0])
	if info == nil || (info.kind != .Array && info.kind != .Simd) {
		return
	}
	_, is_name := v.bound[0].(^Expr_Ident)
	if receiver := expr_base(v.bound[0]); is_name || receiver != nil && base_is_const(receiver) {
		v.const_value = int_const(k.c, i64(info.count))
	}
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
		synth_receiver_proc(k.c, "hash", .Standard_Hash, type, []Type_Id{type, TYPE_UINT}, []Param_Mode{.Borrow, .Value}, TYPE_UINT),
	})
}

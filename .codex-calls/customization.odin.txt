// The canonical receiver members the language expects a type to supply.
//
// `value.f(args)` is the only spelling: there is no free `len(value)` or
// `hash(value, seed)`, so a reader's implicit receiver borrow is as visible as a
// mutator's. Ordinary free procedures keep ordinary lexical lookup and never
// perform receiver lookup, whatever they are named.
package lokec

// Built-in operations must satisfy the same receiver-form interface
// requirements as user types: install their canonical `len`, `cap`, and `hash`
// members lazily, alongside the existing iteration and lifecycle contributors.
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
	if standard_hash_type(k.c, under) {
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
	// A vector's `len` is its lane count, folded from the type like a fixed
	// array's. It stays out of `Sequence` regardless: that also wants iteration
	// and a runtime index, and a vector has neither (design.md "SIMD vectors").
	case .Array, .Slice, .Dynamic_Array, .Map, .String, .String_View, .Simd:
		return true
	}
	return false
}

@(private = "file")
standard_hash_type :: proc(c: ^Compiler, type: Type_Id) -> bool {
	// Untyped constants materialize before a free `hash` call and have no stable
	// receiver type on which a method could live.
	if type_is_untyped(c, type) {
		return false
	}
	return type_is_hashable(c, type)
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
	// design.md "Receiver forms": the immutable receiver is a borrow of the
	// caller's value, so it carries `.Borrow` here exactly as a written `self`
	// does. The remaining parameters keep the zero value, `.Value`.
	if len(modes) > 0 { modes[0] = .Borrow }
	id := synth_proc(c, name, kind, owner, params, modes, result)
	if sym := symbol_of(c, id); sym != nil {
		sym.has_receiver = true
		sym.receiver = .Borrow
	}
	return id
}

// Local allocator regions: `mem.Arena` and `mem.Scratch` (m6b-plan step 5).
//
// design.md "Allocators": "There is no ambient temporary allocator. Temporary
// storage has a reset boundary and runtime identity, so code creates a
// `mem.Scratch` or `mem.Arena` owner and passes its allocator explicitly."
//
// Both are the same thing: one pointer to an address-stable control block in
// `runtime/arena.c`. Two nominal types because design.md publishes two names and
// gives them different constructors — an `Arena` may be laid over a caller's
// fixed buffer, a `Scratch` is always provider-backed.
//
// Address stability is the whole point. design.md: "Copying an allocator value
// preserves that identity, and every allocation records it." Here the identity
// *is* the control block's address, so moving the owner cannot change it, and
// the region check has one fact to follow rather than a per-copy tag.
//
// The value is move-only. Two owners of one control block would release it
// twice, and there is no meaningful clone of a bump region — so `clone` is
// disabled in `lifecycle_of` rather than generated and then trapped.
package lokec

// The single field: the control-block pointer. Not user-visible, for the same
// reason a container's four words are not.
PROVIDER_CONTROL :: 0

// Which contributed operation one provider member is.
Provider_Op :: enum {
	None,
	// `mem.Arena()`, `mem.Arena(buffer)`, `mem.Scratch()`. One member with a
	// defaulted buffer rather than two overloads, because a Loke type has one
	// member per name. An empty buffer means "ask the program default provider
	// for blocks"; a non-empty one carves the control block out of the caller's
	// storage, so the region never allocates at all and the buffer has to outlive
	// it — an ordinary borrow, checked as one.
	Open,
	// `arena.allocator()`: the handle. Its region is this provider's.
	Handle,
}

arena_type :: proc(c: ^Compiler) -> Type_Id {
	if c.arena_type == INVALID_TYPE {
		c.arena_type = new_provider_type(c, "mem.Arena")
	}
	return c.arena_type
}

scratch_type :: proc(c: ^Compiler) -> Type_Id {
	if c.scratch_type == INVALID_TYPE {
		c.scratch_type = new_provider_type(c, "mem.Scratch")
	}
	return c.scratch_type
}

@(private = "file")
new_provider_type :: proc(c: ^Compiler, name: string) -> Type_Id {
	type := new_type(c, Type_Info{kind = .Struct, name = intern_identifier(c, name), provider = true})
	fields := make([]Symbol_Id, 1, c.semantic_allocator)
	fields[PROVIDER_CONTROL] = new_symbol(c, Symbol {
		name  = intern_identifier(c, "control"),
		span  = no_span(),
		kind  = .Field,
		type  = TYPE_RAWPTR,
		index = PROVIDER_CONTROL,
	})
	if info := type_of(c, type); info != nil {
		info.fields = fields
		info.mangled = llvm_safe(name)
	}
	return type
}

// Whether this type is one of the two local region providers. Asked by the
// lifecycle classifier, the region lattice, and the backend's drop path.
type_is_region_provider :: proc(c: ^Compiler, id: Type_Id) -> bool {
	info := type_of(c, type_underlying(c, id))
	return info != nil && info.provider
}

// design.md writes both constructors as calls on the type name, which is the
// ordinary `init` path: `arena := mem.Arena();` and `mem.Arena(buffer[:])`.
ensure_provider_members :: proc(k: ^Checker, type: Type_Id) {
	info := type_of(k.c, type_underlying(k.c, type))
	if info == nil || !info.provider || .Container in info.contributed {
		return
	}
	info.contributed += {.Container}

	// design.md "The allocator selects the location of backing storage":
	// `arena := mem.Arena(buffer[:])` puts a dynamic array's backing storage in
	// the current stack frame. The buffer is written into, so it is `[]mut u8`.
	// `mem.Scratch` is always provider-backed and takes no buffer at all.
	members := make([dynamic]Symbol_Id, 0, 2, k.c.semantic_allocator)
	if type == k.c.arena_type {
		buffer := slice_of(k.c, TYPE_U8, mutable = true)
		init := provider_member(
			k, type, "init", .Open,
			[]Type_Id{buffer}, []Param_Mode{.Value}, []Type_Id{type}, has_receiver = false,
		)
		if sym := symbol_of(k.c, init); sym != nil {
			sym.param_defaults[0] = empty_slice_arg(k.c, buffer)
		}
		append(&members, init)
	} else {
		append(&members, provider_member(
			k, type, "init", .Open, []Type_Id{}, []Param_Mode{}, []Type_Id{type}, has_receiver = false,
		))
	}
	// The receiver is by value: the handle is derived from the control block's
	// address, and reading a provider does not modify it.
	append(&members, provider_member(
		k, type, "allocator", .Handle,
		[]Type_Id{type}, []Param_Mode{.Value}, []Type_Id{TYPE_ALLOCATOR}, has_receiver = true,
	))
	add_members(k.c, type, members[:])
}

// The nil slice a defaulted `mem.Arena()` receives. One shared node, exactly as
// a written default argument is shared by every call site that omits it.
@(private = "file")
empty_slice_arg :: proc(c: ^Compiler, type: Type_Id) -> Expr {
	if c.empty_slice_arg != nil {
		return c.empty_slice_arg
	}
	value, ok := zero_const(c, type)
	if !ok {
		return nil
	}
	literal := new(Expr_Literal, c.semantic_allocator)
	literal.span = no_span()
	literal.kind = .Int // unread: the constant value is what the backend emits
	literal.type = type
	literal.value_category = .Value
	literal.is_const = true
	literal.const_value = value
	c.empty_slice_arg = literal
	return literal
}

@(private = "file")
provider_member :: proc(
	k: ^Checker,
	owner: Type_Id,
	name: string,
	op: Provider_Op,
	params: []Type_Id,
	modes: []Param_Mode,
	results: []Type_Id,
	has_receiver: bool,
) -> Symbol_Id {
	id := synth_proc(k.c, name, .Provider_Op, owner, params, modes, results)
	if sym := symbol_of(k.c, id); sym != nil {
		sym.has_receiver = has_receiver
		if has_receiver {
			sym.receiver = .Value
		}
		sym.provider_op = op
	}
	return id
}

// The provider a `Provider_Op` member belongs to, or `.None` for anything else.
// One lookup, so the checker and the backend agree about what a call is.
call_provider_op :: proc(c: ^Compiler, v: ^Expr_Call) -> Provider_Op {
	sym := symbol_of(c, v.resolution.chosen_overload)
	if sym == nil || sym.synth != .Provider_Op {
		return .None
	}
	return sym.provider_op
}

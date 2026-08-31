// Local allocator regions: `mem.Arena` and `mem.Scratch`.
//
// design.md "Allocators": there is no ambient temporary allocator. Temporary
// storage has a reset boundary and runtime identity, so code creates a
// `mem.Scratch` or `mem.Arena` owner and passes its allocator explicitly.
//
// Both are the same thing: one pointer to an address-stable control block in
// `runtime/arena.c`. Two nominal types because design.md publishes two names
// with different constructors — an `Arena` may be laid over a caller's fixed
// buffer, a `Scratch` is always provider-backed.
//
// Address stability is the whole point: copying an allocator value preserves
// identity, and every allocation records it (design.md). Here the identity
// *is* the control block's address, so moving the owner can't change it, and
// the region check has one fact to follow rather than a per-copy tag.
//
// The value is move-only: two owners of one control block would release it
// twice, and there is no meaningful clone of a bump region — so `clone` is
// disabled in `lifecycle_of` rather than generated and then trapped.
package lokec

// The single field: the control-block pointer. Not user-visible, for the same
// reason a container's four words are not.
PROVIDER_CONTROL :: 0

// Which contributed operation one provider member is.
Provider_Op :: enum {
	None,
	// Provider-backed `mem.Arena.init(parent)` and `mem.Scratch.init(parent)`.
	Open,
	// `mem.Arena.from_buffer(buffer)`, whose storage and control block live in the buffer.
	Open_Fixed,
	// Fallible package procedures `mem.try_arena(parent)` and
	// `mem.try_scratch(parent)`.
	Try_Open,
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
	info := underlying_info(c, id)
	return info != nil && info.provider
}

// design.md writes both constructors as calls on the type name, the ordinary
// `init` path. Provider-backed construction accepts an explicit parent
// allocator and defaults to the program provider; `Arena(buffer)` remains the
// fixed-storage overload.
ensure_provider_members :: proc(k: ^Checker, type: Type_Id) {
	info := underlying_info(k.c, type)
	if info == nil || !info.provider || .Container in info.contributed {
		return
	}
	info.contributed += {.Container}

	// design.md "The allocator selects the location of backing storage":
	// `arena := mem.Arena.from_buffer(buffer[:])` puts a dynamic array's backing
	// storage in the current stack frame. The buffer is written into, so it is
	// `[]mut u8`. `mem.Scratch` is always provider-backed.
	members := make([dynamic]Symbol_Id, 0, 3, k.c.semantic_allocator)
	if type == k.c.arena_type {
		buffer := slice_of(k.c, TYPE_U8, mutable = true)
		append(&members, provider_member(
			k.c, type, "from_buffer", .Open_Fixed,
			[]Type_Id{buffer}, []Param_Mode{.Value}, type, has_receiver = false,
		))
	}
	open := provider_member(
		k.c, type, "init", .Open,
		[]Type_Id{TYPE_ALLOCATOR}, []Param_Mode{.Value}, type, has_receiver = false,
	)
	if sym := symbol_of(k.c, open); sym != nil {
		sym.param_defaults[0] = default_allocator_arg(k.c)
	}
	append(&members, open)
	// The receiver is by value: the handle is derived from the control block's
	// address, and reading a provider does not modify it.
	append(&members, provider_member(
		k.c, type, "allocator", .Handle,
		[]Type_Id{type}, []Param_Mode{.Value}, TYPE_ALLOCATOR, has_receiver = true,
	))
	add_members(k.c, type, members[:])
}

@(private = "file")
provider_member :: proc(
	c: ^Compiler,
	owner: Type_Id,
	name: string,
	op: Provider_Op,
	params: []Type_Id,
	modes: []Param_Mode,
	result: Type_Id,
	has_receiver: bool,
) -> Symbol_Id {
	id := synth_proc(c, name, .Provider_Op, owner, params, modes, result)
	if sym := symbol_of(c, id); sym != nil {
		sym.has_receiver = has_receiver
		if has_receiver {
			sym.receiver = .Value
		}
		sym.provider_op = op
	}
	return id
}

// A package-level fallible constructor. It is synthesized eagerly when
// `core:mem` is loaded because, unlike an associated member, package lookup has
// no type from which to trigger lazy contribution.
provider_try_proc :: proc(k: ^Checker, owner: Type_Id, name: string) -> Symbol_Id {
	c := k.c
	id := provider_member(
		c, owner, name, .Try_Open,
		[]Type_Id{TYPE_ALLOCATOR}, []Param_Mode{.Value},
		result_type(k, owner, TYPE_ALLOCATOR_ERROR),
		has_receiver = false,
	)
	if sym := symbol_of(c, id); sym != nil {
		sym.param_defaults[0] = default_allocator_arg(c)
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

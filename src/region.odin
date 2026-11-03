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
// The region identity is the control block's address (design.md "Allocator regions
// and region provenance"), so moving or copying a handle keeps it and the region
// check follows one fact.
//
// The value is move-only: two owners of one control block would release it
// twice, and there is no meaningful clone of a bump region — so `clone` is
// disabled in `lifecycle_of` rather than generated and then trapped.
package lokec

// Index of the one field, the control-block pointer.
PROVIDER_CONTROL :: 0

Provider_Op :: enum {
	None,
	// `mem.Arena.init(parent, policy)` and `mem.Scratch.init(parent, policy)`.
	Open,
	// `mem.Arena.from_buffer(buffer, policy)`: storage and control block in the
	// buffer.
	Open_Fixed,
	// `mem.try_arena(parent, policy)` and `mem.try_scratch(parent, policy)`.
	Try_Open,
	// `arena.allocator()`: the handle. Its region is this provider's.
	Handle,
}

// design.md "Allocators": what `core:mem` holds that the compiler has to recognise.
// A package-level fallible constructor is synthesized here too, as package lookup
// has no type to trigger contribution from.
contribute_provider_types :: proc(k: ^Checker, pkg: ^Package) {
	c := k.c
	arena, scratch := new_provider_type(c, "mem.Arena"), new_provider_type(c, "mem.Scratch")
	// design.md "Allocation failure": the policy a region's own failures follow. The
	// members' values are the runtime's `LOKE_RT_ON_FAILURE_*`.
	policy := synth_enum(c, "mem.Failure_Policy", {"Panic", "Trap"})
	contribute_type(c, pkg, "Arena", arena)
	contribute_type(c, pkg, "Scratch", scratch)
	contribute_type(c, pkg, "Failure_Policy", policy)
	contribute_symbol(c, pkg, "try_arena", provider_try_proc(k, arena, "try_arena", policy))
	contribute_symbol(c, pkg, "try_scratch", provider_try_proc(k, scratch, "try_scratch", policy))
	// The buffer is written into, so it is `[]mut u8`. `mem.Scratch` is always
	// provider-backed.
	buffer := slice_of(c, TYPE_U8, mutable = true)
	add_provider_members(c, arena, policy, provider_constructor(c, arena, "from_buffer", .Open_Fixed, buffer, "buffer", arena, policy))
	add_provider_members(c, scratch, policy)
}

// The `.Panic` an omitted `policy` argument means.
@(private = "file")
panic_policy_arg :: proc(c: ^Compiler, policy: Type_Id) -> Expr {
	literal := new(Expr_Literal, c.semantic_allocator)
	literal.span = no_span()
	literal.kind = .Int
	literal.type = policy
	literal.value_category = .Value
	literal.is_const = true
	literal.const_value = int_const(c, 0)
	return literal
}

@(private = "file")
new_provider_type :: proc(c: ^Compiler, name: string) -> Type_Id {
	fields := make([]Symbol_Id, 1, c.semantic_allocator)
	fields[PROVIDER_CONTROL] = new_field(c, "control", TYPE_RAWPTR, PROVIDER_CONTROL)
	return new_type(c, Type_Info{kind = .Struct, name = intern_identifier(c, name), provider = true, fields = fields, backend_label = name})
}

// Whether this type is one of the two local region providers, through a
// `distinct` wrapper too: the region lattice follows storage, not names.
type_is_region_provider :: proc(c: ^Compiler, id: Type_Id) -> bool {
	info := underlying_info(c, id)
	return info != nil && info.provider
}

// Whether a value of this type holds a provider by value, so ending the value
// ends that provider's region.
type_carries_provider :: proc(c: ^Compiler, type: Type_Id) -> bool {
	if cached, found := c.provider_carriers[type]; found {
		return cached
	}
	visited := make(map[Type_Id]bool, 8, context.temp_allocator)
	carries := provider_reach_walk(c, type, &visited)
	c.provider_carriers[type] = carries
	return carries
}

@(private = "file")
provider_reach_walk :: proc(c: ^Compiler, type: Type_Id, visited: ^map[Type_Id]bool) -> bool {
	if type == INVALID_TYPE || visited[type] {
		return false
	}
	visited[type] = true
	if type_is_region_provider(c, type) {
		return true
	}
	info := underlying_info(c, type)
	if info == nil {
		return false
	}
	// design.md "Shared ownership": any strong handle may be the last, whose end
	// ends the payload. A `Weak` one keeps no payload.
	if payload := shared_payload_type(c, type); payload != INVALID_TYPE {
		return info.instance_of == c.shared_symbol && provider_reach_walk(c, payload, visited)
	}
	#partial switch info.kind {
	case .Struct:
		for field in info.fields {
			if sym := symbol_of(c, field); sym != nil && provider_reach_walk(c, sym.type, visited) {
				return true
			}
		}
	case .Union:
		for payload in info.variants {
			if payload != TYPE_VOID && provider_reach_walk(c, payload, visited) {
				return true
			}
		}
	case .Array, .Dynamic_Array, .Box, .Map:
		return provider_reach_walk(c, info.element, visited) || provider_reach_walk(c, info.key, visited)
	}
	return false
}

// The provider's own info, never the underlying one: `add_members` installs on the
// type as given, and design.md "Distinct types" says a `distinct` alias does not
// inherit the members.
@(private = "file")
add_provider_members :: proc(c: ^Compiler, type, policy: Type_Id, extra := INVALID_SYMBOL) {
	members := make([dynamic]Symbol_Id, 0, 3, c.semantic_allocator)
	if extra != INVALID_SYMBOL {
		append(&members, extra)
	}
	append(&members, provider_constructor(c, type, "init", .Open, TYPE_ALLOCATOR, "parent", type, policy, default_allocator_arg(c)))
	// The receiver is by value: the handle is derived from the control block's
	// address, and reading a provider does not modify it.
	handle := provider_member(c, type, "allocator", .Handle, []Type_Id{type}, TYPE_ALLOCATOR)
	symbol_of(c, handle).has_receiver = true
	append(&members, handle)
	add_members(c, type, members[:])
}

@(private = "file")
provider_member :: proc(c: ^Compiler, owner: Type_Id, name: string, op: Provider_Op, params: []Type_Id, result: Type_Id) -> Symbol_Id {
	modes := make([]Param_Mode, len(params), c.semantic_allocator)
	id := synth_proc(c, name, .Provider_Op, owner, params, modes, result)
	symbol_of(c, id).provider_op = op
	return id
}

// A constructor taking its storage source, then a `policy` that defaults to
// `.Panic`. Both are named, so `policy = .Trap` may be written alone.
@(private = "file")
provider_constructor :: proc(
	c: ^Compiler,
	owner: Type_Id,
	name: string,
	op: Provider_Op,
	source: Type_Id,
	source_name: string,
	result, policy: Type_Id,
	source_default: Expr = nil,
) -> Symbol_Id {
	id := provider_member(c, owner, name, op, []Type_Id{source, policy}, result)
	sym := symbol_of(c, id)
	sym.param_defaults[0] = source_default
	sym.param_defaults[1] = panic_policy_arg(c, policy)
	for parameter, index in ([]string{source_name, "policy"}) {
		sym.param_symbols[index] = new_parameter(c, intern_identifier(c, parameter), sym.params[index], .Value)
	}
	return id
}

@(private = "file")
provider_try_proc :: proc(k: ^Checker, owner: Type_Id, name: string, policy: Type_Id) -> Symbol_Id {
	return provider_constructor(
		k.c, owner, name, .Try_Open, TYPE_ALLOCATOR, "parent", result_type(k, owner, TYPE_ALLOCATOR_ERROR), policy, default_allocator_arg(k.c),
	)
}

// Which provider operation this call resolved to, or `.None`.
call_provider_op :: proc(c: ^Compiler, v: ^Expr_Call) -> Provider_Op {
	sym := symbol_of(c, v.resolution.chosen_overload)
	return sym != nil ? sym.provider_op : .None
}

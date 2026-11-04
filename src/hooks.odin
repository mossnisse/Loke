// Semantic lifecycle hooks and the managed-type classification (design.md
// "Lifecycle hooks and resource types").
package lokec

// What a type's lifecycle is, cached per underlying type. Resolved lazily because
// a record's fields may be checked after the `impl` block that gives it a hook.
Lifecycle :: struct {
	custom_drop:      Symbol_Id,
	custom_try_clone: Symbol_Id,
	// The contributed public copy entry points.
	clone:            Symbol_Id,
	try_clone:        Symbol_Id,
	// `@(move_only)`, a provider, holding a move-only part, or an instance whose
	// `hook(copy)` its `where` clause excluded: no copy exists.
	clone_disabled:   bool,
	// Has a hook, is move-only, or has a managed part.
	managed:          bool,
	// `string`, containers and providers: the runtime does the clone/drop, so
	// there is no hook symbol. A container's clone is a real, fallible deep copy.
	intrinsic:        bool,
	container:        bool,
	provider:         bool,
	// design.md "Owned values": a `Box(T)`. Its clone allocates and its drop
	// releases, both through the allocator its allocation records; the emitter
	// supplies both.
	boxed:            bool,
	state:            Size_State,
}

// Emission reads a finalized value snapshot, not the checker's lazy cache.
Lifecycle_Operations :: struct {
	using facts: Lifecycle,
	clone_fallible: bool,
	// Whether dropping one can run a user hook, and so panic. A container's
	// element hooks run inside the runtime, so one with managed parts counts.
	drop_may_panic: bool,
}

finalize_lifecycle_operations :: proc(c: ^Compiler) -> bool {
	if c.lifecycle_operations_ready { return true }
	if c.error_count != 0 { return false }
	if !committing(c) {
		return emission_contract_error(c, "lifecycle operations cannot be finalized during speculation")
	}
	// Creates no types, symbols, or procedures; every entry point already exists.
	for index in 1 ..< len(c.types) {
		if !finalize_type_lifecycle(c, Type_Id(index)) { return false }
	}
	c.lifecycle_operations_ready = true
	return true
}

@(private = "file")
finalize_type_lifecycle :: proc(c: ^Compiler, type: Type_Id) -> bool {
	under := type_underlying(c, type)
	if existing, found := c.lifecycle_operations[under]; found {
		if existing.state == .Finite { return true }
		return emission_contract_error(c, "a lifecycle dependency contains a by-value cycle")
	}
	if under == INVALID_TYPE { return true }
	facts := lifecycle_of(c, under)^
	operations := Lifecycle_Operations{facts = facts}
	operations.state = .Checking
	operations.clone_fallible = copy_itself_allocates(facts)
	if facts.boxed {
		operations.drop_may_panic = lifecycle_of(c, box_element(c, under)).managed
	} else if facts.container {
		operations.drop_may_panic = lifecycle_of(c, container_element(c, under)).managed
		if type_is_map(c, under) {
			operations.drop_may_panic ||= lifecycle_of(c, container_key(c, under)).managed
		}
	} else if !facts.intrinsic {
		operations.drop_may_panic = facts.custom_drop != INVALID_SYMBOL
	}
	c.lifecycle_operations[under] = operations
	for part in lifecycle_parts(c, under) {
		if !finalize_type_lifecycle(c, part) { return false }
		operations.clone_fallible ||= c.lifecycle_operations[type_underlying(c, part)].clone_fallible
		if !facts.intrinsic {
			operations.drop_may_panic ||= c.lifecycle_operations[type_underlying(c, part)].drop_may_panic
		}
	}
	operations.state = .Finite
	c.lifecycle_operations[under] = operations
	return true
}

// The parts a generated copy or drop visits: a record's fields, one fixed-array
// element (they all share its operations), or every union payload.
@(private = "file")
lifecycle_parts :: proc(c: ^Compiler, type: Type_Id) -> []Type_Id {
	info := underlying_info(c, type)
	// A type that contains itself by value is already `L0364`, and walking its
	// parts would not end.
	if info == nil || info.size_state == .Cyclic {
		return nil
	}
	parts := make([dynamic]Type_Id, 0, 4, context.temp_allocator)
	#partial switch info.kind {
	case .Array:
		if info.count > 0 { append(&parts, info.element) }
	case .Struct:
		for index in 0 ..< len(info.fields) { append(&parts, clone_part(c, type, index)) }
	case .Union:
		for variant in info.variants {
			if variant != TYPE_VOID { append(&parts, variant) }
		}
	}
	return parts[:]
}

resolved_lifecycle_operations :: proc(c: ^Compiler, type: Type_Id) -> (Lifecycle_Operations, bool) {
	operations, found := c.lifecycle_operations[type_underlying(c, type)]
	return operations, c.lifecycle_operations_ready && found && operations.state == .Finite
}

lifecycle_of :: proc(c: ^Compiler, type: Type_Id) -> ^Lifecycle {
	under := type_underlying(c, type)
	// An entry still `.Checking` is a record reached through a container of
	// itself; by-value cycles were already rejected by the finite-size check.
	if existing, found := c.lifecycles[under]; found {
		return existing
	}
	entry := new(Lifecycle, c.semantic_allocator)
	entry.custom_drop = INVALID_SYMBOL
	entry.custom_try_clone = INVALID_SYMBOL
	// design.md "Interface bodies": a requirement cannot prove capabilities of
	// a record still defining its fields. Neither it nor a container holding it
	// has a lifecycle to cache yet; assume no copy and possible cleanup until a
	// later query can inspect the completed record.
	visiting := make(map[Type_Id]bool, 8, context.temp_allocator)
	// design.md "Lifecycle hooks and resource types": a hook counts wherever it is
	// written. While file-scope blocks are still being declared, or an instance's
	// hooks are being resolved, what this type holds can still gain or lose one, so
	// the answer is what is known so far, and is not kept.
	open := c.impls_declaring > 0
	if !lifecycle_fields_resolved(c, under, &visiting, &open) {
		entry.clone_disabled = true
		entry.managed = true
		return entry
	}
	entry.state = .Checking
	c.lifecycles[under] = entry

	info := type_of(c, under)
	if info != nil {
		collect_hooks(c, info, entry)
		entry.container = info.kind == .Dynamic_Array || info.kind == .Map
		entry.provider = info.provider
		entry.boxed = info.kind == .Box
		entry.intrinsic = info.kind == .String || entry.container || entry.provider
		entry.clone_disabled = type_itself_move_only(c, info) || has_move_only_part(c, under, info)
		entry.managed =
			entry.intrinsic ||
			entry.boxed ||
			entry.custom_drop != INVALID_SYMBOL ||
			entry.custom_try_clone != INVALID_SYMBOL ||
			entry.clone_disabled ||
			has_managed_part(c, info)
	}
	if open {
		delete_key(&c.lifecycles, under)
		return entry
	}
	entry.state = .Finite
	return entry
}

@(private = "file")
lifecycle_fields_resolved :: proc(c: ^Compiler, type: Type_Id, visiting: ^map[Type_Id]bool, open: ^bool) -> bool {
	under := type_underlying(c, type)
	info := type_of(c, under)
	if info == nil || visiting[under] { return true }
	if record_resolving(c, info) { return false }
	open^ ||= info.hooks_resolving
	visiting[under] = true
	for part in type_owned_parts(c, info) {
		if !lifecycle_fields_resolved(c, part, visiting, open) { return false }
	}
	return true
}

// Inherent, hand-written members only: extensions never contribute a hook.
@(private = "file")
collect_hooks :: proc(c: ^Compiler, info: ^Type_Info, entry: ^Lifecycle) {
	for member in info.members {
		sym := symbol_of(c, member)
		if sym == nil || sym.synth != .None {
			continue
		}
		switch sym.hook {
		case .Drop:
			// design.md "where clauses": an instance that fails the hook's bound has no
			// such member, and no body of it is emitted; its parts still drop.
			if !sym.bound_excluded {
				entry.custom_drop = member
			}
		case .Copy:
			// One its bound excluded makes the instance move-only instead.
			if !sym.bound_excluded {
				entry.custom_try_clone = member
			}
		case .Convert, .None:
		}
	}
}

// Asked only of what is not managed for itself, as a container or box already is.
@(private = "file")
has_managed_part :: proc(c: ^Compiler, info: ^Type_Info) -> bool {
	for part in type_owned_parts(c, info) {
		if type_is_managed(c, part) {
			return true
		}
	}
	return false
}

type_is_managed :: proc(c: ^Compiler, type: Type_Id) -> bool {
	if type == INVALID_TYPE {
		return false
	}
	return lifecycle_of(c, type).managed
}

// Whether dropping a value of this type runs a hand-written `hook(drop)`, its
// own or one of something it owns. Such a hook may read the value's borrows,
// so the drop is a use of them; a container's intrinsic drop reads none.
type_drop_runs_hook :: proc(c: ^Compiler, type: Type_Id) -> bool {
	return len(type_drop_hooks(c, type)) > 0
}

// The hand-written `hook(drop)`s dropping a value of this type may run: its own
// and those of everything it owns.
type_drop_hooks :: proc(c: ^Compiler, type: Type_Id) -> []Symbol_Id {
	return type_hooks(c, type, .Drop)
}

// The hand-written `hook(copy)`s copying a value of this type may run: its own,
// which then decides how its parts are copied, or those of everything it owns.
type_copy_hooks :: proc(c: ^Compiler, type: Type_Id) -> []Symbol_Id {
	return type_hooks(c, type, .Copy)
}

@(private = "file")
type_hooks :: proc(c: ^Compiler, type: Type_Id, role: Hook_Kind) -> []Symbol_Id {
	// Most values own nothing; they need no walk state.
	if !type_is_managed(c, type) {
		return nil
	}
	hooks := make([dynamic]Symbol_Id, 0, 2, context.temp_allocator)
	visiting := make(map[Type_Id]bool, 8, context.temp_allocator)
	type_hooks_walk(c, type, role, &visiting, &hooks)
	return hooks[:]
}

@(private = "file")
type_hooks_walk :: proc(c: ^Compiler, type: Type_Id, role: Hook_Kind, visiting: ^map[Type_Id]bool, hooks: ^[dynamic]Symbol_Id) {
	if !type_is_managed(c, type) {
		return
	}
	under := type_underlying(c, type)
	info := type_of(c, under)
	if info == nil || visiting[under] {
		return
	}
	visiting[under] = true
	entry := lifecycle_of(c, type)
	if hook := role == .Drop ? entry.custom_drop : entry.custom_try_clone; hook != INVALID_SYMBOL {
		append(hooks, hook)
		if role == .Copy {
			return
		}
	}
	// A zero-length array has no element to copy or drop (design.md "Slice literals").
	if info.kind == .Array && info.count == 0 {
		return
	}
	for part in type_owned_parts(c, info) {
		type_hooks_walk(c, part, role, visiting, hooks)
	}
}

type_clone_disabled :: proc(c: ^Compiler, type: Type_Id) -> bool {
	if type == INVALID_TYPE {
		return false
	}
	return lifecycle_of(c, type).clone_disabled
}

// Containers count: their clone deep-copies elements. The question is whether a move-only type is reachable, so each type is visited
// once. What a walk finds holds for the queried type only, so nothing is cached.
@(private = "file")
has_move_only_part :: proc(c: ^Compiler, type: Type_Id, info: ^Type_Info) -> bool {
	visiting := make(map[Type_Id]bool, 8, context.temp_allocator)
	visiting[type_underlying(c, type)] = true
	return has_move_only_part_walk(c, info, &visiting)
}

@(private = "file")
has_move_only_part_walk :: proc(c: ^Compiler, info: ^Type_Info, visiting: ^map[Type_Id]bool) -> bool {
	for part in type_owned_parts(c, info) {
		if type_clone_disabled_walk(c, part, visiting) {
			return true
		}
	}
	return false
}

@(private = "file")
type_clone_disabled_walk :: proc(c: ^Compiler, type: Type_Id, visiting: ^map[Type_Id]bool) -> bool {
	if type == INVALID_TYPE {
		return false
	}
	under := type_underlying(c, type)
	if existing, found := c.lifecycles[under]; found && existing.state == .Finite {
		return existing.clone_disabled
	}
	if visiting[under] {
		return false
	}
	info := type_of(c, under)
	if info == nil {
		return false
	}
	if type_itself_move_only(c, info) {
		return true
	}
	visiting[under] = true
	return has_move_only_part_walk(c, info, visiting)
}

// What has no copy whatever its parts hold.
@(private = "file")
type_itself_move_only :: proc(c: ^Compiler, info: ^Type_Info) -> bool {
	return info.provider || info.move_only || has_excluded_copy_hook(c, info)
}

// design.md "Lifecycle hooks and resource types": an instance that fails its
// `hook(copy)`'s bound has no copy, rather than a bitwise one its drop hook would
// release twice.
@(private = "file")
has_excluded_copy_hook :: proc(c: ^Compiler, info: ^Type_Info) -> bool {
	for member in info.members {
		sym := symbol_of(c, member)
		if sym != nil && sym.synth == .None && sym.hook == .Copy && sym.bound_excluded {
			return true
		}
	}
	return false
}

// ------------------------------------------------- generated copy members --

// Contributed only when `clone`/`try_clone` is looked up: `lifecycle_of` caches,
// and asking before the subject's `impl` is declared would miss its hooks.
ensure_lifecycle_members :: proc(k: ^Checker, type: Type_Id, name: Identifier_Id) {
	switch identifier_text(k.c, name) {
	case "try_clone", "clone":
		contribute_lifecycle_members(k, type, requested = true)
	}
}

// The public `try_clone`/`clone` of a type, plus those of every managed part
// its generated bodies call. A plain value such as `int` or a slice is its own
// clone, so `Cloneable` holds for every copyable type; but it, like a
// `distinct` name's own pair, is contributed only when `requested` by a lookup
// of the member itself. An implicit copy of one needs no body, and the many
// copy sites would otherwise emit a pair for every scalar they touch.
contribute_lifecycle_members :: proc(k: ^Checker, written: Type_Id, requested := false) {
	type := type_underlying(k.c, written)
	contribute_underlying_lifecycle_members(k, type, requested)
	if type != written && requested {
		contribute_distinct_copy_members(k, written, type)
	}
}

// design.md "Distinct types": a copyable `distinct` name has its own pair, typed
// in the name; the lifecycle entry stays the underlying type's.
@(private = "file")
contribute_distinct_copy_members :: proc(k: ^Checker, written, under: Type_Id) {
	info := type_of(k.c, written)
	under_info := type_of(k.c, under)
	if info == nil || under_info == nil || lifecycle_settled(k.c, info) ||
	   .Lifecycle not_in under_info.contributed || lifecycle_of(k.c, under).clone_disabled {
		return
	}
	if .Lifecycle not_in info.contributed {
		info.contributed += {.Lifecycle}
		add_copy_members(k, written)
	}
	enroll_lifecycle_members(k.c, written)
}

// A hypothetical check may create a type's copy members, since resolving
// `value.clone()` needs the symbol, but must not enroll them in the program
// (compiler-architecture.md "Checking and overload resolution"). A real use
// enrolls them, so a speculative contribution is finished once created, a real
// one only once enrolled.
@(private = "file")
lifecycle_settled :: proc(c: ^Compiler, info: ^Type_Info) -> bool {
	return (committing(c) ? Contribution.Lifecycle_Enrolled : .Lifecycle) in info.contributed
}

@(private = "file")
enroll_lifecycle_members :: proc(c: ^Compiler, type: Type_Id) {
	info := type_of(c, type)
	if !committing(c) || .Lifecycle_Enrolled in info.contributed { return }
	info.contributed += {.Lifecycle_Enrolled}
	for id in info.members {
		sym := symbol_of(c, id)
		if sym == nil || (sym.synth != .Clone && sym.synth != .Try_Clone) { continue }
		enroll_synth(c, id)
		// A `distinct` name's pair is its own; the entry records the underlying's.
		if type_underlying(c, type) == type {
			entry := lifecycle_of(c, type)
			if sym.synth == .Try_Clone { entry.try_clone = id } else { entry.clone = id }
		}
	}
}

@(private = "file")
contribute_underlying_lifecycle_members :: proc(k: ^Checker, type: Type_Id, requested: bool) {
	info := type_of(k.c, type)
	if info == nil || info.descriptor || lifecycle_settled(k.c, info) {
		return
	}
	#partial switch info.kind {
	case .Struct, .Array, .Union, .Dynamic_Array, .Box, .Map, .String:
	case .Invalid, .Void, .Untyped_Int, .Untyped_Float, .Untyped_Bool, .Untyped_Rune,
	     .Untyped_Nil, .Untyped_String, .Interface, .Type:
		return
	case:
		if !requested { return }
	}
	if k.c.lifecycle_operations_ready {
		emission_contract_error(k.c, "lifecycle members were requested after finalization")
		return
	}
	entry := lifecycle_of(k.c, type)
	if entry.state != .Finite { return }
	created := .Lifecycle in info.contributed
	info.contributed += {.Lifecycle}

	// A move-only type has no copy entry point, but its parts still need theirs
	// for cleanup.
	if !entry.clone_disabled && !created {
		add_copy_members(k, type)
	}
	// Settled before the parts, so a type reached again through them stops.
	enroll_lifecycle_members(k.c, type)
	#partial switch info.kind {
	case .String:
	case .Dynamic_Array, .Box:
		contribute_lifecycle_members(k, info.element)
	case .Map:
		contribute_lifecycle_members(k, info.element)
		contribute_lifecycle_members(k, info.key)
	case:
		for part in lifecycle_parts(k.c, type) {
			if type_is_managed(k.c, part) {
				contribute_lifecycle_members(k, part)
			}
		}
	}
}

// The emitter supplies an intrinsic type's bodies, from `Lifecycle.intrinsic`.
@(private = "file")
add_copy_members :: proc(k: ^Checker, type: Type_Id) {
	// `add_members` keeps the slice it is handed, so this has to outlive the call.
	members := make([]Symbol_Id, 2, k.c.semantic_allocator)
	members[0] = generated_hook(k, type, .Try_Clone)
	members[1] = generated_hook(k, type, .Clone)
	add_members(k.c, type, members)
}

// Emission indexes these; `lifecycle_parts` keeps one array element.
clone_part_count :: proc(c: ^Compiler, type: Type_Id) -> int {
	info := underlying_info(c, type)
	if info == nil {
		return 0
	}
	#partial switch info.kind {
	case .Array:
		return int(info.count)
	case .Struct:
		return len(info.fields)
	}
	return 0
}

clone_part :: proc(c: ^Compiler, type: Type_Id, index: int) -> Type_Id {
	info := underlying_info(c, type)
	if info == nil {
		return INVALID_TYPE
	}
	if info.kind == .Array {
		return info.element
	}
	if index < 0 || index >= len(info.fields) {
		return INVALID_TYPE
	}
	sym := symbol_of(c, info.fields[index])
	return sym == nil ? INVALID_TYPE : sym.type
}

// A custom copy hook, a container's clone and a box's can each fail, and each
// allocates; a generated clone does so only through a part.
@(private = "file")
copy_itself_allocates :: proc(entry: Lifecycle) -> bool {
	return entry.custom_try_clone != INVALID_SYMBOL || entry.container || entry.boxed
}

// Whether copying a `type` may allocate: a container, or a record whose own or
// a field's copy is a custom `hook(copy)`. A `string` or `Shared(T)` copy
// retains its storage instead, and so does a record of them.
clone_may_allocate :: proc(c: ^Compiler, type: Type_Id) -> bool {
	question :: proc(c: ^Compiler, type: Type_Id, entry: ^Lifecycle) -> Part_Answer {
		if type_is_shared_handle(c, type) {
			return .No
		}
		return copy_itself_allocates(entry^) ? .Yes : .Ask_Parts
	}
	return some_lifecycle_part(c, type, question)
}

// Whether a `type` holds allocator storage its drop releases: a `string`, a
// container, a provider, a box, a `Shared(T)` handle, or a record or union
// holding one. A `@(move_only)` or hooked record of plain parts is managed for
// its lifecycle but frees nothing itself; what its hook does is the hook's.
type_owns_allocation :: proc(c: ^Compiler, type: Type_Id) -> bool {
	question :: proc(c: ^Compiler, type: Type_Id, entry: ^Lifecycle) -> Part_Answer {
		return entry.intrinsic || entry.boxed || type_is_shared_handle(c, type) ? .Yes : .Ask_Parts
	}
	return some_lifecycle_part(c, type, question)
}

@(private = "file")
Part_Answer :: enum {
	Ask_Parts,
	Yes,
	No,
}

@(private = "file")
Part_Question :: #type proc(c: ^Compiler, type: Type_Id, entry: ^Lifecycle) -> Part_Answer

// Whether `question` answers yes of a managed `type` or a part of it, however
// deep, asking each type once.
@(private = "file")
some_lifecycle_part :: proc(c: ^Compiler, type: Type_Id, question: Part_Question) -> bool {
	// Most values own nothing; they need no walk state.
	if !type_is_managed(c, type) {
		return false
	}
	visited := make(map[Type_Id]bool, 8, context.temp_allocator)
	return some_lifecycle_part_walk(c, type, question, &visited)
}

@(private = "file")
some_lifecycle_part_walk :: proc(c: ^Compiler, type: Type_Id, question: Part_Question, visited: ^map[Type_Id]bool) -> bool {
	under := type_underlying(c, type)
	if !type_is_managed(c, type) || visited[under] {
		return false
	}
	visited[under] = true
	switch question(c, type, lifecycle_of(c, type)) {
	case .Yes:
		return true
	case .No:
		return false
	case .Ask_Parts:
	}
	for part in lifecycle_parts(c, type) {
		if some_lifecycle_part_walk(c, part, question, visited) {
			return true
		}
	}
	return false
}

@(private = "file")
generated_hook :: proc(k: ^Checker, type: Type_Id, kind: Synth_Kind) -> Symbol_Id {
	fallible := kind == .Try_Clone
	result := fallible ? result_type(k, type, TYPE_ALLOCATOR_ERROR) : type
	// `enroll_lifecycle_members` enrolls it and records it in the lifecycle entry.
	id := synth_receiver_proc(
		k.c, fallible ? "try_clone" : "clone", kind, type,
		[]Type_Id{type, TYPE_ALLOCATOR}, []Param_Mode{.Borrow, .Value}, result,
		enroll = false,
	)
	symbol_of(k.c, id).param_defaults[1] = default_allocator_arg(k.c)
	return id
}

// The `default_allocator()` call supplied for an omitted hook allocator, one
// node shared by every call site.
default_allocator_arg :: proc(c: ^Compiler) -> Expr {
	if c.default_allocator_arg != nil {
		return c.default_allocator_arg
	}
	sym := c.default_allocator_symbol
	callee := synth_ident(c, "default_allocator", NO_SPAN)
	callee.symbol = sym
	callee.type = TYPE_ALLOCATOR
	callee.resolution = Resolution{kind = .Value, symbol = sym}
	callee.value_category = .Value

	call := synth_call(c, callee, nil, NO_SPAN)
	call.type = TYPE_ALLOCATOR
	call.value_category = .Value
	call.resolution = Resolution{kind = .Call, symbol = sym, chosen_overload = sym}
	call.operation = Call_Builtin{}
	c.default_allocator_arg = call
	return call
}

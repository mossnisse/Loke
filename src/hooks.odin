// Semantic lifecycle hooks and the managed-type classification (design.md
// "Lifecycle hooks and resource types"):
//
//   hook(drop): proc(self: inout T)
//   hook(copy): proc(self, allocator: Allocator) -> Result(T, Allocator_Error)
//
// The compiler supplies the copy hook's `mem.default_allocator()` default; a
// written default is rejected.
package lokec

// What a type's lifecycle is, cached per underlying type. Resolved lazily because
// a record's fields may be checked after the `impl` block that gives it a hook.
Lifecycle :: struct {
	custom_drop:      Symbol_Id,
	custom_try_clone: Symbol_Id,
	// The contributed public copy entry points.
	clone:            Symbol_Id,
	try_clone:        Symbol_Id,
	// `move_only`, a provider, or holding a move-only part: no copy exists.
	clone_disabled:   bool,
	// Has a hook, is move-only, or has a managed part.
	managed:          bool,
	// `string`, containers and providers: the runtime does the clone/drop, so
	// there is no hook symbol. A container's clone is a real, fallible deep copy.
	intrinsic:        bool,
	container:        bool,
	provider:         bool,
	state:            Size_State,
}

// Emission reads a finalized value snapshot, not the checker's lazy cache.
Lifecycle_Operations :: struct {
	using facts: Lifecycle,
	clone_fallible: bool,
}

finalize_lifecycle_operations :: proc(c: ^Compiler) -> bool {
	if c.lifecycle_operations_ready { return true }
	if c.error_count != 0 { return false }
	if c.speculation_depth != 0 {
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
	operations.clone_fallible = facts.custom_try_clone != INVALID_SYMBOL || facts.container
	c.lifecycle_operations[under] = operations
	for part in lifecycle_parts(c, under) {
		if !finalize_type_lifecycle(c, part) { return false }
		operations.clone_fallible ||= c.lifecycle_operations[type_underlying(c, part)].clone_fallible
	}
	operations.state = .Finite
	c.lifecycle_operations[under] = operations
	return true
}

// The parts a generated copy or drop visits: a record's fields, one fixed-array
// element (they all share its operations), or every union payload.
@(private = "file")
lifecycle_parts :: proc(c: ^Compiler, type: Type_Id) -> []Type_Id {
	count := clone_part_count(c, type)
	if underlying_kind(c, type) == .Array { count = min(count, 1) }
	parts := make([dynamic]Type_Id, 0, count, context.temp_allocator)
	for index in 0 ..< count { append(&parts, clone_part(c, type, index)) }
	if info := underlying_info(c, type); info != nil && info.kind == .Union {
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
	entry.state = .Checking
	c.lifecycles[under] = entry

	info := type_of(c, under)
	if info != nil {
		collect_hooks(c, under, info, entry)
		entry.container = info.kind == .Dynamic_Array || info.kind == .Map
		entry.provider = info.provider
		entry.intrinsic = info.kind == .String || entry.container || entry.provider
		entry.clone_disabled = entry.provider || info.move_only || has_move_only_part(c, under, info)
		entry.managed =
			entry.intrinsic ||
			entry.custom_drop != INVALID_SYMBOL ||
			entry.custom_try_clone != INVALID_SYMBOL ||
			entry.clone_disabled ||
			has_managed_part(c, under, info)
	}
	entry.state = .Finite
	return entry
}

// Inherent, hand-written members only: extensions never contribute a hook.
@(private = "file")
collect_hooks :: proc(c: ^Compiler, type: Type_Id, info: ^Type_Info, entry: ^Lifecycle) {
	for member in info.members {
		sym := symbol_of(c, member)
		if sym == nil || sym.synth != .None {
			continue
		}
		switch sym.hook {
		case .Drop:
			entry.custom_drop = member
		case .Copy:
			entry.custom_try_clone = member
		case .Convert, .None:
		}
	}
}

@(private = "file")
has_managed_part :: proc(c: ^Compiler, type: Type_Id, info: ^Type_Info) -> bool {
	#partial switch info.kind {
	case .Array:
		return type_is_managed(c, info.element)
	case .Struct:
		for field in info.fields {
			sym := symbol_of(c, field)
			if sym != nil && type_is_managed(c, sym.type) {
				return true
			}
		}
	case .Union:
		for variant in info.variants {
			if type_is_managed(c, variant) {
				return true
			}
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

type_clone_disabled :: proc(c: ^Compiler, type: Type_Id) -> bool {
	if type == INVALID_TYPE {
		return false
	}
	return lifecycle_of(c, type).clone_disabled
}

// Unlike `has_managed_part`, containers count: their clone deep-copies elements.
// The recursion-stack guard makes the answer exact for the queried type only,
// so intermediate answers are not cached.
@(private = "file")
has_move_only_part :: proc(c: ^Compiler, type: Type_Id, info: ^Type_Info) -> bool {
	visiting := make(map[Type_Id]bool, 8, context.temp_allocator)
	visiting[type_underlying(c, type)] = true
	return has_move_only_part_walk(c, info, &visiting)
}

@(private = "file")
has_move_only_part_walk :: proc(c: ^Compiler, info: ^Type_Info, visiting: ^map[Type_Id]bool) -> bool {
	#partial switch info.kind {
	case .Array, .Dynamic_Array:
		return type_clone_disabled_walk(c, info.element, visiting)
	case .Map:
		return type_clone_disabled_walk(c, info.key, visiting) ||
		       type_clone_disabled_walk(c, info.element, visiting)
	case .Struct:
		for field in info.fields {
			sym := symbol_of(c, field)
			if sym != nil && type_clone_disabled_walk(c, sym.type, visiting) {
				return true
			}
		}
	case .Union:
		for variant in info.variants {
			if variant != TYPE_VOID && type_clone_disabled_walk(c, variant, visiting) {
				return true
			}
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
	if info.provider || info.move_only {
		return true
	}
	visiting[under] = true
	defer delete_key(visiting, under)
	return has_move_only_part_walk(c, info, visiting)
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

// design.md "Distinct types": a `distinct` name inherits no operations, but it
// is copyable like its underlying type, so it gets its own pair typed in the
// name. The bodies copy exactly as the underlying type's do, and the lifecycle
// entry stays the underlying type's.
@(private = "file")
contribute_distinct_copy_members :: proc(k: ^Checker, written, under: Type_Id) {
	info := type_of(k.c, written)
	under_info := type_of(k.c, under)
	if info == nil || under_info == nil || .Lifecycle in info.contributed ||
	   .Lifecycle not_in under_info.contributed || lifecycle_of(k.c, under).clone_disabled {
		return
	}
	info.contributed += {.Lifecycle}
	members := make([dynamic]Symbol_Id, 0, 2, k.c.semantic_allocator)
	append(&members, generated_hook(k, written, "try_clone", .Try_Clone, true))
	if under_info.kind != .Array {
		append(&members, generated_hook(k, written, "clone", .Clone, false))
	}
	add_members(k.c, written, members[:])
}

@(private = "file")
contribute_underlying_lifecycle_members :: proc(k: ^Checker, type: Type_Id, requested: bool) {
	info := type_of(k.c, type)
	if info == nil || info.descriptor || .Lifecycle in info.contributed {
		return
	}
	#partial switch info.kind {
	case .Struct, .Array, .Union, .Dynamic_Array, .Map, .String:
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
	info.contributed += {.Lifecycle}
	entry := lifecycle_of(k.c, type)

	#partial switch info.kind {
	case .Dynamic_Array, .Map, .String:
		if !entry.clone_disabled {
			contribute_intrinsic_copy_members(k, type)
		}
		if info.kind != .String {
			contribute_lifecycle_members(k, info.element)
		}
		if info.kind == .Map {
			contribute_lifecycle_members(k, info.key)
		}
		return
	}

	// A move-only type has no copy entry point, but its parts still need theirs
	// for cleanup.
	if !entry.clone_disabled {
		members := make([dynamic]Symbol_Id, 0, 2, k.c.semantic_allocator)
		append(&members, generated_hook(k, type, "try_clone", .Try_Clone, true))
		// A fixed array is only reached as a part, so it gets no `clone`.
		if info.kind != .Array {
			append(&members, generated_hook(k, type, "clone", .Clone, false))
		}
		add_members(k.c, type, members[:])
	}
	for part in lifecycle_parts(k.c, type) {
		if type_is_managed(k.c, part) {
			contribute_lifecycle_members(k, part)
		}
	}
}

// The emitter supplies these bodies from `Lifecycle.intrinsic`.
@(private = "file")
contribute_intrinsic_copy_members :: proc(k: ^Checker, type: Type_Id) {
	// `add_members` keeps the slice it is handed, so this has to outlive the call.
	members := make([]Symbol_Id, 2, k.c.semantic_allocator)
	members[0] = generated_hook(k, type, "try_clone", .Try_Clone, true)
	members[1] = generated_hook(k, type, "clone", .Clone, false)
	add_members(k.c, type, members)
}

// The parts a generated field-wise clone visits: a record's fields or a fixed
// array's elements.
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

// Only a custom copy hook or a container's clone can fail; a generated clone
// fails when some part's can.
type_clone_is_fallible :: proc(c: ^Compiler, type: Type_Id) -> bool {
	if type == INVALID_TYPE {
		return false
	}
	entry := lifecycle_of(c, type)
	if entry.custom_try_clone != INVALID_SYMBOL || entry.container {
		return true
	}
	for part in lifecycle_parts(c, type) {
		if type_clone_is_fallible(c, part) {
			return true
		}
	}
	return false
}

@(private = "file")
generated_hook :: proc(k: ^Checker, type: Type_Id, name: string, kind: Synth_Kind, fallible: bool) -> Symbol_Id {
	result := fallible ? result_type(k, type, TYPE_ALLOCATOR_ERROR) : type
	id := synth_proc(
		k.c, name, kind, type,
		[]Type_Id{type, TYPE_ALLOCATOR}, []Param_Mode{.Borrow, .Value}, result,
	)
	if sym := symbol_of(k.c, id); sym != nil {
		sym.has_receiver = true
		sym.receiver = .Borrow
		sym.param_defaults[1] = default_allocator_arg(k.c)
	}
	// A `distinct` name's pair is its own; the entry records the underlying's.
	if type_underlying(k.c, type) == type {
		entry := lifecycle_of(k.c, type)
		if kind == .Try_Clone { entry.try_clone = id } else { entry.clone = id }
	}
	return id
}

// The `default_allocator()` call supplied for an omitted hook allocator, one
// node shared by every call site.
default_allocator_arg :: proc(c: ^Compiler) -> Expr {
	if c.default_allocator_arg != nil {
		return c.default_allocator_arg
	}
	sym := c.default_allocator_symbol
	callee := new(Expr_Ident, c.semantic_allocator)
	callee.span = no_span()
	callee.name = "default_allocator"
	callee.name_id = intern_identifier(c, "default_allocator")
	callee.symbol = sym
	callee.type = TYPE_ALLOCATOR
	callee.resolution = Resolution{kind = .Value, symbol = sym}
	callee.value_category = .Value

	call := new(Expr_Call, c.semantic_allocator)
	call.span = no_span()
	call.callee = callee
	call.type = TYPE_ALLOCATOR
	call.value_category = .Value
	call.resolution = Resolution{kind = .Call, symbol = sym, chosen_overload = sym}
	call.operation = Call_Builtin{}
	c.default_allocator_arg = call
	return call
}

// ------------------------------------------------------------ validation --

// Resolves the procedure nested in `hook(role)`, recording the role on the symbol.
resolve_hook_declaration :: proc(k: ^Checker, d: ^Decl, value: ^Expr_Operator) {
	if len(d.symbols) != 1 || d.symbols[0] == INVALID_SYMBOL {
		return
	}
	symbol_id := d.symbols[0]
	sym := symbol_of(k.c, symbol_id)
	if sym == nil {
		return
	}
	sym.hook = value.hook
	literal, ok := value.value.(^Expr_Proc)
	if !ok {
		return
	}
	sym.kind = .Proc
	literal.symbol = symbol_id
	resolve_proc_signature(k, literal, symbol_id)
	apply_proc_metadata(k, d, symbol_id)
	// Re-read: resolving may have grown the symbol table.
	if sym = symbol_of(k.c, symbol_id); sym != nil && k.impl_type == INVALID_TYPE {
		errorf(k.c, sym.span, "L0488", "`hook(%s)` is a type role and must be declared as an inherent `impl` member", hook_name(value.hook))
	}
}

// The fixed hook signatures, checked where each inherent declaration is written.
validate_semantic_hook :: proc(k: ^Checker, item: ^Item_Impl, d: ^Decl, sym: ^Symbol, symbol_id: Symbol_Id) {
	name := identifier_text(k.c, sym.name)
	if sym.hook == .None {
		if name == "clone" || name == "try_clone" {
			errorf(k.c, sym.span, "L0487", "`%s` is a compiler-generated copy operation; bind custom behavior with `hook(copy)`", name)
		}
		return
	}
	subject := item.subject
	if sym.hook != .Convert {
		info := type_of(k.c, subject)
		if info != nil && info.kind == .Distinct && underlying_kind(k.c, subject) == .Struct {
			errorf(k.c, sym.span, "L0488", "`hook(%s)` cannot be declared on `distinct` `%s`, which shares the lifecycle of `%s`", hook_name(sym.hook), type_name(k.c, subject), type_name(k.c, type_underlying(k.c, subject)))
			return
		}
		if info == nil || info.kind != .Struct {
			errorf(k.c, sym.span, "L0488", "`hook(%s)` is a record lifecycle role; `%s` is not a record type", hook_name(sym.hook), type_name(k.c, subject))
			return
		}
	}
	if item.kind == .Extend {
		errorf(
			k.c,
			sym.span,
			"L0486",
			"a semantic hook belongs with the package that declares `%s`; an extension block cannot add `hook(%s)`",
			type_name(k.c, subject),
			hook_name(sym.hook),
		)
		return
	}
	if sym.kind != .Proc {
		errorf(k.c, sym.span, "L0488", "`hook(%s)` must be a procedure with its fixed signature", hook_name(sym.hook))
		return
	}
	// Lifecycle roles are unique per type; conversions per source type. Only
	// earlier declarations are compared, so the later one is reported once.
	if info := underlying_info(k.c, subject); info != nil {
		for other_id in info.members {
			if other_id >= symbol_id {
				continue
			}
			other := symbol_of(k.c, other_id)
			if other == nil || other.synth != .None || other.hook != sym.hook {
				continue
			}
			conflict := sym.hook != .Convert
			if sym.hook == .Convert && len(sym.params) == 1 && len(other.params) == 1 {
				conflict = sym.params[0] == other.params[0]
			}
			if conflict {
				errorf(
					k.c,
					sym.span,
					"L0488",
					"duplicate `hook(%s)` for `%s`%s",
					hook_name(sym.hook),
					type_name(k.c, subject),
					sym.hook == .Convert ? " and this source type" : "",
				)
				return
			}
		}
	}
	switch sym.hook {
	case .Drop, .Copy:
		// Includes a record made move-only by one of its fields.
		if sym.hook == .Copy && type_clone_disabled(k.c, subject) {
			errorf(k.c, sym.span, "L0488", "a `move_only` type cannot also declare `hook(copy)`")
			return
		}
		require_hook_shape(k, sym, subject)
	case .Convert:
		if sym.has_receiver || len(sym.params) != 1 || sym.result != subject {
			errorf(k.c, sym.span, "L0411", "`hook(convert)` takes one value without a receiver and returns `%s`", type_name(k.c, subject))
			return
		}
		if convertible(k.c, sym.params[0], subject) {
			errorf(k.c, sym.span, "L0411", "`%s` already has a built-in conversion to `%s`; a conversion hook for that pair would be unreachable", type_name(k.c, sym.params[0]), type_name(k.c, subject))
		}
	case .None:
	}
}

@(private = "file")
require_hook_shape :: proc(k: ^Checker, sym: ^Symbol, subject: Type_Id) {
	ok := sym.has_receiver && len(sym.params) > 0 && sym.params[0] == subject
	shape: string
	if sym.hook == .Drop {
		shape = "proc(self: inout T)"
		ok = ok && sym.receiver == .Inout && len(sym.params) == 1 && sym.result == INVALID_TYPE
	} else {
		shape = "proc(self, allocator: Allocator) -> Result(T, Allocator_Error)"
		ok = ok && (sym.receiver == .Borrow || sym.receiver == .Value) && len(sym.params) == 2 && sym.params[1] == TYPE_ALLOCATOR &&
		     sym.result == result_type(k, subject, TYPE_ALLOCATOR_ERROR)
	}
	if !ok {
		errorf(k.c, sym.span, "L0488", "`%s` has a fixed signature for `%s`: `%s`", hook_name(sym.hook), type_name(k.c, subject), shape)
		return
	}
	if sym.hook == .Copy && len(sym.param_defaults) > 1 {
		if sym.param_defaults[1] != nil {
			errorf(
				k.c,
				expr_span(sym.param_defaults[1]),
				"L0489",
				"a lifecycle hook takes no written default; the compiler supplies `mem.default_allocator()`",
			)
			return
		}
		sym.param_defaults[1] = default_allocator_arg(k.c)
	}
}

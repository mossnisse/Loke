// Semantic lifecycle hooks and the managed-type classification.
//
// design.md "Lifecycle hooks and resource types": user records receive
// field-wise `try_clone`, `clone`, `move`, and `drop` behavior by default, and
// an `impl` block may bind `hook(copy)` or `hook(drop)` for a type
// that owns a resource. The signatures are fixed by the type, so they are
// validated rather than inferred:
//
//   hook(drop): proc(self: inout T)
//   hook(copy): proc(self, allocator: Allocator) -> Result(T, Allocator_Error)
//
// `move_only struct` disables both copy entry points. `clone` and `try_clone`
// remain generated public operations and are never implementation hook names.
//
// Narrowing: design.md fixes the canonical hook's default argument as
// `mem.default_allocator()` — fixed by the language, not chosen per type. A
// custom hook is therefore written with a plain `allocator: Allocator`
// parameter, and the compiler supplies the default at every call site that
// omits it. Writing a default on a lifecycle hook is rejected, including the
// one the design spells.
package lokec

// What a type's lifecycle is, cached per nominal type. Resolved lazily because a
// record's fields may be checked after the `impl` block that gives it a hook.
Lifecycle :: struct {
	custom_drop:      Symbol_Id,
	custom_try_clone: Symbol_Id,
	// Canonical public copy entry points, recorded when contributed. Emission
	// must not rediscover these by searching for the strings "clone"/"try_clone".
	clone:           Symbol_Id,
	try_clone:       Symbol_Id,
	// An explicit `move_only struct`, or a type that contains one: neither
	// public copy entry point exists.
	clone_disabled:   bool,
	// A record is managed when it has a drop/copy hook, is move-only, or has a
	// recursively managed field — the managed value is what scope exit cleans
	// up and what assignment clones.
	managed:          bool,
	// design.md "string type": a `string` is managed, but its clone/drop are the
	// runtime's shared-storage retain/release, not anything a package could
	// write — there is no hook symbol to find, so the emitter recognises this
	// flag instead of looking one up.
	//
	// The same holds for `[dynamic]T` and `map[K]V`, whose clone/drop are the
	// versioned C helpers driven by a generated operation table. `container`
	// tells the two apart: a string's implicit copy is a retain, a container's
	// is a real deep clone that can fail.
	intrinsic:        bool,
	container:        bool,
	// A local allocator-region provider (`src/region.odin`): managed and
	// move-only. Two owners of one control block would release it twice, and a
	// bump region has no meaningful copy — so `clone` is disabled here rather
	// than generated and trapped at run time.
	provider:         bool,
	state:            Size_State,
}

// Emission reads a finalized value snapshot, not the checker's lazy cache.
// Fallibility is transitive through record fields and nonempty fixed arrays.
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
	// This pass makes no types, symbols, or generated procedures. All contributed
	// entry points must already exist; unused types need facts, not new bodies.
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
	// The parts a generated copy visits, asked for through the one pair every
	// other walk uses, so the snapshot cannot index a record and a fixed array by
	// a second convention. One array element is enough regardless of the array's
	// length: walking every index would make finalization proportional to size.
	count := clone_part_count(c, under)
	if underlying_kind(c, under) == .Array && count > 1 { count = 1 }
	parts := make([dynamic]Type_Id, 0, count, context.temp_allocator)
	for index in 0 ..< count { append(&parts, clone_part(c, under, index)) }
	// Which variant is active is a runtime fact, so a union's generated clone
	// admits the worst case across every payload it could hold.
	if info := underlying_info(c, under); info != nil && info.kind == .Union {
		for variant in info.variants {
			if variant != TYPE_VOID { append(&parts, variant) }
		}
	}
	for part in parts {
		if !finalize_type_lifecycle(c, part) { return false }
		operations.clone_fallible ||= c.lifecycle_operations[type_underlying(c, part)].clone_fallible
	}
	operations.state = .Finite
	c.lifecycle_operations[under] = operations
	return true
}

resolved_lifecycle_operations :: proc(c: ^Compiler, type: Type_Id) -> (Lifecycle_Operations, bool) {
	operations, found := c.lifecycle_operations[type_underlying(c, type)]
	return operations, c.lifecycle_operations_ready && found && operations.state == .Finite
}

// `drop` has the signature `proc(self: inout T)` (design.md).
lifecycle_of :: proc(c: ^Compiler, type: Type_Id) -> ^Lifecycle {
	under := type_underlying(c, type)
	if existing, found := c.lifecycles[under]; found {
		if existing.state != .Checking {
			return existing
		}
		// A record reached through its own field: the cycle is broken by treating
		// the in-progress answer as final, which the finite-size check has already
		// rejected if it were a real by-value cycle.
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
		// design.md: assignment of a `string` shares immutable backing storage and
		// the last drop deallocates through the string's bound allocator, so a
		// string is an owner exactly like a record with `hook(drop)`.
		entry.container = info.kind == .Dynamic_Array || info.kind == .Map
		entry.provider = info.provider
		entry.intrinsic = info.kind == .String || entry.container || entry.provider
		entry.clone_disabled ||= entry.provider || info.move_only
		// A record containing a move-only part is itself move-only: the generated
		// field-wise clone would have no hook to call for that field. Only this
		// queried type is cached; a part reached through a cycle may see an
		// ancestor before the ancestor's later fields, so caching that partial
		// answer would make the result depend on declaration order.
		entry.clone_disabled ||= has_move_only_part(c, under, info)
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

@(private = "file")
collect_hooks :: proc(c: ^Compiler, type: Type_Id, info: ^Type_Info, entry: ^Lifecycle) {
	// Inherent members only: a lifecycle hook belongs with the type's own
	// package, so an extension block never contributes one.
	for member in info.members {
		sym := symbol_of(c, member)
		// A generated hook is not a custom one: reading one back would make the
		// type look customised the moment its own members were contributed.
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

// A fixed array inherits its element's lifecycle (design.md). A struct is
// managed when any field is.
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

// A `move_only` type has neither copy entry point, so assignment, copy
// initialization, and a borrowed-parameter return all have to say so rather
// than silently producing a shallow copy.
type_clone_disabled :: proc(c: ^Compiler, type: Type_Id) -> bool {
	if type == INVALID_TYPE {
		return false
	}
	return lifecycle_of(c, type).clone_disabled
}

// The parts whose move-only-ness the containing type inherits. A container is
// included, unlike `has_managed_part`: `[dynamic]T` owns a deep clone of its
// elements, so it has the same nothing-to-call problem a record does.
//
// This is existential reachability, so a recursion-stack guard gives the exact
// answer for the type asked about: an ancestor continues visiting its other
// fields after a back-edge contributes nothing. Only the queried lifecycle is
// cached. An intermediate part may have an answer that is right for this walk
// and wrong when asked on its own, because its path through the ancestor was
// deliberately cut.
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
		// A union holding a move-only variant is move-only: the tag-aware clone
		// would have no hook to call for the arm that is active.
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

// A user-defined record gets field-wise `try_clone`, `clone`, `move`, and
// `drop` by default, and `clone` is generated from `try_clone` — user code
// never replaces it independently (design.md). Both entry points are real
// members with real emitted bodies, so `value.clone()`, generic code, and the
// catalogue's `Cloneable` find them exactly where a hand-written hook would be.
//
// Keyed on the name being looked up rather than running for every member
// query. `lifecycle_of` caches its answer, so asking before the subject's own
// `impl` block is declared would freeze the wrong classification and install
// a generated hook beside the custom one.
ensure_lifecycle_members :: proc(k: ^Checker, type: Type_Id, name: Identifier_Id) {
	switch identifier_text(k.c, name) {
	case "try_clone", "clone":
	case:
		return
	}
	contribute_lifecycle_members(k, type)
}

// Generated bodies copy every managed part, including infallible ones; their
// dependencies must be contributed too — records use `clone`, fixed arrays use
// `try_clone`, strings retain their backing storage directly. Keyed on the
// underlying type, exactly as `lifecycle_of` is: a `distinct` name shares its
// underlying record's lifecycle and canonical copy procedures.
contribute_lifecycle_members :: proc(k: ^Checker, written: Type_Id) {
	type := type_underlying(k.c, written)
	info := type_of(k.c, type)
	if info == nil || info.descriptor || .Lifecycle in info.contributed {
		return
	}
	#partial switch info.kind {
	case .Struct, .Array, .Union, .Dynamic_Array, .Map, .String:
	case:
		return
	}
	if k.c.lifecycle_operations_ready {
		emission_contract_error(k.c, "lifecycle members were requested after finalization")
		return
	}
	// Copyable owning built-ins such as `string`, dynamic arrays, and maps
	// satisfy `Cloneable` (design.md "Standard interface catalogue"). That
	// interface names the `try_clone` slot, so those types need the member as
	// much as a record does — the difference is only what its body lowers to,
	// which `emit_synth_try_clone` decides from `Lifecycle.intrinsic`.
	#partial switch info.kind {
	case .Struct, .Array, .Union:
	case .Dynamic_Array, .Map:
		// What the generated operation table calls *is* the element's (and key's)
		// own hook, so the recursion has to run whatever this type installs.
		info.contributed += {.Lifecycle}
		contribute_intrinsic_copy_members(k, type)
		contribute_lifecycle_members(k, info.element)
		if info.kind == .Map {
			contribute_lifecycle_members(k, info.key)
		}
		return
	case .String:
		info.contributed += {.Lifecycle}
		contribute_intrinsic_copy_members(k, type)
		return
	case:
		// A built-in with no owned storage: its copy is its representation, so it
		// needs no hook and does not satisfy `Cloneable`.
		return
	}
	info.contributed += {.Lifecycle}

	entry := lifecycle_of(k.c, type)
	// A move-only declaration, or a record holding a move-only part, has no copy
	// entry point to contribute. Its managed parts still need theirs: cleanup of
	// a container field emits the container's complete operation table even when
	// the containing record itself can never be copied.
	if !entry.clone_disabled && !type_clone_disabled(k.c, type) {
		members := make([dynamic]Symbol_Id, 0, 2, k.c.semantic_allocator)
		// Always contribute the public fallible wrapper. With a custom `hook(copy)`
		// its emitted body forwards to that hook; otherwise it performs the generated
		// field-wise operation.
		append(&members, generated_hook(k, type, "try_clone", .Try_Clone, true))
		// design.md: `clone` is generated for a user record and for a union, both of
		// which a program names directly. A fixed array is reached only as a part of
		// one, and is not itself a record.
		if info.kind == .Struct || info.kind == .Union {
			append(&members, generated_hook(k, type, "clone", .Clone, false))
		}
		add_members(k.c, type, members[:])
	}

	// A union's parts are its variant payloads. The generated body reads the tag
	// and visits exactly one, and its cleanup follows the same tag. Any payload
	// could be active, so every payload's own operations have to exist even when
	// this union is move-only and has no generated body of its own.
	if info.kind == .Union {
		for variant in info.variants {
			if variant != TYPE_VOID && type_is_managed(k.c, variant) {
				contribute_lifecycle_members(k, variant)
			}
		}
		return
	}

	// All elements of a fixed array have the same operation dependencies.
	part_count := clone_part_count(k.c, type)
	if info.kind == .Array && part_count > 1 { part_count = 1 }
	for index in 0 ..< part_count {
		part := clone_part(k.c, type, index)
		if type_is_managed(k.c, part) {
			contribute_lifecycle_members(k, part)
		}
	}
}

// Both copy entry points for a built-in owning type. No field walk and no
// custom hook to respect: `string` retains a handle, a container calls its
// versioned helper — the members exist to be found by name and slot matching,
// and the emitter supplies the one body each has.
@(private = "file")
contribute_intrinsic_copy_members :: proc(k: ^Checker, type: Type_Id) {
	// `add_members` keeps the slice it is handed, so this has to outlive the call.
	members := make([]Symbol_Id, 2, k.c.semantic_allocator)
	members[0] = generated_hook(k, type, "try_clone", .Try_Clone, true)
	members[1] = generated_hook(k, type, "clone", .Clone, false)
	add_members(k.c, type, members)
}

// The parts a generated field-wise clone visits, in declaration order: a
// record's fields or a fixed array's elements. `clone_part_count`/`clone_part`
// are the one pair every walk uses, so a struct and an array are never
// indexed by two different conventions.
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

// Can cloning this type actually fail? Only a custom copy hook returns a real
// error; a generated one is fallible exactly when some part reaches one — this
// keeps a generated body a plain copy in the ordinary case, instead of a
// chain of error branches that can never be taken.
type_clone_is_fallible :: proc(c: ^Compiler, type: Type_Id) -> bool {
	if type == INVALID_TYPE {
		return false
	}
	if lifecycle_of(c, type).custom_try_clone != INVALID_SYMBOL {
		return true
	}
	// A container's clone duplicates its storage, so it allocates and can fail
	// whatever its element is.
	if lifecycle_of(c, type).container {
		return true
	}
	// A fixed array inherits its element's, so one part answers for every index.
	for index in 0 ..< clone_part_count(c, type) {
		if type_clone_is_fallible(c, clone_part(c, type, index)) {
			return true
		}
	}
	// A union inherits from every variant it could be holding: which one is
	// active is a runtime fact, so the signature has to admit the worst case.
	if info := underlying_info(c, type); info != nil && info.kind == .Union {
		for variant in info.variants {
			if variant != TYPE_VOID && type_clone_is_fallible(c, variant) {
				return true
			}
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
	entry := lifecycle_of(k.c, type)
	if kind == .Try_Clone { entry.try_clone = id } else { entry.clone = id }
	return id
}

// The call expression the compiler supplies for an omitted hook allocator. One
// shared node, exactly as a written default argument is shared by every call
// site that omits it.
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

// Resolves the ordinary procedure nested in `hook(role)` while retaining the
// role as semantic metadata rather than deriving it from the declaration name.
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
	if sym = symbol_of(k.c, symbol_id); sym != nil {
		sym.hook = value.hook
	}
	apply_proc_metadata(k, d, symbol_id)
	if k.impl_type == INVALID_TYPE {
		errorf(k.c, sym.span, "L0488", "`hook(%s)` is a type role and must be declared as an inherent `impl` member", hook_name(value.hook))
	}
}

// The fixed hook signatures, checked once where each inherent declaration is
// written. Ordinary names such as `init` and `drop` have no bearing here.
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
		if info == nil || info.kind != .Struct {
			errorf(k.c, sym.span, "L0488", "`hook(%s)` is a record lifecycle role; `%s` is not a record type", hook_name(sym.hook), type_name(k.c, subject))
			return
		}
	}

	// design.md: a lifecycle hook replaces behavior the compiler generates for
	// the type, so it belongs with the type's own package.
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
	// Lifecycle roles are unique per type. Conversion is overloadable, but a
	// source/target pair must still identify exactly one implementation.
	if info := underlying_info(k.c, subject); info != nil {
		for other_id in info.members {
			if other_id == symbol_id {
				continue
			}
			// Report the later declaration once; symbol ids follow declaration order.
			if other_id > symbol_id {
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
	case .Drop:
		require_hook_shape(k, sym, subject, "drop", "proc(self: inout T)", 1, 0, .Inout)
	case .Copy:
		if info := type_of(k.c, subject); info != nil && info.move_only {
			errorf(k.c, sym.span, "L0488", "a `move_only` type cannot also declare `hook(copy)`")
			return
		}
		require_hook_shape(k, sym, subject, "copy", "proc(self, allocator: Allocator) -> Result(T, Allocator_Error)", 2, 1, .Borrow)
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
require_hook_shape :: proc(
	k: ^Checker,
	sym: ^Symbol,
	subject: Type_Id,
	name: string,
	shape: string,
	params: int,
	results: int,
	receiver: Param_Mode,
) {
	bad := false
	if !sym.has_receiver || sym.receiver != receiver {
		bad = true
	}
	if len(sym.params) != params || (sym.result == INVALID_TYPE ? 0 : 1) != results {
		bad = true
	}
	if !bad && sym.params[0] != subject {
		bad = true
	}
	if !bad && name == "copy" {
		// design.md "Typed fallibility": the fallible copy primitive reports
		// through `Result(Self, Allocator_Error)`.
		if sym.params[1] != TYPE_ALLOCATOR ||
		   sym.result != result_type(k, subject, TYPE_ALLOCATOR_ERROR) {
			bad = true
		}
	}
	if bad {
		errorf(
			k.c,
			sym.span,
			"L0488",
			"`%s` has a fixed signature for `%s`: `%s`",
			name,
			type_name(k.c, subject),
			shape,
		)
		return
	}
	// The design's default argument names `mem.default_allocator()`, which is
	// fixed for every implementation, so the compiler supplies it instead of
	// re-checking a written copy of it.
	if name == "copy" && len(sym.param_defaults) > 1 {
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

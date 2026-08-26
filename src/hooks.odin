// Semantic lifecycle hooks and the managed-type classification.
//
// design.md "Lifecycle hooks and resource types": user records receive
// field-wise `try_clone`, `clone`, `move`, and `drop` behavior by default, and
// an `impl` block may bind `hook(copy)` or `hook(drop)` for a type
// that owns a resource. The signatures are fixed by the type, so they are
// validated rather than inferred:
//
//   hook(drop): proc(self: inout T)
//   hook(copy): proc(self, allocator: Allocator) -> (T, Allocator_Error)
//
// `move_only struct` disables both copy entry points. `clone` and `try_clone`
// remain generated public operations and are never implementation hook names.
//
// Narrowing: design.md gives the canonical hook a default argument of
// `mem.default_allocator()`, and that default is fixed by the language rather
// than chosen per type. A custom hook is therefore written with a plain
// `allocator: Allocator` parameter and the compiler supplies the default at
// every call site that omits it (m5a-plan step 3). Writing a default on a
// lifecycle hook is rejected — including the one the design spells.
package lokec

// What a type's lifecycle is, cached per nominal type. Resolved lazily because a
// record's fields may be checked after the `impl` block that gives it a hook.
Lifecycle :: struct {
	custom_drop:      Symbol_Id,
	custom_try_clone: Symbol_Id,
	// An explicit `move_only struct`: neither public copy entry point exists.
	clone_disabled:   bool,
	// A record is managed when it has a drop/copy hook, is move-only, or has a
	// recursively managed field. A managed value is
	// what scope exit cleans up and what assignment clones.
	managed:          bool,
	// design.md "string type": a `string` is managed, but its clone and drop are
	// the runtime's shared-storage retain and release rather than anything a
	// package could write. There is no hook symbol to find, so the emitter
	// recognises this flag instead of looking one up (m6a-plan step 4).
	//
	// The same is true of `[dynamic]T` and `map[K]V`, whose clone and drop are
	// the versioned C helpers driven by a generated operation table (m6b-plan
	// step 1). `container` tells the two apart, because a string's implicit copy
	// is a retain while a container's is a real deep clone that can fail.
	intrinsic:        bool,
	container:        bool,
	// A local allocator-region provider (`src/region.odin`). Managed, and
	// move-only: two owners of one control block would release it twice, and a
	// bump region has no meaningful copy. So `clone` is disabled here rather than
	// generated and then trapped at run time.
	provider:         bool,
	state:            Size_State,
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

// M5a implements recursive lifecycle operations for records and fixed arrays.
// A tagged union needs tag-aware clone/drop lowering so that only its active
// variant is touched; reject any runtime position that would require that
// lowering instead of letting it reach the backend as a managed value with no
// hook. Provenance does not change this boundary.
type_contains_managed_union :: proc(c: ^Compiler, type: Type_Id) -> bool {
	seen := make(map[Type_Id]bool, allocator = context.temp_allocator)
	return type_contains_managed_union_inner(c, type, &seen)
}

@(private = "file")
type_contains_managed_union_inner :: proc(c: ^Compiler, type: Type_Id, seen: ^map[Type_Id]bool) -> bool {
	under := type_underlying(c, type)
	if seen[under] {
		return false
	}
	seen[under] = true
	info := type_of(c, under)
	if info == nil {
		return false
	}
	#partial switch info.kind {
	case .Union:
		return lifecycle_of(c, type).managed
	case .Array, .Slice, .Dynamic_Array:
		return type_contains_managed_union_inner(c, info.element, seen)
	case .Map:
		return type_contains_managed_union_inner(c, info.key, seen) ||
		       type_contains_managed_union_inner(c, info.element, seen)
	case .Struct:
		for field in info.fields {
			sym := symbol_of(c, field)
			if sym != nil && type_contains_managed_union_inner(c, sym.type, seen) {
				return true
			}
		}
	}
	return false
}

// A `move_only` type has neither copy entry
// point, so assignment, copy initialization, and a borrowed-parameter return all
// have to say so rather than silently producing a shallow copy.
type_clone_disabled :: proc(c: ^Compiler, type: Type_Id) -> bool {
	if type == INVALID_TYPE {
		return false
	}
	if lifecycle_of(c, type).clone_disabled {
		return true
	}
	// A record containing a move-only part is itself move-only: the generated
	// field-wise clone would have no hook to call for that field.
	info := underlying_info(c, type)
	if info == nil {
		return false
	}
	#partial switch info.kind {
	case .Array, .Dynamic_Array:
		// A container of a move-only element is itself move-only for the same
		// reason a record holding one is: the deep clone would have no hook to
		// call for the element it has to duplicate.
		return type_clone_disabled(c, info.element)
	case .Map:
		return type_clone_disabled(c, info.key) || type_clone_disabled(c, info.element)
	case .Struct:
		for field in info.fields {
			sym := symbol_of(c, field)
			if sym != nil && type_clone_disabled(c, sym.type) {
				return true
			}
		}
	}
	return false
}

// ------------------------------------------------- generated copy members --

// A user-defined record gets field-wise `try_clone`, `clone`, `move`, and
// `drop` by default, and `clone` is generated from `try_clone` — user code
// never replaces it independently (design.md). Both copy entry points are
// therefore real members with real emitted bodies, so `value.clone()`,
// generic code, and the catalogue's `Cloneable` find them exactly where a
// hand-written hook would be (m5a-plan step 3).
//
// The contribution is keyed on the name being looked up rather than running for
// every member query. `lifecycle_of` caches its answer, so asking before the
// subject's own `impl` block is declared would both freeze the wrong
// classification and install a generated hook beside the custom one.
ensure_lifecycle_members :: proc(k: ^Checker, type: Type_Id, name: Identifier_Id) {
	switch identifier_text(k.c, name) {
	case "try_clone", "clone":
	case:
		return
	}
	contribute_lifecycle_members(k, type)
}

// The recursion behind that. A generated body calls `try_clone` on every part
// whose own clone can fail, so those parts need their hook installed too — a
// fixed array's included, which is why this is not restricted to records even
// though only a record receives the `clone` entry point.
// Keyed on the underlying type, exactly as `lifecycle_of` is: a `distinct` name
// shares its underlying record's lifecycle, and `type_hook` resolves through the
// same step, so both halves agree on where one type's hooks live.
contribute_lifecycle_members :: proc(k: ^Checker, written: Type_Id) {
	type := type_underlying(k.c, written)
	info := type_of(k.c, type)
	if info == nil || info.descriptor || .Lifecycle in info.contributed {
		return
	}
	// Copyable owning built-ins such as `string`, dynamic arrays, and maps
	// satisfy `Cloneable` (design.md "standard interface catalogue"). That
	// interface names the `try_clone` slot, so those types need the member as
	// much as a record
	// does — the difference is only what its body lowers to, which
	// `emit_synth_try_clone` decides from `Lifecycle.intrinsic`.
	#partial switch info.kind {
	case .Struct, .Array:
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
	// entry point to contribute.
	if entry.clone_disabled || type_clone_disabled(k.c, type) {
		return
	}
	members := make([dynamic]Symbol_Id, 0, 2, k.c.semantic_allocator)
	// Always contribute the public fallible wrapper. With a custom `hook(copy)`
	// its emitted body forwards to that hook; otherwise it performs the generated
	// field-wise operation.
	append(&members, generated_hook(k, type, "try_clone", .Try_Clone, true))
	// design.md: `clone` is generated for a user record. A fixed array is reached
	// only as a part of one, and is not itself a record.
	if info.kind == .Struct {
		append(&members, generated_hook(k, type, "clone", .Clone, false))
	}
	add_members(k.c, type, members[:])

	for index in 0 ..< clone_part_count(k.c, type) {
		part := clone_part(k.c, type, index)
		if type_clone_is_fallible(k.c, part) {
			contribute_lifecycle_members(k, part)
		}
	}
}

// Both copy entry points for a built-in owning type. There is no field walk and
// no custom hook to respect: `string` retains a handle and a container calls its
// versioned helper, so the members exist to be found by name and by slot
// matching, and the emitter supplies the one body each of them has.
@(private = "file")
contribute_intrinsic_copy_members :: proc(k: ^Checker, type: Type_Id) {
	// `add_members` keeps the slice it is handed, so this has to outlive the call.
	members := make([]Symbol_Id, 2, k.c.semantic_allocator)
	members[0] = generated_hook(k, type, "try_clone", .Try_Clone, true)
	members[1] = generated_hook(k, type, "clone", .Clone, false)
	add_members(k.c, type, members)
}

// The parts a generated field-wise clone visits, in declaration order: a
// record's fields, or a fixed array's elements. `clone_part_count` and
// `clone_part` are the one pair every walk uses, so a struct and an array are
// never indexed by two different conventions.
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
// error; a generated one is fallible exactly when some part of it reaches one.
// This is what keeps a generated body a plain copy for the ordinary case
// instead of a chain of error branches that can never be taken.
type_clone_is_fallible :: proc(c: ^Compiler, type: Type_Id) -> bool {
	if type == INVALID_TYPE {
		return false
	}
	if lifecycle_of(c, type).custom_try_clone != INVALID_SYMBOL {
		return true
	}
	// A container's clone duplicates its storage, so it allocates and can fail
	// whatever its element is (m6b-plan decision "Element lifecycle").
	if lifecycle_of(c, type).container {
		return true
	}
	// A fixed array inherits its element's, so one part answers for every index.
	for index in 0 ..< clone_part_count(c, type) {
		if type_clone_is_fallible(c, clone_part(c, type, index)) {
			return true
		}
	}
	return false
}

@(private = "file")
generated_hook :: proc(k: ^Checker, type: Type_Id, name: string, kind: Synth_Kind, fallible: bool) -> Symbol_Id {
	results := fallible ? []Type_Id{type, TYPE_ALLOCATOR_ERROR} : []Type_Id{type}
	id := synth_proc(
		k.c, name, kind, type,
		[]Type_Id{type, TYPE_ALLOCATOR}, []Param_Mode{.Value, .Value}, results,
	)
	if sym := symbol_of(k.c, id); sym != nil {
		sym.has_receiver = true
		sym.receiver = .Value
		sym.param_defaults[1] = default_allocator_arg(k.c)
	}
	return id
}

// `clone(value)` and `try_clone(value)` are standard aliases for the generated
// receiver members (design.md "Standard customization procedures"). This
// resolves to the very member `value.clone()` would and rewrites the callee to
// name it — one emitted call, not two entry points that could drift.
//
// A user customizes copying with `hook(copy)`; there is deliberately no way to
// answer the alias with an unrelated free procedure.
check_clone_builtin :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident, expected: Type_Id) {
	check_standard_alias(k, v, ident, expected)
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
		require_hook_shape(k, sym, subject, "copy", "proc(self, allocator: Allocator) -> (T, Allocator_Error)", 2, 2, .Value)
	case .Convert:
		if sym.has_receiver || len(sym.params) != 1 || len(sym.results) != 1 || sym.results[0] != subject {
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
	if len(sym.params) != params || len(sym.results) != results {
		bad = true
	}
	if !bad && sym.params[0] != subject {
		bad = true
	}
	if !bad && name == "copy" {
		if sym.params[1] != TYPE_ALLOCATOR || sym.results[0] != subject || sym.results[1] != TYPE_ALLOCATOR_ERROR {
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

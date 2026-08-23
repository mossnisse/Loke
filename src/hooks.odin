// Lifecycle hooks and the managed-type classification (m5a-plan step 3).
//
// design.md "Lifecycle hooks and resource types": user records receive
// field-wise `try_clone`, `clone`, `move`, and `drop` behavior by default, and
// an `impl` block may replace the canonical `try_clone` or `drop` for a type
// that owns a resource. The signatures are fixed by the type, so they are
// validated rather than inferred:
//
//   drop      :: proc(self: inout T)
//   try_clone :: proc(self, allocator: Allocator) -> (T, Allocator_Error)
//
// `try_clone :: ---;` disables both copy entry points, making the type
// move-only. `clone` is generated from `try_clone` and is never written by hand.
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
	// `try_clone :: ---`: neither the fallible nor the policy-following entry
	// point exists, so the type is move-only.
	clone_disabled:   bool,
	// design.md: a record is managed when it has a custom `drop`, a custom or
	// disabled `try_clone`, or a recursively managed field. A managed value is
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

// design.md: "`drop` is `proc(self: inout T)`."
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
		// string is an owner exactly like a record with a written `drop`.
		entry.container = info.kind == .Dynamic_Array || info.kind == .Map
		entry.provider = info.provider
		entry.intrinsic = info.kind == .String || entry.container || entry.provider
		entry.clone_disabled ||= entry.provider
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
		switch identifier_text(c, sym.name) {
		case "drop":
			entry.custom_drop = member
		case "try_clone":
			if sym.decl != nil && len(sym.decl.values) == 1 && sym.decl.values[0] == nil {
				entry.clone_disabled = true
			} else {
				entry.custom_try_clone = member
			}
		}
	}
}

// design.md: "Fixed arrays inherit their element lifecycle." A struct is managed
// when any field is.
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

// design.md: a move-only type — `try_clone :: ---` — has neither copy entry
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

// design.md: "User-defined records receive field-wise `try_clone`, `clone`,
// `move`, and `drop` behavior by default", and "`clone` is generated from
// `try_clone`; user code does not replace it independently." Both copy entry
// points are therefore real members with real emitted bodies, so `value.clone()`,
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
	// design.md "standard interface catalogue": "copyable owning built-ins such as
	// `string`, dynamic arrays, maps ... satisfy `Cloneable`". That interface names
	// the `try_clone` slot, so those types need the member as much as a record
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
	// `try_clone :: ---` disables both entry points, and a record holding a
	// move-only part has no hook to call for it.
	if entry.clone_disabled || type_clone_disabled(k.c, type) {
		return
	}
	members := make([dynamic]Symbol_Id, 0, 2, k.c.semantic_allocator)
	if entry.custom_try_clone == INVALID_SYMBOL {
		append(&members, generated_hook(k, type, "try_clone", .Try_Clone, true))
	}
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

// Can cloning this type actually fail? Only a custom `try_clone` returns a real
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

// design.md "Standard customization procedures": `clone(value)` and
// `try_clone(value)` "are written as free calls ... which is canonical and
// always available", and "the compiler contributes free `clone` and `try_clone`
// overloads forwarding to the fixed hooks". So this resolves to the very member
// `value.clone()` would, and rewrites the callee to name it — a free call and a
// method call on one type are one emitted call, not two entry points that could
// drift.
//
// A user customizes copying by replacing `T.try_clone`; there is deliberately no
// way to answer this call with an unrelated free procedure.
check_clone_builtin :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident, builtin: Builtin_Kind) {
	name := builtin == .Clone ? "clone" : "try_clone"
	v.value_category = .Value
	if len(v.args) < 1 || len(v.args) > 2 {
		errorf(k.c, v.span, "L0322", "`%s` takes 1 or 2 arguments, found %d", name, len(v.args))
		v.type = INVALID_TYPE
		return
	}
	for arg in v.args {
		if arg.mode != .Value {
			// The subject is borrowed and the allocator is an ordinary value, so
			// neither slot has a mode to write.
			errorf(k.c, arg.span, "L0322", "`%s` takes plain arguments", name)
			v.type = INVALID_TYPE
			return
		}
	}
	subject := check_single_expr(k, v.args[0].value)
	if subject == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}

	// The same lookup a member call performs, so a disabled `try_clone :: ---`
	// reports the type as move-only here too rather than silently missing.
	ensure_lifecycle_members(k, subject, intern_identifier(k.c, name))
	chosen := INVALID_SYMBOL
	if info := underlying_info(k.c, subject); info != nil {
		chosen = member_named_in(k.c, info.members, intern_identifier(k.c, name))
	}
	sym := symbol_of(k.c, chosen)
	if sym == nil {
		errorf(
			k.c,
			expr_span(v.args[0].value),
			"L0363",
			"`%s` has no `%s`: it owns nothing to copy, or its `try_clone` is disabled",
			type_name(k.c, subject),
			name,
		)
		v.type = INVALID_TYPE
		return
	}

	// An omitted allocator is the hook's own default, so `clone(x)` and
	// `x.clone()` load the program provider at the same point.
	allocator := default_allocator_arg(k.c)
	if len(v.args) == 2 {
		supplied := check_single_expr(k, v.args[1].value, TYPE_ALLOCATOR)
		if supplied == INVALID_TYPE {
			v.type = INVALID_TYPE
			return
		}
		if supplied != TYPE_ALLOCATOR {
			errorf(
				k.c,
				expr_span(v.args[1].value),
				"L0310",
				"`%s`'s second argument is an `Allocator`, found `%s`",
				name,
				type_name(k.c, supplied),
			)
			v.type = INVALID_TYPE
			return
		}
		allocator = v.args[1].value
	}

	bound := make([]Expr, 2, k.c.semantic_allocator)
	bound[0] = v.args[0].value
	bound[1] = allocator
	v.bound = bound
	annotate_chosen_callee(k, v, chosen)
	v.resolution = Resolution{kind = .Call, symbol = chosen, chosen_overload = chosen}
	v.type = sym.results[0]
	// `try_clone` is `(T, Allocator_Error)`; `clone` applies the failure policy
	// and yields the value alone.
	if len(sym.results) > 1 {
		v.result_types = sym.results
	}
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

// `try_clone :: ---;` inside an `impl` block. design.md: "No signature is
// written, because the signature of a lifecycle hook is fixed by the type." It
// is the one `---` that needs no declared type, and it disables both copy entry
// points rather than leaving storage uninitialised.
disabled_lifecycle_hook :: proc(k: ^Checker, d: ^Decl, index: int) -> bool {
	if d.kind != .Const || !d.top_level || index >= len(d.names) {
		return false
	}
	if k.impl_type == INVALID_TYPE {
		return false
	}
	if d.names[index].text != "try_clone" {
		return false
	}
	// Only the declaring package may disable it; an extension block is rejected by
	// `validate_lifecycle_hook` with its own diagnostic.
	return true
}

// The fixed signatures. Called once per `impl` member, after its signature is
// resolved, so the shape is checked where it is written rather than at a use.
validate_lifecycle_hook :: proc(k: ^Checker, item: ^Item_Impl, d: ^Decl, sym: ^Symbol, symbol_id: Symbol_Id) {
	name := identifier_text(k.c, sym.name)
	if name != "drop" && name != "try_clone" && name != "clone" {
		return
	}
	subject := item.subject

	// design.md: a lifecycle hook replaces behavior the compiler generates for
	// the type, so it belongs with the type's own package.
	if item.kind == .Extend {
		errorf(
			k.c,
			sym.span,
			"L0486",
			"a lifecycle hook belongs with the package that declares `%s`; an extension block cannot add `%s`",
			type_name(k.c, subject),
			name,
		)
		return
	}
	if name == "clone" {
		errorf(
			k.c,
			sym.span,
			"L0487",
			"`clone` is generated from `try_clone` and cannot be written; customise `try_clone` instead",
		)
		return
	}
	// `try_clone :: ---` writes no signature, because the signature of a
	// lifecycle hook is fixed by the type.
	if d != nil && len(d.values) == 1 && d.values[0] == nil {
		return
	}
	if sym.kind != .Proc {
		errorf(k.c, sym.span, "L0488", "`%s` must be a procedure with its fixed lifecycle signature", name)
		return
	}
	if name == "drop" {
		require_hook_shape(k, sym, subject, "drop", "proc(self: inout T)", 1, 0, .Inout)
		return
	}
	require_hook_shape(
		k, sym, subject, "try_clone",
		"proc(self, allocator: Allocator) -> (T, Allocator_Error)",
		2, 2, .Value,
	)
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
	if !bad && name == "try_clone" {
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
	if name == "try_clone" && len(sym.param_defaults) > 1 {
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

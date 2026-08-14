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
// M5a narrowing: design.md gives the canonical hook a default argument of
// `mem.default_allocator()`, but `core:mem` is not nameable until M6. A custom
// hook is therefore written with a plain `allocator: Allocator` parameter and
// the compiler supplies the default at every call site that omits it
// (m5a-plan step 3). Writing a default on a lifecycle hook is rejected.
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
	state:            Size_State,
}

// design.md: "`drop` is `proc(self: inout T)`."
lifecycle_of :: proc(k: ^Checker, type: Type_Id) -> ^Lifecycle {
	under := type_underlying(k.c, type)
	if existing, found := k.c.lifecycles[under]; found {
		if existing.state != .Checking {
			return existing
		}
		// A record reached through its own field: the cycle is broken by treating
		// the in-progress answer as final, which the finite-size check has already
		// rejected if it were a real by-value cycle.
		return existing
	}
	entry := new(Lifecycle, k.c.semantic_allocator)
	entry.custom_drop = INVALID_SYMBOL
	entry.custom_try_clone = INVALID_SYMBOL
	entry.state = .Checking
	k.c.lifecycles[under] = entry

	info := type_of(k.c, under)
	if info != nil {
		collect_hooks(k, under, info, entry)
		entry.managed =
			entry.custom_drop != INVALID_SYMBOL ||
			entry.custom_try_clone != INVALID_SYMBOL ||
			entry.clone_disabled ||
			has_managed_part(k, under, info)
	}
	entry.state = .Finite
	return entry
}

@(private = "file")
collect_hooks :: proc(k: ^Checker, type: Type_Id, info: ^Type_Info, entry: ^Lifecycle) {
	// Inherent members only: a lifecycle hook belongs with the type's own
	// package, so an `extend` block never contributes one.
	for member in info.members {
		sym := symbol_of(k.c, member)
		if sym == nil {
			continue
		}
		switch identifier_text(k.c, sym.name) {
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
has_managed_part :: proc(k: ^Checker, type: Type_Id, info: ^Type_Info) -> bool {
	#partial switch info.kind {
	case .Array:
		return type_is_managed(k, info.element)
	case .Struct:
		for field in info.fields {
			sym := symbol_of(k.c, field)
			if sym != nil && type_is_managed(k, sym.type) {
				return true
			}
		}
	case .Union:
		for variant in info.variants {
			if type_is_managed(k, variant) {
				return true
			}
		}
	}
	return false
}

type_is_managed :: proc(k: ^Checker, type: Type_Id) -> bool {
	if type == INVALID_TYPE {
		return false
	}
	return lifecycle_of(k, type).managed
}

// design.md: a move-only type — `try_clone :: ---` — has neither copy entry
// point, so assignment, copy initialization, and a borrowed-parameter return all
// have to say so rather than silently producing a shallow copy.
type_clone_disabled :: proc(k: ^Checker, type: Type_Id) -> bool {
	if type == INVALID_TYPE {
		return false
	}
	if lifecycle_of(k, type).clone_disabled {
		return true
	}
	// A record containing a move-only part is itself move-only: the generated
	// field-wise clone would have no hook to call for that field.
	info := type_of(k.c, type_underlying(k.c, type))
	if info == nil {
		return false
	}
	#partial switch info.kind {
	case .Array:
		return type_clone_disabled(k, info.element)
	case .Struct:
		for field in info.fields {
			sym := symbol_of(k.c, field)
			if sym != nil && type_clone_disabled(k, sym.type) {
				return true
			}
		}
	}
	return false
}

// ------------------------------------------------------- allocation roots --

// Does this binding carry the fresh-allocation-base fact `free` requires?
symbol_is_allocation_root :: proc(k: ^Checker, id: Symbol_Id) -> bool {
	sym := symbol_of(k.c, id)
	return sym != nil && sym.allocation_root
}

// An initialiser that hands its binding a fresh allocation base: a direct
// `new`/`new_clone` call, or a chain of explicit moves from one. M5b widens this
// to full root propagation (m5a-plan step 3/4).
initializer_is_allocation_root :: proc(k: ^Checker, value: Expr) -> bool {
	#partial switch v in value {
	case ^Expr_Call:
		sym := symbol_of(k.c, v.resolution.symbol)
		return sym != nil && (sym.builtin == .New || sym.builtin == .New_Clone)
	case ^Expr_Move:
		// `move` transfers the base rather than copying it, so the fact follows.
		if ident, is_ident := v.value.(^Expr_Ident); is_ident {
			return symbol_is_allocation_root(k, ident.symbol)
		}
	}
	return false
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
	// Only the declaring package may disable it; `extend` is rejected by
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
			"a lifecycle hook belongs with the package that declares `%s`; `extend` cannot add `%s`",
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
	// M5a narrowing: the design's default argument names `mem.default_allocator()`,
	// which is not spellable until M6, so the compiler supplies it instead.
	if name == "try_clone" && len(sym.param_defaults) > 1 && sym.param_defaults[1] != nil {
		errorf(
			k.c,
			expr_span(sym.param_defaults[1]),
			"L0489",
			"a lifecycle hook takes no written default; the compiler supplies the allocator until `core:mem` is nameable in M6",
		)
	}
}

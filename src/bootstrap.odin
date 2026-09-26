// The `base:runtime` bootstrap (design.md "Typed fallibility"). `Unit`, `Option`,
// `Result`, the shared handles, and the yield markers are ordinary runtime source
// bound into the universe, so the compiler and a program name one declaration
// each rather than two that print the same.
package lokec


@(private = "file")
Bootstrap_Kind :: enum {
	Type,
	Proc_Group,
}

// Called once, right after `base:runtime` has been prepared. Every name is looked
// up so each missing one is reported, and whatever was found is still bound.
bind_runtime_bootstrap :: proc(k: ^Checker, pkg: ^Package) {
	c := k.c
	if c.bootstrap_ready || pkg == nil || pkg.scope == nil || pkg.scope.parent == nil || pkg.key != STD_RUNTIME {
		return
	}
	c.bootstrap_ready = true
	universe := pkg.scope.parent

	unit := bootstrap_symbol(k, pkg, "Unit", .Type)
	c.option_symbol = bootstrap_symbol(k, pkg, "Option", .Type)
	c.result_symbol = bootstrap_symbol(k, pkg, "Result", .Type)
	c.shared_symbol = bootstrap_symbol(k, pkg, "Shared", .Type)
	c.weak_symbol = bootstrap_symbol(k, pkg, "Weak", .Type)
	c.shared_construct_symbol = bootstrap_symbol(k, pkg, "shared_construct", .Proc_Group)
	try_shared := bootstrap_symbol(k, pkg, "try_shared", .Proc_Group)
	if sym := symbol_of(c, unit); sym != nil {
		c.unit_type = sym.type
	}

	bind_universe_name(c, universe, "Unit", unit)
	bind_universe_name(c, universe, "Option", c.option_symbol)
	bind_universe_name(c, universe, "Result", c.result_symbol)
	// `shared` names the type; a call `shared(value)` is resolved to
	// `shared_construct` at the call.
	bind_universe_name(c, universe, "shared", c.shared_symbol)
	bind_universe_name(c, universe, "weak", c.weak_symbol)
	bind_universe_name(c, universe, "try_shared", try_shared)

	c.alloc_result_type = result_type(k, c.unit_type, TYPE_ALLOCATOR_ERROR)
}

@(private = "file")
bootstrap_symbol :: proc(k: ^Checker, pkg: ^Package, name: string, want: Bootstrap_Kind) -> Symbol_Id {
	id := pkg.scope.names[intern_identifier(k.c, name)] or_else INVALID_SYMBOL
	if sym := symbol_of(k.c, id); sym != nil {
		switch want {
		case .Type:
			if sym.kind == .Type {
				return id
			}
		case .Proc_Group:
			// A group's symbol kind is settled only when its signature resolves.
			if sym.decl != nil && len(sym.decl.values) == 1 {
				if _, is_group := sym.decl.values[0].(^Expr_Proc_Group); is_group {
					return id
				}
			}
		}
	}
	errorf(
		k.c, no_span(), "L0704",
		"`base:runtime` must declare `%s` as a %s; the compiler cannot bootstrap without it",
		name, want == .Type ? "type" : "procedure group",
	)
	return INVALID_SYMBOL
}

@(private = "file")
bind_universe_name :: proc(c: ^Compiler, universe: ^Scope, name: string, id: Symbol_Id) {
	if id != INVALID_SYMBOL {
		universe.names[intern_identifier(c, name)] = id
	}
}

// `Option(T)`, through the one generic instance cache.
option_type :: proc(k: ^Checker, payload: Type_Id, span := Span{}) -> Type_Id {
	if k.c.option_symbol == INVALID_SYMBOL || payload == INVALID_TYPE {
		return INVALID_TYPE
	}
	args := [1]Type_Id{payload}
	return instantiate_record_types(k, k.c.option_symbol, args[:], span)
}

// `Result(T, E)`.
result_type :: proc(k: ^Checker, payload, error: Type_Id, span := Span{}) -> Type_Id {
	if k.c.result_symbol == INVALID_SYMBOL || payload == INVALID_TYPE || error == INVALID_TYPE {
		return INVALID_TYPE
	}
	args := [2]Type_Id{payload, error}
	return instantiate_record_types(k, k.c.result_symbol, args[:], span)
}

// Is this an instance of `shared(T)` or `weak(T)`? design.md "Shared ownership"
// gives both a `nil` zero and rejects a `via` declaration of either.
type_is_shared_handle :: proc(c: ^Compiler, id: Type_Id) -> bool {
	if c.shared_symbol == INVALID_SYMBOL {
		return false
	}
	info := type_of(c, type_underlying(c, id))
	if info == nil || info.instance_of == INVALID_SYMBOL {
		return false
	}
	return info.instance_of == c.shared_symbol || info.instance_of == c.weak_symbol
}

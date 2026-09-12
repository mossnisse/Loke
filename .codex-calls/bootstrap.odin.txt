// The `base:runtime` bootstrap.
//
// design.md "Typed fallibility": `Unit`, `Option`, and `Result` are ordinary
// source declarations, not compiler-owned types. Built-ins, container members,
// generated hooks, and iteration all instantiate *those* declarations, so a
// program and the compiler can't end up with two `Option`s that print the
// same and compare unequal.
//
// `base:runtime` is therefore loaded before the root package and checked
// first, and the three symbols are bound into the universe once their
// signatures are resolved. Failure to find them is diagnosed here rather than
// papered over with a synthesized substitute.
package lokec

// Called once, right after `base:runtime` has been prepared. Binds the three
// declarations into the universe scope so every package names them unqualified.
bind_runtime_bootstrap :: proc(k: ^Checker, pkg: ^Package) {
	c := k.c
	if c.bootstrap_ready || pkg == nil || pkg.scope == nil || pkg.key != STD_RUNTIME {
		return
	}
	universe := pkg.scope.parent
	if universe == nil {
		return
	}
	c.bootstrap_ready = true

	unit := bootstrap_symbol(k, pkg, "Unit")
	option := bootstrap_symbol(k, pkg, "Option")
	result := bootstrap_symbol(k, pkg, "Result")
	if unit == INVALID_SYMBOL || option == INVALID_SYMBOL || result == INVALID_SYMBOL {
		return
	}
	// design.md "Shared ownership": `shared(T)`, `weak(T)`, and `try_shared` are
	// written with no import in sight, so they are universe names over the same
	// two declarations every program would otherwise have to spell twice. The
	// construction procedure is bound separately because the *name* `shared` has
	// to mean the type in `shared(Node)` and the constructor in `shared(node)`;
	// which one a call means is settled at the call.
	shared_type := bootstrap_symbol(k, pkg, "Shared")
	weak_type := bootstrap_symbol(k, pkg, "Weak")
	shared_new := bootstrap_symbol(k, pkg, "shared_construct")
	try_shared := bootstrap_symbol(k, pkg, "try_shared")
	if shared_type == INVALID_SYMBOL || weak_type == INVALID_SYMBOL ||
	   shared_new == INVALID_SYMBOL || try_shared == INVALID_SYMBOL {
		return
	}
	c.shared_symbol = shared_type
	c.weak_symbol = weak_type
	c.shared_construct_symbol = shared_new
	universe.names[intern_identifier(c, "shared")] = shared_type
	universe.names[intern_identifier(c, "weak")] = weak_type
	universe.names[intern_identifier(c, "try_shared")] = try_shared
	if symbol := symbol_of(c, unit); symbol != nil {
		c.unit_type = symbol.type
	}
	c.option_symbol = option
	c.result_symbol = result

	universe.names[intern_identifier(c, "Unit")] = unit
	universe.names[intern_identifier(c, "Option")] = option
	universe.names[intern_identifier(c, "Result")] = result

	// The instance compiler-owned signatures need before any checker exists to ask.
	c.alloc_result_type = result_type(k, c.unit_type, TYPE_ALLOCATOR_ERROR)
}

@(private = "file")
bootstrap_symbol :: proc(k: ^Checker, pkg: ^Package, name: string) -> Symbol_Id {
	id, found := pkg.scope.names[intern_identifier(k.c, name)]
	if !found || id == INVALID_SYMBOL {
		errorf(
			k.c, no_span(), "L0434",
			"`base:runtime` does not declare `%s`; the compiler cannot bootstrap without it", name,
		)
		return INVALID_SYMBOL
	}
	return id
}

// design.md "Typed fallibility": `Option(T)`. One helper so every producer of
// absence reaches the same generic instance cache.
option_type :: proc(k: ^Checker, payload: Type_Id, span := Span{}) -> Type_Id {
	if k.c.option_symbol == INVALID_SYMBOL || payload == INVALID_TYPE {
		return INVALID_TYPE
	}
	args := [1]Type_Id{payload}
	return instantiate_record_types(k, k.c.option_symbol, args[:], span)
}

// design.md "Typed fallibility": `Result(T, E)`.
result_type :: proc(k: ^Checker, payload, error: Type_Id, span := Span{}) -> Type_Id {
	if k.c.result_symbol == INVALID_SYMBOL || payload == INVALID_TYPE || error == INVALID_TYPE {
		return INVALID_TYPE
	}
	args := [2]Type_Id{payload, error}
	return instantiate_record_types(k, k.c.result_symbol, args[:], span)
}

// The success type of a fallible operation that produces no value.
unit_type :: proc(c: ^Compiler) -> Type_Id {
	return c.unit_type
}

// design.md "Shared ownership": four things about `shared(T)` and `weak(T)` are
// the language's rather than the library's. Recognising an instance is what the
// first two need — `nil` is the zero value and compares to it, and a `via`
// declaration is rejected because the control block already stores its
// allocator.
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

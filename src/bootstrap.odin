// The `base:runtime` bootstrap (design.md "Typed fallibility"). `Unit`, `Option`,
// `Result`, `Status`, the shared handles and their constructors are ordinary
// runtime source bound into the universe, so the compiler and a program name one
// declaration each rather than two that print the same.
package lokec

import "core:slice"


@(private = "file")
Bootstrap_Kind :: enum {
	Type,
	// A type, or a parametric alias of one: `Status :: Result(Unit, $E)`.
	Type_Or_Alias,
	Proc_Group,
}

// Called for every package, and acts once, when `base:runtime`'s names exist.
// Every name is looked up so each missing one is reported, and whatever was found is still bound.
bind_runtime_bootstrap :: proc(k: ^Checker, pkg: ^Package) {
	c := k.c
	if c.bootstrap_ready || pkg.key != STD_RUNTIME {
		return
	}
	c.bootstrap_ready = true

	unit := bootstrap_symbol(k, pkg, "Unit", .Type)
	c.option_symbol = bootstrap_symbol(k, pkg, "Option", .Type)
	c.result_symbol = bootstrap_symbol(k, pkg, "Result", .Type)
	bootstrap_symbol(k, pkg, "Status", .Type_Or_Alias)
	// design.md "Shared ownership".
	c.shared_symbol = bootstrap_symbol(k, pkg, "Shared", .Type)
	c.weak_symbol = bootstrap_symbol(k, pkg, "Weak", .Type)
	c.shared_construct_symbol = bootstrap_symbol(k, pkg, "shared", .Proc_Group)
	c.try_shared_symbol = bootstrap_symbol(k, pkg, "try_shared", .Proc_Group)
	if sym := symbol_of(c, unit); sym != nil {
		c.unit_type = sym.type
	}

	// design.md "Container insertion": `Status(Allocator_Error)`.
	c.alloc_result_type = result_type(k, c.unit_type, TYPE_ALLOCATOR_ERROR)
}

// Binds the name into the universe when `base:runtime` declares it as wanted.
@(private = "file")
bootstrap_symbol :: proc(k: ^Checker, pkg: ^Package, name: string, want: Bootstrap_Kind) -> Symbol_Id {
	name_id := intern_identifier(k.c, name)
	id := pkg.scope.names[name_id]
	found := false
	if sym := symbol_of(k.c, id); sym != nil {
		switch want {
		case .Type:
			found = sym.kind == .Type
		case .Type_Or_Alias:
			found = sym.kind == .Type || declaration_generic_kind(sym.decl) == .Alias
		case .Proc_Group:
			// A group's symbol kind is settled only when its signature resolves.
			if sym.decl != nil && len(sym.decl.values) == 1 {
				_, found = sym.decl.values[0].(^Expr_Proc_Group)
			}
		}
	}
	if found {
		k.c.universe.names[name_id] = id
		return id
	}
	errorf(
		k.c, no_span(), "L0704",
		"`base:runtime` must declare `%s` as a %s; the compiler cannot bootstrap without it",
		name, want == .Proc_Group ? "procedure group" : "type",
	)
	return INVALID_SYMBOL
}

// `Option(T)`, through the one generic instance cache.
option_type :: proc(k: ^Checker, payload: Type_Id, span := Span{}) -> Type_Id {
	if payload == INVALID_TYPE {
		return INVALID_TYPE
	}
	return instantiate_record_types(k, k.c.option_symbol, []Type_Id{payload}, span)
}

result_type :: proc(k: ^Checker, payload, error: Type_Id) -> Type_Id {
	if payload == INVALID_TYPE || error == INVALID_TYPE {
		return INVALID_TYPE
	}
	return instantiate_record_types(k, k.c.result_symbol, []Type_Id{payload, error}, Span{})
}

// An instance of `Shared(T)` or `Weak(T)`? design.md "Shared ownership" rejects
// `via` on either.
type_is_shared_handle :: proc(c: ^Compiler, id: Type_Id) -> bool {
	info := type_of(c, type_underlying(c, id))
	return info != nil && info.instance_of != INVALID_SYMBOL &&
	       (info.instance_of == c.shared_symbol || info.instance_of == c.weak_symbol)
}

// The payload type of a `Shared(T)` or `Weak(T)`, or INVALID_TYPE. The record
// holds its block as a `rawptr`, so the compiler supplies what the handle
// carries: its payload's borrows (design.md "Values that contain borrows").
shared_payload_type :: proc(c: ^Compiler, id: Type_Id) -> Type_Id {
	if !type_is_shared_handle(c, id) {
		return INVALID_TYPE
	}
	info := type_of(c, type_underlying(c, id))
	if len(info.instance_args) != 1 || !info.instance_args[0].is_type {
		return INVALID_TYPE
	}
	return info.instance_args[0].type
}

// `shared(value)` or `try_shared(value)`: the payload it takes, and whether its
// result is a `Result`. Nil for any other call.
shared_constructor_payload :: proc(c: ^Compiler, v: ^Expr_Call) -> (payload: Expr, fallible: bool) {
	chosen := symbol_of(c, v.resolution.chosen_overload)
	if chosen == nil || len(v.bound) == 0 {
		return nil, false
	}
	template := chosen.instance_of != INVALID_SYMBOL ? chosen.instance_of : v.resolution.chosen_overload
	for group, index in ([2]Symbol_Id{c.shared_construct_symbol, c.try_shared_symbol}) {
		if members := symbol_of(c, group); members != nil && slice.contains(members.members, template) {
			return v.bound[0], index == 1
		}
	}
	return nil, false
}

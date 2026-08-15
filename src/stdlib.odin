// Compiler-contributed members of the bundled standard packages (m6a-plan step
// 2, decision "Compiler-owned names").
//
// `Allocator`, `Allocator_Error`, `meta.Field` and `meta.Enum_Value` already
// have one identity apiece — the universe's, and the descriptor types M4b
// created. Making them nameable through `core:mem`, `base:runtime` and
// `base:meta` must therefore *bind* those identities rather than declare new
// ones: a second nominal type would silently break every M5 provenance fact and
// every lifecycle signature written against the unqualified spelling.
//
// Everything a package can express in Loke stays in its `.loke` files. Only what
// the compiler already owns is contributed here.
package lokec

// The import paths whose members the compiler contributes to. A package reached
// by any other path is an ordinary user package, even if its directory is the
// bundled one.
STD_RUNTIME :: "base:runtime"
STD_META :: "base:meta"
STD_MEM :: "core:mem"

// Called once per package, right after its scope exists and before any of its
// own declarations are collected, so a source declaration colliding with a
// contributed name is reported as the ordinary redeclaration it is.
contribute_standard_members :: proc(c: ^Compiler, pkg: ^Package) {
	if pkg == nil || pkg.scope == nil || pkg.contributed {
		return
	}
	pkg.contributed = true
	switch pkg.key {
	case STD_RUNTIME, STD_MEM:
		// design.md "Allocators": both packages name the allocator surface, and
		// design.md's own text spells it unqualified in every lifecycle signature.
		// One `Type_Id` under three spellings, never three types.
		contribute_type(c, pkg, "Allocator", TYPE_ALLOCATOR)
		contribute_type(c, pkg, "Allocator_Error", TYPE_ALLOCATOR_ERROR)
		if pkg.key == STD_MEM {
			// design.md: an `Allocator` "is obtained by the ordinary runtime default
			// expression `mem.default_allocator()`". This is the *same* symbol the
			// generated default argument of a lifecycle hook names, so an omitted
			// allocator and a written `mem.default_allocator()` are one call through
			// one provider.
			contribute_symbol(c, pkg, "default_allocator", c.default_allocator_symbol)
		}
	case STD_META:
		// The compile-time reflection descriptors M4b already owns. They remain
		// compile-time-only types: naming them does not make them storable.
		contribute_type(c, pkg, "Field", meta_field_type(c))
		contribute_type(c, pkg, "Enum_Value", meta_enum_value_type(c))
	}
}

@(private = "file")
contribute_type :: proc(c: ^Compiler, pkg: ^Package, name: string, type: Type_Id) {
	contribute_symbol(c, pkg, name, new_symbol(c, Symbol {
		name   = intern_identifier(c, name),
		span   = no_span(),
		kind   = .Type,
		type   = type,
		public = true,
	}))
}

// Binds an existing symbol into the package scope. A contributed symbol is
// reachable through `pkg.name`, so it has to be public; the universe entries it
// aliases are never reached that way, which is why marking them here is safe.
@(private = "file")
contribute_symbol :: proc(c: ^Compiler, pkg: ^Package, name: string, symbol_id: Symbol_Id) {
	if symbol_id == INVALID_SYMBOL {
		return
	}
	if symbol := symbol_of(c, symbol_id); symbol != nil {
		symbol.public = true
	}
	pkg.scope.names[intern_identifier(c, name)] = symbol_id
}

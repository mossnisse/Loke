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
STD_UNSAFE :: "core:unsafe"
STD_FMT :: "core:fmt"
STD_STRINGS :: "core:strings"

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
		// The `LOKE_*` enum types are intentionally not bound into `base:runtime`:
		// doing it eagerly would allocate them for every importer and shift type
		// numbering. Nothing in M7 needs `runtime.Os` by name; a later milestone
		// that does can bind it lazily. (m7-plan step 1)
		if pkg.key == STD_MEM {
			// An `Allocator` is obtained by the ordinary runtime default expression
			// `mem.default_allocator()` (design.md). This is the *same* symbol the
			// generated default argument of a public copy operation names, so an omitted
			// allocator and a written `mem.default_allocator()` are one call through
			// one provider.
			contribute_symbol(c, pkg, "default_allocator", c.default_allocator_symbol)
			// There is no ambient temporary allocator; code creates a `mem.Scratch`
			// or `mem.Arena` owner and passes its allocator explicitly (design.md
			// "Allocators"). Both are compiler-owned because the region
			// lattice has to recognise them, not merely call them.
			contribute_type(c, pkg, "Arena", arena_type(c))
			contribute_type(c, pkg, "Scratch", scratch_type(c))
			contribute_symbol(c, pkg, "try_arena", provider_try_proc(c, arena_type(c), "try_arena"))
			contribute_symbol(c, pkg, "try_scratch", provider_try_proc(c, scratch_type(c), "try_scratch"))
		}
	case STD_UNSAFE:
		// These make the loss of bounds and borrow capability visible at the call
		// site (design.md "unsafe.raw_data procedure"), which is the whole reason
		// they are spelled `unsafe.` rather than being implicit conversions.
		contribute_builtin(c, pkg, "raw_data", .Unsafe_Raw_Data)
		contribute_builtin(c, pkg, "string_view", .Unsafe_String_View)
		contribute_builtin(c, pkg, "cstring_view", .Unsafe_C_String_View)
	case STD_FMT:
		// design.md "String format printing": the library owns the protocol, the
		// writer, the options, and the `print` family. What the compiler owns is
		// the process sinks and the erased per-`typeid` dispatch — the one thing a
		// Loke procedure cannot express, because an `any_view` carries only a
		// pointer and a `typeid`.
		//
		// These are package-private: `core:fmt`'s own source names them
		// unqualified, and nothing outside it should reach the dispatch table.
		contribute_builtin(c, pkg, "stdout_writer", .Fmt_Stdout_Writer, public = false)
		contribute_builtin(c, pkg, "stderr_writer", .Fmt_Stderr_Writer, public = false)
		contribute_builtin(c, pkg, "write_bytes", .Fmt_Write_Bytes, public = false)
		contribute_builtin(c, pkg, "format_any", .Fmt_Format_Any, public = false)
		// `fmt.to_string(allocator, ...)` has to create a `string` in storage the
		// *caller* chose, which is the same primitive `core:strings` gets below.
		// It is contributed here rather than imported from there because
		// `core:fmt` is in almost every program: importing `core:strings` for one
		// call measured at 397 to 4923 lines of IR for hello-world, since the whole
		// imported package is emitted.
		contribute_builtin(c, pkg, "allocate_string", .Strings_Allocate, public = false)
	case STD_STRINGS:
		// The standard-library plan's one unexpressible bridge: a copy of
		// known-valid UTF-8 into string storage taken from a *supplied* allocator,
		// reporting failure instead of applying a policy. Every built-in text
		// operation allocates from the default provider, so nothing else in Loke
		// can answer `strings.copy(text, allocator)`.
		//
		// Package-private: `core:strings` wraps it in `copy`/`try_copy`, and the
		// rest of the library goes through those.
		contribute_builtin(c, pkg, "allocate_string", .Strings_Allocate, public = false)
	case STD_META:
		// The compile-time reflection descriptors M4b already owns. They remain
		// compile-time-only types: naming them does not make them storable.
		contribute_type(c, pkg, "Field", meta_field_type(c))
		contribute_type(c, pkg, "Enum_Value", meta_enum_value_type(c))
	}
}

@(private = "file")
contribute_builtin :: proc(c: ^Compiler, pkg: ^Package, name: string, kind: Builtin_Kind, public := true) {
	symbol_id := new_symbol(c, Symbol {
		name      = intern_identifier(c, name),
		span      = no_span(),
		kind      = .Builtin,
		builtin   = kind,
		type      = TYPE_VOID,
		proc_type = intern_proc_type(c, nil, nil, nil, nil, ""),
		public    = public,
	})
	pkg.scope.names[intern_identifier(c, name)] = symbol_id
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

// Compiler-contributed members of the bundled standard packages.
//
// `Allocator`, `Allocator_Error`, `meta.Field` and `meta.Enum_Value` already
// have one identity apiece — the universe's, and the descriptor types M4b
// created. Naming them through `core:mem`, `base:runtime` and `base:meta` must
// therefore *bind* those identities rather than declare new ones: a second
// nominal type would silently break every M5 provenance fact and every
// lifecycle signature written against the unqualified spelling.
//
// Everything a package can express in Loke stays in its `.loke` files; only
// what the compiler already owns is contributed here.
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
STD_LOG :: "core:log"
STD_SYNC :: "core:sync"
STD_SIMD :: "core:simd"

// Called once per package, right after its scope exists and before any of its
// own declarations are collected, so a source declaration colliding with a
// contributed name is reported as the ordinary redeclaration it is.
contribute_standard_members :: proc(k: ^Checker, pkg: ^Package) {
	c := k.c
	if pkg == nil || pkg.scope == nil || pkg.contributed {
		return
	}
	pkg.contributed = true
	switch pkg.key {
	case STD_RUNTIME, STD_MEM:
		// design.md "Allocators": both packages name the allocator surface, which
		// design.md's own text spells unqualified in every lifecycle signature.
		// One `Type_Id` under three spellings, never three types.
		contribute_type(c, pkg, "Allocator", TYPE_ALLOCATOR)
		contribute_type(c, pkg, "Allocator_Error", TYPE_ALLOCATOR_ERROR)
		// The `LOKE_*` enum types stay unbound from `base:runtime`: binding them
		// eagerly would allocate one per importer and shift type numbering.
		// Nothing in M7 needs `runtime.Os` by name; a later milestone that does
		// can bind it lazily. (m7-plan step 1)
		if pkg.key == STD_RUNTIME {
			// `shared(T)` allocates its control block, and `base:runtime` is below
			// `core:mem` in the dependency order, so it cannot import the package
			// that publishes the default provider. Contributed package-privately
			// for the same reason `allocate_string` is contributed twice: the
			// alternative is a package dependency that exists only to spell a name.
			contribute_builtin(c, pkg, "default_allocator", .Default_Allocator, public = false)
			// The atomic control block needs the intrinsics, and `core:sync` is a
			// package every program would then have to load — `shared` and `weak`
			// are universe names.
			contribute_atomic_intrinsics(c, pkg)
			// The control block travels as a `rawptr`, so releasing it is exactly
			// the unchecked release `core:unsafe` publishes. Same name, same
			// built-in, contributed here so `base:runtime` need not import it.
			contribute_builtin(c, pkg, "unsafe_free", .Unsafe_Free, public = false)
		}
		if pkg.key == STD_MEM {
			// An `Allocator` comes from the ordinary runtime default expression
			// `mem.default_allocator()` (design.md) — the same symbol a public copy
			// operation's generated default argument names, so an omitted allocator
			// and a written `mem.default_allocator()` are one call through one
			// provider.
			contribute_symbol(c, pkg, "default_allocator", c.default_allocator_symbol)
			// No ambient temporary allocator: code creates a `mem.Scratch` or
			// `mem.Arena` owner and passes its allocator explicitly (design.md
			// "Allocators"). Both are compiler-owned because the region lattice
			// has to recognise them, not merely call them.
			contribute_type(c, pkg, "Arena", arena_type(c))
			contribute_type(c, pkg, "Scratch", scratch_type(c))
			contribute_symbol(c, pkg, "try_arena", provider_try_proc(k, arena_type(c), "try_arena"))
			contribute_symbol(c, pkg, "try_scratch", provider_try_proc(k, scratch_type(c), "try_scratch"))
		}
	case STD_UNSAFE:
		// Makes the loss of bounds and borrow capability visible at the call site
		// (design.md "unsafe.raw_data procedure") — the whole reason these are
		// spelled `unsafe.` rather than implicit conversions.
		contribute_builtin(c, pkg, "raw_data", .Unsafe_Raw_Data)
		contribute_builtin(c, pkg, "string_view", .Unsafe_String_View)
		contribute_builtin(c, pkg, "cstring_view", .Unsafe_C_String_View)
		// Suppressing cleanup is the same kind of visible loss: the resource is
		// leaked, or escaped to whatever owns it now (design.md "Forgotten owners").
		contribute_builtin(c, pkg, "forget", .Unsafe_Forget)
		// Releasing storage the provenance analysis cannot follow: same visible
		// loss, and the only release `shared(T)` and any other handle over a
		// `rawptr` control block can perform.
		contribute_builtin(c, pkg, "free", .Unsafe_Free)
		// Reinterpreting bits is the third visible loss: nothing about the source
		// value says the destination representation is one its type ever admits,
		// so the spelling is `unsafe.transmute(T, value)` and the operation is
		// never injected into the universe (design.md "unsafe.transmute procedure").
		contribute_builtin(c, pkg, "transmute", .Unsafe_Transmute)
	case STD_FMT:
		// design.md "String format printing": the library owns the protocol,
		// writer, options, and `print` family. The compiler owns the process
		// sinks and the erased per-`typeid` dispatch — the one thing a Loke
		// procedure can't express, since an `any_view` carries only a pointer
		// and a `typeid`.
		//
		// Package-private: `core:fmt`'s own source names them unqualified, and
		// nothing outside it should reach the dispatch table.
		contribute_builtin(c, pkg, "stdout_writer", .Fmt_Stdout_Writer, public = false)
		contribute_builtin(c, pkg, "stderr_writer", .Fmt_Stderr_Writer, public = false)
		contribute_builtin(c, pkg, "write_bytes", .Fmt_Write_Bytes, public = false)
		contribute_builtin(c, pkg, "format_any", .Fmt_Format_Any, public = false)
		// `fmt.to_string(allocator, ...)` must create a `string` in storage the
		// *caller* chose — the same primitive `core:strings` gets below. It's
		// contributed here rather than imported from there because `core:fmt` is
		// in almost every program: importing `core:strings` for one call measured
		// 397 to 4923 lines of IR for hello-world, since the whole package gets
		// emitted.
		contribute_builtin(c, pkg, "allocate_string", .Strings_Allocate, public = false)
	case STD_STRINGS:
		// The one bridge the standard-library plan can't express in Loke itself:
		// copying known-valid UTF-8 into string storage from a *supplied*
		// allocator, reporting failure instead of applying a policy. Every
		// built-in text operation allocates from the default provider, so nothing
		// else in Loke can answer `strings.copy(text, allocator)`.
		//
		// Package-private: `core:strings` wraps it in `copy`/`try_copy`, and the
		// rest of the library goes through those.
		contribute_builtin(c, pkg, "allocate_string", .Strings_Allocate, public = false)
	case STD_SYNC:
		// design.md "Concurrency and the memory model": the ordering enum is
		// ordinary `base:runtime` source, and this *binds* that identity rather
		// than declaring a second one — the same rule `Allocator` follows under
		// three spellings. `sync.Memory_Order` and `runtime.Memory_Order` are one
		// type, so an ordering forwarded through a `$` parameter keeps meaning
		// what it meant.
		contribute_type(c, pkg, "Memory_Order", memory_order_type(k))
		// design.md "Concurrency and the memory model": `Atomic(T)` is a `core:sync`
		// wrapper over compiler atomic intrinsics, so the split is specified rather
		// than chosen. Each intrinsic requires a *constant* ordering, which is the
		// one thing an ordinary signature cannot ask for.
		//
		// Package-private: `core:sync` publishes them as `Atomic(T)`s methods and
		// as `fence`, and nothing outside it should reach an unwrapped one. The
		// fence intrinsic is `atomic_fence` rather than `fence` because a
		// contributed name and a source declaration share one package scope.
		contribute_atomic_intrinsics(c, pkg)
	case STD_SIMD:
		// design.md "SIMD vectors": `core:simd` "supplies what the operators cannot
		// spell. A lane index is constant, so none of these can be written as a
		// loop in ordinary Loke."
		//
		// The reduction's fold is a `$` parameter for the reason an atomic's
		// ordering is: it selects the instruction, so it has to survive the
		// library boundary as a constant.
		// `Fold` itself is an ordinary enum in this package's own source: only this
		// package can reach the intrinsic, so the constant is matched by member
		// name rather than by binding a second identity for one enum.
		contribute_builtin(c, pkg, "simd_cast", .Simd_Cast, public = false)
		contribute_builtin(c, pkg, "simd_select", .Simd_Select, public = false)
		contribute_builtin(c, pkg, "simd_reduce", .Simd_Reduce, public = false)
	case STD_LOG:
		// design.md "Compiled log level": `LOKE_LOG_LEVEL` and `core:log`'s own
		// `Level` must be one type, or a caller could not compare them. The enum
		// is allocated lazily, exactly as the other `LOKE_*` enums are.
		contribute_type(c, pkg, "Level", build_config_enum_type(c, .Log_Level))
	case STD_META:
		// The compile-time reflection descriptors M4b already owns. They remain
		// compile-time-only types: naming them does not make them storable.
		contribute_type(c, pkg, "Field", meta_field_type(c))
		contribute_type(c, pkg, "Enum_Value", meta_enum_value_type(c))
	}
}

// The ten atomic intrinsics, contributed package-privately wherever a bundled
// package is written over them.
@(private = "file")
contribute_atomic_intrinsics :: proc(c: ^Compiler, pkg: ^Package) {
	contribute_builtin(c, pkg, "atomic_load", .Atomic_Load, public = false)
	contribute_builtin(c, pkg, "atomic_store", .Atomic_Store, public = false)
	contribute_builtin(c, pkg, "atomic_exchange", .Atomic_Exchange, public = false)
	contribute_builtin(c, pkg, "atomic_compare_exchange", .Atomic_Compare_Exchange, public = false)
	contribute_builtin(c, pkg, "atomic_add", .Atomic_Add, public = false)
	contribute_builtin(c, pkg, "atomic_sub", .Atomic_Sub, public = false)
	contribute_builtin(c, pkg, "atomic_and", .Atomic_And, public = false)
	contribute_builtin(c, pkg, "atomic_or", .Atomic_Or, public = false)
	contribute_builtin(c, pkg, "atomic_xor", .Atomic_Xor, public = false)
	contribute_builtin(c, pkg, "atomic_fence", .Atomic_Fence, public = false)
}

@(private = "file")
contribute_builtin :: proc(c: ^Compiler, pkg: ^Package, name: string, kind: Builtin_Kind, public := true) {
	symbol_id := new_symbol(c, Symbol {
		name      = intern_identifier(c, name),
		span      = no_span(),
		kind      = .Builtin,
		builtin   = kind,
		type      = TYPE_VOID,
		proc_type = intern_proc_type(c, nil, nil, INVALID_TYPE, false, ""),
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

// Compiler-contributed members of the bundled standard packages.
//
// `Allocator`, `Allocator_Error`, `meta.Field` and `meta.Enum_Value` already
// have one identity apiece. Naming them through `core:mem`, `base:runtime` and
// `base:meta` must therefore *bind* those identities rather than declare new
// ones: a second nominal type would silently break every M5 provenance fact and
// every lifecycle signature written against the unqualified spelling.
//
// Everything a package can express in Loke stays in its `.loke` files; only what
// the compiler already owns is contributed here.
package lokec

// The import paths whose members the compiler contributes to, in the order the
// switch below handles them. A package reached by any other path is an ordinary
// user package, even if its directory is the bundled one.
STD_RUNTIME :: "base:runtime"
STD_MEM :: "core:mem"
STD_UNSAFE :: "core:unsafe"
STD_FMT :: "core:fmt"
STD_SLICE :: "core:slice"
STD_STRINGS :: "core:strings"
STD_SYNC :: "core:sync"
STD_SIMD :: "core:simd"
STD_LOG :: "core:log"
STD_META :: "base:meta"

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
	case STD_RUNTIME:
		contribute_allocator_surface(c, pkg)
		// The `LOKE_*` enum types stay unbound here: binding them eagerly would
		// allocate one per importer and shift type numbering.
		//
		// `shared(T)` allocates its control block, and `base:runtime` is below
		// `core:mem` in the dependency order, so it cannot import the package that
		// publishes the default provider. The control block then travels as a
		// `rawptr`, so releasing it is exactly the unchecked release `core:unsafe`
		// publishes. Both are contributed package-privately rather than through a
		// package dependency that would exist only to spell a name.
		contribute_builtin(c, pkg, "default_allocator", .Default_Allocator, public = false)
		contribute_builtin(c, pkg, "unsafe_free", .Unsafe_Free, public = false)
		// The payload is capacity inside that block, so it arrives and leaves the way
		// a container element does, without asking `T` for a zero.
		contribute_builtin(c, pkg, "unsafe_write", .Unsafe_Write, public = false)
		contribute_builtin(c, pkg, "unsafe_take", .Unsafe_Take, public = false)
		// The control block is atomic, and `core:sync` is a package every program
		// would then have to load — `shared` and `weak` are universe names.
		contribute_atomic_intrinsics(c, pkg)
	case STD_MEM:
		contribute_allocator_surface(c, pkg)
		// An `Allocator` comes from the ordinary runtime default expression
		// `mem.default_allocator()` (design.md "Allocators") — the same symbol a
		// public copy operation's generated default argument names, so an omitted
		// allocator and a written call are one call through one provider.
		contribute_symbol(c, pkg, "default_allocator", c.default_allocator_symbol)
		// No ambient temporary allocator: code creates a `mem.Scratch` or
		// `mem.Arena` owner and passes its allocator explicitly. Both are
		// compiler-owned because the region lattice has to recognise them, not
		// merely call them.
		contribute_type(c, pkg, "Arena", arena_type(c))
		contribute_type(c, pkg, "Scratch", scratch_type(c))
		contribute_symbol(c, pkg, "try_arena", provider_try_proc(k, arena_type(c), "try_arena"))
		contribute_symbol(c, pkg, "try_scratch", provider_try_proc(k, scratch_type(c), "try_scratch"))
	case STD_UNSAFE:
		// Every one of these makes a lost capability visible at the call site — the
		// whole reason they are spelled `unsafe.` rather than applied implicitly.
		// Bounds and borrow capability (design.md "unsafe.raw_data procedure"):
		contribute_builtin(c, pkg, "raw_data", .Unsafe_Raw_Data)
		contribute_builtin(c, pkg, "string_view", .Unsafe_String_View)
		contribute_builtin(c, pkg, "cstring_view", .Unsafe_C_String_View)
		// Cleanup, so the resource leaks or escapes (design.md "`unsafe.forget`"),
		// and the only release a handle over a `rawptr` control block can perform:
		contribute_builtin(c, pkg, "forget", .Unsafe_Forget)
		contribute_builtin(c, pkg, "free", .Unsafe_Free)
		// Knowing whether raw capacity holds a value, so the container author says
		// so (design.md "Uninitialized capacity"):
		contribute_builtin(c, pkg, "take", .Unsafe_Take)
		contribute_builtin(c, pkg, "write", .Unsafe_Write)
		// And the source type's claim about the destination representation
		// (design.md "`unsafe.transmute`"):
		contribute_builtin(c, pkg, "transmute", .Unsafe_Transmute)
	case STD_FMT:
		// design.md "String format printing": the library owns the protocol,
		// writer, options, and `print` family. The compiler owns the process sinks
		// and the erased per-`typeid` dispatch — the one thing a Loke procedure
		// can't express, since an `any_view` carries only a pointer and a `typeid`.
		// Package-private, because `core:fmt` names them unqualified and nothing
		// outside it should reach the dispatch table.
		contribute_builtin(c, pkg, "stdout_writer", .Fmt_Stdout_Writer, public = false)
		contribute_builtin(c, pkg, "stderr_writer", .Fmt_Stderr_Writer, public = false)
		contribute_builtin(c, pkg, "write_bytes", .Fmt_Write_Bytes, public = false)
		contribute_builtin(c, pkg, "format_any", .Fmt_Format_Any, public = false)
		// `fmt.to_string(allocator, ...)` needs the same primitive `core:strings`
		// gets below. Contributed twice rather than imported because `core:fmt` is
		// in almost every program: importing `core:strings` for one call measured
		// 397 to 4923 lines of IR for hello-world, since the whole package emits.
		contribute_builtin(c, pkg, "allocate_string", .Strings_Allocate, public = false)
	case STD_SLICE:
		// `slice.sort_by` owns the typed public surface; this is the package-private
		// bridge giving the shared runtime introsort a call-scoped comparator
		// address and a generated typed thunk. Ordinary Loke cannot express raw
		// relocation of an element without invoking its copy/drop operations.
		contribute_builtin(c, pkg, "sort_by_intrinsic", .Slice_Sort_By, public = false)
	case STD_STRINGS:
		// The one bridge the standard-library plan can't express in Loke itself:
		// copying known-valid UTF-8 into string storage from a *supplied* allocator,
		// reporting failure instead of applying a policy. Every built-in text
		// operation allocates from the default provider. Package-private, because
		// `core:strings` wraps it in `copy`/`try_copy`.
		contribute_builtin(c, pkg, "allocate_string", .Strings_Allocate, public = false)
	case STD_SYNC:
		// design.md "Concurrency and the memory model": the ordering enum is
		// ordinary `base:runtime` source, and this *binds* that identity rather than
		// declaring a second one, so an ordering forwarded through a `$` parameter
		// keeps meaning what it meant.
		contribute_type(c, pkg, "Memory_Order", memory_order_type(k))
		// `Atomic(T)` is a `core:sync` wrapper over the intrinsics, so the split is
		// specified rather than chosen. Each intrinsic requires a *constant*
		// ordering, the one thing an ordinary signature cannot ask for.
		// Package-private: `core:sync` publishes them as `Atomic(T)`'s methods and
		// as `fence`. The fence intrinsic is `atomic_fence` rather than `fence`
		// because a contributed name and a source declaration share one scope.
		contribute_atomic_intrinsics(c, pkg)
	case STD_SIMD:
		// design.md "SIMD vectors": `core:simd` supplies what the operators cannot
		// spell, because a lane index is constant and none of these can be written
		// as a loop. The reduction's fold is constant too, since it selects the
		// instruction — `Fold` stays an ordinary enum in this package's own source,
		// matched by member name rather than bound as a second identity.
		contribute_builtin(c, pkg, "simd_cast", .Simd_Cast, public = false)
		contribute_builtin(c, pkg, "simd_select", .Simd_Select, public = false)
		contribute_builtin(c, pkg, "simd_reduce", .Simd_Reduce, public = false)
	case STD_LOG:
		// design.md "Compiled log level": `LOKE_LOG_LEVEL` and `core:log`'s own
		// `Level` must be one type, or a caller could not compare them. Allocated
		// lazily, exactly as the other `LOKE_*` enums are.
		contribute_type(c, pkg, "Level", build_config_enum_type(c, .Log_Level))
	case STD_META:
		// The compile-time reflection descriptors. They stay compile-time-only
		// types: naming them does not make them storable.
		contribute_type(c, pkg, "Field", meta_field_type(c))
		contribute_type(c, pkg, "Enum_Value", meta_enum_value_type(c))
	}
}

// design.md "Allocators": both packages name the allocator surface, which
// design.md's own text spells unqualified in every lifecycle signature. One
// `Type_Id` under three spellings, never three types.
@(private = "file")
contribute_allocator_surface :: proc(c: ^Compiler, pkg: ^Package) {
	contribute_type(c, pkg, "Allocator", TYPE_ALLOCATOR)
	contribute_type(c, pkg, "Allocator_Error", TYPE_ALLOCATOR_ERROR)
}

// The ten atomic intrinsics, contributed package-privately wherever a bundled
// package is written over them. A package that uses only some still takes the
// set: one list beats a per-package subset nothing would keep in step.
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
	ident := intern_identifier(c, name)
	pkg.scope.names[ident] = new_symbol(c, Symbol {
		name      = ident,
		span      = no_span(),
		kind      = .Builtin,
		builtin   = kind,
		type      = TYPE_VOID,
		proc_type = intern_proc_type(c, nil, nil, INVALID_TYPE, false, ""),
		public    = public,
	})
}

// A type the compiler owns, under this package's spelling for it. An unresolved
// one binds nothing: a name for `<invalid>` reports as a broken member of a type
// that exists, when the truth is that the type never arrived.
@(private = "file")
contribute_type :: proc(c: ^Compiler, pkg: ^Package, name: string, type: Type_Id) {
	if type == INVALID_TYPE {
		return
	}
	ident := intern_identifier(c, name)
	pkg.scope.names[ident] = new_symbol(c, Symbol {
		name   = ident,
		span   = no_span(),
		kind   = .Type,
		type   = type,
		public = true,
	})
}

// Binds an existing symbol into the package scope. These aliases are reached as
// `pkg.name`, so each has to be public; the universe entries they alias are
// never reached that way, which is why marking them here is safe.
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

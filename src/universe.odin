// The predeclared scope (m2-plan step 1, decision "Universe").
//
// Every predeclared name is a real, shadowable symbol in a real scope. Nothing
// downstream compares an identifier against a hard-coded string to decide
// whether it is `int`, and `byte` is another symbol for the same `u8` type
// rather than a second identity.
package lokec

// The M0 stand-in for `core:fmt`.
// ponytail: scaffolding, not a language feature; delete when the seed runtime
// and core:fmt land in M6 (B14).
PRINT_BUILTIN :: "print_int"

build_universe :: proc(c: ^Compiler) -> ^Scope {
	init_semantic_stores(c)
	universe := new_scope(c, nil, .Universe)

	types := []struct{name: string, id: Type_Id} {
		{"bool", TYPE_BOOL},
		{"i8", TYPE_I8},
		{"i16", TYPE_I16},
		{"i32", TYPE_I32},
		{"i64", TYPE_I64},
		{"i128", TYPE_I128},
		{"u8", TYPE_U8},
		{"u16", TYPE_U16},
		{"u32", TYPE_U32},
		{"u64", TYPE_U64},
		{"u128", TYPE_U128},
		{"int", TYPE_INT},
		{"uint", TYPE_UINT},
		{"uintptr", TYPE_UINTPTR},
		{"f16", TYPE_F16},
		{"f32", TYPE_F32},
		{"f64", TYPE_F64},
		{"rune", TYPE_RUNE},
		{"rawptr", TYPE_RAWPTR},
		// `byte` is a predeclared alias for `u8`, not a distinct type
		// (design.md "Basic types").
		{"byte", TYPE_U8},
		// Real runtime types since M4b: a `typeid` is an identity scalar and an
		// `any_view` is a two-word borrowed view.
		{"typeid", TYPE_TYPEID},
		{"any_view", TYPE_ANY_VIEW},
		// Named, and deferred to M6: `type_is_supported` rejects them, so a use is
		// one `L0350` rather than "unknown type". `string_view` has an identity in
		// M4b because a reflection descriptor's name and tag are `string_view`s;
		// runtime construction and storage wait with `string`.
		{"string", TYPE_STRING},
		{"string_view", TYPE_STRING_VIEW},
		// design.md "Allocators": these live in `core:mem` / `base:runtime`, which
		// M6 makes nameable. Until then the compiler owns them, because the fixed
		// lifecycle signatures and the catalogue's `Cloneable` both spell them
		// unqualified (m5a-plan step 3).
		{"Allocator", TYPE_ALLOCATOR},
		{"Allocator_Error", TYPE_ALLOCATOR_ERROR},
	}
	for entry in types {
		define(c, universe, entry.name, Symbol{kind = .Type, type = entry.id})
		// The first name registered for a type is the one diagnostics print, so
		// `u8` must win over the `byte` alias that follows it.
		if info := type_of(c, entry.id); info != nil && info.name == INVALID_IDENTIFIER {
			info.name = intern_identifier(c, entry.name)
		}
	}

	define(c, universe, "true", Symbol {
		kind        = .Const,
		type        = TYPE_UNTYPED_BOOL,
		const_value = bool_const(true),
	})
	define(c, universe, "false", Symbol {
		kind        = .Const,
		type        = TYPE_UNTYPED_BOOL,
		const_value = bool_const(false),
	})
	define(c, universe, "nil", Symbol {
		kind        = .Const,
		type        = TYPE_UNTYPED_NIL,
		const_value = nil_const(),
	})

	// The parameter list outlives this frame, so it is arena-owned rather than a
	// slice literal pointing into the stack.
	print_params := make([]Type_Id, 1, c.semantic_allocator)
	print_params[0] = TYPE_INT
	print_modes := make([]Param_Mode, 1, c.semantic_allocator)
	print_modes[0] = .Value
	define(c, universe, PRINT_BUILTIN, Symbol {
		kind          = .Builtin,
		builtin       = .Print_Int,
		type          = TYPE_VOID,
		params        = print_params,
		param_symbols = make([]Symbol_Id, 1, c.semantic_allocator),
		proc_type     = intern_proc_type(c, print_params, print_modes, nil, nil, ""),
	})

	// `assert` and `panic` are ordinary calls whose phase is chosen by execution:
	// the evaluator diagnoses them, and a runtime occurrence takes the trap seam
	// (m3-plan decision "Phase-neutral `assert`/`panic`"). Their arity is checked
	// by `check_builtin_call`, so the interned type carries no parameters.
	no_args := intern_proc_type(c, nil, nil, nil, nil, "")
	define(c, universe, "assert", Symbol{kind = .Builtin, builtin = .Assert, type = TYPE_VOID, proc_type = no_args})
	define(c, universe, "panic",  Symbol{kind = .Builtin, builtin = .Panic,  type = TYPE_VOID, proc_type = no_args})

	// The layout and length queries. Their operands are inspected, not evaluated
	// (m3-plan decision "Unevaluated layout operands"), so `check_builtin_call`
	// binds them itself rather than through the ordinary argument path.
	layout := []struct{name: string, kind: Builtin_Kind} {
		{"size_of", .Size_Of},
		{"align_of", .Align_Of},
		{"offset_of", .Offset_Of},
		{"len", .Len},
	}
	for entry in layout {
		define(c, universe, entry.name, Symbol {
			kind      = .Builtin,
			builtin   = entry.kind,
			type      = TYPE_INT,
			proc_type = no_args,
		})
	}

	// design.md "`type` and `typeid`" and "Compile-time reflection". Their
	// operands are inspected rather than evaluated, so `check_builtin_call` binds
	// them itself.
	reflection := []struct{name: string, kind: Builtin_Kind} {
		{"type_of", .Type_Of},
		{"typeid_of", .Typeid_Of},
		{"fields_of", .Fields_Of},
		{"enum_values_of", .Enum_Values_Of},
	}
	for entry in reflection {
		define(c, universe, entry.name, Symbol {
			kind      = .Builtin,
			builtin   = entry.kind,
			type      = TYPE_TYPE,
			proc_type = no_args,
		})
	}

	// design.md "Iteration protocol": the compiler contributes an `iter` overload
	// for built-in iterables and finds a user type's own `iter` member, so the
	// free call in the `Iterable` requirement resolves for both.
	define(c, universe, "iter", Symbol{kind = .Builtin, builtin = .Iter, type = TYPE_VOID, proc_type = no_args})

	// design.md "Allocators": the explicitly fallible primitives. Their operand
	// types and arity are checked by `check_builtin_call`, so the interned type
	// carries none. `free_all` is registered and type-checked here but gated
	// before lowering until M5b's region analysis exists.
	allocation := []struct{name: string, kind: Builtin_Kind} {
		{"new", .New},
		{"new_clone", .New_Clone},
		{"free", .Free},
		{"free_all", .Free_All},
	}
	for entry in allocation {
		define(c, universe, entry.name, Symbol {
			kind      = .Builtin,
			builtin   = entry.kind,
			type      = TYPE_VOID,
			proc_type = no_args,
		})
	}

	// design.md: `Allocator` is obtained by the ordinary runtime default
	// expression `mem.default_allocator()`. `core:mem` is not nameable until M6,
	// so M5a exposes the same value under a compiler-owned name that the
	// generated default argument also uses.
	define(c, universe, "default_allocator", Symbol {
		kind      = .Builtin,
		builtin   = .Default_Allocator,
		type      = TYPE_ALLOCATOR,
		proc_type = no_args,
	})

	// design.md: `hash(value, seed: uint) -> uint` over the built-in types the
	// standard catalogue promises satisfy `Hashable`. Its operand types are
	// checked by `check_builtin_call`, so the interned type carries none.
	define(c, universe, "hash", Symbol {
		kind      = .Builtin,
		builtin   = .Hash,
		type      = TYPE_UINT,
		proc_type = no_args,
	})

	return universe
}

@(private = "file")
define :: proc(c: ^Compiler, scope: ^Scope, name: string, template: Symbol) {
	symbol := template
	symbol.name = intern_identifier(c, name)
	symbol.span = no_span()
	scope.names[symbol.name] = new_symbol(c, symbol)
}

// The predeclared scope (m2-plan step 1, decision "Universe").
//
// Every predeclared name is a real, shadowable symbol in a real scope. Nothing
// downstream compares an identifier against a hard-coded string to decide
// whether it is `int`, and `byte` is another symbol for the same `u8` type
// rather than a second identity.
package lokec

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
		// design.md "string type", "string type conversions", "C string views":
		// real runtime carriers since M6a. An owning immutable UTF-8 value, its
		// borrowed view, and the zero-terminated foreign view.
		{"string", TYPE_STRING},
		{"string_view", TYPE_STRING_VIEW},
		{"cstring_view", TYPE_CSTRING_VIEW},
		// design.md "Allocators": `core:mem` and `base:runtime` export these very
		// identities, and they stay predeclared as well because the fixed lifecycle
		// signatures and the catalogue's `Cloneable` spell them unqualified
		// (m6a-plan decision "Compiler-owned names").
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

	// `assert` and `panic` are ordinary calls whose phase is chosen by execution:
	// the evaluator diagnoses them, and a runtime occurrence takes the program's
	// panic strategy like every other defined failure
	// (m3-plan decision "Phase-neutral `assert`/`panic`"). Their arity is checked
	// by `check_builtin_call`, so the interned type carries no parameters.
	no_args := intern_proc_type(c, nil, nil, nil, nil, "")
	define(c, universe, "assert", Symbol{kind = .Builtin, builtin = .Assert, type = TYPE_VOID, proc_type = no_args})
	define(c, universe, "panic",  Symbol{kind = .Builtin, builtin = .Panic,  type = TYPE_VOID, proc_type = no_args})

	// design.md "Compile-time built-ins". Each one answers entirely in the
	// checker and leaves nothing for the backend, but none of them is a separate
	// syntactic category: they are predeclared, shadowable identifiers like
	// `size_of` and `transmute`.
	compile_time := []struct{name: string, kind: Builtin_Kind} {
		{"static_assert", .Static_Assert},
		{"build_config", .Build_Config},
		{"source_location", .Source_Location},
		{"caller_location", .Caller_Location},
	}
	for entry in compile_time {
		define(c, universe, entry.name, Symbol {
			kind      = .Builtin,
			builtin   = entry.kind,
			type      = TYPE_VOID,
			proc_type = no_args,
		})
	}

	// The layout and length queries. Their operands are inspected, not evaluated
	// (m3-plan decision "Unevaluated layout operands"), so `check_builtin_call`
	// binds them itself rather than through the ordinary argument path.
	layout := []struct{name: string, kind: Builtin_Kind} {
		{"size_of", .Size_Of},
		{"align_of", .Align_Of},
		{"offset_of", .Offset_Of},
		{"len", .Len},
		{"cap", .Cap},
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

	// design.md "`type` and `typeid`": the runtime half of reflection. Its operand
	// is an ordinary runtime `typeid`, so unlike the compile-time forms above it
	// is evaluated rather than inspected.
	define(c, universe, "type_info_of", Symbol {
		kind      = .Builtin,
		builtin   = .Type_Info_Of,
		type      = TYPE_VOID,
		proc_type = no_args,
	})

	// design.md "Iteration protocol": the compiler contributes an `iter` overload
	// for built-in iterables and finds a user type's own `iter` member, so the
	// free call in the `Iterable` requirement resolves for both.
	define(c, universe, "iter", Symbol{kind = .Builtin, builtin = .Iter, type = TYPE_VOID, proc_type = no_args})

	// design.md "Standard customization procedures": the free-call spelling of the
	// two copy entry points, forwarding to whichever hook the subject's type owns.
	// Their result types come from that hook, so the interned type carries none.
	copies := []struct{name: string, kind: Builtin_Kind} {
		{"clone", .Clone},
		{"try_clone", .Try_Clone},
	}
	for entry in copies {
		define(c, universe, entry.name, Symbol {
			kind      = .Builtin,
			builtin   = entry.kind,
			type      = TYPE_VOID,
			proc_type = no_args,
		})
	}

	// design.md "Allocators": the explicitly fallible primitives. Their operand
	// types and arity are checked by `check_builtin_call`, so the interned type
	// carries none.
	allocation := []struct{name: string, kind: Builtin_Kind} {
		{"new", .New},
		{"new_clone", .New_Clone},
		{"free", .Free},
		{"free_all", .Free_All},
		// design.md "Dynamic arrays" and "Maps": `make` names a container *type*
		// and binds the result to the selected allocator. No ordinary signature can
		// spell a type-valued first operand, so it joins the built-ins here.
		{"make", .Make},
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
	// expression `mem.default_allocator()`, so the name a program writes is the
	// one `core:mem` contributes and not a predeclared one. The symbol itself is
	// still compiler-owned: the generated default argument of a lifecycle hook
	// names it, which is what makes an omitted allocator and a written
	// `mem.default_allocator()` one call.
	c.default_allocator_symbol = new_symbol(c, Symbol {
		kind      = .Builtin,
		builtin   = .Default_Allocator,
		name      = intern_identifier(c, "default_allocator"),
		span      = no_span(),
		type      = TYPE_ALLOCATOR,
		proc_type = no_args,
	})

	// `drop(value)` explicitly cleans up a definitely live lexical owning
	// variable; it's a compiler special form, not an ordinary procedure, and a
	// declaration can shadow it to make the special form unavailable in that
	// scope (design.md "Storage modifiers") — which an ordinary universe symbol
	// already gives it.
	define(c, universe, "drop", Symbol{kind = .Builtin, builtin = .Drop, type = TYPE_VOID, proc_type = no_args})

	// design.md "Exchange": `exchange(inout destination, replacement)`. Its result
	// type is the destination's, so the interned type carries none and
	// `check_exchange_builtin` settles both.
	define(c, universe, "exchange", Symbol{kind = .Builtin, builtin = .Exchange, type = TYPE_VOID, proc_type = no_args})

	// design.md: `hash(value, seed: uint) -> uint` over the built-in types the
	// standard catalogue promises satisfy `Hashable`. Its operand types are
	// checked by `check_builtin_call`, so the interned type carries none.
	define(c, universe, "hash", Symbol {
		kind      = .Builtin,
		builtin   = .Hash,
		type      = TYPE_UINT,
		proc_type = no_args,
	})

	// design.md "Build configuration": the `LOKE_*` constants (m7-plan step 1).
	predeclare_build_config(c, universe)

	return universe
}

@(private = "file")
define :: proc(c: ^Compiler, scope: ^Scope, name: string, template: Symbol) {
	define_universe(c, scope, name, template)
}

// Package-visible so `src/build_config.odin` can predeclare the `LOKE_*`
// constants into the same scope.
define_universe :: proc(c: ^Compiler, scope: ^Scope, name: string, template: Symbol) {
	symbol := template
	symbol.name = intern_identifier(c, name)
	symbol.span = no_span()
	scope.names[symbol.name] = new_symbol(c, symbol)
}

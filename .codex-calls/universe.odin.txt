// The predeclared scope.
//
// Every predeclared name is a real, shadowable symbol in a real scope. Nothing
// downstream compares an identifier against a hard-coded string to decide
// whether it is `int`, and `byte` is another symbol for the same `u8` type,
// not a second identity.
package lokec

// One universe per compilation, not per package: `bind_runtime_bootstrap`
// binds `Unit`, `Option`, and `Result` into it once, and every package must
// see them.
build_universe :: proc(c: ^Compiler) -> ^Scope {
	if c.universe != nil {
		return c.universe
	}
	init_semantic_stores(c)
	universe := new_scope(c, nil, .Universe)
	c.universe = universe

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
		// signatures and the catalogue's `Cloneable` spell them unqualified.
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

	// The signature every built-in shares: none. `check_builtin_call` settles
	// arity and operand types for all of them, so an interned signature would
	// only be a second place for those rules to disagree.
	no_args := intern_proc_type(c, nil, nil, INVALID_TYPE, false, "")
	// Every predeclared built-in: one name, the kind that selects its checking,
	// and the type the checker starts from. All share `no_args`, since arity and
	// operand types are settled by `check_builtin_call`, not an interned
	// signature. Order is irrelevant — the names are distinct, so none shadows
	// another.
	builtins := []struct{name: string, kind: Builtin_Kind, type: Type_Id} {
		// `assert` and `panic` are ordinary calls whose phase execution chooses: the
		// evaluator diagnoses them, and a runtime occurrence takes the program's
		// panic strategy like any other defined failure.
		{"assert", .Assert, TYPE_VOID},
		{"panic", .Panic, TYPE_VOID},

		// design.md "Compile-time built-ins". Each answers entirely in the checker
		// and leaves nothing for the backend, but none is a separate syntactic
		// category — they're predeclared, shadowable identifiers like `size_of`
		// and `transmute`.
		{"static_assert", .Static_Assert, TYPE_VOID},
		{"build_config", .Build_Config, TYPE_VOID},
		{"source_location", .Source_Location, TYPE_VOID},
		{"caller_location", .Caller_Location, TYPE_VOID},

		// The layout and length queries. Their operands are inspected, not
		// evaluated, so `check_builtin_call` binds them itself rather than through
		// the ordinary argument path.
		{"size_of", .Size_Of, TYPE_INT},
		{"align_of", .Align_Of, TYPE_INT},
		{"offset_of", .Offset_Of, TYPE_INT},
		{"is_copyable", .Is_Copyable, TYPE_BOOL},


		// design.md "`type` and `typeid`" and "Compile-time reflection". Their
		// operands are inspected rather than evaluated, so `check_builtin_call`
		// binds them itself.
		{"type_of", .Type_Of, TYPE_TYPE},
		{"typeid_of", .Typeid_Of, TYPE_TYPE},
		{"fields_of", .Fields_Of, TYPE_TYPE},
		{"enum_values_of", .Enum_Values_Of, TYPE_TYPE},

		// design.md "`type` and `typeid`": the runtime half of reflection. Its
		// operand is an ordinary runtime `typeid`, so unlike the compile-time forms
		// above it is evaluated, not inspected.
		{"type_info_of", .Type_Info_Of, TYPE_VOID},

		// design.md "Allocators": the explicitly fallible primitives.
		{"new", .New, TYPE_VOID},
		{"new_clone", .New_Clone, TYPE_VOID},
		{"free", .Free, TYPE_VOID},
		{"free_all", .Free_All, TYPE_VOID},
		// design.md "Dynamic arrays" and "Maps": `make` names a container *type* and
		// binds the result to the selected allocator. No ordinary signature can
		// spell a type-valued first operand, so it joins the built-ins here.
		{"make", .Make, TYPE_VOID},

		// `drop(value)` explicitly cleans up a definitely live lexical owning
		// variable; it's a compiler special form, not an ordinary procedure. A
		// declaration can shadow it to make the form unavailable in that scope
		// (design.md "Storage modifiers") — free with an ordinary universe symbol.
		{"drop", .Drop, TYPE_VOID},

		// design.md "Exchange": `exchange(inout destination, replacement)`. Its result
		// type is the destination's, so the interned type carries none and
		// `check_exchange_builtin` settles both.
		{"exchange", .Exchange, TYPE_VOID},
	}
	for entry in builtins {
		define(c, universe, entry.name, Symbol {
			kind      = .Builtin,
			builtin   = entry.kind,
			type      = entry.type,
			proc_type = no_args,
		})
	}

	// design.md: `Allocator` is obtained by the ordinary runtime default
	// expression `mem.default_allocator()`, so the name a program writes is the
	// one `core:mem` contributes, not a predeclared one. The symbol is still
	// compiler-owned: a lifecycle hook's generated default argument names it,
	// which makes an omitted allocator and a written `mem.default_allocator()`
	// the same call.
	c.default_allocator_symbol = new_symbol(c, Symbol {
		kind      = .Builtin,
		builtin   = .Default_Allocator,
		name      = intern_identifier(c, "default_allocator"),
		span      = no_span(),
		type      = TYPE_ALLOCATOR,
		proc_type = no_args,
	})

	// design.md "Build configuration": the `LOKE_*` constants.
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

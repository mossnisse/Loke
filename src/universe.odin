// The predeclared scope. Every predeclared name is a real, shadowable symbol, so
// `byte` is a second name for `u8`, not a second type.
package lokec

// One universe per compilation, not per package: `bind_runtime_bootstrap`
// binds the `base:runtime` bootstrap names into it once for every package.
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
		{"byte", TYPE_U8},
		{"typeid", TYPE_TYPEID},
		{"any_view", TYPE_ANY_VIEW},
		{"string", TYPE_STRING},
		{"string_view", TYPE_STRING_VIEW},
		{"cstring_view", TYPE_CSTRING_VIEW},
		// Also exported by `core:mem` and `base:runtime`, but the lifecycle
		// signatures spell them unqualified.
		{"Allocator", TYPE_ALLOCATOR},
		{"Allocator_Error", TYPE_ALLOCATOR_ERROR},
	}
	for entry in types {
		define_universe(c, universe, entry.name, Symbol{kind = .Type, type = entry.id})
		// The first name wins in diagnostics, so `u8` beats `byte`.
		if info := type_of(c, entry.id); info != nil && info.name == INVALID_IDENTIFIER {
			info.name = intern_identifier(c, entry.name)
		}
	}

	// design.md "Predeclared names": literals are `reserved`, so no declaration
	// can change what `true` means.
	define_universe(c, universe, "true", Symbol {
		kind        = .Const,
		type        = TYPE_UNTYPED_BOOL,
		const_value = bool_const(true),
		reserved    = true,
	})
	define_universe(c, universe, "false", Symbol {
		kind        = .Const,
		type        = TYPE_UNTYPED_BOOL,
		const_value = bool_const(false),
		reserved    = true,
	})
	define_universe(c, universe, "nil", Symbol {
		kind        = .Const,
		type        = TYPE_UNTYPED_NIL,
		const_value = nil_const(),
		reserved    = true,
	})

	// Built-ins share an empty signature: `check_builtin_call` settles arity and
	// operand types.
	no_args := intern_proc_type(c, nil, nil, INVALID_TYPE, false, "")
	builtins := []struct{name: string, kind: Builtin_Kind} {
		{"assert", .Assert},
		{"panic", .Panic},
		{"static_assert", .Static_Assert},
		{"build_config", .Build_Config},
		{"source_location", .Source_Location},
		{"caller_location", .Caller_Location},
		{"size_of", .Size_Of},
		{"align_of", .Align_Of},
		{"offset_of", .Offset_Of},
		{"is_copyable", .Is_Copyable},
		{"type_of", .Type_Of},
		{"typeid_of", .Typeid_Of},
		{"fields_of", .Fields_Of},
		{"enum_values_of", .Enum_Values_Of},
		{"type_info_of", .Type_Info_Of},
		{"new", .New},
		{"new_clone", .New_Clone},
		{"free", .Free},
		{"free_all", .Free_All},
		{"make", .Make},
		{"drop", .Drop},
		{"exchange", .Exchange},
	}
	for entry in builtins {
		define_universe(c, universe, entry.name, Symbol {
			kind      = .Builtin,
			builtin   = entry.kind,
			type      = TYPE_VOID,
			proc_type = no_args,
		})
	}

	// Not predeclared: programs write `mem.default_allocator()`, which
	// `core:mem` binds to this symbol, as does a hook's generated default argument.
	c.default_allocator_symbol = new_symbol(c, Symbol {
		kind      = .Builtin,
		builtin   = .Default_Allocator,
		name      = intern_identifier(c, "default_allocator"),
		span      = no_span(),
		type      = TYPE_VOID,
		proc_type = no_args,
	})

	predeclare_build_config(c, universe)
	return universe
}

define_universe :: proc(c: ^Compiler, scope: ^Scope, name: string, template: Symbol) {
	symbol := template
	symbol.name = intern_identifier(c, name)
	symbol.span = no_span()
	scope.names[symbol.name] = new_symbol(c, symbol)
}

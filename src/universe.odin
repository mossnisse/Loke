// Predeclared names as symbols, so `byte` is a second name for `u8`, not a second
// type.
package lokec

import "core:slice"

// One universe per compilation, not per package: `bind_runtime_bootstrap`
// binds the `base:runtime` bootstrap names into it once for every package.
build_universe :: proc(c: ^Compiler) -> ^Scope {
	if c.universe != nil {
		return c.universe
	}
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
		{"typeid", TYPE_TYPEID},
		{"string", TYPE_STRING},
		{"string_view", TYPE_STRING_VIEW},
		{"cstring_view", TYPE_CSTRING_VIEW},
		// Also exported by `core:mem` and `base:runtime`, but the lifecycle
		// signatures spell them unqualified.
		{"Allocator", TYPE_ALLOCATOR},
		{"Allocator_Error", TYPE_ALLOCATOR_ERROR},
	}
	for entry in types {
		define_universe(c, entry.name, Symbol{kind = .Type, type = entry.id})
		// The typeid sort key reads this name, and `Allocator` prints by it.
		type_of(c, entry.id).name = intern_identifier(c, entry.name)
	}
	define_universe(c, "byte", Symbol{kind = .Type, type = TYPE_U8})

	// design.md "Predeclared names": literals are `reserved`, so no declaration
	// can change what `true` means.
	literals := []struct{name: string, type: Type_Id, value: Const_Value} {
		{"true", TYPE_UNTYPED_BOOL, bool_const(true)},
		{"false", TYPE_UNTYPED_BOOL, bool_const(false)},
		{"nil", TYPE_UNTYPED_NIL, nil_const()},
	}
	for entry in literals {
		define_universe(c, entry.name, Symbol{kind = .Const, type = entry.type, const_value = entry.value, reserved = true})
	}

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
		{"is_union", .Is_Union},
		{"type_of", .Type_Of},
		{"typeid_of", .Typeid_Of},
		{"fields_of", .Fields_Of},
		{"enum_values_of", .Enum_Values_Of},
		{"variants_of", .Variants_Of},
		{"type_info_of", .Type_Info_Of},
		{"free_all", .Free_All},
		{"box", .Box_New},
		{"try_box", .Try_Box},
		{"make", .Make},
		{"try_make", .Try_Make},
		{"drop", .Drop},
		{"exchange", .Exchange},
	}
	for entry in builtins {
		c.universe.names[intern_identifier(c, entry.name)] = new_builtin_symbol(c, entry.name, entry.kind)
	}

	// Not predeclared: programs write `mem.default_allocator()`, which
	// `core:mem` binds to this symbol, as does a hook's generated default argument.
	c.default_allocator_symbol = new_builtin_symbol(c, "default_allocator", .Default_Allocator)

	predeclare_build_config(c)
	return universe
}

// Built-ins share an empty signature: `check_builtin_call` settles arity and
// operand types.
new_builtin_symbol :: proc(c: ^Compiler, name: string, kind: Builtin_Kind, public := false) -> Symbol_Id {
	return new_symbol(c, Symbol {
		name      = intern_identifier(c, name),
		span      = NO_SPAN,
		kind      = .Builtin,
		builtin   = kind,
		type      = TYPE_VOID,
		proc_type = intern_proc_type(c, nil, nil, INVALID_TYPE, false, ""),
		public    = public,
	})
}

// design.md "Predeclared names": `Simd`, `Range`, and `Box` are recognized by
// name, with no universe binding, so a program's own declaration shadows them.
predeclared_callee :: proc(k: ^Checker, callee: Expr, names: ..string) -> bool {
	ident, is_ident := callee.(^Expr_Ident)
	return is_ident && slice.contains(names, ident.name) && lookup_symbol(k.scope, identifier_of(k.c, ident)) == INVALID_SYMBOL
}

define_universe :: proc(c: ^Compiler, name: string, template: Symbol) {
	symbol := template
	symbol.name = intern_identifier(c, name)
	symbol.span = NO_SPAN
	c.universe.names[symbol.name] = new_symbol(c, symbol)
}

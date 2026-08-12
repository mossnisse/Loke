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
		// Named, and deferred: `type_is_supported` rejects them, so a use is
		// one `L0350` rather than "unknown type".
		{"string", TYPE_STRING},
		{"typeid", TYPE_TYPEID},
		{"any_view", TYPE_ANY_VIEW},
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
		type          = TYPE_VOID,
		params        = print_params,
		param_symbols = make([]Symbol_Id, 1, c.semantic_allocator),
		proc_type     = intern_proc_type(c, print_params, print_modes, nil, nil, ""),
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

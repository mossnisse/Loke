// Name resolution and type checking (compiler-plan B6/B8, minimal), plus the
// constant folding that stands in for the compile-time engine until M3.
//
// Annotations are written back onto the AST nodes; there is no separate typed
// tree (decision A1).
package lokec

@(private = "file")
Checker :: struct {
	c:     ^Compiler,
	file:  u32,
	scope: ^Scope,
	pkg:   Package_Id,
}

// The M0 stand-in for `core:fmt`.
// ponytail: scaffolding, not a language feature; delete when the seed runtime
// and core:fmt land in M6 (B14).
PRINT_BUILTIN :: "print_int"

check :: proc(c: ^Compiler, f: ^File) {
	pkg_id := new_package(c, f.package_name, c.sources[f.file].path)
	add_package_file(c, pkg_id, f)
	check_package(c, pkg_id)
	validate_executable(c, pkg_id)
}

// Package checking is deliberately separate from executable validation: M2
// imports libraries whose package name is not `main` and which have no entry
// procedure. Each phase consumes stable IDs produced by the previous one.
check_package :: proc(c: ^Compiler, package_id: Package_Id) {
	pkg := package_of(c, package_id)
	if pkg == nil {
		return
	}
	if len(pkg.files) > 1 {
		first := pkg.files[0]
		for file in pkg.files[1:] {
			if file.package_name != first.package_name {
				errorf(c, file.package_span, "L0300", "package `%s` does not match `%s`", file.package_name, first.package_name)
				add_notef(c, first.package_span, "the package was established here")
			}
		}
	}
	k := Checker {
		c    = c,
		pkg  = package_id,
	}

	universe := new_scope(c, nil, .Universe)
	print_name := intern_identifier(c, PRINT_BUILTIN)
	print_sym := new_symbol(c, Symbol {
		name   = print_name,
		kind   = .Builtin,
		type   = TYPE_VOID,
		params = []Type_Id{TYPE_INT},
		proc_type = intern_proc_type(c, []Type_Id{TYPE_INT}, []Param_Mode{.Value}, nil, nil, ""),
		pkg    = package_id,
	})
	universe.names[print_name] = print_sym

	k.scope = new_scope(c, universe, .Package)
	pkg.scope = k.scope

	// Phase 1: collect package declarations from every file, order-independent.
	for file in pkg.files {
		k.file = file.file
		for item in file.items {
			if d, ok := item.(^Decl); ok {
				declare_all(&k, d, top_level = true)
			}
		}
	}

	// Phase 2a: create every nominal shell before resolving a single field.
	for file in pkg.files {
		k.file = file.file
		for item in file.items {
			if d, ok := item.(^Decl); ok {
				create_nominal_type_shell(&k, d)
			}
		}
	}

	// Phase 2b: resolve fields and callable signatures. Recursive types and
	// mutually recursive procedures now already have stable identities.
	for file in pkg.files {
		k.file = file.file
		for item in file.items {
			if d, ok := item.(^Decl); ok {
				resolve_declaration_signature(&k, d)
			}
		}
	}

	// Phase 3: bind names in initializers and procedure bodies. Unsupported M1
	// constructs remain opaque so their single L0350 diagnostic is preserved.
	resolve_package_bodies(&k, pkg)

	// Phase 4: type checking and constant folding consume the binding IDs.
	for file in pkg.files {
		k.file = file.file
		for item in file.items {
			#partial switch v in item {
			case ^Decl:
				check_decl(&k, v)
			case ^Item_Error:
			case:
				unsupported_construct(&k, item_span(item))
			}
		}
	}
}

@(private = "file")
create_nominal_type_shell :: proc(k: ^Checker, d: ^Decl) {
	if len(d.values) != 1 || len(d.symbols) != 1 || d.symbols[0] == INVALID_SYMBOL {
		return
	}
	symbol := symbol_of(k.c, d.symbols[0])
	if symbol == nil {
		return
	}
	kind := Type_Kind.Invalid
	#partial switch value in d.values[0] {
	case ^Type_Record:
		kind = value.kind == .Struct ? Type_Kind.Struct : Type_Kind.Union
	case ^Type_Enum:
		kind = .Enum
	case ^Type_Interface:
		kind = .Interface
	case ^Type_Distinct:
		kind = .Distinct
	}
	if kind == .Invalid {
		return
	}
	symbol.kind = .Type
	symbol.type = new_type(k.c, Type_Info{kind = kind, name = symbol.name, symbol = d.symbols[0]})
	if base := expr_base(d.values[0]); base != nil {
		base.denoted_type = symbol.type
		base.resolution = Resolution{kind = .Type, symbol = d.symbols[0]}
		base.value_category = .Type
	}
}

@(private = "file")
resolve_package_bodies :: proc(k: ^Checker, pkg: ^Package) {
	for file in pkg.files {
		k.file = file.file
		k.scope = pkg.scope
		for item in file.items {
			if d, ok := item.(^Decl); ok {
				resolve_decl_names(k, d)
			}
		}
	}
	k.scope = pkg.scope
}

@(private = "file")
resolve_decl_names :: proc(k: ^Checker, d: ^Decl) {
	if literal := decl_proc(d); literal != nil {
		outer := k.scope
		k.scope = new_scope(k.c, outer, .Procedure)
		if literal.signature != nil {
			for parameter in literal.signature.params {
				install_symbols(k.scope, k.c, parameter.symbols)
			}
			for result in literal.signature.results {
				install_symbols(k.scope, k.c, result.symbols)
			}
		}
		resolve_block_names(k, literal.body)
		k.scope = outer
		return
	}
	for value in d.values {
		resolve_expr_names(k, value)
	}
}

@(private = "file")
resolve_block_names :: proc(k: ^Checker, block: ^Block) {
	if block == nil {
		return
	}
	for statement in block.stmts {
		#partial switch value in statement {
		case ^Decl:
			if len(value.symbols) == 0 {
				declare_all(k, value)
			} else {
				install_symbols(k.scope, k.c, value.symbols)
			}
			resolve_decl_names(k, value)
		case ^Stmt_Expr:
			for expression in value.exprs {
				resolve_expr_names(k, expression)
			}
		case ^Stmt_Return:
			for result in value.values {
				resolve_expr_names(k, result.expr)
			}
		case ^Block:
			outer := k.scope
			k.scope = new_scope(k.c, outer, .Local)
			resolve_block_names(k, value)
			k.scope = outer
		}
	}
}

@(private = "file")
resolve_expr_names :: proc(k: ^Checker, expression: Expr) {
	if expression == nil {
		return
	}
	#partial switch value in expression {
	case ^Expr_Ident:
		name := value.name_id
		if name == INVALID_IDENTIFIER {
			name = intern_identifier(k.c, value.name)
			value.name_id = name
		}
		symbol := lookup_symbol(k.scope, name)
		if symbol == INVALID_SYMBOL {
			if value.name == "_" {
				errorf(k.c, value.span, "L0314", "`_` cannot be read")
			} else {
				errorf(k.c, value.span, "L0315", "unknown name `%s`", value.name)
			}
			value.resolution.kind = .Error
			return
		}
		value.symbol = symbol
		resolved := symbol_of(k.c, symbol)
		if resolved != nil && resolved.kind == .Type {
			value.resolution = Resolution{kind = .Type, symbol = symbol}
			value.denoted_type = resolved.type
			value.value_category = .Type
		} else if resolved != nil && resolved.kind == .Package_Alias {
			value.resolution = Resolution{kind = .Package, symbol = symbol}
		} else {
			value.resolution = Resolution{kind = .Value, symbol = symbol}
		}
	case ^Expr_Unary:
		resolve_expr_names(k, value.operand)
	case ^Expr_Binary:
		resolve_expr_names(k, value.lhs)
		resolve_expr_names(k, value.rhs)
	case ^Expr_Call:
		resolve_expr_names(k, value.callee)
		for argument in value.args {
			resolve_expr_names(k, argument.value)
		}
		if callee, ok := value.callee.(^Expr_Ident); ok && callee.symbol != INVALID_SYMBOL {
			kind := Resolution_Kind.Call
			chosen := callee.symbol
			if symbol := symbol_of(k.c, callee.symbol); symbol != nil {
				#partial switch symbol.kind {
				case .Type:
					kind = .Conversion
					chosen = INVALID_SYMBOL
				case .Proc_Group:
					chosen = INVALID_SYMBOL
				}
			}
			value.resolution = Resolution {
				kind            = kind,
				symbol          = callee.symbol,
				chosen_overload = chosen,
			}
		}
	}
}

@(private = "file")
install_symbols :: proc(scope: ^Scope, c: ^Compiler, symbols: []Symbol_Id) {
	for id in symbols {
		if symbol := symbol_of(c, id); symbol != nil && symbol.name != INVALID_IDENTIFIER {
			scope.names[symbol.name] = id
		}
	}
}

validate_executable :: proc(c: ^Compiler, package_id: Package_Id) {
	pkg := package_of(c, package_id)
	if pkg == nil || len(pkg.files) == 0 {
		return
	}
	first := pkg.files[0]
	name := identifier_text(c, pkg.name)
	if name != "" && name != "main" {
		errorf(c, first.package_span, "L0301", "an executable is built from a package named `main`, found `%s`", name)
	}
	entry := lookup_symbol(pkg.scope, intern_identifier(c, "main"))
	if entry == INVALID_SYMBOL {
		errorf(c, no_span(), "L0302", "package `main` has no `main` procedure")
	} else if symbol := symbol_of(c, entry); symbol == nil || symbol.kind != .Proc {
		span := symbol == nil ? no_span() : symbol.span
		errorf(c, span, "L0303", "`main` must be a procedure: `main :: proc() { ... }`")
	}
}

@(private = "file")
// Creates the symbols for one declaration. Shadowing is rejected, which is the
// default design.md's open question records.
declare_all :: proc(k: ^Checker, d: ^Decl, top_level := false) {
	d.top_level = top_level
	symbols := make([dynamic]Symbol_Id, 0, len(d.names), k.c.semantic_allocator)
	for name in d.names {
		if name.text == "_" {
			append(&symbols, INVALID_SYMBOL) // the discard identifier binds nothing
			continue
		}

		name_id := name.id
		if name_id == INVALID_IDENTIFIER {
			name_id = intern_identifier(k.c, name.text)
		}
		if existing, ok := k.scope.names[name_id]; ok {
			errorf(k.c, name.span, "L0304", "`%s` is already declared in this scope", name.text)
			_ = existing
			append(&symbols, INVALID_SYMBOL)
			continue
		}
		outer, owner := lookup_symbol_with_scope(k.scope.parent, name_id)
		if outer != INVALID_SYMBOL && owner.kind == .Local {
			errorf(k.c, name.span, "L0305", "`%s` shadows an outer declaration", name.text)
		}

		sym := Symbol {
			name = name_id,
			span = name.span,
			decl = d,
			pkg  = k.pkg,
		}
		switch {
		case decl_proc(d) != nil:
			sym.kind = .Proc
			sym.type = TYPE_VOID
		case d.kind == .Const:
			sym.kind = .Const
		case:
			sym.kind = .Var
		}
		id := new_symbol(k.c, sym)
		k.scope.names[name_id] = id
		append(&symbols, id)
	}
	d.symbols = symbols[:]
}

@(private = "file")
resolve_declaration_signature :: proc(k: ^Checker, d: ^Decl) {
	if literal := decl_proc(d); literal != nil {
		for symbol_id in d.symbols {
			if symbol := symbol_of(k.c, symbol_id); symbol != nil {
				symbol.kind = .Proc
				symbol.type = TYPE_VOID
				if literal.signature != nil {
					params := make([dynamic]Type_Id, 0, len(literal.signature.params), k.c.semantic_allocator)
					modes := make([dynamic]Param_Mode, 0, len(literal.signature.params), k.c.semantic_allocator)
					for &parameter in literal.signature.params {
						parameter_type := resolve_type_syntax(k, parameter.type)
						append(&params, parameter_type)
						append(&modes, parameter.mode)
						bindings := make([dynamic]Symbol_Id, 0, len(parameter.names), k.c.semantic_allocator)
						for parameter_name in parameter.names {
							binding := new_binding_symbol(k, parameter_name.name, .Parameter)
							if bound := symbol_of(k.c, binding); bound != nil {
								bound.type = parameter_type
							}
							append(&bindings, binding)
						}
						parameter.symbols = bindings[:]
					}
					results := make([dynamic]Type_Id, 0, len(literal.signature.results), k.c.semantic_allocator)
					result_inout := make([dynamic]bool, 0, len(literal.signature.results), k.c.semantic_allocator)
					for &result in literal.signature.results {
						result_type := resolve_type_syntax(k, result.type)
						append(&results, result_type)
						append(&result_inout, result.is_inout)
						bindings := make([dynamic]Symbol_Id, 0, len(result.names), k.c.semantic_allocator)
						for name in result.names {
							binding := new_binding_symbol(k, name, .Result)
							if bound := symbol_of(k.c, binding); bound != nil {
								bound.type = result_type
							}
							append(&bindings, binding)
						}
						result.symbols = bindings[:]
					}
					proc_type := intern_proc_type(k.c, params[:], modes[:], results[:], result_inout[:], literal.signature.convention)
					// Parameter/result binding creation may grow the symbol store.
					// Reacquire by ID rather than retaining a pointer across append.
					symbol = symbol_of(k.c, symbol_id)
					symbol.params = params[:]
					symbol.results = results[:]
					symbol.proc_type = proc_type
					if len(results) == 1 {
						symbol.type = results[0]
					}
				}
			}
		}
		return
	}

	if len(d.values) == 1 && len(d.symbols) == 1 && d.symbols[0] != INVALID_SYMBOL {
		symbol := symbol_of(k.c, d.symbols[0])
		#partial switch value in d.values[0] {
		case ^Type_Record:
			members := make([dynamic]Symbol_Id, 0, len(value.fields), k.c.semantic_allocator)
			for &generic_parameter in value.generic_params {
				bindings := make([dynamic]Symbol_Id, 0, len(generic_parameter.names), k.c.semantic_allocator)
				for name in generic_parameter.names {
					append(&bindings, new_binding_symbol(k, name, .Type))
				}
				generic_parameter.symbols = bindings[:]
			}
			for &field in value.fields {
				field_type := resolve_type_syntax(k, field.type)
				bindings := make([dynamic]Symbol_Id, 0, len(field.names), k.c.semantic_allocator)
				for name in field.names {
					binding := new_binding_symbol(k, name, .Field)
					if bound := symbol_of(k.c, binding); bound != nil {
						bound.type = field_type
					}
					append(&bindings, binding)
					if binding != INVALID_SYMBOL { append(&members, binding) }
				}
				field.symbols = bindings[:]
			}
			symbol_of(k.c, d.symbols[0]).members = members[:]
		case ^Type_Enum:
			members := make([dynamic]Symbol_Id, 0, len(value.fields), k.c.semantic_allocator)
			for &field in value.fields {
				field.symbol = new_binding_symbol(k, field.name, .Enum_Member)
				if field.symbol != INVALID_SYMBOL { append(&members, field.symbol) }
			}
			symbol_of(k.c, d.symbols[0]).members = members[:]
		case ^Type_Interface:
			for &requirement in value.requirements {
				for &binding_group in requirement.bindings {
					bindings := make([dynamic]Symbol_Id, 0, len(binding_group.names), k.c.semantic_allocator)
					for name in binding_group.names {
						append(&bindings, new_binding_symbol(k, name, .Parameter))
					}
					binding_group.symbols = bindings[:]
				}
			}
		case ^Expr_Proc_Group:
			symbol.kind = .Proc_Group
			members := make([dynamic]Symbol_Id, 0, len(value.names), k.c.semantic_allocator)
			for name in value.names {
				member := lookup_symbol(k.scope, name.id)
				if member != INVALID_SYMBOL {
					append(&members, member)
				}
			}
			symbol.members = members[:]
		case ^Expr_Operator:
			symbol.kind = .Proc
			pkg := package_of(k.c, k.pkg)
			set, found := pkg.operators[value.symbol]
			if !found {
				set = new(Operator_Set, k.c.semantic_allocator)
				set.candidates = make([dynamic]Symbol_Id, 0, 4, k.c.semantic_allocator)
				pkg.operators[value.symbol] = set
			}
			append(&set.candidates, d.symbols[0])
		case ^Type_Distinct:
			underlying := resolve_type_syntax(k, value.elem)
			if info := type_of(k.c, symbol.type); info != nil {
				info.element = underlying
			}
		}
	}
}

@(private = "file")
new_binding_symbol :: proc(k: ^Checker, name: Name, kind: Symbol_Kind) -> Symbol_Id {
	if name.text == "_" || name.text == "" {
		return INVALID_SYMBOL
	}
	id := name.id
	if id == INVALID_IDENTIFIER {
		id = intern_identifier(k.c, name.text)
	}
	return new_symbol(k.c, Symbol{name = id, span = name.span, kind = kind, pkg = k.pkg})
}

@(private = "file")
resolve_type_syntax :: proc(k: ^Checker, syntax: Expr) -> Type_Id {
	if syntax == nil {
		return INVALID_TYPE
	}
	#partial switch value in syntax {
	case ^Expr_Error:
		return INVALID_TYPE
	case ^Expr_Ident:
		if value.name == "int" {
			value.denoted_type = TYPE_INT
			value.resolution.kind = .Type
			return TYPE_INT
		}
		id := value.name_id
		if id == INVALID_IDENTIFIER {
			id = intern_identifier(k.c, value.name)
		}
		symbol_id := lookup_symbol(k.scope, id)
		if symbol := symbol_of(k.c, symbol_id); symbol != nil && symbol.kind == .Type {
			value.symbol = symbol_id
			value.denoted_type = symbol.type
			value.resolution = Resolution{kind = .Type, symbol = symbol_id}
			return symbol.type
		}
	case ^Type_Pointer:
		element := resolve_type_syntax(k, value.elem)
		if element == INVALID_TYPE {
			return INVALID_TYPE
		}
		value.denoted_type = intern_type(k.c, Type_Key{kind = .Pointer, element = element}, Type_Info{kind = .Pointer, element = element})
		value.resolution.kind = .Type
		return value.denoted_type
	case ^Type_Multi_Pointer:
		element := resolve_type_syntax(k, value.elem)
		if element == INVALID_TYPE {
			return INVALID_TYPE
		}
		value.denoted_type = intern_type(k.c, Type_Key{kind = .Multi_Pointer, element = element}, Type_Info{kind = .Multi_Pointer, element = element})
		value.resolution.kind = .Type
		return value.denoted_type
	case ^Type_Slice:
		element := resolve_type_syntax(k, value.elem)
		if element == INVALID_TYPE {
			return INVALID_TYPE
		}
		mutable := value.mutable ? u64(1) : u64(0)
		value.denoted_type = intern_type(k.c, Type_Key{kind = .Slice, element = element, count = mutable}, Type_Info{kind = .Slice, element = element, mutable = value.mutable})
		value.resolution.kind = .Type
		return value.denoted_type
	case ^Type_Dynamic_Array:
		element := resolve_type_syntax(k, value.elem)
		if element == INVALID_TYPE {
			return INVALID_TYPE
		}
		value.denoted_type = intern_type(k.c, Type_Key{kind = .Dynamic_Array, element = element}, Type_Info{kind = .Dynamic_Array, element = element})
		value.resolution.kind = .Type
		return value.denoted_type
	case ^Type_Array:
		element := resolve_type_syntax(k, value.elem)
		if element == INVALID_TYPE || value.inferred || value.length == nil {
			return INVALID_TYPE
		}
		length_literal, ok := value.length.(^Expr_Literal)
		if !ok || length_literal.kind != .Int {
			return INVALID_TYPE
		}
		length, fits := parse_int_text(length_literal.text)
		if !fits || length < 0 {
			return INVALID_TYPE
		}
		value.denoted_type = intern_type(k.c, Type_Key{kind = .Array, element = element, count = u64(length)}, Type_Info{kind = .Array, element = element, count = u64(length)})
		value.resolution.kind = .Type
		return value.denoted_type
	case ^Type_Map:
		key := resolve_type_syntax(k, value.key)
		element := resolve_type_syntax(k, value.value)
		if key == INVALID_TYPE || element == INVALID_TYPE {
			return INVALID_TYPE
		}
		value.denoted_type = intern_type(k.c, Type_Key{kind = .Map, key = key, element = element}, Type_Info{kind = .Map, key = key, element = element})
		value.resolution.kind = .Type
		return value.denoted_type
	case ^Type_Distinct:
		// Anonymous distinct syntax is still a fresh identity. A named distinct
		// declaration receives its shell in phase 2a.
		if value.denoted_type == INVALID_TYPE {
			value.denoted_type = new_type(k.c, Type_Info{kind = .Distinct, element = resolve_type_syntax(k, value.elem)})
		}
		value.resolution.kind = .Type
		return value.denoted_type
	case ^Type_Proc:
		params := make([dynamic]Type_Id, 0, len(value.params), k.c.semantic_allocator)
		modes := make([dynamic]Param_Mode, 0, len(value.params), k.c.semantic_allocator)
		for parameter in value.params {
			append(&params, resolve_type_syntax(k, parameter.type))
			append(&modes, parameter.mode)
		}
		results := make([dynamic]Type_Id, 0, len(value.results), k.c.semantic_allocator)
		result_inout := make([dynamic]bool, 0, len(value.results), k.c.semantic_allocator)
		for result in value.results {
			append(&results, resolve_type_syntax(k, result.type))
			append(&result_inout, result.is_inout)
		}
		value.denoted_type = intern_proc_type(k.c, params[:], modes[:], results[:], result_inout[:], value.convention)
		value.resolution.kind = .Type
		return value.denoted_type
	case ^Type_Type:
		value.denoted_type = TYPE_TYPE
		value.resolution.kind = .Type
		return TYPE_TYPE
	}
	return INVALID_TYPE
}

// M1 parses the whole grammar; this checker still only compiles the M0 subset.
// Reporting from the dispatch's default arm — and not descending — is what
// keeps it to one diagnostic per outer construct with no cascade.
@(private = "file")
unsupported_construct :: proc(k: ^Checker, span: Span) {
	errorf(
		k.c,
		span,
		"L0350",
		"this construct parses, but is not compiled yet in this milestone",
	)
}

@(private = "file")
resolve_type_name :: proc(k: ^Checker, d: ^Decl) -> Type_Id {
	if d.declared_type == nil {
		return INVALID_TYPE // inferred
	}
	resolved := resolve_type_syntax(k, d.declared_type)
	if resolved != INVALID_TYPE {
		return resolved
	}
	if syntax, ok := d.declared_type.(^Expr_Ident); ok {
		errorf(k.c, syntax.span, "L0306", "unknown type `%s`", syntax.name)
		return INVALID_TYPE
	}
	unsupported_construct(k, expr_span(d.declared_type))
	return INVALID_TYPE
}

@(private = "file")
check_decl :: proc(k: ^Checker, d: ^Decl) {
	if d.check_state == .Checked {
		return
	}
	if d.check_state == .Checking {
		errorf(k.c, d.span, "L0324", "constant initialisation cycle")
		return
	}
	d.check_state = .Checking
	check_decl_inner(k, d)
	d.check_state = .Checked
}

@(private = "file")
check_decl_inner :: proc(k: ^Checker, d: ^Decl) {
	if literal := decl_proc(d); literal != nil {
		check_proc(k, d, literal)
		return
	}
	if len(d.symbols) == 1 {
		if symbol := symbol_of(k.c, d.symbols[0]); symbol != nil {
			if symbol.kind == .Type || symbol.kind == .Proc_Group {
				unsupported_construct(k, d.span)
				return
			}
		}
	}
	if d.duration != .None || d.manual || d.via != nil {
		unsupported_construct(k, d.span)
		return
	}

	declared := resolve_type_name(k, d)

	if len(d.values) == 0 {
		if d.kind == .Const {
			errorf(k.c, d.span, "L0307", "a constant needs an initialiser")
		}
		assign_symbol_types(k.c, d, declared == INVALID_TYPE ? TYPE_INT : declared)
		return
	}
	if len(d.values) != len(d.names) {
		errorf(
			k.c,
			d.span,
			"L0308",
			"%d name%s but %d initialiser%s",
			len(d.names),
			len(d.names) == 1 ? "" : "s",
			len(d.values),
			len(d.values) == 1 ? "" : "s",
		)
	}

	for value, i in d.values {
		if value == nil {
			continue
		}
		type := check_expr(k, value)
		if type == TYPE_VOID {
			errorf(k.c, expr_span(value), "L0309", "this expression produces no value")
			type = INVALID_TYPE
		}

		if declared != INVALID_TYPE && type != INVALID_TYPE && !assignable(type, declared) {
			errorf(
				k.c,
				expr_span(value),
				"L0310",
				"cannot initialise `%s` with `%s`",
				type_name(k.c, declared),
				type_name(k.c, type),
			)
		}

		if d.top_level && d.kind == .Var && !is_const_expr(value) {
			errorf(
				k.c,
				expr_span(value),
				"L0325",
				"a file-scope initializer must be a compile-time constant",
			)
		}

		final := declared != INVALID_TYPE ? declared : default_type(type)
		if i < len(d.symbols) && d.symbols[i] != INVALID_SYMBOL {
			sym := symbol_of(k.c, d.symbols[i])
			sym.type = final
			if d.kind == .Const {
				if type != INVALID_TYPE && !is_const_expr(value) {
					errorf(
						k.c,
						expr_span(value),
						"L0311",
						"a constant initialiser must be a compile-time constant",
					)
				}
				if is_const_expr(value) {
					sym.const_value = expr_base(value).const_value
				}
			}
		}
	}
}

@(private = "file")
assign_symbol_types :: proc(c: ^Compiler, d: ^Decl, type: Type_Id) {
	for symbol_id in d.symbols {
		if sym := symbol_of(c, symbol_id); sym != nil {
			sym.type = type
		}
	}
}

@(private = "file")
check_proc :: proc(k: ^Checker, d: ^Decl, literal: ^Expr_Proc) {
	if len(d.names) != 1 {
		errorf(k.c, d.span, "L0312", "a procedure declaration binds exactly one name")
	}

	signature := literal.signature
	if literal.bodiless ||
	   len(literal.where_clauses) > 0 ||
	   signature == nil ||
	   signature.convention != "" ||
	   len(signature.params) > 0 ||
	   len(signature.results) > 0 {
		unsupported_construct(k, literal.span)
		return
	}

	outer := k.scope
	k.scope = new_scope(k.c, outer, .Procedure)
	if signature != nil {
		for parameter in signature.params {
			install_symbols(k.scope, k.c, parameter.symbols)
		}
		for result in signature.results {
			install_symbols(k.scope, k.c, result.symbols)
		}
	}
	check_block(k, literal.body)
	k.scope = outer
}

@(private = "file")
check_block :: proc(k: ^Checker, b: ^Block) {
	if b == nil {
		return
	}
	for stmt in b.stmts {
		#partial switch s in stmt {
		case ^Stmt_Error:
			// Parser diagnostics already describe this retained recovery node.
		case ^Decl:
			install_symbols(k.scope, k.c, s.symbols)
			check_decl(k, s)
		case ^Stmt_Expr:
			for expr in s.exprs {
				if _, is_call := expr.(^Expr_Call); !is_call && expr != nil {
					errorf(k.c, expr_span(expr), "L0313", "this expression statement has no effect")
				}
				check_expr(k, expr)
			}
		case ^Stmt_Return:
			// `main` has no results, so a bare `return;` is valid; a value is not.
			if len(s.values) > 0 {
				unsupported_construct(k, s.span)
			}
		case ^Block:
			outer := k.scope
			k.scope = new_scope(k.c, outer, .Local)
			check_block(k, s)
			k.scope = outer
		case:
			unsupported_construct(k, stmt_span(stmt))
		}
	}
}

// `untyped int` materialises as `int`, its default type (design.md "Untyped
// types").
@(private = "file")
default_type :: proc(t: Type_Id) -> Type_Id {
	return t == TYPE_UNTYPED_INT ? TYPE_INT : t
}

@(private = "file")
assignable :: proc(from: Type_Id, to: Type_Id) -> bool {
	if from == to {
		return true
	}
	return from == TYPE_UNTYPED_INT && to == TYPE_INT
}

@(private = "file")
is_numeric :: proc(t: Type_Id) -> bool {
	return t == TYPE_INT || t == TYPE_UNTYPED_INT
}

// Constness lives on Expr_Base, which every node embeds, so these need no
// per-node switch: a node the checker never folded is simply not constant.
is_const_expr :: proc(e: Expr) -> bool {
	base := expr_base(e)
	return base != nil && base.is_const
}

const_value_of :: proc(e: Expr) -> i64 {
	base := expr_base(e)
	return base == nil || base.const_value.kind != .Integer ? 0 : base.const_value.integer
}

@(private = "file")
check_expr :: proc(k: ^Checker, e: Expr) -> Type_Id {
	if e == nil {
		return INVALID_TYPE
	}

	#partial switch v in e {
	case ^Expr_Error:
		v.type = INVALID_TYPE
		return INVALID_TYPE

	case ^Expr_Literal:
		if v.kind != .Int {
			unsupported_construct(k, v.span)
			v.type = INVALID_TYPE
			return v.type
		}
		// Representability is a semantic question, so the parser kept the
		// spelling and this is where it is asked. Renumbered out of the parser's
		// L02xx block along with the move; nothing referenced the old L0218.
		value, fits := parse_int_text(v.text)
		if !fits {
			errorf(k.c, v.span, "L0351", "integer literal does not fit in `int`")
		}
		v.type = TYPE_UNTYPED_INT
		v.is_const = true
		v.const_value = integer_const(value)
		return v.type

	case ^Expr_Ident:
		name_id := v.name_id
		if name_id == INVALID_IDENTIFIER {
			name_id = intern_identifier(k.c, v.name)
			v.name_id = name_id
		}
		symbol_id := v.symbol
		if symbol_id == INVALID_SYMBOL && v.resolution.kind != .Error {
			symbol_id = lookup_symbol(k.scope, name_id)
		}
		sym := symbol_of(k.c, symbol_id)
		if sym == nil {
			if v.resolution.kind != .Error {
				if v.name == "_" {
					errorf(k.c, v.span, "L0314", "`_` cannot be read")
				} else {
					errorf(k.c, v.span, "L0315", "unknown name `%s`", v.name)
				}
			}
			v.type = INVALID_TYPE
			return v.type
		}
		if sym.kind == .Const && sym.decl != nil {
			switch sym.decl.check_state {
			case .Unchecked:
				check_decl(k, sym.decl)
			case .Checking:
				errorf(k.c, v.span, "L0324", "constant initialisation cycle involving `%s`", v.name)
				v.type = INVALID_TYPE
				return v.type
			case .Checked:
			}
		}
		v.symbol = symbol_id
		v.resolution = Resolution{kind = .Value, symbol = symbol_id}
		if sym.kind == .Proc || sym.kind == .Builtin {
			// Only legal as a callee; Expr_Call handles that case itself.
			errorf(k.c, v.span, "L0316", "`%s` is a procedure and must be called", v.name)
			v.type = INVALID_TYPE
			return v.type
		}
		v.type = sym.type
		v.value_category = sym.kind == .Var ? .Place : .Value
		if sym.kind == .Const {
			v.is_const = true
			v.const_value = sym.const_value
		}
		return v.type

	case ^Expr_Unary:
		if v.op != .Plus && v.op != .Minus {
			unsupported_construct(k, v.span)
			v.type = INVALID_TYPE
			return v.type
		}
		operand := check_expr(k, v.operand)
		if operand != INVALID_TYPE && !is_numeric(operand) {
			errorf(
				k.c,
				v.op_span,
				"L0317",
				"`%s` does not apply to `%s`",
				v.op == .Minus ? "-" : "+",
				type_name(k.c, operand),
			)
			v.type = INVALID_TYPE
			return v.type
		}
		v.type = operand
		if is_const_expr(v.operand) {
			v.is_const = true
			v.const_value = integer_const(v.op == .Minus ? -const_value_of(v.operand) : const_value_of(v.operand))
		}
		return v.type

	case ^Expr_Binary:
		if !is_m0_operator(v.op) {
			unsupported_construct(k, v.span)
			v.type = INVALID_TYPE
			return v.type
		}
		lhs := check_expr(k, v.lhs)
		rhs := check_expr(k, v.rhs)
		v.resolution.kind = .Builtin_Operator
		if lhs == INVALID_TYPE || rhs == INVALID_TYPE {
			v.type = INVALID_TYPE
			return v.type
		}
		if !is_numeric(lhs) || !is_numeric(rhs) {
			errorf(
				k.c,
				v.op_span,
				"L0318",
				"`%s` does not apply to `%s` and `%s`",
				operator_text(v.op),
				type_name(k.c, lhs),
				type_name(k.c, rhs),
			)
			v.type = INVALID_TYPE
			return v.type
		}
		if v.op == .Shl || v.op == .Shr {
			if rhs != TYPE_UNTYPED_INT || !is_const_expr(v.rhs) || const_value_of(v.rhs) < 0 {
				errorf(
					k.c,
					v.op_span,
					"L0326",
					"the M0 shift count must be a non-negative untyped constant",
				)
				v.type = INVALID_TYPE
				return v.type
			}
		}
		// One untyped operand takes the other's type; two stay untyped.
		v.type = (lhs == TYPE_UNTYPED_INT && rhs == TYPE_UNTYPED_INT) ? TYPE_UNTYPED_INT : TYPE_INT

		if is_const_expr(v.lhs) && is_const_expr(v.rhs) {
			a, b := const_value_of(v.lhs), const_value_of(v.rhs)
			if (v.op == .Slash || v.op == .Percent) && b == 0 {
				errorf(k.c, v.op_span, "L0319", "division by zero")
				v.type = INVALID_TYPE
				return v.type
			}
			v.is_const = true
			v.const_value = integer_const(fold(v.op, a, b))
		}
		return v.type

	case ^Expr_Call:
		callee, is_ident := v.callee.(^Expr_Ident)
		if !is_ident {
			errorf(k.c, expr_span(v.callee), "L0320", "this expression is not callable")
			v.type = INVALID_TYPE
			return v.type
		}
		name_id := callee.name_id
		if name_id == INVALID_IDENTIFIER {
			name_id = intern_identifier(k.c, callee.name)
			callee.name_id = name_id
		}
		symbol_id := callee.symbol
		if symbol_id == INVALID_SYMBOL && callee.resolution.kind != .Error {
			symbol_id = lookup_symbol(k.scope, name_id)
		}
		sym := symbol_of(k.c, symbol_id)
		if sym == nil {
			if callee.resolution.kind != .Error {
				errorf(k.c, callee.span, "L0315", "unknown name `%s`", callee.name)
			}
			v.type = INVALID_TYPE
			return v.type
		}
		callee.symbol = symbol_id
		callee.resolution = Resolution{kind = .Value, symbol = symbol_id}
		v.resolution = Resolution{kind = .Call, symbol = symbol_id, chosen_overload = symbol_id}
		if sym.kind != .Proc && sym.kind != .Builtin {
			errorf(k.c, callee.span, "L0321", "`%s` is not a procedure", callee.name)
			v.type = INVALID_TYPE
			return v.type
		}

		if len(v.args) != len(sym.params) {
			errorf(
				k.c,
				v.span,
				"L0322",
				"`%s` takes %d argument%s, found %d",
				callee.name,
				len(sym.params),
				len(sym.params) == 1 ? "" : "s",
				len(v.args),
			)
		}
		for arg, i in v.args {
			if arg.name.text != "" || arg.mode != .Value {
				unsupported_construct(k, arg.span)
				continue
			}
			type := check_expr(k, arg.value)
			if i < len(sym.params) && type != INVALID_TYPE && !assignable(type, sym.params[i]) {
				errorf(
					k.c,
					expr_span(arg.value),
					"L0323",
					"expected `%s`, found `%s`",
					type_name(k.c, sym.params[i]),
					type_name(k.c, type),
				)
			}
		}
		v.type = sym.type
		return v.type
	}

	// Every other node the parser can now build: named, and not descended into.
	unsupported_construct(k, expr_span(e))
	if base := expr_base(e); base != nil {
		base.type = INVALID_TYPE
	}
	return INVALID_TYPE
}

// The binary operators this milestone compiles. The rest parse and are gated
// above rather than silently folded as arithmetic.
@(private = "file")
is_m0_operator :: proc(op: Token_Kind) -> bool {
	#partial switch op {
	case .Plus, .Minus, .Pipe, .Tilde, .Star, .Slash, .Percent, .Amp, .Amp_Tilde, .Shl, .Shr:
		return true
	}
	return false
}

// Decodes an integer literal per grammar.md: decimal, or a `0b`/`0o`/`0x`
// prefix, with `_` allowed as a separator anywhere but the first character.
@(private = "file")
parse_int_text :: proc(text: string) -> (value: i64, ok: bool) {
	base := i64(10)
	digits := text
	if len(text) > 2 && text[0] == '0' {
		switch text[1] {
		case 'b':
			base, digits = 2, text[2:]
		case 'o':
			base, digits = 8, text[2:]
		case 'x':
			base, digits = 16, text[2:]
		}
	}

	for ch in transmute([]u8)digits {
		if ch == '_' {
			continue
		}
		digit: i64
		switch {
		case ch >= '0' && ch <= '9':
			digit = i64(ch - '0')
		case ch >= 'a' && ch <= 'f':
			digit = i64(ch-'a') + 10
		case ch >= 'A' && ch <= 'F':
			digit = i64(ch-'A') + 10
		}
		next := value*base + digit
		if next < value {
			return 0, false // overflowed i64
		}
		value = next
	}
	return value, true
}

@(private = "file")
fold :: proc(op: Token_Kind, a: i64, b: i64) -> i64 {
	#partial switch op {
	case .Plus:
		return a + b
	case .Minus:
		return a - b
	case .Star:
		return a * b
	case .Slash:
		if a == min(i64) && b == -1 {
			return min(i64)
		}
		return a / b
	case .Percent:
		if a == min(i64) && b == -1 {
			return 0
		}
		return a % b
	case .Amp:
		return a & b
	case .Pipe:
		return a | b
	case .Tilde:
		return a ~ b
	case .Amp_Tilde:
		return a &~ b
	case .Shl:
		if b >= 64 {
			return 0
		}
		return a << u64(b)
	case .Shr:
		if b >= 64 {
			return a < 0 ? -1 : 0
		}
		return a >> u64(b)
	}
	return 0
}

operator_text :: proc(op: Token_Kind) -> string {
	#partial switch op {
	case .Plus:
		return "+"
	case .Minus:
		return "-"
	case .Star:
		return "*"
	case .Slash:
		return "/"
	case .Percent:
		return "%"
	case .Amp:
		return "&"
	case .Pipe:
		return "|"
	case .Tilde:
		return "~"
	case .Amp_Tilde:
		return "&~"
	case .Shl:
		return "<<"
	case .Shr:
		return ">>"
	}
	return "?"
}

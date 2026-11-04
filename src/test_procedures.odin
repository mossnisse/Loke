// design.md "Test procedures": `@(test)` declarations, checked in every build
// and called only by a test build's entry.
package lokec

// A test procedure is a file-scope, non-generic `loke` procedure with the
// signature `main` may have, less the `i32` status. Its attribute's position
// and shape are `validate_attribute_list`'s.
check_test_procedures :: proc(k: ^Checker, pkg: ^Package) {
	for file in pkg.files {
		for item in file.active_items {
			if d, ok := item.(^Decl); ok {
				check_test_declaration(k, d)
			}
		}
	}
}

@(private = "file")
check_test_declaration :: proc(k: ^Checker, d: ^Decl) {
	attribute, written := find_attribute(d.attributes, "test")
	if !written || len(d.symbols) != 1 {
		return
	}
	symbol := symbol_of(k.c, d.symbols[0])
	if symbol == nil || symbol.kind != .Proc {
		return
	}
	if declaration_generic_kind(d) != .None {
		errorf(k.c, attribute.span, "L0615", "a test procedure cannot be generic: the test build has nothing to instantiate it with")
		return
	}
	info := type_of(k.c, symbol.proc_type)
	if info == nil {
		return
	}
	if len(info.parameters) != 0 || (info.result != INVALID_TYPE && !entry_result_is_fallible(k.c, info.result)) {
		errorf(
			k.c, symbol.span, "L0615",
			"a test procedure takes no parameters and returns nothing or a fallible union such as `Status(E)`: `%s`",
			"parses_digits :: proc() { ... }",
		)
	} else if info.result_inout || convention_is_foreign(info.convention) || has_attribute(d.attributes, "export") {
		errorf(k.c, symbol.span, "L0615", "a test procedure is an ordinary `loke` procedure, called only by the test build")
	}
}

// design.md "Test procedures": a use of the name is an error, so the test
// build's entry is the only caller and other builds can leave the body out.
reject_test_procedure_use :: proc(k: ^Checker, symbol: ^Symbol, name: string, span: Span) -> bool {
	if !symbol_is_test(symbol) {
		return false
	}
	errorf(k.c, span, "L0616", "`%s` is a test procedure, which only a test build calls", name)
	return true
}

// Read from the attribute: a file-scope `when` condition is selected before any
// signature is resolved.
symbol_is_test :: proc(symbol: ^Symbol) -> bool {
	return symbol.kind == .Proc && symbol.decl != nil && has_attribute(symbol.decl.attributes, "test")
}

// The root package's tests, in file-name order and then source order, which
// the test entry runs and the runner names. A fallible test's failure is
// printed by its type, as a failing `main`'s is.
collect_tests :: proc(c: ^Compiler, root: Package_Id) {
	clear(&c.tests)
	pkg := package_of(c, root)
	if pkg == nil {
		return
	}
	for file in pkg.files {
		for item in file.active_items {
			d, is_decl := item.(^Decl)
			if !is_decl || len(d.symbols) != 1 {
				continue
			}
			symbol := symbol_of(c, d.symbols[0])
			if symbol == nil || !symbol_is_test(symbol) {
				continue
			}
			append(&c.tests, d.symbols[0])
			request_entry_failure_printing(c, symbol.result)
		}
	}
}

// design.md "Test procedures": whether the backend leaves this out: a test the
// build omits, anything written inside one at any depth, or what only such a
// test can reach, an instance on a type declared inside it. That instance's own
// scope is the template's, so nothing but its arguments ties it to the test.
omitted_with_test :: proc(c: ^Compiler, symbol_id: Symbol_Id) -> bool {
	seen: Type_Walk
	defer delete(seen)
	return symbol_omitted_with_test(c, symbol_id, &seen)
}

// One walk throughout: `Grid { next: Option(^Grid) }` reaches its own instance's
// arguments again.
@(private = "file")
symbol_omitted_with_test :: proc(c: ^Compiler, symbol_id: Symbol_Id, seen: ^Type_Walk) -> bool {
	symbol := symbol_of(c, symbol_id)
	if symbol == nil {
		return false
	}
	if symbol_is_test(symbol) && (c.build_mode != .Test || symbol.pkg != c.root_package) {
		return true
	}
	for scope := symbol.def_scope; scope != nil; scope = scope.parent {
		if scope.instance == nil {
			continue
		}
		for binding in scope.instance.bindings {
			if generic_arg_names_omitted_test(c, binding.arg, seen) {
				return true
			}
		}
	}
	if symbol.def_scope == nil || symbol.def_scope.owner_proc == nil {
		return false
	}
	return symbol_omitted_with_test(c, (^Expr_Proc)(symbol.def_scope.owner_proc).symbol, seen)
}

@(private = "file")
generic_arg_names_omitted_test :: proc(c: ^Compiler, arg: Generic_Arg, seen: ^Type_Walk) -> bool {
	return type_names_omitted_test(c, arg.is_type ? arg.type : arg.value_type, seen)
}

@(private = "file")
type_names_omitted_test :: proc(c: ^Compiler, id: Type_Id, seen: ^Type_Walk) -> bool {
	info := type_of(c, id)
	if info == nil || !type_walk_enter(seen, id, info) {
		return false
	}
	if symbol_omitted_with_test(c, info.symbol, seen) {
		return true
	}
	#partial switch info.kind {
	case .Struct:
		for field in info.fields {
			if sym := symbol_of(c, field); sym != nil && type_names_omitted_test(c, sym.type, seen) {
				return true
			}
		}
	case .Union:
		for variant in info.variants {
			if type_names_omitted_test(c, variant, seen) {
				return true
			}
		}
	case .Proc:
		for parameter in info.parameters {
			if type_names_omitted_test(c, parameter, seen) {
				return true
			}
		}
		return type_names_omitted_test(c, info.result, seen)
	case .Dyn:
		for arg in info.dyn_args {
			if generic_arg_names_omitted_test(c, arg, seen) {
				return true
			}
		}
		return symbol_omitted_with_test(c, info.dyn_interface, seen)
	case .Map:
		return type_names_omitted_test(c, info.key, seen) || type_names_omitted_test(c, info.element, seen)
	case .Pointer, .C_Pointer, .Slice, .Dynamic_Array, .Box, .Array, .Simd, .Distinct:
		return type_names_omitted_test(c, info.element, seen)
	}
	return false
}

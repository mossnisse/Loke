// design.md "Test procedures": `@(test)` declarations, checked in every build
// and called only by a test build's entry.
package lokec

// A test procedure is a file-scope, non-generic `loke` procedure with the
// signature `main` may have, less the `i32` status. Its attribute's position
// and shape are `validate_attribute_list`'s.
check_test_procedures :: proc(k: ^Checker, pkg: ^Package) {
	for file in pkg.files {
		k.file, k.file_node = file.file, file
		for item in file.active_items {
			#partial switch v in item {
			case ^Decl:
				check_test_declaration(k, v)
			case ^Item_Impl:
				for member in v.members {
					if d, ok := member.(^Decl); ok {
						reject_test_attribute(k, d.attributes, "an `impl` member")
					}
				}
			case ^Item_Foreign_Block:
				for member in v.members {
					if d, ok := member.(^Decl); ok {
						reject_test_attribute(k, d.attributes, "a foreign declaration")
					}
				}
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

@(private = "file")
reject_test_attribute :: proc(k: ^Checker, attributes: []Attribute, position: string) {
	if attribute, written := find_attribute(attributes, "test"); written {
		errorf(k.c, attribute.span, "L0607", "`@(test)` cannot appear on %s", position)
	}
}

// design.md "Test procedures": a use of the name is an error, so the test
// build's entry is the only caller and other builds can leave the body out.
reject_test_procedure_use :: proc(k: ^Checker, symbol: ^Symbol, name: string, span: Span) -> bool {
	if !symbol.is_test {
		return false
	}
	errorf(k.c, span, "L0616", "`%s` is a test procedure, which only a test build calls", name)
	return true
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
			if symbol == nil || !symbol.is_test {
				continue
			}
			append(&c.tests, d.symbols[0])
			if failure, fallible := entry_failure_type(c, symbol.result); fallible {
				request_typeid(c, failure)
				c.format_requested = true
			}
		}
	}
}

// Whether the backend writes this procedure's body: a test procedure only in a
// test build of its own package.
test_procedure_emitted :: proc(c: ^Compiler, symbol: ^Symbol) -> bool {
	return symbol == nil || !symbol.is_test || (c.build_mode == .Test && symbol.pkg == c.root_package)
}

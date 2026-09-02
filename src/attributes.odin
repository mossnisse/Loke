// Attribute discipline (m7-plan step 1, decision "Attribute discipline").
//
// One table maps every attribute design.md defines to the positions it may
// appear in and the value shape it takes. Before M7 attributes were parsed and
// mostly ignored, so a typo was silent; this pass gives an unknown name, an
// unknown namespace, a misplaced attribute, and a wrong value shape each their
// own diagnostic. `@(deprecated)` and `@(require_results)` also gain behaviour
// here (flags set in `resolve_declaration_signature`).
//
// Record-layout value validation (power-of-two `@(align=N)`) stays with its own
// feature: `union @(align=N)` is validated in `src/union.odin`.
package lokec

Attr_Pos :: enum {
	Package_Clause,
	Proc_Decl,
	Proc_Group,
	Var_Decl,
	Const_Decl,
	Type_Decl,
	Struct_Field,
	Parameter,
	Struct_Literal,
	Union_Literal,
	Foreign_Block,
	Static_Assert,
}

Attr_Shape :: enum {
	None,           // `@(name)`, no value
	Value_Required, // `@(name=value)`
	Deferred,       // value validated by the owning feature (e.g. `@(align=N)`)
}

Attr_Spec :: struct {
	positions: bit_set[Attr_Pos],
	shape:     Attr_Shape,
}

// design.md "Attributes" and "Layout and ABI attributes". Every base-language
// attribute, with where it may appear and the value it takes.
attribute_spec :: proc(name: string) -> (Attr_Spec, bool) {
	// Keep this lookup allocation-free. Compiler instances carry their own
	// allocators, so a lazily initialized static map would retain storage owned
	// by whichever instance reached it first and would also race in parallel
	// test runs.
	switch name {
	case "public":
		return {{.Package_Clause, .Proc_Decl, .Proc_Group, .Var_Decl, .Const_Decl, .Type_Decl, .Struct_Field, .Foreign_Block}, .None}, true
	case "private":
		return {{.Proc_Decl, .Proc_Group, .Var_Decl, .Const_Decl, .Type_Decl, .Struct_Field, .Foreign_Block}, .None}, true
	case "require_results":
		// design.md "Required results": on a type declaration the property is
		// carried by the *type*, so every value of it is checked, not just the
		// procedures declared beside it.
		return {{.Proc_Decl, .Proc_Group, .Foreign_Block, .Type_Decl}, .None}, true
	case "deprecated":
		return {{.Proc_Decl}, .Value_Required}, true
	case "export":
		return {{.Proc_Decl, .Var_Decl}, .None}, true
	case "implicit":
		return {{.Proc_Decl}, .None}, true
	case "link_name":
		return {{.Proc_Decl, .Var_Decl}, .Value_Required}, true
	case "default_calling_convention":
		return {{.Foreign_Block}, .Value_Required}, true
	case "allocator_reset":
		return {{.Parameter}, .None}, true
	case "escape":
		// The level is a bare identifier rather than a string, so the value shape
		// is validated by `check_escape_attribute` with the rest of the rule.
		return {{.Parameter}, .Deferred}, true
	case "by_ptr":
		return {{.Parameter}, .None}, true
	case "c_vararg":
		return {{.Parameter}, .None}, true
	case "packed":
		return {{.Struct_Literal}, .None}, true
	case "align":
		return {{.Struct_Literal, .Union_Literal}, .Deferred}, true
	case "zero", "failure":
		// The value is a bare variant name rather than a string, so the shape is
		// validated by `src/union.odin` against the union's own variant list.
		return {{.Union_Literal}, .Deferred}, true
	}
	return {}, false
}

attr_pos_name :: proc(pos: Attr_Pos) -> string {
	switch pos {
	case .Package_Clause: return "a package clause"
	case .Proc_Decl:      return "a procedure declaration"
	case .Proc_Group:     return "a procedure group"
	case .Var_Decl:       return "a variable declaration"
	case .Const_Decl:     return "a constant declaration"
	case .Type_Decl:      return "a type declaration"
	case .Struct_Field:   return "a struct field"
	case .Parameter:      return "a parameter"
	case .Struct_Literal: return "a struct type"
	case .Union_Literal:  return "a union type"
	case .Foreign_Block:  return "a foreign block"
	case .Static_Assert:  return "a `static_assert`"
	}
	return "here"
}

// Validates one attribute list against its position. Diagnostics only —
// behaviour (deprecation warnings, required-result errors, layout) is applied
// by the owning feature.
validate_attribute_list :: proc(k: ^Checker, attributes: []Attribute, pos: Attr_Pos) {
	seen := make(map[string]bool, len(attributes), context.temp_allocator)
	for attribute in attributes {
		if len(attribute.path) == 0 {
			continue
		}
		// A namespaced attribute is an extension attribute; no toolchain extension
		// is enabled in v1, so every one is an error naming its namespace.
		if len(attribute.path) > 1 {
			errorf(
				k.c, attribute.span, "L0610",
				"`@(%s.%s)` is an extension attribute; its `%s` namespace is not enabled",
				attribute.path[0].text, attribute.path[1].text, attribute.path[0].text,
			)
			continue
		}
		name := attribute.path[0].text
		spec, known := attribute_spec(name)
		if !known {
			errorf(k.c, attribute.span, "L0606", "unknown attribute `@(%s)`", name)
			continue
		}
		if seen[name] {
			errorf(k.c, attribute.span, "L0609", "`@(%s)` is written more than once here", name)
			continue
		}
		seen[name] = true
		if pos not_in spec.positions {
			errorf(
				k.c, attribute.span, "L0607",
				"`@(%s)` cannot appear on %s", name, attr_pos_name(pos),
			)
			continue
		}
		switch spec.shape {
		case .None:
			if attribute.value != nil {
				errorf(k.c, attribute.span, "L0608", "`@(%s)` takes no value", name)
			}
		case .Value_Required:
			if attribute.value == nil {
				errorf(k.c, attribute.span, "L0608", "`@(%s)` needs a value: `@(%s=...)`", name, name)
			} else if lit, ok := attribute.value.(^Expr_Literal); !ok ||
			          (lit.kind != .String && lit.kind != .Raw_String) {
				// Every base-language value-bearing attribute currently takes a
				// string; checking the literal kind here stops a malformed value from
				// silently being treated as if the attribute were absent.
				errorf(k.c, attribute.span, "L0608", "`@(%s)` needs a string value", name)
			}
		case .Deferred:
		}
	}
}

// The whole-package attribute pass, run once over the settled item view.
// Visits every attribute-bearing node the checker owns in step 1: the package
// clause, top-level declarations, procedure parameters, record type literals
// with their fields, and foreign blocks with theirs (step 4).
validate_attributes :: proc(k: ^Checker, pkg: ^Package) {
	for file in pkg.files {
		k.file, k.file_node = file.file, file
		validate_attribute_list(k, file.attributes, .Package_Clause)
		for item in file.active_items {
			#partial switch v in item {
			case ^Decl:
				validate_decl_attributes(k, v)
			case ^Item_Impl:
				for member in v.members {
					if d, ok := member.(^Decl); ok {
						validate_decl_attributes(k, d)
					}
				}
			case ^Item_Static_Assert:
				// No attribute lists this position, so every one written here is
				// reported as misplaced by the ordinary table lookup.
				validate_attribute_list(k, v.attributes, .Static_Assert)
			case ^Item_Foreign_Block:
				validate_attribute_list(k, v.attributes, .Foreign_Block)
				for member in v.members {
					if d, ok := member.(^Decl); ok {
						validate_decl_attributes(k, d)
					}
				}
			}
		}
	}
}

validate_decl_attributes :: proc(k: ^Checker, d: ^Decl) {
	if len(d.symbols) == 0 {
		return
	}
	pos := decl_attr_position(k, d)
	validate_attribute_list(k, d.attributes, pos)

	// A procedure's parameters carry `@(allocator_reset)`, `@(by_ptr)`, and
	// `@(c_vararg)`.
	if literal := decl_proc_literal(d); literal != nil {
		for param in literal.signature.params {
			validate_attribute_list(k, param.attributes, .Parameter)
		}
	}

	// A record type declaration carries `@(packed)`/`@(align=N)` on the literal
	// and `@(public)`/`@(private)` on each field.
	if len(d.values) == 1 {
		if record, ok := d.values[0].(^Type_Record); ok {
			literal_pos := record.kind == .Struct ? Attr_Pos.Struct_Literal : Attr_Pos.Union_Literal
			validate_attribute_list(k, record.attributes, literal_pos)
			for field in record.fields {
				validate_attribute_list(k, field.attributes, .Struct_Field)
			}
		}
	}
}

@(private = "file")
decl_attr_position :: proc(k: ^Checker, d: ^Decl) -> Attr_Pos {
	if sym := symbol_of(k.c, d.symbols[0]); sym != nil {
		#partial switch sym.kind {
		case .Proc:       return .Proc_Decl
		case .Proc_Group: return .Proc_Group
		case .Type:       return .Type_Decl
		case .Const:      return .Const_Decl
		}
	}
	return d.kind == .Const ? .Const_Decl : .Var_Decl
}

// design.md "@(deprecated)" and "@(require_results)": records the two pieces
// of declaration metadata on the symbol, from the declaration's attributes.
// Called from `resolve_declaration_signature`, so a cross-package use already
// sees the flag before its own body is checked.
apply_proc_metadata :: proc(k: ^Checker, d: ^Decl, symbol_id: Symbol_Id) {
	sym := symbol_of(k.c, symbol_id)
	if sym == nil {
		return
	}
	for attribute in d.attributes {
		if len(attribute.path) != 1 {
			continue
		}
		switch attribute.path[0].text {
		case "deprecated":
			sym.deprecated = true
			if lit, ok := attribute.value.(^Expr_Literal); ok && (lit.kind == .String || lit.kind == .Raw_String) {
				if text, decoded := decode_string_literal(k.c, lit.text, lit.kind == .Raw_String); decoded {
					sym.deprecated_message = text
				}
			}
		case "require_results":
			sym.require_results = true
		}
	}
}

// Attribute discipline: one table of every attribute design.md defines, with the
// positions it may appear in and the value shape it takes. Behaviour lives with
// the owning feature; this file only reports misuse.
package lokec

import "core:strings"

Attr_Pos :: enum {
	Package_Clause,
	Import,
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
	Delegate,
	Impl,
	Statement,
}

// Where a declaration's attribute list sits, for the rules the position alone
// cannot express.
Attr_Scope :: enum {
	Global,
	Local,   // inside a body: no linkage or visibility
	Foreign, // a foreign block member: `@(link_name)` needs no `@(export)`
}

Attr_Shape :: enum {
	None,           // `@(name)`
	Value_Required, // `@(name="...")`
	Deferred,       // the owning feature validates the value
}

Attr_Spec :: struct {
	positions:   bit_set[Attr_Pos],
	shape:       Attr_Shape,
	global_only: bool,
}

// design.md "Attributes" and "Layout and ABI attributes". A switch rather than a
// map, so the lookup allocates nothing and shares nothing between compilers.
attribute_spec :: proc(name: string) -> (Attr_Spec, bool) {
	switch name {
	case "public":
		return {{.Package_Clause, .Proc_Decl, .Proc_Group, .Var_Decl, .Const_Decl, .Type_Decl, .Struct_Field, .Foreign_Block}, .None, true}, true
	case "private":
		return {{.Proc_Decl, .Proc_Group, .Var_Decl, .Const_Decl, .Type_Decl, .Struct_Field, .Foreign_Block}, .None, true}, true
	case "default_allocator", "default_logger":
		// Also read before import discovery by `collect_source_provider_defaults`.
		return {{.Package_Clause}, .Value_Required, false}, true
	case "require_results":
		return {{.Proc_Decl, .Proc_Group, .Foreign_Block, .Type_Decl}, .None, false}, true
	case "deprecated":
		return {{.Proc_Decl}, .Value_Required, false}, true
	case "export":
		return {{.Proc_Decl, .Var_Decl}, .None, true}, true
	case "link_name":
		return {{.Proc_Decl, .Var_Decl}, .Value_Required, true}, true
	case "default_calling_convention":
		return {{.Foreign_Block}, .Value_Required, false}, true
	case "allocator_reset", "by_ptr", "c_vararg":
		return {{.Parameter}, .None, false}, true
	case "escape":
		// A bare level identifier, checked by `check_escape_attribute`.
		return {{.Parameter}, .Deferred, false}, true
	case "packed":
		return {{.Struct_Literal}, .None, false}, true
	case "align":
		return {{.Struct_Literal, .Union_Literal}, .Deferred, false}, true
	case "initialized":
		// A sibling field name, checked by `resolve_uninitialized_fields`.
		return {{.Struct_Field}, .Deferred, false}, true
	case "zero", "failure":
		// A variant name, checked in `src/union.odin`.
		return {{.Union_Literal}, .Deferred, false}, true
	}
	return {}, false
}

attr_pos_name :: proc(pos: Attr_Pos) -> string {
	switch pos {
	case .Package_Clause: return "a package clause"
	case .Import:         return "an import"
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
	case .Delegate:       return "a `delegate`"
	case .Impl:           return "an `impl` block"
	case .Statement:      return "a statement"
	}
	return "here"
}

// Reports each misuse in one attribute list, once per written list: generic
// instances and static foreach copies share the spans, so they are skipped.
validate_attribute_list :: proc(k: ^Checker, attributes: []Attribute, pos: Attr_Pos, scope := Attr_Scope.Global) {
	if len(attributes) == 0 {
		return
	}
	// A speculative check discards its diagnostics, so it must not claim the list.
	if k.c.speculation_depth == 0 {
		first := attributes[0].span
		key := u64(first.file) << 32 | u64(first.lo)
		if k.c.validated_attributes[key] {
			return
		}
		k.c.validated_attributes[key] = true
	}
	seen := make(map[string]bool, len(attributes), context.temp_allocator)
	for attribute in attributes {
		if len(attribute.path) == 0 {
			continue
		}
		// No toolchain extension is enabled in v1.
		if len(attribute.path) > 1 {
			names := make([]string, len(attribute.path), context.temp_allocator)
			for part, index in attribute.path {
				names[index] = part.text
			}
			errorf(
				k.c, attribute.span, "L0610",
				"`@(%s)` is an extension attribute; its `%s` namespace is not enabled",
				strings.join(names, ".", context.temp_allocator), names[0],
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
			errorf(k.c, attribute.span, "L0607", "`@(%s)` cannot appear on %s", name, attr_pos_name(pos))
			continue
		}
		if scope == .Local && spec.global_only {
			errorf(k.c, attribute.span, "L0607", "`@(%s)` cannot appear on a local declaration", name)
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
				errorf(k.c, attribute.span, "L0608", "`@(%s)` needs a string value", name)
			}
		case .Deferred:
		}
	}
	// design.md: `@(link_name)` names an exported or foreign symbol.
	if scope == .Global && (pos == .Proc_Decl || pos == .Var_Decl) && seen["link_name"] && !seen["export"] {
		for attribute in attributes {
			if len(attribute.path) == 1 && attribute.path[0].text == "link_name" {
				errorf(
					k.c, attribute.span, "L0607",
					"`@(link_name)` names a linked symbol, so it needs `@(export)` outside a foreign block",
				)
			}
		}
	}
}

// The whole-package pass. Record literals and parameters nested anywhere are
// also validated where they resolve (`resolve_type_syntax`, the signatures).
validate_attributes :: proc(k: ^Checker, pkg: ^Package) {
	for file in pkg.files {
		k.file, k.file_node = file.file, file
		validate_attribute_list(k, file.attributes, .Package_Clause)
		for attribute in file.attributes {
			if _, is_provider := source_provider_slot(attribute); is_provider &&
			   pkg.id != k.c.root_package {
				errorf(
					k.c, attribute.span, "L0613",
					"`@(%s=...)` is only allowed on the root package clause",
					attribute.path[0].text,
				)
			}
		}
		validate_item_attributes(k, file.items)
		for item in file.active_items {
			#partial switch v in item {
			case ^Decl:
				validate_decl_attributes(k, v)
			case ^Item_Impl:
				validate_impl_attributes(k, v)
			case ^Item_Static_Assert:
				validate_attribute_list(k, v.attributes, .Static_Assert)
			case ^Item_Foreign_Block:
				validate_attribute_list(k, v.attributes, .Foreign_Block)
				for member in v.members {
					if d, ok := member.(^Decl); ok {
						validate_decl_attributes(k, d, .Foreign)
					}
				}
			}
		}
	}
}

// Imports and `when` blocks, in every branch: neither takes an attribute.
@(private = "file")
validate_item_attributes :: proc(k: ^Checker, items: []Item) {
	for item in items {
		#partial switch v in item {
		case ^Item_Import:
			validate_attribute_list(k, v.attributes, .Import)
		case ^Item_Foreign_Import:
			validate_attribute_list(k, v.attributes, .Import)
		case ^Item_When:
			validate_attribute_list(k, v.attributes, .Statement)
			if v.then != nil {
				validate_item_attributes(k, {v.then})
			}
			validate_item_attributes(k, {v.otherwise})
		case ^Item_Block:
			validate_attribute_list(k, v.attributes, .Statement)
			validate_item_attributes(k, v.items)
		}
	}
}

validate_impl_attributes :: proc(k: ^Checker, item: ^Item_Impl) {
	validate_attribute_list(k, item.attributes, .Impl)
	for member in item.members {
		#partial switch m in member {
		case ^Decl:
			validate_decl_attributes(k, m)
		case ^Item_Delegate:
			validate_attribute_list(k, m.attributes, .Delegate)
		}
	}
}

validate_decl_attributes :: proc(k: ^Checker, d: ^Decl, scope := Attr_Scope.Global) {
	if len(d.symbols) == 0 {
		return
	}
	validate_attribute_list(k, d.attributes, decl_attr_position(k, d), scope)
	// A generic template never resolves, so its parameters and record are
	// reached here rather than only at resolution.
	if literal := decl_proc_literal(d); literal != nil {
		validate_param_attributes(k, literal.signature.params)
	}
	if len(d.values) == 1 {
		if record, ok := d.values[0].(^Type_Record); ok {
			validate_record_attributes(k, record)
		}
	}
}

validate_param_attributes :: proc(k: ^Checker, params: []Parameter) {
	for param in params {
		validate_attribute_list(k, param.attributes, .Parameter)
	}
}

validate_record_attributes :: proc(k: ^Checker, record: ^Type_Record) {
	validate_attribute_list(k, record.attributes, record.kind == .Struct ? .Struct_Literal : .Union_Literal)
	for field in record.fields {
		validate_attribute_list(k, field.attributes, .Struct_Field)
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

// Records `@(deprecated)` and `@(require_results)` on the symbol while its
// signature resolves, so a use in another package already sees them.
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

// The string value of a named attribute in a list, decoded from its literal.
attribute_string_value :: proc(c: ^Compiler, attributes: []Attribute, name: string) -> (string, bool) {
	for attribute in attributes {
		if len(attribute.path) != 1 || attribute.path[0].text != name {
			continue
		}
		if lit, ok := attribute.value.(^Expr_Literal); ok && (lit.kind == .String || lit.kind == .Raw_String) {
			if text, decoded := decode_string_literal(c, lit.text, lit.kind == .Raw_String); decoded {
				return text, true
			}
		}
	}
	return "", false
}

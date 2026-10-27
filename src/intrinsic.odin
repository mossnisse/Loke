// design.md "`@(intrinsic)`": a bundled package declares each name the compiler
// contributes to it (`src/stdlib.odin`), so the name's signature and doc
// comment are written once, beside the package's other declarations, where
// `-doc` and the interface file show them.
//
// The declaration describes the contributed symbol and adds none of its own.
// `rebuild_active_items` leaves it out of every file's selected view, so no
// semantic pass sees it as an ordinary declaration; this file binds it to what
// it describes, checks what it states, and reports a public contributed name
// nothing describes.
package lokec

import "core:strings"

// One `@(intrinsic)` declaration and the symbol it describes. `subject` is the
// type an `impl` member belongs to.
Intrinsic_Decl :: struct {
	decl:    ^Decl,
	symbol:  Symbol_Id,
	subject: Type_Id,
	file:    ^File,
}

decl_is_intrinsic :: proc(d: ^Decl) -> bool {
	return has_attribute(d.attributes, "intrinsic")
}

// An `impl` block holding an `@(intrinsic)` member describes contributed
// members, and may hold nothing else.
impl_is_intrinsic :: proc(v: ^Item_Impl) -> bool {
	for member in v.members {
		if d, is_decl := member.(^Decl); is_decl && decl_is_intrinsic(d) {
			return true
		}
	}
	return false
}

// Once per package, right after the compiler contributes its names, so each
// declaration finds what it describes and a missing one is reported once.
bind_intrinsic_declarations :: proc(k: ^Checker, pkg: ^Package) {
	if pkg.intrinsics_bound {
		return
	}
	pkg.intrinsics_bound = true
	pkg.intrinsics = make([dynamic]Intrinsic_Decl, 0, len(pkg.contributions), k.c.semantic_allocator)
	saved := save_checker_location(k)
	defer restore_checker_location(k, saved)
	k.scope, k.pkg, k.lookup_pkg = pkg.scope, pkg.id, pkg.id
	for file in pkg.files {
		k.file, k.file_node = file.file, file
		bind_intrinsic_items(k, pkg, file, file.items)
	}
	report_undescribed_contributions(k, pkg)
}

// File scope and top-level blocks. One inside a `when` branch is reported once
// the branch is selected (`check_intrinsic_declarations`).
@(private = "file")
bind_intrinsic_items :: proc(k: ^Checker, pkg: ^Package, file: ^File, items: []Item) {
	for item in items {
		#partial switch v in item {
		case ^Decl:
			if decl_is_intrinsic(v) {
				bind_intrinsic(k, pkg, file, v, INVALID_TYPE)
			}
		case ^Item_Impl:
			if impl_is_intrinsic(v) {
				bind_intrinsic_impl(k, pkg, file, v)
			}
		case ^Item_Block:
			bind_intrinsic_items(k, pkg, file, v.items)
		}
	}
}

@(private = "file")
bind_intrinsic_impl :: proc(k: ^Checker, pkg: ^Package, file: ^File, v: ^Item_Impl) {
	subject := INVALID_TYPE
	if ident, is_ident := v.type.(^Expr_Ident); is_ident {
		name := intern_identifier(k.c, ident.name)
		if sym := symbol_of(k.c, pkg.scope.names[name] or_else INVALID_SYMBOL);
		   sym != nil && sym.kind == .Type && contributed_here(pkg, name) {
			subject = sym.type
		}
	}
	if subject == INVALID_TYPE {
		errorf(
			k.c, expr_span(v.type), "L0735",
			"an `impl` block of `@(intrinsic)` members describes a type the compiler supplies in this package",
		)
		return
	}
	if type_is_region_provider(k.c, subject) {
		ensure_provider_members(k, subject)
	}
	for member in v.members {
		d, is_decl := member.(^Decl)
		if !is_decl || !decl_is_intrinsic(d) {
			errorf(
				k.c, item_span(member), "L0734",
				"an `impl` block of `@(intrinsic)` members holds nothing else, since the compiler supplies the type",
			)
			continue
		}
		bind_intrinsic(k, pkg, file, d, subject)
	}
}

@(private = "file")
bind_intrinsic :: proc(k: ^Checker, pkg: ^Package, file: ^File, d: ^Decl, subject: Type_Id) {
	c := k.c
	validate_intrinsic_attributes(k, d)
	if len(pkg.contributions) == 0 {
		errorf(
			c, d.names[0].span, "L0734",
			"`@(intrinsic)` describes a name the compiler supplies, and it supplies none in this package",
		)
		return
	}
	literal := decl_proc_literal(d)
	shape_ok := d.kind == .Const && len(d.names) == 1 && len(d.values) == 1
	if shape_ok && literal == nil {
		#partial switch v in d.values[0] {
		case nil, ^Type_Enum:
		case ^Type_Record:
			shape_ok = v.kind == .Struct
		case:
			shape_ok = false
		}
	}
	if !shape_ok {
		errorf(
			c, d.names[0].span, "L0734",
			"an `@(intrinsic)` declaration is a procedure ending in `---`, or a type written `---`, as an `enum`, or as a `struct`",
		)
		return
	}
	if literal != nil && literal.body != nil {
		errorf(c, literal.body.span, "L0734", "the compiler supplies `%s`, so its declaration ends with `---` rather than a body", d.names[0].text)
		return
	}

	name := intern_identifier(c, d.names[0].text)
	symbol_id := INVALID_SYMBOL
	if subject == INVALID_TYPE {
		if contributed_here(pkg, name) {
			symbol_id = pkg.scope.names[name] or_else INVALID_SYMBOL
		}
	} else if info := type_of(c, subject); info != nil {
		member := member_named(c, info.members, name)
		if sym := symbol_of(c, member); sym != nil && sym.synth != .None {
			symbol_id = member
		}
	}
	sym := symbol_of(c, symbol_id)
	if sym == nil {
		if subject == INVALID_TYPE {
			errorf(c, d.names[0].span, "L0735", "the compiler supplies no `%s` in this package", d.names[0].text)
		} else {
			errorf(c, d.names[0].span, "L0735", "the compiler supplies no member `%s` of `%s`", d.names[0].text, type_name(c, subject))
		}
		return
	}
	describes_proc := literal != nil
	is_proc := sym.kind == .Proc || sym.kind == .Builtin
	if describes_proc != is_proc {
		errorf(
			c, d.names[0].span, "L0735", "the compiler supplies `%s` as a %s",
			d.names[0].text, is_proc ? "procedure, declared `proc(...) ---`" : "type, declared `---`, an `enum`, or a `struct`",
		)
		return
	}
	for entry in pkg.intrinsics {
		if entry.symbol == symbol_id {
			errorf(c, d.names[0].span, "L0735", "`%s` is already described by an `@(intrinsic)` declaration", d.names[0].text)
			add_notef(c, entry.decl.names[0].span, "described here")
			return
		}
	}
	symbols := make([]Symbol_Id, 1, c.semantic_allocator)
	symbols[0] = symbol_id
	d.symbols = symbols
	d.top_level = true
	// A contributed symbol has no source position; this is now its declaration.
	if sym.span == no_span() {
		sym.span = d.names[0].span
	}
	append(&pkg.intrinsics, Intrinsic_Decl{decl = d, symbol = symbol_id, subject = subject, file = file})
}

// The declaration's other attributes, which the package pass never reaches
// because the declaration is not in the selected view.
@(private = "file")
validate_intrinsic_attributes :: proc(k: ^Checker, d: ^Decl) {
	rest := make([dynamic]Attribute, 0, len(d.attributes), context.temp_allocator)
	for attribute in d.attributes {
		if len(attribute.path) != 1 || attribute.path[0].text != "intrinsic" {
			append(&rest, attribute)
		} else if attribute.value != nil {
			errorf(k.c, attribute.span, "L0608", "`@(intrinsic)` takes no value")
		}
	}
	position := decl_proc_literal(d) != nil ? Attr_Pos.Proc_Decl : Attr_Pos.Type_Decl
	validate_attribute_list(k, rest[:], position)
}

@(private = "file")
contributed_here :: proc(pkg: ^Package, name: Identifier_Id) -> bool {
	for contributed in pkg.contributions {
		if contributed == name {
			return true
		}
	}
	return false
}

@(private = "file")
described :: proc(pkg: ^Package, symbol_id: Symbol_Id) -> bool {
	for entry in pkg.intrinsics {
		if entry.symbol == symbol_id {
			return true
		}
	}
	return false
}

// Every public name the compiler contributes, and every member it contributes
// to a region provider, is described, so none is missing from documentation.
@(private = "file")
report_undescribed_contributions :: proc(k: ^Checker, pkg: ^Package) {
	c := k.c
	where_reported := len(pkg.files) > 0 ? pkg.files[0].package_span : no_span()
	for name in pkg.contributions {
		symbol_id := pkg.scope.names[name] or_else INVALID_SYMBOL
		sym := symbol_of(c, symbol_id)
		if sym == nil || !sym.public {
			continue
		}
		if !described(pkg, symbol_id) {
			errorf(
				c, where_reported, "L0737",
				"the compiler supplies `%s` in this package, and no `@(intrinsic)` declaration describes it",
				identifier_text(c, name),
			)
			continue
		}
		if sym.kind != .Type || !type_is_region_provider(c, sym.type) {
			continue
		}
		ensure_provider_members(k, sym.type)
		info := type_of(c, sym.type)
		for member in info.members {
			if found := symbol_of(c, member); found != nil && found.synth == .Provider_Op && !described(pkg, member) {
				errorf(
					c, sym.span, "L0737",
					"the compiler supplies `%s.%s`, and no `@(intrinsic)` declaration in an `impl %s` block describes it",
					identifier_text(c, name), identifier_text(c, found.name), identifier_text(c, name),
				)
			}
		}
	}
}

// Once signatures resolve: what each declaration states is checked against
// what it describes, and one inside a selected `when` branch is reported.
check_intrinsic_declarations :: proc(k: ^Checker, pkg: ^Package) {
	saved := save_checker_location(k)
	defer restore_checker_location(k, saved)
	k.scope, k.pkg, k.lookup_pkg = pkg.scope, pkg.id, pkg.id
	for entry in pkg.intrinsics {
		k.file, k.file_node = entry.file.file, entry.file
		check_intrinsic(k, entry)
	}
	for file in pkg.files {
		k.file, k.file_node = file.file, file
		report_intrinsics_in_when(k, file.items, false)
	}
}

@(private = "file")
report_intrinsics_in_when :: proc(k: ^Checker, items: []Item, selected: bool) {
	for item in items {
		#partial switch v in item {
		case ^Decl:
			if selected && decl_is_intrinsic(v) && len(v.names) > 0 {
				errorf(k.c, v.names[0].span, "L0734", "an `@(intrinsic)` declaration is not inside `when`: the compiler supplies the name whichever branch is taken")
			}
		case ^Item_Impl:
			if selected && impl_is_intrinsic(v) {
				errorf(k.c, expr_span(v.type), "L0734", "an `@(intrinsic)` declaration is not inside `when`: the compiler supplies the name whichever branch is taken")
			}
		case ^Item_Block:
			report_intrinsics_in_when(k, v.items, selected)
		case ^Item_When:
			if !v.resolved {
				continue
			}
			if v.taken {
				report_intrinsics_in_when(k, v.then.items, true)
			} else if v.otherwise != nil {
				report_intrinsics_in_when(k, []Item{v.otherwise}, true)
			}
		}
	}
}

@(private = "file")
check_intrinsic :: proc(k: ^Checker, entry: Intrinsic_Decl) {
	c := k.c
	sym := symbol_of(c, entry.symbol)
	d := entry.decl
	if literal := decl_proc_literal(d); literal != nil {
		// An operation the compiler types itself has a signature written for
		// readers; its section of design.md defines its typing.
		if sym.kind == .Proc {
			check_intrinsic_signature(k, d, literal.signature, sym, entry.subject)
		}
		return
	}
	#partial switch v in d.values[0] {
	case ^Type_Enum:
		check_intrinsic_enum(k, d, v, sym.type)
	case ^Type_Record:
		check_intrinsic_struct(k, d, v, sym.type)
	}
}

@(private = "file")
check_intrinsic_signature :: proc(k: ^Checker, d: ^Decl, signature: ^Type_Proc, sym: ^Symbol, subject: Type_Id) {
	c := k.c
	name := d.names[0].text
	for parameter, position in signature.params {
		if parameter.type == nil && !(subject != INVALID_TYPE && position == 0) {
			errorf(c, parameter.span, "L0736", "an `@(intrinsic)` procedure writes each parameter's type")
			return
		}
	}
	params, modes, result, result_inout, resolved := slot_signature(k, signature, subject)
	if !resolved {
		return
	}
	info := type_of(c, sym.proc_type)
	differs := info == nil || len(params) != len(sym.params) || result != sym.result || result_inout != sym.result_inout
	for index in 0 ..< len(params) {
		if differs || index >= len(info.param_modes) {
			differs = true
			break
		}
		differs = params[index] != sym.params[index] || modes[index] != info.param_modes[index]
	}
	if differs {
		errorf(
			c, d.names[0].span, "L0736", "the compiler supplies `%s` as `%s`",
			name, type_name(c, sym.proc_type),
		)
		return
	}
	// Names bind named arguments, so a written one is the parameter's name; a
	// default's value is the compiler's, so only whether there is one is stated.
	flat := 0
	for parameter in signature.params {
		count := max(len(parameter.names), 1)
		for index in 0 ..< count {
			written := index < len(parameter.names) ? parameter.names[index].name.text : ""
			receiver := sym.has_receiver && flat == 0
			if flat < len(sym.param_defaults) && (sym.param_defaults[flat] != nil) != (parameter.default != nil) {
				errorf(
					c, parameter.span, "L0736", "the compiler supplies `%s`'s parameter `%s` %s a default",
					name, written, sym.param_defaults[flat] != nil ? "with" : "without",
				)
			}
			if !receiver && written != "" && flat < len(sym.param_symbols) {
				written_id := intern_identifier(c, written)
				if existing := symbol_of(c, sym.param_symbols[flat]); existing == nil {
					sym.param_symbols[flat] = new_symbol(c, Symbol {
						name = written_id, kind = .Parameter, type = sym.params[flat], mode = modes[flat],
					})
				} else if existing.name != written_id {
					errorf(
						c, parameter.span, "L0736", "the compiler supplies this parameter of `%s` as `%s`",
						name, identifier_text(c, existing.name),
					)
				}
			}
			flat += 1
		}
	}
}

@(private = "file")
check_intrinsic_enum :: proc(k: ^Checker, d: ^Decl, written: ^Type_Enum, type: Type_Id) {
	c := k.c
	info := type_of(c, type)
	if info == nil || info.kind != .Enum {
		errorf(c, d.names[0].span, "L0736", "the compiler supplies `%s`, which is not an enum", d.names[0].text)
		return
	}
	if written.backing != nil {
		errorf(c, expr_span(written.backing), "L0736", "the compiler supplies `%s`'s backing type, so it is not written", d.names[0].text)
	}
	for field, index in written.fields {
		if field.value != nil {
			errorf(c, expr_span(field.value), "L0736", "the compiler supplies `%s`'s values, so its members are written without them", d.names[0].text)
			return
		}
		member := index < len(info.fields) ? symbol_of(c, info.fields[index]) : nil
		if member == nil || identifier_text(c, member.name) != field.name.text {
			errorf(c, field.span, "L0736", "the compiler supplies `%s` with the members %s", d.names[0].text, member_list(c, info.fields))
			return
		}
	}
	if len(written.fields) != len(info.fields) {
		errorf(c, d.names[0].span, "L0736", "the compiler supplies `%s` with the members %s", d.names[0].text, member_list(c, info.fields))
	}
}

@(private = "file")
check_intrinsic_struct :: proc(k: ^Checker, d: ^Decl, written: ^Type_Record, type: Type_Id) {
	c := k.c
	info := type_of(c, type)
	if info == nil || info.kind != .Struct {
		errorf(c, d.names[0].span, "L0736", "the compiler supplies `%s`, which is not a struct", d.names[0].text)
		return
	}
	public := make([dynamic]^Symbol, 0, len(info.fields), context.temp_allocator)
	for field in info.fields {
		if sym := symbol_of(c, field); sym != nil && sym.public {
			append(&public, sym)
		}
	}
	index := 0
	for field in written.fields {
		field_type := resolve_type_syntax(k, field.type)
		for field_name in field.names {
			expected := index < len(public) ? public[index] : nil
			if expected == nil || identifier_text(c, expected.name) != field_name.text ||
			   (field_type != INVALID_TYPE && field_type != expected.type) {
				errorf(c, field_name.span, "L0736", "the compiler supplies `%s` with the public fields %s", d.names[0].text, field_list(c, public[:]))
				return
			}
			index += 1
		}
	}
	if index != len(public) {
		errorf(c, d.names[0].span, "L0736", "the compiler supplies `%s` with the public fields %s", d.names[0].text, field_list(c, public[:]))
	}
}

@(private = "file")
member_list :: proc(c: ^Compiler, members: []Symbol_Id) -> string {
	b := strings.builder_make(c.semantic_allocator)
	for member, index in members {
		if index > 0 {
			strings.write_string(&b, ", ")
		}
		strings.write_string(&b, "`")
		strings.write_string(&b, identifier_text(c, symbol_of(c, member).name))
		strings.write_string(&b, "`")
	}
	return strings.to_string(b)
}

@(private = "file")
field_list :: proc(c: ^Compiler, fields: []^Symbol) -> string {
	b := strings.builder_make(c.semantic_allocator)
	for field, index in fields {
		if index > 0 {
			strings.write_string(&b, ", ")
		}
		strings.write_string(&b, "`")
		strings.write_string(&b, identifier_text(c, field.name))
		strings.write_string(&b, ": ")
		strings.write_string(&b, type_name(c, field.type))
		strings.write_string(&b, "`")
	}
	return strings.to_string(b)
}

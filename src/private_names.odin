package lokec

import "core:mem/virtual"
import "core:slice"
import "core:strings"

// design.md "Private names in public declarations": a public declaration that
// names a private declaration of its package is the warning L0740, since an
// importer can use the public one but cannot name what it names. The walk is
// over the written syntax, by name, as the interface file reads it: a generic
// template and a generic `impl`'s members are checked per instance, so their
// syntax resolves to nothing, and what an importer reads is the written name.
check_private_names :: proc(c: ^Compiler, package_id: Package_Id) {
	pkg := package_of(c, package_id)
	// design.md "Exported names": nothing imports a `package main`.
	if pkg == nil || len(pkg.files) == 0 || pkg.files[0].package_name == "main" {
		return
	}
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		return
	}
	defer virtual.arena_destroy(&arena)
	// The diagnostics outlive the arena, so their allocator is pinned first.
	_ = diagnostic_allocator(c)
	context.allocator = virtual.arena_allocator(&arena)

	x := Exposure{c = c}
	for file in pkg.files {
		x.file = file
		collect_named(&x, file.active_items)
	}
	for file in pkg.files {
		x.file = file
		for item in file.active_items {
			#partial switch v in item {
			case ^Decl:
				if decl_is_public(c, file, v) {
					read_public_decl(&x, v, "")
				}
			case ^Item_Foreign_Block:
				for member in v.members {
					if d, is_decl := member.(^Decl); is_decl && decl_is_public(c, file, d, v.attributes) {
						read_public_decl(&x, d, "")
					}
				}
			case ^Item_Impl:
				read_impl(&x, v)
			}
		}
	}
}

@(private = "file")
Exposure :: struct {
	c:        ^Compiler,
	file:     ^File,
	// Each declaration of the package by its name, and each `impl`'s members
	// by the written name of its subject.
	declared: map[string]Named,
	members:  map[string]map[string]Named,
	// The subject of the `impl` being read, whose members a written name may
	// also mean.
	subject:  string,
	// The parameters and `$` names in scope, which a written name means before
	// any declaration of the package.
	bound:    [dynamic]string,
	// The public declaration being read, and the public group that exports it
	// when it is a private member of one.
	owner:    string,
	group:    string,
	// The private names already reported for `owner`.
	reported: [dynamic]string,
	// The private group members already read, so a member of two groups is
	// read once.
	read_members: map[^Decl]bool,
}

@(private = "file")
Named :: struct {
	decl:    ^Decl,
	span:    Span,
	public:  bool,
	is_type: bool,
	is_proc: bool,
}

@(private = "file")
Position :: enum {
	// Type syntax: only a private type counts, since a value in it, such as an
	// array length, is one an importer can write itself.
	Type,
	// A `where` clause or an interface requirement: any private declaration.
	Where,
}

@(private = "file")
collect_named :: proc(x: ^Exposure, items: []Item) {
	for item in items {
		#partial switch v in item {
		case ^Decl:
			add_named(x, &x.declared, v, nil)
		case ^Item_Foreign_Block:
			for member in v.members {
				if d, is_decl := member.(^Decl); is_decl {
					add_named(x, &x.declared, d, v.attributes)
				}
			}
		case ^Item_Impl:
			subject := subject_name(v.type)
			if !(subject in x.members) {
				x.members[subject] = make(map[string]Named)
			}
			members := &x.members[subject]
			for member in v.members {
				if d, is_decl := member.(^Decl); is_decl {
					add_named(x, members, d, nil)
				}
			}
		}
	}
}

@(private = "file")
add_named :: proc(x: ^Exposure, into: ^map[string]Named, d: ^Decl, block: []Attribute) {
	if d.kind == .Var {
		return // never public, and never in a signature
	}
	public := decl_is_public(x.c, x.file, d, block)
	for name, index in d.names {
		if name.text == "_" {
			continue
		}
		named := Named{decl = d, span = name.span, public = public}
		symbol := symbol_of(x.c, d.symbols[index]) if index < len(d.symbols) else nil
		if symbol != nil {
			named.is_type = symbol_names_type(x.c, symbol)
			named.is_proc = symbol.kind == .Proc
		} else {
			// A generic `impl`'s member, which no symbol records.
			named.is_proc = decl_proc_literal(d) != nil
			if index < len(d.values) {
				#partial switch _ in d.values[index] {
				case ^Type_Record, ^Type_Enum, ^Type_Interface, ^Type_Distinct, ^Type_Proc:
					named.is_type = true
				}
			}
		}
		into[name.text] = named
	}
}

// `Name` of `impl Name`, `impl Name($T)`, and `impl pkg.Name`, as written.
@(private = "file")
subject_name :: proc(e: Expr) -> string {
	#partial switch v in e {
	case ^Expr_Ident:
		return v.name
	case ^Expr_Call:
		return subject_name(v.callee)
	case ^Expr_Selector:
		if operand, is_ident := v.operand.(^Expr_Ident); is_ident {
			return strings.concatenate({operand.name, ".", v.name.text})
		}
	}
	return ""
}

// design.md "Private names in public declarations": the members of an `impl`
// whose subject is a private type are reached only through a value of it, so
// the declaration that hands one out is the one reported.
@(private = "file")
read_impl :: proc(x: ^Exposure, v: ^Item_Impl) {
	subject := subject_name(v.type)
	if named, declared := x.declared[subject]; declared && named.is_type && !named.public {
		return
	}
	x.subject = subject
	defer x.subject = ""
	clear(&x.bound)
	bind_poly(x, v.type)
	mark := len(x.bound)
	for member in v.members {
		if d, is_decl := member.(^Decl); is_decl && decl_is_public(x.c, x.file, d) {
			read_public_decl(x, d, subject)
			resize(&x.bound, mark)
		}
	}
}

// `subject` is the written subject of the `impl` `d` is a member of.
@(private = "file")
read_public_decl :: proc(x: ^Exposure, d: ^Decl, subject: string) {
	for name, index in d.names {
		if name.text == "_" {
			continue
		}
		owner := name.text if subject == "" else strings.concatenate({subject, ".", name.text})
		start(x, owner, "")
		if literal := decl_proc_literal(d); literal != nil {
			read_signature(x, literal)
			continue
		}
		if index >= len(d.values) {
			continue
		}
		symbol := symbol_of(x.c, d.symbols[index]) if index < len(d.symbols) else nil
		#partial switch v in d.values[index] {
		case ^Expr_Proc_Group:
			read_group(x, v, owner)
		case ^Type_Record:
			read_record(x, v, owner)
		case ^Type_Interface:
			read_interface(x, v)
		case ^Type_Enum:
			walk(x, v.backing, .Type)
		case ^Type_Distinct:
			walk(x, v.elem, .Type)
		case:
			if symbol != nil && symbol_names_type(x.c, symbol) {
				walk(x, d.values[index], .Type) // a type alias's target
			} else if d.declared_type != nil {
				walk(x, d.declared_type, .Type)
			} else if symbol != nil && symbol.kind == .Const {
				report_constant_type(x, name, symbol.type)
			}
		}
	}
}

// A type, or a type alias, which is a constant whose value is a type.
@(private = "file")
symbol_names_type :: proc(c: ^Compiler, symbol: ^Symbol) -> bool {
	return symbol.kind == .Type || (symbol.kind == .Const && const_names_type(c, symbol.const_value, symbol.type))
}

@(private = "file")
start :: proc(x: ^Exposure, owner, group: string) {
	x.owner, x.group = owner, group
	clear(&x.reported)
}

@(private = "file")
read_signature :: proc(x: ^Exposure, literal: ^Expr_Proc) {
	signature := literal.signature
	if signature == nil {
		return
	}
	mark := len(x.bound)
	defer resize(&x.bound, mark)
	bind_parameters(x, signature)
	for parameter in signature.params {
		walk(x, parameter.type, .Type) // a default is a value the importer need not name
	}
	if signature.result != nil {
		walk(x, signature.result.type, .Type)
	}
	for clause in literal.where_clauses {
		walk(x, clause, .Where)
	}
}

// design.md "Private names in public declarations": a group's members are not
// API by name, but each signature it exports is, so a private member declared
// in the package is read as a public procedure would be.
@(private = "file")
read_group :: proc(x: ^Exposure, group: ^Expr_Proc_Group, owner: string) {
	for name in group.names {
		named, found := lookup(x, name.text)
		if !found || named.public || !named.is_proc || named.decl in x.read_members {
			continue
		}
		x.read_members[named.decl] = true
		member := name.text if x.subject == "" else strings.concatenate({x.subject, ".", name.text})
		start(x, member, owner)
		read_signature(x, decl_proc_literal(named.decl))
	}
	start(x, owner, "")
}

@(private = "file")
read_record :: proc(x: ^Exposure, record: ^Type_Record, owner: string) {
	mark := len(x.bound)
	defer resize(&x.bound, mark)
	bind_generic(x, record.generic_params)
	for parameter in record.generic_params {
		walk(x, parameter.type, .Type)
	}
	for clause in record.where_clauses {
		walk(x, clause, .Where)
	}
	for variant in record.variants {
		walk(x, variant.type, .Type)
	}
	for &field in record.fields {
		if !field_is_exported(x, &field) {
			continue
		}
		for name in field.names {
			start(x, strings.concatenate({owner, ".", name.text}), "")
			walk(x, field.type, .Type)
		}
	}
	start(x, owner, "")
}

// A public field, but not padding. A generic record's fields are checked per
// instance, so its template's take their visibility from what is written.
@(private = "file")
field_is_exported :: proc(x: ^Exposure, field: ^Field) -> bool {
	if len(field.names) == 1 && field.names[0].text == "_" {
		return false
	}
	if len(field.symbols) > 0 {
		symbol := symbol_of(x.c, field.symbols[0])
		return symbol != nil && symbol.public
	}
	return written_is_public(field.attributes, x.file.attributes)
}

@(private = "file")
read_interface :: proc(x: ^Exposure, v: ^Type_Interface) {
	mark := len(x.bound)
	defer resize(&x.bound, mark)
	bind_generic(x, v.generic_params)
	for parameter in v.generic_params {
		walk(x, parameter.type, .Type)
	}
	for clause in v.where_clauses {
		walk(x, clause, .Where)
	}
	for requirement in v.requirements {
		inner := len(x.bound)
		for group in requirement.bindings {
			for name in group.names {
				append(&x.bound, name.text)
			}
		}
		for group in requirement.bindings {
			walk(x, group.type, .Type)
		}
		walk(x, requirement.expr, .Where)
		walk(x, requirement.result, .Type)
		walk(x, requirement.slot_type, .Type)
		resize(&x.bound, inner)
	}
}

// Each parameter's name, and each `$` name its types and defaults bind.
@(private = "file")
bind_parameters :: proc(x: ^Exposure, signature: ^Type_Proc) {
	for parameter in signature.params {
		for name in parameter.names {
			append(&x.bound, name.name.text)
		}
		bind_poly(x, parameter.type)
		bind_poly(x, parameter.default)
	}
}

@(private = "file")
bind_generic :: proc(x: ^Exposure, parameters: []Generic_Param) {
	for parameter in parameters {
		for name in parameter.names {
			append(&x.bound, name.text)
		}
	}
}

// The `$` names written in type syntax, as `T` in `[]$T`.
@(private = "file")
bind_poly :: proc(x: ^Exposure, e: Expr) {
	type_syntax_any_name(e, &x.bound, proc(data: rawptr, node: Expr) -> bool {
		if poly, is_poly := node.(^Type_Poly); is_poly {
			append((^[dynamic]string)(data), poly.name.text)
		}
		return false
	})
}

// The declaration of the package a written name means, if no parameter or `$`
// name binds it: one at file scope, or in an `impl`, a member of its subject.
@(private = "file")
lookup :: proc(x: ^Exposure, name: string) -> (Named, bool) {
	if slice.contains(x.bound[:], name) {
		return {}, false
	}
	if named, found := x.declared[name]; found {
		return named, true
	}
	if members, found := x.members[x.subject]; found && x.subject != "" {
		named, is_member := members[name]
		return named, is_member
	}
	return {}, false
}

@(private = "file")
walk :: proc(x: ^Exposure, e: Expr, position: Position) {
	if e == nil {
		return
	}
	#partial switch v in e {
	case ^Expr_Ident:
		if named, found := lookup(x, v.name); found {
			found_name(x, v.name, v.span, named, position)
		}
	case ^Expr_Selector:
		// `Subject.member`; an import's name is no declaration of the package.
		if operand, is_ident := v.operand.(^Expr_Ident); is_ident && !slice.contains(x.bound[:], operand.name) {
			if members, found := x.members[operand.name]; found {
				if named, is_member := members[v.name.text]; is_member {
					found_name(x, strings.concatenate({operand.name, ".", v.name.text}), v.name.span, named, position)
				}
			}
		}
		walk(x, v.operand, position)
	case ^Expr_Checked_Extract:
		walk(x, v.operand, position)
		walk(x, v.target, position)
	case ^Expr_Index:
		walk(x, v.operand, position)
		for index in v.indices {
			walk(x, index, position)
		}
	case ^Expr_Slice:
		walk(x, v.operand, position)
		walk(x, v.lo, position)
		walk(x, v.hi, position)
	case ^Expr_Call:
		walk(x, v.callee, position)
		for argument in v.args {
			walk(x, argument.value, position)
		}
	case ^Expr_Postfix:
		walk(x, v.operand, position)
		walk(x, v.failure, position)
	case ^Expr_Unary:
		walk(x, v.operand, position)
	case ^Expr_Binary:
		walk(x, v.lhs, position)
		walk(x, v.rhs, position)
	case ^Expr_Range:
		walk(x, v.lo, position)
		walk(x, v.hi, position)
	case ^Expr_Or_Else:
		walk(x, v.value, position)
		walk(x, v.fallback, position)
	case ^Expr_Cond:
		walk(x, v.cond, position)
		walk(x, v.then, position)
		walk(x, v.otherwise, position)
	case ^Expr_Move:
		walk(x, v.value, position)
	case ^Expr_Composite:
		walk(x, v.type_expr, position)
		for element in v.elements {
			// A field's name is not a reference.
			if _, is_name := element.key.(^Expr_Ident); !is_name {
				walk(x, element.key, position)
			}
			walk(x, element.value, position)
		}
	case ^Type_Pointer:
		walk(x, v.elem, position)
	case ^Type_C_Pointer:
		walk(x, v.elem, position)
	case ^Type_Slice:
		walk(x, v.elem, position)
	case ^Type_Dynamic_Array:
		walk(x, v.elem, position)
	case ^Type_Distinct:
		walk(x, v.elem, position)
	case ^Type_Dyn:
		walk(x, v.interface_expr, position)
	case ^Type_Array:
		walk(x, v.length, position)
		walk(x, v.elem, position)
	case ^Type_Map:
		walk(x, v.key, position)
		walk(x, v.value, position)
	case ^Type_Proc:
		mark := len(x.bound)
		bind_parameters(x, v)
		for parameter in v.params {
			walk(x, parameter.type, position)
		}
		if v.result != nil {
			walk(x, v.result.type, position)
		}
		resize(&x.bound, mark)
	case ^Type_Anon_Record:
		for field in v.fields {
			walk(x, field.type, position)
		}
	case ^Type_Anon_Union:
		for variant in v.variants {
			walk(x, variant.type, position)
		}
	case ^Type_Record:
		for field in v.fields {
			walk(x, field.type, position)
		}
		for variant in v.variants {
			walk(x, variant.type, position)
		}
	}
}

@(private = "file")
found_name :: proc(x: ^Exposure, written: string, span: Span, named: Named, position: Position) {
	if named.public || (position == .Type && !named.is_type) || slice.contains(x.reported[:], written) {
		return
	}
	append(&x.reported, written)
	where_clause := position == .Where
	what := "type " if named.is_type && !where_clause else ""
	if x.group != "" {
		warnf(
			x.c, span, "L0740",
			"`%s`, which the public group `%s` exports, names the private %s`%s`%s, which an importer cannot name",
			x.owner, x.group, what, written, " in a `where` clause" if where_clause else "",
		)
	} else {
		warnf(
			x.c, span, "L0740",
			"public `%s` names the private %s`%s`%s, which an importer cannot name",
			x.owner, what, written, " in a `where` clause" if where_clause else "",
		)
	}
	add_notef(x.c, named.span, "declared here; make it `@(public)` if it is part of the API")
}

// A constant with no written type has the type of its value, as `Fill` for
// `DEFAULT :: Fill{}`.
@(private = "file")
report_constant_type :: proc(x: ^Exposure, name: Name, type: Type_Id) {
	symbol := private_type_in(x, type, 0)
	if symbol == nil {
		return
	}
	written := identifier_text(x.c, symbol.name)
	warnf(
		x.c, name.span, "L0740",
		"public `%s` has the private type `%s`, which an importer cannot name",
		x.owner, written,
	)
	add_notef(x.c, symbol.span, "declared here; make it `@(public)` if it is part of the API")
}

// A private type of the package that `type` is or holds as an element, a key,
// or a generic argument.
@(private = "file")
private_type_in :: proc(x: ^Exposure, type: Type_Id, depth: int) -> ^Symbol {
	info := type_of(x.c, type)
	if info == nil || depth > 8 {
		return nil
	}
	for id in ([]Symbol_Id{info.symbol, info.instance_of}) {
		symbol := symbol_of(x.c, id)
		if symbol != nil && symbol_names_type(x.c, symbol) && !symbol.public && symbol.decl != nil {
			if named, found := x.declared[identifier_text(x.c, symbol.name)]; found && named.decl == symbol.decl {
				return symbol
			}
		}
	}
	for argument in info.instance_args {
		if argument.is_type {
			if found := private_type_in(x, argument.type, depth + 1); found != nil {
				return found
			}
		}
	}
	#partial switch info.kind {
	case .Pointer, .C_Pointer, .Slice, .Dynamic_Array, .Array, .Box, .Simd:
		return private_type_in(x, info.element, depth + 1)
	case .Map:
		if found := private_type_in(x, info.key, depth + 1); found != nil {
			return found
		}
		return private_type_in(x, info.element, depth + 1)
	}
	return nil
}

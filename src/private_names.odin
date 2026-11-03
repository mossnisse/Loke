package lokec

import "core:mem"
import "core:mem/virtual"
import "core:slice"
import "core:strings"

// design.md "Private names in public declarations": a public declaration that
// names a private declaration of its package is the warning L0740, since an
// importer can use the public one but cannot name what it names. The walk is
// over the written syntax, by name, as the interface file reads it: a generic
// template and a generic `impl`'s members are checked per instance, so their
// syntax resolves to nothing, and what an importer reads is the written name.
// The one type read, an untyped constant's, is read for a generic `impl`'s
// members by `read_generic_impl_constants` and `check_instance_private_names`;
// the first also says which of those members are type aliases, and the second
// reads the block again where an instance says what its syntax could not.
// `check_generic_private_names` does the same for any other generic declaration.
check_private_names :: proc(k: ^Checker, package_id: Package_Id) {
	c := k.c
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
	checker_allocator := context.allocator
	context.allocator = virtual.arena_allocator(&arena)

	x := exposure_of(k, pkg, checker_allocator)
	for file in pkg.files {
		x.file = file
		k.file, k.file_node, k.scope = file.file, file, pkg.scope
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

// The declarations of `pkg` by name, in the context's allocator.
@(private = "file")
exposure_of :: proc(k: ^Checker, pkg: ^Package, checker_allocator: mem.Allocator) -> Exposure {
	x := Exposure{k = k, c = k.c, scope = pkg.scope, checker_allocator = checker_allocator}
	for file in pkg.files {
		x.file = file
		collect_named(&x, file.active_items)
	}
	return x
}

@(private = "file")
Exposure :: struct {
	k:        ^Checker,
	c:        ^Compiler,
	// What the checker allocates with, since what it records outlives this
	// pass's arena.
	checker_allocator: mem.Allocator,
	// Reading an instance, whose scope binds the `$` names, and not a template.
	instance: bool,
	// How many of `bound` the checker's scope binds, as a generic `impl`'s instance
	// does the block's `$` names. A later one is a member's own: a method's calls
	// bind it, so the scope knows nothing of it, or means something else by it. An
	// instance of the declaration being read itself binds them all.
	scoped:   int,
	file:     ^File,
	// The package's scope, which a private type a value's type holds is
	// declared in.
	scope:    ^Scope,
	// Each declaration of the package by its name, and each `impl`'s members
	// by the written name of its subject.
	declared: map[string]Named,
	members:  map[string]map[string]Named,
	// The `impl` each member is declared in, by its name's span.
	blocks:   map[Span]^Item_Impl,
	// The subject of the `impl` being read, whose members a written name may
	// also mean.
	subject:  string,
	// The `$` parameters and names in scope, which a written name means before any
	// declaration of the package.
	bound:    [dynamic]string,
	// The public declaration being read, and the public group that exports it
	// when it is a private member of one.
	owner:    string,
	group:    string,
	// The private names already reported for `owner`.
	reported: [dynamic]string,
	// Reading an instance found a member that is no type there, which a later
	// instance may say it is.
	undecided: bool,
	// The read walked a selection from an instance, as `Box(T).Hidden`.
	selects:  bool,
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
	// A generic `impl`'s member's value, which may select another member.
	value:   Expr,
	// A generic `impl`'s member, whose `is_type` is what its syntax says: what
	// an instance makes of it, only resolution knows.
	unresolved: bool,
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
					for name in d.names {
						x.blocks[name.span] = v
					}
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
			// A generic `impl`'s member, which no symbol records: whether an
			// alias is a type, `read_generic_impl_constants` decided.
			named.unresolved = true
			named.is_proc = decl_proc_literal(d) != nil
			named.is_type = name.span in x.c.generic_impl_types
			if index < len(d.values) {
				named.value = d.values[index]
				named.is_type ||= writes_type(named.value)
			}
		}
		into[name.text] = named
	}
}

// `Name` of `impl Name`, `impl Name($T)`, and `impl pkg.Name`, as written.
@(private = "file")
subject_name :: proc(e: Expr, allocator := context.allocator) -> string {
	#partial switch v in e {
	case ^Expr_Ident:
		return v.name
	case ^Expr_Call:
		return subject_name(v.callee, allocator)
	case ^Expr_Selector:
		if operand, is_ident := v.operand.(^Expr_Ident); is_ident {
			return strings.concatenate({operand.name, ".", v.name.text}, allocator)
		}
	}
	return ""
}

// design.md "Private names in public declarations": the members of an `impl`
// whose subject is a private type are reached only through a value of it, so
// the declaration that hands one out is the one reported.
@(private = "file")
read_impl :: proc(x: ^Exposure, v: ^Item_Impl) {
	if !impl_members_read(x, v) {
		return
	}
	subject := subject_name(v.type)
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

@(private = "file")
impl_members_read :: proc(x: ^Exposure, v: ^Item_Impl) -> bool {
	named, declared := x.declared[subject_name(v.type)]
	return !declared || !named.is_type || named.public || subject_type_is_public(x.c, v)
}

// A block written through a private alias of a public type, as `impl Short(int)`
// for `Short :: Box($T)`, is on that public type, whose values an importer has.
// A generic block's subject is resolved only per instance, and a block cannot
// apply an alias to `$` names, so such a block names the private type itself.
@(private = "file")
subject_type_is_public :: proc(c: ^Compiler, v: ^Item_Impl) -> bool {
	info := type_of(c, v.subject)
	if info == nil {
		return false
	}
	declared := symbol_of(c, info.instance_of)
	if declared == nil {
		declared = symbol_of(c, info.symbol)
	}
	return declared != nil && declared.public
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
		value := d.values[index]
		#partial switch v in value {
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
			// A value written as a type, as `[]T` is, is a type alias's target.
			// A generic `impl`'s member has no symbol: whether a value written
			// otherwise is a type, `read_generic_impl_constants` decided, or the
			// member it selects says, as `Box(T).Hidden`'s does; a constant's
			// value is read there by its type.
			names_type := writes_type(value)
			if !names_type && symbol != nil {
				names_type = symbol_names_type(x.c, symbol)
			} else if !names_type {
				_, selected, selects := selected_member(x, value)
				names_type = name.span in x.c.generic_impl_types || (selects && selected.is_type)
			}
			if names_type {
				// A type alias's target. A parametric alias binds the `$` names
				// its target writes, which mean that parameter wherever they
				// appear in it, whatever the package declares by the same name.
				mark := len(x.bound)
				bind_poly(x, value)
				walk(x, value, .Type)
				resize(&x.bound, mark)
			} else if d.declared_type != nil {
				walk(x, d.declared_type, .Type)
			} else if !x.instance && symbol != nil && symbol.kind == .Const {
				report_constant_type(x, name, symbol.type)
			}
		}
	}
}

// Syntax that can only write a type, whatever it names: a declaration whose
// value is written so is a type, or a type alias whose target it is. A name or
// a call may write a type too, which resolution decides.
@(private = "file")
writes_type :: proc(e: Expr) -> bool {
	#partial switch _ in e {
	case ^Type_Record, ^Type_Enum, ^Type_Interface, ^Type_Distinct, ^Type_Proc, ^Type_Pointer, ^Type_C_Pointer,
	     ^Type_Slice, ^Type_Dynamic_Array, ^Type_Array, ^Type_Map, ^Type_Dyn, ^Type_Anon_Record, ^Type_Anon_Union,
	     ^Type_Type:
		return true
	}
	return false
}

// A type, or a type alias: a constant whose value is a type, or a parametric
// alias, a constant that has no value until an application supplies its `$`
// names.
@(private = "file")
symbol_names_type :: proc(c: ^Compiler, symbol: ^Symbol) -> bool {
	if symbol.kind != .Const {
		return symbol.kind == .Type
	}
	return const_names_type(c, symbol.const_value, symbol.type) || declaration_generic_kind(symbol.decl) == .Alias
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

// Each `$` parameter's name, and each `$` name its types and defaults bind. A
// plain parameter's name is in no type's scope, so `proc(T: int) -> T` means what
// `T` means outside it.
@(private = "file")
bind_parameters :: proc(x: ^Exposure, signature: ^Type_Proc) {
	for parameter in signature.params {
		for name in parameter.names {
			if name.is_poly {
				append(&x.bound, name.name.text)
			}
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

@(private = "file")
bind_poly :: proc(x: ^Exposure, e: Expr) {
	poly_names(e, &x.bound)
}

// The `$` names written in type syntax, as `T` in `[]$T`.
@(private = "file")
poly_names :: proc(e: Expr, out: ^[dynamic]string) {
	type_syntax_any_name(e, out, proc(data: rawptr, node: Expr) -> bool {
		if poly, is_poly := node.(^Type_Poly); is_poly {
			append((^[dynamic]string)(data), poly.name.text)
		}
		return false
	})
}

// The declaration of the package a written name means, if no `$`
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
			found_name(x, v.name, v.span, v, named, position)
		}
	case ^Expr_Selector:
		if _, from_instance := v.operand.(^Expr_Call); from_instance {
			x.selects = true
		}
		if written, named, found := selected_member(x, v); found {
			found_name(x, written, v.name.span, v, named, position)
		}
		walk(x, v.operand, position)
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

// The member of an `impl` of the package that `Subject.member` or, from an
// instance, `Subject(...).member` selects, and its name as `Subject.member`; an
// import's name is no declaration of the package. A generic `impl`'s member
// that itself selects one is a type when that one is, however long the chain
// of selections: design.md "Private names in public declarations" sets no
// limit, so only a chain that returns to a member it has passed ends unread.
@(private = "file")
selected_member :: proc(x: ^Exposure, e: Expr) -> (written: string, named: Named, found: bool) {
	written, named = member_selected(x, e) or_return
	passed := make([dynamic]Span)
	for inner := named; !named.is_type && !slice.contains(passed[:], inner.span); {
		append(&passed, inner.span)
		_, next, selects := member_selected(x, inner.value)
		if !selects {
			break
		}
		named.is_type = next.is_type
		inner = next
	}
	return written, named, true
}

// The member `e` selects, as written, without following its own selection.
@(private = "file")
member_selected :: proc(x: ^Exposure, e: Expr) -> (written: string, named: Named, found: bool) {
	selector, is_selector := e.(^Expr_Selector)
	if !is_selector {
		return
	}
	operand := selector.operand
	if call, is_call := operand.(^Expr_Call); is_call {
		operand = call.callee
	}
	subject, is_ident := operand.(^Expr_Ident)
	if !is_ident || slice.contains(x.bound[:], subject.name) {
		return
	}
	members := x.members[subject.name] or_return
	named = members[selector.name.text] or_return
	return strings.concatenate({subject.name, ".", selector.name.text}), named, true
}

@(private = "file")
found_name :: proc(x: ^Exposure, written: string, span: Span, e: Expr, named: Named, position: Position) {
	if named.public || slice.contains(x.reported[:], written) {
		return
	}
	is_type := named.is_type || (position == .Type && named.unresolved && resolves_to_type(x, e))
	if position == .Type && !is_type {
		return
	}
	append(&x.reported, written)
	// An instance reads the block's syntax again for what its template could not
	// see, so the template's own reports are not repeated.
	if x.instance && span in x.c.private_names_warned {
		return
	}
	x.c.private_names_warned[span] = true
	where_clause := position == .Where
	what := "type " if is_type && !where_clause else ""
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

// design.md "Private names in public declarations" reads a private alias, and
// whether a generic `impl`'s member is one may depend on the instance, as
// `Hidden: T : Point` in `Box(type)`. Syntax that names a `$` name means nothing
// in a template, and is read when an instance binds it; other syntax, as
// `Box(type).Hidden`, means what it means anywhere. An instance of a block binds
// the block's `$` names, and syntax that names a member's own means nothing there.
@(private = "file")
resolves_to_type :: proc(x: ^Exposure, e: Expr) -> bool {
	if names_unscoped(x, e) {
		return false
	}
	context.allocator = x.checker_allocator
	probe := begin_probe(x.c)
	type := check_single_expr(x.k, clone_expr(x.c, e))
	end_probe(x.c, probe)
	x.undecided ||= type != TYPE_TYPE
	return type == TYPE_TYPE
}

// Whether `e` writes a `$` name, or a name a `$` name binds that the checker's
// scope does not.
@(private = "file")
names_unscoped :: proc(x: ^Exposure, e: Expr) -> bool {
	return type_syntax_any_name(e, x, proc(data: rawptr, node: Expr) -> bool {
		#partial switch v in node {
		case ^Type_Poly:
			return true
		case ^Expr_Ident:
			exposure := (^Exposure)(data)
			return slice.contains(exposure.bound[min(exposure.scoped, len(exposure.bound)):], v.name)
		}
		return false
	})
}

// A constant with no written type has the type of its value, as `Fill` for
// `DEFAULT :: Fill{}`.
@(private = "file")
report_constant_type :: proc(x: ^Exposure, name: Name, type: Type_Id) {
	if x.scope != nil {
		report_private_constant(x.c, name, x.owner, private_type_in(x.c, x.scope, type, nil, 0))
	}
}

@(private = "file")
report_private_constant :: proc(c: ^Compiler, name: Name, owner: string, symbol: ^Symbol) {
	if symbol == nil {
		return
	}
	warnf(
		c, name.span, "L0740",
		"public `%s` has the private type `%s`, which an importer cannot name",
		owner, identifier_text(c, symbol.name),
	)
	add_notef(c, symbol.span, "declared here; make it `@(public)` if it is part of the API")
}

// A private type the package whose scope is `scope` declares, which `type` is
// or holds as an element, a key, or a generic argument. A part that is one of
// `bound`, the types an instance binds to `$` names, is not read: it is what
// the parameter means, not a name the declaration writes.
@(private = "file")
private_type_in :: proc(c: ^Compiler, scope: ^Scope, type: Type_Id, bound: []Type_Id, depth: int) -> ^Symbol {
	info := type_of(c, type)
	if info == nil || depth > 8 || slice.contains(bound, type) {
		return nil
	}
	for id in ([]Symbol_Id{info.symbol, info.instance_of}) {
		symbol := symbol_of(c, id)
		if symbol != nil && symbol_names_type(c, symbol) && !symbol.public && symbol.decl != nil {
			declared := symbol_of(c, scope.names[symbol.name])
			if declared != nil && declared.decl == symbol.decl {
				return symbol
			}
		}
	}
	for argument in info.instance_args {
		if argument.is_type {
			if found := private_type_in(c, scope, argument.type, bound, depth + 1); found != nil {
				return found
			}
		}
	}
	#partial switch info.kind {
	case .Pointer, .C_Pointer, .Slice, .Dynamic_Array, .Array, .Box, .Simd:
		return private_type_in(c, scope, info.element, bound, depth + 1)
	case .Map:
		if found := private_type_in(c, scope, info.key, bound, depth + 1); found != nil {
			return found
		}
		return private_type_in(c, scope, info.element, bound, depth + 1)
	}
	return nil
}

// design.md "Private names in public declarations": a generic `impl`'s
// constant with no written type has no symbol in its template, so its value's
// type is read here instead. A value that names none of the block's `$` names
// has the same type in every instance, and is read at the declaration whether
// or not an instance exists; which it is, resolution decides, as for a `$`
// default: a speculative check of a copy against stand-ins for those names
// sees whether any lookup reached one. A value that names one is read per
// instance, by `check_instance_private_names`.
//
// A member whose value is a type is a type alias, whose target
// `check_private_names` reads by its syntax, as it does any alias's: a private
// alias of a public type is a name an importer cannot write, though the type
// it means is public. Its written type says so when it resolves to `type`, as
// for `Inner: type : Corner` or through an alias of `type`, and resolution here
// for a value that names no `$` name; one that does is a type when it is
// written as one, as `[]T` is, when it instantiates a generic record, as
// `Pair(T, Corner)` does, or when it selects a member that is a type, as
// `Box(T).Hidden` may, which `check_private_names` sees by the member's syntax.
read_generic_impl_constants :: proc(k: ^Checker, item: ^Item_Impl, template: ^Generic_Template) {
	call, is_call := item.type.(^Expr_Call)
	pkg := package_of(k.c, k.pkg)
	if !is_call || pkg == nil || pkg.scope == nil || len(pkg.files) == 0 || pkg.files[0].package_name == "main" {
		return
	}
	subject := symbol_of(k.c, template.symbol)
	if subject == nil {
		return
	}
	// The members of a private type are reached only through a value of it,
	// but an alias elsewhere may select one, so they are classified all the same.
	read := subject.pkg != k.pkg || subject.public
	names := make([dynamic]string, context.temp_allocator)
	poly_names(call, &names)
	stand_ins := new_scope(k.c, k.scope, .Local)
	for name in names {
		declare_stand_in(k, stand_ins, name, expr_span(call))
	}
	for member in item.members {
		d, is_decl := member.(^Decl)
		if !is_decl || !constant_value(d) {
			continue
		}
		// A written type says what the value is: `Inner: type : Corner` is an
		// alias, as is `Inner: Meta : Corner` for `Meta :: type`, and any other
		// type is read as written. One that names a `$` name says so only in an
		// instance, which `check_instance_private_names` reads.
		if d.declared_type != nil {
			probe := begin_probe(k.c)
			saved := k.scope
			k.scope = stand_ins
			stand_ins.reached = false
			declared := resolve_type_syntax(k, clone_expr(k.c, d.declared_type))
			k.scope = saved
			end_probe(k.c, probe)
			if declared == TYPE_TYPE && !stand_ins.reached {
				for name in d.names {
					k.c.generic_impl_types[name.span] = true
				}
			}
			continue
		}
		// A private alias is classified too, since a public one may select it.
		public := read && declaration_is_public(k, d)
		for name, index in d.names {
			if name.text == "_" || index >= len(d.values) {
				continue
			}
			probe := begin_probe(k.c)
			saved := k.scope
			k.scope = stand_ins
			stand_ins.reached = false
			type := check_single_expr(k, clone_expr(k.c, d.values[index]))
			k.scope = saved
			end_probe(k.c, probe)
			is_type := writes_type(d.values[index]) || (instantiates_generic_record(k, d.values[index]) if stand_ins.reached else type == TYPE_TYPE)
			if is_type {
				k.c.generic_impl_types[name.span] = true
			} else if public && !stand_ins.reached && type != INVALID_TYPE {
				read_impl_constant(k.c, pkg.scope, item, name, type, nil)
			}
		}
	}
}

// `Name(...)` where `Name` is a generic record, which a `$` name in the
// arguments leaves unresolved until an instance binds it.
@(private = "file")
instantiates_generic_record :: proc(k: ^Checker, value: Expr) -> bool {
	call, is_call := value.(^Expr_Call)
	return is_call && generic_template_of_callee(k, call.callee, .Record) != nil
}

// design.md "Private names in public declarations": a generic `impl`'s
// constant whose value names the block's `$` names has a type only in an
// instance, so it is read as each instance's block is checked, by the type its
// value has there. The types the instance binds to those names are passed
// over, since a `$` name names no type: a constant whose type differs between
// instances is warned about by the first that shows a private type of its own.
//
// The block's public declarations are read here too, by their syntax as the
// template's were: only an instance says whether a private member they select is
// a type, as `Box(T).Hidden` for `Hidden: T : Point` or `Hidden :: type_of(T{})`,
// and whether a member such as `Inner: T : Corner` is an alias at all. What is
// a type in only some instances is read in each, as `read_instance_declarations`
// says.
check_instance_private_names :: proc(k: ^Checker, pending: Pending_Impl) {
	c := k.c
	pkg := package_of(c, pending.pkg)
	if pkg == nil || pkg.scope == nil || len(pkg.files) == 0 || pkg.files[0].package_name == "main" {
		return
	}
	// The members of a private type are reached only through a value of it.
	subject_info := type_of(c, pending.impl_type)
	if subject_info == nil {
		return
	}
	if template := symbol_of(c, subject_info.instance_of); template != nil && template.pkg == pending.pkg && !template.public {
		return
	}
	bound := make([dynamic]Type_Id, context.temp_allocator)
	for _, id in pending.scope.names {
		if symbol := symbol_of(c, id); symbol != nil && symbol.generic_binding && symbol.kind == .Type {
			append(&bound, symbol.type)
		}
	}
	unread := make([dynamic]^Decl, context.temp_allocator)
	for member in pending.item.members {
		d, is_decl := member.(^Decl)
		if !is_decl {
			continue
		}
		if constant_value(d) && d.declared_type == nil {
			for name, index in d.names {
				symbol := symbol_of(c, d.symbols[index]) if index < len(d.symbols) else nil
				if symbol != nil && symbol.public && symbol.kind == .Const && !symbol_names_type(c, symbol) {
					read_impl_constant(c, pkg.scope, pending.item, name, symbol.type, bound[:])
				}
			}
		}
		if decl_is_public(c, pending.file_node, d) && instance_declaration_unread(c, d) {
			append(&unread, d)
		}
	}
	if len(unread) > 0 {
		read_instance_declarations(k, pkg, pending, unread[:])
	}
}

// Whether this instance shows anything of `d` that no earlier one has settled. A
// constant is an alias in the instances whose value is a type, and is otherwise
// read by its written type, each settled once, however many instances there are.
// A method whose bound excludes it from an instance says nothing there. With
// `settle`, what this instance showed is marked settled.
@(private = "file")
instance_declaration_unread :: proc(c: ^Compiler, d: ^Decl, settle := false) -> bool {
	unread := false
	for name, index in d.names {
		symbol := symbol_of(c, d.symbols[index]) if index < len(d.symbols) else nil
		if name.text == "_" || symbol == nil || symbol.bound_excluded || symbol.superseded {
			continue
		}
		read_as := name.span
		if constant_value(d) && !symbol_names_type(c, symbol) {
			if d.declared_type == nil {
				continue
			}
			read_as = expr_span(d.declared_type)
		}
		if !(read_as in c.private_constants_read) {
			if settle {
				c.private_constants_read[read_as] = true
			}
			unread = true
		}
	}
	return unread
}

@(private = "file")
read_instance_declarations :: proc(k: ^Checker, pkg: ^Package, pending: Pending_Impl, decls: []^Decl) {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		return
	}
	defer virtual.arena_destroy(&arena)
	_ = diagnostic_allocator(k.c)
	checker_allocator := context.allocator
	context.allocator = virtual.arena_allocator(&arena)

	x := exposure_of(k, pkg, checker_allocator)
	x.instance = true
	x.file = pending.file_node
	x.subject = subject_name(pending.item.type)
	bind_poly(&x, pending.item.type)
	mark := len(x.bound)
	x.scoped = mark
	for d in decls {
		// A member selected here may be a type in a later instance, as `Hidden: T : V`
		// is in `Holder(type, Point)` but not `Holder(int, 0)`, so what selects it is
		// read again; `found_name` warns once.
		x.undecided = false
		read_public_decl(&x, d, x.subject)
		resize(&x.bound, mark)
		if !x.undecided {
			instance_declaration_unread(k.c, d, settle = true)
		}
	}
}

// design.md "Private names in public declarations": a generic record's fields, a
// generic procedure's signature, a parametric alias's target, and a generic
// interface's requirements are syntax that names `$` names, as
// `Twin(Bag(T).Inferred, int)` does, which the template's reading could not
// resolve. Each is read here by that syntax in an instance, with the checker in the
// instance's scope. A procedure's instance is one a call selected, an interface's
// is an application a type satisfied, and a private procedure is read for a public
// group that exports it.
//
// A declaration that selects nothing from an instance has nothing to learn from
// one, and nearly all do, so a first read with no names to find says whether to
// build the table of them.
check_generic_private_names :: proc(k: ^Checker, read: Pending_Private_Read) {
	c := k.c
	d := read.decl
	pkg := package_of(c, read.pkg)
	if pkg == nil || pkg.scope == nil || len(pkg.files) == 0 || pkg.files[0].package_name == "main" ||
	   read.file_node == nil || len(d.values) == 0 {
		return
	}
	read_as := expr_span(d.values[0])
	if read_as in c.private_constants_read {
		return
	}
	literal := decl_proc_literal(d)
	public := decl_is_public(c, read.file_node, d)
	syntax := Exposure{k = k, c = c, scope = pkg.scope, instance = true, file = read.file_node}
	{
		context.allocator = context.temp_allocator
		if public {
			read_public_decl(&syntax, d, "")
		} else if literal != nil {
			read_signature(&syntax, literal)
		}
	}
	if !syntax.selects {
		c.private_constants_read[read_as] = true
		return
	}

	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		return
	}
	defer virtual.arena_destroy(&arena)
	_ = diagnostic_allocator(c)
	checker_allocator := context.allocator
	context.allocator = virtual.arena_allocator(&arena)

	x := exposure_of(k, pkg, checker_allocator)
	x.instance = true
	x.scoped = max(int)
	x.file = read.file_node
	if block, is_member := x.blocks[d.names[0].span]; is_member {
		if !impl_members_read(&x, block) {
			c.private_constants_read[read_as] = true
			return
		}
		x.subject = subject_name(block.type)
		bind_poly(&x, block.type)
	}
	if public {
		read_public_decl(&x, d, x.subject)
	} else if group := exporting_group(&x, pkg, d.names[0].text); group != "" {
		name := d.names[0].text
		start(&x, name if x.subject == "" else strings.concatenate({x.subject, ".", name}), group)
		read_signature(&x, literal)
	}
	if !x.undecided {
		c.private_constants_read[read_as] = true
	}
}

// The public group beside a private procedure that exports it, as it is reported,
// or "".
@(private = "file")
exporting_group :: proc(x: ^Exposure, pkg: ^Package, member: string) -> string {
	lists :: proc(x: ^Exposure, file: ^File, d: ^Decl, member: string) -> string {
		if !decl_is_public(x.c, file, d) {
			return ""
		}
		for value, index in d.values {
			group, is_group := value.(^Expr_Proc_Group)
			if !is_group || index >= len(d.names) {
				continue
			}
			for name in group.names {
				if name.text == member {
					return d.names[index].text
				}
			}
		}
		return ""
	}
	for file in pkg.files {
		for item in file.active_items {
			#partial switch v in item {
			case ^Decl:
				if x.subject == "" {
					if found := lists(x, file, v, member); found != "" {
						return found
					}
				}
			case ^Item_Impl:
				if x.subject == "" || subject_name(v.type) != x.subject {
					continue
				}
				for block_member in v.members {
					if d, is_decl := block_member.(^Decl); is_decl {
						if found := lists(x, file, d, member); found != "" {
							return strings.concatenate({x.subject, ".", found})
						}
					}
				}
			}
		}
	}
	return ""
}

// A constant whose value is neither a procedure, a group, nor a type's
// definition.
@(private = "file")
constant_value :: proc(d: ^Decl) -> bool {
	if d.kind != .Const || decl_proc_literal(d) != nil {
		return false
	}
	for value in d.values {
		#partial switch _ in value {
		case ^Expr_Proc_Group, ^Type_Record, ^Type_Enum, ^Type_Interface, ^Type_Distinct, ^Type_Proc:
			return false
		}
	}
	return true
}

// Reported once for each declaration, however many instances read it.
@(private = "file")
read_impl_constant :: proc(c: ^Compiler, scope: ^Scope, item: ^Item_Impl, name: Name, type: Type_Id, bound: []Type_Id) {
	if name.span in c.private_constants_read {
		return
	}
	found := private_type_in(c, scope, type, bound, 0)
	if found == nil {
		return
	}
	c.private_constants_read[name.span] = true
	owner := strings.concatenate({subject_name(item.type, context.temp_allocator), ".", name.text}, context.temp_allocator)
	report_private_constant(c, name, owner, found)
}

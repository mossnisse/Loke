package lokec

import "core:slice"
import "core:strings"

// design.md "Private names in public declarations": a public declaration that
// names a private declaration of its package is the warning L0740, since an
// importer can use the public one but cannot name what it names. The walk is
// over written syntax by name, as the interface file reads it;
// `read_generic_impl_constants`, `check_instance_private_names` and
// `check_generic_private_names` cover what only resolution or an instance can say.
check_private_names :: proc(k: ^Checker, package_id: Package_Id) {
	c := k.c
	pkg := package_of(c, package_id)
	if !package_exports_names(pkg) {
		return
	}
	x := exposure_of(k, pkg)
	for file in pkg.files {
		x.file = file
		k.file, k.file_node, k.scope = file.file, file, pkg.scope
		for item in file.active_items {
			#partial switch v in item {
			case ^Decl:
				if decl_is_public(c, file, v) {
					read_public_decl(&x, v)
				}
			case ^Item_Foreign_Block:
				for d in v.members {
					if decl_is_public(c, file, d, v.attributes) {
						read_public_decl(&x, d)
					}
				}
			case ^Item_Impl:
				read_impl(&x, v)
			}
		}
	}
}

// design.md "Exported names": nothing imports a `package main`.
@(private = "file")
package_exports_names :: proc(pkg: ^Package) -> bool {
	return pkg != nil && len(pkg.files) > 0 && pkg.files[0].package_name != "main"
}

// A read of `pkg`, whose scratch memory is the temporary allocator's.
@(private = "file")
exposure_of :: proc(k: ^Checker, pkg: ^Package) -> Exposure {
	return Exposure {
		k = k,
		c = k.c,
		scope = pkg.scope,
		names = package_names(k.c, pkg),
		bound = make([dynamic]string, context.temp_allocator),
		reported = make([dynamic]string, context.temp_allocator),
		read_members = make(map[^Decl]bool, context.temp_allocator),
	}
}

// Each declaration of a package by its name, and each `impl`'s members by the
// written name of its subject, built once its bodies are checked. A generic
// declaration's instances are read after that, so they share it.
Package_Names :: struct {
	declared: map[string]Named,
	members:  map[string]map[string]Named,
	// The `impl` each member is declared in, by its name's span.
	blocks:   map[Span]^Item_Impl,
	// What each `impl` itself declares, which a group in it means first, by the
	// block's span: an instance reads a copy of the block.
	own_members: map[Span]map[string]Named,
}

@(private = "file")
package_names :: proc(c: ^Compiler, pkg: ^Package) -> ^Package_Names {
	if pkg.declared_names == nil {
		context.allocator = c.semantic_allocator
		pkg.declared_names = new(Package_Names)
		for file in pkg.files {
			collect_named(c, pkg.declared_names, file)
		}
		for file in pkg.files {
			collect_group_exports(c, pkg.declared_names, file)
		}
	}
	return pkg.declared_names
}

@(private = "file")
Exposure :: struct {
	k:        ^Checker,
	c:        ^Compiler,
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
	names:    ^Package_Names,
	// The `impl` being read and its written subject, or nil and "".
	block:    ^Item_Impl,
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
	// Another block on this written subject declares the name, as `impl Box(int)`
	// and `impl Box(string)` may: only resolution knows which a selection means.
	several: bool,
	// The first public group beside it that lists it, by its name.
	group:   string,
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
collect_named :: proc(c: ^Compiler, names: ^Package_Names, file: ^File) {
	for item in file.active_items {
		#partial switch v in item {
		case ^Decl:
			add_named(c, file, &names.declared, v, nil)
		case ^Item_Foreign_Block:
			for d in v.members {
				add_named(c, file, &names.declared, d, v.attributes)
			}
		case ^Item_Impl:
			subject := subject_name(c, v.type)
			if !(subject in names.members) {
				names.members[subject] = make(map[string]Named)
			}
			members := &names.members[subject]
			names.own_members[v.span] = make(map[string]Named)
			own := &names.own_members[v.span]
			for member in v.members {
				if d, is_decl := member.(^Decl); is_decl {
					add_named(c, file, members, d, nil)
					add_named(c, file, own, d, nil)
					names.blocks[d.names[0].span] = v
				}
			}
		}
	}
}

@(private = "file")
add_named :: proc(c: ^Compiler, file: ^File, into: ^map[string]Named, d: ^Decl, block: []Attribute) {
	if d.kind == .Var {
		return // never public, and never in a signature
	}
	name := d.names[0]
	if name.text == "_" {
		return
	}
	named := named_of(c, decl_symbol(c, d), d, name.span)
	named.public = decl_is_public(c, file, d, block)
	if named.unresolved {
		// A generic `impl`'s member, which no symbol records: whether an
		// alias is a type, `read_generic_impl_constants` decided.
		named.is_proc = decl_proc_literal(d) != nil
		named.is_type = name.span in c.generic_impl_types
		if len(d.values) > 0 {
			named.value = d.values[0]
			named.is_type ||= writes_type(named.value)
		}
	}
	_, named.several = into[name.text]
	into[name.text] = named
}

// What `symbol` says of `d`, or with none, that it is unresolved.
@(private = "file")
named_of :: proc(c: ^Compiler, symbol: ^Symbol, d: ^Decl, span: Span) -> Named {
	if symbol == nil {
		return Named{decl = d, span = span, unresolved = true}
	}
	return Named {
		decl = d,
		span = span,
		public = symbol.public,
		is_type = symbol_names_type(c, symbol),
		is_proc = symbol.kind == .Proc,
	}
}

// The symbol of a constant, which binds one name, if it has one.
@(private = "file")
decl_symbol :: proc(c: ^Compiler, d: ^Decl) -> ^Symbol {
	return symbol_of(c, d.symbols[0]) if len(d.symbols) > 0 else nil
}

// Which public group exports each private procedure, as it is reported.
@(private = "file")
collect_group_exports :: proc(c: ^Compiler, names: ^Package_Names, file: ^File) {
	for item in file.active_items {
		#partial switch v in item {
		case ^Decl:
			note_group_exports(c, file, names, nil, v)
		case ^Item_Impl:
			for member in v.members {
				if d, is_decl := member.(^Decl); is_decl {
					note_group_exports(c, file, names, v, d)
				}
			}
		}
	}
}

@(private = "file")
note_group_exports :: proc(c: ^Compiler, file: ^File, names: ^Package_Names, block: ^Item_Impl, d: ^Decl) {
	if len(d.values) == 0 {
		return
	}
	group, is_group := d.values[0].(^Expr_Proc_Group)
	if !is_group || !decl_is_public(c, file, d) {
		return
	}
	for name in group.names {
		if named := group_member(c, names, block, name.text); named != nil && named.group == "" {
			named.group = d.names[0].text
		}
	}
}

// What a group in `block`, or at file scope with none, lists by `name`: an `impl`'s
// members in one (L0395), or else the package's. Blocks of one generic type each
// declare for their own instances, so the group's own block answers first, and
// another block on its subject only for a name its own does not declare.
@(private = "file")
group_member :: proc(c: ^Compiler, names: ^Package_Names, block: ^Item_Impl, name: string) -> ^Named {
	if block == nil {
		return &names.declared[name] if name in names.declared else nil
	}
	if own, declared := &names.own_members[block.span]; declared && name in own {
		return &own[name]
	}
	if shared, declared := &names.members[subject_name(c, block.type)]; declared && name in shared {
		return &shared[name]
	}
	return nil
}

// `Name` of `impl Name`, `impl Name($T)`, and `impl ^Name`, and otherwise the
// subject as written, as `pkg.Name` or `[]Name`.
subject_name :: proc(c: ^Compiler, e: Expr) -> string {
	#partial switch v in e {
	case ^Expr_Call:
		return subject_name(c, v.callee)
	case ^Type_Pointer:
		return subject_name(c, v.elem)
	}
	return source_text(c, e)
}

@(private = "file")
qualified :: proc(subject, name: string) -> string {
	return name if subject == "" else strings.concatenate({subject, ".", name}, context.temp_allocator)
}

// design.md "Private names in public declarations": the members of an `impl`
// whose subject is a private type are reached only through a value of it, so
// the declaration that hands one out is the one reported.
@(private = "file")
read_impl :: proc(x: ^Exposure, v: ^Item_Impl) {
	if !impl_members_read(x, v) {
		return
	}
	enter_block(x, v)
	defer {
		x.block, x.subject = nil, ""
		clear(&x.bound)
	}
	for member in v.members {
		if d, is_decl := member.(^Decl); is_decl && decl_is_public(x.c, x.file, d) {
			read_public_decl(x, d)
		}
	}
}

@(private = "file")
enter_block :: proc(x: ^Exposure, v: ^Item_Impl) {
	x.block, x.subject = v, subject_name(x.c, v.type)
	bind_poly_names(&x.bound, v.type)
}

@(private = "file")
impl_members_read :: proc(x: ^Exposure, v: ^Item_Impl) -> bool {
	named, declared := x.names.declared[subject_name(x.c, v.type)]
	return !declared || !named.is_type || named.public || subject_type_is_public(x.c, v)
}

// A block written through a private alias of a public type, as `impl Short(int)`
// for `Short :: Box($T)`, is on that public type, whose values an importer has.
// A generic block's subject is resolved only per instance, and a block cannot
// apply an alias to `$` names, so such a block names the private type itself.
subject_type_is_public :: proc(c: ^Compiler, v: ^Item_Impl) -> bool {
	info := type_of(c, v.subject)
	if info != nil && info.kind == .Pointer {
		info = type_of(c, info.element)
	}
	if info == nil {
		return false
	}
	declared := symbol_of(c, info.instance_of)
	if declared == nil {
		declared = symbol_of(c, info.symbol)
	}
	return declared != nil && declared.public
}

@(private = "file")
read_public_decl :: proc(x: ^Exposure, d: ^Decl) {
	name := d.names[0]
	start(x, qualified(x.subject, name.text), "")
	walk(x, d.declared_type, .Type)
	if literal := decl_proc_literal(d); literal != nil {
		read_signature(x, literal)
		return
	}
	if len(d.values) == 0 {
		return
	}
	symbol := decl_symbol(x.c, d)
	value := d.values[0]
	#partial switch v in value {
	case ^Expr_Proc_Group:
		read_group(x, v)
	case ^Type_Record:
		read_record(x, v)
	case ^Type_Interface:
		read_interface(x, v)
	case ^Type_Enum:
		walk(x, v.backing, .Type)
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
			// A parametric alias binds the `$` names its target writes, which
			// mean that parameter wherever they appear in it, whatever the
			// package declares by the same name.
			mark := len(x.bound)
			bind_poly_names(&x.bound, value)
			walk(x, value, .Type)
			resize(&x.bound, mark)
		} else if !x.instance && d.declared_type == nil && symbol != nil && symbol.kind == .Const {
			// A constant with no written type has the type of its value, as
			// `Fill` for `DEFAULT :: Fill{}`.
			if found := private_type_in(x.c, x.scope, symbol.type, nil); found != nil {
				report_private_constant(x.c, name, x.owner, found)
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
	bind_signature(&x.bound, signature)
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
read_group :: proc(x: ^Exposure, group: ^Expr_Proc_Group) {
	owner := x.owner
	for name in group.names {
		named := group_member(x.c, x.names, x.block, name.text)
		if named == nil || named.public || !named.is_proc || named.decl in x.read_members {
			continue
		}
		x.read_members[named.decl] = true
		start(x, qualified(x.subject, name.text), owner)
		read_signature(x, decl_proc_literal(named.decl))
	}
}

@(private = "file")
read_record :: proc(x: ^Exposure, record: ^Type_Record) {
	owner := x.owner
	mark := len(x.bound)
	defer resize(&x.bound, mark)
	bind_generic_params(&x.bound, record.generic_params)
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
		if !field_is_exported(x.c, x.file, &field) {
			continue
		}
		for name in field.names {
			if name.text != "_" {
				start(x, strings.concatenate({owner, ".", name.text}, context.temp_allocator), "")
				walk(x, field.type, .Type)
			}
		}
	}
}

@(private = "file")
read_interface :: proc(x: ^Exposure, v: ^Type_Interface) {
	mark := len(x.bound)
	defer resize(&x.bound, mark)
	bind_generic_params(&x.bound, v.generic_params)
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

@(private = "file")
Exposure_Walk :: struct {
	x:        ^Exposure,
	position: Position,
}

// An array's length and a parameter's default are values, read only in a `where`
// clause (design.md "Private names in public declarations").
@(private = "file")
walk :: proc(x: ^Exposure, e: Expr, position: Position) {
	mark := len(x.bound)
	defer resize(&x.bound, mark)
	#partial switch v in e {
	case ^Expr_Ident:
		if named, found := x.names.declared[v.name]; found && !slice.contains(x.bound[:], v.name) {
			found_name(x, v.name, v.span, v, named, position)
		}
	case ^Expr_Selector:
		if written, named, found := selected_member(x, v); found {
			found_name(x, written, v.name.span, v, named, position)
		}
	case ^Type_Array:
		if position != .Where {
			walk(x, v.elem, position)
			return
		}
	case ^Expr_Call:
		if position != .Where && walk_application(x, v) {
			return
		}
	case ^Type_Proc:
		bind_signature(&x.bound, v)
		if position != .Where {
			for parameter in v.params {
				walk(x, parameter.type, position)
			}
			if v.result != nil {
				walk(x, v.result.type, position)
			}
			return
		}
	}
	walking := Exposure_Walk{x, position}
	expr_children(e, &walking, proc(data: rawptr, child: Expr) -> bool {
		walking := (^Exposure_Walk)(data)
		walk(walking.x, child, walking.position)
		return false
	})
}

// `Name(...)` where `Name` is a generic type or a parametric alias: an argument of a
// constant parameter is a value, whatever it names, and only the others are types.
// False for anything else, which has no parameters to read. A parameter whose type
// did not resolve is reported where it is declared, so these questions are probes.
@(private = "file")
walk_application :: proc(x: ^Exposure, call: ^Expr_Call) -> bool {
	if callee, is_name := call.callee.(^Expr_Ident); is_name && slice.contains(x.bound[:], callee.name) {
		return false
	}
	probe := begin_probe(x.c)
	applied := applied_parameters(x.k, call.callee)
	end_probe(x.c, probe)
	if applied.params == nil {
		return false
	}
	walk(x, call.callee, .Type)
	for argument, index in call.args {
		if !argument_is_value(x, call, applied, applied.first + index) {
			walk(x, argument.value, .Type)
		}
	}
	return true
}

// Whether the parameter at `at` takes a value in this application. `$V: T` takes a
// type where `T` is `type`, and `$V: Kind_Of(T)` where that call gives `type`, so its
// type is asked for with the arguments before it bound. What an argument decides
// through a `$` name has no one answer, and what it selects is read in each instance.
@(private = "file")
argument_is_value :: proc(x: ^Exposure, call: ^Expr_Call, applied: Applied_Parameters, at: int) -> bool {
	if at >= len(applied.params) {
		return false
	}
	probe := begin_probe(x.c)
	defer end_probe(x.c, probe)
	kind, dependent := generic_parameter_kind(x.k, applied, at)
	if !dependent {
		return kind != TYPE_TYPE && kind != INVALID_TYPE
	}
	// An argument written with a `$` name is known only in each instance. There, only a
	// name or a call can come to be `type`: `$V: []T` is a value whatever `T` is.
	for argument in call.args[:min(at - applied.first, len(call.args))] {
		if names_bound(x, argument.value) {
			if applied.alias != nil {
				return false
			}
			#partial switch _ in applied.params[at].type_syntax {
			case ^Expr_Ident, ^Expr_Call:
				return false
			}
			return true
		}
	}
	saved := x.k.location
	defer x.k.location = saved
	type := applied_parameter_type(x.k, clone_expr(x.c, call).(^Expr_Call).args, applied, at, x.k.scope, report = false)
	return type != TYPE_TYPE && type != INVALID_TYPE
}

// Whether `e` writes a `$` name, whether or not the checker's scope binds it.
@(private = "file")
names_bound :: proc(x: ^Exposure, e: Expr) -> bool {
	return type_syntax_any_name(e, x, proc(data: rawptr, node: Expr) -> bool {
		#partial switch v in node {
		case ^Type_Poly:
			return true
		case ^Expr_Ident:
			return slice.contains((^Exposure)(data).bound[:], v.name)
		}
		return false
	})
}

// The member of an `impl` of the package that `Subject.member` or, from an
// instance, `Subject(...).member` selects, and its name as `Subject.member`; an
// import's name is no declaration of the package. A generic `impl`'s member
// that itself selects one is a type when that one is. A chain of selections is
// followed until it repeats a member.
@(private = "file")
selected_member :: proc(x: ^Exposure, e: Expr) -> (written: string, named: Named, found: bool) {
	written, named = member_selected(x, e) or_return
	passed := make([dynamic]Span, context.temp_allocator)
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
	members := x.names.members[subject.name] or_return
	named = members[selector.name.text] or_return
	written = strings.concatenate({subject.name, ".", selector.name.text}, context.temp_allocator)
	if named.several {
		named = member_resolved(x, selector) or_return
	}
	return written, named, true
}

// The member a selection means when several blocks of its subject declare that
// name, which a later instance may answer otherwise. Syntax that means nothing
// here has no answer yet.
@(private = "file")
member_resolved :: proc(x: ^Exposure, selector: ^Expr_Selector) -> (named: Named, found: bool) {
	x.undecided = true
	if names_unscoped(x, selector) {
		return
	}
	checked := clone_expr(x.c, selector)
	probe := begin_probe(x.c)
	check_single_expr(x.k, checked)
	end_probe(x.c, probe)
	symbol := symbol_of(x.c, expr_base(checked).resolution.symbol)
	if symbol == nil {
		return
	}
	return named_of(x.c, symbol, symbol.decl, symbol.span), true
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
	opening := strings.concatenate({"public `", x.owner, "`"}, context.temp_allocator)
	if x.group != "" {
		opening = strings.concatenate({"`", x.owner, "`, which the public group `", x.group, "` exports,"}, context.temp_allocator)
	}
	where_clause := position == .Where
	warnf(
		x.c, span, "L0740",
		"%s names the private %s`%s`%s, which an importer cannot name",
		opening, "type " if is_type && !where_clause else "", written, " in a `where` clause" if where_clause else "",
	)
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

@(private = "file")
report_private_constant :: proc(c: ^Compiler, name: Name, owner: string, symbol: ^Symbol) {
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
private_type_in :: proc(c: ^Compiler, scope: ^Scope, type: Type_Id, bound: []Type_Id) -> ^Symbol {
	seen := make([dynamic]Type_Id, 0, len(bound) + 8, context.temp_allocator)
	append(&seen, ..bound)
	return private_type_reached(c, scope, type, &seen)
}

@(private = "file")
private_type_reached :: proc(c: ^Compiler, scope: ^Scope, type: Type_Id, seen: ^[dynamic]Type_Id) -> ^Symbol {
	info := type_of(c, type)
	if info == nil || slice.contains(seen[:], type) {
		return nil
	}
	append(seen, type)
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
			if found := private_type_reached(c, scope, argument.type, seen); found != nil {
				return found
			}
		}
	}
	#partial switch info.kind {
	case .Pointer, .C_Pointer, .Slice, .Dynamic_Array, .Array, .Box, .Simd:
		return private_type_reached(c, scope, info.element, seen)
	case .Map:
		if found := private_type_reached(c, scope, info.key, seen); found != nil {
			return found
		}
		return private_type_reached(c, scope, info.element, seen)
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
// A member whose value is a type is a type alias, read by its target's syntax in
// `check_private_names`.
read_generic_impl_constants :: proc(k: ^Checker, item: ^Item_Impl, call: ^Expr_Call, template: ^Generic_Template) {
	pkg := package_of(k.c, k.pkg)
	if !package_exports_names(pkg) {
		return
	}
	subject := symbol_of(k.c, template.symbol)
	if subject == nil {
		return
	}
	// The members of a private type are reached only through a value of it,
	// but an alias elsewhere may select one, so they are classified all the same.
	read := !is_private_to(subject, k.pkg)
	names := make([dynamic]string, context.temp_allocator)
	bind_poly_names(&names, call)
	stand_ins := new_scope(k.c, k.scope, .Local)
	for name in names {
		declare_stand_in(k, stand_ins, name, expr_span(call))
	}
	for member in item.members {
		d, is_decl := member.(^Decl)
		if !is_decl || !constant_value(d) || d.names[0].text == "_" {
			continue
		}
		public := read && d.declared_type == nil && declaration_is_public(k, d)
		is_type, type := member_is_type(k, stand_ins, d)
		if is_type {
			k.c.generic_impl_types[d.names[0].span] = true
		} else if public && type != INVALID_TYPE {
			read_impl_constant(k.c, pkg.scope, item, d.names[0], type, nil)
		}
	}
}

// Whether a generic `impl`'s constant is a type alias, and if it is not, the
// type its value has in every instance, when it has one.
@(private = "file")
member_is_type :: proc(k: ^Checker, stand_ins: ^Scope, d: ^Decl) -> (is_type: bool, type: Type_Id) {
	if d.declared_type != nil {
		declared, reached := check_against_stand_ins(k, stand_ins, d.declared_type, as_type = true)
		return declared == TYPE_TYPE && !reached, INVALID_TYPE
	}
	value := d.values[0]
	checked, reached := check_against_stand_ins(k, stand_ins, value, as_type = false)
	if writes_type(value) {
		return true, INVALID_TYPE
	}
	if reached {
		return applies_generic_type(k, value), INVALID_TYPE
	}
	return checked == TYPE_TYPE, checked
}

// A speculative check of a copy of `e`, and whether any lookup reached a stand-in.
@(private)
check_against_stand_ins :: proc(k: ^Checker, stand_ins: ^Scope, e: Expr, as_type: bool) -> (type: Type_Id, reached: bool) {
	probe := begin_probe(k.c)
	saved := k.scope
	k.scope = stand_ins
	stand_ins.reached = false
	copy := clone_expr(k.c, e)
	type = resolve_type_syntax(k, copy) if as_type else check_single_expr(k, copy)
	k.scope = saved
	end_probe(k.c, probe)
	return type, stand_ins.reached
}

@(private = "file")
is_private_to :: proc(symbol: ^Symbol, pkg: Package_Id) -> bool {
	return symbol.pkg == pkg && !symbol.public
}

// `Name(...)` where `Name` is a generic record or a parametric alias, which a `$`
// name in the arguments leaves unresolved until an instance binds it.
@(private = "file")
applies_generic_type :: proc(k: ^Checker, value: Expr) -> bool {
	call, is_call := value.(^Expr_Call)
	if !is_call {
		return false
	}
	return generic_template_of_callee(k, call.callee, TYPE_GENERICS) != nil
}

// design.md "Private names in public declarations": a generic `impl`'s
// constant whose value names the block's `$` names has a type only in an
// instance, so it is read as each instance's block is checked, by the type its
// value has there. The types the instance binds to those names are passed
// over, since a `$` name names no type: a constant whose type differs between
// instances is warned about by the first that shows a private type of its own.
//
// The block's public declarations are read here too, since only an instance says
// whether a private member they select is a type.
check_instance_private_names :: proc(k: ^Checker, pending: Pending_Impl) {
	c := k.c
	pkg := package_of(c, pending.pkg)
	if !package_exports_names(pkg) {
		return
	}
	subject_info := type_of(c, pending.impl_type)
	if subject_info == nil {
		return
	}
	if template := symbol_of(c, subject_info.instance_of); template != nil && is_private_to(template, pending.pkg) {
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
			symbol := decl_symbol(c, d)
			if symbol != nil && symbol.public && symbol.kind == .Const && !symbol_names_type(c, symbol) {
				read_impl_constant(c, pkg.scope, pending.item, d.names[0], symbol.type, bound[:])
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
	symbol := decl_symbol(c, d)
	if symbol == nil || symbol.bound_excluded || symbol.superseded {
		return false
	}
	read_as := d.names[0].span
	if constant_value(d) && !symbol_names_type(c, symbol) {
		if d.declared_type == nil {
			return false
		}
		read_as = expr_span(d.declared_type)
	}
	if read_as in c.private_reads_settled {
		return false
	}
	if settle {
		c.private_reads_settled[read_as] = true
	}
	return true
}

@(private = "file")
read_instance_declarations :: proc(k: ^Checker, pkg: ^Package, pending: Pending_Impl, decls: []^Decl) {
	x := exposure_of(k, pkg)
	x.instance = true
	x.file = pending.file_node
	enter_block(&x, pending.item)
	x.scoped = len(x.bound)
	for d in decls {
		// A member selected here may be a type in a later instance, as `Hidden: T : V`
		// is in `Holder(type, Point)` but not `Holder(int, 0)`, so what selects it is
		// read again; `found_name` warns once.
		x.undecided = false
		read_public_decl(&x, d)
		if !x.undecided {
			instance_declaration_unread(k.c, d, settle = true)
		}
	}
}

// design.md "Private names in public declarations": a generic declaration's syntax
// is read per instance, with the checker in its scope.
check_generic_private_names :: proc(k: ^Checker, read: Pending_Private_Read) {
	c := k.c
	d := read.decl
	pkg := package_of(c, read.pkg)
	if !package_exports_names(pkg) || read.file_node == nil || len(d.values) == 0 {
		return
	}
	read_as := expr_span(d.values[0])
	if read_as in c.private_reads_settled {
		return
	}
	x := exposure_of(k, pkg)
	x.instance = true
	x.scoped = max(int)
	x.file = read.file_node
	name := d.names[0]
	if block, is_member := x.names.blocks[name.span]; is_member {
		if !impl_members_read(&x, block) {
			c.private_reads_settled[read_as] = true
			return
		}
		enter_block(&x, block)
	}
	if decl_is_public(c, read.file_node, d) {
		read_public_decl(&x, d)
	} else if literal := decl_proc_literal(d); literal != nil {
		named := group_member(c, x.names, x.block, name.text)
		if named != nil && named.group != "" {
			start(&x, qualified(x.subject, name.text), qualified(x.subject, named.group))
			read_signature(&x, literal)
		}
	}
	if !x.undecided {
		c.private_reads_settled[read_as] = true
	}
}

@(private = "file")
constant_value :: proc(d: ^Decl) -> bool {
	if d.kind != .Const || decl_proc_literal(d) != nil || len(d.values) == 0 {
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
	if name.span in c.private_reads_settled {
		return
	}
	found := private_type_in(c, scope, type, bound)
	if found == nil {
		return
	}
	c.private_reads_settled[name.span] = true
	report_private_constant(c, name, qualified(subject_name(c, item.type), name.text), found)
}

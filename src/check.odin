// Name resolution and type checking for declarations, statements, signatures,
// and type syntax; `check_expr.odin` owns everything that produces a value.
// Annotations are written back onto the AST nodes (decision A1).
package lokec

import "core:strings"

Checker :: struct {
	c:     ^Compiler,
	// Uses that trap on `nil`, pending the rest of the body that decides whether
	// the local can be anything else (`nil_uses.odin`).
	nil_uses: [dynamic]Nil_Use,
	// Foreign signatures that named a record still resolving its fields
	// (`check_deferred_foreign_signatures`).
	deferred_foreign_signatures: [dynamic]Foreign_Signature,
	file:  u32,
	// The file being checked. Its package-clause attributes decide the default
	// visibility of the declarations in it.
	file_node: ^File,
	scope: ^Scope,
	pkg:   Package_Id,
	// The package whose method, operator, and extension tables the declaration
	// being checked may use. Usually `pkg`; `delegate` freezes its own.
	lookup_pkg: Package_Id,
	// The `impl` subject whose block is being checked, which is what an
	// untyped `self` receiver takes its type from.
	impl_type:  Type_Id,
	// Set while the callee of a call is being checked, so a method selector knows
	// it is about to be called rather than used as a value.
	in_callee:  bool,
	// design.md "Indexing and slicing": a place position requires an `inout`
	// `operator([])`. Consumed by the node it is set for.
	place_position: bool,
	// design.md "Maps": set only for the destination of a plain assignment, the
	// one position where `m[key]` may create an entry.
	insert_position: bool,
	// How many generic instantiations enclose the code being checked.
	generic_depth:  int,
	// How deep interface requirement checking is, so an interface that composes
	// itself is a diagnostic rather than a spin.
	interface_depth: int,

	// The procedure being checked, and so the frame a name may come from.
	proc_literal:   ^Expr_Proc,
	// design.md: at most one result. INVALID_TYPE means the procedure has none.
	result_type:    Type_Id,
	// Whether the result was declared `inout`, so `return` must hand out a place.
	result_inout:   bool,

	// Lexical loop targets for `break` and `continue`, and defer restrictions.
	loop_depth: int,
	in_defer:   bool,
	// One flag slot per syntactic `defer` in the procedure being checked.
	defer_slots:  int,
}

// What a statement can do to control flow.
Flow_Info :: struct {
	can_fall_through: bool,
	returns:          bool,
	breaks:           bool,
	continues:        bool,
}

FLOWS :: Flow_Info{can_fall_through = true}

// Scope, declarations, nominal shells, and import aliases, for whatever is
// active so far. Every step guards against repeating itself, so a later
// discovery round only does what a newly selected branch added.
prepare_package :: proc(k: ^Checker, package_id: Package_Id) {
	pkg := package_of(k.c, package_id)
	if pkg == nil {
		return
	}
	if pkg.scope == nil {
		pkg.scope = new_scope(k.c, build_universe(k.c), .Package)
	}
	// First, so a declaration colliding with a contributed name is a redeclaration.
	contribute_standard_members(k, pkg)
	k.pkg = package_id
	k.lookup_pkg = package_id
	k.scope = pkg.scope

	for file in pkg.files {
		k.file, k.file_node = file.file, file
		for item in file.active_items {
			#partial switch v in item {
			case ^Decl:
				declare_all(k, v, top_level = true)
			case ^Item_Foreign_Block:
				// Foreign members are ordinary symbols (design.md "Foreign system").
				declare_foreign_block(k, v)
			}
		}
	}
	for file in pkg.files {
		k.file, k.file_node = file.file, file
		for item in file.active_items {
			if d, ok := item.(^Decl); ok {
				create_nominal_type_shell(k, d)
			}
		}
	}
	// design.md "Typed fallibility": the bootstrap declarations join the universe
	// once `base:runtime`'s names exist, before any other package is prepared.
	bind_runtime_bootstrap(k, pkg)
	// Before `impl` blocks, which may name their subject as `vendor.Vector2`.
	bind_import_aliases(k, pkg)
	// Only blocks whose subject's package (and its imports) has no pending `when`:
	// declaring a block resolves its subject once, and a record's fields may come
	// from a branch not selected yet, as `core:fs`'s `File.handle` does. Any block
	// left is declared by `resolve_impl_signatures`.
	for file in pkg.files {
		k.file, k.file_node = file.file, file
		for item in file.active_items {
			impl, ok := item.(^Item_Impl)
			if ok && !package_closure_has_pending_whens(k.c, impl_subject_package(k, impl)) {
				declare_impl_block(k, impl)
			}
		}
	}
}

// The package whose scope an `impl` subject is written in, read off the syntax
// because resolving it is what is being gated.
@(private = "file")
impl_subject_package :: proc(k: ^Checker, item: ^Item_Impl) -> Package_Id {
	subject := item.type
	if call, is_call := subject.(^Expr_Call); is_call {
		subject = call.callee // `impl vendor.Table($K, $V)`
	}
	selector, is_selector := subject.(^Expr_Selector)
	if !is_selector {
		return k.pkg
	}
	ident, is_ident := selector.operand.(^Expr_Ident)
	if !is_ident {
		return k.pkg
	}
	sym := symbol_of(k.c, lookup_symbol(k.scope, identifier_of(k.c, ident)))
	return sym != nil && sym.kind == .Package_Alias ? sym.pkg : k.pkg
}

// design.md: an import name is a lexical alias for a `Package_Id`, nothing more.
@(private = "file")
bind_import_aliases :: proc(k: ^Checker, pkg: ^Package) {
	// Only the edges a previous round did not reach, so a collision reports once.
	defer pkg.bound_aliases = len(pkg.imports)
	for index in pkg.bound_aliases ..< len(pkg.imports) {
		edge := pkg.imports[index]
		if edge.target == INVALID_PACKAGE || edge.alias == "" {
			continue
		}
		name := intern_identifier(k.c, edge.alias)
		if existing, bound := pkg.scope.names[name]; bound {
			symbol := symbol_of(k.c, existing)
			if symbol != nil && symbol.kind == .Package_Alias && symbol.pkg == edge.target {
				continue // the same package under the same name, from another file
			}
			errorf(k.c, edge.span, "L0331", "`%s` is already declared in this package", edge.alias)
			continue
		}
		pkg.scope.names[name] = new_symbol(k.c, Symbol {
			name = name,
			span = edge.span,
			kind = .Package_Alias,
			type = TYPE_VOID,
			pkg  = edge.target,
		})
	}
}

// Signatures, finite size, and bodies, over the settled selected view. This
// runs only once the whole program's selection and import graph are stable.
check_package_bodies :: proc(k: ^Checker, package_id: Package_Id) {
	pkg := package_of(k.c, package_id)
	if pkg == nil || pkg.scope == nil {
		return
	}
	k.pkg = package_id
	k.lookup_pkg = package_id

	// Phase 2b: fields and callable signatures.
	for file in pkg.files {
		k.file, k.file_node, k.scope = file.file, file, pkg.scope
		for item in file.active_items {
			#partial switch v in item {
			case ^Decl:
				resolve_declaration_signature(k, v)
			case ^Item_Impl:
				resolve_impl_signatures(k, v)
			case ^Item_Foreign_Block:
				check_foreign_block(k, v)
			}
		}
	}

	// design.md "Attributes": after signatures, so a procedure group's symbol
	// kind is known.
	validate_attributes(k, pkg)

	// Every record has its fields now.
	check_deferred_foreign_signatures(k)

	// Phase 2c: reject a type that contains itself by value.
	for file in pkg.files {
		k.file, k.file_node, k.scope = file.file, file, pkg.scope
		for item in file.active_items {
			if d, ok := item.(^Decl); ok {
				check_declaration_size(k, d)
			}
		}
	}

	// Phase 3: type checking and constant folding.
	for file in pkg.files {
		k.file, k.file_node, k.scope = file.file, file, pkg.scope
		for item in file.active_items {
			#partial switch v in item {
			case ^Decl:
				check_decl(k, v)
			case ^Item_Impl:
				check_impl_block(k, v)
			case ^Item_Import, ^Item_Foreign_Import, ^Item_Foreign_Block, ^Item_Error:
			case ^Item_Static_Assert:
			case:
				unsupported_construct(k, item_span(item))
			}
		}
	}

	// Phase 3b: file-scope assertions, after every declaration, so they do not
	// depend on declaration order.
	for file in pkg.files {
		k.file, k.file_node, k.scope = file.file, file, pkg.scope
		for item in file.active_items {
			if v, ok := item.(^Item_Static_Assert); ok {
				check_file_scope_static_assert(k, v)
			}
		}
	}
	// And any a body's own procedure type deferred.
	check_deferred_foreign_signatures(k)
}

@(private = "file")
check_file_scope_static_assert :: proc(k: ^Checker, item: ^Item_Static_Assert) {
	call, is_call := item.call.(^Expr_Call)
	if !is_call {
		return // the parser already rejected the malformed item shape
	}
	ident, is_ident := call.callee.(^Expr_Ident)
	if !is_ident {
		return // likewise: file-scope syntax admits only the unqualified spelling
	}
	symbol := symbol_of(k.c, lookup_symbol(k.scope, identifier_of(k.c, ident)))
	if symbol == nil || symbol.kind != .Builtin || symbol.builtin != .Static_Assert {
		errorf(
			k.c,
			ident.span,
			"L0387",
			"a file-scope `static_assert` must name the predeclared built-in",
		)
		return
	}
	check_expr(k, call)
}

@(private = "file")
create_nominal_type_shell :: proc(k: ^Checker, d: ^Decl) {
	if len(d.values) != 1 || len(d.symbols) != 1 || d.symbols[0] == INVALID_SYMBOL {
		return
	}
	symbol := symbol_of(k.c, d.symbols[0])
	if symbol == nil || symbol.kind == .Type {
		return // already given its shell in an earlier round
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
	move_only := false
	if record, ok := d.values[0].(^Type_Record); ok {
		move_only = record.move_only
	}
	symbol.type = new_type(k.c, Type_Info{kind = kind, name = symbol.name, symbol = d.symbols[0], move_only = move_only})
	if base := expr_base(d.values[0]); base != nil {
		base.denoted_type = symbol.type
		base.resolution = Resolution{kind = .Type, symbol = d.symbols[0]}
		base.value_category = .Type
	}
}

validate_executable :: proc(c: ^Compiler, package_id: Package_Id) {
	c.entry_point = INVALID_SYMBOL
	errors_before := c.error_count
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
	} else if info := type_of(c, symbol.proc_type); info == nil || len(info.parameters) != 0 || info.result != INVALID_TYPE {
		errorf(c, symbol.span, "L0303", "`main` must have no parameters and no results: `main :: proc() { ... }`")
	} else if c.error_count == errors_before {
		c.entry_point = entry
	}
}

// design.md "@(export)": a whole-program pass, so clashing external symbols are
// reported with locations rather than failing at link time.
check_exports :: proc(c: ^Compiler) {
	claimed := make(map[string]Span, 16, context.temp_allocator)
	linked := make(map[string]Symbol_Id, 16, context.temp_allocator)
	for id in package_order(c) {
		pkg := package_of(c, id)
		if pkg == nil {
			continue
		}
		for file in pkg.files {
			for item in file.active_items {
				#partial switch v in item {
				case ^Decl:
					check_export_decl(c, v, &claimed)
				case ^Item_Impl:
					for member in v.members {
						if d, ok := member.(^Decl); ok {
							check_export_decl(c, d, &claimed)
						}
					}
				case ^Item_Foreign_Block:
					check_foreign_links(c, v, &linked)
				}
			}
		}
	}
}

@(private = "file")
check_export_decl :: proc(c: ^Compiler, d: ^Decl, claimed: ^map[string]Span) {
	if !has_attribute(d.attributes, "export") {
		return
	}
	for sid in d.symbols {
		sym := symbol_of(c, sid)
		// A foreign member has no body to export; skip it rather than redefine.
		if sym == nil || sym.is_foreign {
			continue
		}
		name := link_name_of(c, d, sym)
		if strings.has_prefix(name, "loke_rt_") {
			errorf(c, sym.span, "L0635", "an exported symbol cannot use the reserved `loke_rt_` runtime prefix: `%s`", name)
			continue
		}
		// Already L0438.
		if sym.generic {
			continue
		}
		#partial switch sym.kind {
		case .Proc:
			info := type_of(c, sym.proc_type)
			if info == nil || !convention_is_foreign(info.convention) {
				errorf(c, sym.span, "L0629", "an exported procedure must use a foreign calling convention: `proc \"c\" (...)`")
				continue
			}
		case .Var:
			if ok, reason := foreign_abi_safe(c, sym.type); !ok {
				errorf(c, sym.span, "L0619", "an exported global is not ABI-safe: %s", reason)
				continue
			}
		case:
			continue // export on anything else is a misplaced-attribute error already
		}
		if first, seen := claimed[name]; seen {
			errorf(c, sym.span, "L0634", "two declarations export the symbol `%s`", name)
			add_notef(c, first, "`%s` is also exported here", name)
			continue
		}
		claimed[name] = sym.span
		sym.exported = true
		sym.link_name = name
	}
}

// Creates the symbols for one declaration, rejecting a shadowed local. Also
// used for a foreign block's members.
declare_all :: proc(k: ^Checker, d: ^Decl, top_level := false) {
	if len(d.symbols) > 0 {
		return // already collected in an earlier phase
	}
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
		if _, ok := k.scope.names[name_id]; ok {
			errorf(k.c, name.span, "L0304", "`%s` is already declared in this scope", name.text)
			append(&symbols, INVALID_SYMBOL)
			continue
		}
		if reject_reserved_name(k, name_id, name.span) {
			append(&symbols, INVALID_SYMBOL)
			continue
		}
		outer, owner := lookup_symbol_with_scope(k.scope.parent, name_id)
		if outer != INVALID_SYMBOL && (owner.kind == .Local || owner.kind == .Procedure) {
			errorf(k.c, name.span, "L0305", "`%s` shadows an outer declaration", name.text)
		}

		sym := Symbol {
			name   = name_id,
			span   = name.span,
			decl   = d,
			pkg    = k.pkg,
			public = top_level && declaration_is_public(k, d),
			// An instantiation resolves names in the declaration's own scope.
			def_scope     = k.scope,
			def_file      = k.file,
			def_file_node = k.file_node,
		}
		switch {
		case decl_proc_literal(d) != nil:
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

// design.md "Exported names": package-private by default. `@(public)` exports
// one declaration; `@(public)` on the package clause makes the file's
// declarations public by default, and `@(private)` opts one back out.
declaration_is_public :: proc(k: ^Checker, d: ^Decl) -> bool {
	own_public := has_attribute(d.attributes, "public")
	own_private := has_attribute(d.attributes, "private")
	if own_public && own_private {
		errorf(k.c, d.span, "L0332", "this declaration is both `@(public)` and `@(private)`")
		return false
	}
	if own_public {
		return true
	}
	if own_private {
		return false
	}
	return k.file_node != nil && has_attribute(k.file_node.attributes, "public")
}

// `declaration_is_public`'s rule, for a struct field.
@(private = "file")
field_is_public :: proc(k: ^Checker, attributes: []Attribute) -> bool {
	if has_attribute(attributes, "public") {
		return true
	}
	if has_attribute(attributes, "private") {
		return false
	}
	return k.file_node != nil && has_attribute(k.file_node.attributes, "public")
}

// design.md `@(escape=...)`: the written level, which only a parameter carrying
// a borrow may have.
check_escape_attribute :: proc(
	k: ^Checker,
	attributes: []Attribute,
	type: Type_Id,
	span: Span,
	generic_instance := false,
	borrowing := false,
) -> Escape_Level {
	level, written, ok := attribute_escape_level(k.c, attributes)
	if !written {
		return .Result
	}
	if !ok {
		errorf(
			k.c, span, "L0648",
			"`@(escape=...)` takes one of `none`, `result`, `stored`, or `static`",
		)
		return .Result
	}
	// A generic signature serves bindings with and without borrows, such as
	// `Small_Array(string_view, N)` and `Small_Array(int, N)`, so it is exempt.
	if !generic_instance && !borrowing && type != INVALID_TYPE && !type_is_carrier(k.c, type) && !type_carries_borrow(k.c, type).any {
		errorf(
			k.c, span, "L0648",
			"`@(escape=...)` describes what a call may keep of a borrow, and `%s` carries none",
			type_name(k.c, type),
		)
		return .Result
	}
	return level
}

// Is this signature one binding of a declaration written for many? A generic
// procedure, an instance of one, or any member of an `impl` block on a generic
// record instance.
@(private = "file")
in_generic_signature :: proc(k: ^Checker, literal: ^Expr_Proc) -> bool {
	if literal.generic_instance || k.generic_depth > 0 {
		return true
	}
	if k.impl_type == INVALID_TYPE {
		return false
	}
	info := type_of(k.c, k.impl_type)
	return info != nil && info.instance_of != INVALID_SYMBOL
}

has_attribute :: proc(attributes: []Attribute, name: string) -> bool {
	for attribute in attributes {
		if len(attribute.path) == 1 && attribute.path[0].text == name {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------- signatures --

// Where the code being checked sits. Every on-demand check saves and restores
// this, so a new field describing location belongs here.
Checker_Location :: struct {
	scope:         ^Scope,
	pkg:           Package_Id,
	lookup_pkg:    Package_Id,
	impl_type:     Type_Id,
	file:          u32,
	file_node:     ^File,
	proc_literal:  ^Expr_Proc,
	generic_depth: int,
}

save_checker_location :: proc(k: ^Checker) -> Checker_Location {
	return Checker_Location {
		scope = k.scope, pkg = k.pkg, lookup_pkg = k.lookup_pkg,
		impl_type = k.impl_type, file = k.file, file_node = k.file_node,
		proc_literal = k.proc_literal, generic_depth = k.generic_depth,
	}
}

restore_checker_location :: proc(k: ^Checker, saved: Checker_Location) {
	k.scope, k.pkg, k.lookup_pkg = saved.scope, saved.pkg, saved.lookup_pkg
	k.impl_type, k.file, k.file_node = saved.impl_type, saved.file, saved.file_node
	k.proc_literal, k.generic_depth = saved.proc_literal, saved.generic_depth
}

enter_symbol_location :: proc(k: ^Checker, sym: ^Symbol, subject := INVALID_TYPE) {
	if sym == nil {
		return
	}
	if sym.def_scope != nil {
		k.scope = sym.def_scope
	}
	if sym.def_file_node != nil {
		k.file, k.file_node = sym.def_file, sym.def_file_node
	}
	if sym.pkg != INVALID_PACKAGE {
		k.pkg = sym.pkg
		k.lookup_pkg = sym.lookup_pkg == INVALID_PACKAGE ? sym.pkg : sym.lookup_pkg
	}
	if subject != INVALID_TYPE {
		k.impl_type = subject
	}
}

resolve_symbol_signature_in_place :: proc(k: ^Checker, symbol_id: Symbol_Id, subject := INVALID_TYPE) {
	sym := symbol_of(k.c, symbol_id)
	if sym == nil || sym.decl == nil || sym.decl.sig_state != .Unchecked {
		return
	}
	saved := save_checker_location(k)
	defer restore_checker_location(k, saved)
	enter_symbol_location(k, sym, subject)
	resolve_declaration_signature(k, sym.decl)
}

check_symbol_decl_in_place :: proc(k: ^Checker, symbol_id: Symbol_Id, subject := INVALID_TYPE) {
	sym := symbol_of(k.c, symbol_id)
	if sym == nil || sym.decl == nil {
		return
	}
	saved := save_checker_location(k)
	defer restore_checker_location(k, saved)
	enter_symbol_location(k, sym, subject)
	check_decl(k, sym.decl)
}

resolve_declaration_signature :: proc(k: ^Checker, d: ^Decl) {
	if d.sig_state != .Unchecked {
		return // resolved, or already on the stack below this call
	}
	d.sig_state = .Checking
	defer d.sig_state = .Checked
	// A template has no signature of its own: `$T` names nothing until an
	// instantiation binds it. Registration is all this phase does for one.
	if len(d.symbols) == 1 && d.symbols[0] != INVALID_SYMBOL {
		if declaration_generic_kind(d) != .None {
			generic_template_for(k, d.symbols[0])
			// A generic method is reachable by method syntax, so its receiver is
			// read off the syntax.
			mark_template_receiver(k, d)
			reject_uninstantiated_generic(k, d)
			return
		}
	}
	if literal := decl_proc(d); literal != nil {
		if len(d.symbols) > 0 && d.symbols[0] != INVALID_SYMBOL {
			literal.symbol = d.symbols[0]
			resolve_proc_signature(k, literal, d.symbols[0])
			apply_proc_metadata(k, d, d.symbols[0])
		}
		return
	}

	if len(d.values) != 1 || len(d.symbols) != 1 || d.symbols[0] == INVALID_SYMBOL {
		return
	}
	symbol := symbol_of(k.c, d.symbols[0])
	#partial switch value in d.values[0] {
	case ^Type_Record:
		if value.kind == .Struct {
			resolve_struct_fields(k, symbol.type, value)
		} else {
			resolve_union_variants(k, symbol.type, value)
		}
		apply_type_metadata(k, d, symbol.type)
	case ^Type_Enum:
		resolve_enum_members(k, symbol.type, value)
		apply_type_metadata(k, d, symbol.type)
	case ^Expr_Proc_Group:
		symbol.kind = .Proc_Group
		resolve_group_members(k, d.symbols[0], value)
		apply_proc_metadata(k, d, d.symbols[0])
	case ^Expr_Operator:
		if value.hook != .None {
			resolve_hook_declaration(k, d, value)
		} else {
			resolve_operator_declaration(k, d, value)
		}
	case ^Type_Distinct:
		before := k.c.error_count
		underlying := resolve_type_syntax(k, value.elem)
		if value.elem != nil && underlying == INVALID_TYPE && k.c.error_count == before {
			report_unresolved_type(k, value.elem)
		}
		if info := type_of(k.c, symbol.type); info != nil {
			info.element = underlying
		}
		apply_type_metadata(k, d, symbol.type)
	case ^Type_Interface:
		check_interface_declaration(k, d.symbols[0])
		apply_type_metadata(k, d, symbol.type)
	}
}

resolve_struct_fields :: proc(k: ^Checker, type: Type_Id, value: ^Type_Record) {
	members := make([dynamic]Symbol_Id, 0, len(value.fields), k.c.semantic_allocator)
	for &field in value.fields {
		before := k.c.error_count
		field_type := resolve_type_syntax(k, field.type)
		if field.type != nil && field_type == INVALID_TYPE && k.c.error_count == before {
			report_unresolved_type(k, field.type)
		}
		bindings := make([dynamic]Symbol_Id, 0, len(field.names), k.c.semantic_allocator)
		// design.md "Compile-time reflection": fields have visibility too.
		public := field_is_public(k, field.attributes)
		reject_any_view_position(k, field_type, field.span, "a record field")
		for name in field.names {
			if name.text != "_" && member_named(k.c, members[:], name_identifier(k.c, name)) != INVALID_SYMBOL {
				errorf(k.c, name.span, "L0304", "`%s` is already a field of this record", name.text)
				append(&bindings, INVALID_SYMBOL)
				continue
			}
			binding := new_binding_symbol(k, name, .Field)
			if bound := symbol_of(k.c, binding); bound != nil {
				bound.type = field_type
				bound.index = u32(len(members))
				bound.public = public
				bound.is_using = field.is_using
			}
			append(&bindings, binding)
			if binding != INVALID_SYMBOL {
				append(&members, binding)
			}
		}
		field.symbols = bindings[:]
	}
	if info := type_of(k.c, type); info != nil {
		info.fields = members[:]
		// design.md "Record layout attributes".
		info.packed = record_is_packed(value)
		info.written_align = record_written_alignment(k, value)
	}
	resolve_uninitialized_fields(k, type, value)
}

// design.md "Uninitialized capacity": `@(initialized = count)` names the sibling
// `int` field counting a fixed array's live prefix. Only its shape is checked.
@(private = "file")
resolve_uninitialized_fields :: proc(k: ^Checker, type: Type_Id, value: ^Type_Record) {
	info := type_of(k.c, type)
	if info == nil {
		return
	}
	for &field in value.fields {
		attribute, written := field_initialized_attribute(field.attributes)
		if !written {
			continue
		}
		for binding in field.symbols {
			symbol := symbol_of(k.c, binding)
			if symbol == nil {
				continue
			}
			if underlying_kind(k.c, symbol.type) != .Array {
				errorf(
					k.c, attribute.span, "L0691",
					"`@(initialized)` names the live prefix of a fixed array, and `%s` is `%s`",
					identifier_text(k.c, symbol.name), type_name(k.c, symbol.type),
				)
				continue
			}
			ident, is_ident := attribute.value.(^Expr_Ident)
			if !is_ident {
				errorf(
					k.c, attribute.span, "L0691",
					"`@(initialized=...)` names a field of this record holding the live count",
				)
				continue
			}
			counter := member_named(k.c, info.fields, ident.name_id)
			counted := symbol_of(k.c, counter)
			if counted == nil {
				errorf(
					k.c, attribute.span, "L0691",
					"`%s` is not a field of this record", ident.name,
				)
				continue
			}
			if type_underlying(k.c, counted.type) != TYPE_INT {
				errorf(
					k.c, attribute.span, "L0691",
					"the live count `%s` is `%s`, and must be `int`",
					ident.name, type_name(k.c, counted.type),
				)
				continue
			}
			symbol.initialized_by = counter
		}
	}
}

@(private = "file")
field_initialized_attribute :: proc(attributes: []Attribute) -> (Attribute, bool) {
	for attribute in attributes {
		if len(attribute.path) == 1 && attribute.path[0].text == "initialized" {
			return attribute, true
		}
	}
	return {}, false
}

// `(name: Type, ...)`, interned while checking so the type exists before
// lifecycle contribution closes (`src/hooks.odin`).
@(private = "file")
resolve_anon_record :: proc(k: ^Checker, value: ^Type_Anon_Record) -> Type_Id {
	specs := make([dynamic]Anon_Record_Field, 0, len(value.fields), context.temp_allocator)
	names := make([dynamic]Identifier_Id, 0, len(value.fields), context.temp_allocator)
	bad := false
	for &field in value.fields {
		field_type := resolve_type_syntax(k, field.type)
		if field_type == INVALID_TYPE {
			report_unresolved_type(k, field.type)
			bad = true
			continue
		}
		reject_any_view_position(k, field_type, field.span, "a record field")
		for name in field.names {
			name_id := name_identifier(k.c, name)
			if name.text != "_" && identifier_list_contains(names[:], name_id) {
				errorf(k.c, name.span, "L0304", "`%s` is already a field of this record", name.text)
				continue
			}
			if name.text != "_" {
				append(&names, name_id)
			}
			append(&specs, Anon_Record_Field{name = name_id, type = field_type})
		}
	}
	if bad || len(specs) == 0 {
		return INVALID_TYPE
	}
	return anon_record_type(k.c, specs[:])
}

// Whether a multi-binding form takes this type apart; anything else is an
// arity error instead.
type_is_destructurable :: proc(c: ^Compiler, type: Type_Id) -> bool {
	info := underlying_info(c, type)
	return info != nil && info.kind == .Struct
}

// design.md "Destructuring": exactly as many directly declared fields as
// bindings, all visible here. `using` fields are not flattened.
destructure_fields :: proc(
	k: ^Checker,
	record: Type_Id,
	count: int,
	span: Span,
	code: string,
	action: string,
) -> ([]Symbol_Id, bool) {
	info := underlying_info(k.c, record)
	if info == nil || info.kind != .Struct {
		errorf(
			k.c, span, code,
			"`%s` is not a record, so it cannot fill %d bindings",
			type_name(k.c, record), count,
		)
		return nil, false
	}
	if len(info.fields) != count {
		errorf(
			k.c, span, code,
			"`%s` has %d field%s, so it fills %d binding%s, not %d",
			type_name(k.c, record), len(info.fields), len(info.fields) == 1 ? "" : "s",
			len(info.fields), len(info.fields) == 1 ? "" : "s", count,
		)
		return nil, false
	}
	for field in info.fields {
		if !require_visible_field(k, span, record, field, code, action) {
			return nil, false
		}
	}
	return info.fields, true
}

// A place is cloned from; a temporary is taken apart, which a custom copy or
// drop hook forbids.
@(private = "file")
plan_destructure :: proc(
	k: ^Checker,
	operand: Expr,
	record: Type_Id,
	fields: []Symbol_Id,
	retained: []bool,
) -> Destructure {
	plan := Destructure {
		active     = true,
		record     = record,
		fields     = fields,
		from_place = expression_is_borrowed_place(operand),
		retained   = retained,
	}
	if !plan.from_place {
		if life := lifecycle_of(k.c, record); life != nil &&
		   (life.custom_drop != INVALID_SYMBOL || life.custom_try_clone != INVALID_SYMBOL) {
			errorf(
				k.c, expr_span(operand), "L0508",
				"`%s` has a custom `hook(copy)` or `hook(drop)`, so it cannot be taken apart by a destructure",
				type_name(k.c, record),
			)
			add_notef(k.c, expr_span(operand), "bind the whole value, or give the type a procedure that decomposes it")
		}
	}
	return plan
}

// design.md: an enum's members are named constants that need not be
// contiguous. An omitted value continues from the previous member.
resolve_enum_members :: proc(k: ^Checker, type: Type_Id, value: ^Type_Enum) {
	backing := TYPE_INT
	if value.backing != nil {
		before := k.c.error_count
		resolved := resolve_type_syntax(k, value.backing)
		switch {
		case resolved == INVALID_TYPE:
			if k.c.error_count == before {
				report_unresolved_type(k, value.backing)
			}
		case !type_is_integer(k.c, resolved):
			errorf(k.c, expr_span(value.backing), "L0380", "an enum's backing type must be an integer type")
		case:
			backing = resolved
		}
	}
	info := type_of(k.c, type)
	if info != nil {
		info.element = backing
		info.bits = u16(type_bits(k.c, backing))
		info.signed = type_signed(k.c, backing)
	}

	members := make([dynamic]Symbol_Id, 0, len(value.fields), k.c.semantic_allocator)
	next := bi_from_i64(k.c, 0)
	for &field in value.fields {
		discriminant := next
		if field.value != nil {
			if check_single_expr(k, field.value, backing) != INVALID_TYPE {
				folded, evaluated := require_const(k, field.value, "an enum member's value", "L0380")
				if !evaluated {
				} else if folded.kind != .Integer && folded.kind != .Rune {
					errorf(k.c, expr_span(field.value), "L0380", "an enum member's value must be a constant integer")
				} else if !bi_fits(k.c, folded.integer, type_bits(k.c, backing), type_signed(k.c, backing)) {
					errorf(
						k.c,
						expr_span(field.value),
						"L0352",
						"%s is not representable by `%s`",
						bi_text(k.c, folded.integer),
						type_name(k.c, backing),
					)
				} else {
					discriminant = folded.integer
				}
			}
		}
		if field.name.text != "" && field.name.text != "_" {
			name_id := intern_identifier(k.c, field.name.text)
			for existing in members {
				if symbol := symbol_of(k.c, existing); symbol != nil && symbol.name == name_id {
					errorf(k.c, field.name.span, "L0304", "`%s` is already a member of this enum", field.name.text)
					break
				}
			}
		}
		if !bi_fits(k.c, discriminant, type_bits(k.c, backing), type_signed(k.c, backing)) {
			errorf(k.c, field.name.span, "L0352", "enum member representation does not fit `%s`", type_name(k.c, backing))
		}
		for existing in members {
			symbol := symbol_of(k.c, existing)
			equal, ok := const_equal(k.c, symbol.const_value, Const_Value{kind = .Integer, integer = discriminant})
			if ok && equal {
				errorf(k.c, field.name.span, "L0380", "enum variants must have distinct integer representations")
				break
			}
		}
		field.symbol = new_binding_symbol(k, field.name, .Enum_Member)
		if symbol := symbol_of(k.c, field.symbol); symbol != nil {
			symbol.type = type
			symbol.index = u32(len(members))
			symbol.const_value = Const_Value{kind = .Integer, integer = discriminant}
		}
		if field.symbol != INVALID_SYMBOL {
			append(&members, field.symbol)
		}
		next = bi_add(k.c, discriminant, bi_from_i64(k.c, 1))
	}
	if info != nil {
		info.fields = members[:]
	}
}

// A receiver-aware signature reads `proc(self, values: ..int)` as an implicit
// receiver followed by a typed parameter. Plain procedure types do not split.
parameter_splits_receiver :: proc(parameter: Parameter, position: int) -> bool {
	return position == 0 && parameter.type != nil && len(parameter.names) > 1 &&
		parameter.names[0].name.text == "self"
}

// The type and mode of one name in a parameter group, given the group's
// resolved type and, for a method, the receiver type.
normalize_signature_parameter :: proc(
	c: ^Compiler,
	parameter: Parameter,
	position, name_index: int,
	written: Type_Id,
	receiver := INVALID_TYPE,
) -> (type: Type_Id, mode: Param_Mode, split_receiver: bool) {
	type, mode = written, parameter.mode
	if receiver != INVALID_TYPE && position == 0 && name_index == 0 {
		split_receiver = parameter_splits_receiver(parameter, position)
		if parameter.type == nil || split_receiver { type = receiver }
		if split_receiver { mode = .Value }
		// design.md "Receiver forms": a plain `self` of the subject type borrows.
		if mode == .Value && type == receiver && len(parameter.names) > 0 &&
		   parameter.names[0].name.text == "self" {
			mode = .Borrow
		}
	}
	// `..T` is received as `[]T`.
	if mode == .Variadic && type != INVALID_TYPE {
		type = slice_of(c, type, mutable = false)
	}
	return
}

@(private = "file")
variadic_position_ok :: proc(k: ^Checker, literal: ^Expr_Proc, position, name_index: int, span: Span) -> bool {
	last := &literal.signature.params[len(literal.signature.params) - 1]
	if position != len(literal.signature.params) - 1 || name_index != len(last.names) - 1 {
		errorf(k.c, span, "L0574", "a variadic parameter must be the last one")
		return false
	}
	return true
}

// Marks a generic `impl` member whose first parameter is `self` as a method;
// its instance checks the receiver's type.
@(private = "file")
mark_template_receiver :: proc(k: ^Checker, d: ^Decl) {
	if k.impl_type == INVALID_TYPE {
		return
	}
	literal := decl_proc(d)
	if literal == nil || literal.signature == nil || len(literal.signature.params) == 0 {
		return
	}
	first := literal.signature.params[0]
	if len(first.names) == 0 || first.names[0].name.text != "self" {
		return
	}
	if sym := symbol_of(k.c, d.symbols[0]); sym != nil {
		sym.has_receiver = true
		sym.receiver = first.mode
	}
}

// `@(allocator_reset)` only means anything on an `Allocator`.
@(private = "file")
allocator_reset_ok :: proc(k: ^Checker, marked: bool, type: Type_Id, span: Span) -> bool {
	if !marked || type_underlying(k.c, type) == TYPE_ALLOCATOR {
		return marked
	}
	errorf(
		k.c,
		span,
		"L0539",
		"`@(allocator_reset)` marks an `Allocator` parameter whose region a call may end, found `%s`",
		type_name(k.c, type),
	)
	return false
}

// Builds the flattened signature a call site binds against and interns its
// procedure type — one entry per parameter name, so `proc(a, b: int)` has two.
resolve_proc_signature :: proc(k: ^Checker, literal: ^Expr_Proc, symbol_id: Symbol_Id) {
	symbol := symbol_of(k.c, symbol_id)
	if symbol == nil || literal.signature == nil {
		return
	}
	symbol.kind = .Proc
	symbol.type = TYPE_VOID
	validate_param_attributes(k, literal.signature.params)

	reported := k.c.error_count
	params := make([dynamic]Type_Id, 0, 4, k.c.semantic_allocator)
	modes := make([dynamic]Param_Mode, 0, 4, k.c.semantic_allocator)
	resets_list := make([dynamic]bool, 0, 4, k.c.semantic_allocator)
	escapes_list := make([dynamic]Escape_Level, 0, 4, k.c.semantic_allocator)
	by_ptr_list := make([dynamic]bool, 0, 4, k.c.semantic_allocator)
	param_symbols := make([dynamic]Symbol_Id, 0, 4, k.c.semantic_allocator)
	param_names := make([dynamic]Identifier_Id, 0, 4, context.temp_allocator)
	defaults := make([dynamic]Expr, 0, 4, k.c.semantic_allocator)

	has_receiver := false
	receiver_mode := Param_Mode.Value
	is_foreign := symbol.is_foreign
	saw_c_vararg := false

	for &parameter, position in literal.signature.params {
		// design.md "`@(c_vararg)`": checker-only, never a lowered parameter.
		if has_attribute(parameter.attributes, "c_vararg") {
			check_c_vararg_param(k, is_foreign, literal, position, parameter)
			saw_c_vararg = true
			continue
		}
		// `@(by_ptr) p: T` lowers to `T const *`; it is foreign-declaration metadata.
		is_by_ptr := has_attribute(parameter.attributes, "by_ptr")
		if is_by_ptr && !is_foreign {
			errorf(k.c, parameter.span, "L0626", "`@(by_ptr)` is only allowed on a foreign procedure parameter")
			is_by_ptr = false
		}
		before := k.c.error_count
		parameter_type := resolve_type_syntax(k, parameter.type)
		if parameter.type != nil && parameter_type == INVALID_TYPE && k.c.error_count == before {
			report_unresolved_type(k, parameter.type)
		}
		if parameter.type == nil {
			// design.md "Receiver forms": a parameter with no type is the receiver
			// `self`, whose type comes from the enclosing `impl` block.
			if position == 0 && k.impl_type != INVALID_TYPE {
				parameter_type = k.impl_type
			} else {
				errorf(k.c, parameter.span, "L0408", "a parameter needs a type; only the receiver `self` may omit one")
			}
		}
		if parameter_type != INVALID_TYPE && type_mentions_any_view(k.c, parameter_type, allow_top = true) {
			reject_any_view_position(k, parameter_type, parameter.span, "stored inside another type")
		}
		bindings := make([dynamic]Symbol_Id, 0, len(parameter.names), k.c.semantic_allocator)
		for parameter_name, name_index in parameter.names {
			// Written names, so a removed `$` parameter still takes its name.
			name_id := name_identifier(k.c, parameter_name.name)
			if parameter_name.name.text != "_" {
				if identifier_list_contains(param_names[:], name_id) {
					errorf(
						k.c, parameter_name.name.span, "L0304",
						"`%s` is already a parameter of this procedure", parameter_name.name.text,
					)
				} else {
					append(&param_names, name_id)
				}
			}
			// An instance's `$` parameter is a bound constant, not a runtime one.
			if parameter_name.is_poly && literal.generic_instance {
				append(&bindings, INVALID_SYMBOL)
				continue
			}
			name_type, mode, split_receiver := normalize_signature_parameter(
				k.c, parameter, position, name_index, parameter_type, receiver = k.impl_type,
			)
			// Group defaults and reset effects belong to the typed parameters.
			default := split_receiver ? nil : parameter.default
			written_type := split_receiver ? k.impl_type : parameter_type
			escape := check_escape_attribute(
				k, parameter.attributes, written_type, parameter.span, in_generic_signature(k, literal),
				borrowing = mode == .Borrow || mode == .Inout,
			)
			resets := has_attribute(parameter.attributes, "allocator_reset") &&
				!split_receiver
			resets = allocator_reset_ok(k, resets, written_type, parameter.span)
			if mode == .Variadic && name_type != INVALID_TYPE {
				if !variadic_position_ok(k, literal, position, name_index, parameter.span) {
					name_type, mode = written_type, .Value
				}
			}
			reject_reserved_name(k, parameter_name.name.id, parameter_name.name.span)
			binding := new_binding_symbol(k, parameter_name.name, .Parameter)
			if bound := symbol_of(k.c, binding); bound != nil {
				bound.type = name_type
				bound.index = u32(len(params))
				bound.mode = mode
				// design.md "Parameter semantics and ABI lowering".
				bound.immutable = mode == .Value || mode == .Borrow
				bound.owner_proc = literal
				bound.allocator_reset = resets
				bound.escape = escape
			}
			if position == 0 && name_index == 0 &&
			   k.impl_type != INVALID_TYPE &&
			   parameter_name.name.text == "self" &&
			   name_type == k.impl_type {
				has_receiver = true
				receiver_mode = mode
			}
			append(&bindings, binding)
			append(&params, name_type)
			append(&modes, mode)
			append(&resets_list, resets)
			append(&escapes_list, escape)
			append(&by_ptr_list, is_by_ptr)
			append(&param_symbols, binding)
			append(&defaults, default)
		}
		parameter.symbols = bindings[:]
	}

	result_type := INVALID_TYPE
	result_inout := false
	if result := literal.signature.result; result != nil {
		before := k.c.error_count
		result_type = resolve_type_syntax(k, result.type)
		if result.type != nil && result_type == INVALID_TYPE && k.c.error_count == before {
			report_unresolved_type(k, result.type)
		}
		reject_any_view_position(k, result_type, result.span, "a result type")
		result_inout = result.is_inout
	}

	if validate_convention(k, literal.signature.convention, literal.span) &&
	   convention_is_foreign(literal.signature.convention) {
		check_foreign_signature(
			k, params[:], modes[:], by_ptr_list[:], result_type, result_inout, literal.span,
		)
	}
	proc_type := intern_proc_type(
		k.c, params[:], modes[:], result_type, result_inout,
		literal.signature.convention, resets_list[:],
		param_by_ptr = by_ptr_list[:], c_vararg = saw_c_vararg,
		param_escapes = escapes_list[:],
		proc_contract = !is_foreign && literal.body != nil && result_needs_contract(k.c, result_type, result_inout) ? symbol_id : INVALID_SYMBOL,
	)
	// Creating bindings may have grown the symbol store.
	symbol = symbol_of(k.c, symbol_id)
	symbol.params = params[:]
	symbol.result = result_type
	symbol.result_inout = result_inout
	symbol.param_symbols = param_symbols[:]
	symbol.param_defaults = defaults[:]
	symbol.proc_type = proc_type
	symbol.signature_error = k.c.error_count > reported
	// design.md "Receiver forms": a `self: ^T` is not a receiver.
	symbol.has_receiver = has_receiver
	symbol.receiver = receiver_mode
	literal.type = proc_type
	literal.symbol = symbol_id
	check_param_defaults(k, literal, symbol_id)
}

// design.md "Default values": checked with the signature, so a caller checked
// before the body still sees them resolved.
@(private = "file")
check_param_defaults :: proc(k: ^Checker, literal: ^Expr_Proc, symbol_id: Symbol_Id) {
	written := false
	for parameter in literal.signature.params {
		written ||= parameter.default != nil
	}
	if !written {
		return
	}
	symbol := symbol_of(k.c, symbol_id)
	outer_scope, outer_proc := k.scope, k.proc_literal
	outer_result, outer_result_inout := k.result_type, k.result_inout
	defer {
		k.scope, k.proc_literal = outer_scope, outer_proc
		k.result_type, k.result_inout = outer_result, outer_result_inout
	}
	// The body's context, so `source_location()` reports this procedure.
	k.scope = new_scope(k.c, outer_scope, .Procedure)
	k.scope.owner_proc = literal
	k.proc_literal = literal
	k.result_type = symbol.result
	k.result_inout = symbol.result_inout
	for parameter in literal.signature.params {
		if parameter.default != nil {
			// Only the parameters to its left are in scope.
			check_value_expr(k, parameter.default, resolve_type_syntax(k, parameter.type), "pass")
		}
		install_symbols(k.scope, k.c, parameter.symbols)
	}
}

@(private = "file")
identifier_list_contains :: proc(names: []Identifier_Id, wanted: Identifier_Id) -> bool {
	for name in names {
		if name == wanted {
			return true
		}
	}
	return false
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

// design.md "Predeclared names": `true`, `false` and `nil` spell literals, so no
// name a lookup reaches may be one of them.
reject_reserved_name :: proc(k: ^Checker, name_id: Identifier_Id, span: Span) -> bool {
	sym := symbol_of(k.c, lookup_symbol(build_universe(k.c), name_id))
	if sym == nil || !sym.reserved {
		return false
	}
	errorf(
		k.c, span, "L0700",
		"`%s` spells a literal, so it cannot be declared",
		identifier_text(k.c, name_id),
	)
	return true
}

name_identifier :: proc(c: ^Compiler, name: Name) -> Identifier_Id {
	return name.id != INVALID_IDENTIFIER ? name.id : intern_identifier(c, name.text)
}

identifier_of :: proc(c: ^Compiler, v: ^Expr_Ident) -> Identifier_Id {
	if v.name_id == INVALID_IDENTIFIER {
		v.name_id = intern_identifier(c, v.name)
	}
	return v.name_id
}

// ------------------------------------------------------- finite size --

@(private = "file")
check_declaration_size :: proc(k: ^Checker, d: ^Decl) {
	if len(d.symbols) != 1 || d.symbols[0] == INVALID_SYMBOL {
		return
	}
	symbol := symbol_of(k.c, d.symbols[0])
	if symbol == nil || symbol.kind != .Type {
		return
	}
	path := make([dynamic]Type_Id, 0, 8, context.temp_allocator)
	check_finite_size(k, symbol.type, d.span, &path)
}

// Walks value edges only, since a pointer breaks a containment cycle.
check_finite_size :: proc(k: ^Checker, type: Type_Id, span: Span, path: ^[dynamic]Type_Id) -> bool {
	info := type_of(k.c, type)
	if info == nil {
		return true
	}
	switch info.size_state {
	case .Finite:
		return true
	case .Cyclic:
		return false
	case .Checking:
		errorf(
			k.c, span, "L0364", "`%s` contains itself by value: %s",
			type_name(k.c, type), size_cycle_path(k, path[:], type),
		)
		info.size_state = .Cyclic
		return false
	case .Unchecked:
	}

	#partial switch info.kind {
	case .Struct, .Array, .Distinct, .Union:
	case:
		info.size_state = .Finite
		return true
	}

	info.size_state = .Checking
	append(path, type)
	defer pop(path)

	ok := true
	#partial switch info.kind {
	case .Struct:
		for field in info.fields {
			symbol := symbol_of(k.c, field)
			if symbol == nil {
				continue
			}
			if !check_finite_size(k, symbol.type, span, path) {
				ok = false
			}
		}
	case .Array, .Distinct:
		if info.element != INVALID_TYPE {
			ok = check_finite_size(k, info.element, span, path)
		}
	case .Union:
		for variant in info.variants {
			if !check_finite_size(k, variant, span, path) {
				ok = false
			}
		}
	}
	// Reacquired: the walk may have grown the type store.
	info = type_of(k.c, type)
	info.size_state = ok ? .Finite : .Cyclic
	return ok
}

@(private = "file")
size_cycle_path :: proc(k: ^Checker, path: []Type_Id, closing: Type_Id) -> string {
	text := ""
	for type, index in path {
		if index > 0 {
			text = concat(k.c, text, " -> ")
		}
		text = concat(k.c, text, type_name(k.c, type))
	}
	if len(path) > 0 {
		text = concat(k.c, text, " -> ")
	}
	return concat(k.c, text, type_name(k.c, closing))
}

concat :: proc(c: ^Compiler, a, b: string) -> string {
	out := make([]u8, len(a) + len(b), c.semantic_allocator)
	copy(out, a)
	copy(out[len(a):], b)
	return string(out)
}

// ---------------------------------------------------------- type syntax --

resolve_type_syntax :: proc(k: ^Checker, syntax: Expr) -> Type_Id {
	if syntax == nil {
		return INVALID_TYPE
	}
	#partial switch value in syntax {
	case ^Expr_Error:
		return INVALID_TYPE

	case ^Expr_Ident:
		symbol_id := lookup_symbol(k.scope, identifier_of(k.c, value))
		// A template names no type on its own.
		if symbol_is_generic(k, symbol_id) {
			return INVALID_TYPE
		}
		if symbol := symbol_of(k.c, symbol_id); symbol != nil && symbol.kind == .Type {
			resolve_symbol_signature_in_place(k, symbol_id)
			symbol = symbol_of(k.c, symbol_id)
			value.symbol = symbol_id
			value.denoted_type = symbol.type
			value.resolution = Resolution{kind = .Type, symbol = symbol_id}
			value.value_category = .Type
			return symbol.type
		}
		// A type alias is a constant whose value is a type: `Alias :: u32`.
		if symbol := symbol_of(k.c, symbol_id); symbol != nil && symbol.kind == .Const {
			if symbol.decl != nil && symbol.decl.check_state == .Unchecked {
				check_symbol_decl_in_place(k, symbol_id)
				symbol = symbol_of(k.c, symbol_id)
			}
			if symbol.const_value.kind == .Type {
				value.symbol = symbol_id
				value.denoted_type = symbol.const_value.type_value
				value.resolution = Resolution{kind = .Type, symbol = symbol_id}
				value.value_category = .Type
				return value.denoted_type
			}
		}
		return INVALID_TYPE

	case ^Expr_Selector:
		// `pkg.Point`.
		if ident, is_ident := value.operand.(^Expr_Ident); is_ident {
			alias := lookup_symbol(k.scope, identifier_of(k.c, ident))
			if sym := symbol_of(k.c, alias); sym != nil && sym.kind == .Package_Alias {
				check_package_selector(k, value, ident, alias)
				return value.value_category == .Type ? value.denoted_type : INVALID_TYPE
			}
		}
		// An associated type, `Countdown.Iterator`.
		return resolve_associated_type(k, value)

	case ^Type_Pointer:
		element := resolve_type_syntax(k, value.elem)
		if element == INVALID_TYPE {
			return INVALID_TYPE
		}
		value.denoted_type = pointer_to(k.c, element, value.mutable)
		value.resolution.kind = .Type
		return value.denoted_type

	case ^Type_C_Pointer:
		element := resolve_type_syntax(k, value.elem)
		if element == INVALID_TYPE {
			return INVALID_TYPE
		}
		value.denoted_type = intern_type(k.c, Type_Key{kind = .C_Pointer, element = element}, Type_Info{kind = .C_Pointer, element = element})
		value.resolution.kind = .Type
		return value.denoted_type

	case ^Type_Slice:
		element := resolve_type_syntax(k, value.elem)
		if element == INVALID_TYPE {
			return INVALID_TYPE
		}
		value.denoted_type = slice_of(k.c, element, value.mutable)
		value.resolution.kind = .Type
		return value.denoted_type

	case ^Type_Dynamic_Array:
		element := resolve_type_syntax(k, value.elem)
		if element == INVALID_TYPE {
			return INVALID_TYPE
		}
		value.denoted_type = dynamic_array_of(k.c, element)
		value.resolution.kind = .Type
		return value.denoted_type

	case ^Type_Array:
		element := resolve_type_syntax(k, value.elem)
		if element == INVALID_TYPE {
			return INVALID_TYPE
		}
		if value.inferred || value.length == nil {
			// `[?]T` takes its length from the literal it types, which
			// `check_composite` fills in; on its own it has none.
			return INVALID_TYPE
		}
		if value.denoted_type != INVALID_TYPE {
			return value.denoted_type
		}
		// `[$N]E` inside an instance.
		if poly, is_poly := value.length.(^Type_Poly); is_poly {
			count, bound := poly_array_length(k, poly)
			if !bound {
				return INVALID_TYPE
			}
			value.denoted_type = array_of(k.c, element, count)
			value.resolution.kind = .Type
			return value.denoted_type
		}
		if check_single_expr(k, value.length, TYPE_INT) == INVALID_TYPE {
			return INVALID_TYPE
		}
		folded, evaluated := require_const(k, value.length, "an array length", "L0384")
		if !evaluated {
			return INVALID_TYPE
		}
		if folded.kind != .Integer {
			errorf(k.c, expr_span(value.length), "L0384", "an array length must be a constant integer")
			return INVALID_TYPE
		}
		length, fits := bi_to_i64(k.c, folded.integer)
		if !fits || length < 0 {
			errorf(k.c, expr_span(value.length), "L0384", "an array length must be a non-negative constant")
			return INVALID_TYPE
		}
		value.denoted_type = array_of(k.c, element, u64(length))
		value.resolution.kind = .Type
		return value.denoted_type

	case ^Type_Map:
		key := resolve_type_syntax(k, value.key)
		element := resolve_type_syntax(k, value.value)
		if key == INVALID_TYPE || element == INVALID_TYPE {
			return INVALID_TYPE
		}
		value.denoted_type = map_of(k.c, key, element)
		value.resolution.kind = .Type
		return value.denoted_type

	case ^Type_Distinct:
		// A fresh identity; a named one got its shell in phase 2a.
		if value.denoted_type == INVALID_TYPE {
			before := k.c.error_count
			element := resolve_type_syntax(k, value.elem)
			if value.elem != nil && element == INVALID_TYPE && k.c.error_count == before {
				report_unresolved_type(k, value.elem)
			}
			value.denoted_type = new_type(k.c, Type_Info{kind = .Distinct, element = element})
		}
		value.resolution.kind = .Type
		return value.denoted_type

	case ^Type_Record:
		if value.denoted_type == INVALID_TYPE {
			validate_record_attributes(k, value)
			if value.kind == .Struct {
				value.denoted_type = new_type(k.c, Type_Info{kind = .Struct, move_only = value.move_only})
				resolve_struct_fields(k, value.denoted_type, value)
			} else {
				value.denoted_type = new_type(k.c, Type_Info{kind = .Union})
				resolve_union_variants(k, value.denoted_type, value)
			}
		}
		value.resolution.kind = .Type
		return value.denoted_type

	case ^Type_Anon_Record:
		if value.denoted_type == INVALID_TYPE {
			value.denoted_type = resolve_anon_record(k, value)
		}
		value.resolution.kind = .Type
		return value.denoted_type

	case ^Type_Enum:
		if value.denoted_type == INVALID_TYPE {
			value.denoted_type = new_type(k.c, Type_Info{kind = .Enum})
			resolve_enum_members(k, value.denoted_type, value)
		}
		value.resolution.kind = .Type
		return value.denoted_type

	case ^Type_Proc:
		validate_param_attributes(k, value.params)
		params := make([dynamic]Type_Id, 0, len(value.params), k.c.semantic_allocator)
		modes := make([dynamic]Param_Mode, 0, len(value.params), k.c.semantic_allocator)
		resets := make([dynamic]bool, 0, len(value.params), k.c.semantic_allocator)
		escapes := make([dynamic]Escape_Level, 0, len(value.params), k.c.semantic_allocator)
		for parameter, position in value.params {
			// The reset effect is part of the procedure type.
			marked := has_attribute(parameter.attributes, "allocator_reset")
			count := max(len(parameter.names), 1)
			before := k.c.error_count
			written := resolve_type_syntax(k, parameter.type)
			if parameter.type == nil {
				// A procedure type has no receiver to take a type from.
				name := len(parameter.names) > 0 ? parameter.names[0].name.text : "value"
				if parameter.default == nil && parameter.mode == .Value {
					// A bare word was meant as the type.
					errorf(
						k.c, parameter.span, "L0697",
						"`%s` is a parameter name here, not a type: a procedure type is written `proc(value: %s)`",
						name, name,
					)
				} else {
					errorf(
						k.c, parameter.span, "L0697",
						"a parameter of a procedure type needs a written type, as in `proc(%s: T)`", name,
					)
				}
			} else if written == INVALID_TYPE && k.c.error_count == before {
				report_unresolved_type(k, parameter.type)
			}
			for name_index in 0 ..< count {
				marked = allocator_reset_ok(k, marked, written, parameter.span)
				resolved, mode, _ := normalize_signature_parameter(k.c, parameter, position, name_index, written)
				append(&params, resolved)
				append(&modes, mode)
				append(&resets, marked)
				append(&escapes, check_escape_attribute(k, parameter.attributes, resolved, parameter.span, borrowing = mode == .Borrow || mode == .Inout))
			}
		}
		result_type := INVALID_TYPE
		result_inout := false
		if result := value.result; result != nil {
			before := k.c.error_count
			result_type = resolve_type_syntax(k, result.type)
			if result.type != nil && result_type == INVALID_TYPE && k.c.error_count == before {
				report_unresolved_type(k, result.type)
			}
			result_inout = result.is_inout
		}
		if validate_convention(k, value.convention, value.span) &&
		   convention_is_foreign(value.convention) {
			check_foreign_signature(k, params[:], modes[:], nil, result_type, result_inout, value.span)
		}
		value.denoted_type = intern_proc_type(
			k.c, params[:], modes[:], result_type, result_inout, value.convention, resets[:],
			param_escapes = escapes[:],
		)
		value.resolution.kind = .Type
		return value.denoted_type

	case ^Type_Dyn:
		// `dyn Interface(args...)`, without the subject parameter.
		if value.denoted_type != INVALID_TYPE {
			return value.denoted_type
		}
		value.denoted_type = resolve_dyn_type(k, value)
		value.resolution.kind = .Type
		return value.denoted_type

	case ^Type_Type:
		value.denoted_type = TYPE_TYPE
		value.resolution.kind = .Type
		return TYPE_TYPE

	case ^Type_Poly:
		// Inside an instance, `$E` is bound in the instance scope.
		name := value.name.id
		if name == INVALID_IDENTIFIER {
			name = intern_identifier(k.c, value.name.text)
		}
		bound := lookup_symbol(k.scope, name)
		if sym := symbol_of(k.c, bound); sym != nil && sym.kind == .Type {
			value.denoted_type = sym.type
			value.resolution = Resolution{kind = .Type, symbol = bound}
			value.value_category = .Type
			return sym.type
		}
		return INVALID_TYPE

	case ^Expr_Call:
		// Predeclared type constructors: design.md "SIMD vectors" and "Ranges".
		if simd_callee(k, value.callee) {
			return resolve_simd_application(k, value)
		}
		if range_callee(k, value.callee) {
			return resolve_range_application(k, value)
		}
		// `Table(string, int)`: a generic application in type position.
		template := generic_template_of_callee(k, value.callee, .Record)
		if template == nil {
			return INVALID_TYPE
		}
		if value.denoted_type != INVALID_TYPE {
			return value.denoted_type
		}
		return instantiate_record_application(k, value, template, report = true)
	}
	return INVALID_TYPE
}

// `Type.Member` where the member is an associated type. Silent when the operand
// is not a type or the member is not one, so an ordinary value selection is
// still free to mean what it means.
@(private = "file")
resolve_associated_type :: proc(k: ^Checker, value: ^Expr_Selector) -> Type_Id {
	subject := resolve_type_syntax(k, value.operand)
	if subject == INVALID_TYPE {
		return INVALID_TYPE
	}
	member := find_member(k, subject, intern_identifier(k.c, value.name.text))
	sym := symbol_of(k.c, member)
	if sym == nil {
		return INVALID_TYPE
	}
	if sym.kind == .Const && sym.decl != nil && sym.decl.check_state == .Unchecked {
		check_symbol_decl_in_place(k, member, subject)
		sym = symbol_of(k.c, member)
	}
	denoted := INVALID_TYPE
	switch {
	case sym.kind == .Type:
		denoted = sym.type
	case sym.kind == .Const && sym.const_value.kind == .Type:
		denoted = sym.const_value.type_value
	}
	if denoted == INVALID_TYPE {
		return INVALID_TYPE
	}
	value.denoted_type = denoted
	value.resolution = Resolution{kind = .Type, symbol = member}
	value.value_category = .Type
	return denoted
}

// An invariant guard: every construct is compiled or has its own diagnostic,
// so reaching this is a compiler defect.
unsupported_construct :: proc(k: ^Checker, span: Span) {
	errorf(
		k.c,
		span,
		"L0350",
		"this construct parses, but the checker has no rule for it; this is a compiler defect",
	)
}

// Whether a type may be used for runtime storage, reported once per declaration.
gate_type :: proc(k: ^Checker, type: Type_Id, span: Span) -> bool {
	if type == INVALID_TYPE {
		return false
	}
	// design.md: an interface declaration is compile-time metadata and cannot be
	// a variable, field, parameter, or result type. `dyn I` is the erased type.
	if type_is_interface(k.c, type) {
		errorf(
			k.c,
			span,
			"L0441",
			"`%s` is an interface, which is compile-time metadata; write `dyn %s` for a runtime value",
			type_name(k.c, type),
			type_name(k.c, type),
		)
		return false
	}
	if !type_is_supported(k.c, type) {
		// A component that never resolved was already reported.
		if !type_mentions_invalid(k.c, type) {
			unsupported_construct(k, span)
		}
		return false
	}
	// design.md "Maps": key policies are settled where the map type is named.
	if !require_nested_map_key_policies(k, type, span) {
		return false
	}
	if type_is_region_provider(k.c, type) {
		ensure_provider_members(k, type_underlying(k.c, type))
	}
	return true
}

@(private = "file")
resolve_type_name :: proc(k: ^Checker, d: ^Decl) -> Type_Id {
	if d.declared_type == nil {
		return INVALID_TYPE // inferred
	}
	reported := k.c.error_count
	resolved := resolve_type_syntax(k, d.declared_type)
	if resolved != INVALID_TYPE {
		return resolved
	}
	if k.c.error_count > reported {
		return INVALID_TYPE // resolution already said what is wrong with this type
	}
	report_unresolved_type(k, d.declared_type)
	return INVALID_TYPE
}

// Says why a written type did not resolve. `resolve_type_syntax` is also a
// probe, so it reports nothing itself.
report_unresolved_type :: proc(k: ^Checker, syntax: Expr) {
	// The parser already reported it.
	if _, is_error := syntax.(^Expr_Error); is_error {
		return
	}
	if ident, is_ident := syntax.(^Expr_Ident); is_ident {
		if ident.name == "Simd" {
			errorf(k.c, ident.span, "L0681", "`Simd` needs its element type and lane count, as in `Simd(f32, 4)`")
			return
		}
		if symbol_is_generic(k, lookup_symbol(k.scope, identifier_of(k.c, ident))) {
			errorf(k.c, ident.span, "L0431", "`%s` is generic and needs its arguments, as in `%s(...)`", ident.name, ident.name)
			return
		}
		errorf(k.c, ident.span, "L0306", "unknown type `%s`", ident.name)
		return
	}
	// Name the component that failed rather than the shape around it.
	component := unresolved_component(k, syntax)
	if component != nil {
		report_unresolved_type(k, component)
		return
	}
	if poly, is_poly := syntax.(^Type_Poly); is_poly {
		errorf(k.c, poly.span, "L0437", "`$%s` is not bound here", poly.name.text)
		return
	}
	// `Name(args)` whose head names nothing.
	if call, is_call := syntax.(^Expr_Call); is_call {
		if head, head_is_ident := call.callee.(^Expr_Ident); head_is_ident {
			errorf(k.c, head.span, "L0306", "unknown type `%s`", head.name)
			return
		}
	}
	unsupported_construct(k, expr_span(syntax))
}

// The component of a composed type that did not resolve, or nil.
@(private = "file")
unresolved_component :: proc(k: ^Checker, syntax: Expr) -> Expr {
	failed :: proc(k: ^Checker, part: Expr) -> bool {
		return part != nil && resolve_type_syntax(k, part) == INVALID_TYPE
	}
	#partial switch value in syntax {
	case ^Type_Pointer:
		if failed(k, value.elem) { return value.elem }
	case ^Type_C_Pointer:
		if failed(k, value.elem) { return value.elem }
	case ^Type_Slice:
		if failed(k, value.elem) { return value.elem }
	case ^Type_Dynamic_Array:
		if failed(k, value.elem) { return value.elem }
	case ^Type_Array:
		if failed(k, value.elem) { return value.elem }
	case ^Type_Distinct:
		if failed(k, value.elem) { return value.elem }
	case ^Type_Map:
		if failed(k, value.key) { return value.key }
		if failed(k, value.value) { return value.value }
	}
	return nil
}

// ------------------------------------------------------- declarations --

check_decl :: proc(k: ^Checker, d: ^Decl) {
	if d.check_state == .Checked {
		return
	}
	if d.check_state == .Checking {
		errorf(k.c, d.span, "L0324", "%s initialisation cycle", d.kind == .Const ? "constant" : "global")
		return
	}
	d.check_state = .Checking
	check_decl_inner(k, d)
	d.check_state = .Checked
	// Here rather than in `check_decl_inner`, which returns from several places.
	if d.duration != .None && !d.top_level && d.kind == .Var {
		record_static_local(k, d)
	}
}

@(private = "file")
check_decl_inner :: proc(k: ^Checker, d: ^Decl) {
	// A template's body is checked in its instances.
	if len(d.symbols) == 1 && d.symbols[0] != INVALID_SYMBOL && symbol_is_generic(k, d.symbols[0]) {
		return
	}
	if literal := decl_proc_literal(d); literal != nil {
		check_proc(k, d, literal)
		return
	}
	// An operator group's members are checked as their own declarations.
	if len(d.values) == 1 {
		if _, is_operator := d.values[0].(^Expr_Operator); is_operator {
			return
		}
	}
	if len(d.symbols) == 1 {
		if symbol := symbol_of(k.c, d.symbols[0]); symbol != nil && symbol.kind == .Type {
			if type_is_interface(k.c, symbol.type) {
				check_interface_declaration(k, d.symbols[0])
				return
			}
			gate_type(k, symbol.type, d.span)
			return
		}
	}
	for symbol_id in d.symbols {
		if sym := symbol_of(k.c, symbol_id); sym != nil {
			sym.duration = d.duration
		}
	}
	if len(d.symbols) == 1 {
		if symbol := symbol_of(k.c, d.symbols[0]); symbol != nil && symbol.kind == .Proc_Group {
			return // members were resolved with the signature; a group holds no value
		}
	}

	declared := resolve_type_name(k, d)
	if declared == INVALID_TYPE && d.declared_type != nil {
		return // the written type did not resolve, and said so
	}
	if declared != INVALID_TYPE && !gate_type(k, declared, d.span) {
		return
	}
	// design.md "Allocators": before the initialiser, which builds with the
	// selected provider.
	if !check_via_policy(k, d, declared) {
		return
	}
	if declared != INVALID_TYPE && type_mentions_any_view(k.c, declared, allow_top = !d.top_level) {
		reject_any_view_position(k, declared, d.span, d.top_level ? "a global" : "stored inside another type")
		return
	}
	if declared != INVALID_TYPE && type_is_compile_time_only(k.c, declared) && d.kind != .Const {
		report_compile_time_only(k, declared, d.span)
		return
	}

	if len(d.values) == 0 {
		if d.kind == .Const {
			errorf(k.c, d.span, "L0307", "a constant needs an initialiser")
			return
		}
		if declared == INVALID_TYPE {
			errorf(k.c, d.span, "L0306", "this declaration needs a type or an initialiser")
			return
		}
		// design.md "Zero values": only static storage is zero-initialised.
		if d.top_level || d.duration != .None {
			require_type_has_zero(k, declared, d.span, "a declaration with static duration")
		}
		assign_symbol_types(k.c, d, declared)
		return
	}
	// `a, b := record;`
	if len(d.values) == 1 && len(d.names) > 1 && d.values[0] != nil {
		check_expr(k, d.values[0])
		if base := expr_base(d.values[0]); base != nil && type_is_destructurable(k.c, base.type) {
			if fields, ok := destructure_fields(
				k, base.type, len(d.names), expr_span(d.values[0]), "L0308", "bound by a destructuring declaration",
			); ok {
				retained := make([]bool, len(fields), k.c.semantic_allocator)
				for symbol_id, index in d.symbols {
					retained[index] = symbol_id != INVALID_SYMBOL
				}
				d.destructure = plan_destructure(k, d.values[0], base.type, fields, retained)
				for symbol_id, index in d.symbols {
					field := symbol_of(k.c, fields[index])
					if symbol := symbol_of(k.c, symbol_id); symbol != nil && field != nil {
						symbol.type = field.type
					}
					note_nil_write_to(k, symbol_id, d.values[0])
				}
			}
			return
		}
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
		if len(d.values) == 1 && len(d.names) > 1 {
			note_optional_replacement(k, d.values[0])
		}
	}

	for value, i in d.values {
		symbol_id := i < len(d.symbols) ? d.symbols[i] : INVALID_SYMBOL

		// `---`; the parser already requires `x: T = ---`.
		if value == nil {
			if declared == INVALID_TYPE {
				errorf(k.c, d.span, "L0381", "`---` needs an explicitly written type")
			} else if d.kind == .Const {
				errorf(k.c, d.span, "L0381", "a constant cannot be left uninitialised")
			}
			if symbol := symbol_of(k.c, symbol_id); symbol != nil {
				symbol.type = declared
			}
			continue
		}

		type := check_single_expr(k, value, declared)
		if type == INVALID_TYPE {
			if symbol := symbol_of(k.c, symbol_id); symbol != nil {
				symbol.type = declared
			}
			continue
		}

		final := declared
		if declared != INVALID_TYPE {
			materialize_value_expr(k, value, declared, "initialise")
		} else if d.kind == .Const && type_is_untyped(k.c, type) {
			// An untyped constant stays untyped (design.md "Unfixed constants").
			final = type
		} else {
			final = default_type(k.c, type)
			if final == INVALID_TYPE {
				errorf(k.c, expr_span(value), "L0310", "`nil` has no type to infer here")
				continue
			}
			materialize(k, value, final)
			if type_is_compile_time_only(k.c, final) && d.kind != .Const {
				report_compile_time_only(k, final, d.span)
				continue
			}
			if !gate_type(k, final, d.span) {
				continue
			}
		}

		// The codes here are `require_const`'s fallback, unpinned by design.
		if d.top_level && d.kind == .Var {
			require_const(k, value, "a file-scope initializer", "L0325")
		}

		bind_literal_allocator(k.c, value, symbol_id)
		if symbol := symbol_of(k.c, symbol_id); symbol != nil {
			symbol.type = final
			if d.kind == .Const {
				folded, evaluated := require_const(k, value, "a constant initialiser", "L0311")
				// Re-fetched: evaluation may have grown the symbol store.
				if updated := symbol_of(k.c, symbol_id); updated != nil && evaluated {
					updated.const_value = folded
					// A type-valued constant is an alias, and names a type.
					if updated.const_value.kind == .Type {
						updated.type = TYPE_TYPE
					}
				}
			}
		}
		note_nil_write_to(k, symbol_id, value)
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

// -------------------------------------------------------- procedures --

@(private = "file")
check_proc :: proc(k: ^Checker, d: ^Decl, literal: ^Expr_Proc) {
	if len(d.names) != 1 {
		errorf(k.c, d.span, "L0312", "a procedure declaration binds exactly one name")
	}
	signature := literal.signature
	// Checked by `check_foreign_block`.
	if len(d.symbols) == 1 && d.symbols[0] != INVALID_SYMBOL {
		if sym := symbol_of(k.c, d.symbols[0]); sym != nil && sym.is_foreign {
			return
		}
	}
	if literal.bodiless {
		errorf(
			k.c, literal.span, "L0630",
			"only a foreign declaration ends with `---`; a procedure declared here needs a body",
		)
		return
	}
	if signature == nil {
		unsupported_construct(k, literal.span)
		return
	}
	// design.md "where clauses": only with generic parameters in scope.
	if len(literal.where_clauses) > 0 && !literal.generic_instance && k.generic_depth == 0 {
		errorf(
			k.c,
			expr_span(literal.where_clauses[0]),
			"L0433",
			"a `where` clause needs a generic parameter in scope; use `if` or `assert` for a runtime precondition",
		)
		return
	}
	symbol := symbol_of(k.c, literal.symbol)
	if symbol == nil {
		return
	}
	if symbol.bound_excluded {
		// Its `where` bound excluded it from this instantiation.
		return
	}
	if k.generic_depth > 0 && !literal.generic_instance {
		// A method of an instantiated block.
		if !check_where_clauses(k, literal.where_clauses, literal.span, identifier_text(k.c, symbol.name), true) {
			return
		}
	}
	if symbol.signature_error {
		return // resolving the signature already said what is wrong with it
	}
	if !gate_type(k, symbol.proc_type, literal.span) {
		return
	}
	check_proc_body(k, literal)
}

// Installs parameters, checks the body, and demands a return on every path that
// can fall out of a result-bearing procedure.
check_proc_body :: proc(k: ^Checker, literal: ^Expr_Proc) {
	symbol := symbol_of(k.c, literal.symbol)
	if symbol == nil {
		return
	}
	outer_scope := k.scope
	outer_proc := k.proc_literal
	outer_result := k.result_type
	outer_result_inout := k.result_inout
	outer_loop, outer_defer := k.loop_depth, k.in_defer
	defer {
		k.scope = outer_scope
		k.proc_literal = outer_proc
		k.result_type = outer_result
		k.result_inout = outer_result_inout
		k.loop_depth, k.in_defer = outer_loop, outer_defer
	}
	// Only this body's uses, not an enclosing one's (`nil_uses.odin`).
	nil_mark := len(k.nil_uses)
	defer report_nil_uses(k, nil_mark)

	k.scope = new_scope(k.c, outer_scope, .Procedure)
	k.scope.owner_proc = literal
	k.proc_literal = literal
	k.result_type = symbol.result
	k.result_inout = symbol.result_inout
	k.loop_depth, k.in_defer = 0, false
	outer_slots := k.defer_slots
	k.defer_slots = 0
	defer k.defer_slots = outer_slots

	errors_before := k.c.error_count
	// Defaults were checked with the signature; the body only needs the names.
	for parameter in literal.signature.params {
		install_symbols(k.scope, k.c, parameter.symbols)
	}

	flow := check_block(k, literal.body)
	// design.md "Managed values and storage": dataflow over the finished body.
	analyze_ownership(k, literal)
	// Provenance runs later, once every body's summary is settled.
	append(&k.c.checked_bodies, Checked_Body{literal = literal, clean = k.c.error_count == errors_before})
	literal.defer_count = k.defer_slots
	if symbol.result != INVALID_TYPE && flow.can_fall_through {
		errorf(k.c, literal.span, "L0365", "this procedure can end without returning a value")
	}
}

install_symbols :: proc(scope: ^Scope, c: ^Compiler, symbols: []Symbol_Id) {
	for id in symbols {
		if symbol := symbol_of(c, id); symbol != nil && symbol.name != INVALID_IDENTIFIER {
			scope.names[symbol.name] = id
		}
	}
}

// --------------------------------------------------------- statements --

check_block :: proc(k: ^Checker, b: ^Block) -> Flow_Info {
	if b == nil {
		return FLOWS
	}
	return check_stmts(k, b.stmts)
}

// The combined flow of a statement sequence: a block's, or one switch case's.
check_stmts :: proc(k: ^Checker, stmts: []Stmt) -> Flow_Info {
	flow := FLOWS
	for stmt in stmts {
		result := check_stmt(k, stmt)
		flow.returns ||= result.returns
		flow.breaks ||= result.breaks
		flow.continues ||= result.continues
		flow.can_fall_through = flow.can_fall_through && result.can_fall_through
	}
	report_unread_required_results(k, stmts)
	return flow
}

// design.md "@(require_results)": a required result bound and never read.
// Asked after the whole sequence is checked, in source order.
@(private = "file")
report_unread_required_results :: proc(k: ^Checker, stmts: []Stmt) {
	for stmt in stmts {
		d, is_decl := stmt.(^Decl)
		if !is_decl || d.kind != .Var {
			continue
		}
		for id, index in d.symbols {
			sym := symbol_of(k.c, id)
			if sym == nil || sym.named || sym.kind != .Var {
				continue
			}
			required := type_requires_results(k.c, sym.type)
			source := ""
			if !required && index < len(d.values) {
				if call, is_call := d.values[index].(^Expr_Call); is_call && call.type != INVALID_TYPE {
					source, required = required_result_of_call(k, call)
				}
			}
			if !required {
				continue
			}
			span := index < len(d.names) ? d.names[index].span : d.span
			if source != "" {
				errorf(
					k.c, span, "L0698",
					"`%s` holds the result of `%s`, which is never used: inspect it, or discard it with `_ = ...`",
					identifier_text(k.c, sym.name), source,
				)
				continue
			}
			errorf(
				k.c, span, "L0698",
				"`%s` holds a `%s` that is never used: inspect it, or discard it with `_ = ...`",
				identifier_text(k.c, sym.name), type_name(k.c, sym.type),
			)
		}
	}
}

check_scoped_block :: proc(k: ^Checker, b: ^Block) -> Flow_Info {
	outer := k.scope
	k.scope = new_scope(k.c, outer, .Local)
	defer k.scope = outer
	return check_block(k, b)
}

// The backend emits only file-level procedures, so a local one (or a local
// `impl` method) is hoisted like a literal.
hoist_body_local_proc :: proc(k: ^Checker, d: ^Decl) {
	literal := decl_proc_literal(d)
	if literal == nil || k.c.speculation_depth != 0 || len(d.symbols) == 0 {
		return
	}
	if d.symbols[0] == INVALID_SYMBOL || symbol_is_generic(k, d.symbols[0]) {
		return
	}
	if pkg := package_of(k.c, k.pkg); pkg != nil {
		append(&pkg.hoisted_procs, literal)
	}
}

check_stmt :: proc(k: ^Checker, stmt: Stmt) -> Flow_Info {
	#partial switch _ in stmt {
	case ^Decl, ^Item_Impl:
		// Validated with their members, by position.
	case:
		validate_attribute_list(k, stmt_base(stmt).attributes, .Statement)
	}
	switch s in stmt {
	case ^Stmt_Error:
		// Parser diagnostics already describe this retained recovery node.
		return FLOWS

	case ^Item_Impl:
		check_local_impl(k, s)
		return FLOWS

	case ^Decl:
		declare_all(k, s)
		install_symbols(k.scope, k.c, s.symbols)
		// The package phases, in the same order, for a local declaration.
		create_nominal_type_shell(k, s)
		resolve_declaration_signature(k, s)
		hoist_body_local_proc(k, s)
		// Local symbols do not exist during the package-wide attribute pass.
		validate_decl_attributes(k, s, .Local)
		check_decl(k, s)
		return FLOWS

	case ^Stmt_Expr:
		flow := FLOWS
		for expr in s.exprs {
			if expr != nil && !expression_statement_has_effect(expr) {
				errorf(k.c, expr_span(expr), "L0313", "this expression statement has no effect")
			}
			check_expr(k, expr)
			report_discarded_required_results(k, expr)
			// `panic` never returns, in either phase, so nothing after it in this
			// block is reachable.
			if is_builtin_call(k.c, expr, .Panic) {
				flow.can_fall_through = false
			}
		}
		return flow

	case ^Stmt_Assign:
		check_assign(k, s)
		return FLOWS

	case ^Stmt_If:
		return check_if(k, s)

	case ^Stmt_For:
		return check_for(k, s)

	case ^Stmt_Switch:
		return check_switch(k, s)

	case ^Stmt_Defer:
		return check_defer(k, s)

	case ^Stmt_Return:
		return check_return(k, s)

	case ^Stmt_Branch:
		return check_branch(k, s)

	case ^Block:
		return check_scoped_block(k, s)

	case ^Stmt_When:
		return check_when_stmt(k, s)

	case ^Stmt_Foreach:
		// A `$` binding makes this a compile-time expansion.
		for binding in s.bindings {
			if binding.is_static {
				return check_static_foreach(k, s)
			}
		}
		return check_runtime_foreach(k, s)
	}
	unsupported_construct(k, stmt_span(stmt))
	return FLOWS
}

// A procedure-scope `when` introduces no scope: the selected branch behaves as
// if written in its place.
@(private = "file")
check_when_stmt :: proc(k: ^Checker, s: ^Stmt_When) -> Flow_Info {
	if s.resolved {
		return FLOWS // already selected and checked
	}
	s.resolved = true
	value, ok := check_when_condition(k, s.cond)
	if !ok {
		return FLOWS
	}
	if value {
		s.selected = s.then
		return check_block(k, s.then)
	}
	#partial switch otherwise in s.otherwise {
	case ^Stmt_When:
		flow := check_when_stmt(k, otherwise)
		s.selected = when_selected_block(otherwise)
		return flow
	case ^Block:
		s.selected = otherwise
		return check_block(k, otherwise)
	}
	return FLOWS
}

// A call, or a single-valued `or_return` over one — the only expressions
// design.md allows as a standalone statement.
@(private = "file")
expression_statement_has_effect :: proc(e: Expr) -> bool {
	#partial switch v in e {
	case ^Expr_Call:
		return true
	case ^Expr_Postfix:
		return v.op == .Or_Return
	}
	return false
}

is_builtin_call :: proc(c: ^Compiler, e: Expr, kind: Builtin_Kind) -> bool {
	call, is_call := e.(^Expr_Call)
	if !is_call {
		return false
	}
	symbol := symbol_of(c, call.resolution.symbol)
	return symbol != nil && symbol.kind == .Builtin && symbol.builtin == kind
}

// design.md "Assignment statements": every right side is evaluated, then every
// destination address, then the writes happen. The checker records the pieces;
// the backend preserves the order.
@(private = "file")
check_assign :: proc(k: ^Checker, s: ^Stmt_Assign) {
	if s.op != .Assign {
		check_compound_assign(k, s)
		return
	}

	// `a, b = record`: one record value filling several destinations.
	if len(s.rhs) == 1 && len(s.lhs) > 1 {
		check_expr(k, s.rhs[0])
		if base := expr_base(s.rhs[0]); base != nil && type_is_destructurable(k.c, base.type) {
			if fields, ok := destructure_fields(
				k, base.type, len(s.lhs), expr_span(s.rhs[0]), "L0360", "bound by a destructuring assignment",
			); ok {
				retained := make([]bool, len(fields), k.c.semantic_allocator)
				for target, index in s.lhs {
					retained[index] = !is_discard(target)
				}
				s.destructure = plan_destructure(k, s.rhs[0], base.type, fields, retained)
				for target, index in s.lhs {
					field := symbol_of(k.c, fields[index])
					if field == nil {
						return
					}
					check_assign_target(k, target, field.type)
					note_unknown_nil_write(k, target)
				}
			}
			return
		}
	}
	if len(s.lhs) != len(s.rhs) {
		errorf(
			k.c,
			s.span,
			"L0360",
			"%d destination%s but %d value%s",
			len(s.lhs),
			len(s.lhs) == 1 ? "" : "s",
			len(s.rhs),
			len(s.rhs) == 1 ? "" : "s",
		)
		if len(s.rhs) == 1 && len(s.lhs) > 1 {
			note_optional_replacement(k, s.rhs[0])
		}
		return
	}
	for target, index in s.lhs {
		// A discard destination constrains nothing; its value is still evaluated
		// for whatever it does on the way.
		if is_discard(target) {
			ident := target.(^Expr_Ident)
			ident.type = check_single_expr(k, s.rhs[index])
			ident.immutable = .Discard
			if type_is_untyped(k.c, ident.type) {
				materialize(k, s.rhs[index], default_type(k.c, ident.type))
				ident.type = expr_base(s.rhs[index]).type
			}
			continue
		}
		// `grid[x, y] = v` on a container with no location to hand out.
		if indexed, is_index := target.(^Expr_Index); is_index {
			if check_place_setter(k, s, indexed, s.rhs[index]) {
				continue
			}
		}
		type := check_assign_target(k, target, INVALID_TYPE)
		if type == INVALID_TYPE {
			check_expr(k, s.rhs[index])
			continue
		}
		check_value_expr(k, s.rhs[index], type, "assign")
		note_nil_write(k, target, s.rhs[index])
	}
}

// design.md: `operator([]=)` is for containers that have no location to hand
// out. It is reached only when no `operator([])` returning `inout` exists, so a
// type that can supply an address still gets an ordinary store.
@(private = "file")
check_place_setter :: proc(k: ^Checker, s: ^Stmt_Assign, target: ^Expr_Index, value: Expr) -> bool {
	operand := check_single_expr(k, target.operand)
	if operand == INVALID_TYPE {
		return false
	}
	operands := []Type_Id{operand}
	setters := operator_candidates_for_receiver(k, "[]=", operand)
	if len(setters) == 0 {
		return false
	}
	for candidate in operator_candidates_for_receiver(k, "[]", operand) {
		if operator_result_is_place(k, candidate) {
			return false // it can hand out a location, so an ordinary store applies
		}
	}
	args, ok := index_and_value_arguments(k, target, value)
	if !ok {
		return true
	}
	chosen, bound := resolve_operator(k, s.op_span, "[]=", operands, args, among = setters)
	if chosen == INVALID_SYMBOL {
		return true
	}
	s.place_setter = chosen
	s.setter_bound = bound
	return true
}

@(private = "file")
index_and_value_arguments :: proc(k: ^Checker, target: ^Expr_Index, value: Expr) -> ([]Arg_Info, bool) {
	args := make([]Arg_Info, len(target.indices) + 2, k.c.semantic_allocator)
	args[0] = arg_from_expr(k, target.operand)
	args[0].is_receiver = true
	ok := true
	for index, position in target.indices {
		if check_single_expr(k, index) == INVALID_TYPE {
			ok = false
			continue
		}
		args[position + 1] = arg_from_expr(k, index)
	}
	if check_single_expr(k, value) == INVALID_TYPE {
		ok = false
	} else {
		args[len(args) - 1] = arg_from_expr(k, value)
	}
	return args, ok
}

@(private = "file")
check_compound_assign :: proc(k: ^Checker, s: ^Stmt_Assign) {
	if len(s.lhs) != 1 || len(s.rhs) != 1 {
		errorf(k.c, s.op_span, "L0360", "a compound assignment takes one destination and one value")
		return
	}
	// design.md "Maps": `m[key] += 1` reads and writes one element, so the entry
	// must already be there; only `m[key] = elem` creates one.
	note_unknown_nil_write(k, s.lhs[0])
	type := check_assign_target(k, s.lhs[0], INVALID_TYPE, inserts = false)
	if type == INVALID_TYPE {
		check_expr(k, s.rhs[0])
		return
	}
	op := compound_operator(s.op)
	if op == .EOF {
		unsupported_construct(k, s.op_span)
		return
	}
	// Whether a SIMD operation is built in depends on the right operand, so it is
	// checked first.
	if type_is_simd(k.c, type) && compound_applies(k.c, op, type) {
		hint := argument_needs_context(s.rhs[0]) ? type : INVALID_TYPE
		rhs_type := check_single_expr(k, s.rhs[0], hint)
		if rhs_type == INVALID_TYPE {
			return
		}
		info := underlying_info(k.c, type)
		builtin_rhs := info != nil &&
			(type_underlying(k.c, rhs_type) == type_underlying(k.c, type) ||
			 (!type_is_simd(k.c, rhs_type) && assignable(k.c, rhs_type, info.element)))
		if !builtin_rhs && check_user_compound(k, s, op, type, rhs_type) {
			return
		}
		materialize_value_expr(k, s.rhs[0], type, "assign")
		return
	}
	// The built-in compound operation wins where it is defined; otherwise a
	// direct `+=` overload, and failing that the binary `+` fallback.
	if !operand_is_builtin(k, type) || !compound_applies(k.c, op, type) {
		if check_user_compound(k, s, op, type) {
			return
		}
	}
	if type_is_simd(k.c, type) && !compound_applies(k.c, op, type) {
		errorf(
			k.c, s.op_span, "L0318",
			"`%s` does not apply to `%s`", operator_text(op), type_name(k.c, type),
		)
		return
	}
	// design.md "SIMD vectors": a vector shift splats its count.
	if (op == .Shl || op == .Shr) && !type_is_simd(k.c, type) {
		if !check_shift_count(k, s.rhs[0]) {
			return
		}
	} else if !check_value_expr(k, s.rhs[0], type, "assign") {
		return
	}
	if !compound_applies(k.c, op, type) {
		errorf(
			k.c,
			s.op_span,
			"L0318",
			"`%s` does not apply to `%s`",
			operator_text(op),
			type_name(k.c, type),
		)
	}
}

// A direct compound overload, or the binary operator plus an assignment.
@(private = "file")
check_user_compound :: proc(
	k: ^Checker, s: ^Stmt_Assign, op: Token_Kind, type: Type_Id,
	prechecked_rhs: Type_Id = INVALID_TYPE,
) -> bool {
	rhs_type := prechecked_rhs
	if rhs_type == INVALID_TYPE {
		rhs_type = check_single_expr(k, s.rhs[0])
		if rhs_type == INVALID_TYPE {
			return true // already reported; re-checking it would report a second time
		}
	}
	operands := []Type_Id{type, rhs_type}

	compound := operator_spelling(s.op)
	direct_args := make([]Arg_Info, 2, k.c.semantic_allocator)
	direct_args[0] = arg_from_expr(k, s.lhs[0], .Inout)
	direct_args[1] = arg_from_expr(k, s.rhs[0])
	if operator_viable(k, compound, operands, direct_args) {
		chosen, bound := resolve_operator(k, s.op_span, compound, operands, direct_args)
		if chosen == INVALID_SYMBOL {
			return true
		}
		s.lhs[0], s.rhs[0] = bound[0], bound[1]
		s.operator, s.operator_direct = chosen, true
		return true
	}

	binary := operator_text(op)
	args := make([]Arg_Info, 2, k.c.semantic_allocator)
	args[0] = arg_from_expr(k, s.lhs[0])
	args[1] = arg_from_expr(k, s.rhs[0])
	if !operator_viable(k, binary, operands, args) {
		if operator_exists(k, compound, operands) {
			resolve_operator(k, s.op_span, compound, operands, direct_args)
			return true
		}
		if operator_exists(k, binary, operands) {
			resolve_operator(k, s.op_span, binary, operands, args, type)
			return true
		}
		return false
	}
	chosen, bound := resolve_operator(k, s.op_span, binary, operands, args, type)
	if chosen == INVALID_SYMBOL {
		return true
	}
	result := symbol_of(k.c, chosen)
	if result.result == INVALID_TYPE || !assignable(k.c, result.result, type) {
		errorf(
			k.c,
			s.op_span,
			"L0417",
			"`%s` produces `%s`, which cannot be assigned back to `%s`",
			binary,
			result.result == INVALID_TYPE ? "no value" : type_name(k.c, result.result),
			type_name(k.c, type),
		)
		return true
	}
	s.lhs[0], s.rhs[0] = bound[0], bound[1]
	s.operator, s.operator_direct = chosen, false
	return true
}

// The destination half of an assignment. A `_` on the left is a discard, which
// is a legal destination with no storage.
@(private = "file")
check_assign_target :: proc(k: ^Checker, target: Expr, from: Type_Id, inserts := true) -> Type_Id {
	if is_discard(target) {
		ident := target.(^Expr_Ident)
		ident.type = from
		ident.immutable = .Discard
		ident.value_category = .Invalid
		return from == INVALID_TYPE ? TYPE_VOID : from
	}
	k.place_position, k.insert_position = true, inserts
	type := check_single_expr(k, target)
	k.place_position, k.insert_position = false, false
	if type == INVALID_TYPE {
		return INVALID_TYPE
	}
	base := expr_base(target)
	if !base.assignable {
		report_not_assignable(k, base, "an assignment destination")
		return INVALID_TYPE
	}
	if from != INVALID_TYPE && !assignable(k.c, from, type) {
		errorf(
			k.c,
			expr_span(target),
			"L0310",
			"cannot assign `%s` with `%s`",
			type_name(k.c, type),
			type_name(k.c, from),
		)
		return INVALID_TYPE
	}
	if from != INVALID_TYPE { record_proc_contract_check(k.c, from, type, expr_span(target)) }
	return type
}

report_not_assignable :: proc(k: ^Checker, base: ^Expr_Base, what: string) {
	switch base.immutable {
	case .Constant:
		errorf(k.c, base.span, "L0358", "a constant cannot be %s", what)
	case .Value_Parameter:
		errorf(k.c, base.span, "L0358", "a value parameter is immutable and cannot be %s", what)
	case .Temporary:
		errorf(k.c, base.span, "L0359", "a temporary value cannot be %s", what)
	case .Discard:
		errorf(k.c, base.span, "L0359", "`_` cannot be %s", what)
	case .Read_Only:
		errorf(k.c, base.span, "L0478", "this is read-only storage and cannot be %s", what)
	case .Through_Pointer:
		errorf(
			k.c, base.span, "L0640",
			"this place is reached through a read-only `^T` and cannot be %s; borrow it with `&mut` for a `^mut T`",
			what,
		)
	case .None, .Not_A_Place:
		errorf(k.c, base.span, "L0359", "this expression cannot be %s", what)
	}
}

@(private = "file")
compound_applies :: proc(c: ^Compiler, op: Token_Kind, type: Type_Id) -> bool {
	if type_kind(c, type) == .Distinct {
		return false
	}
	if info := underlying_info(c, type); info != nil && info.kind == .Simd {
		return simd_operator_applies(c, op, info.element)
	}
	#partial switch op {
	case .Plus, .Minus, .Star, .Slash:
		return type_is_numeric(c, type)
	case .Percent, .Pipe, .Tilde, .Amp, .Amp_Tilde, .Shl, .Shr:
		return type_is_integer(c, type) || type_is_rune(c, type)
	}
	return false
}

// The init statement's scope spans the condition and both branches.
@(private = "file")
check_if :: proc(k: ^Checker, s: ^Stmt_If) -> Flow_Info {
	outer := k.scope
	k.scope = new_scope(k.c, outer, .Local)
	defer k.scope = outer

	if s.init != nil {
		check_stmt(k, s.init)
	}
	check_condition(k, s.cond)

	then_flow := check_scoped_block(k, s.then)
	if s.otherwise == nil {
		return Flow_Info {
			can_fall_through = true,
			returns          = then_flow.returns,
			breaks           = then_flow.breaks,
			continues        = then_flow.continues,
		}
	}
	else_flow := check_stmt(k, s.otherwise)
	return Flow_Info {
		can_fall_through = then_flow.can_fall_through || else_flow.can_fall_through,
		returns          = then_flow.returns || else_flow.returns,
		breaks           = then_flow.breaks || else_flow.breaks,
		continues        = then_flow.continues || else_flow.continues,
	}
}

check_condition :: proc(k: ^Checker, cond: Expr) {
	if cond == nil {
		return
	}
	type := check_single_expr(k, cond, TYPE_BOOL)
	if type == INVALID_TYPE {
		return
	}
	materialize(k, cond, TYPE_BOOL)
	if !type_is_boolean(k.c, expr_base(cond).type) {
		errorf(k.c, expr_span(cond), "L0355", "a condition must be `bool`, found `%s`", type_name(k.c, type))
	}
}

@(private = "file")
check_for :: proc(k: ^Checker, s: ^Stmt_For) -> Flow_Info {
	outer := k.scope
	k.scope = new_scope(k.c, outer, .Local)
	defer k.scope = outer

	if s.init != nil {
		check_stmt(k, s.init)
	}
	check_condition(k, s.cond)

	k.loop_depth += 1
	body := check_scoped_block(k, s.body)
	if s.post != nil {
		check_stmt(k, s.post)
	}
	k.loop_depth -= 1
	// `for (;;)` without a `break` never falls out of the loop.
	infinite := s.cond == nil
	return Flow_Info {
		can_fall_through = !infinite || body.breaks,
		returns          = body.returns,
	}
}

@(private = "file")
check_switch :: proc(k: ^Checker, s: ^Stmt_Switch) -> Flow_Info {
	if s.kind != .Value {
		return check_type_switch(k, s)
	}
	outer := k.scope
	k.scope = new_scope(k.c, outer, .Local)
	defer k.scope = outer

	if s.init != nil {
		check_stmt(k, s.init)
	}
	subject := check_single_expr(k, s.subject)
	if subject == INVALID_TYPE {
		// Not falling through, so no missing return is blamed on it.
		return Flow_Info{}
	}
	// design.md "Inspecting a union": the subject's type decides.
	if type_is_union(k.c, subject) {
		adopt_branch_patterns(s)
		return check_variant_cases(k, s, subject)
	}
	if type_is_untyped(k.c, subject) {
		materialize(k, s.subject, default_type(k.c, subject))
		subject = expr_base(s.subject).type
	}
	if !type_is_comparable(k.c, subject) {
		errorf(k.c, expr_span(s.subject), "L0355", "`%s` is not comparable", type_name(k.c, subject))
		return Flow_Info{}
	}

	seen := make([dynamic]Const_Value, 0, 8, context.temp_allocator)
	covered := make(map[u32]bool, 0, context.temp_allocator)
	has_default := false
	flow := Flow_Info{}
	any_case_falls := false
	for &entry in s.cases {
		if len(entry.values) == 0 {
			if has_default {
				errorf(k.c, entry.span, "L0367", "this switch already has a default case")
			}
			has_default = true
		}
		for value in entry.values {
			check_case_value(k, value, subject, &seen, &covered)
		}
		case_scope := k.scope
		k.scope = new_scope(k.c, case_scope, .Local)
		case_flow := check_stmts(k, entry.stmts)
		k.scope = case_scope
		flow.returns ||= case_flow.returns
		flow.breaks ||= case_flow.breaks
		flow.continues ||= case_flow.continues
		any_case_falls ||= case_flow.can_fall_through
	}

	member_complete := false
	if !has_default {
		member_complete = check_exhaustive(k, s, subject, covered)
	}
	// Closed enums have exactly their declared variants, as tagged unions do.
	s.exhaustive = has_default || member_complete
	return Flow_Info {
		can_fall_through = !s.exhaustive || any_case_falls,
		returns          = flow.returns,
		breaks           = flow.breaks,
		continues        = flow.continues,
	}
}

@(private = "file")
check_case_value :: proc(
	k: ^Checker,
	value: Expr,
	subject: Type_Id,
	seen: ^[dynamic]Const_Value,
	covered: ^map[u32]bool,
) {
	if range, is_range := value.(^Expr_Range); is_range {
		check_value_expr(k, range.lo, subject, "compare")
		check_value_expr(k, range.hi, subject, "compare")
		range.type = subject
		if !type_is_ordered(k.c, subject) {
			errorf(k.c, range.op_span, "L0355", "`%s` is not ordered, so a range case is not meaningful", type_name(k.c, subject))
		}
		return
	}
	if !check_value_expr(k, value, subject, "compare") {
		return
	}
	base := expr_base(value)
	if !base.is_const {
		return // an ordered dynamic case, compared in source order
	}
	for previous in seen {
		equal, ok := const_equal(k.c, previous, base.const_value)
		if ok && equal {
			errorf(k.c, expr_span(value), "L0367", "this value is already covered by an earlier case")
			return
		}
	}
	append(seen, base.const_value)
	if type_is_enum(k.c, subject) {
		if member := enum_member_by_value(k.c, subject, base.const_value); member != INVALID_SYMBOL {
			covered[u32(member)] = true
		}
	}
}

// design.md "Exhaustive switch": a switch over an enum with no default must
// name every member.
@(private = "file")
check_exhaustive :: proc(k: ^Checker, s: ^Stmt_Switch, subject: Type_Id, covered: map[u32]bool) -> (complete: bool) {
	if !type_is_enum(k.c, subject) {
		errorf(k.c, s.span, "L0366", "a switch over `%s` needs a default case", type_name(k.c, subject))
		return false
	}
	info := underlying_info(k.c, subject)
	missing := ""
	count := 0
	for member in info.fields {
		if covered[u32(member)] {
			continue
		}
		count += 1
		symbol := symbol_of(k.c, member)
		if count <= 3 {
			if missing != "" {
				missing = concat(k.c, missing, ", ")
			}
			missing = concat(k.c, missing, identifier_text(k.c, symbol.name))
		}
	}
	if count == 0 {
		return true
	}
	if count > 3 {
		missing = concat(k.c, missing, ", ...")
	}
	errorf(k.c, s.span, "L0366", "this switch over `%s` does not cover %s", type_name(k.c, subject), missing)
	return false
}

// Also the validity test for an `unsafe.transmute` whose destination is an enum:
// a constant pattern matching no member is a value the type never admits.
enum_member_by_value :: proc(c: ^Compiler, type: Type_Id, value: Const_Value) -> Symbol_Id {
	info := underlying_info(c, type)
	if info == nil || value.kind != .Integer {
		return INVALID_SYMBOL
	}
	for member in info.fields {
		symbol := symbol_of(c, member)
		if symbol == nil || symbol.const_value.kind != .Integer {
			continue
		}
		if bi_cmp(c, symbol.const_value.integer, value.integer) == 0 {
			return member
		}
	}
	return INVALID_SYMBOL
}

const_equal :: proc(c: ^Compiler, a, b: Const_Value) -> (bool, bool) {
	if a.kind != b.kind {
		return false, false
	}
	#partial switch a.kind {
	case .Integer, .Rune:
		return bi_cmp(c, a.integer, b.integer) == 0, true
	case .Boolean:
		return a.boolean == b.boolean, true
	case .Float:
		return a.float == b.float, true
	case .String:
		return a.text == b.text, true
	case .Type:
		return a.type_value == b.type_value, true
	case .Nil:
		return true, true
	}
	return false, false
}

// design.md "defer statement": deferred code runs on the way out of its own
// scope, so it may not itself leave that scope.
@(private = "file")
check_defer :: proc(k: ^Checker, s: ^Stmt_Defer) -> Flow_Info {
	if k.in_defer {
		errorf(k.c, s.span, "L0369", "a deferred statement cannot contain another `defer`")
		return FLOWS
	}
	s.slot = k.defer_slots
	k.defer_slots += 1
	k.in_defer = true
	flow := check_stmt(k, s.stmt)
	k.in_defer = false

	if flow.returns {
		errorf(k.c, s.span, "L0369", "a deferred statement cannot `return`")
	}
	if flow.breaks || flow.continues {
		errorf(k.c, s.span, "L0369", "a deferred statement cannot leave the construct it is registered in")
	}
	return FLOWS
}

@(private = "file")
check_return :: proc(k: ^Checker, s: ^Stmt_Return) -> Flow_Info {
	if k.in_defer {
		// Reported by `check_defer` from the flow summary; nothing to add here.
		return Flow_Info{returns = true}
	}
	terminated := Flow_Info{returns = true}

	if s.value == nil {
		if k.result_type != INVALID_TYPE {
			errorf(
				k.c, s.span, "L0326",
				"this procedure returns `%s`, so `return` needs a value; a result is anonymous and has no local to fill",
				type_name(k.c, k.result_type),
			)
		}
		return terminated
	}
	if k.result_type == INVALID_TYPE {
		// A written result that did not resolve was already reported.
		if k.proc_literal != nil && k.proc_literal.signature.result != nil {
			return terminated
		}
		errorf(k.c, s.span, "L0326", "this procedure returns nothing")
		return terminated
	}

	value := s.value
	if !check_value_expr(k, value.expr, k.result_type, "return") {
		return terminated
	}
	classify_return_value(k, value, k.result_type)
	// design.md "`inout` results": an assignable place of exactly the result type.
	if k.result_inout {
		base := expr_base(value.expr)
		switch {
		case base == nil || !base.addressable:
			errorf(k.c, expr_span(value.expr), "L0418", "an `inout` result must return a place")
		case !base.assignable:
			report_not_assignable(k, base, "returned as `inout`")
		case base.type != k.result_type:
			errorf(
				k.c, expr_span(value.expr), "L0418",
				"an `inout` result must return a place of exactly `%s`, found `%s`",
				type_name(k.c, k.result_type), type_name(k.c, base.type),
			)
		}
	}
	return terminated
}

@(private = "file")
check_branch :: proc(k: ^Checker, s: ^Stmt_Branch) -> Flow_Info {
	if s.kind == .Break {
		if k.loop_depth == 0 {
			errorf(k.c, s.span, "L0368", "`break` is only valid inside a loop")
			return FLOWS
		}
		return Flow_Info{breaks = true}
	}
	if k.loop_depth == 0 {
		errorf(k.c, s.span, "L0368", "`continue` is only valid inside a loop")
		return FLOWS
	}
	return Flow_Info{continues = true}
}

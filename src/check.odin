// Name resolution and type checking, plus the constant
// folding that stands in for the compile-time engine until M3.
//
// Owns declarations, statements, signatures, and the type syntax that names a
// type; `check_expr.odin` owns everything that produces a value. Annotations
// are written back onto the AST nodes — no separate typed tree (decision A1).
package lokec

import "core:strings"

Checker :: struct {
	c:     ^Compiler,
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
	// design.md "Indexing and slicing": in a place position an `operator([])`
	// overload returning `inout T` is required before ordinary ranking. The flag
	// is consumed by the node it is set for and never inherited by its operands.
	place_position: bool,
	// design.md "Maps": the whole-element assignment `m[key] = elem` is the one
	// index form that creates an entry, so this is set only for the destination
	// of a plain assignment, and cleared on the way down through a field or
	// index chain. Every other place position — a compound assignment, an
	// `inout` argument, `&m[key]` — names a location inside an element that must
	// already be there.
	insert_position: bool,
	// How many generic instantiations enclose the code being checked. A `where`
	// clause needs generic parameters in scope, which is either a template being
	// instantiated or a declaration inside one.
	generic_depth:  int,
	// How deep interface requirement checking is, so an interface that composes
	// itself is a diagnostic rather than a spin.
	interface_depth: int,

	// The procedure being checked. `proc_literal` also identifies the frame a
	// name may come from, which is what makes the capture check possible.
	proc_literal:   ^Expr_Proc,
	// design.md: at most one result. INVALID_TYPE means the procedure has none.
	result_type:    Type_Id,
	// Whether the result was declared `inout`: such a result returns a place, so
	// its `return inout e` needs an addressable operand.
	result_inout:   bool,

	// Lexical targets for `break`, `continue`, and `defer` restrictions.
	loop_depth:   int,
	switch_depth: int,
	in_defer:     bool,
	// One flag slot per syntactic `defer` in the procedure being checked.
	defer_slots:  int,
}

// What a statement can do to control flow. A single "terminates" boolean cannot
// answer missing-return, unreachable emission, loop exit, and cleanup routing at
// once.
Flow_Info :: struct {
	can_fall_through: bool,
	returns:          bool,
	breaks:           bool,
	continues:        bool,
	// Set when this statement falls through *only* because an enum can hold a
	// non-member value: a member-complete switch with no default whose cases
	// all terminate. It carries the span the missing-return diagnostic blames,
	// since the signature is not where the answer is.
	open_enum_exit:   ^Stmt_Switch,
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
	// Before the package's own declarations are collected, so a source
	// declaration colliding with a contributed name is an ordinary
	// redeclaration rather than a silent replacement.
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
				// design.md "Foreign system": a block's members are collected as
				// ordinary symbols here, so nothing downstream needs a foreign path
				// for name resolution or overloads.
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
	// design.md "Typed fallibility": the three bootstrap declarations enter the
	// universe as soon as `base:runtime`'s own names exist, which is before any
	// other package is prepared.
	bind_runtime_bootstrap(k, pkg)
	// Aliases first: an `impl vendor.Vector2` block names its subject through
	// one, so the alias has to exist before the block can resolve it.
	bind_import_aliases(k, pkg)
	// Last, and one block at a time: only those whose subject has stopped
	// changing shape. Declaring a block resolves its subject, and resolving a
	// record resolves its fields -- which a `when` branch not selected yet may be
	// what declares. A signature resolves exactly once
	// (`resolve_declaration_signature` returns on any `sig_state` but
	// `.Unchecked`), so doing it early does not merely report early, it freezes a
	// subject whose fields never resolved. `core:fs` writes that shape: `impl
	// File`, and `File.handle` has the type its `when (LOKE_OS)` declares.
	//
	// The question belongs to the subject's package, not to this one. `impl
	// vendor.Cell` resolves `Cell` in `vendor`'s scope, so it is `vendor`'s
	// selection that has to have settled -- and `vendor`'s imports' too, since a
	// field may be spelled `other.Thing`.
	//
	// Nothing is lost by waiting. A block still undeclared once selection has
	// settled is declared by `resolve_impl_signatures`, which is also what turns
	// an unresolvable subject from pending into a diagnostic.
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

// The package whose scope this `impl` subject is written in, read off the
// syntax rather than resolved -- resolving is the very thing being gated. An
// unbound alias answers this package, which costs nothing: the subject will not
// resolve either, and `declare_impl_block` leaves such a block for a later
// round.
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

// design.md: an import name is a lexical alias and nothing more. Two names for
// one package refer to the same declarations and never create a second
// instance, which is why the alias symbol only carries a `Package_Id`.
@(private = "file")
bind_import_aliases :: proc(k: ^Checker, pkg: ^Package) {
	// Only the edges a previous round did not reach. Binding is one-way and the
	// list only grows, so re-walking the whole of it would re-report a collision
	// once per discovery round.
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

	// Phase 2b: resolve fields and callable signatures. Recursive types and
	// mutually recursive procedures now already have stable identities.
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

	// design.md "Attributes": one validation pass over the settled item view, run
	// after signatures so a procedure group's symbol kind is known, so an unknown,
	// misplaced, duplicated, or badly shaped attribute is one exact diagnostic
	//.
	validate_attributes(k, pkg)

	// Phase 2c: a struct or array that contains itself by value has no finite
	// size, and LLVM cannot be asked to lay one out. Pointer edges break the
	// cycle, so this runs on the resolved graph and before any emission.
	for file in pkg.files {
		k.file, k.file_node, k.scope = file.file, file, pkg.scope
		for item in file.active_items {
			if d, ok := item.(^Decl); ok {
				check_declaration_size(k, d)
			}
		}
	}

	// Phase 3: type checking and constant folding consume the binding IDs.
	for file in pkg.files {
		k.file, k.file_node, k.scope = file.file, file, pkg.scope
		for item in file.active_items {
			#partial switch v in item {
			case ^Decl:
				check_decl(k, v)
			case ^Item_Impl:
				check_impl_block(k, v)
			case ^Item_Import, ^Item_Foreign_Import, ^Item_Foreign_Block, ^Item_Error:
				// Foreign imports carry only a link path; foreign blocks were checked
				// in phase 2b. Neither has a Loke body to check here.
			case ^Item_Static_Assert:
				// Checked in phase 3b, once every declaration in the package has been.
			case:
				unsupported_construct(k, item_span(item))
			}
		}
	}

	// Phase 3b: file-scope assertions. They run after every declaration in the
	// package has been checked, so an assertion is independent of the order of
	// its file and of the split `impl` blocks it may be talking about. The item
	// holds the written call and nothing else, so this is the ordinary built-in
	// reached the ordinary way -- there is no second evaluator, and nothing is
	// left for emission.
	for file in pkg.files {
		k.file, k.file_node, k.scope = file.file, file, pkg.scope
		for item in file.active_items {
			if v, ok := item.(^Item_Static_Assert); ok {
				check_file_scope_static_assert(k, v)
			}
		}
	}
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

// design.md "@(export)": whole-program pass over every settled
// declaration. An exported symbol emits under its written name (or
// `@(link_name)`); two claiming the same name is a link-time failure with no
// source location, so the compiler names both here. An exported procedure needs
// a foreign calling convention and an ABI-safe signature (the latter already
// checked by `resolve_declaration_signature`); an exported global needs an
// ABI-safe type; neither may claim the reserved `loke_rt_` runtime prefix.
check_exports :: proc(c: ^Compiler) {
	claimed := make(map[string]Span, 16, context.temp_allocator)
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
		name, has := attribute_string_value(c, d.attributes, "link_name")
		if !has {
			name = identifier_text(c, sym.name)
		}
		if strings.has_prefix(name, "loke_rt_") {
			errorf(c, sym.span, "L0635", "an exported symbol cannot use the reserved `loke_rt_` runtime prefix: `%s`", name)
			continue
		}
		// A generic `@(export)` is already L0438 from the generic rules; skipping it
		// here keeps that one diagnostic rather than adding a second.
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

// Creates the symbols for one declaration. Shadowing anything already visible
// in the enclosing procedure is rejected — the default design.md's open
// question records. Also called for a foreign block's members
// (`src/foreign.odin`), so they become ordinary package symbols.
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
			// design.md: the same instantiation means the same thing in every
			// caller, so a clone resolves names against the declaration's own
			// lexical scope, not the scope that asked for it.
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

// The same visibility rule declarations use, applied to a struct field: own
// `@(public)` wins, own `@(private)` opts out, otherwise the file's default.
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

// design.md `@(escape=...)`: the level a parameter is written at, validated
// where it is written. A parameter that carries no borrow cannot escape, so the
// attribute on one is a mistake rather than a no-op — the same rule
// `@(allocator_reset)` has for a non-`Allocator` parameter.
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
	// A generic signature is written once for every binding of its parameters,
	// and a container storing `T` needs the level exactly when `T` carries a
	// borrow. `Small_Array(string_view, N)` needs it and `Small_Array(int, N)`
	// does not, so demanding that the one declaration be right for both would
	// make such a container unwritable. The level is simply vacuous where the
	// bound type carries nothing.
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

// The location-dependent part of Checker state. On-demand checking is used by
// constants, compile-time evaluation, associated members, and staged `when`
// selection; every one of those paths must resolve names with the declaration's
// own scope, file, package, and extension visibility.
Checker_Location :: struct {
	scope:      ^Scope,
	pkg:        Package_Id,
	lookup_pkg: Package_Id,
	impl_type:  Type_Id,
	file:       u32,
	file_node:  ^File,
}

save_checker_location :: proc(k: ^Checker) -> Checker_Location {
	return Checker_Location {
		scope = k.scope, pkg = k.pkg, lookup_pkg = k.lookup_pkg,
		impl_type = k.impl_type, file = k.file, file_node = k.file_node,
	}
}

restore_checker_location :: proc(k: ^Checker, saved: Checker_Location) {
	k.scope, k.pkg, k.lookup_pkg = saved.scope, saved.pkg, saved.lookup_pkg
	k.impl_type, k.file, k.file_node = saved.impl_type, saved.file, saved.file_node
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
			// design.md excludes a generic method from `dyn` and from nothing else,
			// so `value.method($T)` has to be reachable by method syntax. A template
			// has no resolved parameter types, and the ordinary receiver rule
			// compares one against the subject — so the receiver is read off the
			// syntax here, and the instantiation checks the type the usual way.
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
		// The identity is fresh but the representation is the underlying type's, so
		// an underlying type that did not resolve is what is wrong here.
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
		// A field whose written type did not resolve is what is wrong with the
		// record. Say so here; otherwise the declaration is gated as unimplemented,
		// which names neither the field nor the type.
		if field.type != nil && field_type == INVALID_TYPE && k.c.error_count == before {
			report_unresolved_type(k, field.type)
		}
		bindings := make([dynamic]Symbol_Id, 0, len(field.names), k.c.semantic_allocator)
		// design.md "Compile-time reflection": reflection observes only
		// declarations visible at the reflection site, so a field carries the same
		// visibility default as any other declaration in its file.
		public := field_is_public(k, field.attributes)
		reject_any_view_position(k, field_type, field.span, "a record field")
		for name in field.names {
			// A record's fields share one namespace, the way an enum's members
			// (L0304) and a union's variants (L0422) do. A repeat is not harmless:
			// the first field answers `s.x` and `offset_of`, and the second can never
			// be named or initialised -- a literal setting `x` twice is L0376 -- so it
			// is a hole nothing can reach.
			if name.text != "_" && member_named(k.c, members[:], identifier_id_of(k.c, name)) != INVALID_SYMBOL {
				errorf(k.c, name.span, "L0304", "`%s` is already a field of this record", name.text)
				append(&bindings, INVALID_SYMBOL)
				continue
			}
			binding := new_binding_symbol(k, name, .Field)
			if bound := symbol_of(k.c, binding); bound != nil {
				bound.type = field_type
				bound.index = u32(len(members))
				bound.public = public
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
		// design.md "Record layout attributes": `@(packed)` removes inter-field
		// padding and `@(align=N)` raises the whole record's alignment. Both are
		// read here so the cached layout and the emitter agree.
		info.packed = record_is_packed(value)
		info.written_align = record_written_alignment(k, value)
	}
}

// `(name: Type, ...)`. Every field is named and public by grammar, so all that
// is left is resolving the field types and interning the shape. Interning
// happens here, during checking, so the type exists before
// `c.lifecycle_operations_ready` closes contribution (`src/hooks.odin`).
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
			name_id := identifier_id_of(k.c, name)
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

// design.md "Destructuring": two or more bindings take a record's directly
// declared fields, positionally, by the same eligibility rule wherever the form
// appears (declaration, assignment, `foreach` binding list): exactly as many
// directly declared fields as bindings, all visible here. Promoted (`using`)
// fields are not flattened, and `_` does not bypass visibility.
// Whether this type can be taken apart at all — a non-record on the right of a
// multi-binding form is an arity error, not a destructuring error, so this
// separates "the wrong shape" from "a record that does not fit".
type_is_destructurable :: proc(c: ^Compiler, type: Type_Id) -> bool {
	info := underlying_info(c, type)
	return info != nil && info.kind == .Struct
}

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

// The ownership half of the rule. A place stays live, so every retained managed
// field is cloned out of it; a temporary or `move(...)` transfers instead and
// clones nothing. A record with its own copy or drop hook is rejected rather
// than exempted — that hook would run on a value being taken apart.
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
		from_place = expression_is_borrowed_place(k.c, operand),
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
		resolved := resolve_type_syntax(k, value.backing)
		if resolved == INVALID_TYPE || !type_is_integer(k.c, resolved) {
			errorf(k.c, expr_span(value.backing), "L0380", "an enum's backing type must be an integer type")
		} else {
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
					// `require_const` has already said why.
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

// Normalize one name from a written parameter group. The caller resolves the
// group's type and owns bindings, defaults, effects, and diagnostics. An explicit
// receiver context supplies an omitted receiver type; a split receiver keeps
// its own value mode even when the rest of the group is inout or variadic.
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
		// design.md "Receiver forms": a plain `self` is an immutable *borrow* of
		// the caller's value, not a callee-local copy of it, so it gets its own
		// mode rather than sharing `.Value` with an ordinary parameter. `inout`
		// and `move` receivers already say what they are. A first parameter that
		// is not the subject-typed `self` is an ordinary parameter and keeps
		// `.Value`, which is why both the name and the type are checked here.
		if mode == .Value && type == receiver && len(parameter.names) > 0 &&
		   parameter.names[0].name.text == "self" {
			mode = .Borrow
		}
	}
	// The runtime parameter for `..T` is always the read-only slice `[]T`,
	// including static interface slots and written procedure types.
	if mode == .Variadic && type != INVALID_TYPE {
		type = slice_of(c, type, mutable = false)
	}
	return
}

// design.md's variadic form is one trailing parameter: everything after it
// would be unreachable, and two would make the split ambiguous.
@(private = "file")
variadic_position_ok :: proc(k: ^Checker, literal: ^Expr_Proc, position, name_index: int, span: Span) -> bool {
	last := &literal.signature.params[len(literal.signature.params) - 1]
	if position != len(literal.signature.params) - 1 || name_index != len(last.names) - 1 {
		errorf(k.c, span, "L0574", "a variadic parameter must be the last one")
		return false
	}
	return true
}

// A generic `impl` member whose first parameter is written `self` is a method,
// and method-call syntax has to find it before anything can be instantiated.
// Only the *shape* is recorded; the instantiated signature still checks that
// `self` has the subject type, so a `self` of some other type is rejected then
// rather than silently becoming a receiver here.
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

// `@(allocator_reset)` only means anything on an `Allocator`. A declaration's
// signature and a written `proc` type resolve their parameters separately, so
// both ask here rather than keeping two copies of the rule and its message.
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

	reported := k.c.error_count
	params := make([dynamic]Type_Id, 0, 4, k.c.semantic_allocator)
	modes := make([dynamic]Param_Mode, 0, 4, k.c.semantic_allocator)
	resets_list := make([dynamic]bool, 0, 4, k.c.semantic_allocator)
	escapes_list := make([dynamic]Escape_Level, 0, 4, k.c.semantic_allocator)
	by_ptr_list := make([dynamic]bool, 0, 4, k.c.semantic_allocator)
	param_symbols := make([dynamic]Symbol_Id, 0, 4, k.c.semantic_allocator)
	param_names := make([dynamic]Identifier_Id, 0, 4, context.temp_allocator)
	defaults := make([dynamic]Expr, 0, 4, k.c.semantic_allocator)

	// design.md "Receiver forms", set below by whichever name is the receiver, so
	// the rule is decided once rather than re-derived from the syntax afterwards.
	has_receiver := false
	receiver_mode := Param_Mode.Value
	is_foreign := symbol.is_foreign
	saw_c_vararg := false

	for &parameter, position in literal.signature.params {
		// design.md "`@(c_vararg)`": the final `..any_view` of a foreign
		// declaration is a checker-only C variadic, not a real slice parameter, so
		// it never joins the lowered signature.
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
		// A parameter may *be* an `any_view`, but never hold one nested inside
		// another type.
		if parameter_type != INVALID_TYPE && type_mentions_any_view(k.c, parameter_type, allow_top = true) {
			reject_any_view_position(k, parameter_type, parameter.span, "stored inside another type")
		}
		bindings := make([dynamic]Symbol_Id, 0, len(parameter.names), k.c.semantic_allocator)
		for parameter_name, name_index in parameter.names {
			// Use the written names rather than runtime symbols: a generic instance
			// removes `$` parameters below, but their names still occupy this namespace.
			name_id := identifier_id_of(k.c, parameter_name.name)
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
			// A `$` parameter is a compile-time input: the instantiation consumed
			// its argument and bound the name as a constant, so the instance's
			// runtime signature does not carry it.
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
			// design.md "`@(allocator_reset)`": a successful call can end every
			// allocation root within that allocator's region, so the attribute only
			// makes sense on an `Allocator`.
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
			binding := new_binding_symbol(k, parameter_name.name, .Parameter)
			if bound := symbol_of(k.c, binding); bound != nil {
				bound.type = name_type
				bound.index = u32(len(params))
				bound.mode = mode
				// A value parameter is immutable addressable storage; an `inout` parameter
				// is a mutable alias (design.md "Parameter semantics and ABI lowering").
				// An immutable receiver is a borrow of the caller's storage, and just
				// as unwritable through `self`.
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
	// Parameter/result binding creation may grow the symbol store. Reacquire by
	// ID rather than retaining a pointer across append.
	symbol = symbol_of(k.c, symbol_id)
	symbol.params = params[:]
	symbol.result = result_type
	symbol.result_inout = result_inout
	symbol.param_symbols = param_symbols[:]
	symbol.param_defaults = defaults[:]
	symbol.proc_type = proc_type
	symbol.signature_error = k.c.error_count > reported
	// design.md "Receiver forms": three modes and no others, and a first
	// parameter typed `^T` is deliberately not one of them — it keeps the name
	// but gets no method-call sugar, because `^T` is not the subject type.
	symbol.has_receiver = has_receiver
	symbol.receiver = receiver_mode
	literal.type = proc_type
	literal.symbol = symbol_id
	check_param_defaults(k, literal, symbol_id)
}

// design.md "Default values": a default belongs to the signature, since every
// call that omits the argument binds it. Checked here rather than with the
// body, so a caller checked earlier still sees it resolved — notably
// `caller_location()`, which each call site replaces with a constant for its
// own span and cannot recognise until the default's call is resolved.
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
	// The same context the body is checked in: a default names the procedure it
	// is written on, and `source_location()` in one reports that procedure.
	k.scope = new_scope(k.c, outer_scope, .Procedure)
	k.scope.owner_proc = literal
	k.proc_literal = literal
	k.result_type = symbol.result
	k.result_inout = symbol.result_inout
	for parameter in literal.signature.params {
		if parameter.default != nil {
			// design.md "Default values": a default is resolved in the declaration's
			// lexical scope with only the parameters to its left installed, so a
			// reference to a later parameter is an unknown name rather than a forward
			// peek. It may name `self` and nothing else in the body.
			check_value_expr(k, parameter.default, resolve_type_syntax(k, parameter.type), "pass")
		}
		install_symbols(k.scope, k.c, parameter.symbols)
	}
}

// A written name's interned id, interning it if the parser left that to the
// checker. The duplicate checks above need the id before a symbol exists.
identifier_id_of :: proc(c: ^Compiler, name: Name) -> Identifier_Id {
	return name.id == INVALID_IDENTIFIER ? intern_identifier(c, name.text) : name.id
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

// A layout-independent dependency walk: a value edge into a struct, array, or
// distinct type continues the path, and a pointer edge ends it. Only the
// containment cycle matters here — offsets and alignment stay deferred.
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
		// The repeated type closes the cycle rather than extending it, so it is not
		// pushed onto the walk's shared path: a sibling's own cycle, found after
		// this one returns, would otherwise print this cycle's tail as its prefix.
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
		// A union holds one variant at a time, but by value: a variant that
		// contains the union again has no finite size either.
		for variant in info.variants {
			if !check_finite_size(k, variant, span, path) {
				ok = false
			}
		}
	}
	// The pointer to the info may have been invalidated by types created while
	// resolving; reacquire it.
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
		// A template names no type on its own. Staying silent here keeps
		// `resolve_type_syntax` usable as a probe; `report_unresolved_type` says
		// what is missing at the positions that require a type.
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
		// A qualified type name, `pkg.Point`. Anything else selects out of a
		// value and is not a type, so this stays silent for it.
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
		// `[$N]E` inside an instance: the length is a bound generic constant, not
		// an expression to check.
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
		// Anonymous distinct syntax is still a fresh identity. A named distinct
		// declaration receives its shell in phase 2a.
		if value.denoted_type == INVALID_TYPE {
			before := k.c.error_count
			element := resolve_type_syntax(k, value.elem)
			// The fresh identity resolves whatever the underlying type does not, so an
			// underlying type that failed would otherwise travel inside a valid shell.
			if value.elem != nil && element == INVALID_TYPE && k.c.error_count == before {
				report_unresolved_type(k, value.elem)
			}
			value.denoted_type = new_type(k.c, Type_Info{kind = .Distinct, element = element})
		}
		value.resolution.kind = .Type
		return value.denoted_type

	case ^Type_Record:
		if value.denoted_type == INVALID_TYPE {
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
		params := make([dynamic]Type_Id, 0, len(value.params), k.c.semantic_allocator)
		modes := make([dynamic]Param_Mode, 0, len(value.params), k.c.semantic_allocator)
		resets := make([dynamic]bool, 0, len(value.params), k.c.semantic_allocator)
		escapes := make([dynamic]Escape_Level, 0, len(value.params), k.c.semantic_allocator)
		for parameter, position in value.params {
			// design.md: the reset effect is part of the written procedure type, so
			// a value of this type keeps it through an indirect call.
			marked := has_attribute(parameter.attributes, "allocator_reset")
			count := max(len(parameter.names), 1)
			// A written parameter type that did not resolve is what is wrong with the
			// procedure type. Said once here, ahead of the per-name loop, because the
			// interned type carries the failure silently otherwise.
			before := k.c.error_count
			written := resolve_type_syntax(k, parameter.type)
			if parameter.type != nil && written == INVALID_TYPE &&
			   k.c.error_count == before {
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
		// `dyn Interface(args...)`: the subject parameter is deliberately omitted,
		// so this validates the declaration, the non-subject arguments, and dyn
		// compatibility, and never attempts satisfaction.
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
		// `$E` in a written type is a binding site during inference and a use
		// afterwards: inside an instance the name is bound in the instance scope,
		// so the clone's own syntax resolves to the argument with no rewriting.
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
		// design.md "SIMD vectors": `Simd(T, N)` is a predeclared type
		// constructor, not a generic record, so it is answered before the
		// template lookup that would find nothing.
		if simd_callee(k, value.callee) {
			return resolve_simd_application(k, value)
		}
		// design.md "Ranges": `Range(T)` is predeclared the same way, so a range
		// is spellable wherever a result or field type has to be written.
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
		check_member_decl_in_place(k, member, subject)
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

// M1 parses the whole grammar; the checker compiles a subset, and each
// milestone retired part of the difference. After M7 the difference is empty:
// every construct is compiled or has its own diagnostic, so no call site below
// is reachable from source. M8 closed the last of
// them: `Simd(T, N)` is a real type now rather than a reserved name, so the
// message names a compiler defect rather than a milestone that will never
// arrive for it.
//
// The calls stay as invariant guards, not deleted: each sits on a dispatch arm
// whose union or token set is exhaustively handled above it, so reaching one
// means a parser or resolver invariant broke — better a diagnostic naming the
// span than falling through unchecked.
unsupported_construct :: proc(k: ^Checker, span: Span) {
	errorf(
		k.c,
		span,
		"L0350",
		"this construct parses, but the checker has no rule for it; this is a compiler defect",
	)
}

// One gate per outer semantic unit. A declaration whose type mentions anything
// deferred reports here once, however many fields or parameters are involved.
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
		// Unsupported because a component never resolved is not this diagnostic's
		// answer: whatever rejected that component already said what is wrong with
		// it, and "the checker has no rule for it" names neither.
		if !type_mentions_invalid(k.c, type) {
			unsupported_construct(k, span)
		}
		return false
	}
	// design.md "Maps": the key's coherent `==`/`hash` pair is settled where the
	// map type is named, so one map reports once rather than once per operation.
	if !require_nested_map_key_policies(k, type, span) {
		return false
	}
	// A named region provider gets its constructors and `allocator` here, for the
	// same reason a container gets its operations where its type is named.
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

// Says why a written type did not resolve, once resolution stayed silent about
// it. `resolve_type_syntax` doubles as a probe — `associated_group` asks it
// whether a callee names a type at all — so it reports nothing itself; every
// position that requires a type says so here instead. Otherwise the construct
// is gated as unimplemented, naming the wrong problem and a milestone that
// will never actually fix it.
report_unresolved_type :: proc(k: ^Checker, syntax: Expr) {
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
	// A composed type is unresolved because one of its components is. Recurse
	// into the failed component, so the answer names it rather than the shape
	// written around it. `resolve_type_syntax` is the documented probe: it
	// reports nothing, so asking it twice costs no extra diagnostic.
	component := unresolved_component(k, syntax)
	if component != nil {
		report_unresolved_type(k, component)
		return
	}
	if poly, is_poly := syntax.(^Type_Poly); is_poly {
		errorf(k.c, poly.span, "L0437", "`$%s` is not bound here", poly.name.text)
		return
	}
	// `Name(args)` in type position: a generic application whose head named
	// nothing. The head is what is unknown, so it gets the same answer a bare name
	// would rather than the compiler-defect guard.
	if call, is_call := syntax.(^Expr_Call); is_call {
		if head, head_is_ident := call.callee.(^Expr_Ident); head_is_ident {
			errorf(k.c, head.span, "L0306", "unknown type `%s`", head.name)
			return
		}
	}
	unsupported_construct(k, expr_span(syntax))
}

// The written component of a composed type that did not resolve, or nil when
// the shape itself is what is unaccounted for. An array's length is an
// expression rather than a type and is diagnosed where it is checked.
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
		errorf(k.c, d.span, "L0324", "constant initialisation cycle")
		return
	}
	d.check_state = .Checking
	check_decl_inner(k, d)
	d.check_state = .Checked
	// Static-duration locals need module-level storage and constant initialisers.
	// Settled here rather than inside `check_decl_inner`, which returns from
	// several places that each still declared the storage; `check_state` makes
	// this run once.
	if d.duration != .None && !d.top_level && d.kind == .Var {
		record_static_local(k, d)
	}
}

@(private = "file")
check_decl_inner :: proc(k: ^Checker, d: ^Decl) {
	// A template's body belongs to its instances; there is nothing concrete here
	// to check, and no symbol for the backend to emit.
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
			// An interface declaration is compile-time metadata, so the gate that
			// keeps one out of runtime storage does not apply to it.
			if type_is_interface(k.c, symbol.type) {
				check_interface_declaration(k, d.symbols[0])
				return
			}
			// A nominal type declaration: fields and members are already
			// resolved, so only the gate remains.
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
	// design.md "Allocators": `T via expression` selects the provider this
	// declaration's value is built with. Settled here, before the initialiser,
	// because a container literal initialising this destination constructs with
	// the selected allocator rather than through a default-backed temporary.
	if !check_via_policy(k, d, declared) {
		return
	}
	// A local may hold an `any_view`; a global cannot, and no position may hold
	// one nested inside another type.
	if declared != INVALID_TYPE && type_mentions_any_view(k.c, declared, allow_top = !d.top_level) {
		reject_any_view_position(k, declared, d.span, d.top_level ? "a global" : "stored inside another type")
		return
	}
	// `type` and a reflection descriptor are compile-time only: either may name a
	// constant, never runtime storage.
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
		// design.md "Zero values": only a static-duration declaration with no
		// initialiser manufactures a zero, before the program runs, so only it
		// needs the type to have one. A lexical local starts dead and manufactures
		// nothing. `---` asks for storage without a value and carries `nil` in
		// `d.values`, so it never arrives here either.
		if d.top_level || d.duration != .None {
			require_type_has_zero(k, declared, d.span, "a declaration with static duration")
		}
		assign_symbol_types(k.c, d, declared)
		return
	}
	// `a, b := record;`: one record value filling several names, checked before
	// arity so the single initialiser is not mistaken for a missing one.
	if len(d.values) == 1 && len(d.names) > 1 && d.values[0] != nil {
		check_expr(k, d.values[0])
		// A non-record initialiser is an ordinary arity error, and keeps the
		// existing note that says which operation produces the value it wanted.
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
				}
				return
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

		// `---` is uninitialised storage, not a zero value, and needs a written
		// type to have any shape at all.
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
			check_value_expr_annotated(k, value, declared)
		} else if d.kind == .Const && type_is_untyped(k.c, type) {
			// An untyped constant stays untyped (design.md "Unfixed constants"): it
			// converts at each use to whatever type can represent it, which is
			// how `MAX :: 340282366920938463463374607431768211455` can name a
			// value no default type could hold.
			final = type
		} else {
			// An inferred declaration materialises its initialiser at the
			// untyped value's default type.
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

		// Every compile-time-required context goes through one funnel, so a
		// constant initialiser may call a procedure and still get the same
		// diagnostics as a folded one.
		if d.top_level && d.kind == .Var {
			require_const(k, value, "a file-scope initializer", "L0325")
		}

		bind_literal_allocator(k.c, value, symbol_id)
		if symbol := symbol_of(k.c, symbol_id); symbol != nil {
			symbol.type = final
			if d.kind == .Const {
				folded, evaluated := require_const(k, value, "a constant initialiser", "L0311")
				// The evaluator may declare symbols of its own - an instantiation, a
				// synthesised iterator - and `c.symbols` is a dynamic array, so the
				// pointer taken before the call can be stale after it. Re-fetch it
				// rather than writing the folded value into freed storage.
				if updated := symbol_of(k.c, symbol_id); updated != nil && evaluated {
					updated.const_value = folded
					// A type-valued constant is an alias, and names a type.
					if updated.const_value.kind == .Type {
						updated.type = TYPE_TYPE
					}
				}
			}
		}
	}
}

// The assignability half of `check_value_expr` for an expression already
// checked against its destination.
@(private = "file")
check_value_expr_annotated :: proc(k: ^Checker, value: Expr, declared: Type_Id) {
	if !materialize(k, value, declared) {
		return
	}
	final := expr_base(value).type
	if !assignable(k.c, final, declared) {
		errorf(
			k.c,
			expr_span(value),
			"L0310",
			"cannot initialise `%s` with `%s`",
			type_name(k.c, declared),
			type_name(k.c, final),
		)
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
	// A foreign declaration is bodiless by design and is checked by
	// `check_foreign_block`; reaching here (e.g. a compile-time path forcing the
	// callee's declaration) must not re-gate it.
	if len(d.symbols) == 1 && d.symbols[0] != INVALID_SYMBOL {
		if sym := symbol_of(k.c, d.symbols[0]); sym != nil && sym.is_foreign {
			return
		}
	}
	// `---` isn't a value or an initializer; it's declaration syntax for a
	// foreign procedure with no Loke body (design.md). A foreign block's members
	// returned above, so a bodiless declaration reaching here is outside one — a
	// permanent error rather than an unfinished milestone.
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
	// design.md "where clauses": a bound is a compile-time predicate over an
	// instantiation, so a declaration with no generic parameters in scope cannot
	// have one. An instance's own bounds were evaluated when it was created.
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
	if k.generic_depth > 0 && !literal.generic_instance {
		// A method of an instantiated block: its bounds close over the block's
		// arguments, which are bound in the scope this body is checked in.
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
	outer_loop, outer_switch, outer_defer := k.loop_depth, k.switch_depth, k.in_defer
	defer {
		k.scope = outer_scope
		k.proc_literal = outer_proc
		k.result_type = outer_result
		k.result_inout = outer_result_inout
		k.loop_depth, k.switch_depth, k.in_defer = outer_loop, outer_switch, outer_defer
	}

	k.scope = new_scope(k.c, outer_scope, .Procedure)
	k.scope.owner_proc = literal
	k.proc_literal = literal
	k.result_type = symbol.result
	k.result_inout = symbol.result_inout
	k.loop_depth, k.switch_depth, k.in_defer = 0, 0, false
	outer_slots := k.defer_slots
	k.defer_slots = 0
	defer k.defer_slots = outer_slots

	errors_before := k.c.error_count
	// Defaults were checked with the signature; the body only needs the names.
	for parameter in literal.signature.params {
		install_symbols(k.scope, k.c, parameter.symbols)
	}

	flow := check_block(k, literal.body)
	// design.md "Managed values and storage": ownership is dataflow over the
	// finished body, so it runs once every node has its type and every `defer`
	// has its slot. Implicit drops take the slots that follow.
	analyze_ownership(k, literal)
	// Root and region provenance need every body's result summary settled, so
	// this one only joins the queue the post-checking passes walk.
	append(&k.c.checked_bodies, Checked_Body{literal = literal, clean = k.c.error_count == errors_before})
	literal.defer_count = k.defer_slots
	if symbol.result != INVALID_TYPE && flow.can_fall_through {
		if s := flow.open_enum_exit; s != nil {
			errorf(
				k.c, s.span, "L0365",
				"this switch covers every member of `%s`, but an enum can hold a non-member value, so control can fall past it; add `case:` to return or panic there",
				type_name(k.c, expr_base(s.subject).type),
			)
		} else {
			errorf(k.c, literal.span, "L0365", "this procedure can end without returning a value")
		}
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
	flow := FLOWS
	for stmt in b.stmts {
		result := check_stmt(k, stmt)
		flow.returns ||= result.returns
		flow.breaks ||= result.breaks
		flow.continues ||= result.continues
		flow.can_fall_through = flow.can_fall_through && result.can_fall_through
		// Only the last statement can be the one control falls out of.
		flow.open_enum_exit = result.open_enum_exit
		if !flow.can_fall_through {
			// Statements after a terminator are still checked, but they cannot
			// restore fallthrough.
			continue
		}
	}
	return flow
}

check_scoped_block :: proc(k: ^Checker, b: ^Block) -> Flow_Info {
	outer := k.scope
	k.scope = new_scope(k.c, outer, .Local)
	defer k.scope = outer
	return check_block(k, b)
}

check_stmt :: proc(k: ^Checker, stmt: Stmt) -> Flow_Info {
	switch s in stmt {
	case ^Stmt_Error:
		// Parser diagnostics already describe this retained recovery node.
		return FLOWS

	case ^Decl:
		declare_all(k, s)
		install_symbols(k.scope, k.c, s.symbols)
		// Local declaration symbols do not exist during the package-wide attribute
		// pass, so validate their attributes once they are declared here.
		validate_decl_attributes(k, s)
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
		// A `$` binding makes this a compile-time expansion. Runtime iteration
		// arrives with the iteration protocol in M4b step 4.
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

// A procedure-scope `when` introduces no scope and has no initialiser: the
// selected branch's statements behave as if written in its place — including
// declaring into the surrounding scope and contributing their own flow and
// defer slots.
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
		// design.md "or_return operator": propagating a failure *is* the effect, so
		// a bare `fallible or_return;` is a statement whatever its operand is.
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
				}
				return
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
		if ident, is_ident := target.(^Expr_Ident); is_ident && ident.name == "_" {
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
	// The built-in compound operation wins where it is defined; otherwise a
	// direct `+=` overload, and failing that the binary `+` fallback.
	if !operand_is_builtin(k, type) || !compound_applies(k.c, op, type) {
		if check_user_compound(k, s, op, type) {
			return
		}
	}
	if op == .Shl || op == .Shr {
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

// A compound assignment falls back to the corresponding binary operator plus
// an ordinary assignment; a direct compound overload can skip the temporary
// or allocation that implies (design.md).
@(private = "file")
check_user_compound :: proc(k: ^Checker, s: ^Stmt_Assign, op: Token_Kind, type: Type_Id) -> bool {
	rhs_type := check_single_expr(k, s.rhs[0])
	if rhs_type == INVALID_TYPE {
		return true // already reported; re-checking it would report a second time
	}
	operands := []Type_Id{type, rhs_type}

	// `compound_operator` above already rejected anything but the eleven compound
	// kinds, so this is always their `+=`-style spelling, never "".
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
	if result.result == INVALID_TYPE || !assignable(k.c, result.result, type) && result.result != type {
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
	if ident, is_ident := target.(^Expr_Ident); is_ident && ident.name == "_" {
		ident.type = from
		ident.immutable = .Discard
		ident.value_category = .Invalid
		return from == INVALID_TYPE ? TYPE_VOID : from
	}
	// An assignment destination is a place position, which is what selects an
	// `inout` indexing overload before ordinary ranking.
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
		// The condition may be false, so only assignments already live on entry
		// remain definite after an if without an else.
		return Flow_Info {
			can_fall_through = true,
			returns          = then_flow.returns,
			breaks           = then_flow.breaks,
			continues        = then_flow.continues,
		}
	}
	else_flow := check_stmt(k, s.otherwise)
	switch {
	case then_flow.can_fall_through && else_flow.can_fall_through:
	case then_flow.can_fall_through:
	case else_flow.can_fall_through:
	case:
	}
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
	// A conditional loop may execute zero times. A loop that exits through break
	// likewise has no single body assignment guaranteed on every exit path.

	// `for (;;)` without a `break` never falls out of the loop.
	infinite := s.cond == nil
	return Flow_Info {
		can_fall_through = !infinite || body.breaks,
		returns          = body.returns,
	}
}

@(private = "file")
check_switch :: proc(k: ^Checker, s: ^Stmt_Switch) -> Flow_Info {
	if s.kind == .Type {
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
		return FLOWS
	}
	if type_is_untyped(k.c, subject) {
		materialize(k, s.subject, default_type(k.c, subject))
		subject = expr_base(s.subject).type
	}
	if !type_is_comparable(k.c, subject) {
		errorf(k.c, expr_span(s.subject), "L0355", "`%s` is not comparable", type_name(k.c, subject))
		return FLOWS
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
		k.switch_depth += 1
		case_scope := k.scope
		k.scope = new_scope(k.c, case_scope, .Local)
		case_flow := check_case_body(k, entry.stmts)
		k.scope = case_scope
		k.switch_depth -= 1
		flow.returns ||= case_flow.returns
		flow.continues ||= case_flow.continues
		any_case_falls ||= case_flow.can_fall_through || case_flow.breaks
	}

	member_complete := false
	if !has_default {
		member_complete = check_exhaustive(k, s, subject, covered)
	}
	// Only a default closes a value switch: an open enum admits a value outside
	// its declared members, so covering every one of them still falls through.
	s.exhaustive = has_default
	return Flow_Info {
		can_fall_through = !has_default || any_case_falls || len(s.cases) == 0,
		returns          = flow.returns,
		continues        = flow.continues,
		open_enum_exit   = member_complete && !any_case_falls ? s : nil,
	}
}

check_case_body :: proc(k: ^Checker, stmts: []Stmt) -> Flow_Info {
	flow := FLOWS
	for stmt in stmts {
		result := check_stmt(k, stmt)
		flow.returns ||= result.returns
		flow.breaks ||= result.breaks
		flow.continues ||= result.continues
		flow.can_fall_through = flow.can_fall_through && result.can_fall_through
	}
	return flow
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
		errorf(k.c, s.span, "L0326", "this procedure returns nothing")
		return terminated
	}

	value := s.value
	if !check_value_expr(k, value.expr, k.result_type, "return") {
		return terminated
	}
	classify_return_value(k, value, k.result_type)
	// An `inout` result hands back a place, so what is returned must be one.
	if k.result_inout {
		if base := expr_base(value.expr); base == nil || !base.addressable {
			errorf(k.c, expr_span(value.expr), "L0418", "an `inout` result must return a place")
		}
	}
	return terminated
}

@(private = "file")
check_branch :: proc(k: ^Checker, s: ^Stmt_Branch) -> Flow_Info {
	if s.kind == .Break {
		if k.loop_depth == 0 && k.switch_depth == 0 {
			errorf(k.c, s.span, "L0368", "`break` is only valid inside a loop or a switch")
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

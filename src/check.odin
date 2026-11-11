// Name resolution and type checking for declarations and signatures;
// `check_types.odin` owns type syntax, `check_stmt.odin` statements, and
// `check_expr.odin` everything that produces a value. Annotations are written back onto the AST nodes
// (compiler-architecture.md "One annotated AST").
package lokec

import "core:slice"
import "core:strings"

Checker :: struct {
	c:     ^Compiler,
	// Parts of foreign signatures that named a record still resolving its fields
	// (`check_deferred_foreign_parts`).
	deferred_foreign_parts: [dynamic]Foreign_Part,
	// Likewise, the types under `@(escape=...)` (`check_deferred_escape_parts`).
	deferred_escape_parts: [dynamic]Escape_Part,
	// Likewise, a generic union's designated payload (`check_deferred_union_zeros`).
	deferred_union_zeros: [dynamic]Deferred_Union_Zero,
	using location: Checker_Location,
	// How deep interface composition is, and how many applications the outermost
	// one has entered, so one that composes itself is a failure, not a spin
	// (`step_into_interface`).
	interface_depth: int,
	interface_steps: int,
	// Set by `check_finite_size` when its walk reached a record still resolving
	// its fields, so the answer is not cached.
	size_incomplete: bool,
}

// Where the code being checked sits. An on-demand check saves and restores the
// whole record, so a new field describing location belongs here:
// `saved := k.location; defer k.location = saved`.
Checker_Location :: struct {
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
	// How many generic instantiations enclose the code being checked.
	generic_depth:  int,

	using body: Body_Context,
}

// The procedure body being checked. Entering another body, or a position that
// is in none, replaces the whole record and restores it afterwards, so no field
// is left behind: `outer := k.body; defer k.body = outer`.
Body_Context :: struct {
	// The procedure being checked, and so the frame a name may come from.
	proc_literal:      ^Expr_Proc,
	// design.md "Interface bodies": the `where` clauses whose bare bounds grant
	// what satisfied them to the code being checked when it is a signature, a
	// `where` clause, or a record's fields; set, they replace `proc_literal`'s.
	bounds:            []Expr,
	bounds_set:        bool,
	// The interface application whose requirements are being checked, which
	// reach the associated constants it requires as a bound's body does.
	requiring:         ^Interface_Info,
	requiring_args:    []Generic_Arg,
	// The capture record whose literal is being checked, which alone may
	// initialise its fields (design.md "Capture literals").
	building_capture:  Type_Id,
	// design.md "One result": at most one result. INVALID_TYPE means the
	// procedure has none.
	result_type:       Type_Id,
	// Whether the result was declared `inout`, so `return` must hand out a place.
	result_inout:      bool,
	// Whether the written result names a generic argument of this instance
	// (design.md "Success returns").
	result_generic:    bool,
	// Whether the result's success carries nothing or `Unit` as written, so the
	// body may reach its end or use `return;` (design.md "One result").
	bare_success:      bool,
	// Lexical loop targets for `break` and `continue`, and defer restrictions.
	loop_depth:        int,
	// Runtime loops around a static expansion, which resets `loop_depth`; its
	// body still runs on each of their iterations.
	expanded_in_loops: int,
	// The static expansion being checked has a `break` or `continue` of its
	// own, already reported once on its written body (L0455).
	branches_reported: bool,
	in_defer:          bool,
	// The place whose address a `rawptr(&place)` conversion is taking, which
	// is not an access to a synchronized field on its chain (design.md
	// "@(synchronized)").
	raw_address_place: Expr,
	// `loop_depth` where the current `defer` began: a loop inside it is a
	// target its statement may leave to.
	defer_loop_depth:  int,
	// Checking a loop's header, which no `or_else` exit may leave from.
	loop_header:       bool,
	// An `or_else` exit in the innermost loop's body has broken out of it.
	loop_broken:       bool,
	// One flag slot per syntactic `defer` in the procedure being checked.
	defer_slots:       int,
	// The innermost `parallel` block of this procedure being checked, which a
	// `spawn` joins (design.md "Spawn statements").
	parallel_block:    ^Stmt_Parallel,
	// The statements still to come in the current scope, for
	// `hoist_local_lifecycle_hooks`.
	following:         ^Following_Stmts,
}

// What follows a statement: the rest of its sequence and, in a selected `when`
// branch, which has no scope of its own, the rest of the sequence around it.
Following_Stmts :: struct {
	stmts: []Stmt,
	outer: ^Following_Stmts,
}

// What a statement can do to control flow.
Flow_Info :: struct {
	can_fall_through: bool,
	returns:          bool,
	breaks:           bool,
	continues:        bool,
}

FLOWS :: Flow_Info{can_fall_through = true}

// `next` runs after what `flow` summarizes.
flow_then :: proc(flow: ^Flow_Info, next: Flow_Info) {
	flow.returns ||= next.returns
	flow.breaks ||= next.breaks
	flow.continues ||= next.continues
	flow.can_fall_through = flow.can_fall_through && next.can_fall_through
}

// `other` may run instead of what `flow` summarizes.
flow_either :: proc(flow: ^Flow_Info, other: Flow_Info) {
	flow.returns ||= other.returns
	flow.breaks ||= other.breaks
	flow.continues ||= other.continues
	flow.can_fall_through ||= other.can_fall_through
}

// Scope, declarations, nominal shells, and import aliases, for whatever is
// active so far. Every step guards against repeating itself, so a later
// discovery round only does what a newly selected branch added.
prepare_package :: proc(k: ^Checker, package_id: Package_Id) {
	pkg := package_of(k.c, package_id)
	if pkg == nil {
		return
	}
	k.c.impls_declaring += 1
	defer k.c.impls_declaring -= 1
	if pkg.scope == nil {
		pkg.scope = new_scope(k.c, build_universe(k.c), .Package)
	}
	// First, so a declaration colliding with a contributed name is a redeclaration.
	if !pkg.contributed {
		pkg.contributed = true
		contribute_standard_members(k, pkg)
		bind_intrinsic_declarations(k, pkg)
	}
	k.pkg = package_id
	k.lookup_pkg = package_id
	k.scope = pkg.scope

	for_each_package_item(k, pkg, proc(k: ^Checker, item: Item) {
		#partial switch v in item {
		case ^Decl:
			declare_all(k, v, top_level = true)
		case ^Item_Foreign_Block:
			// Foreign members are ordinary symbols (design.md "Foreign system").
			declare_foreign_block(k, v)
		}
	})
	for_each_package_decl(k, pkg, create_nominal_type_shell)
	// design.md "Typed fallibility": the bootstrap declarations join the universe
	// once `base:runtime`'s names exist, before any other package is prepared.
	bind_runtime_bootstrap(k, pkg)
	// Before `impl` blocks, which may name their subject as `vendor.Vector2`.
	bind_import_aliases(k, pkg)
	// Declaring a block resolves its subject once, and a record's fields may come
	// from a branch not selected yet, as `core:fs`'s `File.handle` does. So a block
	// is declared now only once its subject names nothing a pending `when` may still
	// declare, as a condition asks (`first_unresolved_name`), since design.md "when
	// statement" lets a condition reach the block. A subject package whose closure
	// has no pending `when` is the cheap case of that, and reports a bad subject
	// here. Any block left is declared by `resolve_impl_signatures`.
	pending := make(map[Package_Id]bool, 8, context.temp_allocator)
	for file in pkg.files {
		k.file, k.file_node = file.file, file
		for item in file.active_items {
			impl, ok := item.(^Item_Impl)
			if !ok || impl.declared {
				continue
			}
			subject := impl_subject_package(k, impl)
			waits, asked := pending[subject]
			if !asked {
				waits = package_closure_has_pending_whens(k.c, subject)
				pending[subject] = waits
			}
			if !waits || first_unresolved_name(k, impl.type) == "" {
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
	if _, alias, is_alias := selector_package_alias(k, selector); is_alias {
		return symbol_of(k.c, alias).pkg
	}
	return k.pkg
}

// design.md "Import statement": an import name is a lexical alias for a
// `Package_Id`, nothing more.
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
// runs only once the package's selection and the import graph are stable.
check_package_bodies :: proc(k: ^Checker, package_id: Package_Id) {
	pkg := package_of(k.c, package_id)
	if pkg == nil || pkg.scope == nil {
		return
	}
	k.pkg = package_id
	k.lookup_pkg = package_id
	for file in pkg.files {
		check_doc_comments(k.c, file)
	}

	resolve_package_operators(k, pkg)

	// Fields and callable signatures.
	for_each_package_item(k, pkg, proc(k: ^Checker, item: Item) {
		#partial switch v in item {
		case ^Decl:
			resolve_declaration_signature(k, v)
		case ^Item_Impl:
			resolve_impl_signatures(k, v)
		case ^Item_Foreign_Block:
			check_foreign_block(k, v)
		}
	})

	// design.md "Attributes": after signatures, so a procedure group's symbol
	// kind is known.
	validate_attributes(k, pkg)
	check_test_procedures(k, pkg)
	check_intrinsic_declarations(k, pkg)

	// Every record has its fields now.
	check_deferred_parts(k)

	// Reject a type that contains itself by value, a layout past the maximum, and
	// a union's designated zero with no zero value: each needs every record's
	// fields.
	for_each_package_decl(k, pkg, check_declaration_size)

	// Type checking and constant folding.
	for_each_package_item(k, pkg, proc(k: ^Checker, item: Item) {
		#partial switch v in item {
		case ^Decl:
			check_decl(k, v)
		case ^Item_Impl:
			check_impl_block(k, v)
		case ^Item_Foreign_Import:
			check_foreign_import(k, v)
		case ^Item_Import, ^Item_Foreign_Block, ^Item_Error, ^Item_Static_Assert:
		case:
			unsupported_construct(k, item_span(item))
		}
	})

	// Every inherent hook is validated, so each record's copy decision can be read
	// (design.md "Lifecycle hooks and resource types").
	for_each_package_decl(k, pkg, check_copy_decision)

	// File-scope assertions, after every declaration, so they do not depend on
	// declaration order.
	for_each_package_item(k, pkg, check_file_scope_static_assert)
	// And any a body's own procedure type deferred.
	check_deferred_parts(k)

	// Every symbol has its kind and its constant its type.
	check_private_names(k, package_id)
	// standard-library.md "Printed forms": packages that print are checked after
	// `core:fmt`: their effects and thread transfers ask about the view printing
	// dispatches through, and a `format`'s signature about what the view passes it.
	if pkg.key == STD_FMT {
		for name in ([]string{"Writer", "Options", "Format_View"}) {
			if type, exists := package_type_named(k, pkg, name); exists {
				k.c.runtime_types[name] = type
			}
		}
	}
}

// Each active item of a package, located in its file and the package's scope.
for_each_package_item :: proc(k: ^Checker, pkg: ^Package, visit: proc(k: ^Checker, item: Item)) {
	for file in pkg.files {
		k.file, k.file_node, k.scope = file.file, file, pkg.scope
		for item in file.active_items {
			visit(k, item)
		}
	}
}

// Each active declaration of a package, located in its file.
@(private = "file")
for_each_package_decl :: proc(k: ^Checker, pkg: ^Package, visit: proc(k: ^Checker, d: ^Decl)) {
	for file in pkg.files {
		k.file, k.file_node, k.scope = file.file, file, pkg.scope
		for item in file.active_items {
			if d, ok := item.(^Decl); ok {
				visit(k, d)
			}
		}
	}
}

// The parts of declarations that waited for every record's fields.
@(private = "file")
check_deferred_parts :: proc(k: ^Checker) {
	check_deferred_foreign_parts(k)
	check_deferred_escape_parts(k)
	check_deferred_union_zeros(k)
}

@(private = "file")
check_file_scope_static_assert :: proc(k: ^Checker, any_item: Item) {
	item, is_assert := any_item.(^Item_Static_Assert)
	if !is_assert {
		return
	}
	call, is_call := item.call.(^Expr_Call)
	if !is_call {
		return // the parser already rejected the malformed item shape
	}
	ident, is_ident := call.callee.(^Expr_Ident)
	if !is_ident {
		return // likewise: file-scope syntax admits only the unqualified spelling
	}
	symbol := ident_symbol(k, ident)
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

create_nominal_type_shell :: proc(k: ^Checker, d: ^Decl) {
	// design.md "Structs": only a constant declaration names a type; a variable
	// initialised with a definition is a type used as a value, reported as one.
	if d.kind != .Const || len(d.values) != 1 || len(d.symbols) != 1 || d.symbols[0] == INVALID_SYMBOL {
		return
	}
	symbol := symbol_of(k.c, d.symbols[0])
	if symbol == nil || symbol.kind == .Type {
		return // already given its shell in an earlier round
	}
	kind := Type_Kind.Invalid
	move_only := false
	#partial switch value in d.values[0] {
	case ^Type_Record:
		kind = value.kind == .Struct ? Type_Kind.Struct : Type_Kind.Union
		move_only = value.move_only
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
	symbol.type = new_type(k.c, Type_Info{kind = kind, name = symbol.name, symbol = d.symbols[0], move_only = move_only})
	mark_denotes_type(expr_base(d.values[0]), symbol.type, d.symbols[0])
}

// This node names a type, by way of `symbol` when there is one to say which.
mark_denotes_type :: proc(base: ^Expr_Base, type: Type_Id, symbol: Symbol_Id) -> Type_Id {
	base.denoted_type = type
	base.resolution = Resolution{kind = .Type, symbol = symbol}
	base.value_category = .Type
	return type
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
		errorf(c, NO_SPAN, "L0302", "package `main` has no `main` procedure")
	} else if symbol := symbol_of(c, entry); symbol == nil || symbol.kind != .Proc {
		span := symbol == nil ? NO_SPAN : symbol.span
		errorf(c, span, "L0303", "`main` must be a procedure: `%s`", "main :: proc() { ... }")
	} else if symbol_is_test(symbol) {
		// design.md "Test procedures": only a test build calls one.
		errorf(c, symbol.span, "L0303", "`main` is a test procedure, so only a test build calls it; an executable needs an ordinary `main`")
	} else if info := type_of(c, symbol.proc_type); info == nil || len(info.parameters) != 0 ||
	   (info.result != INVALID_TYPE && info.result != TYPE_I32 && !entry_result_is_fallible(c, info.result)) {
		errorf(
			c, symbol.span, "L0303",
			"`main` takes no parameters and returns nothing, an `i32` status, or a fallible union such as `Status(E)`: `%s`",
			"main :: proc() -> i32 { ... }",
		)
	} else if info.result_inout || convention_is_foreign(info.convention) {
		// The startup wrapper calls an ordinary `loke` procedure for an `i32` value.
		errorf(c, symbol.span, "L0303", "`main` is an ordinary `loke` procedure returning its status by value: `%s`", "main :: proc() -> i32 { ... }")
	} else if c.error_count == errors_before {
		c.entry_point = entry
		request_entry_failure_printing(c, info.result)
	}
}

// design.md "Program entry and exit": a failure is printed by its type.
request_entry_failure_printing :: proc(c: ^Compiler, result: Type_Id) {
	if failure, fallible := entry_failure_type(c, result); fallible {
		request_typeid(c, failure)
		c.format_requested = true
	}
}

// design.md "Program entry and exit": `main` may return a fallible union whose
// success carries nothing, such as `Status(E)` or `Result(Unit, E)`.
entry_result_is_fallible :: proc(c: ^Compiler, result: Type_Id) -> bool {
	_, fallible := entry_failure_type(c, result)
	return fallible
}

// What the startup code prints for a failing `main`: the failure's payload,
// or the whole union when the failure carries none.
entry_failure_type :: proc(c: ^Compiler, result: Type_Id) -> (Type_Id, bool) {
	shape, fallible := fallible_of(c, result)
	if !fallible || (shape.success_type != TYPE_VOID && shape.success_type != c.unit_type) {
		return INVALID_TYPE, false
	}
	return shape.failure_type == TYPE_VOID ? result : shape.failure_type, true
}

// The checks every name gets on its way into `scope` (design.md "Variable
// declarations"), reported. False when it binds nothing: the discard `_`, or a name
// that cannot be declared.
check_new_local :: proc(k: ^Checker, name: Name, scope: ^Scope) -> bool {
	if name.text == "_" || name.text == "" {
		return false
	}
	id := name_identifier(k.c, name)
	if _, declared := scope.names[id]; declared {
		errorf(k.c, name.span, "L0304", "`%s` is already declared in this scope", name.text)
		return false
	}
	if reject_reserved_name(k, id, name.span) {
		return false
	}
	outer, owner := lookup_symbol_with_scope(scope.parent, id)
	// A synthesized name, such as a nested `parallel` block's hidden scope
	// local or a capture record's, which is its literal's text, is out of a
	// source name's reach, so hiding an outer one is harmless.
	synthesized := strings.index_any(name.text, "$(") >= 0
	if outer != INVALID_SYMBOL && (owner.kind == .Local || owner.kind == .Procedure) && !synthesized {
		errorf(k.c, name.span, "L0305", "`%s` shadows an outer declaration", name.text)
		note_shadowed_capture(k, outer)
	}
	return true
}

// Creates the symbols for one declaration, rejecting a shadowed local. Also
// used for a foreign block's members.
declare_all :: proc(k: ^Checker, d: ^Decl, top_level := false) {
	if len(d.symbols) > 0 {
		return // already collected in an earlier phase
	}
	d.top_level = top_level
	public := top_level && declaration_is_public(k, d)
	symbols := make([dynamic]Symbol_Id, 0, len(d.names), k.c.semantic_allocator)
	for name in d.names {
		if !check_new_local(k, name, k.scope) {
			append(&symbols, INVALID_SYMBOL)
			continue
		}

		name_id := name_identifier(k.c, name)
		sym := Symbol {
			name   = name_id,
			span   = name.span,
			decl   = d,
			pkg    = k.pkg,
			public = public,
			// An instantiation resolves names in the declaration's own scope.
			def_scope     = k.scope,
			def_file      = k.file,
			def_file_node = k.file_node,
		}
		switch {
		case decl_proc_literal(d) != nil:
			sym.kind = .Proc
			sym.type = TYPE_VOID
		case d.kind == .Const && decl_is_proc_group(d):
			// A group from the start, as a constant's value may call it before
			// its signature is reached.
			sym.kind = .Proc_Group
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

// Is a signature here one binding of a declaration written for many? Anything
// inside an instantiation, or any member of an `impl` block on a generic record
// instance.
in_generic_signature :: proc(k: ^Checker) -> bool {
	if k.generic_depth > 0 {
		return true
	}
	if k.impl_type == INVALID_TYPE {
		return false
	}
	info := type_of(k.c, k.impl_type)
	return info != nil && info.instance_of != INVALID_SYMBOL
}

// ---------------------------------------------------------- signatures --

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
	saved := k.location
	defer k.location = saved
	enter_symbol_location(k, sym, subject)
	leave_grants(k)
	resolve_declaration_signature(k, sym.decl)
}

// `member` with its signature resolved, for a lookup that goes on to read it.
member_with_signature :: proc(k: ^Checker, member: Symbol_Id, subject := INVALID_TYPE) -> ^Symbol {
	resolve_symbol_signature_in_place(k, member, subject)
	return symbol_of(k.c, member)
}

check_symbol_decl_in_place :: proc(k: ^Checker, symbol_id: Symbol_Id, subject := INVALID_TYPE) {
	sym := symbol_of(k.c, symbol_id)
	if sym == nil || sym.decl == nil {
		return
	}
	saved := k.location
	defer k.location = saved
	enter_symbol_location(k, sym, subject)
	leave_grants(k)
	// A file-scope declaration is in no body, whichever one reached it.
	if sym.decl.top_level {
		k.body = {}
	}
	check_decl(k, sym.decl)
}

// The type a constant names, as an alias does, or INVALID_TYPE. Nothing may have
// checked the constant yet, so this does.
const_type_value :: proc(k: ^Checker, id: Symbol_Id, subject := INVALID_TYPE) -> Type_Id {
	symbol := symbol_of(k.c, id)
	if symbol == nil || symbol.kind != .Const {
		return INVALID_TYPE
	}
	if symbol.decl != nil && symbol.decl.check_state == .Unchecked {
		check_symbol_decl_in_place(k, id, subject)
		symbol = symbol_of(k.c, id)
	}
	return const_names_type(k.c, symbol.const_value, symbol.type) ? symbol.const_value.type_value : INVALID_TYPE
}

// design.md "Interface bodies": another declaration checked on demand has its
// own bounds, not those of the code that reached it. A body's grant is already
// confined to that body's scopes (`granting_bounds`).
@(private = "file")
leave_grants :: proc(k: ^Checker) {
	k.body.bounds, k.body.bounds_set = nil, false
	k.body.requiring, k.body.requiring_args = nil, nil
}

resolve_declaration_signature :: proc(k: ^Checker, d: ^Decl) {
	if d.sig_state != .Unchecked {
		return // resolved, or already on the stack below this call
	}
	d.sig_state = .Checking
	settling := begin_settling(k.c, d)
	defer {
		end_settling(k.c, settling)
		d.sig_state = .Checked
	}
	// A template has no signature of its own: `$T` names nothing until an
	// instantiation binds it. Registration is all this phase does for one.
	if len(d.symbols) == 1 && d.symbols[0] != INVALID_SYMBOL && declaration_generic_kind(d) != .None {
		template := generic_template_for(k, d.symbols[0])
		// Found by method syntax, operator, or hook role before any instance exists.
		mark_template_receiver(k, d)
		mark_template_operator(k, d)
		mark_template_hook(k, d)
		reject_uninstantiated_generic(k, d)
		// design.md "@(require_results)" and "`@(deprecated=<string>)`" bind
		// the declaration: recorded on the template, a call of any instance
		// reads them there (`declaration_of_choice`). A generic type takes
		// its `@(require_results)` per instance (`apply_type_metadata`).
		if template != nil && template.kind == .Procedure {
			apply_proc_metadata(k, d, d.symbols[0])
		}
		if template != nil && template.kind == .Alias {
			check_alias_template(k, d, template)
		}
		return
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
	// Only a constant declaration got a type shell to fill; a variable's
	// definition is a type used as a value, which `check_decl` reports.
	if d.kind != .Const {
		#partial switch _ in d.values[0] {
		case ^Type_Record, ^Type_Enum, ^Type_Distinct, ^Type_Interface:
			return
		}
	}
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
		underlying := resolve_distinct_element(k, value)
		if info := type_of(k.c, symbol.type); info != nil {
			info.element = underlying
		}
		apply_type_metadata(k, d, symbol.type)
	case ^Type_Interface:
		check_interface_declaration(k, d.symbols[0])
	}
}

// Members resolve after declaration collection, including later declarations.
resolve_group_members :: proc(k: ^Checker, group_id: Symbol_Id, value: ^Expr_Proc_Group) {
	members := make([dynamic]Symbol_Id, 0, len(value.names), k.c.semantic_allocator)
	for name in value.names {
		id := name_identifier(k.c, name)
		member := INVALID_SYMBOL
		owner := symbol_of(k.c, group_id)
		if owner != nil && owner.owner_type != INVALID_TYPE {
			member = find_member(k, owner.owner_type, id)
			if member == INVALID_SYMBOL && excluded_member(k, owner.owner_type, id) != nil {
				continue
			}
		} else {
			member = lookup_symbol(k.scope, id)
		}
		if member == INVALID_SYMBOL {
			errorf(k.c, name.span, "L0395", "unknown name `%s` in this procedure group", name.text)
			continue
		}
		if sym := symbol_of(k.c, member); sym != nil && sym.decl != nil && sym.decl.sig_state == .Unchecked {
			resolve_declaration_signature(k, sym.decl)
		}
		sym := symbol_of(k.c, member)
		if sym == nil || sym.kind != .Proc {
			errorf(k.c, name.span, "L0393", "`%s` is not a procedure, so it cannot be a group member", name.text)
			continue
		}
		// A group would make the hook an ordinary callable operation.
		if reject_direct_hook_call(k, name.span, member) {
			continue
		}
		// design.md "Test procedures": nor may a group make a test callable.
		if reject_test_procedure_use(k, sym, name.text, name.span) {
			continue
		}
		if slice.contains(members[:], member) {
			errorf(k.c, name.span, "L0394", "`%s` is already a member of this group", name.text)
			continue
		}
		append(&members, member)
	}
	if group := symbol_of(k.c, group_id); group != nil {
		group.members = members[:]
	}
}

// design.md "Distinct types": a nominal record is declared with `struct`, so
// `distinct` does not give an anonymous record a second way to become one.
resolve_distinct_element :: proc(k: ^Checker, value: ^Type_Distinct) -> Type_Id {
	element := resolve_type_reporting(k, value.elem)
	info := type_of(k.c, element)
	switch {
	case info == nil:
	case info.anonymous_record:
		errorf(
			k.c, value.span, "L0717",
			"`distinct` does not make an anonymous record nominal; declare a `struct` for that",
		)
	case info.anonymous_union:
		// design.md "Anonymous unions": likewise, a nominal union is declared.
		errorf(
			k.c, value.span, "L0717",
			"`distinct` does not make an anonymous union nominal; declare a `union` for that",
		)
	}
	return element
}

resolve_struct_fields :: proc(k: ^Checker, type: Type_Id, value: ^Type_Record) {
	members := make([dynamic]Symbol_Id, 0, len(value.fields), k.c.semantic_allocator)
	// The names `members` holds, so a generated record with hundreds of fields
	// does not search them once per field.
	named := make(map[Identifier_Id]struct{}, len(value.fields), context.temp_allocator)
	for &field in value.fields {
		field_type := resolve_type_reporting(k, field.type)
		// design.md "`type` and `typeid`": a record is runtime storage.
		if offender := compile_time_only_component(k.c, field_type); offender != INVALID_TYPE {
			report_compile_time_only(k, offender, field.span)
		}
		bindings := make([dynamic]Symbol_Id, 0, len(field.names), k.c.semantic_allocator)
		// design.md "Compile-time reflection": fields have visibility too.
		public := field_is_public(k, &field)
		for name in field.names {
			if name.text != "_" && name_identifier(k.c, name) in named {
				errorf(k.c, name.span, "L0304", "`%s` is already a field of this record", name.text)
				append(&bindings, INVALID_SYMBOL)
				continue
			}
			binding := new_binding_symbol(k, name, .Field)
			// grammar.md "Records": `_` is unnamed padding. It keeps its storage
			// under no name, and nothing outside the record sees it.
			padding := name.text == "_"
			if padding {
				binding = new_symbol(k.c, Symbol{span = name.span, kind = .Field, pkg = k.pkg})
			}
			if bound := symbol_of(k.c, binding); bound != nil {
				bound.type = field_type
				bound.index = u32(len(members))
				bound.public = public && !padding
				bound.is_using = field.is_using
				bound.required = has_attribute(field.attributes, "required")
				bound.synchronized = has_attribute(field.attributes, "synchronized")
			}
			append(&bindings, binding)
			if binding != INVALID_SYMBOL {
				append(&members, binding)
				if !padding {
					named[name_identifier(k.c, name)] = {}
				}
			}
		}
		field.symbols = bindings[:]
	}
	if info := type_of(k.c, type); info != nil {
		info.fields = members[:]
		// design.md "Record layout attributes".
		info.packed = has_attribute(value.attributes, "packed")
		// design.md "@(positional)".
		info.positional = has_attribute(value.attributes, "positional")
		info.written_align = record_written_alignment(k, value)
		info.thread_affine = has_attribute(value.attributes, "thread_affine")
		info.wakes_on_drop = has_attribute(value.attributes, "wakes_on_drop")
	}
	resolve_uninitialized_fields(k, type, value)
}

// design.md "Uninitialized capacity": `@(initialized = count)` names the sibling
// `int` field counting a fixed array's live prefix. Only its shape is checked,
// so declaring one is unchecked.
@(private = "file")
resolve_uninitialized_fields :: proc(k: ^Checker, type: Type_Id, value: ^Type_Record) {
	info := type_of(k.c, type)
	if info == nil {
		return
	}
	for &field in value.fields {
		attribute, written := find_attribute(field.attributes, "initialized")
		if !written {
			continue
		}
		_ = require_unsafe_import(k, attribute.span, "trusting an `@(initialized)` count")
		// design.md "Required fields".
		if has_attribute(field.attributes, "required") {
			errorf(k.c, attribute.span, "L0691", "`@(initialized)` storage is left unset by a literal, so it cannot be `@(required)`")
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

// `(name: Type, ...)`, interned while checking so the type exists before
// lifecycle contribution closes (`src/hooks.odin`).
resolve_anon_record :: proc(k: ^Checker, value: ^Type_Anon_Record) -> Type_Id {
	specs := make([dynamic]Anon_Member, 0, len(value.fields), context.temp_allocator)
	names := make([dynamic]Identifier_Id, 0, len(value.fields), context.temp_allocator)
	bad := false
	for &field, index in value.fields {
		field_type := resolve_type_reporting(k, field.type)
		if field_type == INVALID_TYPE {
			// `(a, b)` written for a value is a record type of two types.
			if !bad && len(field.names) == 0 {
				add_notef(k.c, value.span, "parentheses around a comma list describe a record type; a record value is written `{{...}}`")
			}
			bad = true
			continue
		}
		if len(field.names) == 0 {
			append(&specs, Anon_Member{name = positional_field_name(k.c, index), type = field_type})
			continue
		}
		for name in field.names {
			name_id := name_identifier(k.c, name)
			if name.text != "_" && slice.contains(names[:], name_id) {
				errorf(k.c, name.span, "L0304", "`%s` is already a field of this record", name.text)
				continue
			}
			if name.text != "_" {
				append(&names, name_id)
			}
			append(&specs, Anon_Member{name = name_id, type = field_type})
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
	// A padding field fills no binding.
	fields := named_fields(k.c, info)
	if len(fields) != count {
		errorf(
			k.c, span, code,
			"`%s` has %d field%s, so it fills %d binding%s, not %d",
			type_name(k.c, record), len(fields), len(fields) == 1 ? "" : "s",
			len(fields), len(fields) == 1 ? "" : "s", count,
		)
		return nil, false
	}
	for field in fields {
		if !require_visible_field(k, span, record, field, code, action) {
			return nil, false
		}
	}
	if record_order_is_foreign(k, record) {
		errorf(
			k.c, span, "L0708",
			"the fields of `%s` are declared in another package, so they cannot be %s",
			type_name(k.c, record), action,
		)
		add_notef(k.c, span, "bind the whole value and select its fields by name; that package may reorder them")
		return nil, false
	}
	return fields, true
}

// design.md "Destructuring": a nominal record's field order belongs to the
// package that declares its fields, which may reorder them. An anonymous
// record's order is its type identity, and a `@(positional)` one's is public
// (design.md "@(positional)").
record_order_is_foreign :: proc(k: ^Checker, record: Type_Id) -> bool {
	info := underlying_info(k.c, record)
	if info == nil || info.kind != .Struct || info.anonymous_record || info.positional || len(info.fields) == 0 {
		return false
	}
	field := symbol_of(k.c, info.fields[0])
	return field != nil && field.pkg != INVALID_PACKAGE && field.pkg != lookup_package(k)
}

// A place is cloned from; a temporary is taken apart, which a custom copy or
// drop hook forbids.
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
		reject_hooked_destructure(k, record, expr_span(operand))
	}
	return plan
}

// design.md "Destructuring": an owned value whose type has a custom copy or
// drop hook is never taken apart, since its hook would be skipped.
reject_hooked_destructure :: proc(k: ^Checker, record: Type_Id, span: Span) -> bool {
	life := lifecycle_of(k.c, record)
	if life == nil || (life.custom_drop == INVALID_SYMBOL && life.custom_try_clone == INVALID_SYMBOL) {
		return false
	}
	errorf(
		k.c, span, "L0508",
		"`%s` has a custom `hook(copy)` or `hook(drop)`, so it cannot be taken apart by a destructure",
		type_name(k.c, record),
	)
	add_notef(k.c, span, "bind the whole value, or give the type a procedure that decomposes it")
	return true
}

// A receiver-aware signature reads `proc(self, values: ..int)` as an implicit
// receiver followed by a typed parameter. Plain procedure types do not split.
// design.md "Receiver forms": only the receiver `self` may omit its type and
// default, taking the enclosing `impl` type.
parameter_is_bare_self :: proc(parameter: Parameter, position: int) -> bool {
	return position == 0 && parameter.type == nil && parameter.default == nil && len(parameter.names) == 1 &&
		parameter.names[0].name.text == "self"
}

parameter_splits_receiver :: proc(parameter: Parameter, position: int) -> bool {
	return position == 0 && (parameter.type != nil || parameter.default != nil) && len(parameter.names) > 1 &&
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
		if parameter_is_bare_self(parameter, position) || split_receiver { type = receiver }
		if split_receiver { mode = .Value }
		// design.md "Receiver forms": `self: ^Self` is received by address. The
		// body sees the pointer; callers pass the receiver as for any borrowing
		// member, so the address is taken implicitly.
		if mode == .Value && type == pointer_to(c, receiver, false) && len(parameter.names) > 0 &&
		   parameter.names[0].name.text == "self" {
			type, mode = receiver, .Borrow
		}
	}
	// `..T` is received as `[]T`.
	if mode == .Variadic && type != INVALID_TYPE {
		type = slice_of(c, type, mutable = false)
	}
	return
}

@(private = "file")
variadic_position_ok :: proc(k: ^Checker, params: []Parameter, position, name_index: int, span: Span) -> bool {
	last := &params[len(params) - 1]
	if position != len(params) - 1 || name_index != max(len(last.names), 1) - 1 {
		errorf(k.c, span, "L0574", "a variadic parameter must be the last one")
		return false
	}
	return true
}

// One name of a parameter group as the signature receives it, and the
// type-level effects its attributes state.
@(private = "file")
Signature_Parameter :: struct {
	type:           Type_Id,
	mode:           Param_Mode,
	split_receiver: bool,
	escape:         Escape_Level,
	resets:         bool,
	crosses:        bool,
}

// design.md "Variadic parameters": a parameter means the same in a procedure
// type as in a declaration, so both check each name here. The attributes are
// checked against the written type: a `..T` pack's escape level bounds what
// each lent `T` holds, as it does for a `value: T` parameter, not the `[]T`
// the body receives.
check_signature_parameter :: proc(
	k: ^Checker,
	params: []Parameter,
	position, name_index: int,
	written: Type_Id,
	generic, in_foreign: bool,
	receiver := INVALID_TYPE,
) -> (result: Signature_Parameter) {
	parameter := &params[position]
	result.type, result.mode, result.split_receiver = normalize_signature_parameter(
		k.c, parameter^, position, name_index, written, receiver,
	)
	// A split receiver's group type belongs to the names after it.
	written_type := result.split_receiver ? receiver : written
	result.escape = check_escape_attribute(k, parameter.attributes, written_type, parameter.span, result.mode, generic)
	marked := has_attribute(parameter.attributes, "allocator_reset") && !result.split_receiver
	result.resets = allocator_reset_ok(k, marked, written_type, parameter.span)
	result.crosses = check_cross_thread_attribute(
		k, parameter.attributes, written_type, result.mode, result.escape, in_foreign, parameter.span,
	)
	if result.mode == .Variadic && result.type != INVALID_TYPE &&
	   !variadic_position_ok(k, params, position, name_index, parameter.span) {
		result.type, result.mode = written_type, .Value
	}
	return
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
		if _, pointer := first.type.(^Type_Pointer); pointer && first.mode == .Value {
			sym.receiver = .Borrow
		}
	}
}

@(private = "file")
allocator_reset_ok :: proc(k: ^Checker, marked: bool, type: Type_Id, span: Span) -> bool {
	if !marked || type_is_allocator(k.c, type) {
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

// What `resolve_proc_signature` flattens a written parameter list into, one entry
// per parameter name: `proc(a, b: int)` has two. `resolve_proc_type` fills only
// what `append_signature_parameter` appends.
Signature_Builder :: struct {
	params:        [dynamic]Type_Id,
	modes:         [dynamic]Param_Mode,
	resets:        [dynamic]bool,
	escapes:       [dynamic]Escape_Level,
	crosses:       [dynamic]bool,
	by_ptr:        [dynamic]bool,
	param_symbols: [dynamic]Symbol_Id,
	param_names:   [dynamic]Identifier_Id,
	defaults:      [dynamic]Expr,
	has_receiver:  bool,
	receiver_mode: Param_Mode,
	is_foreign:    bool,
}

// The parts of a checked name a procedure type keeps, in a declaration's
// signature and in a procedure type alike.
append_signature_parameter :: proc(builder: ^Signature_Builder, checked: Signature_Parameter) {
	append(&builder.params, checked.type)
	append(&builder.modes, checked.mode)
	append(&builder.resets, checked.resets)
	append(&builder.escapes, checked.escape)
	append(&builder.crosses, checked.crosses)
}

// Builds the flattened signature a call site binds against and interns its
// procedure type.
resolve_proc_signature :: proc(k: ^Checker, literal: ^Expr_Proc, symbol_id: Symbol_Id) {
	symbol := symbol_of(k.c, symbol_id)
	if symbol == nil || literal.signature == nil {
		return
	}
	symbol.kind = .Proc
	symbol.type = TYPE_VOID
	validate_param_attributes(k, literal.signature.params)
	// design.md "Interface bodies": the signature has the grant of its own bounds.
	outer_bounds, outer_set := k.body.bounds, k.body.bounds_set
	k.body.bounds, k.body.bounds_set = literal.where_clauses, true
	defer k.body.bounds, k.body.bounds_set = outer_bounds, outer_set

	reported := k.c.error_count
	// `intern_proc_type` keeps its own copies; the symbol keeps these three.
	builder := Signature_Builder {
		params        = make([dynamic]Type_Id, 0, 4, k.c.semantic_allocator),
		param_symbols = make([dynamic]Symbol_Id, 0, 4, k.c.semantic_allocator),
		defaults      = make([dynamic]Expr, 0, 4, k.c.semantic_allocator),
		modes         = make([dynamic]Param_Mode, 0, 4, context.temp_allocator),
		resets        = make([dynamic]bool, 0, 4, context.temp_allocator),
		escapes       = make([dynamic]Escape_Level, 0, 4, context.temp_allocator),
		crosses       = make([dynamic]bool, 0, 4, context.temp_allocator),
		by_ptr        = make([dynamic]bool, 0, 4, context.temp_allocator),
		param_names   = make([dynamic]Identifier_Id, 0, 4, context.temp_allocator),
		receiver_mode = .Value,
		is_foreign    = symbol.is_foreign,
	}
	saw_c_vararg := false

	for &parameter, position in literal.signature.params {
		// design.md "`@(c_vararg)`": checker-only, never a lowered parameter.
		if has_attribute(parameter.attributes, "c_vararg") {
			check_c_vararg_param(k, builder.is_foreign, literal, position, parameter)
			saw_c_vararg = true
			continue
		}
		if parameter.mode == .Variadic && parameter.type == nil {
			errorf(
				k.c, parameter.span, "L0627",
				"a bare `..` is a C variadic parameter, written `@(c_vararg)` on a foreign procedure; a Loke one names its element type, as in `..T`",
			)
			continue
		}
		append_signature_group(k, &builder, literal, &parameter, position)
	}

	result_type, result_inout := resolve_signature_result(k, literal.signature.result)
	check_signature_convention(
		k, literal.signature.convention, builder.params[:], builder.modes[:], builder.by_ptr[:], result_type, result_inout, literal.span,
	)
	proc_type := intern_proc_type(
		k.c, builder.params[:], builder.modes[:], result_type, result_inout,
		literal.signature.convention, builder.resets[:],
		param_by_ptr = builder.by_ptr[:], c_vararg = saw_c_vararg,
		param_escapes = builder.escapes[:],
		param_cross_thread = builder.crosses[:],
		proc_contract = !builder.is_foreign && literal.body != nil && result_needs_contract(k.c, result_type, result_inout) ? symbol_id : INVALID_SYMBOL,
	)
	// Creating bindings may have grown the symbol store.
	symbol = symbol_of(k.c, symbol_id)
	symbol.params = builder.params[:]
	symbol.result = result_type
	symbol.result_inout = result_inout
	symbol.diverges = literal.signature.result != nil && literal.signature.result.diverges
	symbol.param_symbols = builder.param_symbols[:]
	symbol.param_defaults = builder.defaults[:]
	symbol.proc_type = proc_type
	symbol.signature_error = k.c.error_count > reported
	// design.md "Receiver forms": `self: ^T` is a receiver taken by address;
	// `self: ^mut T` is an ordinary first parameter.
	symbol.has_receiver = builder.has_receiver
	symbol.receiver = builder.receiver_mode
	literal.type = proc_type
	literal.symbol = symbol_id
	check_param_defaults(k, literal, symbol_id)
}

// One written parameter group, its names all of one type but a split receiver.
@(private = "file")
append_signature_group :: proc(k: ^Checker, builder: ^Signature_Builder, literal: ^Expr_Proc, parameter: ^Parameter, position: int) {
	// `@(by_ptr) p: T` lowers to `T const *`; it is foreign-declaration metadata.
	is_by_ptr := has_attribute(parameter.attributes, "by_ptr")
	if is_by_ptr && !builder.is_foreign {
		errorf(k.c, parameter.span, "L0626", "`@(by_ptr)` is only allowed on a foreign procedure parameter")
		is_by_ptr = false
	}
	parameter_type := resolve_type_reporting(k, parameter.type)
	// design.md "Default values": `name := default` takes the default's type. A
	// split receiver is in scope for it, so it is bound first.
	splits := k.impl_type != INVALID_TYPE && parameter_splits_receiver(parameter^, position)
	inferred := parameter.type == nil && parameter.default != nil && !parameter_is_poly(parameter^)
	if inferred && !splits {
		parameter_type = infer_param_default_type(k, literal, position)
	} else if parameter.type == nil && !inferred {
		switch {
		case k.impl_type != INVALID_TYPE && parameter_is_bare_self(parameter^, position):
			parameter_type = k.impl_type
		case parameter_is_poly(parameter^) && parameter.default != nil:
			errorf(k.c, parameter.span, "L0408", "a `$` parameter writes its type, as in `$Name: Type`, even with a default")
		case:
			errorf(k.c, parameter.span, "L0408", "a parameter needs a type or a default; only the receiver `self` may omit both")
		}
	}
	bindings := make([dynamic]Symbol_Id, 0, len(parameter.names), k.c.semantic_allocator)
	for parameter_name, name_index in parameter.names {
		name := parameter_name.name
		// Written names, so a removed `$` parameter still takes its name.
		name_id := name_identifier(k.c, name)
		if name.text != "_" {
			if slice.contains(builder.param_names[:], name_id) {
				errorf(k.c, name.span, "L0304", "`%s` is already a parameter of this procedure", name.text)
			} else {
				append(&builder.param_names, name_id)
			}
		}
		// An instance's `$` parameter is a bound constant, not a runtime one, so
		// it takes no place in `parameter.symbols`: a position in those lists is a
		// runtime parameter's index, which `_` has too, as an invalid symbol.
		if parameter_name.is_poly && literal.generic_instance {
			continue
		}
		checked := check_signature_parameter(
			k, literal.signature.params, position, name_index, parameter_type,
			literal.generic_instance || in_generic_signature(k), in_foreign = builder.is_foreign, receiver = k.impl_type,
		)
		reject_reserved_name(k, name_id, name.span)
		binding := new_binding_symbol(k, name, .Parameter)
		if bound := symbol_of(k.c, binding); bound != nil {
			bound.type = checked.type
			bound.index = u32(len(builder.params))
			bound.mode = checked.mode
			// `self: ^Self` binds the pointer itself, an ordinary value.
			if checked.mode == .Borrow {
				bound.type, bound.mode = pointer_to(k.c, checked.type, false), .Value
			}
			// design.md "Parameter semantics and ABI lowering".
			bound.immutable = bound.mode == .Value
			bound.owner_proc = literal
			bound.allocator_reset = checked.resets
			bound.cross_thread = checked.crosses
			bound.escape = checked.escape
		}
		if position == 0 && name_index == 0 && k.impl_type != INVALID_TYPE && name.text == "self" && checked.type == k.impl_type {
			builder.has_receiver = true
			builder.receiver_mode = checked.mode
		}
		append(&bindings, binding)
		append_signature_parameter(builder, checked)
		append(&builder.by_ptr, is_by_ptr)
		append(&builder.param_symbols, binding)
		// A group's default belongs to its typed names, not a split receiver.
		append(&builder.defaults, checked.split_receiver ? nil : parameter.default)
		if checked.split_receiver && inferred {
			parameter.symbols = bindings[:]
			parameter_type = infer_param_default_type(k, literal, position)
		}
	}
	parameter.symbols = bindings[:]
}

// A signature's written result, whichever kind of signature it is. `-> !`
// returns nothing; the parser rejects it on a procedure type.
resolve_signature_result :: proc(k: ^Checker, result: ^Result) -> (type: Type_Id, inout: bool) {
	if result == nil || result.diverges {
		return INVALID_TYPE, false
	}
	return resolve_type_reporting(k, result.type), result.is_inout
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
	outer_scope, outer_body := k.scope, k.body
	defer k.scope, k.body = outer_scope, outer_body
	// The body's context, so `source_location()` reports this procedure.
	enter_procedure_body(k, literal, symbol_of(k.c, symbol_id))
	for parameter, position in literal.signature.params {
		// A `$` default is checked at its declaration and bound per call
		// (`bind_default_compile_time_argument`), never in an instance's copy.
		// An inferred parameter's default was checked when its type was inferred.
		if parameter.default != nil && !parameter_is_poly(parameter) && parameter.type != nil {
			// Only the receiver and the parameters to its left are in scope.
			if k.impl_type != INVALID_TYPE && parameter_splits_receiver(parameter, position) {
				install_symbols(k.scope, k.c, parameter.symbols[:1])
			}
			check_value_expr(k, parameter.default, resolve_type_syntax(k, parameter.type), "pass")
		}
		install_symbols(k.scope, k.c, parameter.symbols)
	}
}

@(private = "file")
parameter_is_poly :: proc(parameter: Parameter) -> bool {
	for entry in parameter.names {
		if entry.is_poly {
			return true
		}
	}
	return false
}

// design.md "Default values": the default of `name := default` decides the
// parameter's type, seeing only the parameters to its left, as it does when
// `check_param_defaults` checks a written type's default.
@(private = "file")
infer_param_default_type :: proc(k: ^Checker, literal: ^Expr_Proc, position: int) -> Type_Id {
	parameter := literal.signature.params[position]
	outer_scope, outer_body := k.scope, k.body
	defer k.scope, k.body = outer_scope, outer_body
	enter_procedure_body(k, literal)
	for earlier in literal.signature.params[:position] {
		install_symbols(k.scope, k.c, earlier.symbols)
	}
	if k.impl_type != INVALID_TYPE && parameter_splits_receiver(parameter, position) {
		install_symbols(k.scope, k.c, parameter.symbols[:1])
	}
	type := check_single_expr(k, parameter.default, INVALID_TYPE)
	if type == INVALID_TYPE {
		return INVALID_TYPE
	}
	final := inferred_type(k, parameter.default, type)
	if final == INVALID_TYPE {
		return INVALID_TYPE
	}
	materialize(k, parameter.default, final)
	if type_is_compile_time_only(k.c, final) {
		report_compile_time_only(k, final, parameter.span)
		return INVALID_TYPE
	}
	return final
}

new_binding_symbol :: proc(k: ^Checker, name: Name, kind: Symbol_Kind) -> Symbol_Id {
	if name.text == "_" || name.text == "" {
		return INVALID_SYMBOL
	}
	return new_symbol(k.c, Symbol{name = name_identifier(k.c, name), span = name.span, kind = kind, pkg = k.pkg})
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

// The identifier a selector's operand is and the symbol it names, and whether
// that is a package alias, which no check of the operand as a value may reach.
selector_package_alias :: proc(k: ^Checker, sel: ^Expr_Selector) -> (ident: ^Expr_Ident, alias: Symbol_Id, ok: bool) {
	ident, ok = sel.operand.(^Expr_Ident)
	if !ok {
		return nil, INVALID_SYMBOL, false
	}
	alias = lookup_symbol(k.scope, identifier_of(k.c, ident))
	symbol := symbol_of(k.c, alias)
	return ident, alias, symbol != nil && symbol.kind == .Package_Alias
}

identifier_of :: proc(c: ^Compiler, v: ^Expr_Ident) -> Identifier_Id {
	if v.name_id == INVALID_IDENTIFIER {
		v.name_id = intern_identifier(c, v.name)
	}
	return v.name_id
}

// What an identifier names here, or nil.
ident_symbol :: proc(k: ^Checker, ident: ^Expr_Ident) -> ^Symbol {
	return symbol_of(k.c, lookup_symbol(k.scope, identifier_of(k.c, ident)))
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
	settling := begin_settling(k.c, d)
	defer end_settling(k.c, settling)
	mark := len(k.c.diagnostics)
	check_decl_inner(k, d)
	d.check_state = .Checked
	d.check_failed = errors_since(k.c, mark)
	if d.duration != .None && !d.top_level && d.kind == .Var {
		record_static_local(k, d)
	}
}

// Static-duration locals use constant initialization and module storage.
@(private = "file")
record_static_local :: proc(k: ^Checker, d: ^Decl) {
	for symbol_id, index in d.symbols {
		sym := symbol_of(k.c, symbol_id)
		if sym == nil || sym.kind != .Var {
			continue
		}
		// Compile-time evaluation of the initializer already said why it failed.
		if index < len(d.values) && d.values[index] != nil && !is_const_expr(d.values[index]) {
			continue
		}
		if committing(k.c) {
			append(&k.c.static_locals, symbol_id)
		}
	}
}

@(private = "file")
check_decl_inner :: proc(k: ^Checker, d: ^Decl) {
	// design.md "Parametric aliases": one is declared at package scope, where
	// every use can name it.
	if !d.top_level && declaration_generic_kind(d) == .Alias {
		errorf(k.c, d.span, "L0741", "a parametric alias is declared at package scope, not in a procedure")
		return
	}
	only := len(d.symbols) == 1 ? d.symbols[0] : INVALID_SYMBOL
	// A template's body is checked in its instances.
	if only != INVALID_SYMBOL && symbol_is_generic(k, only) {
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
	if symbol := symbol_of(k.c, only); symbol != nil {
		#partial switch symbol.kind {
		case .Type:
			if type_is_interface(k.c, symbol.type) {
				check_interface_declaration(k, only)
			} else {
				gate_type(k, symbol.type, d.span)
			}
			return
		case .Proc_Group:
			return // members were resolved with the signature; a group holds no value
		}
	}
	for symbol_id in d.symbols {
		if sym := symbol_of(k.c, symbol_id); sym != nil {
			sym.duration = d.duration
			sym.synchronized = sym.kind == .Var && has_attribute(d.attributes, "synchronized")
		}
	}

	declared := resolve_type_reporting(k, d.declared_type)
	if declared == INVALID_TYPE && d.declared_type != nil {
		return // the written type did not resolve, and said so
	}
	if declared != INVALID_TYPE {
		if !gate_type(k, declared, d.span) {
			return
		}
		// Reports `L0364` here for storage whose layout is past the maximum.
		type_size(k.c, declared, d.span)
	}
	// design.md "Allocators": before the initialiser, which builds with the
	// selected provider.
	if !check_via_policy(k, d, declared) {
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
		value_mark := len(k.c.diagnostics)
		check_expr(k, d.values[0])
		// An initializer that failed has no type to say how many it fills.
		if !check_decl_destructure(k, d, value_mark) && !errors_since(k.c, value_mark) {
			report_decl_arity(k, d)
			note_optional_replacement(k, d.values[0])
		}
		return
	}
	if len(d.values) != len(d.names) {
		report_decl_arity(k, d)
	}

	for value, i in d.values {
		symbol_id := i < len(d.symbols) ? d.symbols[i] : INVALID_SYMBOL
		// `---`; the parser already requires `x: T = ---`.
		if value == nil {
			check_uninitialized_binding(k, d, declared, symbol_id)
		} else {
			check_decl_value(k, d, value, declared, symbol_id)
		}
	}
}

@(private = "file")
report_decl_arity :: proc(k: ^Checker, d: ^Decl) {
	errorf(
		k.c, d.span, "L0308", "%d name%s but %d initialiser%s",
		len(d.names), len(d.names) == 1 ? "" : "s",
		len(d.values), len(d.values) == 1 ? "" : "s",
	)
}

// `a, b := record`, once the record is checked; false when it is no record.
@(private = "file")
check_decl_destructure :: proc(k: ^Checker, d: ^Decl, value_mark: int) -> bool {
	value := d.values[0]
	type := expr_base(value).type
	if !type_is_destructurable(k.c, type) {
		return false
	}
	// design.md "Destructuring": each binding takes its field's type, so a
	// written type would be ignored.
	if d.declared_type != nil {
		errorf(
			k.c, d.span, "L0308",
			"a destructuring declaration takes each binding's type from its field; write `%s`",
			"a, b := record",
		)
		return true
	}
	if !errors_since(k.c, value_mark) && !require_static_initializer(k, d, value) {
		return true
	}
	retained := make([]bool, len(d.names), k.c.semantic_allocator)
	for symbol_id, index in d.symbols {
		retained[index] = symbol_id != INVALID_SYMBOL
	}
	plan, ok := destructure_plan(k, value, retained, "L0308", "bound by a destructuring declaration")
	if !ok {
		return true
	}
	d.destructure = plan
	for symbol_id, index in d.symbols {
		field := symbol_of(k.c, plan.fields[index])
		if symbol := symbol_of(k.c, symbol_id); symbol != nil && field != nil {
			symbol.type = field.type
		}
	}
	return true
}

// `x: T = ---`.
@(private = "file")
check_uninitialized_binding :: proc(k: ^Checker, d: ^Decl, declared: Type_Id, symbol_id: Symbol_Id) {
	if declared == INVALID_TYPE {
		errorf(k.c, d.span, "L0381", "`---` needs an explicitly written type")
	} else if d.kind == .Const {
		errorf(k.c, d.span, "L0381", "a constant cannot be left uninitialised")
	} else if type_is_managed(k.c, declared) || type_carries_borrow(k.c, declared).any {
		// design.md "Built-in values": unspecified bytes would be read as an
		// owner or a borrow nothing loaned.
		errorf(
			k.c, d.span, "L0381",
			"`%s` %s, so it cannot be left uninitialised with `---`",
			type_name(k.c, declared),
			type_is_managed(k.c, declared) ? "has a lifecycle" : "is or contains a reference",
		)
		add_notef(k.c, d.span, "declare it without an initializer, or give it `%s` or `nil`", "{}")
	} else {
		_ = require_unsafe_import(k, d.span, "leaving a variable uninitialised with `---`")
	}
	if symbol := symbol_of(k.c, symbol_id); symbol != nil {
		symbol.type = declared
	}
}

// One initializer and the name it binds.
@(private = "file")
check_decl_value :: proc(k: ^Checker, d: ^Decl, value: Expr, declared: Type_Id, symbol_id: Symbol_Id) {
	value_mark := len(k.c.diagnostics)
	type := check_single_expr(k, value, declared)
	// An initializer that reported an error may have unresolved nodes, so it
	// is never evaluated; a constant without a value stays invalid.
	evaluable := !errors_since(k.c, value_mark)
	if type == INVALID_TYPE || (d.kind == .Const && !evaluable) {
		if symbol := symbol_of(k.c, symbol_id); symbol != nil {
			symbol.type = declared
		}
		return
	}

	final := declared
	if declared != INVALID_TYPE {
		materialize_value_expr(k, value, declared, "initialise")
	} else if d.kind == .Const && type_is_untyped(k.c, type) {
		// An untyped constant stays untyped (design.md "Unfixed constants").
		final = type
	} else {
		final = inferred_type(k, value, type)
		if final == INVALID_TYPE {
			return
		}
		materialize(k, value, final)
		if type_is_compile_time_only(k.c, final) && d.kind != .Const {
			report_compile_time_only(k, final, d.span)
			return
		}
		if !gate_type(k, final, d.span) {
			return
		}
	}

	if d.kind == .Var && evaluable {
		require_static_initializer(k, d, value)
	}

	bind_literal_allocator(k.c, value, symbol_id)
	if symbol := symbol_of(k.c, symbol_id); symbol != nil {
		symbol.type = final
		if d.kind == .Const {
			folded, evaluated := require_const(k, value, "a constant initialiser", "L0311")
			if evaluated {
				symbol.const_value = folded
				// A type-valued constant is an alias, and names a type.
				if const_names_type(k.c, symbol.const_value, final) {
					symbol.type = TYPE_TYPE
				}
			}
		}
	}
}

// The destructure of a checked record `value`: its fields, which of them are
// `retained`, and whether it clones them or takes the value apart.
destructure_plan :: proc(k: ^Checker, value: Expr, retained: []bool, code, action: string) -> (Destructure, bool) {
	record := expr_base(value).type
	fields, ok := destructure_fields(k, record, len(retained), expr_span(value), code, action)
	if !ok {
		return {}, false
	}
	return plan_destructure(k, value, record, fields, retained), true
}

// design.md "Allocators": `T via expression` records the declaration's allocator
// policy on its symbols. It selects for revival, copies in, and literals built
// here; a live destination keeps the allocator its value was built with.
@(private = "file")
check_via_policy :: proc(k: ^Checker, d: ^Decl, declared: Type_Id) -> bool {
	if d.via == nil {
		return true
	}
	// Static storage cannot run the allocator expression.
	if d.top_level || d.duration != .None {
		errorf(
			k.c,
			expr_span(d.via),
			"L0576",
			"`via` selects a provider by running an expression, which %s cannot do; it starts allocator-unbound and binds on first use",
			storage_phrase(d.duration),
		)
		return false
	}
	if declared == INVALID_TYPE {
		return false // the written type already said why
	}
	// design.md "Shared ownership": the control block stores the allocator.
	if type_is_shared_handle(k.c, declared) {
		errorf(
			k.c,
			expr_span(d.via),
			"L0671",
			"`%s` stores its allocator in the control block, so a declaration cannot select one with `via`",
			type_name(k.c, declared),
		)
		add_notef(
			k.c,
			NO_SPAN,
			"select it where the value is made: `shared(value, allocator=...)` or `try_shared(value, allocator)`",
		)
		return false
	}
	if !type_accepts_via(k.c, declared) {
		errorf(
			k.c,
			expr_span(d.via),
			"L0577",
			"`via` selects the provider a value is built with, and `%s` has no destination allocation to select",
			type_name(k.c, declared),
		)
		add_notef(
			k.c,
			NO_SPAN,
			"`via` applies to a managed owner whose storage is allocated as it grows, such as `[dynamic]T`, `map[K]V`, or a record with a `try_clone`",
		)
		return false
	}
	if !check_allocator_argument(k, d.via, "L0578", "a `via` policy names an `Allocator`") {
		return false
	}
	// A copy into this destination clones.
	contribute_lifecycle_members(k, declared)
	for symbol_id in d.symbols {
		if sym := symbol_of(k.c, symbol_id); sym != nil {
			sym.via = d.via
		}
	}
	return true
}

// A trivial or borrowed value owns no allocation; a move-only value has no
// clone to pass an allocator to; an immutable `string` shares storage through
// a retain rather than allocating into a destination.
@(private = "file")
type_accepts_via :: proc(c: ^Compiler, type: Type_Id) -> bool {
	return type_is_managed(c, type) && !type_clone_disabled(c, type) && underlying_kind(c, type) != .String
}

// design.md "Storage modifiers": a file-scope variable, and a local `static` or
// `thread_local`, is initialised before code runs, so its initializer is a
// constant. The codes are `require_const`'s fallback, unpinned by design.
@(private = "file")
require_static_initializer :: proc(k: ^Checker, d: ^Decl, value: Expr) -> bool {
	what: string
	switch {
	case d.top_level:              what = "a file-scope initializer"
	case d.duration == .Static:    what = "a `static` initializer"
	case d.duration == .Thread_Local: what = "a `thread_local` initializer"
	case:                          return true
	}
	_, evaluated := require_const(k, value, what, d.top_level ? "L0325" : "L0506")
	return evaluated
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
	// Checked by `check_foreign_block`.
	if len(d.symbols) == 1 {
		if sym := symbol_of(k.c, d.symbols[0]); sym != nil && sym.is_foreign {
			return
		}
	}
	if !proc_shape_ok(k, literal, is_value = false) {
		return
	}
	symbol := symbol_of(k.c, literal.symbol)
	if symbol == nil {
		return
	}
	if symbol.bound_excluded || symbol.superseded {
		// Its `where` bound excluded it from this instantiation, or a more
		// specialized block replaced it.
		return
	}
	if k.generic_depth > 0 && !literal.generic_instance {
		// A method of an instantiated block.
		if !check_where_clauses(k, literal.where_clauses, literal.span, identifier_text(k.c, symbol.name), true) {
			return
		}
	}
	if (!symbol.signature_error && compile_time_only_procedure(k.c, symbol)) || runtime_signature_ok(k, symbol, literal.span) {
		check_proc_body(k, literal)
	}
}

// Checks before the signature is resolved, for a declaration and a literal.
proc_shape_ok :: proc(k: ^Checker, literal: ^Expr_Proc, is_value: bool) -> bool {
	if literal.bodiless {
		errorf(
			k.c, literal.span, "L0630",
			"only a foreign declaration ends with `---`; %s needs a body",
			is_value ? "a procedure value" : "a procedure declared here",
		)
		return false
	}
	if literal.signature == nil {
		unsupported_construct(k, literal.span)
		return false
	}
	// design.md "Generics": a generic procedure has no runtime value.
	if is_value && proc_signature_is_generic(literal) {
		errorf(
			k.c, literal.span, "L0431",
			"a procedure literal is a value, and a generic procedure is not one; declare it with `::` and call it",
		)
		return false
	}
	// design.md "where clauses": only with generic parameters in scope, which a
	// literal never has of its own.
	if len(literal.where_clauses) > 0 && (is_value || (!literal.generic_instance && k.generic_depth == 0)) {
		message := "a `where` clause needs a generic parameter in scope; use `if` or `assert` for a runtime precondition"
		if is_value {
			message = "a procedure literal has no generic parameters, so it cannot have a `where` clause; bound the enclosing declaration"
		}
		errorf(k.c, expr_span(literal.where_clauses[0]), "L0433", "%s", message)
		return false
	}
	return true
}

// design.md "`type` and `typeid`": a procedure that computes a `type` or a
// reflection descriptor is compile-time-only. Every call is evaluated by the
// compiler, so it is never emitted and cannot be a procedure value; its
// parameters still bind runtime values, so none of them may be compile-time-only.
compile_time_only_procedure :: proc(c: ^Compiler, symbol: ^Symbol) -> bool {
	if symbol.result == INVALID_TYPE || compile_time_only_component(c, symbol.result) == INVALID_TYPE {
		return false
	}
	for parameter in symbol.params {
		if compile_time_only_component(c, parameter) != INVALID_TYPE {
			return false
		}
	}
	return true
}

// Whether the signature can be a runtime procedure value.
runtime_signature_ok :: proc(k: ^Checker, symbol: ^Symbol, span: Span) -> bool {
	if symbol.signature_error {
		return false // resolving the signature already said what is wrong with it
	}
	// `type` is a supported shape for `$` parameters, but never a runtime one.
	if offender := compile_time_only_component(k.c, symbol.proc_type); offender != INVALID_TYPE {
		report_compile_time_only(k, offender, span)
		return false
	}
	return gate_type(k, symbol.proc_type, span)
}

check_proc_body :: proc(k: ^Checker, literal: ^Expr_Proc) {
	symbol := symbol_of(k.c, literal.symbol)
	if symbol == nil {
		return
	}
	outer_scope, outer_body := k.scope, k.body
	defer k.scope, k.body = outer_scope, outer_body

	enter_procedure_body(k, literal, symbol)
	if result := literal.signature.result; result != nil {
		k.body.result_generic = type_syntax_names_generic(k, outer_scope, result.type)
	}
	k.body.bare_success = success_needs_no_value(k, outer_scope, literal, symbol)

	errors_before := k.c.error_count
	held := len(k.c.held_copy_reports)
	// Defaults were checked with the signature; the body only needs the names.
	for parameter in literal.signature.params {
		install_symbols(k.scope, k.c, parameter.symbols)
	}

	flow := check_block(k, literal.body)
	if flow.can_fall_through && implicit_success(k, literal, symbol) {
		flow.can_fall_through = false
	}
	// design.md "Managed values and storage": dataflow over the finished body.
	analyze_ownership(k, literal, held)
	// Provenance runs later, once every body's summary is settled. A probe's body
	// is not part of the program, as its literal is not hoisted.
	if committing(k.c) {
		append(&k.c.checked_bodies, Checked_Body{literal = literal, clean = k.c.error_count == errors_before})
		k.c.checked_body_symbols[literal.symbol] = true
	}
	literal.defer_count = k.defer_slots
	if symbol.result != INVALID_TYPE && flow.can_fall_through {
		errorf(k.c, literal.span, "L0365", "this procedure can end without returning a value")
	}
	if symbol.diverges && flow.can_fall_through {
		errorf(k.c, literal.span, "L0710", "this procedure is declared `-> !` but can reach its end")
	}
}

// A procedure body's context inside the current scope: a scope the literal owns
// and a fresh `k.body`, with the result `symbol` declares when it is known. The
// caller saves and restores `k.scope` and `k.body`.
@(private = "file")
enter_procedure_body :: proc(k: ^Checker, literal: ^Expr_Proc, symbol: ^Symbol = nil) {
	k.scope = new_scope(k.c, k.scope, .Procedure)
	k.scope.owner_proc = literal
	k.body = {proc_literal = literal}
	if symbol != nil {
		k.body.result_type, k.body.result_inout = symbol.result, symbol.result_inout
	}
}

install_symbols :: proc(scope: ^Scope, c: ^Compiler, symbols: []Symbol_Id) {
	for id in symbols {
		if symbol := symbol_of(c, id); symbol != nil && symbol.name != INVALID_IDENTIFIER {
			scope.names[symbol.name] = id
		}
	}
}

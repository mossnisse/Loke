// Source selection: file-scope selection, and the condition rule both scopes
// share.
//
// design.md "when statement": an unselected branch is parsed and nothing else.
//
// Checking annotates the parser's AST in place rather than building a second
// tree, so the selected view must persist: `File.active_items` is rebuilt
// after each activation by flattening every selected branch at its
// surrounding position, and every semantic consumer iterates that.
package lokec

import "core:slice"

// Parser-owned item lists are never mutated. Every round of the activation fixed
// point calls this, so an unchanged view keeps its array rather than
// arena-allocating a copy.
rebuild_active_items :: proc(c: ^Compiler, pkg: ^Package) {
	for file in pkg.files {
		out := make([dynamic]Item, 0, len(file.items), context.temp_allocator)
		for item in file.items {
			flatten_item(item, &out)
		}
		if slice.equal(file.active_items, out[:]) {
			continue
		}
		file.active_items = slice.clone(out[:], c.semantic_allocator)
	}
	note_pending_whens(c, pkg)
}

@(private = "file")
flatten_item :: proc(item: Item, out: ^[dynamic]Item) {
	#partial switch v in item {
	case ^Item_Block:
		// A top-level block groups items; it introduces no scope, so its members
		// take its place in source order.
		for sub in v.items {
			flatten_item(sub, out)
		}
		return
	case ^Item_When:
		if selected := item_when_selected(v); selected != nil {
			flatten_item(selected, out)
		}
		return
	case ^Decl:
		// design.md "`@(intrinsic)`": a description of what the compiler supplies,
		// which `src/intrinsic.odin` binds; no other pass declares or checks it.
		if decl_is_intrinsic(v) {
			return
		}
	case ^Item_Impl:
		if impl_is_intrinsic(v) {
			return
		}
	}
	append(out, item)
}

// The branch this file-scope `when` selected, or nil: the counterpart of
// `Stmt_When.selected`.
item_when_selected :: proc(v: ^Item_When) -> Item {
	#partial switch v.state {
	case .Taken:
		return v.then
	case .Not_Taken:
		return v.otherwise
	}
	return nil
}

// Every file-scope `when` under `item` that is reachable -- at top level, inside
// an active block, or inside a selected branch -- and has not settled yet.
@(private = "file")
collect_pending_whens :: proc(item: Item, out: ^[dynamic]^Item_When) {
	#partial switch v in item {
	case ^Item_Block:
		for sub in v.items {
			collect_pending_whens(sub, out)
		}
	case ^Item_When:
		if v.state == .Pending {
			append(out, v)
		} else {
			collect_pending_whens(item_when_selected(v), out)
		}
	}
}

// Rebuilt only between rounds: a round reads the names its predecessor left, which
// still cover whatever this round selects until `prepare_package` declares it.
@(private = "file")
note_pending_whens :: proc(c: ^Compiler, pkg: ^Package) {
	pending := make([dynamic]^Item_When, 0, 4, context.temp_allocator)
	for file in pkg.files {
		for item in file.items {
			collect_pending_whens(item, &pending)
		}
	}
	pkg.has_pending_whens = len(pending) > 0
	pkg.pending_when_names = nil
	if pkg.has_pending_whens {
		pkg.pending_when_names = make(map[Identifier_Id]bool, c.semantic_allocator)
		for item in pending {
			note_branch_names(c, item, &pkg.pending_when_names)
		}
	}
}

// Every name selecting something under `item` could bring into the package scope.
@(private = "file")
note_branch_names :: proc(c: ^Compiler, item: Item, names: ^map[Identifier_Id]bool) {
	#partial switch v in item {
	case ^Decl:
		for name in v.names {
			names[intern_identifier(c, name.text)] = true
		}
	case ^Item_Import:
		names[intern_identifier(c, import_binding_name(v))] = true
	case ^Item_Foreign_Block:
		for member in v.members {
			note_branch_names(c, member, names)
		}
	case ^Item_Block:
		for sub in v.items {
			note_branch_names(c, sub, names)
		}
	case ^Item_When:
		note_branch_names(c, v.then, names)
		note_branch_names(c, v.otherwise, names)
	}
}

// Whether a `when` of the package being walked may yet declare this name.
@(private = "file")
when_branch_may_declare :: proc(k: ^Checker, name: Identifier_Id) -> bool {
	return name in package_of(k.c, k.pkg).pending_when_names
}

// Whether any file-scope `when` is still pending in this package or in anything
// it imports. Resolving a record resolves its fields, and a field type is named
// in the record's own package through the record's own imports -- so whether a
// declaration there has stopped changing shape is not a question one package
// answers alone.
package_closure_has_pending_whens :: proc(c: ^Compiler, id: Package_Id) -> bool {
	seen := make([]bool, len(c.packages), context.temp_allocator)
	return closure_has_pending_whens(c, id, seen)
}

@(private = "file")
closure_has_pending_whens :: proc(c: ^Compiler, id: Package_Id, seen: []bool) -> bool {
	if id == INVALID_PACKAGE || seen[id] {
		return false
	}
	seen[id] = true
	pkg := package_of(c, id)
	if pkg.has_pending_whens {
		return true
	}
	for edge in pkg.imports {
		if closure_has_pending_whens(c, edge.target, seen) {
			return true
		}
	}
	return false
}

// Calls `visit` on each pending `when` of the package, from its own location, and
// reports whether any call returned true.
@(private = "file")
visit_pending_whens :: proc(k: ^Checker, pkg: ^Package, visit: proc(k: ^Checker, item: ^Item_When) -> bool) -> bool {
	saved := k.location
	defer k.location = saved
	k.scope, k.pkg, k.lookup_pkg = pkg.scope, pkg.id, pkg.id

	progressed := false
	for file in pkg.files {
		pending := make([dynamic]^Item_When, 0, 4, context.temp_allocator)
		for item in file.items {
			collect_pending_whens(item, &pending)
		}
		k.file, k.file_node = file.file, file
		for item in pending {
			progressed |= visit(k, item)
		}
	}
	return progressed
}

// One activation round. Returns true when a `when` settled, which is what makes
// the surrounding fixed point terminate.
activate_when_items :: proc(k: ^Checker, pkg: ^Package) -> bool {
	k.c.impls_declaring += 1
	defer k.c.impls_declaring -= 1
	return visit_pending_whens(k, pkg, resolve_item_when)
}

@(private = "file")
resolve_item_when :: proc(k: ^Checker, item: ^Item_When) -> bool {
	// A condition waiting on a declaration another branch may still supply is
	// pending, not wrong; it is only an error once no round can add anything.
	if first_unresolved_name(k, item.cond) != "" {
		return false
	}
	value, ok := check_when_condition(k, item.cond)
	if !ok {
		// Rejected: settles as stalled, as `check_when_stmt` does; `false` would
		// check the `else` on a refused condition.
		item.state = .Stalled
		return true
	}
	item.state = value ? .Taken : .Not_Taken
	return true
}

// Everything still pending once no round can make progress. Naming the
// dependency distinguishes a condition waiting on discovery from a typo.
report_stalled_whens :: proc(k: ^Checker, pkg: ^Package) {
	visit_pending_whens(k, pkg, report_stalled_when)
	pkg.has_pending_whens = false
	pkg.pending_when_names = nil
}

@(private = "file")
report_stalled_when :: proc(k: ^Checker, item: ^Item_When) -> bool {
	item.state = .Stalled
	missing := first_unresolved_name(k, item.cond)
	// A condition that could only be answered by an import inside its own
	// branch can never be answered: selecting the branch is what would supply
	// the name, and the name is what selects the branch.
	if bootstrap := find_import_binding(item, missing); bootstrap != nil {
		errorf(
			k.c,
			expr_span(item.cond),
			"L0337",
			"this `when` condition needs `%s`, which only its own branch imports",
			missing,
		)
		add_notef(k.c, bootstrap.span, "imported here, inside the branch this condition selects")
	} else if lookup_symbol(k.scope, intern_identifier(k.c, missing)) != INVALID_SYMBOL {
		errorf(k.c, expr_span(item.cond), "L0389", "`%s` is predeclared, but a `when` branch may declare it, so this `when` condition cannot be answered", missing)
	} else {
		errorf(k.c, expr_span(item.cond), "L0389", "`%s` is not declared, so this `when` condition cannot be answered", missing)
	}
	return false
}

@(private = "file")
find_import_binding :: proc(item: Item, name: string) -> ^Item_Import {
	#partial switch v in item {
	case ^Item_Import:
		if import_binding_name(v) == name {
			return v
		}
	case ^Item_Block:
		for entry in v.items {
			if found := find_import_binding(entry, name); found != nil {
				return found
			}
		}
	case ^Item_When:
		if found := find_import_binding(v.then, name); found != nil {
			return found
		}
		return find_import_binding(v.otherwise, name)
	}
	return nil
}

// The shared condition rule for both scopes: `bool`, and a compile-time
// constant.
check_when_condition :: proc(k: ^Checker, cond: Expr) -> (bool, bool) {
	type := check_single_expr(k, cond, TYPE_BOOL)
	if type == INVALID_TYPE {
		return false, false
	}
	// Asked before materialising: converting first would report an unrelated
	// representability failure on the way to the real complaint.
	if !type_is_boolean(k.c, type) {
		errorf(k.c, expr_span(cond), "L0389", "a `when` condition must be `bool`, found `%s`", type_name(k.c, type))
		return false, false
	}
	materialize(k, cond, TYPE_BOOL)
	folded, evaluated := require_const(k, cond, "a `when` condition", "L0389")
	if !evaluated || folded.kind != .Boolean {
		return false, false
	}
	return folded.boolean, true
}

// Does this callee name the given built-in? Used where an argument is a token
// rather than a lexical value, which only the built-in's identity can say.
@(private = "file")
callee_is_builtin :: proc(k: ^Checker, callee: Expr, kind: Builtin_Kind) -> bool {
	ident, is_ident := callee.(^Expr_Ident)
	if !is_ident {
		return false
	}
	sym := ident_symbol(k, ident)
	return sym != nil && sym.kind == .Builtin && sym.builtin == kind
}

// One condition's walk through what it reads.
@(private = "file")
When_Walk :: struct {
	k:         ^Checker,
	// Past the condition's own text, where a name that resolves nowhere and that
	// no branch may declare is left for the check to report.
	following: bool,
	seen:      map[Symbol_Id]bool,
	// What the reached declarations bind for themselves: parameters and locals.
	bound:     [dynamic]string,
	// The answer of the child that ended a walk of `expr_children`.
	missing:   string,
}

// The first name `e` depends on that is not settled, or "" when all are. Only
// value positions are visited: a selector's field and a record literal's field
// key are tokens, not lookups.
//
// Type syntax counts: `size_of(^T)` depends on `T` as `size_of(T)` does. So does
// what a name declares, a called procedure's body included, since evaluating the
// condition reads it (design.md "when statement"). A name is settled once it is in
// its package's scope, or else, for a predeclared name, once no branch may shadow it.
first_unresolved_name :: proc(k: ^Checker, e: Expr) -> string {
	w := When_Walk {
		k     = k,
		seen  = make(map[Symbol_Id]bool, context.temp_allocator),
		bound = make([dynamic]string, context.temp_allocator),
	}
	return unresolved_in(&w, e)
}

@(private = "file")
unresolved_in :: proc(w: ^When_Walk, exprs: ..Expr) -> string {
	for e in exprs {
		if missing := unresolved_name(w, e); missing != "" {
			return missing
		}
	}
	return ""
}

@(private = "file")
unresolved_name :: proc(w: ^When_Walk, e: Expr) -> string {
	k := w.k
	#partial switch v in e {
	case ^Type_Proc:
		return unresolved_in_signature(w, v)
	case ^Expr_Composite:
		if missing := unresolved_in(w, v.type_expr, v.via); missing != "" {
			return missing
		}
		keys_are_values := composite_keys_are_values(w, v)
		for element in v.elements {
			if keys_are_values || !key_names_field(v, element.key) {
				if missing := unresolved_name(w, element.key); missing != "" {
					return missing
				}
			}
			if missing := unresolved_name(w, element.value); missing != "" {
				return missing
			}
		}
		return ""
	case ^Expr_Ident:
		if slice.contains(w.bound[:], v.name) {
			return ""
		}
		name := identifier_of(k.c, v)
		symbol, found_in := lookup_symbol_with_scope(k.scope, name)
		if found_in != nil && found_in.kind != .Universe {
			return found_in.kind == .Package ? unresolved_in_symbol(w, symbol) : ""
		}
		if when_branch_may_declare(k, name) || (symbol == INVALID_SYMBOL && !w.following) {
			return v.name
		}
	case ^Expr_Selector:
		if ident, alias, is_alias := selector_package_alias(k, v); is_alias {
			return unresolved_in_package(w, package_of(k.c, symbol_of(k.c, alias).pkg), ident, v)
		}
	case ^Expr_Call:
		if missing := unresolved_name(w, v.callee); missing != "" {
			// `Simd`, `Range`, and `Box` are predeclared type constructors recognized
			// by name, with no universe binding to find (design.md "Predeclared names").
			predeclared := simd_callee(k, v.callee) || range_callee(k, v.callee) || box_type_callee(k, v.callee)
			if !predeclared || when_branch_may_declare(k, intern_identifier(k.c, missing)) {
				return missing
			}
		}
		// `build_config(NAME, default)` names a configuration key and
		// `offset_of(T, field)` a field of `T`, neither of them a binding.
		skip := -1
		if callee_is_builtin(k, v.callee, .Build_Config) {
			skip = 0
		} else if callee_is_builtin(k, v.callee, .Offset_Of) {
			skip = 1
		}
		for argument, index in v.args {
			if index == skip {
				continue
			}
			if missing := unresolved_name(w, argument.value); missing != "" {
				return missing
			}
		}
		return ""
	case ^Type_Poly:
		append(&w.bound, v.name.text)
	case ^Expr_Proc, ^Type_Record, ^Type_Enum, ^Type_Interface:
		return unresolved_in_own_scope(w, e)
	}
	found := expr_children(e, w, proc(data: rawptr, child: Expr) -> bool {
		w := (^When_Walk)(data)
		w.missing = unresolved_name(w, child)
		return w.missing != ""
	})
	return w.missing if found else ""
}

// `name` selected from an imported package.
@(private = "file")
unresolved_in_package :: proc(w: ^When_Walk, target: ^Package, ident: ^Expr_Ident, v: ^Expr_Selector) -> string {
	k := w.k
	name := intern_identifier(k.c, v.name.text)
	if target != nil && target.scope != nil {
		if symbol, found := target.scope.names[name]; found {
			return unresolved_in_symbol(w, symbol)
		}
		if w.following && name not_in target.pending_when_names {
			return ""
		}
	}
	return concat(k.c, ident.name, ".", v.name.text)
}

// What a package-scope name declares, read where it was declared.
@(private = "file")
unresolved_in_symbol :: proc(w: ^When_Walk, id: Symbol_Id) -> string {
	k := w.k
	symbol := symbol_of(k.c, id)
	if symbol == nil || symbol.decl == nil || id in w.seen {
		return ""
	}
	w.seen[id] = true
	saved, following := k.location, w.following
	defer {
		k.location = saved
		w.following = following
	}
	enter_symbol_location(k, symbol)
	w.following = true
	return unresolved_in_stmt(w, symbol.decl)
}

// A form that binds names of its own, which end with it.
@(private = "file")
unresolved_in_own_scope :: proc(w: ^When_Walk, e: Expr) -> string {
	following, bound := w.following, len(w.bound)
	defer {
		w.following = following
		resize(&w.bound, bound)
	}
	w.following = true
	#partial switch v in e {
	case ^Expr_Proc:
		if missing := unresolved_in_signature(w, v.signature); missing != "" {
			return missing
		}
		if missing := unresolved_in(w, ..v.where_clauses); missing != "" {
			return missing
		}
		return unresolved_in_stmt(w, v.body)
	case ^Type_Record:
		if missing := unresolved_in_generics(w, v.generic_params); missing != "" {
			return missing
		}
		for attribute in v.attributes {
			if missing := unresolved_name(w, attribute.value); missing != "" {
				return missing
			}
		}
		if missing := unresolved_in(w, ..v.where_clauses); missing != "" {
			return missing
		}
		if missing := unresolved_in_fields(w, v.fields); missing != "" {
			return missing
		}
		return unresolved_in_variants(w, v.variants)
	case ^Type_Enum:
		if missing := unresolved_name(w, v.backing); missing != "" {
			return missing
		}
		for field in v.fields {
			if missing := unresolved_name(w, field.value); missing != "" {
				return missing
			}
		}
	case ^Type_Interface:
		if missing := unresolved_in_generics(w, v.generic_params); missing != "" {
			return missing
		}
		if missing := unresolved_in(w, ..v.where_clauses); missing != "" {
			return missing
		}
		for requirement in v.requirements {
			for group in requirement.bindings {
				bind_names(w, group.names)
				if missing := unresolved_name(w, group.type); missing != "" {
					return missing
				}
			}
			if missing := unresolved_in(w, requirement.expr, requirement.result, requirement.slot_type); missing != "" {
				return missing
			}
		}
	}
	return ""
}

@(private = "file")
bind_names :: proc(w: ^When_Walk, names: []Name) {
	for name in names {
		append(&w.bound, name.text)
	}
}

// Every name first, as a later parameter's name may appear in an earlier type.
@(private = "file")
unresolved_in_signature :: proc(w: ^When_Walk, v: ^Type_Proc) -> string {
	for parameter in v.params {
		for name in parameter.names {
			append(&w.bound, name.name.text)
		}
	}
	for parameter in v.params {
		if missing := unresolved_in(w, parameter.type, parameter.default); missing != "" {
			return missing
		}
	}
	return v.result == nil ? "" : unresolved_name(w, v.result.type)
}

@(private = "file")
unresolved_in_generics :: proc(w: ^When_Walk, params: []Generic_Param) -> string {
	for param in params {
		bind_names(w, param.names)
	}
	for param in params {
		if missing := unresolved_name(w, param.type); missing != "" {
			return missing
		}
	}
	return ""
}

@(private = "file")
unresolved_in_fields :: proc(w: ^When_Walk, fields: []Field) -> string {
	for field in fields {
		if missing := unresolved_name(w, field.type); missing != "" {
			return missing
		}
	}
	return ""
}

@(private = "file")
unresolved_in_variants :: proc(w: ^When_Walk, variants: []Variant) -> string {
	for variant in variants {
		if missing := unresolved_name(w, variant.type); missing != "" {
			return missing
		}
	}
	return ""
}

@(private = "file")
bind_foreach :: proc(w: ^When_Walk, bindings: []Foreach_Binding) {
	for binding in bindings {
		append(&w.bound, binding.name.text)
		bind_foreach(w, binding.group)
	}
}

@(private = "file")
unresolved_in_stmts :: proc(w: ^When_Walk, stmts: ..Stmt) -> string {
	for stmt in stmts {
		if missing := unresolved_in_stmt(w, stmt); missing != "" {
			return missing
		}
	}
	return ""
}

@(private = "file")
unresolved_in_header :: proc(w: ^When_Walk, init: Stmt, cond: Expr) -> string {
	if missing := unresolved_in_stmt(w, init); missing != "" {
		return missing
	}
	return unresolved_name(w, cond)
}

@(private = "file")
unresolved_in_stmt :: proc(w: ^When_Walk, stmt: Stmt) -> string {
	switch v in stmt {
	case ^Decl:
		bind_names(w, v.names)
		if missing := unresolved_in(w, v.declared_type, v.via); missing != "" {
			return missing
		}
		return unresolved_in(w, ..v.values)
	case ^Stmt_Error:
		return unresolved_in_stmt(w, v.partial)
	case ^Stmt_Expr:
		return unresolved_in(w, ..v.exprs)
	case ^Stmt_Assign:
		if missing := unresolved_in(w, ..v.lhs); missing != "" {
			return missing
		}
		return unresolved_in(w, ..v.rhs)
	case ^Stmt_If:
		if missing := unresolved_in_header(w, v.init, v.cond); missing != "" {
			return missing
		}
		return unresolved_in_stmts(w, v.then, v.otherwise)
	case ^Stmt_For:
		if missing := unresolved_in_header(w, v.init, v.cond); missing != "" {
			return missing
		}
		return unresolved_in_stmts(w, v.post, v.body)
	case ^Stmt_Foreach:
		bind_foreach(w, v.bindings)
		if missing := unresolved_name(w, v.iterable); missing != "" {
			return missing
		}
		return unresolved_in_stmt(w, v.body)
	case ^Stmt_When:
		if missing := unresolved_name(w, v.cond); missing != "" {
			return missing
		}
		return unresolved_in_stmts(w, v.then, v.otherwise)
	case ^Stmt_Switch:
		if missing := unresolved_in_header(w, v.init, v.subject); missing != "" {
			return missing
		}
		for entry in v.cases {
			append(&w.bound, entry.binding.text)
			append(&w.bound, entry.expanded.text)
			for field in entry.fields {
				append(&w.bound, field.name.text)
			}
			if missing := unresolved_in(w, ..entry.values); missing != "" {
				return missing
			}
			if missing := unresolved_in_stmts(w, ..entry.stmts); missing != "" {
				return missing
			}
		}
	case ^Stmt_Defer:
		return unresolved_in_stmt(w, v.stmt)
	case ^Stmt_Return:
		return v.value == nil ? "" : unresolved_name(w, v.value.expr)
	case ^Stmt_Parallel:
		if missing := unresolved_name(w, v.executor); missing != "" {
			return missing
		}
		return unresolved_in_stmt(w, v.body)
	case ^Stmt_Spawn:
		return unresolved_name(w, v.call)
	case ^Block:
		return v == nil ? "" : unresolved_in_stmts(w, ..v.stmts)
	// Nothing a condition waits on: control flow alone, and a local block's members,
	// which only a call through the type's own name could reach.
	case ^Stmt_Branch, ^Item_Impl:
	}
	return ""
}

// Whether a literal's keys are expressions: an array's index or index range, or
// a map's key. Only a record literal's key is a field name. A literal with no
// written type takes it from context, which this walk does not follow, so a bare
// name keying one is left for the check to report; likewise a named type in a
// reached declaration, whose resolving would be early.
@(private = "file")
composite_keys_are_values :: proc(w: ^When_Walk, v: ^Expr_Composite) -> bool {
	#partial switch _ in v.type_expr {
	case nil:
		return false
	case ^Type_Array, ^Type_Slice, ^Type_Dynamic_Array, ^Type_Map:
		return true
	}
	if w.following {
		return false
	}
	k := w.k
	probe := begin_probe(k.c)
	target := resolve_type_syntax(k, v.type_expr)
	end_probe(k.c, probe)
	info := underlying_info(k.c, target)
	return info != nil && info.kind != .Struct
}

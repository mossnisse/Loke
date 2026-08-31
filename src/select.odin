// Source selection: `when` at file and procedure scope.
//
// `when` is structural source selection, not a constant `if`. An unselected
// branch is parsed and nothing else — never declared, name-resolved,
// type-checked, gated, evaluated, given defer slots, or emitted. No edit inside
// one may change semantic state, diagnostics, symbol names, or generated code.
//
// Checking annotates the parser's AST in place rather than producing a second
// tree, so the selected view has to be persistent: `File.active_items` is
// rebuilt after each activation by flattening every selected branch at its
// surrounding position, and every semantic consumer iterates that.
package lokec

// Rebuilds each file's selected view, in original source order. Parser-owned
// item lists are never mutated.
rebuild_active_items :: proc(c: ^Compiler, pkg: ^Package) {
	for file in pkg.files {
		out := make([dynamic]Item, 0, len(file.items), context.temp_allocator)
		for item in file.items {
			flatten_item(item, &out)
		}
		view := make([]Item, len(out), c.semantic_allocator)
		copy(view, out[:])
		file.active_items = view
	}
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
		if !v.resolved {
			return // still pending; nothing it holds is active yet
		}
		if v.taken {
			flatten_item(v.then, out)
		} else if v.otherwise != nil {
			flatten_item(v.otherwise, out)
		}
		return
	}
	append(out, item)
}

// Every file-scope `when` that is reachable — at top level, inside an active
// block, or inside a taken branch — and has not chosen a branch yet.
collect_pending_whens :: proc(items: []Item, out: ^[dynamic]^Item_When) {
	for item in items {
		#partial switch v in item {
		case ^Item_Block:
			collect_pending_whens(v.items, out)
		case ^Item_When:
			if !v.resolved {
				// A condition already reported as unanswerable is not pending; it has
				// no answer to wait for, and neither branch is selected.
				if !v.stalled {
					append(out, v)
				}
				continue
			}
			if v.taken {
				collect_pending_whens(v.then.items, out)
			} else if v.otherwise != nil {
				branch := [1]Item{v.otherwise}
				collect_pending_whens(branch[:], out)
			}
		}
	}
}

// One activation round. Returns true when a branch was chosen, which is what
// makes the surrounding fixed point terminate.
activate_when_items :: proc(k: ^Checker, pkg: ^Package) -> bool {
	if pkg == nil || pkg.scope == nil {
		return false
	}
	saved := save_checker_location(k)
	defer restore_checker_location(k, saved)
	k.scope, k.pkg, k.lookup_pkg = pkg.scope, pkg.id, pkg.id

	progressed := false
	for file in pkg.files {
		pending := make([dynamic]^Item_When, 0, 4, context.temp_allocator)
		collect_pending_whens(file.items, &pending)
		k.file, k.file_node = file.file, file
		for item in pending {
			if resolve_item_when(k, item) {
				progressed = true
			}
		}
	}
	return progressed
}

@(private = "file")
resolve_item_when :: proc(k: ^Checker, item: ^Item_When) -> bool {
	// A condition waiting on a declaration another branch may still supply is
	// pending, not wrong; it is only an error once no round can add anything.
	if first_unresolved_name(k, item.cond) != "" {
		return false
	}
	value, ok := check_when_condition(k, item.cond)
	item.resolved = true
	item.taken = ok && value
	return true
}

// Everything still pending once no round can make progress. Naming the
// dependency distinguishes a condition waiting on discovery from a typo.
report_stalled_whens :: proc(k: ^Checker, pkg: ^Package) {
	if pkg == nil || pkg.scope == nil {
		return
	}
	saved := save_checker_location(k)
	defer restore_checker_location(k, saved)
	k.scope, k.pkg, k.lookup_pkg = pkg.scope, pkg.id, pkg.id

	for file in pkg.files {
		pending := make([dynamic]^Item_When, 0, 4, context.temp_allocator)
		collect_pending_whens(file.items, &pending)
		k.file, k.file_node = file.file, file
		for item in pending {
			// Reported, but never resolved: a `when` that cannot answer its condition
			// selects neither branch, so nothing inside either one is checked.
			item.stalled = true
			missing := first_unresolved_name(k, item.cond)
			if missing == "" {
				errorf(k.c, expr_span(item.cond), "L0389", "this `when` condition cannot be answered")
				continue
			}
			// A condition that could only be answered by an import inside its own
			// branch can never be answered: selecting the branch is what would supply
			// the name, and the name is what selects the branch.
			if bootstrap := self_bootstrap_import(item, missing); bootstrap != nil {
				errorf(
					k.c,
					expr_span(item.cond),
					"L0337",
					"this `when` condition needs `%s`, which only its own branch imports",
					missing,
				)
				add_notef(k.c, bootstrap.span, "imported here, inside the branch this condition selects")
				continue
			}
			errorf(k.c, expr_span(item.cond), "L0389", "`%s` is not declared, so this `when` condition cannot be answered", missing)
		}
	}
}

// The import inside this `when`'s own branches that would bind `name`, if there
// is one.
@(private = "file")
self_bootstrap_import :: proc(item: ^Item_When, name: string) -> ^Item_Import {
	branches := make([dynamic]Item, 0, 4, context.temp_allocator)
	append(&branches, item.then)
	if item.otherwise != nil {
		append(&branches, item.otherwise)
	}
	return find_import_binding(branches[:], name)
}

@(private = "file")
find_import_binding :: proc(items: []Item, name: string) -> ^Item_Import {
	for entry in items {
		#partial switch v in entry {
		case ^Item_Import:
			if import_binding_name(v) == name {
				return v
			}
		case ^Item_Block:
			if found := find_import_binding(v.items, name); found != nil {
				return found
			}
		case ^Item_When:
			if found := self_bootstrap_import(v, name); found != nil {
				return found
			}
		}
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
	sym := symbol_of(k.c, lookup_symbol(k.scope, identifier_of(k.c, ident)))
	return sym != nil && sym.kind == .Builtin && sym.builtin == kind
}

// The first name in `e` that does not resolve, or "" when they all do. Only
// value positions are visited: a selector's field and a `build_config` key are
// tokens, not lookups.
first_unresolved_name :: proc(k: ^Checker, e: Expr) -> string {
	if e == nil {
		return ""
	}
	#partial switch v in e {
	case ^Expr_Ident:
		if lookup_symbol(k.scope, identifier_of(k.c, v)) == INVALID_SYMBOL {
			return v.name
		}
	case ^Expr_Selector:
		if ident, is_ident := v.operand.(^Expr_Ident); is_ident {
			alias := lookup_symbol(k.scope, identifier_of(k.c, ident))
			if symbol := symbol_of(k.c, alias); symbol != nil && symbol.kind == .Package_Alias {
				target := package_of(k.c, symbol.pkg)
				name := intern_identifier(k.c, v.name.text)
				if target == nil || target.scope == nil {
					return concat(k.c, ident.name, concat(k.c, ".", v.name.text))
				}
				if _, found := target.scope.names[name]; !found {
					return concat(k.c, ident.name, concat(k.c, ".", v.name.text))
				}
				return ""
			}
		}
		return first_unresolved_name(k, v.operand)
	case ^Expr_Unary:
		return first_unresolved_name(k, v.operand)
	case ^Expr_Postfix:
		return first_unresolved_name(k, v.operand)
	case ^Expr_Binary:
		if missing := first_unresolved_name(k, v.lhs); missing != "" {
			return missing
		}
		return first_unresolved_name(k, v.rhs)
	case ^Expr_Cond:
		if missing := first_unresolved_name(k, v.cond); missing != "" {
			return missing
		}
		if missing := first_unresolved_name(k, v.then); missing != "" {
			return missing
		}
		return first_unresolved_name(k, v.otherwise)
	case ^Expr_Index:
		if missing := first_unresolved_name(k, v.operand); missing != "" {
			return missing
		}
		for index in v.indices {
			if missing := first_unresolved_name(k, index); missing != "" {
				return missing
			}
		}
	case ^Expr_Call:
		if missing := first_unresolved_name(k, v.callee); missing != "" {
			return missing
		}
		// `build_config(NAME, default)` names a configuration key, not a binding.
		skip := callee_is_builtin(k, v.callee, .Build_Config) ? 0 : -1
		for argument, index in v.args {
			if index == skip {
				continue
			}
			if missing := first_unresolved_name(k, argument.value); missing != "" {
				return missing
			}
		}
	}
	return ""
}

// The branch a procedure-scope `when` selected, or nil. The backend reads this
// rather than re-deciding.
when_selected_block :: proc(s: ^Stmt_When) -> ^Block {
	return s.resolved ? s.selected : nil
}

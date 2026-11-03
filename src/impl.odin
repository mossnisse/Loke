// `impl` blocks, methods, and associated members.
//
// A block in the subject's own package writes inherent members onto the
// `Type_Info`; one elsewhere writes into its own package's extension table, so
// an unused import cannot change what an expression means.
package lokec

import "core:slice"
import "core:strings"

// ------------------------------------------------------------- declaration --

// Runs in the discovery fixed point, so it must be idempotent and tolerate a
// subject whose package is not loaded yet (`quiet` defers that failure).
declare_impl_block :: proc(k: ^Checker, item: ^Item_Impl, quiet := true) {
	if item.declared {
		return
	}
	// A block on a generic type waits for an instantiation to install it on.
	if call, is_call := item.type.(^Expr_Call); is_call {
		if template := generic_template_of_callee(k, call.callee, .Record); template != nil {
			register_generic_impl(k, item, template.symbol, call.args)
			return
		}
		// design.md "Parametric aliases": a block over every application of an
		// alias would bind names in two packages' scopes at once; one over a
		// single application, `impl Io_Result(int)`, is a block on that type.
		if template := generic_template_of_callee(k, call.callee, .Alias); template != nil && type_syntax_has_poly(item.type) {
			item.declared = true
			errorf(
				k.c, expr_span(item.type), "L0746",
				"an `impl` subject cannot apply a parametric alias to `$` names; write the generic type it stands for",
			)
			return
		}
	}

	// A quiet attempt that fails is rolled back and retried, so it is a
	// speculation: it must not claim a report-once cache the retry needs.
	subject: Type_Id
	if quiet {
		probe := begin_probe(k.c)
		subject = resolve_type_syntax(k, item.type)
		end_probe(k.c, probe, keep = subject != INVALID_TYPE)
		if subject == INVALID_TYPE {
			return
		}
	} else {
		subject = resolve_impl_subject(k, item)
	}
	item.declared = true
	if subject == INVALID_TYPE {
		return
	}
	item.subject = subject

	// Built-in, foreign, and structural subjects have no owning package, so they
	// are extended (design.md "Methods and implementation blocks").
	info := type_of(k.c, subject)
	owner := info == nil ? nil : symbol_of(k.c, info.symbol)
	own_package := owner != nil && owner.pkg == k.pkg
	item.kind = own_package ? .Impl : .Extend
	declare_impl_members(k, item)
}

// `resolve_type_syntax` reports nothing for a subject that names no type at all.
@(private = "file")
resolve_impl_subject :: proc(k: ^Checker, item: ^Item_Impl) -> Type_Id {
	errors := k.c.error_count
	subject := resolve_type_syntax(k, item.type)
	if subject == INVALID_TYPE && k.c.error_count == errors {
		errorf(k.c, expr_span(item.type), "L0406", "this `impl` subject does not name a type")
	}
	return subject
}

// `delegate` and recovery nodes are handled by later phases.
@(private = "file")
declare_impl_members :: proc(k: ^Checker, item: ^Item_Impl, hooks_only := false) {
	members := make([dynamic]Symbol_Id, 0, len(item.members), k.c.semantic_allocator)
	existing := impl_member_table(k, item.kind, item.subject, k.pkg)
	for member in item.members {
		if d, is_decl := member.(^Decl); is_decl && (!hooks_only || decl_is_lifecycle_hook(d)) {
			declare_impl_member(k, item, d, existing, &members)
		}
	}
	install_impl_members(k, item.kind, item.subject, members[:], k.pkg)
}

// A body-local `impl`, which may only give members to a type declared in the same
// body: on any other type it would be a caller-local extension, which
// definition-site lookup rules out. A statement is visited once, so the package
// phases all run here.
check_local_impl :: proc(k: ^Checker, item: ^Item_Impl) {
	if _, generic := item.type.(^Expr_Call); generic {
		errorf(
			k.c, expr_span(item.type), "L0699",
			"a generic `impl` belongs at file scope; a block inside a body names one concrete type",
		)
		return
	}
	subject := resolve_impl_subject(k, item)
	if subject == INVALID_TYPE {
		return
	}
	if !type_declared_in_this_body(k, subject) {
		errorf(
			k.c, expr_span(item.type), "L0699",
			"`%s` is not declared in this procedure, so it cannot be given members here; write the `impl` beside the type",
			type_name(k.c, subject),
		)
		return
	}
	for member in item.members {
		d, is_decl := member.(^Decl)
		if !is_decl {
			continue
		}
		reject_unhoisted_local_hook(k, d, subject)
		// A hoisted hook resolves here, where its block is written.
		for id in d.symbols {
			if sym := symbol_of(k.c, id); sym != nil {
				sym.def_scope = k.scope
			}
		}
	}
	resolve_impl_signatures(k, item)
	validate_impl_attributes(k, item)
	for member in item.members {
		if d, is_decl := member.(^Decl); is_decl {
			hoist_body_local_proc(k, d)
		}
	}
	check_impl_block(k, item)
}

// design.md "Lifecycle hooks and resource types": a hook counts wherever it is
// written, so a body-local record's `hook(drop)` and `hook(copy)` join it as it is
// declared, ahead of the statement holding their block. Their signatures wait for
// that statement, as a block's names may be declared after the record, and what
// asks about the record before then needs only that they exist. The other members
// stay visible from the statement on.
declare_local_impl_hooks :: proc(k: ^Checker, item: ^Item_Impl, subject: Type_Id) {
	item.subject = subject
	item.kind = .Impl
	declare_impl_members(k, item, hooks_only = true)
}

// The one block `declare_local_impl_hooks` cannot reach is in a `when` whose
// condition names a constant declared after the record. If the record's lifecycle
// was already read, copies may have been decided without this hook, so running it
// now could release a value twice. See known-gaps.md "A hook in a `when` on a later
// constant comes too late for a record already used".
@(private = "file")
reject_unhoisted_local_hook :: proc(k: ^Checker, d: ^Decl, subject: Type_Id) {
	if !decl_is_lifecycle_hook(d) || len(d.symbols) > 0 {
		return
	}
	if _, read := k.c.lifecycles[type_underlying(k.c, subject)]; read {
		errorf(
			k.c, d.span, "L0488",
			"`hook(%s)` comes too late: `%s` was already used, and whether this block applies could not be told where `%s` is declared",
			hook_name(decl_hook_kind(d)), type_name(k.c, subject), type_name(k.c, subject),
		)
	}
}

@(private = "file")
type_declared_in_this_body :: proc(k: ^Checker, subject: Type_Id) -> bool {
	info := type_of(k.c, subject)
	if info == nil || k.scope == nil || k.scope.owner_proc == nil {
		return false
	}
	sym := symbol_of(k.c, info.symbol)
	return sym != nil && sym.def_scope != nil && sym.def_scope.owner_proc == k.scope.owner_proc
}

@(private = "file")
declare_impl_member :: proc(
	k: ^Checker,
	item: ^Item_Impl,
	d: ^Decl,
	existing: []Symbol_Id,
	out: ^[dynamic]Symbol_Id,
) {
	if len(d.symbols) > 0 {
		return
	}
	d.top_level = true
	if !require_impl_member_form(k, d) {
		return
	}

	symbols := make([dynamic]Symbol_Id, 0, len(d.names), k.c.semantic_allocator)
	for name in d.names {
		if name.text == "_" {
			append(&symbols, INVALID_SYMBOL)
			continue
		}
		name_id := name_identifier(k.c, name)
		previous := symbol_of(k.c, member_named(k.c, existing, name_id))
		generated := previous != nil && previous.synth != .None
		clash := ""
		switch {
		case generated:
			clash = "generated member"
		case previous != nil || member_named(k.c, out[:], name_id) != INVALID_SYMBOL:
			clash = "member"
		// `c.v` selects the field, so a member of that name could never be reached.
		case subject_field_named(k, item.subject, name_id) != INVALID_SYMBOL:
			clash = "field"
		case (type_is_enum(k.c, item.subject) && enum_builtin_member(name.text)) ||
		     (type_is_union(k.c, item.subject) && name.text == "as"):
			clash = "built-in member"
		}
		if clash != "" {
			errorf(
				k.c, name.span, "L0409",
				"`%s` already has a %s `%s`", type_name(k.c, item.subject), clash, name.text,
			)
			if generated {
				add_notef(k.c, item.span, "a use ahead of this block generated it, so write the block before that use")
			}
			append(&symbols, INVALID_SYMBOL)
			continue
		}
		sym := Symbol {
			name       = name_id,
			span       = name.span,
			decl       = d,
			pkg        = k.pkg,
			lookup_pkg = k.pkg,
			def_scope     = k.scope,
			def_file      = k.file,
			def_file_node = k.file_node,
			owner_type = item.subject,
			public     = declaration_is_public(k, d),
			hook       = decl_hook_kind(d),
			kind       = decl_proc_literal(d) != nil ? Symbol_Kind.Proc : Symbol_Kind.Const,
		}
		if sym.kind == .Proc {
			sym.type = TYPE_VOID
		}
		id := new_symbol(k.c, sym)
		append(&symbols, id)
		append(out, id)
		// A public extension is also reachable as `adapter.member(value)`.
		if item.kind == .Extend && sym.public {
			bind_member_in_package(k, name, name_id, id)
		}
	}
	d.symbols = symbols[:]
}

// What a block may hold, reported once for a generic block, whose instances skip
// anything else.
require_impl_member_form :: proc(k: ^Checker, d: ^Decl) -> bool {
	if d.kind == .Const && d.duration == .None && d.via == nil {
		return true
	}
	errorf(k.c, d.span, "L0406", "an `impl` member is a constant, a procedure, or an associated type")
	return false
}

@(private = "file")
bind_member_in_package :: proc(k: ^Checker, name: Name, name_id: Identifier_Id, id: Symbol_Id) {
	if _, taken := k.scope.names[name_id]; taken {
		errorf(k.c, name.span, "L0304", "`%s` is already declared in this package", name.text)
		return
	}
	k.scope.names[name_id] = id
}

// The type's inherent members, or `in_pkg`'s extensions of it. `in_pkg` is the
// instance's defining package when `src/generic_impl.odin` materialises a block.
impl_member_table :: proc(k: ^Checker, kind: Impl_Kind, subject: Type_Id, in_pkg: Package_Id) -> []Symbol_Id {
	if kind == .Impl {
		info := type_of(k.c, subject)
		return info == nil ? nil : info.members
	}
	pkg := package_of(k.c, in_pkg)
	if pkg == nil {
		return nil
	}
	return pkg.extensions[subject]
}

// Appends to whichever table `impl_member_table` reads, in the same package.
install_impl_members :: proc(k: ^Checker, kind: Impl_Kind, subject: Type_Id, added: []Symbol_Id, in_pkg: Package_Id) {
	if len(added) == 0 {
		return
	}
	if kind == .Impl {
		add_members(k.c, subject, added)
		return
	}
	previous := impl_member_table(k, kind, subject, in_pkg)
	if pkg := package_of(k.c, in_pkg); pkg != nil {
		pkg.extensions[subject] = slice.concatenate([][]Symbol_Id{previous, added}, k.c.semantic_allocator)
	}
}

// Puts `entry` where `previous` is in the table `impl_member_table` reads.
replace_impl_member :: proc(k: ^Checker, kind: Impl_Kind, subject: Type_Id, in_pkg: Package_Id, previous, entry: Symbol_Id) {
	for &member in impl_member_table(k, kind, subject, in_pkg) {
		if member == previous {
			member = entry
			return
		}
	}
}

// Fields share the namespace members are declared into.
subject_field_named :: proc(k: ^Checker, subject: Type_Id, name: Identifier_Id) -> Symbol_Id {
	info := type_of(k.c, type_underlying(k.c, subject))
	return info == nil ? INVALID_SYMBOL : member_named(k.c, info.fields, name)
}

member_named :: proc(c: ^Compiler, members: []Symbol_Id, name: Identifier_Id) -> Symbol_Id {
	for member in members {
		if sym := symbol_of(c, member); sym != nil && sym.name == name {
			return member
		}
	}
	return INVALID_SYMBOL
}

// A body-local record's hooks, from the `impl` statements after it in its scope
// (`declare_local_impl_hooks`). A local name is never shadowed in its body, so the
// names it goes by say which blocks are its own.
hoist_local_lifecycle_hooks :: proc(k: ^Checker, d: ^Decl) {
	if d.kind != .Const || len(d.values) != 1 || len(d.symbols) != 1 || k.body.following == nil {
		return
	}
	record, is_record := d.values[0].(^Type_Record)
	sym := symbol_of(k.c, d.symbols[0])
	if !is_record || record.kind != .Struct || sym == nil || sym.kind != .Type {
		return
	}
	subject := sym.type
	names := make([dynamic]string, 0, 2, context.temp_allocator)
	append(&names, d.names[0].text)
	for following := k.body.following; following != nil; following = following.outer {
		hoist_hooks_in_stmts(k, subject, &names, following.stmts)
	}
	// A `when` condition asked on the way may have read the record before a hook.
	delete_key(&k.c.lifecycles, type_underlying(k.c, subject))
}

@(private = "file")
hoist_hooks_in_stmts :: proc(k: ^Checker, subject: Type_Id, names: ^[dynamic]string, stmts: []Stmt) {
	for stmt in stmts {
		hoist_hooks_in_stmt(k, subject, names, stmt)
	}
}

@(private = "file")
hoist_hooks_in_block :: proc(k: ^Checker, subject: Type_Id, names: ^[dynamic]string, block: ^Block) {
	if block != nil {
		hoist_hooks_in_stmts(k, subject, names, block.stmts)
	}
}

@(private = "file")
hoist_hooks_in_stmt :: proc(k: ^Checker, subject: Type_Id, names: ^[dynamic]string, stmt: Stmt) {
	names_subject :: proc(names: []string, e: Expr) -> bool {
		ident, is_ident := e.(^Expr_Ident)
		return is_ident && slice.contains(names, ident.name)
	}
	#partial switch s in stmt {
	case ^Item_Impl:
		if names_subject(names[:], s.type) {
			declare_local_impl_hooks(k, s, subject)
		}
	case ^Decl:
		// `Alias :: Record;` names the same record.
		if s.kind == .Const && len(s.names) == 1 && len(s.values) == 1 && names_subject(names[:], s.values[0]) {
			append(names, s.names[0].text)
		}
	case ^Block:
		hoist_hooks_in_stmts(k, subject, names, s.stmts)
	case ^Stmt_If:
		hoist_hooks_in_block(k, subject, names, s.then)
		hoist_hooks_in_stmt(k, subject, names, s.otherwise)
	case ^Stmt_For:
		hoist_hooks_in_block(k, subject, names, s.body)
	case ^Stmt_Foreach:
		// A static expansion checks copies of its body, each a block of its own.
		if !any_static_binding(s.bindings) {
			hoist_hooks_in_block(k, subject, names, s.body)
		}
	case ^Stmt_Switch:
		for case_clause in s.cases {
			hoist_hooks_in_stmts(k, subject, names, case_clause.stmts)
		}
	case ^Stmt_Defer:
		hoist_hooks_in_stmt(k, subject, names, s.stmt)
	case ^Stmt_Parallel:
		hoist_hooks_in_block(k, subject, names, s.body)
	case ^Stmt_When:
		// A condition naming a constant declared later cannot be answered yet.
		if first_unresolved_name(k, s.cond) != "" {
			return
		}
		probe := begin_probe(k.c)
		value, answered := check_when_condition(k, s.cond)
		end_probe(k.c, probe)
		switch {
		case !answered:
		case value:
			hoist_hooks_in_block(k, subject, names, s.then)
		case:
			hoist_hooks_in_stmt(k, subject, names, s.otherwise)
		}
	}
}

// ---------------------------------------------------------- later phases --

resolve_impl_signatures :: proc(k: ^Checker, item: ^Item_Impl) {
	// Nothing can load any more, so an unresolved subject is now an error.
	declare_impl_block(k, item, quiet = false)
	if item.subject == INVALID_TYPE {
		check_generic_impl_subject(k, item)
		return
	}
	outer := k.impl_type
	k.impl_type = item.subject
	defer k.impl_type = outer
	for member in item.members {
		if d, is_decl := member.(^Decl); is_decl {
			resolve_declaration_signature(k, d)
		}
	}
	// After the signatures: delegation forwards operators already declared.
	for member in item.members {
		if delegate, is_delegate := member.(^Item_Delegate); is_delegate {
			check_delegate(k, delegate, item.subject, item.kind, k.pkg)
		}
	}
}

check_impl_block :: proc(k: ^Checker, item: ^Item_Impl) {
	if item.subject == INVALID_TYPE {
		// A generic block's members are checked per instance, but a public
		// constant's type may be the same in all of them.
		if call, is_call := item.type.(^Expr_Call); is_call {
			if template := generic_template_of_callee(k, call.callee, .Record); template != nil {
				read_generic_impl_constants(k, item, call, template)
				check_generic_impl_hooks(k, item, template)
			}
		}
		return
	}
	outer := k.impl_type
	k.impl_type = item.subject
	defer k.impl_type = outer
	for member in item.members {
		#partial switch v in member {
		case ^Decl:
			check_decl(k, v)
			for symbol_id in v.symbols {
				if sym := symbol_of(k.c, symbol_id); sym != nil {
					validate_semantic_hook(k, item, sym, symbol_id)
				}
			}
		case ^Item_Delegate, ^Item_Error:
			// Resolved with the signatures.
		case:
			unsupported_construct(k, item_span(member))
		}
	}
	// A declared associated type answers to the signatures whether or not a
	// lookup ever reaches it.
	ensure_derived_members(k, item.subject)
}

// ---------------------------------------------------------------- lookup --

// The package whose extensions are visible: the current one unless a declaration
// froze its own.
lookup_package :: proc(k: ^Checker) -> Package_Id {
	return k.lookup_pkg == INVALID_PACKAGE ? k.pkg : k.lookup_pkg
}

// Members the compiler contributes on demand, as if a hand-written `impl` had
// declared them.
@(private = "file")
ensure_contributed_members :: proc(k: ^Checker, type: Type_Id, name: Identifier_Id) {
	ensure_format_member(k, type, name)
	ensure_standard_customization_members(k, type)
	ensure_hash_member(k, type, name)
	ensure_iteration_members(k, type)
	ensure_mutable_iteration_members(k, type)
	ensure_derived_members(k, type)
	ensure_callable_result_member(k, type, name)
	ensure_lifecycle_members(k, type, name)
	ensure_container_members(k, type)
}

// Every visible member of `type` named `name`, with groups expanded for the
// overload engine.
member_candidates :: proc(k: ^Checker, type: Type_Id, name: Identifier_Id) -> []Symbol_Id {
	ensure_contributed_members(k, type, name)
	out := make([dynamic]Symbol_Id, 0, 4, k.c.semantic_allocator)
	pkg := lookup_package(k)
	expand_visible_members(k, type, impl_member_table(k, .Impl, type, pkg), name, &out)
	expand_visible_members(k, type, impl_member_table(k, .Extend, type, pkg), name, &out)
	if len(out) == 0 {
		// A `where` bound reaches implementations ordinary visibility hides.
		if required := required_slot_candidates(k, type, name); len(required) > 0 {
			return required
		}
		if adapter := iteration_adapter_member(k, type, name); adapter != INVALID_SYMBOL {
			append(&out, adapter)
		}
	}
	return out[:]
}

// A member a failed `where` bound removed, so "no such member" can say why.
excluded_member :: proc(k: ^Checker, type: Type_Id, name: Identifier_Id) -> ^Symbol {
	pkg := lookup_package(k)
	for table in ([][]Symbol_Id{impl_member_table(k, .Impl, type, pkg), impl_member_table(k, .Extend, type, pkg)}) {
		for member in table {
			sym := symbol_of(k.c, member)
			if sym != nil && sym.name == name && sym.bound_excluded {
				return sym
			}
		}
	}
	return nil
}

// The one visibility predicate, asked by every lookup path. The observer is the
// lookup package, so a generic body instantiated elsewhere sees its definition site.
member_is_visible :: proc(k: ^Checker, sym: ^Symbol) -> bool {
	// A member whose `where` bound failed is not part of this instantiation.
	if sym == nil || sym.bound_excluded {
		return false
	}
	if standard_format_hidden(k.c, sym, lookup_package(k)) || !capture_field_visible(k, sym) {
		return false
	}
	return sym.pkg == lookup_package(k) || sym.public
}

// Every field access path routes through here so they agree with reflection.
require_visible_field :: proc(k: ^Checker, span: Span, subject: Type_Id, field: Symbol_Id, code: string, action: string) -> bool {
	sym := symbol_of(k.c, field)
	if member_is_visible(k, sym) {
		return true
	}
	if !capture_field_visible(k, sym) {
		errorf(
			k.c, span, code,
			"`%s` is a capture of `%s`, which only the literal's body reads, so it cannot be %s here",
			strings.trim_prefix(identifier_text(k.c, sym.name), CAPTURE_FIELD_PREFIX), type_name(k.c, subject), action,
		)
		return false
	}
	errorf(
		k.c,
		span,
		code,
		"field `%s` of `%s` is not public, so it cannot be %s here",
		identifier_text(k.c, sym.name),
		type_name(k.c, subject),
		action,
	)
	// A compiler-owned member, such as a descriptor's `owner`, has no source to edit.
	if sym.pkg != INVALID_PACKAGE {
		add_notef(k.c, sym.span, "declared here; add `@(public)` to export it")
	}
	return false
}

@(private = "file")
expand_visible_members :: proc(k: ^Checker, subject: Type_Id, members: []Symbol_Id, name: Identifier_Id, out: ^[dynamic]Symbol_Id) {
	for member in members {
		sym := symbol_of(k.c, member)
		if sym == nil || sym.name != name || !member_is_visible(k, sym) {
			continue
		}
		sym = member_with_signature(k, member, subject)
		sym.looked_up = true
		if sym.kind == .Proc_Group {
			for nested in sym.members {
				if !symbol_of(k.c, nested).bound_excluded {
					append(out, nested)
				}
			}
			continue
		}
		append(out, member)
	}
}

// One named member, without expanding a group: `Type.member`.
find_member :: proc(k: ^Checker, type: Type_Id, name: Identifier_Id) -> Symbol_Id {
	ensure_contributed_members(k, type, name)
	pkg := lookup_package(k)
	if found := visible_member_named(k, impl_member_table(k, .Impl, type, pkg), name); found != INVALID_SYMBOL {
		return found
	}
	if found := visible_member_named(k, impl_member_table(k, .Extend, type, pkg), name); found != INVALID_SYMBOL {
		return found
	}
	// Same `where`-bound fallback as `member_candidates`, so `T.m(x)` finds what
	// `x.m()` does.
	// ponytail: a bound-reached overload group resolves only when it has one member.
	if required := required_slot_candidates(k, type, name); len(required) == 1 {
		return required[0]
	}
	// design.md "Interface bodies": and the associated constants a bound requires.
	if constant := required_associated_constant(k, type, name); constant != INVALID_SYMBOL {
		return constant
	}
	return iteration_adapter_member(k, type, name)
}

@(private = "file")
visible_member_named :: proc(k: ^Checker, members: []Symbol_Id, name: Identifier_Id) -> Symbol_Id {
	member := member_named(k.c, members, name)
	sym := symbol_of(k.c, member)
	if !member_is_visible(k, sym) {
		return INVALID_SYMBOL
	}
	sym.looked_up = true
	return member
}

// `impl` blocks, methods, associated members, and semantic hooks.
//
// A block in the subject's own package writes inherent members onto the
// `Type_Info`; one elsewhere writes into its own package's extension table, so
// an unused import cannot change what an expression means.
package lokec

import "core:fmt"

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
	}

	// A quiet attempt that fails is rolled back and retried, so it is a
	// speculation: it must not claim a report-once cache the retry needs.
	mark := len(k.c.diagnostics)
	errors := k.c.error_count
	if quiet {
		k.c.speculation_depth += 1
	}
	subject := resolve_type_syntax(k, item.type)
	if quiet {
		k.c.speculation_depth -= 1
	}
	if subject == INVALID_TYPE {
		if quiet {
			truncate_diagnostics(k.c, mark)
			return
		}
		item.declared = true
		if k.c.error_count == errors {
			errorf(k.c, expr_span(item.type), "L0406", "this `impl` subject does not name a type")
		}
		return
	}
	item.declared = true
	item.subject = subject

	// Built-in and foreign subjects have no owning package, so they are extended.
	info := type_of(k.c, subject)
	owner := info == nil ? nil : symbol_of(k.c, info.symbol)
	own_package := owner != nil && owner.pkg == k.pkg
	item.kind = own_package ? .Impl : .Extend

	members := make([dynamic]Symbol_Id, 0, len(item.members), k.c.semantic_allocator)
	existing := impl_member_table(k, item.kind, subject, k.pkg)
	for member in item.members {
		d, is_decl := member.(^Decl)
		if !is_decl {
			continue // `delegate` and recovery nodes are handled in the body phase
		}
		declare_impl_member(k, item, d, existing, &members)
	}
	install_impl_members(k, item.kind, subject, members[:], k.pkg)
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
	subject := resolve_type_syntax(k, item.type)
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
	resolve_impl_signatures(k, item)
	validate_impl_attributes(k, item)
	for member in item.members {
		if d, is_decl := member.(^Decl); is_decl {
			hoist_body_local_proc(k, d)
		}
	}
	check_impl_block(k, item)
}

// Whether the subject is a type this very procedure declares.
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
	if d.kind != .Const || d.duration != .None || d.via != nil {
		errorf(k.c, d.span, "L0406", "an `impl` member is a constant, a procedure, or an associated type")
		d.symbols = make([]Symbol_Id, 0, k.c.semantic_allocator)
		return
	}

	symbols := make([dynamic]Symbol_Id, 0, len(d.names), k.c.semantic_allocator)
	for name in d.names {
		if name.text == "_" {
			append(&symbols, INVALID_SYMBOL)
			continue
		}
		name_id := name.id
		if name_id == INVALID_IDENTIFIER {
			name_id = intern_identifier(k.c, name.text)
		}
		if member_named(k.c, existing, name_id) != INVALID_SYMBOL ||
		   member_named(k.c, out[:], name_id) != INVALID_SYMBOL {
			errorf(
				k.c,
				name.span,
				"L0409",
				"`%s` already has a member `%s`",
				type_name(k.c, item.subject),
				name.text,
			)
			append(&symbols, INVALID_SYMBOL)
			continue
		}
		// `c.v` selects the field, so a member of that name could never be reached.
		if subject_field_named(k, item.subject, name_id) != INVALID_SYMBOL {
			errorf(
				k.c, name.span, "L0409",
				"`%s` already has a field `%s`", type_name(k.c, item.subject), name.text,
			)
			append(&symbols, INVALID_SYMBOL)
			continue
		}
		if type_is_enum(k.c, item.subject) && enum_builtin_member(name.text) {
			errorf(
				k.c, name.span, "L0409",
				"`%s` already has a built-in member `%s`", type_name(k.c, item.subject), name.text,
			)
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

@(private = "file")
bind_member_in_package :: proc(k: ^Checker, name: Name, name_id: Identifier_Id, id: Symbol_Id) {
	if _, taken := k.scope.names[name_id]; taken {
		errorf(k.c, name.span, "L0304", "`%s` is already declared in this package", name.text)
		return
	}
	k.scope.names[name_id] = id
}

// The type's inherent members, or `in_pkg`'s extensions of it. `in_pkg` is the
// instance's defining package when `src/generic.odin` materialises a block.
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
	merged := make([]Symbol_Id, len(previous) + len(added), k.c.semantic_allocator)
	copy(merged, previous)
	copy(merged[len(previous):], added)
	if pkg := package_of(k.c, in_pkg); pkg != nil {
		pkg.extensions[subject] = merged
	}
}

// Fields share the namespace members are declared into.
subject_field_named :: proc(k: ^Checker, subject: Type_Id, name: Identifier_Id) -> Symbol_Id {
	info := type_of(k.c, type_underlying(k.c, subject))
	return info == nil ? INVALID_SYMBOL : member_named(k.c, info.fields, name)
}

// Takes the `^Compiler` so `src/generic.odin` can use it from an instance's package.
member_named :: proc(c: ^Compiler, members: []Symbol_Id, name: Identifier_Id) -> Symbol_Id {
	for member in members {
		if sym := symbol_of(c, member); sym != nil && sym.name == name {
			return member
		}
	}
	return INVALID_SYMBOL
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
			check_delegate(k, delegate, item.subject)
		}
	}
}

check_impl_block :: proc(k: ^Checker, item: ^Item_Impl) {
	if item.subject == INVALID_TYPE {
		return
	}
	outer := k.impl_type
	k.impl_type = item.subject
	defer k.impl_type = outer
	for member in item.members {
		#partial switch v in member {
		case ^Decl:
			check_decl(k, v)
			check_associated_member(k, item, v)
		case ^Item_Delegate, ^Item_Error:
			// Resolved with the signatures.
		case:
			unsupported_construct(k, item_span(member))
		}
	}
}

@(private = "file")
check_associated_member :: proc(k: ^Checker, item: ^Item_Impl, d: ^Decl) {
	for symbol_id in d.symbols {
		sym := symbol_of(k.c, symbol_id)
		if sym == nil {
			continue
		}
		validate_semantic_hook(k, item, d, sym, symbol_id)
	}
}

// ---------------------------------------------------------------- lookup --

// The package whose extensions are visible: the current one unless a declaration
// froze its own.
lookup_package :: proc(k: ^Checker) -> Package_Id {
	return k.lookup_pkg == INVALID_PACKAGE ? k.pkg : k.lookup_pkg
}

// Members the compiler contributes on demand, as if a hand-written `impl` had
// declared them. Shared by `member_candidates` and `find_member` so both see the
// same set.
@(private = "file")
ensure_contributed_members :: proc(k: ^Checker, type: Type_Id, name: Identifier_Id) {
	ensure_standard_customization_members(k, type)
	ensure_iteration_members(k, type)
	ensure_mutable_iteration_members(k, type)
	ensure_item_member(k, type)
	ensure_iterator_members(k, type, name)
	ensure_lifecycle_members(k, type, name)
	ensure_container_members(k, type)
	ensure_provider_members(k, type)
}

// Every visible member of `type` named `name`, with groups expanded for the
// overload engine.
member_candidates :: proc(k: ^Checker, type: Type_Id, name: Identifier_Id) -> []Symbol_Id {
	ensure_contributed_members(k, type, name)
	out := make([dynamic]Symbol_Id, 0, 4, k.c.semantic_allocator)
	if info := type_of(k.c, type); info != nil {
		expand_visible_members(k, type, info.members, name, &out)
	}
	if pkg := package_of(k.c, lookup_package(k)); pkg != nil {
		if members, found := pkg.extensions[type]; found {
			expand_visible_members(k, type, members, name, &out)
		}
	}
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
	info := type_of(k.c, type)
	if info == nil {
		return nil
	}
	for member in info.members {
		sym := symbol_of(k.c, member)
		if sym != nil && sym.name == name && sym.bound_excluded {
			return sym
		}
	}
	return nil
}

// The one visibility predicate, asked by every lookup path. The observer is the
// lookup package, so a generic body instantiated elsewhere sees its definition site.
member_is_visible :: proc(k: ^Checker, sym: ^Symbol) -> bool {
	if sym == nil {
		return false
	}
	// A member whose `where` bound failed is not part of this instantiation.
	if sym.bound_excluded {
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
	errorf(
		k.c,
		span,
		code,
		"field `%s` of `%s` is not public, so it cannot be %s here",
		identifier_text(k.c, sym.name),
		type_name(k.c, subject),
		action,
	)
	add_notef(k.c, sym.span, "declared here; add `@(public)` to export it")
	return false
}

@(private = "file")
expand_visible_members :: proc(k: ^Checker, subject: Type_Id, members: []Symbol_Id, name: Identifier_Id, out: ^[dynamic]Symbol_Id) {
	for member in members {
		sym := symbol_of(k.c, member)
		if sym == nil || sym.name != name || !member_is_visible(k, sym) {
			continue
		}
		if sym.decl != nil && sym.decl.sig_state == .Unchecked {
			resolve_symbol_signature_in_place(k, member, subject)
			sym = symbol_of(k.c, member)
		}
		if sym.kind == .Proc_Group {
			for nested in sym.members {
				append(out, nested)
			}
			continue
		}
		append(out, member)
	}
}

// One named member, without expanding a group: `Type.member`.
find_member :: proc(k: ^Checker, type: Type_Id, name: Identifier_Id) -> Symbol_Id {
	ensure_contributed_members(k, type, name)
	if info := type_of(k.c, type); info != nil {
		if found := visible_member_named(k, info.members, name); found != INVALID_SYMBOL {
			return found
		}
	}
	if pkg := package_of(k.c, lookup_package(k)); pkg != nil {
		if members, present := pkg.extensions[type]; present {
			if found := visible_member_named(k, members, name); found != INVALID_SYMBOL {
				return found
			}
		}
	}
	// Same `where`-bound fallback as `member_candidates`, so `T.m(x)` finds what
	// `x.m()` does.
	// ponytail: a bound-reached overload group resolves only when it has one member.
	if required := required_slot_candidates(k, type, name); len(required) == 1 {
		return required[0]
	}
	return iteration_adapter_member(k, type, name)
}

@(private = "file")
visible_member_named :: proc(k: ^Checker, members: []Symbol_Id, name: Identifier_Id) -> Symbol_Id {
	member := member_named(k.c, members, name)
	sym := symbol_of(k.c, member)
	return member_is_visible(k, sym) ? member : INVALID_SYMBOL
}

has_member :: proc(k: ^Checker, type: Type_Id, name: Identifier_Id) -> bool {
	return find_member(k, type, name) != INVALID_SYMBOL
}

// ------------------------------------------------------ semantic hooks --

// Every inherent hook of one role, matched by role rather than name.
hook_candidates :: proc(k: ^Checker, target: Type_Id, role: Hook_Kind) -> []Symbol_Id {
	out := make([dynamic]Symbol_Id, 0, 4, k.c.semantic_allocator)
	info := type_of(k.c, target)
	if info == nil {
		return out[:]
	}
	for member in info.members {
		sym := symbol_of(k.c, member)
		if sym != nil && sym.decl != nil && sym.decl.sig_state == .Unchecked {
			resolve_symbol_signature_in_place(k, member, target)
			sym = symbol_of(k.c, member)
		}
		if sym != nil && sym.hook == role {
			append(&out, member)
		}
	}
	return out[:]
}

// ------------------------------------------------------------- backend name --

// The backend name of a method, unique within a package.
qualified_member_name :: proc(c: ^Compiler, sym: ^Symbol, allocator := context.allocator) -> string {
	owner := type_name(c, sym.owner_type)
	// An instantiation's own spelling: `Pair.int.member`.
	if info := type_of(c, sym.owner_type); info != nil && info.mangled != "" {
		owner = info.mangled
	}
	return fmt.aprintf("%s.%s", owner, identifier_text(c, sym.name), allocator = allocator)
}

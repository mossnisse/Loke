// `impl` blocks, methods, associated members, and semantic hooks.
//
// Storage: an `impl` block in the subject's own package writes inherent
// members onto the nominal `Type_Info`; one elsewhere writes into its own
// package's extension table, and the two never merge. Extension visibility
// is package-scoped by design — an unused import must not change or make
// ambiguous an existing expression.
package lokec

import "core:fmt"

// ------------------------------------------------------------- declaration --

// Resolves the subject type and creates one symbol per member. Runs in the
// discovery fixed point, so it must be idempotent and must tolerate a subject
// whose own package is not prepared yet.
declare_impl_block :: proc(k: ^Checker, item: ^Item_Impl, quiet := true) {
	if item.declared {
		return
	}
	// During discovery the subject's own package may not be loaded yet, so a
	// failure is pending, not wrong: reported only once no round can supply more.
	// A block written against a generic type — `impl Table($K, $V)` or the
	// specialized `impl Table(string, int)` — is kept until an instantiation
	// exists to install it on, rather than resolving a subject that has none yet.
	if call, is_call := item.type.(^Expr_Call); is_call {
		if template := generic_template_of_callee(k, call.callee, .Record); template != nil {
			register_generic_impl(k, item, template.symbol, call.args)
			return
		}
	}

	mark := len(k.c.diagnostics)
	errors := k.c.error_count
	subject := resolve_type_syntax(k, item.type)
	if subject == INVALID_TYPE {
		if quiet {
			truncate_diagnostics(k.c, mark)
			k.c.error_count = errors
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

	// Inherent vs. extension isn't written; it follows from where the subject is
	// declared. A block in the subject's own package contributes inherent members
	// to the nominal type; one anywhere else — including a built-in or foreign
	// subject, which no package declares — is an extension confined to the
	// package that writes it.
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

// design.md "Methods and implementation blocks": a body-local `impl` gives a
// type declared in the same body its methods, so a one-off callable record — the
// explicit form of a small callback — sits beside the call that takes it. The
// three package phases run here in order, because a statement is visited once
// and has no later phase to be reached by.
//
// The subject has to be declared in this body. An `impl` on any other type would
// be a caller-local extension, which definition-site lookup exists to rule out:
// a generic instantiation must mean the same thing in every caller. A local type
// cannot be named from anywhere else, so a block on one adds no such reach.
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
		return // `resolve_type_syntax` said what is wrong with the subject
	}
	if !type_declared_in_this_body(k, subject) {
		errorf(
			k.c, expr_span(item.type), "L0699",
			"`%s` is not declared in this procedure, so it cannot be given members here; write the `impl` beside the type",
			type_name(k.c, subject),
		)
		return
	}
	declare_impl_block(k, item, quiet = false)
	resolve_impl_signatures(k, item)
	validate_impl_attributes(k, item)
	// A method is an ordinary module function. Nothing walks a body looking for
	// one, so each is hoisted exactly as a procedure declared in the body is.
	if pkg := package_of(k.c, k.pkg); pkg != nil && k.c.speculation_depth == 0 {
		for member in item.members {
			d, is_decl := member.(^Decl)
			if !is_decl || len(d.symbols) == 0 || d.symbols[0] == INVALID_SYMBOL {
				continue
			}
			if literal := decl_proc_literal(d); literal != nil && !symbol_is_generic(k, d.symbols[0]) {
				append(&pkg.hoisted_procs, literal)
			}
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
		// A member sharing a field's name is unreachable rather than ambiguous:
		// `c.v` is the field, and `c.v()` is "`int` is not callable", so the block
		// would declare a procedure nothing can call. The subject's fields are
		// resolved by now -- resolving the subject is what this block just did.
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
		// A public extension procedure has an ordinary package-qualified spelling,
		// `adapter.member(value)`. Inherent members remain under their owning type,
		// `vendor.Type.member(value)`, and never consume a package-level name.
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

// The member table an `impl`/`extend` block writes into: the type's own
// inherent members, or one package's extension list. `in_pkg` is the checker's
// current package for a written block, and the instance's defining package for
// one `src/generic.odin` materialises — that is the only difference between the
// two, so there is one table lookup rather than two.
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
	previous := impl_member_table(k, kind, subject, in_pkg)
	merged := make([]Symbol_Id, len(previous) + len(added), k.c.semantic_allocator)
	copy(merged, previous)
	copy(merged[len(previous):], added)
	if kind == .Impl {
		if info := type_of(k.c, subject); info != nil {
			info.members = merged
		}
		return
	}
	if pkg := package_of(k.c, in_pkg); pkg != nil {
		pkg.extensions[subject] = merged
	}
}

// The one member-by-name loop. Takes the `^Compiler` rather than the `^Checker`
// so `src/generic.odin` reaches the same one from an instance's own package.
// The subject's own fields, which share the namespace its members are
// declared into.
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

// ---------------------------------------------------------- later phases --

resolve_impl_signatures :: proc(k: ^Checker, item: ^Item_Impl) {
	// Selection and the import graph are stable by now, so an unresolved subject
	// is a real diagnostic rather than a pending one.
	declare_impl_block(k, item, quiet = false)
	if item.subject == INVALID_TYPE {
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
	// Delegation reads the operators already declared for the subject, and adds
	// forwarding overloads every body checked afterwards can see.
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
			// `delegate` was resolved with the signatures, above.
		case:
			unsupported_construct(k, item_span(member))
		}
	}
}

// The rules that need the member's resolved signature: receiver ownership and
// the closed semantic-hook shapes.
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

// The package whose extension table the declaration being checked may use. It is
// the checker's current package except where a declaration froze its own.
lookup_package :: proc(k: ^Checker) -> Package_Id {
	return k.lookup_pkg == INVALID_PACKAGE ? k.pkg : k.lookup_pkg
}

// Everything the compiler contributes to `type` on demand, so a lookup sees
// exactly what a hand-written `impl` would have declared. One list: a member
// set contributed for `member_candidates` but not for `find_member` would make
// the same name resolve differently depending on which asked.
@(private = "file")
ensure_contributed_members :: proc(k: ^Checker, type: Type_Id, name: Identifier_Id) {
	// Built-in query and hashing operations are real receiver members, which is
	// what `x.len()` and `x.hash(seed)` select on a built-in type.
	ensure_standard_customization_members(k, type)
	// A built-in iterable's associated members and `iter` are contributed on
	// demand, so interface checking and generic code see exactly what a user type
	// declares by hand (design.md "Iteration protocol").
	ensure_iteration_members(k, type)
	ensure_mutable_iteration_members(k, type)
	// `Item` names what this type's own `next` hands back, for any iterator
	// (design.md "Iteration protocol").
	ensure_item_member(k, type)
	// The generated `try_clone`/`clone` are contributed the same way, so a record
	// without a hand-written hook still has both copy entry points.
	ensure_lifecycle_members(k, type, name)
	// A container's operation set, so `xs.append(1)` is an ordinary method call
	// and generic code finds the same members (design.md "Dynamic arrays").
	ensure_container_members(k, type)
	// And a local region provider's constructor and `allocator`, for the same
	// reason: it is a compiler-owned type whose members no source file declares.
	ensure_provider_members(k, type)
}

// Every member of `type` named `name` that this package may use: the type's own
// inherent members, plus the extensions the lookup package declares. Groups are
// expanded, so the overload engine sees one flat candidate set.
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
		// An interface bound on the enclosing declaration reaches implementations
		// the caller's own visibility hides; nothing else does.
		if required := required_slot_candidates(k, type, name); len(required) > 0 {
			return required
		}
		if adapter := iteration_adapter_member(k, type, name); adapter != INVALID_SYMBOL {
			append(&out, adapter)
		}
	}
	return out[:]
}

// A member a failed `where` bound removed from this instantiation. Lookup hides
// it, so a "no such member" report can say the name exists and why it is not
// here, instead of leaving the caller to hunt for a typo.
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

// The one symbol-visibility predicate (design.md "Exported names"). Methods,
// operators, associated members, struct fields, and reflection all ask this, so
// no path can expose a declaration another path would hide. The observer is the
// lookup package rather than the package being compiled, which is what lets a
// generic body instantiated elsewhere still see its own definition site.
member_is_visible :: proc(k: ^Checker, sym: ^Symbol) -> bool {
	if sym == nil {
		return false
	}
	// design.md "where clauses": a method of an instantiated generic `impl` whose
	// bound does not hold is not part of that instantiation. Hiding it here rather
	// than at each lookup is what keeps method calls, operators, interface
	// satisfaction, and reflection agreeing on which members that instance has.
	if sym.bound_excluded {
		return false
	}
	return sym.pkg == lookup_package(k) || sym.public
}

// The declaring package may read, write, and initialize package-visible
// fields; importing packages may do so only for public fields (design.md
// "Exported names"). Ordinary selection, `offset_of`, and both aggregate
// literal forms route through here so they agree with each other and with
// reflection.
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

// One named member, without expanding a group: what an associated constant, an
// associated type, or a directly named procedure resolves to.
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
	return iteration_adapter_member(k, type, name)
}

@(private = "file")
visible_member_named :: proc(k: ^Checker, members: []Symbol_Id, name: Identifier_Id) -> Symbol_Id {
	member := member_named(k.c, members, name)
	sym := symbol_of(k.c, member)
	return member_is_visible(k, sym) ? member : INVALID_SYMBOL
}

// Does this type have any member named `name`? Used before reporting "no field",
// so the diagnostic can name the real problem.
has_member :: proc(k: ^Checker, type: Type_Id, name: Identifier_Id) -> bool {
	return find_member(k, type, name) != INVALID_SYMBOL
}

// ------------------------------------------------------ semantic hooks --

// Every inherent hook of one role. Hook labels are not lookup names: conversion
// overloads with different descriptive names form one candidate set by role.
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

// `Type.member`, which is what the backend mangles a method or associated
// procedure under. Two impl blocks cannot give one type the same member name, so
// this is unique within a package.
qualified_member_name :: proc(c: ^Compiler, sym: ^Symbol, allocator := context.allocator) -> string {
	owner := type_name(c, sym.owner_type)
	// An instantiation carries its own backend spelling, so a member of
	// `Pair(int)` is emitted under `Pair.int.member` rather than through escapes.
	if info := type_of(c, sym.owner_type); info != nil && info.mangled != "" {
		owner = info.mangled
	}
	return fmt.aprintf("%s.%s", owner, identifier_text(c, sym.name), allocator = allocator)
}

// An `impl` member reached on demand — an associated type asked for by an
// interface requirement, say — is checked in its *own* declaration scope. Inside
// an instantiated block that scope binds the block's generic arguments, which is
// what makes `Iterator :: Stack_Iterator(T, N)` resolve wherever it is asked
// for.
check_member_decl_in_place :: proc(k: ^Checker, member: Symbol_Id, subject: Type_Id) {
	sym := symbol_of(k.c, member)
	if sym == nil || sym.decl == nil {
		return
	}
	check_symbol_decl_in_place(k, member, subject)
}

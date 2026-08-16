// `impl`/`extend` blocks, methods, associated members, and `init` construction
// (m4a-plan step 2).
//
// Storage follows the plan's "Method storage" decision: an `impl` block writes
// inherent members onto the nominal `Type_Info`, an `extend` block writes into
// its own package's extension table, and the two are never merged. Extension
// visibility is package-scoped by design — an unused import must not change or
// make ambiguous an existing expression.
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
	// failure is pending rather than wrong: it is reported only once no round can
	// supply anything more.
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

	info := type_of(k.c, subject)
	owner := info == nil ? nil : symbol_of(k.c, info.symbol)
	own_package := owner != nil && owner.pkg == k.pkg
	if item.kind == .Impl && !own_package {
		errorf(
			k.c,
			expr_span(item.type),
			"L0407",
			"`impl` belongs with the package that declares `%s`; write `extend` here",
			type_name(k.c, subject),
		)
		return
	}
	if item.kind == .Extend && own_package {
		errorf(
			k.c,
			expr_span(item.type),
			"L0407",
			"`extend` is for a type from another package; `%s` is declared here, so write `impl`",
			type_name(k.c, subject),
		)
		return
	}

	members := make([dynamic]Symbol_Id, 0, len(item.members), k.c.semantic_allocator)
	existing := impl_member_table(k, item.kind, subject)
	for member in item.members {
		d, is_decl := member.(^Decl)
		if !is_decl {
			continue // `delegate` and recovery nodes are handled in the body phase
		}
		declare_impl_member(k, item, d, existing, &members)
	}
	install_impl_members(k, item.kind, subject, members[:])
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
	if d.kind != .Const || d.duration != .None || d.manual || d.via != nil {
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
		if member_named(k, existing, name_id) != INVALID_SYMBOL || member_named(k, out[:], name_id) != INVALID_SYMBOL {
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
			implicit   = has_attribute(d.attributes, "implicit"),
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

@(private = "file")
impl_member_table :: proc(k: ^Checker, kind: Impl_Kind, subject: Type_Id) -> []Symbol_Id {
	if kind == .Impl {
		info := type_of(k.c, subject)
		return info == nil ? nil : info.members
	}
	pkg := package_of(k.c, k.pkg)
	if pkg == nil {
		return nil
	}
	return pkg.extensions[subject]
}

@(private = "file")
install_impl_members :: proc(k: ^Checker, kind: Impl_Kind, subject: Type_Id, added: []Symbol_Id) {
	if len(added) == 0 {
		return
	}
	previous := impl_member_table(k, kind, subject)
	merged := make([]Symbol_Id, len(previous) + len(added), k.c.semantic_allocator)
	copy(merged, previous)
	copy(merged[len(previous):], added)
	if kind == .Impl {
		if info := type_of(k.c, subject); info != nil {
			info.members = merged
		}
		return
	}
	if pkg := package_of(k.c, k.pkg); pkg != nil {
		pkg.extensions[subject] = merged
	}
}

@(private = "file")
member_named :: proc(k: ^Checker, members: []Symbol_Id, name: Identifier_Id) -> Symbol_Id {
	for member in members {
		if sym := symbol_of(k.c, member); sym != nil && sym.name == name {
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

// The rules that need the member's resolved signature: a receiver's owner, and
// what `@(implicit)` may be written on.
@(private = "file")
check_associated_member :: proc(k: ^Checker, item: ^Item_Impl, d: ^Decl) {
	init_name := intern_identifier(k.c, "init")
	for symbol_id in d.symbols {
		sym := symbol_of(k.c, symbol_id)
		if sym == nil {
			continue
		}
		// design.md "Lifecycle hooks and resource types": the signatures are fixed
		// by the type, so they are checked where they are written.
		validate_lifecycle_hook(k, item, d, sym, symbol_id)
		// design.md "Construction and conversions": an `init` overload constructs
		// the type, so it takes no receiver and produces exactly that type.
		if sym.name == init_name {
			if sym.kind == .Proc {
				check_init_shape(k, item, symbol_id)
			} else if sym.kind == .Proc_Group {
				for member in sym.members {
					check_init_shape(k, item, member)
				}
			}
		}
		if !sym.implicit {
			continue
		}
		if !implicit_conversion_is_valid(k, sym) || !implicit_init_member(k, item.subject, symbol_id) {
			errorf(
				k.c,
				sym.span,
				"L0413",
				"`@(implicit)` needs a one-argument `init` overload whose parameter is a built-in numeric, boolean, rune, or string type",
			)
		}
	}
}

@(private = "file")
implicit_init_member :: proc(k: ^Checker, target: Type_Id, member: Symbol_Id) -> bool {
	init_name := intern_identifier(k.c, "init")
	for candidate in member_candidates(k, target, init_name) {
		if candidate == member {
			return true
		}
	}
	return false
}

@(private = "file")
check_init_shape :: proc(k: ^Checker, item: ^Item_Impl, symbol_id: Symbol_Id) {
	sym := symbol_of(k.c, symbol_id)
	if sym == nil || sym.kind != .Proc {
		return
	}
	if sym.has_receiver || len(sym.results) != 1 || sym.results[0] != item.subject {
		errorf(
			k.c,
			sym.span,
			"L0411",
			"an `init` overload takes no receiver and returns `%s`",
			type_name(k.c, item.subject),
		)
	}
}

@(private = "file")
implicit_conversion_is_valid :: proc(k: ^Checker, sym: ^Symbol) -> bool {
	if sym.kind != .Proc || len(sym.params) != 1 || len(sym.results) != 1 {
		return false
	}
	if sym.results[0] != sym.owner_type {
		return false
	}
	param := sym.params[0]
	if type_kind(k.c, param) == .Distinct {
		return false // a distinct type is not a built-in one an untyped constant reaches
	}
	#partial switch type_kind(k.c, param) {
	case .Int, .Float, .Rune, .Bool, .String, .Untyped_String:
		return true
	}
	return false
}

// ---------------------------------------------------------------- lookup --

// The package whose extension table the declaration being checked may use. It is
// the checker's current package except where a declaration froze its own.
lookup_package :: proc(k: ^Checker) -> Package_Id {
	return k.lookup_pkg == INVALID_PACKAGE ? k.pkg : k.lookup_pkg
}

// Every member of `type` named `name` that this package may use: the type's own
// inherent members, plus the extensions the lookup package declares. Groups are
// expanded, so the overload engine sees one flat candidate set.
member_candidates :: proc(k: ^Checker, type: Type_Id, name: Identifier_Id) -> []Symbol_Id {
	// A built-in iterable's associated members and `iter` are contributed on
	// demand, so interface checking and generic code see exactly what a user type
	// declares by hand (design.md "Iteration protocol").
	ensure_iteration_members(k, type)
	// The generated `try_clone`/`clone` are contributed the same way, so a record
	// without a hand-written hook still has both copy entry points.
	ensure_lifecycle_members(k, type, name)
	// A container's operation set, so `xs.append(1)` is an ordinary method call
	// and generic code finds the same members (design.md "Dynamic arrays").
	ensure_container_members(k, type)
	// And a local region provider's constructor and `allocator`, for the same
	// reason: it is a compiler-owned type whose members no source file declares.
	ensure_provider_members(k, type)
	out := make([dynamic]Symbol_Id, 0, 4, k.c.semantic_allocator)
	if info := type_of(k.c, type); info != nil {
		expand_visible_members(k, type, info.members, name, &out)
	}
	if pkg := package_of(k.c, lookup_package(k)); pkg != nil {
		if members, found := pkg.extensions[type]; found {
			expand_visible_members(k, type, members, name, &out)
		}
	}
	return out[:]
}

// The one symbol-visibility predicate (design.md "Exported names"). Methods,
// operators, associated members, struct fields, and reflection all ask this, so
// no path can expose a declaration another path would hide. The observer is the
// lookup package rather than the package being compiled, which is what lets a
// generic body instantiated elsewhere still see its own definition site.
member_is_visible :: proc(k: ^Checker, sym: ^Symbol) -> bool {
	return sym != nil && (sym.pkg == lookup_package(k) || sym.public)
}

// design.md "Exported names": "Code in the declaring package may read, write,
// and initialize package-visible fields; importing packages may do so only for
// public fields." Ordinary selection, `offset_of`, and both aggregate literal
// forms route through here so they agree with each other and with reflection
// (m5a-plan step 1).
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
	ensure_iteration_members(k, type)
	ensure_lifecycle_members(k, type, name)
	ensure_container_members(k, type)
	ensure_provider_members(k, type)
	if info := type_of(k.c, type); info != nil {
		if found := visible_member_named(k, info.members, name); found != INVALID_SYMBOL {
			return found
		}
	}
	if pkg := package_of(k.c, lookup_package(k)); pkg != nil {
		if members, present := pkg.extensions[type]; present {
			return visible_member_named(k, members, name)
		}
	}
	return INVALID_SYMBOL
}

@(private = "file")
visible_member_named :: proc(k: ^Checker, members: []Symbol_Id, name: Identifier_Id) -> Symbol_Id {
	member := member_named(k, members, name)
	sym := symbol_of(k.c, member)
	return member_is_visible(k, sym) ? member : INVALID_SYMBOL
}

// Does this type have any member named `name`? Used before reporting "no field",
// so the diagnostic can name the real problem.
has_member :: proc(k: ^Checker, type: Type_Id, name: Identifier_Id) -> bool {
	return find_member(k, type, name) != INVALID_SYMBOL
}

// ------------------------------------------- implicit constant conversions --

// The `@(implicit)` one-argument `init` overload on `target` that an untyped
// constant argument can reach, or INVALID_SYMBOL. Ranked below every built-in
// conversion, so a constant always prefers a compatible built-in destination.
implicit_init_overload :: proc(k: ^Checker, arg: Arg_Info, target: Type_Id, report := false) -> (Symbol_Id, bool) {
	if !arg.is_const || !type_is_untyped(k.c, arg.type) {
		return INVALID_SYMBOL, false
	}
	usable := make([dynamic]Symbol_Id, 0, 2, k.c.semantic_allocator)
	for candidate in member_candidates(k, target, intern_identifier(k.c, "init")) {
		sym := symbol_of(k.c, candidate)
		if sym == nil || !sym.implicit || !implicit_conversion_is_valid(k, sym) {
			continue
		}
		// The constant must convert implicitly to that parameter type under the
		// ordinary untyped-constant rule, which is why an untyped float cannot
		// reach an integer-parameter conversion.
		if !assignable(k.c, arg.type, sym.params[0]) {
			continue
		}
		if _, fits := convert_const(k.c, arg.const_value, sym.params[0], false); !fits {
			continue
		}
		append(&usable, candidate)
	}
	if len(usable) == 0 {
		return INVALID_SYMBOL, false
	}
	description := fmt.aprintf("implicit `init` for `%s`", type_name(k.c, target), allocator = k.c.semantic_allocator)
	args := []Arg_Info{arg}
	cand, resolved := resolve_overload(k, arg.span, description, usable[:], args, target, report)
	return resolved ? cand.symbol : INVALID_SYMBOL, true
}

// Wraps `value` in a call to the chosen `@(implicit)` conversion, so the rest of
// the compiler sees an ordinary call and needs no rank-4 special case.
wrap_implicit_conversion :: proc(k: ^Checker, value: Expr, overload: Symbol_Id) -> Expr {
	sym := symbol_of(k.c, overload)
	if sym == nil || len(sym.params) != 1 || len(sym.results) != 1 {
		return value
	}
	if !materialize_argument(k, value, sym.params[0]) {
		return value
	}
	span := expr_span(value)
	callee := new(Expr_Ident, k.c.semantic_allocator)
	callee.span = span
	callee.name = identifier_text(k.c, sym.name)
	callee.name_id = sym.name
	callee.symbol = overload
	callee.type = sym.proc_type
	callee.resolution = Resolution{kind = .Value, symbol = overload}
	callee.value_category = .Value

	bound := make([]Expr, 1, k.c.semantic_allocator)
	bound[0] = value
	call := new(Expr_Call, k.c.semantic_allocator)
	call.span = span
	call.callee = callee
	call.bound = bound
	call.type = sym.results[0]
	call.value_category = .Value
	call.resolution = Resolution{kind = .Call, symbol = overload, chosen_overload = overload}
	return call
}

// ------------------------------------------------------------- backend name --

// `Type.member`, which is what the backend mangles a method or associated
// procedure under. Two impl blocks cannot give one type the same member name, so
// this is unique within a package.
qualified_member_name :: proc(c: ^Compiler, sym: ^Symbol) -> string {
	owner := type_name(c, sym.owner_type)
	// An instantiation carries its own backend spelling, so a member of
	// `Pair(int)` is emitted under `Pair.int.member` rather than through escapes.
	if info := type_of(c, sym.owner_type); info != nil && info.mangled != "" {
		owner = info.mangled
	}
	return fmt.aprintf("%s.%s", owner, identifier_text(c, sym.name))
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

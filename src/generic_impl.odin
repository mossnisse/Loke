// Generic `impl` blocks: kept aside until an instance of their type exists, then
// installed on it, with their members settled against other blocks'.
package lokec

import "core:slice"

// An `impl` block written against a generic type, kept aside until an
// instantiation of that type exists to install it on.
Generic_Impl :: struct {
	item:        ^Item_Impl,
	template:    Symbol_Id,
	using location: Generic_Location,
	// Written arguments, so `impl Table(string, int)` applies to one instance and
	// `impl Table($K, $V)` to every one.
	args:        []Expr,
	specificity: int,
}

Impl_Member_Key :: struct {
	name: Identifier_Id,
	kind: Impl_Kind,
	pkg:  Package_Id, // an extension table's package; none for inherent members
}

Impl_Candidate :: struct {
	symbol: Symbol_Id,
	block:  ^Generic_Impl,
}

// An instantiated `impl` block waiting for its bodies to be checked.
// Signatures are installed as soon as the instance exists, so a method is
// callable right away; bodies wait until the requesting package is finished,
// so a method may itself use the instance.
Pending_Impl :: struct {
	item:      ^Item_Impl,
	using location: Generic_Location,
	// Members another installed block also supplies, reported when the block is
	// checked: installing may happen inside a probe, which would roll them back.
	conflicts: []Impl_Conflict,
}

// A member name two `impl` blocks both give one instance and no use can
// decide: their patterns are equal, the member is not a procedure, or the name
// was already looked up when the later block arrived.
Impl_Conflict :: struct {
	name:  Name,
	other: ^Generic_Impl,
	// The later block is the more specialized, but arrived after a use.
	late:  bool,
}

// Orders `impl` blocks for installation: every written layer counts; `$T` none.
@(private = "file")
pattern_specificity :: proc(e: Expr) -> int {
	specificity, _ := pattern_shape(e)
	return specificity
}

// `impl Table($K, $V)` or `impl Table(string, int)`, kept until an instance
// exists to install it on.
register_generic_impl :: proc(k: ^Checker, item: ^Item_Impl, template: Symbol_Id, args: []Argument) {
	if template not_in k.c.generic_impls {
		k.c.generic_impls[template] = make([dynamic]^Generic_Impl, 0, 2, k.c.semantic_allocator)
	}
	// Inherent in the template's own package, an extension elsewhere.
	owner := symbol_of(k.c, template)
	item.kind = owner != nil && owner.pkg == k.pkg ? .Impl : .Extend

	written := make([]Expr, len(args), k.c.semantic_allocator)
	specificity := 0
	for arg, index in args {
		written[index] = arg.value
		specificity += pattern_specificity(arg.value)
	}
	block := new(Generic_Impl, k.c.semantic_allocator)
	block.item = item
	block.template = template
	block.location = Generic_Location {
		scope      = package_of(k.c, k.pkg).scope,
		pkg        = k.pkg,
		lookup_pkg = k.pkg,
		impl_type  = INVALID_TYPE,
		file       = k.file,
		file_node  = k.file_node,
	}
	block.args = written
	block.specificity = specificity
	register_generic_extension_groups(k, block)
	append(&k.c.generic_impls[template], block)
	item.declared = true
	// A late block still applies to instances that already exist.
	if existing := k.c.generic_templates[template]; existing != nil {
		for instance in existing.instances {
			install_generic_impl_blocks(k, instance, []^Generic_Impl{block})
		}
	}
}

// A generic `impl` subject with the wrong argument count, or a written argument
// that does not resolve, would silently match no instance. A member no instance
// can declare would be silently dropped from all of them.
check_generic_impl_subject :: proc(k: ^Checker, item: ^Item_Impl) {
	call, is_call := item.type.(^Expr_Call)
	if !is_call {
		return
	}
	for arg in call.args {
		for name in pattern_names(arg.value) {
			reject_reserved_name(k, name_identifier(k.c, name), name.span)
		}
	}
	template := generic_template_of_callee(k, call.callee, .Record)
	if template == nil {
		return
	}
	for member in item.members {
		if d, is_decl := member.(^Decl); is_decl {
			require_impl_member_form(k, d)
		}
	}
	if !generic_application_fits(k, call.args, expr_span(item.type), template, true) {
		return
	}
	for arg, index in call.args {
		if type_syntax_has_poly(arg.value) {
			continue
		}
		parameter := template.params[index]
		// The template reports its own parameter types; this only reads one.
		errors := k.c.error_count
		probe := begin_probe(k.c)
		wanted := resolve_type_syntax(k, parameter.type_syntax)
		end_probe(k.c, probe)
		if wanted == TYPE_TYPE || wanted == INVALID_TYPE {
			if resolve_type_syntax(k, arg.value) == INVALID_TYPE && k.c.error_count == errors {
				report_unresolved_type(k, arg.value)
			}
		} else if check_single_expr(k, arg.value, wanted) != INVALID_TYPE {
			require_const(k, arg.value, "a generic argument", "L0432")
		}
	}
}

// A public procedure on a generic extension gets its package name as an empty
// group before any instance exists; instances fill it.
@(private = "file")
register_generic_extension_groups :: proc(k: ^Checker, block: ^Generic_Impl) {
	if block.item.kind != .Extend {
		return
	}
	pkg := package_of(k.c, block.pkg)
	if pkg == nil || pkg.scope == nil {
		return
	}
	for member in block.item.members {
		d, is_decl := member.(^Decl)
		if !is_decl || d.kind != .Const || decl_proc_literal(d) == nil || !declaration_is_public(k, d) {
			continue
		}
		for name in d.names {
			if name.text == "_" {
				continue
			}
			name_id := name_identifier(k.c, name)
			// Never displaces a name the package already owns.
			if _, taken := pkg.scope.names[name_id]; taken {
				continue
			}
			pkg.scope.names[name_id] = new_symbol(k.c, Symbol {
				name          = name_id,
				span          = name.span,
				kind          = .Proc_Group,
				pkg           = block.pkg,
				lookup_pkg    = block.pkg,
				def_scope     = block.scope,
				def_file      = block.file,
				def_file_node = block.file_node,
				public        = true,
				instance_of   = block.template,
			})
		}
	}
}

// Installs every matching block on a fresh instance, most specialized first, so
// a specialized member wins (tie-breaker 5).
install_generic_impls :: proc(k: ^Checker, template: ^Generic_Template, instance: ^Instance) {
	blocks, found := k.c.generic_impls[template.symbol]
	if !found || len(blocks) == 0 {
		return
	}
	ordered := slice.clone(blocks[:], context.temp_allocator)
	slice.stable_sort_by(ordered, proc(a, b: ^Generic_Impl) -> bool {
		return a.specificity > b.specificity
	})
	install_generic_impl_blocks(k, instance, ordered)
}

@(private = "file")
Impl_Install :: struct {
	block:     ^Generic_Impl,
	clone:     ^Item_Impl,
	scope:     ^Scope,
	conflicts: []Impl_Conflict,
}

// design.md "Lifecycle hooks and resource types": a hook counts wherever it is
// written among the blocks. So every member of every block is declared first,
// which makes each hook's role known, and the hooks' bounds are evaluated before
// any other member's: a bound on `helper` that asks `is_copyable` sees a
// `hook(copy)` written after it, in this block or another. A hook's own bound
// that asks gets what is known so far (`Type_Info.hooks_resolving`).
@(private = "file")
install_generic_impl_blocks :: proc(k: ^Checker, instance: ^Instance, blocks: []^Generic_Impl) {
	installs := make([dynamic]Impl_Install, 0, len(blocks), context.temp_allocator)
	set_hooks_resolving(k.c, instance.type, true)
	for block in blocks {
		if install, matched := declare_generic_impl_block(k, instance, block); matched {
			append(&installs, install)
		}
	}
	for install in installs {
		resolve_instance_impl_members(k, instance, install, hooks = true)
	}
	set_hooks_resolving(k.c, instance.type, false)
	for install in installs {
		resolve_instance_impl_members(k, instance, install, hooks = false)
	}
	for install in installs {
		location := impl_install_location(instance, install)
		saved := enter_generic_location(k, location)
		// Groups go last: a group declared before its members must not take one in
		// before its bound has excluded it.
		for member in install.clone.members {
			if d, is_decl := member.(^Decl); is_decl && decl_is_proc_group(d) {
				resolve_declaration_signature(k, d)
			}
		}
		for member in install.clone.members {
			if delegate, is_delegate := member.(^Item_Delegate); is_delegate {
				check_delegate(k, delegate, instance.type, install.clone.kind, location.pkg)
			}
		}
		append(&k.c.pending_impl_instances, Pending_Impl{item = install.clone, location = location, conflicts = install.conflicts})
		k.location = saved
	}
}

// Reacquires the type: resolving a member may grow the type store.
@(private = "file")
set_hooks_resolving :: proc(c: ^Compiler, type: Type_Id, resolving: bool) {
	if info := type_of(c, type); info != nil {
		info.hooks_resolving = resolving
	}
}

@(private = "file")
impl_install_location :: proc(instance: ^Instance, install: Impl_Install) -> Generic_Location {
	location := install.block.location
	location.scope = install.scope
	location.impl_type = instance.type
	return location
}

// The block's lifecycle hooks, or its other members that are not groups, each
// with its bound.
@(private = "file")
resolve_instance_impl_members :: proc(k: ^Checker, instance: ^Instance, install: Impl_Install, hooks: bool) {
	saved := enter_generic_location(k, impl_install_location(instance, install))
	defer k.location = saved
	for member in install.clone.members {
		d, is_decl := member.(^Decl)
		if !is_decl || decl_is_proc_group(d) {
			continue
		}
		if decl_is_lifecycle_hook(d) == hooks {
			resolve_declaration_signature(k, d)
			exclude_member_on_failed_bound(k, d)
		}
	}
}

@(private = "file")
declare_generic_impl_block :: proc(k: ^Checker, instance: ^Instance, block: ^Generic_Impl) -> (install: Impl_Install, matched: bool) {
	if len(block.args) != len(instance.bindings) {
		return
	}
	scope := new_scope(k.c, block.scope, .Local)
	scope.instance = instance
	location := block.location
	location.scope = scope
	saved := enter_generic_location(k, location)
	defer k.location = saved

	// A written argument that differs from the bound one skips this instance;
	// `check_generic_impl_subject` reports one that could never match, so each
	// comparison here is a speculation whose diagnostics are rolled back. A
	// pattern binds its `$` names as a parameter's does, so `impl Pair($T, $T)`
	// needs both arguments equal and `impl Box([]$E)` binds `E`.
	bindings := make([dynamic]Generic_Binding, 0, len(block.args), context.temp_allocator)
	for written, index in block.args {
		bound := instance.bindings[index].arg
		has_poly := type_syntax_has_poly(written)
		if has_poly && !match_generic_arg(k, written, bound, scope, &bindings) {
			return
		}
		// The matcher binds the `$` names and leaves concrete parts to overload
		// ranking, which installation never reaches: `[2]$E` must not take `[3]int`,
		// nor `Pair(int, $T)` take `Pair(bool, int)`.
		if bound.is_type {
			probe := begin_probe(k.c)
			resolved := resolve_type_syntax(k, written)
			end_probe(k.c, probe)
			if resolved != bound.type {
				return
			}
			continue
		}
		if has_poly {
			continue
		}
		folded, evaluated := Const_Value{}, false
		probe := begin_probe(k.c)
		if check_single_expr(k, written, bound.value_type) != INVALID_TYPE {
			folded, evaluated = require_const(k, written, "a generic argument", "L0432")
			if evaluated {
				folded, evaluated = convert_const(k.c, folded, bound.value_type, false)
			}
		}
		end_probe(k.c, probe)
		if !evaluated {
			return
		}
		if !generic_arg_equal(k.c, Generic_Arg{value = folded, value_type = bound.value_type}, bound) {
			return
		}
	}

	clone := clone_item(k.c, block.item).(^Item_Impl)
	clone.subject = instance.type
	clone.declared = true
	k.impl_type = instance.type
	conflicts := declare_instance_impl_members(k, clone, instance, block)
	return Impl_Install{block = block, clone = clone, scope = scope, conflicts = conflicts}, true
}

decl_is_proc_group :: proc(d: ^Decl) -> bool {
	if len(d.values) != 1 {
		return false
	}
	_, is_group := d.values[0].(^Expr_Proc_Group)
	return is_group
}

// design.md "where clauses": a method whose bound fails is dropped from that
// instance, as `Small_Array` drops copying methods for a move-only `T`.
// Evaluated beside the signature, since calls resolve before bodies.
@(private = "file")
exclude_member_on_failed_bound :: proc(k: ^Checker, d: ^Decl) {
	literal := decl_proc_literal(d)
	if literal == nil || len(literal.where_clauses) == 0 {
		return
	}
	// A method with its own generic parameters is a generic procedure, whose
	// bounds may name those parameters; they are evaluated when a call
	// instantiates it.
	if proc_signature_is_generic(literal) {
		return
	}
	if len(d.symbols) == 0 || d.symbols[0] == INVALID_SYMBOL {
		return
	}
	symbol := symbol_of(k.c, d.symbols[0])
	if symbol == nil {
		return
	}
	name := identifier_text(k.c, symbol.name)
	// A malformed bound is reported and keeps the member, rather than removing it
	// over a typo.
	errors := k.c.error_count
	ok := check_where_clauses(
		k, literal.where_clauses, literal.span, name, report = false, report_malformed = true,
	)
	if !ok && k.c.error_count == errors {
		symbol.bound_excluded = true
	}
}

// Members of an instantiated block. A name a more specialized block already
// supplied is left alone; one this block is more specialized than every
// supplier of is taken over; a crossed one is kept beside the others for a use
// to find ambiguous (design.md "Generic types": tie-breaker 5).
@(private = "file")
declare_instance_impl_members :: proc(k: ^Checker, item: ^Item_Impl, instance: ^Instance, block: ^Generic_Impl) -> []Impl_Conflict {
	subject := instance.type
	conflicts := make([dynamic]Impl_Conflict, 0, 0, k.c.semantic_allocator)
	added := make([dynamic]Symbol_Id, 0, len(item.members), k.c.semantic_allocator)
	for member in item.members {
		d, is_decl := member.(^Decl)
		if !is_decl || d.kind != .Const {
			continue
		}
		symbols := make([dynamic]Symbol_Id, 0, len(d.names), k.c.semantic_allocator)
		d.top_level = true
		for name in d.names {
			if name.text == "_" {
				append(&symbols, INVALID_SYMBOL)
				continue
			}
			name_id := name_identifier(k.c, name)
			key := Impl_Member_Key{name = name_id, kind = item.kind, pkg = item.kind == .Impl ? INVALID_PACKAGE : block.pkg}
			current := member_named(k.c, impl_member_table(k, item.kind, subject, block.pkg), name_id)
			if current != INVALID_SYMBOL {
				// A name from outside the generic blocks keeps its meaning.
				candidates, _ := instance.impl_candidates[key]
				if len(candidates) == 0 || !admit_impl_candidate(k, candidates[:], block, current, name, d, &conflicts) {
					append(&symbols, INVALID_SYMBOL)
					continue
				}
			}
			if clash := impl_member_clash(k, subject, name.text, name_id, added[:]); clash != "" {
				errorf(k.c, name.span, "L0409", "`%s` already has a %s `%s`", type_name(k.c, subject), clash, name.text)
				append(&symbols, INVALID_SYMBOL)
				continue
			}
			id := new_impl_member(k, d, name, name_id, subject, block.pkg)
			// design.md "Methods and implementation blocks": a public extension
			// procedure also gets its plain package-qualified spelling. A constant
			// has none, since each instance gives it its own value.
			member := symbol_of(k.c, id)
			if item.kind == .Extend && member.public && member.kind == .Proc {
				register_instance_extension_name(k, block, name_id, id)
			}
			append(&symbols, id)
			if current == INVALID_SYMBOL {
				append(&added, id)
			}
			settle_impl_candidates(k, instance, key, Impl_Candidate{symbol = id, block = block}, current, name.span)
		}
		d.symbols = symbols[:]
	}
	install_impl_members(k, item.kind, subject, added[:], block.pkg)
	return conflicts[:]
}

// Whether `block`'s member may join the candidates for a name the table already
// has as `current`. A more specialized supplier makes it lose silently; an equal
// one, a crossed constant, or a use already made of `current` is a conflict.
@(private = "file")
admit_impl_candidate :: proc(
	k: ^Checker, candidates: []Impl_Candidate, block: ^Generic_Impl, current: Symbol_Id,
	name: Name, d: ^Decl, conflicts: ^[dynamic]Impl_Conflict,
) -> bool {
	dominates_all := true
	for candidate in candidates {
		switch impl_block_relation(candidate.block, block) {
		case .Left:
			return false
		case .Equal:
			append(conflicts, Impl_Conflict{name = name, other = candidate.block})
			return false
		case .Crossed:
			dominates_all = false
			if decl_proc_literal(d) == nil || symbol_of(k.c, candidate.symbol).kind != .Proc {
				append(conflicts, Impl_Conflict{name = name, other = candidate.block})
				return false
			}
		case .Right:
		}
	}
	if symbol_of(k.c, current).looked_up {
		append(conflicts, Impl_Conflict{name = name, other = candidates[0].block, late = dominates_all})
		return false
	}
	return true
}

// Adds `candidate`, supersedes every candidate its block is more specialized
// than, and puts the survivor, or a group of the crossed survivors, in the
// table where `current` was.
@(private = "file")
settle_impl_candidates :: proc(k: ^Checker, instance: ^Instance, key: Impl_Member_Key, candidate: Impl_Candidate, current: Symbol_Id, span: Span) {
	survivors := make([dynamic]Impl_Candidate, 0, 2, k.c.semantic_allocator)
	previous, _ := instance.impl_candidates[key]
	for other in previous {
		if impl_block_relation(candidate.block, other.block) == .Left {
			// Never checked or emitted for this instance.
			symbol_of(k.c, other.symbol).superseded = true
			continue
		}
		append(&survivors, other)
	}
	append(&survivors, candidate)
	instance.impl_candidates[key] = survivors
	if current == INVALID_SYMBOL {
		return
	}
	entry := candidate.symbol
	if len(survivors) > 1 {
		members := make([]Symbol_Id, len(survivors), k.c.semantic_allocator)
		public := false
		for survivor, index in survivors {
			members[index] = survivor.symbol
			public ||= symbol_of(k.c, survivor.symbol).public
		}
		entry = new_symbol(k.c, Symbol {
			name        = key.name,
			span        = span,
			kind        = .Proc_Group,
			pkg         = candidate.block.pkg,
			lookup_pkg  = candidate.block.pkg,
			owner_type  = instance.type,
			public      = public,
			members     = members,
		})
	}
	replace_impl_member(k, key.kind, instance.type, candidate.block.pkg, current, entry)
}

@(private = "file")
impl_block_member_name :: proc(k: ^Checker, block: ^Generic_Impl, name: Identifier_Id) -> ^Name {
	for member in block.item.members {
		if d, is_decl := member.(^Decl); is_decl && d.kind == .Const {
			for &written in d.names {
				if name_identifier(k.c, written) == name {
					return &written
				}
			}
		}
	}
	return nil
}

// `.Left` when `a` is the more specialized block, `.Right` when `b` is.
@(private = "file")
impl_block_relation :: proc(a, b: ^Generic_Impl) -> Pattern_Relation {
	return pattern_relations(a.args, b.args)
}

// The package-qualified name of a public procedure of an instantiated `extend`
// block: each instance adds its own to the group `register_generic_extension_groups`
// gave the name. A name the package already uses for something else keeps its
// meaning.
@(private = "file")
register_instance_extension_name :: proc(k: ^Checker, block: ^Generic_Impl, name: Identifier_Id, member: Symbol_Id) {
	pkg := package_of(k.c, block.pkg)
	if pkg == nil || pkg.scope == nil {
		return
	}
	sym := symbol_of(k.c, pkg.scope.names[name])
	if sym == nil || sym.kind != .Proc_Group || sym.instance_of != block.template {
		return
	}
	members := make([]Symbol_Id, len(sym.members) + 1, k.c.semantic_allocator)
	copy(members, sym.members)
	members[len(sym.members)] = member
	sym.members = members
}

// Positions the checker in the instantiated block that declares `sym`, as
// `check_pending_impl_instances` will: a compile-time call can need a member's
// body before that pass reaches it. False for any other symbol. The caller
// restores its own location.
enter_instance_impl_member :: proc(k: ^Checker, sym: ^Symbol) -> bool {
	scope := sym.def_scope
	if sym.instance_of != INVALID_SYMBOL || sym.owner_type == INVALID_TYPE || scope == nil ||
	   scope.instance == nil || scope.instance.type != sym.owner_type {
		return false
	}
	enter_generic_location(k, Generic_Location {
		scope      = scope,
		pkg        = sym.pkg,
		lookup_pkg = sym.lookup_pkg,
		impl_type  = sym.owner_type,
		file       = sym.def_file,
		file_node  = sym.def_file_node,
	})
	return true
}

pend_template_private_read :: proc(k: ^Checker, template: ^Generic_Template, scope: ^Scope) {
	location := template.location
	location.scope = scope
	append(&k.c.pending_private_reads, Pending_Private_Read{decl = template.decl, location = location})
}

// The block instances discovered so far are checked after the package that
// requested them, so a method's body sees every instantiation its own signature
// created.
check_pending_impl_instances :: proc(k: ^Checker) {
	for {
		for k.c.next_pending_impl < len(k.c.pending_impl_instances) {
			pending := k.c.pending_impl_instances[k.c.next_pending_impl]
			k.c.next_pending_impl += 1
			check_pending_impl_instance(k, pending)
		}
		check_deferred_escape_parts(k)

		if len(k.c.pending_private_reads) == 0 {
			return
		}
		for index := 0; index < len(k.c.pending_private_reads); index += 1 {
			read := k.c.pending_private_reads[index]
			saved := enter_generic_location(k, read.location)
			check_generic_private_names(k, read)
			k.location = saved
		}
		clear(&k.c.pending_private_reads)
		// What those reads selected may have instantiated a block.
	}
}

@(private = "file")
check_pending_impl_instance :: proc(k: ^Checker, pending: Pending_Impl) {
	saved := enter_generic_location(k, pending.location)
	defer k.location = saved
	report_impl_conflicts(k, pending)
	for member in pending.item.members {
		if d, is_decl := member.(^Decl); is_decl {
			check_decl(k, d)
		}
	}
	validate_instance_hooks(k, pending.item)
	// Each constant has its type now.
	check_instance_private_names(k, pending)
	enroll_impl_members(k, pending)
}

@(private = "file")
report_impl_conflicts :: proc(k: ^Checker, pending: Pending_Impl) {
	for conflict in pending.conflicts {
		subject := type_name(k.c, pending.impl_type)
		if conflict.late {
			errorf(
				k.c, conflict.name.span, "L0409",
				"`%s` already has a member `%s`: this block is more specialized, but it is declared after `%s` was first used",
				subject, conflict.name.text, subject,
			)
		} else {
			errorf(
				k.c, conflict.name.span, "L0409",
				"`%s` gets a member `%s` from two `impl` blocks, and neither is more specialized",
				subject, conflict.name.text,
			)
		}
		if other := impl_block_member_name(k, conflict.other, name_identifier(k.c, conflict.name)); other != nil {
			add_notef(k.c, other.span, "the other `%s` is declared here", conflict.name.text)
		}
	}
}

// Queues the block's procedures for emission with their package's items.
@(private = "file")
enroll_impl_members :: proc(k: ^Checker, pending: Pending_Impl) {
	pkg := package_of(k.c, pending.pkg)
	if pkg == nil {
		return
	}
	for member in pending.item.members {
		d, is_decl := member.(^Decl)
		if !is_decl || len(d.symbols) == 0 || d.symbols[0] == INVALID_SYMBOL || decl_proc_literal(d) == nil {
			continue
		}
		sym := symbol_of(k.c, d.symbols[0])
		// A method whose bound did not hold, or that a more specialized block
		// replaced, is not part of this instantiation: its body was never
		// checked, so there is no body to emit.
		if sym != nil && (sym.bound_excluded || sym.superseded) {
			continue
		}
		append(&pkg.instances, Instance_Decl{symbol = d.symbols[0], decl = d})
	}
}

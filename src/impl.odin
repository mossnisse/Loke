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
//
// Resolving a subject can instantiate a generic, whose bounds ask for methods
// that blocks not declared yet supply. So a block is declared without resolving
// anything wherever it can be: one on a generic application waits for the
// instances, and one whose subject `resolve_type_shell` reads is declared on
// that. `unresolved_only` declares those and leaves any other block for a
// later call, once they are all declared. The blocks left are declared from a
// queue (`declare_queued_impl_blocks`), where a lookup that a subject leads to
// declares the blocks it needs first.
declare_impl_block :: proc(k: ^Checker, item: ^Item_Impl, quiet := true, unresolved_only := false) {
	if item.declared || item.declaring {
		return
	}
	item.declaring = true
	defer item.declaring = false
	// A block on a generic type waits for an instantiation to install it on.
	if call := impl_subject_application(k, item); call != nil {
		if template := generic_template_of_callee(k, call.callee, {.Record}); template != nil {
			register_generic_impl(k, item, template.symbol, call.args)
			return
		}
		// design.md "Parametric aliases": a block over every application of an
		// alias would bind names in two packages' scopes at once; one over a
		// single application, `impl Io_Result(int)`, is a block on that type.
		if template := generic_template_of_callee(k, call.callee, {.Alias}); template != nil && type_syntax_has_poly(item.type) {
			item.declared = true
			errorf(
				k.c, expr_span(item.type), "L0746",
				"an `impl` subject cannot apply a parametric alias to `$` names; write the generic type it stands for",
			)
			return
		}
	}

	// A subject read as a shell resolves nothing. Any other quiet attempt that
	// fails is rolled back and retried, so it is a speculation: it must not claim
	// a report-once cache the retry needs.
	probe := begin_probe(k.c)
	subject := resolve_type_shell(k, item.type)
	end_probe(k.c, probe, keep = subject != INVALID_TYPE)
	switch {
	case subject != INVALID_TYPE:
		item.on_shell = true
	case unresolved_only:
		return
	case quiet:
		visited := make(map[Symbol_Id]bool, 8, context.temp_allocator)
		if subject_may_need_operator(k, item.type, k.scope, &visited) {
			return
		}
		probe = begin_probe(k.c)
		subject = resolve_type_syntax(k, item.type)
		end_probe(k.c, probe, keep = subject != INVALID_TYPE)
		if subject == INVALID_TYPE {
			return
		}
	case:
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
	defer_delegates(k, item)
}

// The file-scope blocks a phase declares by resolving each one's subject, and
// whether a subject that does not resolve is left for a later attempt (`quiet` of
// `declare_impl_block`).
Impl_Queue :: struct {
	blocks: []Pending_Block,
	quiet:  bool,
}

// Declares `blocks` in the order given. Resolving one's subject can instantiate
// a generic whose bound asks for the members of a type that a block further on
// gives it, so a lookup of a type's members declares those blocks first
// (`declare_impl_blocks_on`), and the order blocks are written in does not
// decide whether a bound holds (design.md "when statement").
declare_queued_impl_blocks :: proc(k: ^Checker, blocks: []Pending_Block, quiet: bool) {
	saved_queue, saved_location := k.c.impl_queue, k.location
	k.c.impl_queue = {blocks, quiet}
	defer k.c.impl_queue, k.location = saved_queue, saved_location
	for entry in blocks {
		k.location = entry.location
		declare_impl_block(k, entry.item, quiet)
	}
}

// Declares, ahead of its turn, each queued block whose subject may be written
// for `type` (`type_syntax_may_denote`), so a lookup of the members of `type`
// finds what its package gives it wherever the blocks are written. Only those:
// a block on another type may need, for its own subject, the very block whose
// subject led here, and would be rejected for good if it were tried now. A
// block whose subject is being resolved further up is left to finish there; a
// lookup its own subject makes is one it cannot answer.
//
// These are declared at file scope, so a probe that led here does not take them
// with it (`begin_settling_file_scope`).
declare_impl_blocks_on :: proc(k: ^Checker, type: Type_Id) {
	queue := k.c.impl_queue
	if len(queue.blocks) == 0 {
		return
	}
	saved := k.location
	defer k.location = saved
	for entry in queue.blocks {
		if entry.item.declared || entry.item.declaring {
			continue
		}
		// Read where the block is written, as its subject will be resolved.
		k.location = entry.location
		if !type_syntax_may_denote(k, entry.item.type, type) {
			continue
		}
		settling := begin_settling_file_scope(k.c)
		declare_impl_block(k, entry.item, queue.quiet)
		end_settling(k.c, settling)
	}
}

// The generic application a block's subject is, or nil: written, as
// `impl Table($K, $V)` is, or the declaration of an alias the subject names, as
// for `impl Names` after `Names :: Table(string, int)`. The alias is read as it
// is written, since evaluating it would instantiate the type and ask its bounds
// while the blocks that meet them may not be declared; the block is then one on
// `Table(string, int)`, installed whenever that instance comes to exist.
impl_subject_application :: proc(k: ^Checker, item: ^Item_Impl) -> ^Expr_Call {
	if item.applies != nil {
		return item.applies
	}
	if call, is_call := item.type.(^Expr_Call); is_call {
		return call
	}
	ident, is_ident := item.type.(^Expr_Ident)
	// A body-local block names a type declared in its body, never an instance.
	if !is_ident || k.scope == nil || k.scope.kind != .Package {
		return nil
	}
	target := shell_name_target(k, ident)
	call, is_call := target.value.(^Expr_Call)
	// An alias in this package's scope, where the block's own names are read too.
	// A parametric alias's bare name names nothing (design.md "Parametric aliases"),
	// so a block on it is resolved, and reported, as written.
	if !is_call || target.scope != k.scope || type_syntax_has_poly(call) {
		return nil
	}
	template := generic_template_of_callee(k, call.callee, {.Record})
	if template == nil {
		return nil
	}
	ident.symbol = target.named
	item.applies, item.template = call, template.symbol
	return call
}

// The alias a block's subject names denotes its type once the alias is checked,
// which a block declared from the alias's syntax never asked.
@(private = "file")
denote_alias_subject :: proc(k: ^Checker, item: ^Item_Impl) {
	ident, is_ident := item.type.(^Expr_Ident)
	if item.applies == nil || !is_ident {
		return
	}
	if type := const_type_value(k, ident.symbol); type != INVALID_TYPE {
		mark_denotes_type(&ident.base, type, ident.symbol)
	}
}

// What a block declared on its subject's shell could not ask: whether the
// subject's own declaration, resolved by now, gives a member's name another
// meaning. Such a member is withdrawn, as `declare_impl_member` never makes one.
@(private = "file")
reject_shell_clashes :: proc(k: ^Checker, item: ^Item_Impl) {
	if !item.on_shell {
		return
	}
	item.on_shell = false
	info := type_of(k.c, item.subject)
	if info == nil {
		return
	}
	resolve_symbol_signature_in_place(k, info.symbol)
	for member in item.members {
		d, is_decl := member.(^Decl)
		if !is_decl || len(d.symbols) != len(d.names) {
			continue
		}
		for &id, index in d.symbols {
			sym := symbol_of(k.c, id)
			if sym == nil {
				continue
			}
			name := d.names[index]
			clash := impl_member_clash(k, item.subject, name.text, sym.name, nil)
			if clash == "" {
				continue
			}
			errorf(
				k.c, name.span, "L0409",
				"`%s` already has a %s `%s`", type_name(k.c, item.subject), clash, name.text,
			)
			withdraw_impl_member(k, item.kind, item.subject, k.pkg, id)
			id = INVALID_SYMBOL
		}
	}
}

// `resolve_type_syntax` reports nothing for a subject that names no type at all.
@(private = "file")
resolve_impl_subject :: proc(k: ^Checker, item: ^Item_Impl) -> Type_Id {
	errors := k.c.error_count
	subject := resolve_type_syntax(k, item.type)
	if subject == INVALID_TYPE && k.c.error_count == errors && !expr_has_error(item.type) {
		errorf(k.c, expr_span(item.type), "L0406", "this `impl` subject does not name a type")
	}
	return subject
}

// Whether resolving a subject may ask for an operator, as `[N]int` does where
// `N :: a + b`. Whatever asks settles that constant for the program, and the blocks
// declaring operators are not all declared yet, so a quiet attempt leaves these alone
// until `resolve_package_operators` has them queued.
@(private = "file")
subject_may_need_operator :: proc(k: ^Checker, e: Expr, scope: ^Scope, visited: ^map[Symbol_Id]bool) -> bool {
	if e == nil {
		return false
	}
	#partial switch v in e {
	case ^Expr_Binary, ^Expr_Unary, ^Expr_Composite, ^Expr_Index, ^Expr_Slice:
		return true
	case ^Expr_Ident:
		return symbol_may_need_operator(k, lookup_symbol(scope, identifier_of(k.c, v)), visited)
	case ^Expr_Selector:
		// A member of another package is asked about there.
		if ident, is_ident := v.operand.(^Expr_Ident); is_ident {
			if alias := symbol_of(k.c, lookup_symbol(scope, identifier_of(k.c, ident))); alias != nil && alias.kind == .Package_Alias {
				pkg := package_of(k.c, alias.pkg)
				return pkg != nil && pkg.scope != nil && symbol_may_need_operator(k, pkg.scope.names[intern_identifier(k.c, v.name.text)], visited)
			}
		}
	}
	Walk :: struct {
		k:       ^Checker,
		scope:   ^Scope,
		visited: ^map[Symbol_Id]bool,
	}
	walk := Walk{k, scope, visited}
	return expr_children(e, &walk, proc(data: rawptr, child: Expr) -> bool {
		w := (^Walk)(data)
		return subject_may_need_operator(w.k, child, w.scope, w.visited)
	})
}

@(private = "file")
symbol_may_need_operator :: proc(k: ^Checker, id: Symbol_Id, visited: ^map[Symbol_Id]bool) -> bool {
	sym := symbol_of(k.c, id)
	if sym == nil || visited[id] {
		return false
	}
	visited[id] = true
	#partial switch sym.kind {
	case .Proc, .Proc_Group:
		return true
	case .Const:
		return sym.decl != nil && subject_may_need_operator(k, decl_value(sym.decl), sym.def_scope, visited)
	}
	return false
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
	validate_impl_attributes(k, item, .Local)
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
// stay visible from the statement on (design.md "Methods and implementation blocks").
declare_local_impl_hooks :: proc(k: ^Checker, item: ^Item_Impl, subject: Type_Id) {
	item.subject = subject
	item.kind = .Impl
	declare_impl_members(k, item, hooks_only = true)
}

// The blocks `declare_local_impl_hooks` cannot reach are in a `when` whose
// condition cannot be answered where the record is declared, and in a static
// `foreach` body, which each expansion checks as a copy of its own. If the record's
// lifecycle was already read, copies may have been decided without this hook, so
// running it now could release a value twice (design.md "Lifecycle hooks and
// resource types").
@(private = "file")
reject_unhoisted_local_hook :: proc(k: ^Checker, d: ^Decl, subject: Type_Id) {
	if !decl_is_lifecycle_hook(d) || len(d.symbols) > 0 {
		return
	}
	if _, read := k.c.lifecycles[type_underlying(k.c, subject)]; read {
		errorf(
			k.c, d.span, "L0488",
			"`hook(%s)` comes too late: `%s` was already used, and this block could not be found where `%s` is declared",
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
		clash := impl_member_clash(k, item.subject, name.text, name_id, out[:])
		if previous != nil {
			clash = generated ? "generated member" : "member"
		}
		if clash != "" {
			errorf(
				k.c, name.span, "L0409",
				"`%s` already has a %s `%s`", type_name(k.c, item.subject), clash, name.text,
			)
			// design.md "Methods and implementation blocks": a body-local block
			// cannot take a name an earlier use generated.
			if generated {
				add_notef(k.c, item.span, "a use ahead of this block generated it, so write the block before that use")
			}
			append(&symbols, INVALID_SYMBOL)
			continue
		}
		id := new_impl_member(k, d, name, name_id, item.subject, k.pkg)
		append(&symbols, id)
		append(out, id)
		// A public extension is also reachable as `adapter.member(value)`.
		if item.kind == .Extend && symbol_of(k.c, id).public {
			bind_member_in_package(k, name, name_id, id)
		}
	}
	d.symbols = symbols[:]
}

// What L0409 calls the name `subject` already gives another meaning, or "" if it
// is free among `added`, the members the block has declared so far.
impl_member_clash :: proc(k: ^Checker, subject: Type_Id, name: string, name_id: Identifier_Id, added: []Symbol_Id) -> string {
	switch {
	case member_named(k.c, added, name_id) != INVALID_SYMBOL:
		return "member"
	// `c.v` selects the field, so a member of that name could never be reached.
	case field_named(k.c, subject, name_id) != INVALID_SYMBOL:
		return "field"
	case (type_is_enum(k.c, subject) && enum_builtin_member(name)) || (type_is_union(k.c, subject) && name == "as"):
		return "built-in member"
	}
	return ""
}

new_impl_member :: proc(k: ^Checker, d: ^Decl, name: Name, name_id: Identifier_Id, subject: Type_Id, pkg: Package_Id) -> Symbol_Id {
	is_proc := decl_proc_literal(d) != nil
	return new_symbol(k.c, Symbol {
		name          = name_id,
		span          = name.span,
		decl          = d,
		pkg           = pkg,
		lookup_pkg    = pkg,
		owner_type    = subject,
		public        = declaration_is_public(k, d),
		hook          = decl_hook_kind(d),
		kind          = is_proc ? Symbol_Kind.Proc : Symbol_Kind.Const,
		type          = is_proc ? TYPE_VOID : INVALID_TYPE,
		def_scope     = k.scope,
		def_file      = k.file,
		def_file_node = k.file_node,
	})
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
	if existing, taken := k.scope.names[name_id]; taken {
		// A generic extension's group only reserves the name: a name the package uses
		// for something else keeps that meaning, whichever block is declared first and
		// whether or not an instance has joined the group yet, as one does when another
		// package instantiated the type first. Once displaced, the group takes no more
		// instances (`register_instance_extension_name`).
		group := symbol_of(k.c, existing)
		if group == nil || group.kind != .Proc_Group || group.instance_of == INVALID_SYMBOL {
			errorf(k.c, name.span, "L0304", "`%s` is already declared in this package", name.text)
			return
		}
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

// Takes `member` out of the table `impl_member_table` reads.
@(private = "file")
withdraw_impl_member :: proc(k: ^Checker, kind: Impl_Kind, subject: Type_Id, in_pkg: Package_Id, member: Symbol_Id) {
	previous := impl_member_table(k, kind, subject, in_pkg)
	kept := make([dynamic]Symbol_Id, 0, len(previous), k.c.semantic_allocator)
	for entry in previous {
		if entry != member {
			append(&kept, entry)
		}
	}
	if kind == .Impl {
		if info := type_of(k.c, subject); info != nil {
			info.members = kept[:]
		}
	} else if pkg := package_of(k.c, in_pkg); pkg != nil {
		pkg.extensions[subject] = kept[:]
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
	reject_shell_clashes(k, item)
	outer := k.impl_type
	k.impl_type = item.subject
	defer k.impl_type = outer
	for member in item.members {
		if d, is_decl := member.(^Decl); is_decl {
			resolve_declaration_signature(k, d)
		}
	}
	settle_delegates(k, item.subject)
}

check_impl_block :: proc(k: ^Checker, item: ^Item_Impl) {
	if item.subject == INVALID_TYPE {
		// A generic block's members are checked per instance, but a public
		// constant's type may be the same in all of them.
		if call := impl_subject_application(k, item); call != nil {
			if template := generic_template_of_callee(k, call.callee, {.Record}); template != nil {
				read_generic_impl_constants(k, item, call, template)
				check_generic_impl_hooks(k, item, template)
				denote_alias_subject(k, item)
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
// declared them, after the hand-written blocks still waiting to be declared.
@(private = "file")
ensure_contributed_members :: proc(k: ^Checker, type: Type_Id, name: Identifier_Id) {
	declare_impl_blocks_on(k, type)
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
// overload engine, in temporary memory: a caller that keeps the list copies it.
member_candidates :: proc(k: ^Checker, type: Type_Id, name: Identifier_Id) -> []Symbol_Id {
	ensure_contributed_members(k, type, name)
	out := make([dynamic]Symbol_Id, 0, 4, context.temp_allocator)
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

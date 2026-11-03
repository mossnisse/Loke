// Checks hook declarations where they are written (design.md "Lifecycle hooks
// and resource types", "Conversion hooks").
package lokec

resolve_hook_declaration :: proc(k: ^Checker, d: ^Decl, value: ^Expr_Operator) {
	symbol_id := d.symbols[0]
	sym := symbol_of(k.c, symbol_id)
	sym.hook = value.hook
	literal, ok := value.value.(^Expr_Proc)
	if !ok {
		return
	}
	sym.kind = .Proc
	literal.symbol = symbol_id
	resolve_proc_signature(k, literal, symbol_id)
	apply_proc_metadata(k, d, symbol_id)
	if k.impl_type == INVALID_TYPE {
		// Re-read: resolving may have grown the symbol table.
		errorf(k.c, symbol_of(k.c, symbol_id).span, "L0488", "`hook(%s)` is a type role and must be declared as an inherent `impl` member", hook_name(value.hook))
	}
}

// The conversion a generic template declares, so `conversion_hooks` finds it and
// overload resolution instantiates it, as for a generic method. A generic
// lifecycle hook is left to `validate_semantic_hook`, which rejects it: its
// signature is fixed by its subject.
mark_template_hook :: proc(k: ^Checker, d: ^Decl) {
	if d.kind != .Const || len(d.values) != 1 {
		return
	}
	value, is_hook := d.values[0].(^Expr_Operator)
	if !is_hook || value.hook != .Convert {
		return
	}
	sym := symbol_of(k.c, d.symbols[0])
	if sym == nil {
		return
	}
	if k.impl_type == INVALID_TYPE {
		errorf(k.c, sym.span, "L0488", "`hook(convert)` is a type role and must be declared as an inherent `impl` member")
		return
	}
	sym.hook = value.hook
}

// Checked where each inherent declaration is written.
validate_semantic_hook :: proc(k: ^Checker, item: ^Item_Impl, sym: ^Symbol, symbol_id: Symbol_Id) {
	if sym.hook == .None {
		name := identifier_text(k.c, sym.name)
		if name == "clone" || name == "try_clone" {
			errorf(k.c, sym.span, "L0487", "`%s` is a compiler-generated copy operation; bind custom behavior with `hook(copy)`", name)
		}
		return
	}
	if hook_may_be_declared(k, item, sym) && !report_duplicate_hook(k, sym, symbol_id, item.subject) {
		check_hook_role(k, sym, item.subject)
	}
}

// Whether this kind of block may declare a hook on its subject.
@(private = "file")
hook_may_be_declared :: proc(k: ^Checker, item: ^Item_Impl, sym: ^Symbol) -> bool {
	subject := item.subject
	info := type_of(k.c, subject)
	if sym.hook != .Convert {
		if info != nil && info.kind == .Distinct && underlying_kind(k.c, subject) == .Struct {
			errorf(k.c, sym.span, "L0488", "`hook(%s)` cannot be declared on `distinct` `%s`, which shares the lifecycle of `%s`", hook_name(sym.hook), type_name(k.c, subject), type_name(k.c, type_underlying(k.c, subject)))
			return false
		}
		if info == nil || info.kind != .Struct {
			errorf(k.c, sym.span, "L0488", "`hook(%s)` is a record lifecycle role; `%s` is not a record type", hook_name(sym.hook), type_name(k.c, subject))
			return false
		}
	}
	if item.kind == .Extend {
		// No package declares a structural record, so only a declared one can
		// carry a hook (design.md "Methods and implementation blocks").
		if info != nil && info.anonymous_record {
			errorf(
				k.c,
				sym.span,
				"L0486",
				"an anonymous record has no declaring package, so `hook(%s)` cannot be added to `%s`; declare a struct to give it one",
				hook_name(sym.hook),
				type_name(k.c, subject),
			)
			return false
		}
		report_extension_hook(k, sym.span, type_name(k.c, subject), sym.hook)
		return false
	}
	if sym.kind != .Proc {
		errorf(k.c, sym.span, "L0488", "`hook(%s)` must be a procedure with its fixed signature", hook_name(sym.hook))
		return false
	}
	return true
}

@(private = "file")
report_extension_hook :: proc(k: ^Checker, span: Span, type_text: string, role: Hook_Kind) {
	errorf(k.c, span, "L0486", "a semantic hook belongs with the package that declares `%s`; an extension block cannot add `hook(%s)`", type_text, hook_name(role))
}

// Lifecycle roles are unique per type; conversions per source type. Only earlier
// declarations are compared, so the later one is reported once. A hook is a member
// of the type it is written on, and a `distinct` name is not the type it wraps.
@(private = "file")
report_duplicate_hook :: proc(k: ^Checker, sym: ^Symbol, symbol_id: Symbol_Id, subject: Type_Id) -> bool {
	info := type_of(k.c, subject)
	if info == nil {
		return false
	}
	for other_id in info.members {
		if other_id >= symbol_id {
			continue
		}
		other := symbol_of(k.c, other_id)
		if other == nil || other.synth != .None || other.hook != sym.hook || other.bound_excluded || other.superseded {
			continue
		}
		conflict := sym.hook != .Convert || (len(sym.params) == 1 && len(other.params) == 1 && sym.params[0] == other.params[0])
		if conflict {
			errorf(
				k.c,
				sym.span,
				"L0488",
				"duplicate `hook(%s)` for `%s`%s",
				hook_name(sym.hook),
				type_name(k.c, subject),
				sym.hook == .Convert ? " and this source type" : "",
			)
			return true
		}
	}
	return false
}

// The shape its role fixes.
@(private = "file")
check_hook_role :: proc(k: ^Checker, sym: ^Symbol, subject: Type_Id) {
	info := type_of(k.c, subject)
	switch sym.hook {
	case .Drop, .Copy:
		// Includes a record made move-only by one of its fields. A hook its own
		// bound excluded is what made the instance move-only, so it is not a
		// second declaration of anything.
		if sym.hook == .Copy && !sym.bound_excluded && type_clone_disabled(k.c, subject) {
			errorf(k.c, sym.span, "L0488", "a move-only type cannot also declare `hook(copy)`")
			// Which arguments make it so is the block's to say, by a bound on the hook.
			if info != nil && info.instance_of != INVALID_SYMBOL && !info.move_only {
				add_notef(k.c, no_span(), "a field makes `%s` move-only; a bound on the hook, such as `where is_copyable(T)`, leaves it out of this instance", type_name(k.c, subject))
			}
			return
		}
		sym.hook_bound = require_hook_shape(k, sym, subject)
	case .Convert:
		if sym.has_receiver || len(sym.params) != 1 || sym.result != subject {
			errorf(k.c, sym.span, "L0411", "`hook(convert)` takes one value without a receiver and returns `%s`", type_name(k.c, subject))
			return
		}
		// An instance's arguments may make one source convertible by accident, which
		// says nothing about the block its author wrote.
		if info != nil && info.instance_of == INVALID_SYMBOL && convertible(k.c, sym.params[0], subject) {
			errorf(k.c, sym.span, "L0411", "`%s` already has a built-in conversion to `%s`; a conversion hook for that pair would be unreachable", type_name(k.c, sym.params[0]), type_name(k.c, subject))
		}
	case .None:
	}
}

@(private = "file")
require_hook_shape :: proc(k: ^Checker, sym: ^Symbol, subject: Type_Id) -> bool {
	ok := sym.has_receiver && len(sym.params) > 0 && sym.params[0] == subject
	shape: string
	if sym.hook == .Drop {
		shape = "proc(self: inout T)"
		ok = ok && sym.receiver == .Inout && len(sym.params) == 1 && sym.result == INVALID_TYPE
	} else {
		shape = "proc(self, allocator: Allocator) -> Result(T, Allocator_Error)"
		ok = ok && (sym.receiver == .Borrow || sym.receiver == .Value) && len(sym.params) == 2 && sym.params[1] == TYPE_ALLOCATOR &&
		     sym.result == result_type(k, subject, TYPE_ALLOCATOR_ERROR)
	}
	if !ok {
		errorf(k.c, sym.span, "L0488", "`%s` has a fixed signature for `%s`: `%s`", hook_name(sym.hook), type_name(k.c, subject), shape)
		return false
	}
	if sym.hook == .Copy && len(sym.param_defaults) > 1 {
		if sym.param_defaults[1] != nil {
			errorf(
				k.c,
				expr_span(sym.param_defaults[1]),
				"L0489",
				"a lifecycle hook takes no written default; the compiler supplies `mem.default_allocator()`",
			)
			return false
		}
		sym.param_defaults[1] = default_allocator_arg(k.c)
	}
	return true
}

// A generic block's hooks are validated per instance, since their types are the
// instance's, by `validate_instance_hooks`. These two need no instance: a block
// in another package may have none there, and a record decides its copy from the
// shape of its drop hook whether or not it is instantiated.
check_generic_impl_hooks :: proc(k: ^Checker, item: ^Item_Impl, template: ^Generic_Template) {
	record := template.decl.values[0].(^Type_Record)
	for member in item.members {
		d, is_decl := member.(^Decl)
		if !is_decl || len(d.names) == 0 {
			continue
		}
		role := decl_hook_kind(d)
		if role != .None && item.kind == .Extend {
			report_extension_hook(k, d.names[0].span, identifier_text(k.c, symbol_of(k.c, template.symbol).name), role)
		} else if role == .Drop && record.kind == .Struct && !drop_hook_shaped(d) {
			errorf(
				k.c, d.names[0].span, "L0488", "`drop` has a fixed signature for `%s`: `proc(self: inout T)`",
				identifier_text(k.c, symbol_of(k.c, template.symbol).name),
			)
			k.c.reported_generic_hooks[generic_hook_key(d)] = true
		}
	}
}

// The members of one instance's block, as `check_associated_member` for a
// non-generic block. One hook is reported once, by the first instance it is wrong
// for: its bound may hold or its fields be copyable only in some of them.
validate_instance_hooks :: proc(k: ^Checker, item: ^Item_Impl) {
	if item.kind != .Impl {
		return
	}
	for member in item.members {
		d, is_decl := member.(^Decl)
		if !is_decl || k.c.reported_generic_hooks[generic_hook_key(d)] {
			continue
		}
		role := decl_hook_kind(d)
		literal := decl_proc_literal(d)
		// A generic conversion is instantiated by the calls that find it.
		if role == .Convert && literal != nil && proc_signature_is_generic(literal) {
			continue
		}
		for symbol_id in d.symbols {
			sym := symbol_of(k.c, symbol_id)
			if sym == nil || sym.bound_excluded || sym.superseded {
				continue
			}
			// A lifecycle hook with `$` parameters of its own resolves as a generic
			// procedure, with no role; a non-generic block records it when declared.
			sym.hook = role
			errors := k.c.error_count
			validate_semantic_hook(k, item, sym, symbol_id)
			if k.c.error_count != errors {
				k.c.reported_generic_hooks[generic_hook_key(d)] = true
			}
		}
	}
}

@(private = "file")
generic_hook_key :: proc(d: ^Decl) -> u64 {
	return u64(d.span.file) << 32 | u64(d.span.lo)
}

// The written shape of `proc(self: inout T)`, for a block with no instance to
// resolve its types in. Whether `T` is the subject is left to the instance.
@(private = "file")
drop_hook_shaped :: proc(d: ^Decl) -> bool {
	literal := decl_proc_literal(d)
	if literal == nil || literal.signature == nil || literal.signature.result != nil {
		return false
	}
	params := literal.signature.params
	return len(params) == 1 && len(params[0].names) == 1 && params[0].mode == .Inout && params[0].names[0].name.text == "self"
}

// What `check_copy_decision` can find wrong with a declaration.
Copy_Failure :: enum {
	Undecided,
	Opted_Move_Only,
	Opted_Copy_Hook,
	Opted_No_Drop_Hook,
	Opted_Move_Only_Field,
}

// Whether to report this failure of `d`, which instances of a generic procedure
// share while each checks its own copy. A speculative check discards what it
// reports, so it does not count.
@(private = "file")
claim_copy_failure :: proc(k: ^Checker, d: ^Decl, failure: Copy_Failure) -> bool {
	if !committing(k.c) {
		return true
	}
	key := u64(d.span.file) << 32 | u64(d.span.lo)
	reported := k.c.reported_copy_failures[key]
	if failure in reported {
		return false
	}
	k.c.reported_copy_failures[key] = reported + {failure}
	return true
}

// The hooks a record's declaration writes, whatever their bounds.
@(private = "file")
Written_Hooks :: struct {
	drop_written, drop_bound, copy_written: bool,
	drop_span, copy_span:                   Span,
}

// A generic record's are read from its blocks, before any instance's hooks are
// validated, so a hook counts as bound by its shape, which
// `check_generic_impl_hooks` reports the rest of.
@(private = "file")
template_written_hooks :: proc(k: ^Checker, template: Symbol_Id) -> Written_Hooks {
	written: Written_Hooks
	// Copied out: a range over the map entry itself faults when it has no blocks.
	blocks := k.c.generic_impls[template]
	for block in blocks {
		if block.item.kind != .Impl {
			continue
		}
		for member in block.item.members {
			hook_decl, is_decl := member.(^Decl)
			if !is_decl {
				continue
			}
			#partial switch decl_hook_kind(hook_decl) {
			case .Drop:
				written.drop_written = true
				if drop_hook_shaped(hook_decl) && !written.drop_bound {
					written.drop_bound = true
					written.drop_span = hook_decl.names[0].span
				}
			case .Copy:
				written.copy_written = true
				written.copy_span = hook_decl.names[0].span
			}
		}
	}
	return written
}

@(private = "file")
declared_written_hooks :: proc(k: ^Checker, info: ^Type_Info) -> Written_Hooks {
	written: Written_Hooks
	for member_id in info.members {
		member := symbol_of(k.c, member_id)
		if member == nil || member.synth != .None {
			continue
		}
		#partial switch member.hook {
		case .Drop:
			written.drop_written = true
			if member.hook_bound && !written.drop_bound {
				written.drop_bound = true
				written.drop_span = member.span
			}
		case .Copy:
			written.copy_written = true
			written.copy_span = member.span
		}
	}
	return written
}

// design.md "Lifecycle hooks and resource types": a record with a drop hook says
// in writing how it is copied. Asked once every `impl` block the record can have
// is checked, so a hook another diagnostic rejected is not reported again. The
// answer reads the declaration and its hooks only: what its fields make it does
// not count, so a generic record has one answer for all of its instances.
check_copy_decision :: proc(k: ^Checker, d: ^Decl) {
	if d.kind != .Const || len(d.values) != 1 || len(d.symbols) != 1 || decl_is_intrinsic(d) {
		return
	}
	record, is_record := d.values[0].(^Type_Record)
	if !is_record || record.kind != .Struct {
		return
	}
	symbol_id := d.symbols[0]
	template := generic_template_for(k, symbol_id)
	if template != nil && template_rejected(k, template) {
		return
	}
	// Read after the template settles: that may grow the symbol table.
	sym := symbol_of(k.c, symbol_id)
	if sym == nil {
		return
	}
	name, name_span := identifier_text(k.c, sym.name), sym.span
	written: Written_Hooks
	// A generic record has no answer of its own: it depends on the instance.
	subject := INVALID_TYPE
	if template != nil {
		written = template_written_hooks(k, symbol_id)
	} else {
		info := type_of(k.c, sym.type)
		if sym.kind != .Type || info == nil {
			return
		}
		written = declared_written_hooks(k, info)
		subject = sym.type
	}

	if opt_in, opted := find_attribute(record.attributes, "fieldwise_copy"); opted {
		report_fieldwise_copy_misuse(k, d, record, opt_in.span, written, name, subject)
		return
	}
	if record.move_only || !written.drop_bound || written.copy_written || !claim_copy_failure(k, d, .Undecided) {
		return
	}
	errorf(k.c, name_span, "L0747", "`%s` declares `hook(drop)`, so it must say how it is copied", name)
	add_notef(k.c, written.drop_span, "`hook(drop)` is declared here")
	if type_clone_disabled(k.c, subject) {
		add_notef(k.c, no_span(), "`%s` is already move-only through a field; write `@(move_only)` on its declaration to say so", name)
		return
	}
	add_notef(k.c, no_span(), "if a copy would release what the hook releases a second time, write `@(move_only)` on its declaration")
	add_notef(k.c, no_span(), "if a copy must do more than copy each field, declare `hook(copy)`")
	add_notef(k.c, no_span(), "if copying each field is right, write `@(fieldwise_copy)` on its declaration")
}

@(private = "file")
report_fieldwise_copy_misuse :: proc(k: ^Checker, d: ^Decl, record: ^Type_Record, span: Span, written: Written_Hooks, name: string, subject: Type_Id) {
	switch {
	case record.move_only:
		if claim_copy_failure(k, d, .Opted_Move_Only) {
			errorf(k.c, span, "L0748", "`@(fieldwise_copy)` keeps a generated copy, but a `@(move_only)` record has none")
		}
	case written.copy_written:
		if claim_copy_failure(k, d, .Opted_Copy_Hook) {
			errorf(k.c, span, "L0748", "`@(fieldwise_copy)` keeps the generated copy, but `%s` declares `hook(copy)`", name)
			add_notef(k.c, written.copy_span, "`hook(copy)` is declared here")
		}
	case !written.drop_written:
		if claim_copy_failure(k, d, .Opted_No_Drop_Hook) {
			errorf(k.c, span, "L0749", "`@(fieldwise_copy)` is for a record with `hook(drop)`; `%s` declares none, so it already copies field by field", name)
		}
	case type_clone_disabled(k.c, subject):
		if claim_copy_failure(k, d, .Opted_Move_Only_Field) {
			errorf(k.c, span, "L0748", "`@(fieldwise_copy)` keeps a generated copy, but `%s` holds a move-only field and has none; write `@(move_only)`", name)
		}
	}
}

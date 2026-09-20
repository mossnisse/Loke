// Erased views, both compiler-owned two-word structs:
//
//   any_view       { ptr data, typeid id }
//   dyn Interface  { ptr data, ptr witness }
//
// A witness is one private global per `(Interface, Concrete, arguments)`. Its
// slots come from inherent members plus extensions in the slot's declaring
// package, so one key means one behavior everywhere.
package lokec

import "core:fmt"
import "core:strings"

ANY_VIEW_DATA :: 0
ANY_VIEW_ID :: 1

DYN_DATA :: 0
DYN_WITNESS :: 1

// Installed on first use: the predeclared table runs before any symbol exists.
ensure_any_view_fields :: proc(c: ^Compiler) {
	info := type_of(c, TYPE_ANY_VIEW)
	if info == nil || len(info.fields) > 0 {
		return
	}
	fields := make([]Symbol_Id, 2, c.semantic_allocator)
	fields[ANY_VIEW_DATA] = new_field(c, "data", TYPE_RAWPTR, ANY_VIEW_DATA)
	fields[ANY_VIEW_ID] = new_field(c, "id", TYPE_TYPEID, ANY_VIEW_ID)
	// A `^Type_Info` points into the growing type store, so it is never held
	// across the field symbols being made.
	info = type_of(c, TYPE_ANY_VIEW)
	info.fields = fields
	info.mangled = "any_view"
}

// design.md: `any_view` may only be a local or a parameter. The resolved type is
// asked, so an alias or a generic substitution cannot bypass the rule.
type_mentions_any_view :: proc(c: ^Compiler, id: Type_Id, allow_top := false) -> bool {
	if id == INVALID_TYPE {
		return false
	}
	if id == TYPE_ANY_VIEW {
		return !allow_top
	}
	seen := make(map[Type_Id]bool, context.temp_allocator)
	return type_contains_any_view(c, id, &seen)
}

@(private = "file")
type_contains_any_view :: proc(c: ^Compiler, id: Type_Id, seen: ^map[Type_Id]bool) -> bool {
	if seen[id] {
		return false
	}
	seen[id] = true
	info := type_of(c, id)
	if info == nil {
		return false
	}
	#partial switch info.kind {
	case .Any_View:
		return true
	case .Pointer, .C_Pointer, .Slice, .Dynamic_Array, .Array, .Distinct:
		return type_contains_any_view(c, info.element, seen)
	case .Map:
		return type_contains_any_view(c, info.key, seen) ||
		       type_contains_any_view(c, info.element, seen)
	case .Union:
		for variant in info.variants {
			if type_contains_any_view(c, variant, seen) {
				return true
			}
		}
	case .Struct:
		for field in info.fields {
			sym := symbol_of(c, field)
			if sym != nil && type_contains_any_view(c, sym.type, seen) {
				return true
			}
		}
	case .Proc:
		for parameter in info.parameters {
			if type_contains_any_view(c, parameter, seen) {
				return true
			}
		}
		if info.result != INVALID_TYPE && type_contains_any_view(c, info.result, seen) {
			return true
		}
	}
	return false
}

reject_any_view_position :: proc(k: ^Checker, type: Type_Id, span: Span, what: string) -> bool {
	if !type_mentions_any_view(k.c, type) {
		return false
	}
	errorf(
		k.c,
		span,
		"L0462",
		"`any_view` is a borrowed view and cannot be %s; it may only be a local or a parameter",
		what,
	)
	return true
}

// design.md: conversion from a concrete value is implicit at an `any_view`
// destination and never allocates.
any_view_accepts :: proc(c: ^Compiler, from: Type_Id) -> bool {
	if from == INVALID_TYPE || from == TYPE_ANY_VIEW {
		return false
	}
	if type_is_untyped(c, from) && from != TYPE_UNTYPED_NIL {
		return true // through its default type
	}
	return type_is_supported(c, from) && !type_mentions_any_view(c, from)
}

// The concrete type an `any_view` is being made from, once untyped constants
// have taken their default type.
any_view_source_type :: proc(c: ^Compiler, from: Type_Id) -> Type_Id {
	return type_is_untyped(c, from) ? default_type(c, from) : from
}

// `dyn Interface(args...)`, whose arguments omit the erased subject.
dyn_type :: proc(
	k: ^Checker,
	info: ^Interface_Info,
	args: []Generic_Arg,
	span: Span,
	mutable: bool,
	report: bool,
) -> Type_Id {
	if !dyn_compatible(k, info) {
		if report {
			errorf(
				k.c,
				span,
				"L0463",
				"`%s` is not dyn-compatible: %s",
				identifier_text(k.c, symbol_of(k.c, info.symbol).name),
				info.dyn_reason,
			)
		}
		return INVALID_TYPE
	}
	key := dyn_key(k.c, info.symbol, args, mutable)
	if existing, found := k.c.dyn_types[key]; found {
		return existing
	}
	if failure, holds := interface_predicates_check(k, info, interface_application(k.c, info, TYPE_RAWPTR, args)); !holds {
		if report {
			errorf(
				k.c,
				span,
				"L0463",
				"`%s` does not satisfy its interface `where` clause",
				dyn_display_name(k.c, info, args, mutable),
			)
			add_notef(k.c, failure.span, "this predicate does not hold: %s", failure.reason)
		}
		return INVALID_TYPE
	}
	// The read-only variant is the ABI type both capabilities share.
	if mutable {
		dyn_type(k, info, args, span, false, report)
	}
	name := intern_identifier(k.c, dyn_display_name(k.c, info, args, mutable))
	type := new_type(k.c, Type_Info {
		kind          = .Dyn,
		name          = name,
		mutable       = mutable,
		dyn_interface = info.symbol,
		dyn_args      = args,
	})
	fields := make([]Symbol_Id, 2, k.c.semantic_allocator)
	fields[DYN_DATA] = new_field(k.c, "data", TYPE_RAWPTR, DYN_DATA)
	fields[DYN_WITNESS] = new_field(k.c, "witness", TYPE_RAWPTR, DYN_WITNESS)
	if stored := type_of(k.c, type); stored != nil {
		stored.fields = fields
		stored.mangled = fmt.aprintf("dyn.%s", llvm_safe(identifier_text(k.c, name), allocator = context.temp_allocator), allocator = k.c.semantic_allocator)
	}
	k.c.dyn_types[key] = type
	install_dyn_forwarding_slots(k, info, args, type)
	return type
}

// design.md: `dyn I` satisfies `I` through forwarding methods that call
// through the view's own witness.
@(private = "file")
install_dyn_forwarding_slots :: proc(k: ^Checker, info: ^Interface_Info, args: []Generic_Arg, dyn: Type_Id) {
	flattened := make([dynamic]Interface_Slot, 0, 4, context.temp_allocator)
	interface_slots(k, info, interface_application(k.c, info, dyn, args), &flattened)

	dyn_mutable := dyn_is_mutable(k.c, dyn)
	members := make([]Symbol_Id, len(flattened), k.c.semantic_allocator)
	for entry, index in flattened {
		params, modes, result_type, result_inout, ok := slot_signature_for(k, interface_info_for(k, entry.owner), entry, dyn)
		if !ok {
			continue
		}
		// A read-only view leaves a hole for an `inout` slot, so calling it is a
		// capability error (L0643) rather than a missing member.
		if !dyn_mutable && len(modes) > 0 && modes[0] == .Inout {
			continue
		}
		id := new_symbol(k.c, Symbol {
			name           = entry.name,
			span           = entry.span,
			kind           = .Proc,
			public         = true,
			owner_type     = dyn,
			params         = params,
			result         = result_type,
			result_inout   = result_inout,
			param_symbols  = make([]Symbol_Id, len(params), k.c.semantic_allocator),
			param_defaults = make([]Expr, len(params), k.c.semantic_allocator),
			proc_type      = intern_proc_type(k.c, params, modes, result_type, result_inout, ""),
			synth          = .Dyn_Forward,
			has_receiver   = true,
			receiver       = modes[0],
			index          = u32(index),
		})
		members[index] = id
		append(&k.c.synth_procs, id)
	}
	if stored := type_of(k.c, dyn); stored != nil {
		stored.members = members
	}
}

// `subject` followed by the non-subject `rest`: a full interface application.
@(private = "file")
interface_application :: proc(c: ^Compiler, info: ^Interface_Info, subject: Type_Id, rest: []Generic_Arg) -> []Generic_Arg {
	full := make([]Generic_Arg, len(info.params), c.semantic_allocator)
	if len(full) > 0 {
		full[0] = Generic_Arg{is_type = true, type = subject}
	}
	for index in 1 ..< len(full) {
		full[index] = index - 1 < len(rest) ? rest[index - 1] : Generic_Arg{}
	}
	return full
}

// A scope binding the interface's parameters to one application's arguments.
interface_scope :: proc(k: ^Checker, info: ^Interface_Info, args: []Generic_Arg) -> ^Scope {
	scope := new_scope(k.c, info.scope == nil ? build_universe(k.c) : info.scope, .Local)
	for parameter, index in info.params {
		if index < len(args) {
			bind_generic_name(k, scope, Generic_Binding{name = parameter.name, span = parameter.span, arg = args[index]})
		}
	}
	return scope
}

@(private = "file")
write_arg_keys :: proc(c: ^Compiler, b: ^strings.Builder, args: []Generic_Arg) {
	for arg in args {
		if arg.is_type {
			fmt.sbprintf(b, "|T%d", u32(arg.type))
		} else {
			text := const_key_text(c, arg.value)
			fmt.sbprintf(b, "|V%d:%d:%s", u32(arg.value_type), len(text), text)
		}
	}
}

dyn_key :: proc(c: ^Compiler, interface_symbol: Symbol_Id, args: []Generic_Arg, mutable: bool) -> string {
	b := strings.builder_make(c.semantic_allocator)
	fmt.sbprintf(&b, "%d%s", u32(interface_symbol), mutable ? "m" : "")
	write_arg_keys(c, &b, args)
	return strings.to_string(b)
}

@(private = "file")
dyn_display_name :: proc(c: ^Compiler, info: ^Interface_Info, args: []Generic_Arg, mutable: bool) -> string {
	b := strings.builder_make(c.semantic_allocator)
	strings.write_string(&b, mutable ? "dyn mut " : "dyn ")
	strings.write_string(&b, identifier_text(c, symbol_of(c, info.symbol).name))
	if len(args) > 0 {
		strings.write_string(&b, "(")
		for arg, index in args {
			if index > 0 {
				strings.write_string(&b, ", ")
			}
			strings.write_string(&b, interface_argument_text(c, arg))
		}
		strings.write_string(&b, ")")
	}
	return strings.to_string(b)
}

type_is_dyn :: proc(c: ^Compiler, id: Type_Id) -> bool {
	return underlying_kind(c, id) == .Dyn
}

dyn_is_mutable :: proc(c: ^Compiler, id: Type_Id) -> bool {
	info := underlying_info(c, id)
	return info != nil && info.kind == .Dyn && info.mutable
}

// Both capabilities share one representation, so weakening is free.
dyn_abi_type :: proc(c: ^Compiler, id: Type_Id) -> Type_Id {
	under := type_underlying(c, id)
	info := type_of(c, under)
	if info == nil || info.kind != .Dyn || !info.mutable {
		return under
	}
	readonly, found := c.dyn_types[dyn_key(c, info.dyn_interface, info.dyn_args, false)]
	return found ? readonly : under
}

// The same interface and arguments, whatever the capability.
dyn_same_application :: proc(c: ^Compiler, a, b: ^Type_Info) -> bool {
	if a.dyn_interface != b.dyn_interface || len(a.dyn_args) != len(b.dyn_args) {
		return false
	}
	for arg, index in a.dyn_args {
		other := b.dyn_args[index]
		if arg.is_type != other.is_type {
			return false
		}
		if arg.is_type {
			if arg.type != other.type {
				return false
			}
			continue
		}
		if arg.value_type != other.value_type {
			return false
		}
		equal, comparable := const_equal(c, arg.value, other.value)
		if !comparable || !equal {
			return false
		}
	}
	return true
}

// design.md's five rules, computed once per declaration.
dyn_compatible :: proc(k: ^Checker, info: ^Interface_Info) -> bool {
	if info.dyn_computed {
		return info.dyn_ok
	}
	info.dyn_computed = true
	info.dyn_ok = false

	if len(info.params) == 0 {
		info.dyn_reason = "it declares no subject parameter"
		return false
	}
	if _, is_type := info.params[0].type_syntax.(^Type_Type); !is_type {
		info.dyn_reason = "its subject parameter does not have type `type`"
		return false
	}
	subject := info.params[0].name
	for parameter, index in info.params {
		if index > 0 && type_syntax_names(parameter.type_syntax, subject) {
			info.dyn_reason = fmt.aprintf(
				"parameter `%s` has a type that depends on the erased subject",
				identifier_text(k.c, parameter.name),
				allocator = k.c.semantic_allocator,
			)
			return false
		}
	}
	for clause in info.node.where_clauses {
		if type_syntax_names(clause, subject) {
			info.dyn_reason = fmt.aprintf(
				"the `where` predicate on line %d depends on the erased subject",
				span_line(k.c, expr_span(clause)),
				allocator = k.c.semantic_allocator,
			)
			return false
		}
	}

	for requirement in info.node.requirements {
		if requirement.kind == .Slot {
			if reason, ok := dyn_slot_is_compatible(k, requirement, subject); !ok {
				info.dyn_reason = reason
				return false
			}
			continue
		}
		// Only composition of a dyn-compatible interface on the same subject.
		composed := composed_interface_of(k, requirement)
		if composed == nil {
			info.dyn_reason = fmt.aprintf(
				"the requirement on line %d is a free expression; every runtime operation must be a named `slot`",
				span_line(k.c, requirement.span),
				allocator = k.c.semantic_allocator,
			)
			return false
		}
		call := requirement.expr.(^Expr_Call)
		first: ^Expr_Ident
		has_subject := false
		if len(call.args) > 0 {
			first, has_subject = call.args[0].value.(^Expr_Ident)
		}
		if !has_subject || first.name_id != subject {
			info.dyn_reason = fmt.aprintf(
				"the composed interface `%s` does not use this interface's subject as its first argument",
				identifier_text(k.c, symbol_of(k.c, composed.symbol).name),
				allocator = k.c.semantic_allocator,
			)
			return false
		}
		for arg, index in call.args {
			if index > 0 && type_syntax_names(arg.value, subject) {
				info.dyn_reason = fmt.aprintf(
					"the composed interface `%s` derives an explicit argument from the erased subject",
					identifier_text(k.c, symbol_of(k.c, composed.symbol).name),
					allocator = k.c.semantic_allocator,
				)
				return false
			}
		}
		if !dyn_compatible(k, composed) {
			info.dyn_reason = fmt.aprintf(
				"the composed interface `%s` is not dyn-compatible: %s",
				identifier_text(k.c, symbol_of(k.c, composed.symbol).name),
				composed.dyn_reason,
				allocator = k.c.semantic_allocator,
			)
			return false
		}
	}
	info.dyn_ok = true
	return true
}

@(private = "file")
span_line :: proc(c: ^Compiler, span: Span) -> int {
	if span.file == NO_FILE || int(span.file) >= len(c.sources) {
		return 0
	}
	line, _ := line_col(&c.sources[span.file], span.lo)
	return line
}

composed_interface_of :: proc(k: ^Checker, requirement: Requirement) -> ^Interface_Info {
	if requirement.result != nil || len(requirement.bindings) > 0 {
		return nil
	}
	call, is_call := requirement.expr.(^Expr_Call)
	if !is_call {
		return nil
	}
	return interface_info_for(k, named_callee_symbol(k, call.callee))
}

// design.md: a slot is non-generic and non-variadic, uses the ordinary calling
// convention, has no defaults, and mentions the subject exactly once — as the
// receiver.
@(private = "file")
dyn_slot_is_compatible :: proc(k: ^Checker, requirement: Requirement, subject: Identifier_Id) -> (string, bool) {
	signature, is_proc := requirement.slot_type.(^Type_Proc)
	if !is_proc {
		return "a `slot` requirement needs a procedure type", false
	}
	name := requirement.name.text
	if signature.convention != "" {
		return fmt.aprintf("slot `%s` uses a foreign calling convention", name, allocator = k.c.semantic_allocator), false
	}
	for parameter, position in signature.params {
		if parameter.mode == .Variadic {
			return fmt.aprintf("slot `%s` is variadic", name, allocator = k.c.semantic_allocator), false
		}
		if parameter.default != nil {
			return fmt.aprintf("slot `%s` has a default argument", name, allocator = k.c.semantic_allocator), false
		}
		// In `proc(self, canvas: inout Canvas)` the type belongs to `canvas`.
		split := parameter_splits_receiver(parameter, position)
		if position == 0 && !split {
			// A borrowed view cannot supply `move self`.
			if parameter.mode == .Move {
				return fmt.aprintf(
					"slot `%s` consumes its receiver, which a borrowed view cannot supply",
					name,
					allocator = k.c.semantic_allocator,
				), false
			}
			if parameter.type != nil && !type_syntax_names(parameter.type, subject) {
				return fmt.aprintf(
					"slot `%s`'s receiver is not the interface's subject",
					name,
					allocator = k.c.semantic_allocator,
				), false
			}
			continue
		}
		if !split && type_syntax_names(parameter.type, subject) {
			return fmt.aprintf(
				"slot `%s` mentions the subject outside its receiver, so its size is not erasable",
				name,
				allocator = k.c.semantic_allocator,
			), false
		}
	}
	if result := signature.result; result != nil && type_syntax_names(result.type, subject) {
		return fmt.aprintf(
			"slot `%s` returns the subject, whose size is not known behind the view",
			name,
			allocator = k.c.semantic_allocator,
		), false
	}
	return "", true
}

// Whether the syntax mentions `name`; no arguments are bound yet.
@(private = "file")
type_syntax_names :: proc(e: Expr, name: Identifier_Id) -> bool {
	if e == nil {
		return false
	}
	#partial switch v in e {
	case ^Expr_Ident:
		return v.name_id == name
	case ^Expr_Error, ^Expr_Literal, ^Type_Type, ^Expr_Proc_Group:
		return false
	case ^Type_Pointer:
		return type_syntax_names(v.elem, name)
	case ^Type_C_Pointer:
		return type_syntax_names(v.elem, name)
	case ^Type_Slice:
		return type_syntax_names(v.elem, name)
	case ^Type_Dynamic_Array:
		return type_syntax_names(v.elem, name)
	case ^Type_Distinct:
		return type_syntax_names(v.elem, name)
	case ^Type_Dyn:
		return type_syntax_names(v.interface_expr, name)
	case ^Type_Array:
		return type_syntax_names(v.length, name) || type_syntax_names(v.elem, name)
	case ^Type_Map:
		return type_syntax_names(v.key, name) || type_syntax_names(v.value, name)
	case ^Expr_Selector:
		return type_syntax_names(v.operand, name)
	case ^Expr_Checked_Extract:
		return type_syntax_names(v.operand, name) || type_syntax_names(v.target, name)
	case ^Expr_Index:
		if type_syntax_names(v.operand, name) {
			return true
		}
		for index in v.indices {
			if type_syntax_names(index, name) {
				return true
			}
		}
		return false
	case ^Expr_Slice:
		return type_syntax_names(v.operand, name) ||
		       type_syntax_names(v.lo, name) ||
		       type_syntax_names(v.hi, name)
	case ^Expr_Call:
		for arg in v.args {
			if type_syntax_names(arg.value, name) {
				return true
			}
		}
		return type_syntax_names(v.callee, name)
	case ^Expr_Postfix:
		return type_syntax_names(v.operand, name)
	case ^Expr_Unary:
		return type_syntax_names(v.operand, name)
	case ^Expr_Binary:
		return type_syntax_names(v.lhs, name) || type_syntax_names(v.rhs, name)
	case ^Expr_Range:
		return type_syntax_names(v.lo, name) || type_syntax_names(v.hi, name)
	case ^Expr_Or_Else:
		return type_syntax_names(v.value, name) || type_syntax_names(v.fallback, name)
	case ^Expr_Cond:
		return type_syntax_names(v.then, name) ||
		       type_syntax_names(v.cond, name) ||
		       type_syntax_names(v.otherwise, name)
	case ^Expr_Move:
		return type_syntax_names(v.value, name)
	case ^Expr_Composite:
		if type_syntax_names(v.type_expr, name) || type_syntax_names(v.via, name) {
			return true
		}
		for element in v.elements {
			if type_syntax_names(element.key, name) || type_syntax_names(element.value, name) {
				return true
			}
		}
		return false
	case ^Expr_Operator:
		return type_syntax_names(v.value, name)
	case ^Type_Poly:
		return type_syntax_names(v.constraint, name)
	case ^Type_Proc:
		for parameter in v.params {
			if type_syntax_names(parameter.type, name) || type_syntax_names(parameter.default, name) {
				return true
			}
		}
		return v.result != nil && type_syntax_names(v.result.type, name)
	case ^Type_Anon_Record:
		for field in v.fields {
			if type_syntax_names(field.type, name) {
				return true
			}
		}
		return false
	case ^Expr_Proc, ^Type_Record, ^Type_Enum, ^Type_Interface:
		return true // conservatively
	}
	return false
}

// Evidence that one concrete type satisfies one interface application.
Witness :: struct {
	interface_symbol: Symbol_Id,
	concrete:         Type_Id,
	args:             []Generic_Arg,
	// In the flattened order slot calls index by.
	slots:            []Witness_Slot,
	name:             string,
}

Witness_Slot :: struct {
	name:   Identifier_Id,
	target: Symbol_Id,
	mode:   Param_Mode,
	params: []Type_Id,
	result: Type_Id,
}

// The flattened slots of an interface application, composition included.
interface_slots :: proc(k: ^Checker, info: ^Interface_Info, args: []Generic_Arg, out: ^[dynamic]Interface_Slot) {
	saved := save_checker_location(k)
	defer restore_checker_location(k, saved)
	k.scope, k.pkg, k.lookup_pkg = interface_scope(k, info, args), info.pkg, info.pkg
	if info.file_node != nil {
		k.file, k.file_node = info.file, info.file_node
	}

	for requirement in info.node.requirements {
		if requirement.kind == .Slot {
			signature, is_proc := requirement.slot_type.(^Type_Proc)
			if !is_proc {
				continue
			}
			append(out, Interface_Slot {
				name  = name_identifier(k.c, requirement.name),
				span  = requirement.span,
				type  = signature,
				owner = info.symbol,
				args  = args,
			})
			continue
		}
		composed := composed_interface_of(k, requirement)
		if composed == nil {
			continue
		}
		// Clone before annotating: one declaration serves many applications.
		call, is_call := clone_requirement_syntax(k.c, requirement).expr.(^Expr_Call)
		if !is_call {
			continue
		}
		composed_args, valid := bound_arguments(k, call, composed)
		if !valid {
			continue
		}
		interface_slots(k, composed, composed_args, out)
	}
}

// Materializes, or reuses, the witness for one key.
request_witness :: proc(k: ^Checker, info: ^Interface_Info, concrete: Type_Id, args: []Generic_Arg, span: Span) -> ^Witness {
	key := witness_key(k.c, info.symbol, concrete, args)
	if existing, found := k.c.witnesses[key]; found {
		return existing
	}

	flattened := make([dynamic]Interface_Slot, 0, 4, context.temp_allocator)
	interface_slots(k, info, interface_application(k.c, info, concrete, args), &flattened)

	witness := new(Witness, k.c.semantic_allocator)
	witness.interface_symbol = info.symbol
	witness.concrete = concrete
	witness.args = args
	witness.name = witness_llvm_name(k.c, info.symbol, concrete, args)

	slots := make([]Witness_Slot, len(flattened), k.c.semantic_allocator)
	saved := save_checker_location(k)
	for entry, index in flattened {
		owner := interface_info_for(k, entry.owner)
		// The slot's declaring package decides which extensions may supply it.
		k.pkg, k.lookup_pkg = owner.pkg, owner.pkg
		params, modes, result_type, _, shape_ok := slot_signature_for(k, owner, entry, concrete)
		target := INVALID_SYMBOL
		if shape_ok {
			target = find_witness_slot(k, concrete, entry.name, owner.pkg, params, modes, result_type)
		}
		slots[index] = Witness_Slot {
			name   = entry.name,
			target = target,
			mode   = len(modes) > 0 ? modes[0] : Param_Mode.Value,
			params = params,
			result = result_type,
		}
	}
	restore_checker_location(k, saved)
	witness.slots = slots
	if k.c.speculation_depth == 0 {
		// The readable name need not be unique: two packages may both have a `Shape`.
		if k.c.witness_names[witness.name] {
			witness.name = fmt.aprintf("%s.%d", witness.name, len(k.c.witness_order), allocator = k.c.semantic_allocator)
		}
		k.c.witness_names[witness.name] = true
		k.c.witnesses[key] = witness
		append(&k.c.witness_order, witness)
	}
	return witness
}

@(private = "file")
witness_key :: proc(c: ^Compiler, interface_symbol: Symbol_Id, concrete: Type_Id, args: []Generic_Arg) -> string {
	b := strings.builder_make(c.semantic_allocator)
	fmt.sbprintf(&b, "%d|%d", u32(interface_symbol), u32(concrete))
	write_arg_keys(c, &b, args)
	return strings.to_string(b)
}

// Spelled from names rather than ids, which shift on unrelated changes.
@(private = "file")
witness_llvm_name :: proc(c: ^Compiler, interface_symbol: Symbol_Id, concrete: Type_Id, args: []Generic_Arg) -> string {
	b := strings.builder_make(c.semantic_allocator)
	interface_name := "interface"
	if sym := symbol_of(c, interface_symbol); sym != nil {
		interface_name = identifier_text(c, sym.name)
	}
	fmt.sbprintf(&b, "@loke.w.%s.%s", llvm_safe(interface_name, allocator = context.temp_allocator), llvm_safe(type_name(c, concrete), allocator = context.temp_allocator))
	for arg in args {
		part := arg.is_type ? type_name(c, arg.type) : fmt.aprintf(
			"v%s:%s",
			type_name(c, arg.value_type),
			const_key_text(c, arg.value),
			allocator = c.semantic_allocator,
		)
		escaped := llvm_safe(part, dots = false)
		fmt.sbprintf(&b, ".%s", escaped)
		delete(escaped)
	}
	return strings.to_string(b)
}

// One slot's signature for `receiver`, with its interface's parameters bound.
@(private = "file")
slot_signature_for :: proc(
	k: ^Checker,
	owner: ^Interface_Info,
	entry: Interface_Slot,
	receiver: Type_Id,
) -> ([]Type_Id, []Param_Mode, Type_Id, bool, bool) {
	saved := k.scope
	k.scope = interface_scope(k, owner, entry.args)
	defer k.scope = saved
	return slot_signature(k, entry.type, receiver)
}

@(private = "file")
find_witness_slot :: proc(
	k: ^Checker,
	concrete: Type_Id,
	name: Identifier_Id,
	owner_pkg: Package_Id,
	params: []Type_Id,
	modes: []Param_Mode,
	result: Type_Id,
) -> Symbol_Id {
	for candidate in slot_candidates(k, concrete, name, owner_pkg) {
		sym := symbol_of(k.c, candidate)
		if sym == nil || sym.kind != .Proc || !sym.has_receiver {
			continue
		}
		if slot_matches(k, sym, params, modes, result, nil) {
			return candidate
		}
	}
	return INVALID_SYMBOL
}

// The slot a `dyn` value's method call selects, and its index in the witness.
dyn_slot_index :: proc(k: ^Checker, dyn: Type_Id, name: Identifier_Id) -> (int, Interface_Slot, bool) {
	info := underlying_info(k.c, dyn)
	if info == nil || info.kind != .Dyn {
		return 0, Interface_Slot{}, false
	}
	owner := interface_info_for(k, info.dyn_interface)
	if owner == nil {
		return 0, Interface_Slot{}, false
	}
	flattened := make([dynamic]Interface_Slot, 0, 4, context.temp_allocator)
	interface_slots(k, owner, interface_application(k.c, owner, dyn, info.dyn_args), &flattened)
	for entry, index in flattened {
		if entry.name == name {
			return index, entry, true
		}
	}
	return 0, Interface_Slot{}, false
}

// `dyn Interface(args...)`. Satisfaction waits for a concrete subject.
resolve_dyn_type :: proc(k: ^Checker, v: ^Type_Dyn) -> Type_Id {
	callee := v.interface_expr
	args: []Argument
	if call, is_call := callee.(^Expr_Call); is_call {
		args = call.args
		callee = call.callee
	}
	info := interface_info_for(k, named_callee_symbol(k, callee))
	if info == nil {
		errorf(k.c, expr_span(v.interface_expr), "L0463", "`dyn` needs an interface")
		return INVALID_TYPE
	}
	if !dyn_compatible(k, info) {
		return dyn_type(k, info, nil, v.span, v.mutable, report = true)
	}
	if len(args) != len(info.params) - 1 {
		errorf(
			k.c,
			v.span,
			"L0463",
			"`dyn %s` takes %d argument%s beyond its erased subject, found %d",
			identifier_text(k.c, symbol_of(k.c, info.symbol).name),
			len(info.params) - 1,
			len(info.params) - 1 == 1 ? "" : "s",
			len(args),
		)
		return INVALID_TYPE
	}
	bound := make([]Generic_Arg, len(args), k.c.semantic_allocator)
	ok: bool
	bound, ok = interface_arguments_for(
		k, args, info, 1, TYPE_RAWPTR,
		"L0463", "a `dyn` interface argument", true, bound,
	)
	if !ok {
		return INVALID_TYPE
	}
	return dyn_type(k, info, bound, v.span, v.mutable, report = true)
}

// design.md: `(dyn I)(&concrete)` checks `I(Concrete, args...)` and requests
// the witness.
check_dyn_conversion :: proc(k: ^Checker, v: ^Expr_Call, target: Type_Id) {
	v.value_category = .Value
	v.type = target
	if len(v.args) != 1 {
		errorf(k.c, v.span, "L0464", "a `dyn` conversion takes one pointer to the concrete value")
		v.type = INVALID_TYPE
		return
	}
	source := check_single_expr(k, v.args[0].value)
	if source == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}
	bound := make([]Expr, 1, k.c.semantic_allocator)
	bound[0] = v.args[0].value
	v.bound = bound
	v.operation = Call_Dyn_Conversion{}
	v.resolution = {}

	// `nil` gives the nil view, with no witness.
	if source == TYPE_UNTYPED_NIL {
		materialize(k, v.args[0].value, TYPE_RAWPTR)
		return
	}
	pointer := underlying_info(k.c, source)
	if pointer == nil || pointer.kind != .Pointer {
		errorf(
			k.c,
			expr_span(v.args[0].value),
			"L0464",
			"a `dyn` conversion takes `^Concrete`, found `%s`",
			type_name(k.c, source),
		)
		v.type = INVALID_TYPE
		return
	}
	// A mutable view needs a mutable pointer.
	if dyn_is_mutable(k.c, target) && !pointer.mutable {
		errorf(
			k.c,
			expr_span(v.args[0].value),
			"L0642",
			"`%s` needs `^mut Concrete`, found `%s`",
			type_name(k.c, target),
			type_name(k.c, source),
		)
		v.type = INVALID_TYPE
		return
	}
	concrete := pointer.element
	dyn := underlying_info(k.c, target)
	info := interface_info_for(k, dyn.dyn_interface)
	if info == nil {
		v.type = INVALID_TYPE
		return
	}

	if !interface_satisfied(k, info, interface_application(k.c, info, concrete, dyn.dyn_args), v.span, report = true) {
		v.type = INVALID_TYPE
		return
	}

	witness := request_witness(k, info, concrete, dyn.dyn_args, v.span)
	for slot in witness.slots {
		if slot.target == INVALID_SYMBOL {
			errorf(
				k.c,
				v.span,
				"L0464",
				"`%s` supplies no coherent `%s` for `%s`",
				type_name(k.c, concrete),
				identifier_text(k.c, slot.name),
				type_name(k.c, target),
			)
			v.type = INVALID_TYPE
			return
		}
	}
	v.operation = Call_Dyn_Conversion{witness = witness}
}

// design.md "any_view type": `view.as(T)` becomes the same checked extraction
// node as `view.(T)`. Only an `any_view` receiver takes it; any other type keeps
// its own `as` member.
check_any_view_as :: proc(k: ^Checker, v: ^Expr_Call, sel: ^Expr_Selector) -> bool {
	if sel.name.text != "as" {
		return false
	}
	// A package selector names a declaration, not a value receiver.
	if ident, ok := sel.operand.(^Expr_Ident); ok {
		if sym := symbol_of(k.c, lookup_symbol(k.scope, identifier_of(k.c, ident))); sym != nil &&
		   sym.kind == .Package_Alias {
			return false
		}
	}
	if check_single_expr(k, sel.operand) != TYPE_ANY_VIEW {
		return false
	}

	v.value_category = .Value
	v.resolution = Resolution{kind = .Builtin_Operator}
	bound := make([]Expr, 1, k.c.semantic_allocator)
	bound[0] = sel.operand
	v.bound = bound

	if len(v.args) != 1 || v.args[0].name.text != "" || v.args[0].mode != .Value ||
	   v.args[0].value == nil {
		errorf(
			k.c, v.span, "L0425",
			"`as` names the requested type as its one positional argument, found %d argument%s",
			len(v.args), len(v.args) == 1 ? "" : "s",
		)
		v.type = INVALID_TYPE
		return true
	}

	extract := new(Expr_Checked_Extract, k.c.semantic_allocator)
	extract.span = v.span
	extract.operand = sel.operand
	extract.target = v.args[0].value
	extract.mode = .Optional
	v.operation = Call_Extract{node = extract}

	check_extract_of(k, extract, TYPE_ANY_VIEW)
	v.type = extract.type
	return true
}

check_any_view_extract :: proc(k: ^Checker, v: ^Expr_Checked_Extract) {
	target := resolve_type_syntax(k, v.target)
	if target == INVALID_TYPE {
		errorf(k.c, expr_span(v.target), "L0465", "a checked extraction names the requested type")
		v.type = INVALID_TYPE
		return
	}
	if !any_view_accepts(k.c, target) {
		errorf(
			k.c,
			expr_span(v.target),
			"L0465",
			"`%s` is not a concrete type an `any_view` can hold",
			type_name(k.c, target),
		)
		v.type = INVALID_TYPE
		return
	}
	// `.as(T)` gives `Option(T)`; `.(T)` traps on a mismatch.
	v.payload = target
	v.type = v.mode == .Optional ? option_type(k, target, v.span) : target
	if type_clone_disabled(k.c, target) {
		errorf(k.c, v.span, "L0503", "`%s` is move-only, so a checked extraction cannot copy it from an `any_view`", type_name(k.c, target))
		return
	}
	contribute_lifecycle_members(k, target)
	request_typeid(k.c, target)
}

// `view.draw(inout canvas)`: an indirect call through the witness.
check_dyn_slot_call :: proc(k: ^Checker, v: ^Expr_Call, sel: ^Expr_Selector, dyn: Type_Id) -> bool {
	name := intern_identifier(k.c, sel.name.text)
	index, entry, found := dyn_slot_index(k, dyn, name)
	if !found {
		return false
	}
	owner := interface_info_for(k, entry.owner)
	params, modes, result_type, result_inout, ok := slot_signature_for(k, owner, entry, dyn)
	if !ok {
		errorf(k.c, v.span, "L0467", "`%s`'s signature does not resolve here", sel.name.text)
		v.type = INVALID_TYPE
		return true
	}
	if !dyn_is_mutable(k.c, dyn) && len(modes) > 0 && modes[0] == .Inout {
		errorf(
			k.c,
			v.span,
			"L0643",
			"slot `%s` mutates its subject, so it needs `dyn mut %s`",
			sel.name.text,
			identifier_text(k.c, symbol_of(k.c, owner.symbol).name),
		)
		v.type = INVALID_TYPE
		return true
	}

	v.value_category = .Value
	if len(v.args) != len(params) - 1 {
		errorf(
			k.c,
			v.span,
			"L0467",
			"slot `%s` takes %d argument%s, found %d",
			sel.name.text,
			len(params) - 1,
			len(params) - 1 == 1 ? "" : "s",
			len(v.args),
		)
		v.type = INVALID_TYPE
		return true
	}
	bound := make([]Expr, len(params), k.c.semantic_allocator)
	filled := make([]bool, len(params), k.c.semantic_allocator)
	order := make([dynamic]int, 0, len(params), k.c.semantic_allocator)
	bound[0] = sel.operand
	filled[0] = true
	append(&order, 0)
	named := false
	for arg, position in v.args {
		slot := position + 1
		if arg.name.text != "" {
			named = true
			slot = -1
			target := intern_identifier(k.c, arg.name.text)
			flat := 0
			for parameter in entry.type.params {
				for parameter_name in parameter.names {
					if intern_identifier(k.c, parameter_name.name.text) == target {
						slot = flat
						break
					}
					flat += 1
				}
				if slot >= 0 { break }
			}
			if slot < 0 {
				errorf(k.c, arg.span, "L0371", "no parameter named `%s`", arg.name.text)
				v.type = INVALID_TYPE
				return true
			}
			if filled[slot] {
				errorf(k.c, arg.span, "L0371", "`%s` is given twice", arg.name.text)
				v.type = INVALID_TYPE
				return true
			}
		} else if named {
			errorf(k.c, arg.span, "L0372", "a positional argument cannot follow a named one")
			v.type = INVALID_TYPE
			return true
		}
		filled[slot] = true
		append(&order, slot)
		want := params[slot]
		k.place_position, k.insert_position = modes[slot] == .Inout, false
		checked := check_single_expr(k, arg.value, want)
		k.place_position, k.insert_position = false, false
		if checked == INVALID_TYPE || !materialize_argument(k, arg.value, want) {
			v.type = INVALID_TYPE
			return true
		}
		if modes[slot] == .Inout {
			if base := expr_base(arg.value); base != nil && !base.assignable {
				report_not_assignable(k, base, "an `inout` argument")
				v.type = INVALID_TYPE
				return true
			}
		}
		bound[slot] = arg.value
	}
	v.bound = bound
	if named {
		v.bound_order = order[:]
	}
	v.operation = Call_Dyn_Slot{index = index}
	sel.type = intern_proc_type(k.c, params, modes, result_type, result_inout, "")
	set_call_result(v, result_type, result_inout)
	return true
}

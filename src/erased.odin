// Erased views, compiler-owned two-word structs:
//
//   dyn Interface  { ptr data, ptr witness }
//   dyn proc(...)  { ptr data, ptr code }
//
// A `dyn proc` view is `dyn interfaces.Callable(...)`, whose one slot is held
// directly: its second word is the code to call, not a table of slots.
//
// A witness is one private global per `(Interface, Concrete, arguments)`. Its
// slots come from inherent members plus extensions in the slot's declaring
// package, so one key means one behavior everywhere.
package lokec

import "core:fmt"
import "core:strings"

DYN_DATA :: 0
DYN_WITNESS :: 1

// design.md "Variadic parameters": the element of a `..dyn I` pack, which views
// each value written at the call. A `dyn mut I` pack and a `dyn proc` pack take
// views as they are.
variadic_view_element :: proc(c: ^Compiler, element: Type_Id) -> bool {
	info := underlying_info(c, element)
	return info != nil && info.kind == .Dyn && !info.mutable && !dyn_is_callable(c, info)
}

// Whether a value of type `from` written into a `..dyn I` pack is viewed. A
// value already assignable to the element, such as a `dyn I`, a `dyn mut I`, or
// a view of a composing interface, is passed as it is.
variadic_view_accepts :: proc(c: ^Compiler, from, element: Type_Id) -> bool {
	if !variadic_view_element(c, element) || from == INVALID_TYPE || assignable(c, from, element) {
		return false
	}
	if type_is_untyped(c, from) {
		return from != TYPE_UNTYPED_NIL // through its default type
	}
	// design.md "Zero values": a `type` or descriptor exists only while
	// compiling, so there is nothing at run time for a view to point at.
	return type_is_supported(c, from) && compile_time_only_component(c, from) == INVALID_TYPE &&
	       !type_is_capture_record(c, from)
}

// Whether `concrete` satisfies the interface a `..dyn I` pack views through,
// reporting nothing, as ranking an overload must.
variadic_view_satisfied :: proc(k: ^Checker, concrete, element: Type_Id, span: Span) -> bool {
	dyn := underlying_info(k.c, element)
	info := interface_info_for(k, dyn.dyn_interface)
	return info != nil &&
	       interface_satisfied(k, info, interface_application(k.c, info, concrete, dyn.dyn_args), span, report = false)
}

// The witness by which `concrete` is viewed as the `dyn` type `view`, or nil once
// it has reported why there is none. An explicit conversion and a pack element
// differ in their operands and agree on this.
dyn_view_witness :: proc(k: ^Checker, concrete, view: Type_Id, span: Span) -> ^Witness {
	dyn := underlying_info(k.c, view)
	info := interface_info_for(k, dyn.dyn_interface)
	if info == nil || !interface_satisfied(k, info, interface_application(k.c, info, concrete, dyn.dyn_args), span, report = true) {
		return nil
	}
	witness := request_witness(k, info, concrete, dyn.dyn_args, span)
	for slot in witness.slots {
		if slot.target == INVALID_SYMBOL {
			errorf(
				k.c, span, "L0464",
				"`%s` supplies no coherent `%s` for `%s`",
				type_name(k.c, concrete), identifier_text(k.c, slot.name), type_name(k.c, view),
			)
			return nil
		}
	}
	return witness
}

// One element of a `..dyn I` pack: a value is viewed where it is, or in a
// temporary that lives through the call, with the witness of its type.
pass_variadic_element :: proc(k: ^Checker, e: Expr, element: Type_Id, prechecked: bool) -> (Expr, bool) {
	if !variadic_view_element(k.c, element) {
		return pass_argument(k, e, element, prechecked)
	}
	if !prechecked && check_single_expr(k, e, element) == INVALID_TYPE {
		return e, false
	}
	base := expr_base(e)
	if base == nil || base.type == INVALID_TYPE {
		return e, false
	}
	if !variadic_view_accepts(k.c, base.type, element) {
		if offender := compile_time_only_component(k.c, base.type); offender != INVALID_TYPE {
			report_compile_time_only(k, offender, base.span)
			return e, false
		}
		// design.md "Borrowed callable views": a capture literal is held only by
		// a `dyn proc` view.
		if type_is_capture_record(k.c, base.type) {
			errorf(
				k.c, base.span, "L0310",
				"`%s` is a capture literal, which only a `dyn proc` view holds, so no `%s` can view it",
				type_name(k.c, base.type), type_name(k.c, element),
			)
			return e, false
		}
		return e, materialize_value_expr(k, e, element, "pass")
	}
	if type_is_untyped(k.c, base.type) && !materialize(k, e, default_type(k.c, base.type)) {
		return e, false
	}
	concrete := base.type
	// design.md "String format printing": a `format` that cannot serve printing
	// is reported once, at its declaration (L0572), not at each print.
	if dyn_views_printing(k.c, element) && format_misdeclared(k.c, concrete) {
		base.erased_from = concrete
		base.type = element
		return e, true
	}
	if dyn_view_witness(k, concrete, element, base.span) == nil {
		return e, false
	}
	base.erased_from = concrete
	base.type = element
	return e, true
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
		stored.backend_label = fmt.aprintf("dyn.%s", identifier_text(k.c, name), allocator = k.c.semantic_allocator)
	}
	k.c.dyn_types[key] = type
	install_dyn_forwarding_slots(k, info, args, type)
	return type
}

// design.md: `dyn I` satisfies `I` through forwarding methods that call
// through the view's own witness.
@(private = "file")
install_dyn_forwarding_slots :: proc(k: ^Checker, info: ^Interface_Info, args: []Generic_Arg, dyn: Type_Id) {
	if signature := dyn_proc_signature(k.c, dyn); signature != INVALID_TYPE {
		install_dyn_call_slot(k, dyn, signature)
		return
	}
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
		// The slot's parameter names, so `(dyn I).slot(view, name = ...)` binds
		// named arguments as `check_dyn_slot_call` does.
		param_symbols := make([]Symbol_Id, len(params), k.c.semantic_allocator)
		for written, position in slot_parameter_names(k, entry) {
			if written != INVALID_IDENTIFIER && position < len(params) {
				param_symbols[position] = new_symbol(k.c, Symbol {
					name = written, kind = .Parameter, type = params[position], mode = modes[position],
				})
			}
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
			param_symbols  = param_symbols,
			param_defaults = make([]Expr, len(params), k.c.semantic_allocator),
			proc_type      = intern_proc_type(k.c, params, modes, result_type, result_inout, ""),
			synth          = .Dyn_Forward,
			has_receiver   = true,
			receiver       = modes[0],
			index          = u32(index),
		})
		members[index] = id
		enroll_synth(k.c, id)
	}
	if stored := type_of(k.c, dyn); stored != nil {
		stored.members = members
	}
}

// design.md "Borrowed callable views": a `dyn proc` view's one member is the
// `call` its signature describes. It keeps the signature's escape levels and
// reset effects, so a call through the view is checked as a call of the
// signature. A procedure the view holds is called through an adapter of the
// same shape.
@(private = "file")
install_dyn_call_slot :: proc(k: ^Checker, dyn, signature: Type_Id) {
	wanted := underlying_info(k.c, signature)
	count := len(wanted.parameters) + 1
	params := make([]Type_Id, count, k.c.semantic_allocator)
	modes := make([]Param_Mode, count, k.c.semantic_allocator)
	resets := make([]bool, count, k.c.semantic_allocator)
	escapes := make([]Escape_Level, count, k.c.semantic_allocator)
	crosses := make([]bool, count, k.c.semantic_allocator)
	params[0], modes[0], escapes[0] = dyn, .Value, .Result
	for parameter, index in wanted.parameters {
		params[index + 1] = parameter
		modes[index + 1] = proc_parameter_mode(k.c, signature, index)
		resets[index + 1] = index < len(wanted.param_resets) && wanted.param_resets[index]
		escapes[index + 1] = proc_param_escape(k.c, signature, index)
		crosses[index + 1] = proc_param_crosses_thread(k.c, signature, index)
	}
	proc_type := intern_proc_type(
		k.c, params, modes, wanted.result, wanted.result_inout, "",
		param_resets = resets, param_escapes = escapes,
		proc_contract = receiver_contract(k.c, wanted.proc_contract),
		param_cross_thread = crosses,
	)
	member := new_symbol(k.c, Symbol {
		name           = intern_identifier(k.c, "call"),
		span           = no_span(),
		kind           = .Proc,
		public         = true,
		owner_type     = dyn,
		params         = params,
		result         = wanted.result,
		result_inout   = wanted.result_inout,
		param_symbols  = make([]Symbol_Id, count, k.c.semantic_allocator),
		param_defaults = make([]Expr, count, k.c.semantic_allocator),
		proc_type      = proc_type,
		synth          = .Dyn_Forward,
		has_receiver   = true,
		receiver       = .Value,
	})
	enroll_synth(k.c, member)
	adapter_params := make([]Type_Id, count, k.c.semantic_allocator)
	copy(adapter_params, params)
	adapter_params[0] = TYPE_RAWPTR
	k.c.dyn_proc_adapters[dyn] = new_symbol(k.c, Symbol {
		name           = intern_identifier(k.c, "call$procedure"),
		span           = no_span(),
		kind           = .Proc,
		owner_type     = dyn,
		params         = adapter_params,
		result         = wanted.result,
		result_inout   = wanted.result_inout,
		param_symbols  = make([]Symbol_Id, count, k.c.semantic_allocator),
		param_defaults = make([]Expr, count, k.c.semantic_allocator),
		proc_type      = intern_proc_type(k.c, adapter_params, modes, wanted.result, wanted.result_inout, ""),
		synth          = .Dyn_Proc_Adapter,
	})
	if stored := type_of(k.c, dyn); stored != nil {
		members := make([]Symbol_Id, 1, k.c.semantic_allocator)
		members[0] = member
		stored.members = members
	}
}

// design.md "Borrowed callable views": `dyn interfaces.Callable(Signature)`,
// spelled `dyn proc(...)`.
dyn_is_callable :: proc(c: ^Compiler, info: ^Type_Info) -> bool {
	return info != nil && info.kind == .Dyn && len(info.dyn_args) == 1 && info.dyn_args[0].is_type &&
	       symbol_is_callable(c, info.dyn_interface)
}

// The signature a `dyn proc` view calls, or INVALID_TYPE for any other type.
dyn_proc_signature :: proc(c: ^Compiler, type: Type_Id) -> Type_Id {
	info := underlying_info(c, type)
	return dyn_is_callable(c, info) ? info.dyn_args[0].type : INVALID_TYPE
}

// design.md "Borrowed callable views": what converts to a `dyn proc` view
// without being written: a procedure that converts to its signature, and a
// capture literal whose `call` meets it. A named callable record converts only
// where it is written, as any `dyn` view does.
dyn_proc_accepts :: proc(c: ^Compiler, from, signature: Type_Id) -> bool {
	if underlying_kind(c, from) == .Proc {
		return assignable(c, from, signature)
	}
	method, is_capture := c.capture_records[from]
	return is_capture && method != nil && call_method_matches(c, symbol_of(c, method.symbol), from, signature)
}

// The signature a value converting implicitly to a `dyn proc` view calls with:
// a procedure's own type, or a capture literal's `call` without its receiver.
// INVALID_TYPE for anything else.
dyn_proc_source_signature :: proc(c: ^Compiler, from: Type_Id) -> Type_Id {
	if underlying_kind(c, from) == .Proc {
		return type_underlying(c, from)
	}
	method, is_capture := c.capture_records[from]
	sym := is_capture && method != nil ? symbol_of(c, method.symbol) : nil
	info := sym == nil ? nil : type_of(c, sym.proc_type)
	if info == nil || len(info.parameters) == 0 {
		return INVALID_TYPE
	}
	escapes: []Escape_Level
	if len(info.param_escapes) > 1 {
		escapes = info.param_escapes[1:]
	}
	resets: []bool
	if len(info.param_resets) > 1 {
		resets = info.param_resets[1:]
	}
	crosses: []bool
	if len(info.param_cross_thread) > 1 {
		crosses = info.param_cross_thread[1:]
	}
	return intern_proc_type(
		c, info.parameters[1:], info.param_modes[1:], info.result, info.result_inout, "",
		param_resets = resets, param_escapes = escapes, param_cross_thread = crosses,
	)
}

// Records what emission needs to build the view: the adapter for a procedure,
// or the capture literal's witness.
request_dyn_proc_view :: proc(k: ^Checker, from, view: Type_Id, span: Span) {
	if underlying_kind(k.c, from) == .Proc {
		enroll_synth(k.c, k.c.dyn_proc_adapters[dyn_abi_type(k.c, view)])
		return
	}
	dyn := underlying_info(k.c, view)
	if info := interface_info_for(k, dyn.dyn_interface); info != nil {
		request_witness(k, info, from, dyn.dyn_args, span)
	}
}

// The witness already requested for one key.
lookup_witness :: proc(c: ^Compiler, interface_symbol: Symbol_Id, concrete: Type_Id, args: []Generic_Arg) -> ^Witness {
	return c.witnesses[witness_key(c, interface_symbol, concrete, args)]
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
	if interface_is_callable(c, info) && len(args) == 1 && args[0].is_type {
		strings.write_string(&b, type_name(c, args[0].type))
		return strings.to_string(b)
	}
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
		if !generic_arg_equal(c, arg, b.dyn_args[index]) {
			return false
		}
	}
	return true
}

// design.md "Globals while tasks run": the concrete types the program converts
// to `view`'s interface application, under either capability. A procedure a
// callable view holds directly has no witness, and reaches nothing.
view_witness_types :: proc(c: ^Compiler, view: ^Type_Info) -> []Type_Id {
	out := make([dynamic]Type_Id, 0, 4, context.temp_allocator)
	outer: for witness in c.witness_order {
		if witness.interface_symbol != view.dyn_interface || len(witness.args) != len(view.dyn_args) {
			continue
		}
		for arg, index in witness.args {
			if !generic_arg_equal(c, arg, view.dyn_args[index]) {
				continue outer
			}
		}
		append(&out, witness.concrete)
	}
	return out[:]
}

// design.md's five rules, computed once per declaration.
dyn_compatible :: proc(k: ^Checker, info: ^Interface_Info) -> bool {
	if info.dyn_computed {
		return info.dyn_ok
	}
	info.dyn_computed = true
	info.dyn_ok = false

	// design.md "Borrowed callable views": its one slot, `call`, comes from the
	// signature, and the view holds it directly.
	if interface_is_callable(k.c, info) {
		info.dyn_ok = true
		return true
	}

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
		// Its `call` is held by a `dyn proc` view alone, never as one slot of many.
		if interface_is_callable(k.c, composed) {
			info.dyn_reason = "it composes `Callable`, whose `call` only a `dyn proc` view erases"
			return false
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
	name := name
	return type_syntax_any_name(e, &name, proc(data: rawptr, node: Expr) -> bool {
		#partial switch v in node {
		case ^Expr_Ident:
			return v.name_id == (^Identifier_Id)(data)^
		case ^Type_Poly, ^Expr_Selector, ^Type_Distinct:
			return false
		}
		return true // a declared body, conservatively
	})
}

// Evidence that one concrete type satisfies one interface application.
Witness :: struct {
	interface_symbol: Symbol_Id,
	concrete:         Type_Id,
	args:             []Generic_Arg,
	// In the flattened order slot calls index by.
	slots:            []Witness_Slot,
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
	// A composed application's arguments may name this one's associated constants.
	k.body = {requiring = info, requiring_args = args}

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

	if interface_is_callable(k.c, info) {
		witness.slots = callable_witness_slots(k, info, concrete, args)
		// The method behind the view meets the signature's inferred contract.
		if method := symbol_of(k.c, witness.slots[0].target); method != nil {
			if view, found := k.c.dyn_types[dyn_key(k.c, info.symbol, args, false)]; found {
				if members := type_of(k.c, view).members; len(members) > 0 {
					record_call_contract_check(k.c, method.proc_type, symbol_of(k.c, members[0]).proc_type, span)
				}
			}
		}
		if committing(k.c) {
			k.c.witnesses[key] = witness
			append(&k.c.witness_order, witness)
			enroll_synth(k.c, witness.slots[0].target)
		}
		return witness
	}
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
	if committing(k.c) {
		k.c.witnesses[key] = witness
		append(&k.c.witness_order, witness)
		for slot in slots { enroll_synth(k.c, slot.target) }
	}
	return witness
}

// A callable's one slot is its `call` method, for `Callable(concrete,
// Signature)` with the signature as the one non-subject argument.
@(private = "file")
callable_witness_slots :: proc(k: ^Checker, info: ^Interface_Info, concrete: Type_Id, args: []Generic_Arg) -> []Witness_Slot {
	slots := make([]Witness_Slot, 1, k.c.semantic_allocator)
	signature := args[0].type
	wanted := underlying_info(k.c, signature)
	params := make([]Type_Id, len(wanted.parameters) + 1, k.c.semantic_allocator)
	params[0] = concrete
	copy(params[1:], wanted.parameters)
	slots[0] = Witness_Slot {
		name   = intern_identifier(k.c, "call"),
		target = callable_call_method(k, info, concrete, signature),
		mode   = .Value,
		params = params,
		result = wanted.result,
	}
	return slots
}

@(private = "file")
witness_key :: proc(c: ^Compiler, interface_symbol: Symbol_Id, concrete: Type_Id, args: []Generic_Arg) -> string {
	b := strings.builder_make(c.semantic_allocator)
	fmt.sbprintf(&b, "%d|%d", u32(interface_symbol), u32(concrete))
	write_arg_keys(c, &b, args)
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

// The name each of a slot's parameters is written with, aligned with
// `slot_signature`'s parameters; an unnamed one is INVALID_IDENTIFIER.
@(private = "file")
slot_parameter_names :: proc(k: ^Checker, entry: Interface_Slot) -> []Identifier_Id {
	names := make([dynamic]Identifier_Id, 0, len(entry.type.params), context.temp_allocator)
	for parameter in entry.type.params {
		if len(parameter.names) == 0 {
			append(&names, INVALID_IDENTIFIER)
		}
		for written in parameter.names {
			append(&names, intern_identifier(k.c, written.name.text))
		}
	}
	return names[:]
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
	if signature, is_proc := v.interface_expr.(^Type_Proc); is_proc {
		info := callable_interface(k)
		resolved := resolve_type_syntax(k, signature)
		if info == nil || resolved == INVALID_TYPE {
			return INVALID_TYPE
		}
		return callable_dyn_type(k, info, resolved, v)
	}
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
	if interface_is_callable(k.c, info) {
		return callable_dyn_type(k, info, bound[0].type, v)
	}
	return dyn_type(k, info, bound, v.span, v.mutable, report = true)
}

// design.md "Borrowed callable views": the view of one signature, which a
// method's plain `self` makes read-only and a slot makes Loke-convention.
@(private = "file")
callable_dyn_type :: proc(k: ^Checker, info: ^Interface_Info, signature: Type_Id, v: ^Type_Dyn) -> Type_Id {
	wanted := underlying_info(k.c, signature)
	if wanted == nil || wanted.kind != .Proc {
		errorf(k.c, v.span, "L0463", "a callable view takes a procedure type, found `%s`", type_name(k.c, signature))
		return INVALID_TYPE
	}
	if v.mutable {
		errorf(k.c, v.span, "L0463", "a callable view is read-only: a `call` takes a plain `self`, so write `dyn %s`", type_name(k.c, signature))
		return INVALID_TYPE
	}
	if wanted.convention != "" || wanted.c_vararg {
		errorf(k.c, v.span, "L0463", "a callable view calls through the Loke convention, so its signature cannot be `%s`", type_name(k.c, signature))
		return INVALID_TYPE
	}
	args := make([]Generic_Arg, 1, k.c.semantic_allocator)
	args[0] = Generic_Arg{is_type = true, type = signature}
	return dyn_type(k, info, args, v.span, false, report = true)
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

	pointer := underlying_info(k.c, source)
	// design.md "Borrowed callable views": a procedure or a capture literal is
	// the implicit conversion written out.
	if signature := dyn_proc_signature(k.c, target); signature != INVALID_TYPE {
		if pointer == nil || pointer.kind != .Pointer {
			v.operation = Call_Conversion{}
			if !materialize_value_expr(k, v.args[0].value, target, "convert") {
				v.type = INVALID_TYPE
			}
			return
		}
		if underlying_kind(k.c, pointer.element) == .Proc {
			errorf(
				k.c, expr_span(v.args[0].value), "L0464",
				"a procedure converts to `%s` by value, so it takes `%s`, not a pointer to one",
				type_name(k.c, target), type_name(k.c, pointer.element),
			)
			v.type = INVALID_TYPE
			return
		}
	}
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
	witness := dyn_view_witness(k, pointer.element, target, v.span)
	if witness == nil {
		v.type = INVALID_TYPE
		return
	}
	v.operation = Call_Dyn_Conversion{witness = witness}
}

// A union receiver takes `u.as(.name)` (design.md "Inspecting a union"); any
// other type keeps its own `as` member.
check_as_call :: proc(k: ^Checker, v: ^Expr_Call, sel: ^Expr_Selector) -> bool {
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
	subject := check_single_expr(k, sel.operand)
	if type_is_union(k.c, type_underlying(k.c, subject)) {
		return check_union_as(k, v, sel, subject)
	}
	return false
}

// A name a `dyn` view has no member for: a slot it has not, or, since
// design.md "Borrowed dynamic interface values" says a `dyn I` hides the slots
// that mutate their subject, a capability error naming `dyn mut I`, never a
// missing member. A callable view's one member is not a slot.
report_missing_dyn_slot :: proc(k: ^Checker, span: Span, dyn: Type_Id, name: string) -> bool {
	if !type_is_dyn(k.c, dyn) || dyn_proc_signature(k.c, dyn) != INVALID_TYPE {
		return false
	}
	_, entry, found := dyn_slot_index(k, dyn, intern_identifier(k.c, name))
	if !found {
		errorf(k.c, span, "L0467", "`%s` has no slot `%s`", type_name(k.c, dyn), name)
		return true
	}
	if dyn_is_mutable(k.c, dyn) {
		return false
	}
	owner := interface_info_for(k, entry.owner)
	_, modes, _, _, ok := slot_signature_for(k, owner, entry, dyn)
	if !ok || len(modes) == 0 || modes[0] != .Inout {
		return false
	}
	errorf(
		k.c,
		span,
		"L0643",
		"slot `%s` mutates its subject, so it needs `dyn mut %s`",
		name,
		identifier_text(k.c, symbol_of(k.c, owner.symbol).name),
	)
	return true
}

// `view.draw(inout canvas)`: an indirect call through the witness.
check_dyn_slot_call :: proc(k: ^Checker, v: ^Expr_Call, sel: ^Expr_Selector, dyn: Type_Id) -> bool {
	name := intern_identifier(k.c, sel.name.text)
	index, entry, found := dyn_slot_index(k, dyn, name)
	if !found {
		return false
	}
	if report_missing_dyn_slot(k, v.span, dyn, sel.name.text) {
		v.type = INVALID_TYPE
		return true
	}
	params, modes, result_type, result_inout, ok := slot_signature_for(k, interface_info_for(k, entry.owner), entry, dyn)
	if !ok {
		errorf(k.c, v.span, "L0467", "`%s`'s signature does not resolve here", sel.name.text)
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
			for written, flat in slot_parameter_names(k, entry) {
				if written == target {
					slot = flat
					break
				}
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
		if arg.mode == .Spread {
			errorf(k.c, arg.span, "L0371", "`..` needs a variadic parameter to spread into")
			v.type = INVALID_TYPE
			return true
		}
		// design.md "Parameters": the written mode must match the slot's, as in
		// any other call.
		value, passed := bind_written_argument(k, arg, params[slot], modes[slot])
		if !passed {
			v.type = INVALID_TYPE
			return true
		}
		bound[slot] = value
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

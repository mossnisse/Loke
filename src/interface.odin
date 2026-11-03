// Interfaces and requirement checking.
//
// An application such as `Additive(int)` is a compile-time boolean. Each
// requirement is checked as ordinary code in a scratch checker whose diagnostics
// become the failure reason. Free requirements use the application's lookup
// package; a slot is matched by an inherent method or an extension in the
// package of the interface that declares it.
package lokec

import "core:fmt"
import "core:slice"
import "core:strings"

// A flattened slot, with the interface that declared it and that interface's
// arguments, so its signature resolves in its own package.
Interface_Slot :: struct {
	name:  Identifier_Id,
	span:  Span,
	type:  ^Type_Proc,
	owner: Symbol_Id,
	args:  []Generic_Arg,
}

Interface_Info :: struct {
	symbol:    Symbol_Id,
	node:      ^Type_Interface,
	scope:     ^Scope,
	pkg:       Package_Id,
	file:      u32,
	file_node: ^File,
	params:    []Generic_Param_Decl,
	checked:   bool,
	// Computed once per declaration, with the rule that disqualified it.
	dyn_computed: bool,
	dyn_ok:       bool,
	dyn_reason:   string,
}

// ------------------------------------------------------------ registration --

interface_info_for :: proc(k: ^Checker, symbol_id: Symbol_Id) -> ^Interface_Info {
	if symbol_id == INVALID_SYMBOL {
		return nil
	}
	if info, found := k.c.interfaces[symbol_id]; found {
		return info
	}
	sym := symbol_of(k.c, symbol_id)
	if sym == nil || sym.decl == nil || sym.kind != .Type || len(sym.decl.values) != 1 {
		return nil
	}
	node, is_interface := sym.decl.values[0].(^Type_Interface)
	if !is_interface {
		return nil
	}

	info := new(Interface_Info, k.c.semantic_allocator)
	info.symbol = symbol_id
	info.node = node
	info.pkg = sym.pkg
	info.file, info.file_node = sym.def_file, sym.def_file_node
	info.scope = sym.def_scope
	if info.scope == nil {
		if pkg := package_of(k.c, sym.pkg); pkg != nil {
			info.scope = pkg.scope
		}
	}
	params := make([dynamic]Generic_Param_Decl, 0, 4, k.c.semantic_allocator)
	for group in node.generic_params {
		for name in group.names {
			append(&params, Generic_Param_Decl{name = name_identifier(k.c, name), span = name.span, type_syntax = group.type})
		}
	}
	info.params = params[:]
	k.c.interfaces[symbol_id] = info
	return info
}

type_is_interface :: proc(c: ^Compiler, id: Type_Id) -> bool {
	return type_kind(c, id) == .Interface
}

// --------------------------------------------------------- declaration --

// design.md "Interface bodies": the shape rules that hold whatever the
// arguments are. Satisfaction is checked per application, not here.
check_interface_declaration :: proc(k: ^Checker, symbol_id: Symbol_Id) {
	info := interface_info_for(k, symbol_id)
	if info == nil || info.checked {
		return
	}
	info.checked = true
	if len(info.params) == 0 {
		errorf(
			k.c,
			info.node.span,
			"L0441",
			"an interface declares its subject as a generic parameter, as in `interface($Self: type)`",
		)
	} else if _, is_type := info.params[0].type_syntax.(^Type_Type); !is_type {
		errorf(
			k.c,
			info.params[0].span,
			"L0441",
			"an interface's first generic parameter is its subject and must have type `type`",
		)
	}

	seen := make([dynamic]Identifier_Id, 0, 4, context.temp_allocator)
	for requirement in info.node.requirements {
		if requirement.kind != .Slot {
			continue
		}
		name := name_identifier(k.c, requirement.name)
		if slice.contains(seen[:], name) {
			errorf(k.c, requirement.span, "L0442", "`%s` is already a slot of this interface", requirement.name.text)
		} else {
			append(&seen, name)
		}
		signature, is_proc := requirement.slot_type.(^Type_Proc)
		if !is_proc {
			errorf(k.c, requirement.span, "L0442", "a `slot` requirement needs a procedure type")
			continue
		}
		if len(signature.params) == 0 || len(signature.params[0].names) == 0 ||
		   signature.params[0].names[0].name.text != "self" {
			errorf(
				k.c,
				requirement.span,
				"L0442",
				"a `slot` requirement's first parameter is the receiver `self`",
			)
		} else if !slot_receiver_is_subject(k, info, signature.params[0]) {
			errorf(
				k.c,
				requirement.span,
				"L0442",
				"a `slot` requirement's receiver `self` must have the interface's subject type",
			)
		}
	}
	check_composed_slot_names(k, info)
}

// design.md "Receiver forms": a receiver's type, left out, is the subject, and
// written it must be, behind a read-only pointer for `self: ^Self`. In
// `proc(self, other: T)` the type belongs to `other`.
@(private = "file")
slot_receiver_is_subject :: proc(k: ^Checker, info: ^Interface_Info, receiver: Parameter) -> bool {
	if receiver.type == nil || parameter_splits_receiver(receiver, 0) || len(info.params) == 0 {
		return true
	}
	written := receiver.type
	if pointer, is_pointer := written.(^Type_Pointer); is_pointer && receiver.mode == .Value && !pointer.mutable {
		written = pointer.elem
	}
	name, is_name := written.(^Expr_Ident)
	return is_name && identifier_of(k.c, name) == info.params[0].name
}

// design.md "Interface bodies": slot names are unique across everything an
// interface composes. Names do not depend on arguments, so this is syntactic.
@(private = "file")
check_composed_slot_names :: proc(k: ^Checker, info: ^Interface_Info) {
	owners := make(map[Identifier_Id]Symbol_Id, 8, context.temp_allocator)
	visited := make(map[Symbol_Id]bool, 8, context.temp_allocator)
	visited[info.symbol] = true
	for requirement in info.node.requirements {
		add_slot_owners(k, info, requirement, requirement.span, &owners, &visited)
	}
}

// Records the slots `requirement` brings in, reporting any name an earlier one
// already brought from a different interface.
@(private = "file")
add_slot_owners :: proc(
	k: ^Checker,
	owner: ^Interface_Info,
	requirement: Requirement,
	at: Span,
	owners: ^map[Identifier_Id]Symbol_Id,
	visited: ^map[Symbol_Id]bool,
) {
	if requirement.kind == .Slot {
		name := name_identifier(k.c, requirement.name)
		previous, found := owners[name]
		if !found {
			owners[name] = owner.symbol
		} else if previous != owner.symbol {
			errorf(
				k.c, at, "L0442", "`%s` is a slot of both `%s` and `%s`",
				requirement.name.text,
				identifier_text(k.c, symbol_of(k.c, previous).name),
				identifier_text(k.c, symbol_of(k.c, owner.symbol).name),
			)
		}
		return
	}
	saved := k.location
	defer k.location = saved
	enter_interface(k, owner, nil)
	composed := composed_interface_of(k, requirement)
	if composed == nil || visited[composed.symbol] {
		return
	}
	visited[composed.symbol] = true
	for nested in composed.node.requirements {
		add_slot_owners(k, composed, nested, at, owners, visited)
	}
}

// ------------------------------------------------------------ application --

// `Additive(int)` as an expression. Only argument mistakes are errors; an
// unsatisfied interface is just `false`.
check_interface_application :: proc(k: ^Checker, v: ^Expr_Call, info: ^Interface_Info) {
	v.value_category = .Value
	v.type = TYPE_BOOL
	if len(v.args) != len(info.params) {
		errorf(
			k.c,
			v.span,
			"L0443",
			"`%s` takes %d argument%s, found %d",
			identifier_text(k.c, symbol_of(k.c, info.symbol).name),
			len(info.params),
			len(info.params) == 1 ? "" : "s",
			len(v.args),
		)
		v.type = INVALID_TYPE
		return
	}
	args, ok := interface_arguments_for(k, v.args, info, dyn_view = false, report = true)
	if !ok {
		v.type = INVALID_TYPE
		return
	}
	v.resolution = Resolution{kind = .Call, symbol = info.symbol}
	v.is_const = true
	v.const_value = bool_const(interface_satisfied(k, info, args, v.span, report = false))
}

// The one argument path. Parameter types resolve in the interface's scope with
// earlier parameters bound; arguments resolve at the use site. Values are
// converted to the parameter type, so equivalent spellings share witnesses. A
// `dyn` view writes every parameter but its erased subject. The caller has
// checked the number of arguments.
interface_arguments_for :: proc(
	k: ^Checker,
	written: []Argument,
	info: ^Interface_Info,
	dyn_view: bool,
	report: bool,
) -> ([]Generic_Arg, bool) {
	code := dyn_view ? "L0463" : "L0443"
	description := dyn_view ? "a `dyn` interface argument" : "an interface argument"
	if !generic_arguments_positional(k, written, code, report) {
		return nil, false
	}
	erased_subject := [1]Generic_Arg{{is_type = true, type = TYPE_RAWPTR}}
	first := dyn_view ? 1 : 0
	bindings := interface_scope(k, info, erased_subject[:first])
	out := make([]Generic_Arg, len(written), k.c.semantic_allocator)

	use_scope := k.scope
	defer k.scope = use_scope
	for arg, index in written {
		parameter := info.params[first + index]
		// As for a record's: `$F: dyn Scaled(T, 0)` applies this interface again.
		_, names_type := parameter.type_syntax.(^Type_Type)
		if !names_type {
			named := make([]Generic_Binding, index, context.temp_allocator)
			for &binding, at in named {
				binding.arg = out[at]
			}
			if !push_application_frame(k, arg.span, info.symbol, named, report) {
				return nil, false
			}
		}
		k.scope = bindings
		errors := k.c.error_count
		wanted := resolve_type_syntax(k, parameter.type_syntax)
		k.scope = use_scope
		if !names_type {
			pop(&k.c.instantiation_stack)
		}
		if wanted == INVALID_TYPE {
			if report && k.c.error_count == errors {
				errorf(k.c, parameter.span, code, "this interface parameter's type does not resolve")
			}
			return nil, false
		}

		value := Generic_Arg{}
		if wanted == TYPE_TYPE {
			errors = k.c.error_count
			denoted := resolve_type_syntax(k, arg.value)
			if denoted == INVALID_TYPE {
				if report && k.c.error_count == errors {
					errorf(k.c, arg.span, code, "%s of type `type` needs a type", description)
				}
				return nil, false
			}
			// design.md "Maps": key policies are settled where the map type is
			// named. Requirement checks on it contribute members whose bodies
			// need one, even when no value of the type is ever declared.
			if !require_nested_map_key_policies(k, denoted, arg.span) {
				return nil, false
			}
			value = Generic_Arg{is_type = true, type = denoted}
		} else {
			constant, ok := constant_interface_argument(k, arg, parameter, wanted, code, description, report)
			if !ok {
				return nil, false
			}
			value = constant
		}
		out[index] = value
		bind_generic_name(k, bindings, Generic_Binding {
			name = parameter.name,
			span = parameter.span,
			arg  = value,
		})
	}
	return out, true
}

// A compile-time value for a parameter of type `wanted`, converted to it.
@(private = "file")
constant_interface_argument :: proc(
	k: ^Checker,
	arg: Argument,
	parameter: Generic_Param_Decl,
	wanted: Type_Id,
	code, description: string,
	report: bool,
) -> (Generic_Arg, bool) {
	if poly, is_poly := arg.value.(^Type_Poly); is_poly {
		name := name_identifier(k.c, poly.name)
		if symbol := symbol_of(k.c, lookup_symbol(k.scope, name)); symbol != nil && symbol.kind == .Const {
			converted, fits := convert_const(k.c, symbol.const_value, wanted, false)
			fits &&= !type_is_enum(k.c, wanted) || assignable(k.c, symbol.type, wanted)
			fits &&= nil_converts(k.c, symbol.type, wanted)
			if !fits {
				if report {
					report_unrepresentable_argument(k, arg.span, code, symbol.const_value, wanted)
				}
				return {}, false
			}
			return Generic_Arg{value = converted, value_type = wanted}, true
		}
	}
	if check_single_expr(k, arg.value, wanted) == INVALID_TYPE {
		return {}, false
	}
	if base := expr_base(arg.value); base != nil && base.denoted_type != INVALID_TYPE {
		if report {
			errorf(
				k.c,
				arg.span,
				code,
				"%s for `$%s: %s` must be a compile-time value, found a type",
				description,
				identifier_text(k.c, parameter.name),
				type_name(k.c, wanted),
			)
		}
		return {}, false
	}
	folded, evaluated := require_const(k, arg.value, description, code)
	if !evaluated {
		return {}, false
	}
	converted, fits := convert_const(k.c, folded, wanted, false)
	fits &&= !type_is_enum(k.c, wanted) || assignable(k.c, expr_base(arg.value).type, wanted)
	fits &&= nil_converts(k.c, expr_base(arg.value).type, wanted)
	if !fits {
		if report {
			report_unrepresentable_argument(k, arg.span, code, folded, wanted)
		}
		return {}, false
	}
	return Generic_Arg{value = converted, value_type = wanted}, true
}

@(private = "file")
report_unrepresentable_argument :: proc(k: ^Checker, span: Span, code: string, value: Const_Value, wanted: Type_Id) {
	errorf(
		k.c, span, code,
		"`%s` is not representable by the interface parameter's type `%s`",
		const_key_text(k.c, value),
		type_name(k.c, wanted),
	)
}

// The arguments of an application written as `I(...)`: a composition, a `where`
// bound, or a slot's composed interface. Whatever goes wrong stays quiet, since
// such an application may simply be false (design.md "Interface bodies").
bound_arguments :: proc(k: ^Checker, call: ^Expr_Call, info: ^Interface_Info) -> ([]Generic_Arg, bool) {
	if len(call.args) != len(info.params) {
		return nil, false
	}
	probe := begin_probe(k.c)
	defer end_probe(k.c, probe)
	args, ok := interface_arguments_for(k, call.args, info, dyn_view = false, report = false)
	return args, ok && !errors_since(k.c, probe.diagnostics)
}

// `subject` followed by the non-subject `rest`: a full interface application.
interface_application :: proc(c: ^Compiler, info: ^Interface_Info, subject: Type_Id, rest: []Generic_Arg) -> []Generic_Arg {
	full := make([]Generic_Arg, len(info.params), c.semantic_allocator)
	if len(full) > 0 {
		full[0] = Generic_Arg{is_type = true, type = subject}
		copy(full[1:], rest)
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

// Moves into one application's scope, package and file, under the grant its
// requirements have: they, and the arguments of what it composes, reach its
// associated constants. The caller saves `k.location` and restores it.
enter_interface :: proc(k: ^Checker, info: ^Interface_Info, args: []Generic_Arg) {
	k.scope, k.pkg, k.lookup_pkg = interface_scope(k, info, args), info.pkg, info.pkg
	if info.file_node != nil {
		k.file, k.file_node = info.file, info.file_node
	}
	k.body = {requiring = info, requiring_args = args}
}

// The call an expression is, and the interface it applies if any.
interface_call_of :: proc(k: ^Checker, expr: Expr) -> (^Expr_Call, ^Interface_Info) {
	call, is_call := expr.(^Expr_Call)
	if !is_call {
		return nil, nil
	}
	return call, interface_info_for(k, named_callee_symbol(k, call.callee))
}

// ------------------------------------------------------- satisfaction --

Requirement_Failure :: struct {
	span:    Span,
	reason:  string,
}

@(private = "file")
requirement_failuref :: proc(k: ^Checker, span: Span, format: string, args: ..any) -> (Requirement_Failure, bool) {
	return Requirement_Failure{span = span, reason = fmt.aprintf(format, ..args, allocator = k.c.semantic_allocator)}, false
}

// Does `info` hold for these arguments? Only a `where` bound or a `dyn`
// conversion asks for the failure to be reported.
interface_satisfied :: proc(
	k: ^Checker,
	info: ^Interface_Info,
	args: []Generic_Arg,
	span: Span,
	report: bool,
) -> bool {
	failure, ok := interface_check(k, info, args)
	if !ok && report {
		errorf(k.c, span, "L0444", "%s", unsatisfied_text(k, info, args))
		if failure.reason != "" {
			add_notef(k.c, failure.span, "this requirement does not hold: %s", failure.reason)
		} else {
			add_notef(k.c, failure.span, "this requirement does not hold")
		}
	}
	return ok
}

@(private = "file")
unsatisfied_text :: proc(k: ^Checker, info: ^Interface_Info, args: []Generic_Arg) -> string {
	subject := len(args) > 0 && args[0].is_type ? args[0].type : INVALID_TYPE
	return fmt.aprintf(
		"`%s` does not satisfy `%s`",
		type_name(k.c, subject), interface_application_text(k.c, info, args),
		allocator = k.c.semantic_allocator,
	)
}

// A `where` bound that is a bare interface application reports the requirement
// that failed. Returns false for any other bound, which reports itself.
report_failed_interface_bound :: proc(k: ^Checker, clause: Expr, span: Span) -> bool {
	info, args, ok := bound_interface_application(k, clause)
	return ok && !interface_satisfied(k, info, args, span, report = true)
}

// The same failure as text, for a note on a candidate a false bound filtered
// out: the interface and its failed requirement, or else the bound as written.
failed_bound_text :: proc(k: ^Checker, clause: Expr) -> string {
	if info, args, ok := bound_interface_application(k, clause); ok {
		if failure, held := interface_check(k, info, args); !held {
			text := unsatisfied_text(k, info, args)
			if failure.reason != "" {
				text = fmt.aprintf("%s: %s", text, failure.reason, allocator = k.c.semantic_allocator)
			}
			return text
		}
	}
	return fmt.aprintf("its bound `%s` does not hold", where_bound_text(k.c, clause), allocator = k.c.semantic_allocator)
}

@(private = "file")
bound_interface_application :: proc(k: ^Checker, clause: Expr) -> (^Interface_Info, []Generic_Arg, bool) {
	call, info := interface_call_of(k, clause)
	if info == nil {
		return nil, nil, false
	}
	args, ok := bound_arguments(k, call, info)
	return info, args, ok
}

// `I(a, b)`, or `I` when it has no arguments.
interface_application_text :: proc(c: ^Compiler, info: ^Interface_Info, args: []Generic_Arg) -> string {
	text := identifier_text(c, symbol_of(c, info.symbol).name)
	if len(args) == 0 {
		return text
	}
	text = concat(c, text, "(")
	for arg, index in args {
		if index > 0 {
			text = concat(c, text, ", ")
		}
		text = concat(c, text, generic_argument_text(c, arg))
	}
	return concat(c, text, ")")
}

// What stops an interface whose composition names itself, however it does: how
// deep composition goes, and how much one outermost application may ask of it,
// since each level can apply several more.
MAX_INTERFACE_DEPTH :: 32
MAX_INTERFACE_STEPS :: 1 << 14

// Counts one application entered, or says the limits are reached. When it
// returns true the caller owes `k.interface_depth -= 1`.
step_into_interface :: proc(k: ^Checker) -> bool {
	if k.interface_depth == 0 {
		k.interface_steps = 0
	}
	if k.interface_depth >= MAX_INTERFACE_DEPTH || k.interface_steps >= MAX_INTERFACE_STEPS {
		return false
	}
	k.interface_depth += 1
	k.interface_steps += 1
	return true
}

@(private = "file")
interface_check :: proc(k: ^Checker, info: ^Interface_Info, args: []Generic_Arg) -> (Requirement_Failure, bool) {
	if failure, ok := interface_predicates_check(k, info, args); !ok {
		return failure, false
	}
	if interface_is_callable(k.c, info) {
		return callable_check(k, info, args)
	}
	if !step_into_interface(k) {
		return requirement_failuref(k, info.node.span, "this interface composes itself")
	}
	defer k.interface_depth -= 1
	// Speculation keeps a rejected probe from registering typeids or witnesses.
	// Each requirement rolls back its own diagnostics.
	probe := begin_probe(k.c)
	defer end_probe(k.c, probe, keep = true)

	application_pkg := lookup_package(k)
	saved := k.location
	defer k.location = saved
	enter_interface(k, info, args)
	scope := k.scope
	for requirement in info.node.requirements {
		// Checking annotates syntax, and one interface is applied to many types.
		clone := clone_requirement(k.c, requirement)
		k.scope = new_scope(k.c, scope, .Local)
		k.lookup_pkg = requirement.kind == .Slot ? info.pkg : application_pkg

		failure, ok := check_one_requirement(k, info, clone, args, application_pkg)
		if !ok {
			return failure, false
		}
	}
	// design.md "Private names in public declarations": what the requirements
	// select, this application says.
	append(&k.c.pending_private_reads, Pending_Private_Read {
		decl = symbol_of(k.c, info.symbol).decl,
		location = {scope = scope, pkg = info.pkg, lookup_pkg = info.pkg, impl_type = INVALID_TYPE, file = info.file, file_node = info.file_node},
	})
	return {}, true
}

// An interface's own `where` clauses, which must be true before any requirement
// is checked. `dyn` calls this with a placeholder subject, which dyn
// compatibility guarantees the predicates never inspect.
interface_predicates_check :: proc(
	k: ^Checker,
	info: ^Interface_Info,
	args: []Generic_Arg,
) -> (Requirement_Failure, bool) {
	if len(info.node.where_clauses) == 0 {
		return {}, true
	}
	if !step_into_interface(k) {
		return requirement_failuref(k, info.node.span, "this interface predicate is recursive")
	}
	defer k.interface_depth -= 1
	probe := begin_probe(k.c)
	defer end_probe(k.c, probe, keep = true)
	saved := k.location
	defer k.location = saved
	enter_interface(k, info, args)
	k.body = {}

	for clause in info.node.where_clauses {
		clone := clone_expr(k.c, clause)
		mark := len(k.c.diagnostics)
		type := check_single_expr(k, clone, TYPE_BOOL)
		folded, evaluated := require_const(k, clone, "an interface `where` bound", "L0444")
		reason, failed := captured_reason(k, mark, "this predicate is not a compile-time boolean")
		if type == INVALID_TYPE || failed || !evaluated || folded.kind != .Boolean {
			return Requirement_Failure{span = expr_span(clause), reason = reason}, false
		}
		if !folded.boolean {
			return requirement_failuref(k, expr_span(clause), "the predicate `%s` evaluates to false", where_bound_text(k.c, clause))
		}
	}
	return {}, true
}

// Rolls back the diagnostics since `mark`, returning what the first one said,
// or else `fallback`, and whether any was an error.
@(private = "file")
captured_reason :: proc(k: ^Checker, mark: int, fallback: string) -> (reason: string, failed: bool) {
	reason = fallback
	if mark < len(k.c.diagnostics) {
		reason = strings.clone(k.c.diagnostics[mark].message, k.c.semantic_allocator)
	}
	failed = errors_since(k.c, mark)
	truncate_diagnostics(k.c, mark)
	return
}

@(private = "file")
check_one_requirement :: proc(
	k: ^Checker,
	info: ^Interface_Info,
	requirement: Requirement,
	args: []Generic_Arg,
	application_pkg: Package_Id,
) -> (Requirement_Failure, bool) {
	if requirement.kind == .Slot {
		return check_slot_requirement(k, info, requirement, args, application_pkg)
	}

	// Composition: a bare interface application must hold, not merely compile.
	if requirement.result == nil {
		if call, composed := interface_call_of(k, requirement.expr); composed != nil {
			composed_args, ok := bound_arguments(k, call, composed)
			if !ok {
				return requirement_failuref(k, requirement.span, "its interface arguments do not resolve")
			}
			return interface_check(k, composed, composed_args)
		}
	}

	if failure, ok := bind_requirement_names(k, requirement); !ok {
		return failure, false
	}
	mark := len(k.c.diagnostics)
	// `-> inout T` asks for a place, which selects an `inout` `operator([])`
	// (design.md "Indexing and slicing").
	type := check_expr(k, requirement.expr, position = requirement.result_inout ? .Place : .Value)
	reason, failed := captured_reason(k, mark, "this expression does not compile for these arguments")
	if type == INVALID_TYPE || failed {
		return Requirement_Failure{span = requirement.span, reason = reason}, false
	}
	if requirement.result == nil {
		return truth_requirement_holds(k, requirement)
	}
	return requirement_result_holds(k, requirement)
}

// Bindings name hypothetical values or places; nothing ever constructs them.
@(private = "file")
bind_requirement_names :: proc(k: ^Checker, requirement: Requirement) -> (Requirement_Failure, bool) {
	for group in requirement.bindings {
		bound := resolve_type_syntax(k, group.type)
		if bound == INVALID_TYPE {
			return requirement_failuref(k, group.span, "a binding's type does not resolve")
		}
		for name in group.names {
			id := name_identifier(k.c, name)
			k.scope.names[id] = new_symbol(k.c, Symbol {
				name      = id,
				span      = name.span,
				kind      = .Var,
				type      = bound,
				pkg       = k.pkg,
				immutable = !group.is_inout,
			})
		}
	}
	return {}, true
}

// design.md "Interface bodies": a bare requirement must be true, not just compile.
@(private = "file")
truth_requirement_holds :: proc(k: ^Checker, requirement: Requirement) -> (Requirement_Failure, bool) {
	mark := len(k.c.diagnostics)
	folded, evaluated := require_const(k, requirement.expr, "an interface requirement", "L0444")
	truncate_diagnostics(k.c, mark)
	if !evaluated || folded.kind != .Boolean {
		return requirement_failuref(
			k, requirement.span,
			"this requirement is not a compile-time boolean; write `-> _` to require only that it compiles",
		)
	}
	if !folded.boolean {
		return requirement_failuref(k, requirement.span, "the predicate `%s` evaluates to false", where_bound_text(k.c, requirement.expr))
	}
	return {}, true
}

// What `expr -> R` asks of the checked `expr` beyond compiling.
@(private = "file")
requirement_result_holds :: proc(k: ^Checker, requirement: Requirement) -> (Requirement_Failure, bool) {
	// `-> _`: compiling is the whole requirement.
	if any, is_ident := requirement.result.(^Expr_Ident); is_ident && any.name == "_" {
		return {}, true
	}

	base := expr_base(requirement.expr)
	// `T.Element -> type;`: an associated type later requirements can use.
	if _, is_type_keyword := requirement.result.(^Type_Type); is_type_keyword {
		if base.denoted_type == INVALID_TYPE && base.const_value.kind != .Type {
			return requirement_failuref(k, requirement.span, "this member is not a compile-time type")
		}
		return {}, true
	}

	wanted := resolve_type_syntax(k, requirement.result)
	if wanted == INVALID_TYPE {
		return requirement_failuref(k, requirement.span, "its result type does not resolve")
	}
	// `-> inout T`: an assignable place of exactly `T`, with no conversions.
	if requirement.result_inout {
		if !base.assignable || base.type != wanted {
			return requirement_failuref(k, requirement.span, "it does not produce an assignable `%s`", type_name(k.c, wanted))
		}
		return {}, true
	}
	if !assignable(k.c, base.type, wanted) {
		return requirement_failuref(k, requirement.span, "it produces `%s`, not `%s`", type_name(k.c, base.type), type_name(k.c, wanted))
	}
	// A value result from a place is a copy of it, which a move-only type
	// forbids; bindings are never consumed, so nothing can be moved out either.
	// This is what `value[index] -> Element` asks of a sequence.
	if base.value_category == .Place && type_clone_disabled(k.c, base.type) {
		return requirement_failuref(
			k, requirement.span,
			"it lends a move-only `%s`, which cannot be copied out as a value",
			type_name(k.c, base.type),
		)
	}
	return {}, true
}

// A slot holds when an inherent method, or an extension from the interface's
// package, matches its signature exactly.
@(private = "file")
check_slot_requirement :: proc(
	k: ^Checker,
	info: ^Interface_Info,
	requirement: Requirement,
	args: []Generic_Arg,
	application_pkg: Package_Id,
) -> (Requirement_Failure, bool) {
	subject := len(args) > 0 && args[0].is_type ? args[0].type : INVALID_TYPE
	if subject == INVALID_TYPE {
		return requirement_failuref(k, requirement.span, "its subject is not a type")
	}
	signature, is_proc := requirement.slot_type.(^Type_Proc)
	if !is_proc {
		return requirement_failuref(k, requirement.span, "its slot has no procedure type")
	}

	name := name_identifier(k.c, requirement.name)
	// The signature resolves at the application site: a `Self.Assoc` in it is the
	// subject's own member, which need not be public.
	slot_pkg := k.lookup_pkg
	k.lookup_pkg = application_pkg
	wanted_params, wanted_modes, wanted_results, wanted_inout, shape_ok := slot_signature(k, signature, subject)
	k.lookup_pkg = slot_pkg
	if !shape_ok {
		return requirement_failuref(k, requirement.span, "its slot signature does not resolve")
	}

	for candidate in slot_candidates(k, subject, name, info.pkg) {
		sym := symbol_of(k.c, candidate)
		if sym == nil || sym.kind != .Proc || !sym.has_receiver {
			continue
		}
		if slot_matches(k, sym, wanted_params, wanted_modes, wanted_results, wanted_inout, signature.convention) {
			return {}, true
		}
	}
	if private_slot_member(k, subject, name) != nil {
		return private_slot_failure(k, requirement.span, subject, name)
	}
	return requirement_failuref(
		k, requirement.span, "`%s` has no method `%s` with this signature",
		type_name(k.c, subject), identifier_text(k.c, name),
	)
}

// A slot's candidates (design.md "Interface bodies"), shared with witness
// construction so `dyn` selects what satisfaction promised.
slot_candidates :: proc(k: ^Checker, subject: Type_Id, name: Identifier_Id, owner_pkg: Package_Id) -> []Symbol_Id {
	ensure_format_member(k, subject, name)
	ensure_iteration_members(k, subject)
	ensure_lifecycle_members(k, subject, name)
	out := make([dynamic]Symbol_Id, 0, 4, k.c.semantic_allocator)
	// design.md "Distinct types": a `distinct` name's own members, never its
	// underlying type's, as for ordinary member lookup.
	if info := type_of(k.c, subject); info != nil {
		collect_slot_members(k, info.members, name, &out, private_ok = !type_is_exported(k.c, subject))
	}
	if pkg := package_of(k.c, owner_pkg); pkg != nil {
		if members, found := pkg.extensions[subject]; found {
			collect_slot_members(k, members, name, &out, private_ok = true)
		}
	}
	return out[:]
}

// A private inherent method `slot_candidates` passed over, so a failure can say
// why. Anything else of that name could not meet the slot even if it were public.
@(private = "file")
private_slot_member :: proc(k: ^Checker, subject: Type_Id, name: Identifier_Id) -> ^Symbol {
	info := type_of(k.c, subject)
	if info == nil || !type_is_exported(k.c, subject) {
		return nil
	}
	for member in info.members {
		sym := symbol_of(k.c, member)
		if sym != nil && sym.name == name && !sym.public && sym.synth == .None && !sym.bound_excluded && member_has_receiver(k, member) {
			return sym
		}
	}
	return nil
}

// Whether a member is a method, or an overload group with one among its members.
@(private = "file")
member_has_receiver :: proc(k: ^Checker, member: Symbol_Id) -> bool {
	sym := symbol_of(k.c, member)
	if sym == nil {
		return false
	}
	sym = member_with_signature(k, member, sym.owner_type)
	if sym.kind == .Proc_Group {
		for nested in sym.members {
			if member_has_receiver(k, nested) {
				return true
			}
		}
		return false
	}
	return sym.kind == .Proc && sym.has_receiver
}

@(private = "file")
private_slot_failure :: proc(k: ^Checker, span: Span, subject: Type_Id, name: Identifier_Id) -> (Requirement_Failure, bool) {
	return requirement_failuref(
		k, span, "`%s.%s` is private, and a public type's private method meets no slot",
		type_name(k.c, subject), identifier_text(k.c, name),
	)
}

// Whether an importer can name `type`: a public declaration outside `package
// main`, or an instance of one.
type_is_exported :: proc(c: ^Compiler, type: Type_Id) -> bool {
	info := type_of(c, type)
	if info == nil {
		return false
	}
	sym := symbol_of(c, info.instance_of != INVALID_SYMBOL ? info.instance_of : info.symbol)
	if sym == nil || !sym.public {
		return false
	}
	pkg := package_of(c, sym.pkg)
	return pkg != nil && identifier_text(c, pkg.name) != "main"
}

@(private = "file")
collect_slot_members :: proc(k: ^Checker, members: []Symbol_Id, name: Identifier_Id, out: ^[dynamic]Symbol_Id, private_ok: bool) {
	for member in members {
		sym := symbol_of(k.c, member)
		if sym == nil || sym.name != name {
			continue
		}
		// This bypasses `member_is_visible`, so it repeats its `where` exclusion.
		if sym.bound_excluded {
			continue
		}
		// What the compiler contributes is the type's own behavior, not a member
		// its author kept private.
		if !private_ok && !sym.public && sym.synth == .None {
			continue
		}
		// In the member's own file and block: a bound probed from an earlier
		// file, or from another type's block, would otherwise read `self` as
		// that block's subject.
		sym = member_with_signature(k, member, sym.owner_type)
		// A witness member is never a group, so the group's members are candidates.
		if sym.kind == .Proc_Group {
			for nested in sym.members {
				append(out, nested)
			}
			continue
		}
		append(out, member)
	}
}

// The flattened parameter and result lists a slot's written signature asks for,
// with the receiver's own type supplied by the subject.
slot_signature :: proc(
	k: ^Checker,
	signature: ^Type_Proc,
	subject: Type_Id,
) -> ([]Type_Id, []Param_Mode, Type_Id, bool, bool) {
	params := make([dynamic]Type_Id, 0, 4, k.c.semantic_allocator)
	modes := make([dynamic]Param_Mode, 0, 4, k.c.semantic_allocator)
	for parameter, position in signature.params {
		written := INVALID_TYPE
		if parameter.type != nil {
			written = resolve_type_syntax(k, parameter.type)
			if written == INVALID_TYPE {
				return nil, nil, INVALID_TYPE, false, false
			}
		}
		names := max(len(parameter.names), 1)
		for index in 0 ..< names {
			resolved, mode, _ := normalize_signature_parameter(k.c, parameter, position, index, written, receiver = subject)
			if resolved == INVALID_TYPE {
				return nil, nil, INVALID_TYPE, false, false
			}
			append(&params, resolved)
			append(&modes, mode)
		}
	}
	result_type := INVALID_TYPE
	result_inout := false
	if result := signature.result; result != nil {
		result_type = resolve_type_syntax(k, result.type)
		if result_type == INVALID_TYPE {
			return nil, nil, INVALID_TYPE, false, false
		}
		result_inout = result.is_inout
	}
	return params[:], modes[:], result_type, result_inout, true
}

// One candidate against a slot's signature.
slot_matches :: proc(
	k: ^Checker,
	sym: ^Symbol,
	params: []Type_Id,
	modes: []Param_Mode,
	result: Type_Id,
	result_inout: bool,
	convention: string,
) -> bool {
	if len(sym.params) != len(params) || sym.result != result {
		return false
	}
	info := type_of(k.c, sym.proc_type)
	if info == nil || info.convention != convention || info.result_inout != result_inout {
		return false
	}
	for want, index in params {
		if sym.params[index] != want {
			return false
		}
		have := proc_parameter_mode(k.c, sym.proc_type, index)
		// A `self: ^` slot is met by a value `self` too: the method only lends less.
		if have != modes[index] && !(index == 0 && modes[index] == .Borrow && have == .Value) {
			return false
		}
	}
	return true
}

// ------------------------------------------------------------- composition --

composed_interface_of :: proc(k: ^Checker, requirement: Requirement) -> ^Interface_Info {
	if requirement.result != nil || len(requirement.bindings) > 0 {
		return nil
	}
	_, info := interface_call_of(k, requirement.expr)
	return info
}

// The flattened slots of an interface application, composition included.
interface_slots :: proc(k: ^Checker, info: ^Interface_Info, args: []Generic_Arg, out: ^[dynamic]Interface_Slot) {
	if !step_into_interface(k) {
		return
	}
	defer k.interface_depth -= 1
	saved := k.location
	defer k.location = saved
	enter_interface(k, info, args)

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
		call := clone_expr(k.c, requirement.expr).(^Expr_Call)
		composed_args, valid := bound_arguments(k, call, composed)
		if !valid {
			continue
		}
		interface_slots(k, composed, composed_args, out)
	}
}

// ---------------------------------------------------------------- Callable --

// The catalogue's `Callable`, whose one requirement the compiler states: a
// signature's parameter list is not something an interface body can spell.
interface_is_callable :: proc(c: ^Compiler, info: ^Interface_Info) -> bool {
	return symbol_is_callable(c, info.symbol)
}

symbol_is_callable :: proc(c: ^Compiler, id: Symbol_Id) -> bool {
	sym := symbol_of(c, id)
	if sym == nil {
		return false
	}
	pkg := package_of(c, sym.pkg)
	return pkg != nil && pkg.key == STD_INTERFACES && identifier_text(c, sym.name) == "Callable"
}

// `interfaces.Callable`, which `base:runtime` imports, so it is always loaded.
callable_interface :: proc(k: ^Checker) -> ^Interface_Info {
	symbol := package_symbol_named(k.c, standard_package(k.c, STD_INTERFACES), "Callable")
	return symbol == INVALID_SYMBOL ? nil : interface_info_for(k, symbol)
}

// standard-library.md "Standard interface catalogue". A field named `call` is
// not a method.
@(private = "file")
callable_check :: proc(k: ^Checker, info: ^Interface_Info, args: []Generic_Arg) -> (Requirement_Failure, bool) {
	at := info.node.span
	if len(args) != 2 || !args[0].is_type || !args[1].is_type {
		return requirement_failuref(k, at, "its arguments are not types")
	}
	subject, signature := args[0].type, args[1].type
	wanted := underlying_info(k.c, signature)
	if wanted == nil || wanted.kind != .Proc {
		return requirement_failuref(k, at, "its signature `%s` is not a procedure type", type_name(k.c, signature))
	}
	if have := underlying_info(k.c, subject); have != nil && have.kind == .Proc {
		if assignable(k.c, subject, signature) {
			return {}, true
		}
		return requirement_failuref(k, at, "`%s` does not convert to `%s`", type_name(k.c, subject), type_name(k.c, signature))
	}

	if callable_call_method(k, info, subject, signature) != INVALID_SYMBOL {
		return {}, true
	}
	if hidden := private_slot_member(k, subject, intern_identifier(k.c, "call")); hidden != nil {
		return private_slot_failure(k, at, subject, hidden.name)
	}
	return requirement_failuref(
		k, at, "`%s` has no method `call(self, ...)` matching `%s`",
		type_name(k.c, subject), type_name(k.c, signature),
	)
}

// The `call` method of `subject` that meets `signature`, as `Callable` asks.
callable_call_method :: proc(k: ^Checker, info: ^Interface_Info, subject, signature: Type_Id) -> Symbol_Id {
	for candidate in slot_candidates(k, subject, intern_identifier(k.c, "call"), info.pkg) {
		if call_method_matches(k.c, symbol_of(k.c, candidate), subject, signature) {
			return candidate
		}
	}
	return INVALID_SYMBOL
}

// standard-library.md "Standard interface catalogue". The method matches the
// rest of procedure type identity as a procedure converting to the signature
// must, with its parameter `index + 1` as the signature's `index`.
call_method_matches :: proc(c: ^Compiler, sym: ^Symbol, subject, signature: Type_Id) -> bool {
	wanted := underlying_info(c, signature)
	if sym == nil || sym.kind != .Proc || !sym.has_receiver || wanted == nil || wanted.kind != .Proc {
		return false
	}
	have := underlying_info(c, sym.proc_type)
	if have == nil || len(sym.params) != len(wanted.parameters) + 1 || sym.params[0] != subject ||
	   proc_parameter_mode(c, sym.proc_type, 0) != .Value ||
	   sym.result != wanted.result || have.result_inout != wanted.result_inout ||
	   have.convention != wanted.convention || have.c_vararg != wanted.c_vararg {
		return false
	}
	flag_at :: proc(flags: []bool, index: int) -> bool {
		return index < len(flags) && flags[index]
	}
	for parameter, index in wanted.parameters {
		if sym.params[index + 1] != parameter ||
		   proc_parameter_mode(c, sym.proc_type, index + 1) != proc_parameter_mode(c, signature, index) ||
		   flag_at(have.param_resets, index + 1) != flag_at(wanted.param_resets, index) ||
		   flag_at(have.param_by_ptr, index + 1) != flag_at(wanted.param_by_ptr, index) {
			return false
		}
		// design.md "@(cross_thread)": a call through the view checks no less.
		if flag_at(have.param_cross_thread, index + 1) && !flag_at(wanted.param_cross_thread, index) {
			return false
		}
		// design.md "@(escape=<level>)": it retains no argument further than allowed.
		if proc_param_escape(c, sym.proc_type, index + 1) > proc_param_escape(c, signature, index) {
			return false
		}
	}
	return true
}

// The result of a type's first `call` method, and a later one that returns
// something else. `INVALID_TYPE` is a method that returns nothing, or no method.
@(private = "file")
callable_method_results :: proc(k: ^Checker, type: Type_Id) -> (result: Type_Id, conflicting: ^Symbol) {
	result = INVALID_TYPE
	seen := false
	for candidate in slot_candidates(k, type, intern_identifier(k.c, "call"), INVALID_PACKAGE) {
		sym := symbol_of(k.c, candidate)
		if sym == nil || sym.kind != .Proc || !sym.has_receiver {
			continue
		}
		if !seen {
			result, seen = sym.result, true
		} else if sym.result != result {
			return result, sym
		}
	}
	return result, nil
}

// standard-library.md "Standard interface catalogue": `C.Result`. A type
// declaring its own `Result` keeps it.
ensure_callable_result_member :: proc(k: ^Checker, type: Type_Id, name: Identifier_Id) {
	if identifier_text(k.c, name) != "Result" {
		return
	}
	info := type_of(k.c, type)
	if info == nil || member_named(k.c, info.members, name) != INVALID_SYMBOL {
		return
	}
	result := INVALID_TYPE
	if under := underlying_info(k.c, type); under != nil && under.kind == .Proc {
		result = under.result
	} else {
		conflicting: ^Symbol
		result, conflicting = callable_method_results(k, type)
		if conflicting != nil {
			return
		}
	}
	if result == INVALID_TYPE {
		return
	}
	install_impl_members(k, .Impl, type, []Symbol_Id{new_associated_type(k.c, "Result", result, type)}, INVALID_PACKAGE)
}

// Why `type.Result` is missing when `Callable` would have contributed it: two
// `call` methods that disagree on their result.
note_missing_callable_result :: proc(k: ^Checker, type: Type_Id, name: string) {
	if name != "Result" {
		return
	}
	if _, conflicting := callable_method_results(k, type); conflicting != nil {
		add_notef(
			k.c, conflicting.span, "its `call` methods return different types, so `%s.Result` names neither",
			type_name(k.c, type),
		)
	}
}

// The `Callable` that `info(args)` is or composes on `type`, at any depth, as
// `interface_slots` flattens written slots (design.md "Interface bodies").
@(private = "file")
composed_callable :: proc(k: ^Checker, info: ^Interface_Info, args: []Generic_Arg, type: Type_Id) -> ^Interface_Info {
	if interface_is_callable(k.c, info) {
		return len(args) > 0 && args[0].is_type && args[0].type == type ? info : nil
	}
	if !step_into_interface(k) {
		return nil
	}
	defer k.interface_depth -= 1
	saved := k.location
	defer k.location = saved
	enter_interface(k, info, args)
	for requirement in info.node.requirements {
		if requirement.kind == .Slot {
			continue
		}
		composed := composed_interface_of(k, requirement)
		if composed == nil {
			continue
		}
		// Clone before annotating: one declaration serves many applications.
		call := clone_expr(k.c, requirement.expr).(^Expr_Call)
		composed_args, valid := bound_arguments(k, call, composed)
		if !valid {
			continue
		}
		if found := composed_callable(k, composed, composed_args, type); found != nil {
			return found
		}
	}
	return nil
}

// ------------------------------------------------------------------ grants --

// design.md "Interface bodies": the `where` clauses whose bare bounds grant the
// code being checked what satisfied them. A body's are its own procedure's,
// and only while the code is in that body: a declaration elsewhere that its
// checking reaches is checked in its own scope and gets nothing.
granting_bounds :: proc(k: ^Checker) -> []Expr {
	if k.bounds_set {
		return k.bounds
	}
	literal := k.proc_literal
	if literal == nil || len(literal.where_clauses) == 0 {
		return nil
	}
	for scope := k.scope; scope != nil; scope = scope.parent {
		if scope.owner_proc == rawptr(literal) {
			return literal.where_clauses
		}
	}
	return nil
}

// design.md "Interface bodies": a bare `where I(T)` bound grants the slots of
// `I` and of the applications it composes, each on its own subject, under the
// interface's visibility, which ordinary lookup in the body would reject.
// Clearing the bounds guards recursion.
required_slot_candidates :: proc(k: ^Checker, type: Type_Id, name: Identifier_Id) -> []Symbol_Id {
	bounds := granting_bounds(k)
	if len(bounds) == 0 {
		return nil
	}
	outer := k.body
	k.body.bounds, k.body.bounds_set = nil, true
	defer k.body = outer

	for clause in bounds {
		call, info := interface_call_of(k, clause)
		if info == nil || len(call.args) == 0 {
			continue
		}
		args, bound := bound_arguments(k, call, info)
		if !bound || !args[0].is_type {
			continue
		}
		// `Callable` states its slot by a built-in rule, so it grants `call`
		// itself, directly or composed: what `c(args)` in the constrained body
		// reaches.
		if identifier_text(k.c, name) == "call" {
			if callable := composed_callable(k, info, args, type); callable != nil {
				if found := slot_candidates(k, type, name, callable.pkg); len(found) > 0 {
					return found
				}
			}
		}
		if interface_is_callable(k.c, info) {
			continue
		}
		flattened := make([dynamic]Interface_Slot, 0, 4, context.temp_allocator)
		interface_slots(k, info, args, &flattened)
		for entry in flattened {
			owner := interface_info_for(k, entry.owner)
			if entry.name != name || owner == nil {
				continue
			}
			// On the subject of the application that wrote the slot: `Real(T.Real)`
			// in `Scalar(T)` grants `abs` on `T.Real`, not on `T`.
			if len(entry.args) == 0 || !entry.args[0].is_type || entry.args[0].type != type {
				continue
			}
			if found := slot_candidates(k, type, name, owner.pkg); len(found) > 0 {
				return found
			}
		}
	}
	return nil
}

// design.md "Interface bodies": the associated constant `type.name` that the
// application being checked, or a bare bound of this declaration, requires.
// Ordinary lookup has already failed.
required_associated_constant :: proc(k: ^Checker, type: Type_Id, name: Identifier_Id) -> Symbol_Id {
	if k.requiring != nil {
		if found := application_constant(k, k.requiring, k.requiring_args, type, name); found != INVALID_SYMBOL {
			return found
		}
	}
	for clause in granting_bounds(k) {
		call, info := interface_call_of(k, clause)
		if info == nil || interface_is_callable(k.c, info) || !interface_names_constant(k, info, name) {
			continue
		}
		// The bound's arguments are read where it is written, without its grant.
		outer := k.body
		k.body.bounds, k.body.bounds_set, k.body.requiring = nil, true, nil
		args, bound := bound_arguments(k, call, info)
		k.body = outer
		if !bound {
			continue
		}
		if found := application_constant(k, info, args, type, name); found != INVALID_SYMBOL {
			return found
		}
	}
	return INVALID_SYMBOL
}

// Whether `info` or an interface it composes writes a requirement `X.name -> R`,
// read from the syntax alone so a failed lookup costs little.
@(private = "file")
interface_names_constant :: proc(k: ^Checker, info: ^Interface_Info, name: Identifier_Id) -> bool {
	visited := make(map[Symbol_Id]bool, 8, context.temp_allocator)
	return composition_names_constant(k, info, name, &visited)
}

@(private = "file")
composition_names_constant :: proc(k: ^Checker, info: ^Interface_Info, name: Identifier_Id, visited: ^map[Symbol_Id]bool) -> bool {
	visited[info.symbol] = true
	saved := k.location
	defer k.location = saved
	enter_interface(k, info, nil)
	for requirement in info.node.requirements {
		if requirement.kind == .Slot {
			continue
		}
		if selector, is_selector := requirement.expr.(^Expr_Selector); is_selector && requirement.result != nil {
			if intern_identifier(k.c, selector.name.text) == name {
				return true
			}
			continue
		}
		if composed := composed_interface_of(k, requirement); composed != nil && !visited[composed.symbol] {
			if composition_names_constant(k, composed, name, visited) {
				return true
			}
		}
	}
	return false
}

// The member a requirement `X.name -> R` of `info(args)`, or of an application
// it composes, requires of `type`, as `slot_candidates` finds a slot's.
@(private = "file")
application_constant :: proc(k: ^Checker, info: ^Interface_Info, args: []Generic_Arg, type: Type_Id, name: Identifier_Id) -> Symbol_Id {
	if interface_is_callable(k.c, info) || !interface_names_constant(k, info, name) || !step_into_interface(k) {
		return INVALID_SYMBOL
	}
	defer k.interface_depth -= 1
	saved := k.location
	defer k.location = saved
	enter_interface(k, info, args)

	// The application's own requirements first, so resolving a composed
	// argument that names one finds it without composing again.
	for requirement in info.node.requirements {
		if requirement.kind == .Slot || requirement.result == nil || len(requirement.bindings) > 0 {
			continue
		}
		selector, is_selector := requirement.expr.(^Expr_Selector)
		if !is_selector || intern_identifier(k.c, selector.name.text) != name {
			continue
		}
		if resolve_type_syntax(k, clone_expr(k.c, selector.operand)) != type {
			continue
		}
		for candidate in slot_candidates(k, type, name, info.pkg) {
			if sym := symbol_of(k.c, candidate); sym != nil && (sym.kind == .Const || sym.kind == .Type) {
				return candidate
			}
		}
	}
	for requirement in info.node.requirements {
		if requirement.kind == .Slot {
			continue
		}
		composed := composed_interface_of(k, requirement)
		if composed == nil {
			continue
		}
		// Clone before annotating: one declaration serves many applications.
		call := clone_expr(k.c, requirement.expr).(^Expr_Call)
		composed_args, valid := bound_arguments(k, call, composed)
		if !valid {
			continue
		}
		if found := application_constant(k, composed, composed_args, type, name); found != INVALID_SYMBOL {
			return found
		}
	}
	return INVALID_SYMBOL
}

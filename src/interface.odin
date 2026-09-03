// Interfaces and requirement checking.
//
// An interface is compile-time metadata: a list of structural requirements over
// its generic parameters. A type satisfies it implicitly, and an application
// such as `Additive(int)` is a compile-time boolean, not a value.
//
// Requirements are checked by substituting the interface's arguments and then
// checking each written requirement as ordinary code in a scratch checker whose
// diagnostics are captured rather than emitted. Failure is reported as the
// specific requirement line plus the concrete type that failed it — design.md
// calls a bare "constraint not satisfied" a defect.
//
// Lookup context is per requirement, and deliberately not uniform: a free
// expression or validity requirement uses the *application's* lookup package,
// while a named slot is matched only by an inherent method or an extension in
// the package that declares the slot's owning interface. One undifferentiated
// package would either admit caller-local slots or hide legitimate ones.
package lokec

import "core:fmt"
import "core:strings"

// A flattened slot, remembering which interface declared it: composition keeps
// each slot's own coherent lookup package.
Interface_Slot :: struct {
	name:  Identifier_Id,
	span:  Span,
	type:  ^Type_Proc,
	owner: Symbol_Id,
	// Argument vector of the interface that declares this slot, so its parameter
	// names resolve when the slot is matched.
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
	type:      Type_Id,
	checked:   bool,
	// Dyn compatibility is a property of the declaration, so it is computed once
	// and carries the rule that disqualified it.
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
	info.type = sym.type
	info.scope = sym.def_scope
	if info.scope == nil {
		if pkg := package_of(k.c, sym.pkg); pkg != nil {
			info.scope = pkg.scope
		}
	}
	params := make([dynamic]Generic_Param_Decl, 0, 4, k.c.semantic_allocator)
	for group in node.generic_params {
		for name in group.names {
			id := name.id
			if id == INVALID_IDENTIFIER {
				id = intern_identifier(k.c, name.text)
			}
			append(&params, Generic_Param_Decl{name = id, span = name.span, type_syntax = group.type})
		}
	}
	info.params = params[:]
	k.c.interfaces[symbol_id] = info
	return info
}

// An interface application in type position — `dyn I(...)` aside — is not a
// type. This is what tells a value position that it named one.
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
	}

	seen := make([dynamic]Identifier_Id, 0, 4, context.temp_allocator)
	for requirement in info.node.requirements {
		if requirement.kind != .Slot {
			continue
		}
		name := requirement.name.id
		if name == INVALID_IDENTIFIER {
			name = intern_identifier(k.c, requirement.name.text)
		}
		duplicate := false
		for existing in seen {
			if existing == name {
				errorf(k.c, requirement.span, "L0442", "`%s` is already a slot of this interface", requirement.name.text)
				duplicate = true
				break
			}
		}
		if !duplicate {
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
		}
	}
	// Slot names must also be unique across every composed interface; that is
	// only knowable once composition resolves, so it is checked when the
	// composed interface is applied.
}

// ------------------------------------------------------------ application --

// `Additive(int)` in expression position: a compile-time boolean. Reports only
// the argument mistakes; an unsatisfied interface is `false`, not an error, so
// `where` and composition can both use the same construct.
check_interface_application :: proc(k: ^Checker, v: ^Expr_Call, info: ^Interface_Info) {
	v.value_category = .Value
	v.type = TYPE_BOOL
	args, ok := interface_arguments(k, v, info)
	if !ok {
		v.type = INVALID_TYPE
		return
	}
	v.resolution = Resolution{kind = .Generic_Application, symbol = info.symbol}
	v.is_const = true
	v.const_value = bool_const(interface_satisfied(k, info, args, v.span, report = false))
}

// Resolves the written arguments against the interface's own parameters.
@(private = "file")
interface_arguments :: proc(k: ^Checker, v: ^Expr_Call, info: ^Interface_Info) -> ([]Generic_Arg, bool) {
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
		return nil, false
	}
	out := make([]Generic_Arg, len(v.args), k.c.semantic_allocator)
	for arg, index in v.args {
		// Every interface parameter this milestone admits is a `type`; a value
		// parameter would be checked against its own written type here.
		denoted := resolve_type_syntax(k, arg.value)
		if denoted == INVALID_TYPE {
			errorf(k.c, arg.span, "L0443", "an interface argument must name a type")
			return nil, false
		}
		out[index] = Generic_Arg{is_type = true, type = denoted}
	}
	return out, true
}

// ------------------------------------------------------- satisfaction --

Requirement_Failure :: struct {
	span:    Span,
	reason:  string,
	subject: Type_Id,
}

// Does `info` hold for these arguments? Silent by default — an application is
// a predicate; only a `where` bound or a `dyn` conversion turns a `false` into
// a diagnostic, reported by `report_interface_failure`.
interface_satisfied :: proc(
	k: ^Checker,
	info: ^Interface_Info,
	args: []Generic_Arg,
	span: Span,
	report: bool,
) -> bool {
	failure, ok := interface_check(k, info, args, span)
	if !ok && report {
		report_interface_failure(k, info, args, span, failure)
	}
	return ok
}

report_interface_failure :: proc(
	k: ^Checker,
	info: ^Interface_Info,
	args: []Generic_Arg,
	span: Span,
	failure: Requirement_Failure,
) {
	subject := len(args) > 0 && args[0].is_type ? args[0].type : failure.subject
	errorf(
		k.c,
		span,
		"L0444",
		"`%s` does not satisfy `%s`",
		type_name(k.c, subject),
		interface_application_text(k.c, info, args),
	)
	if failure.reason != "" {
		add_notef(k.c, failure.span, "this requirement does not hold: %s", failure.reason)
	} else {
		add_notef(k.c, failure.span, "this requirement does not hold")
	}
}

// A `where` bound that is a bare interface application reports the requirement
// that failed. Returns false for any other bound, which reports itself.
report_failed_interface_bound :: proc(k: ^Checker, clause: Expr, span: Span) -> bool {
	call, is_call := clause.(^Expr_Call)
	if !is_call {
		return false
	}
	info := interface_info_for(k, named_callee_symbol(k, call.callee))
	if info == nil || len(call.args) != len(info.params) {
		return false
	}
	args := make([]Generic_Arg, len(call.args), k.c.semantic_allocator)
	for arg, index in call.args {
		denoted := resolve_type_syntax(k, arg.value)
		if denoted == INVALID_TYPE {
			return false
		}
		args[index] = Generic_Arg{is_type = true, type = denoted}
	}
	return !interface_satisfied(k, info, args, span, report = true)
}

interface_application_text :: proc(c: ^Compiler, info: ^Interface_Info, args: []Generic_Arg) -> string {
	text := identifier_text(c, symbol_of(c, info.symbol).name)
	text = concat(c, text, "(")
	for arg, index in args {
		if index > 0 {
			text = concat(c, text, ", ")
		}
		text = concat(c, text, arg.is_type ? type_name(c, arg.type) : "<value>")
	}
	return concat(c, text, ")")
}

// Guards against an interface whose composition names itself: requirement
// checking is deliberately non-recursive over types that don't exist yet, but
// a cyclic *declaration* would still spin.
MAX_INTERFACE_DEPTH :: 32

@(private = "file")
interface_check :: proc(
	k: ^Checker,
	info: ^Interface_Info,
	args: []Generic_Arg,
	span: Span,
) -> (Requirement_Failure, bool) {
	if len(args) != len(info.params) {
		return Requirement_Failure{span = info.node.span, reason = "wrong number of interface arguments"}, false
	}
	if k.interface_depth >= MAX_INTERFACE_DEPTH {
		return Requirement_Failure {
			span   = info.node.span,
			reason = "this interface composes itself",
		}, false
	}
	// Requirements are hypothetical programs, deliberately checked with the real
	// checker on cloned syntax; registry gates keep rejected probes from changing
	// typeids or adding backend-only globals and witness tables.
	k.c.speculation_depth += 1
	defer k.c.speculation_depth -= 1

	// The scratch scope: the interface's own parameters bound to the arguments,
	// hanging off the interface declaration's lexical scope.
	scope := new_scope(k.c, info.scope == nil ? build_universe(k.c) : info.scope, .Local)
	for parameter, index in info.params {
		bind_generic_name(k, scope, Generic_Binding {
			name = parameter.name,
			span = parameter.span,
			arg  = args[index],
		})
	}

	saved_scope, saved_pkg, saved_lookup := k.scope, k.pkg, k.lookup_pkg
	saved_impl, saved_file, saved_node := k.impl_type, k.file, k.file_node
	saved_literal, saved_result := k.proc_literal, k.result_type
	saved_place := k.place_position
	k.interface_depth += 1
	defer {
		k.scope, k.pkg, k.lookup_pkg = saved_scope, saved_pkg, saved_lookup
		k.impl_type, k.file, k.file_node = saved_impl, saved_file, saved_node
		k.proc_literal, k.result_type = saved_literal, saved_result
		k.place_position = saved_place
		k.interface_depth -= 1
	}
	k.proc_literal = nil
	k.result_type = INVALID_TYPE

	// The application site's own lookup package serves free expression and
	// validity requirements; each slot switches to its declaring interface's.
	application_pkg := lookup_package(k)

	for requirement in info.node.requirements {
		// A requirement is checked on a fresh clone: its syntax is annotated, and
		// the same interface is applied to many types.
		clone := clone_requirement_syntax(k.c, requirement)
		body := new_scope(k.c, scope, .Local)
		k.scope = body
		k.pkg = info.pkg
		k.lookup_pkg = requirement.kind == .Slot ? info.pkg : application_pkg
		if info.file_node != nil {
			k.file, k.file_node = info.file, info.file_node
		}

		failure, ok := check_one_requirement(k, info, clone, body, args, span, application_pkg)
		if !ok {
			return failure, false
		}
	}
	return Requirement_Failure{}, true
}

@(private = "file")
clone_requirement_syntax :: proc(c: ^Compiler, requirement: Requirement) -> Requirement {
	one := make([]Requirement, 1, c.semantic_allocator)
	one[0] = requirement
	return clone_requirements(c, one)[0]
}

@(private = "file")
check_one_requirement :: proc(
	k: ^Checker,
	info: ^Interface_Info,
	requirement: Requirement,
	scope: ^Scope,
	args: []Generic_Arg,
	span: Span,
	application_pkg: Package_Id,
) -> (Requirement_Failure, bool) {
	if requirement.kind == .Slot {
		return check_slot_requirement(k, info, requirement, args, application_pkg)
	}

	// Composition: a bare interface application must hold, not merely compile.
	if call, is_call := requirement.expr.(^Expr_Call); is_call && requirement.result == nil {
		if composed := interface_info_for(k, named_callee_symbol(k, call.callee)); composed != nil {
			composed_args, ok := composed_arguments(k, call, composed)
			if !ok {
				return Requirement_Failure{span = requirement.span, reason = "its interface arguments do not resolve"}, false
			}
			failure, held := interface_check(k, composed, composed_args, span)
			if !held {
				return failure, false
			}
			return Requirement_Failure{}, true
		}
	}

	// The binding list introduces names standing for values, or hypothetical
	// exclusive mutable places — the compiler never constructs either.
	for group in requirement.bindings {
		bound := resolve_type_syntax(k, group.type)
		if bound == INVALID_TYPE {
			return Requirement_Failure{span = group.span, reason = "a binding's type does not resolve"}, false
		}
		for name in group.names {
			id := name.id
			if id == INVALID_IDENTIFIER {
				id = intern_identifier(k.c, name.text)
			}
			scope.names[id] = new_symbol(k.c, Symbol {
				name      = id,
				span      = name.span,
				kind      = .Var,
				type      = bound,
				pkg       = k.pkg,
				immutable = !group.is_inout,
			})
		}
	}

	mark := len(k.c.diagnostics)
	errors := k.c.error_count
	// `-> inout T` asks for a place, so the expression is checked in a place
	// position — otherwise a user `operator([])` with both overloads answers with
	// its value one and no user type could ever satisfy `Mutable_Sequence`
	// (design.md "Indexing and slicing": the `inout` overload is selected only in
	// a place position).
	k.place_position = requirement.result_inout
	type := check_expr(k, requirement.expr)
	k.place_position = false
	captured := k.c.error_count > errors
	// The scratch checker's own diagnostic says exactly what did not compile, so
	// it becomes the reason rather than being thrown away for a generic phrase.
	reason := "this expression does not compile for these arguments"
	if mark < len(k.c.diagnostics) {
		reason = strings.clone(k.c.diagnostics[mark].message, k.c.semantic_allocator)
	}
	truncate_diagnostics(k.c, mark)
	k.c.error_count = errors
	if type == INVALID_TYPE || captured {
		return Requirement_Failure{span = requirement.span, reason = reason}, false
	}
	if requirement.result == nil {
		return Requirement_Failure{}, true // validity form: compiling is the whole requirement
	}

	base := expr_base(requirement.expr)
	// `T.Element -> type;` requires the member to evaluate to a compile-time type,
	// which makes it an associated type usable by later requirements.
	if written, is_type_keyword := requirement.result.(^Type_Type); is_type_keyword {
		_ = written
		if base.denoted_type == INVALID_TYPE && base.const_value.kind != .Type {
			return Requirement_Failure{span = requirement.span, reason = "this member is not a compile-time type"}, false
		}
		return Requirement_Failure{}, true
	}

	wanted := resolve_type_syntax(k, requirement.result)
	if wanted == INVALID_TYPE {
		return Requirement_Failure{span = requirement.span, reason = "its result type does not resolve"}, false
	}
	// `-> inout T` requires an assignable place of exactly `T`: ordinary result
	// conversions deliberately do not apply.
	if requirement.result_inout {
		if !base.assignable || base.type != wanted {
			return Requirement_Failure {
				span   = requirement.span,
				reason = fmt.aprintf(
					"it does not produce an assignable `%s`",
					type_name(k.c, wanted),
					allocator = k.c.semantic_allocator,
				),
			}, false
		}
		return Requirement_Failure{}, true
	}
	if !assignable(k.c, base.type, wanted) {
		return Requirement_Failure {
			span   = requirement.span,
			reason = fmt.aprintf(
				"it produces `%s`, not `%s`",
				type_name(k.c, base.type),
				type_name(k.c, wanted),
				allocator = k.c.semantic_allocator,
			),
		}, false
	}
	return Requirement_Failure{}, true
}

@(private = "file")
composed_arguments :: proc(k: ^Checker, call: ^Expr_Call, composed: ^Interface_Info) -> ([]Generic_Arg, bool) {
	if len(call.args) != len(composed.params) {
		return nil, false
	}
	out := make([]Generic_Arg, len(call.args), k.c.semantic_allocator)
	for arg, index in call.args {
		denoted := resolve_type_syntax(k, arg.value)
		if denoted == INVALID_TYPE {
			return nil, false
		}
		out[index] = Generic_Arg{is_type = true, type = denoted}
	}
	return out, true
}

// Requirement checking selects one matching inherent method or an extension
// method from the interface's own package, matching parameter modes, results,
// calling convention, and type-level effects exactly (design.md).
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
		return Requirement_Failure{span = requirement.span, reason = "its subject is not a type"}, false
	}
	signature, is_proc := requirement.slot_type.(^Type_Proc)
	if !is_proc {
		return Requirement_Failure{span = requirement.span, reason = "its slot has no procedure type"}, false
	}

	name := requirement.name.id
	if name == INVALID_IDENTIFIER {
		name = intern_identifier(k.c, requirement.name.text)
	}
	// The slot's *candidates* are the interface package's business, but a
	// `Self.Assoc` in its signature names the subject's own inherent member,
	// whose visibility answers to the application site — so the signature
	// resolves there, or `Iterable` would demand every iterable publish its
	// `Iterator`.
	slot_pkg := k.lookup_pkg
	k.lookup_pkg = application_pkg
	wanted_params, wanted_modes, wanted_results, wanted_inout, shape_ok := slot_signature(k, signature, subject)
	k.lookup_pkg = slot_pkg
	if !shape_ok {
		return Requirement_Failure{span = requirement.span, reason = "its slot signature does not resolve"}, false
	}

	for candidate in slot_candidates(k, subject, name, info.pkg) {
		sym := symbol_of(k.c, candidate)
		if sym == nil || sym.kind != .Proc || !sym.has_receiver {
			continue
		}
		if slot_matches(k, sym, wanted_params, wanted_modes, wanted_results, wanted_inout) {
			return Requirement_Failure{}, true
		}
	}
	return Requirement_Failure {
		span   = requirement.span,
		reason = fmt.aprintf(
			"`%s` has no method `%s` with this signature",
			type_name(k.c, subject),
			identifier_text(k.c, name),
			allocator = k.c.semantic_allocator,
		),
	}, false
}

// design.md: a named slot is matched by an inherent method, or by an extension
// from the package that declares the slot's owning interface — never the
// package that happens to apply the interface. An inherent method belongs to
// the type itself, so its own visibility doesn't matter; only the extension
// half is package-scoped.
@(private = "file")
slot_candidates :: proc(k: ^Checker, subject: Type_Id, name: Identifier_Id, owner_pkg: Package_Id) -> []Symbol_Id {
	ensure_iteration_members(k, subject)
	ensure_lifecycle_members(k, type_underlying(k.c, subject), name)
	out := make([dynamic]Symbol_Id, 0, 4, k.c.semantic_allocator)
	if info := underlying_info(k.c, subject); info != nil {
		collect_slot_members(k, info.members, name, &out)
	}
	if pkg := package_of(k.c, owner_pkg); pkg != nil {
		if members, found := pkg.extensions[subject]; found {
			collect_slot_members(k, members, name, &out)
		}
	}
	return out[:]
}

@(private = "file")
collect_slot_members :: proc(k: ^Checker, members: []Symbol_Id, name: Identifier_Id, out: ^[dynamic]Symbol_Id) {
	for member in members {
		sym := symbol_of(k.c, member)
		if sym == nil || sym.name != name {
			continue
		}
		if sym.decl != nil && sym.decl.sig_state == .Unchecked {
			resolve_declaration_signature(k, sym.decl)
			sym = symbol_of(k.c, member)
		}
		// Runtime witness members are never overload groups (design.md), so a
		// group's members are the candidates rather than the group itself.
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

// One candidate's signature against a slot's written one. `result_inout` is
// `nil` for a runtime witness, which pairs a concrete member with a slot whose
// result place-ness the `dyn` header does not carry; an interface requirement
// passes the value it demands.
slot_matches :: proc(
	k: ^Checker,
	sym: ^Symbol,
	params: []Type_Id,
	modes: []Param_Mode,
	result: Type_Id,
	result_inout: Maybe(bool),
) -> bool {
	if len(sym.params) != len(params) || sym.result != result {
		return false
	}
	info := type_of(k.c, sym.proc_type)
	if info == nil || info.convention != "" {
		return false
	}
	for want, index in params {
		if sym.params[index] != want {
			return false
		}
		have := index < len(info.param_modes) ? info.param_modes[index] : Param_Mode.Value
		if have != modes[index] {
			return false
		}
	}
	want, checked := result_inout.?
	return !checked || info.result_inout == want
}

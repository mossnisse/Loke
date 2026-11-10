// Parametric aliases (design.md "Parametric aliases"): templates that are never
// instantiated, an application denoting its body's type.
package lokec

import "core:fmt"
import "core:slice"

// design.md "Parametric aliases": the distinct `$` names an alias's body binds,
// in order of first appearance. Their kinds are settled with the declaration
// (`check_alias_template`); until then each is a type.
alias_parameters :: proc(k: ^Checker, body: Expr) -> []Generic_Param_Decl {
	names := pattern_names(body)
	params := make([dynamic]Generic_Param_Decl, 0, len(names), k.c.semantic_allocator)
	next_name: for name in names {
		id := name_identifier(k.c, name)
		for parameter in params {
			if parameter.name == id {
				continue next_name
			}
		}
		append(&params, Generic_Param_Decl{name = id, span = name.span, fixed_type = TYPE_TYPE})
	}
	return params[:]
}

// One place a `$` name of an alias's body is bound: by a type, or by a
// constant of `value_type`, or by a constant whose type `dependent_on`'s earlier
// arguments decide.
@(private = "file")
Alias_Binding_Use :: struct {
	name:            Identifier_Id,
	span:            Span,
	value_type:      Type_Id, // TYPE_TYPE for a type
	dependent_on:    ^Expr_Call,
	dependent_index: int,
}

// The positions `match_type_pattern` binds a `$` name in, and what each binds
// it by, at any depth. Callees resolve in `k.scope`, the alias's own.
@(private = "file")
alias_binding_uses :: proc(k: ^Checker, e: Expr, out: ^[dynamic]Alias_Binding_Use) {
	if e == nil {
		return
	}
	value_use :: proc(k: ^Checker, e: Expr, value_type: Type_Id, out: ^[dynamic]Alias_Binding_Use) {
		if poly, is_poly := e.(^Type_Poly); is_poly {
			append(out, Alias_Binding_Use{name = name_identifier(k.c, poly.name), span = poly.span, value_type = value_type})
		}
	}
	// Each argument against the parameter it binds, for a generic type and for a
	// `dyn` interface alike.
	application_uses :: proc(k: ^Checker, call: ^Expr_Call, out: ^[dynamic]Alias_Binding_Use) {
		applied := applied_parameters(k, call.callee)
		for arg, index in call.args {
			at := applied.first + index
			poly, is_poly := arg.value.(^Type_Poly)
			if at < len(applied.params) && is_poly {
				kind, dependent := generic_parameter_kind(k, applied, at)
				if dependent {
					append(out, Alias_Binding_Use {
						name = name_identifier(k.c, poly.name), span = poly.span,
						dependent_on = call, dependent_index = at,
					})
					continue
				}
				if kind != TYPE_TYPE {
					value_use(k, poly, kind, out)
					continue
				}
			}
			alias_binding_uses(k, arg.value, out)
		}
	}
	#partial switch v in e {
	case ^Type_Poly:
		append(out, Alias_Binding_Use{name = name_identifier(k.c, v.name), span = v.span, value_type = TYPE_TYPE})
	case ^Type_Dyn:
		// `dyn Named($T)` binds its arguments as `dyn` does, for any interface.
		if call, is_call := v.interface_expr.(^Expr_Call); is_call {
			application_uses(k, call, out)
		} else {
			alias_binding_uses(k, v.interface_expr, out)
		}
	case ^Type_Array:
		value_use(k, v.length, TYPE_INT, out)
		alias_binding_uses(k, v.elem, out)
	case ^Expr_Call:
		if predeclared_callee(k, v.callee, "Simd") && len(v.args) == 2 {
			alias_binding_uses(k, v.args[0].value, out)
			value_use(k, v.args[1].value, TYPE_INT, out)
			return
		}
		// A call that computes a type cannot be read backwards from the type it
		// computes. A callee naming nothing is left for its application to report.
		if _, is_ident := v.callee.(^Expr_Ident); !alias_constructor_callee(k, v.callee) && (!is_ident || named_callee_symbol(k, v.callee) != INVALID_SYMBOL) {
			return
		}
		application_uses(k, v, out)
	case:
		for part in type_pattern_parts(e) {
			alias_binding_uses(k, part, out)
		}
	}
}

// Whether a call names a type by its arguments: a generic type, or a predeclared
// constructor, rather than a procedure that computes one.
@(private = "file")
alias_constructor_callee :: proc(k: ^Checker, callee: Expr) -> bool {
	return generic_template_of_callee(k, callee, TYPE_GENERICS) != nil || predeclared_callee(k, callee, "Simd", "Box", "Range")
}

// The parameters an application's arguments bind, with the scope their types
// resolve in. `first` passes over an interface's subject, which `dyn` erases;
// `alias` is the template when they are an alias's.
Applied_Parameters :: struct {
	params: []Generic_Param_Decl,
	scope:  ^Scope,
	first:  int,
	alias:  ^Generic_Template,
}

// The parameters of what `callee` names, read in `k.scope`: none for a
// predeclared constructor, whose arguments are typed by the constructor itself.
applied_parameters :: proc(k: ^Checker, callee: Expr) -> Applied_Parameters {
	symbol := named_callee_symbol(k, callee)
	if info := interface_info_for(k, symbol); info != nil {
		return {params = info.params, scope = info.scope, first = 1}
	}
	template := generic_template_for(k, symbol)
	if template == nil {
		return {}
	}
	#partial switch template.kind {
	case .Record:
		return {params = template.params, scope = template.scope}
	case .Alias:
		template_rejected(k, template)
		return {params = template.params, scope = template.scope, alias = template}
	}
	return {}
}

// What parameter `at` is bound by: `type`, or the constant's type. `dependent`
// when an earlier parameter decides that, so that it has no one answer, as for
// `$V` in `struct($T: type, $V: T)`. INVALID_TYPE, reported, when a type does not
// resolve.
generic_parameter_kind :: proc(k: ^Checker, applied: Applied_Parameters, at: int) -> (kind: Type_Id, dependent: bool) {
	parameter := applied.params[at]
	if applied.alias != nil {
		return parameter.fixed_type, parameter.dependent_on != nil
	}
	if parameter_takes_type(parameter) {
		return TYPE_TYPE, false
	}
	marks := make([]bool, at, context.temp_allocator)
	mark_named_parameters(k, applied.params[:at], parameter.type_syntax, marks)
	if slice.contains(marks, true) {
		return INVALID_TYPE, true
	}
	saved := k.scope
	k.scope = applied.scope
	defer k.scope = saved
	return resolve_type_reporting(k, clone_expr(k.c, parameter.type_syntax)), false
}

// design.md "Parametric aliases": the type of an alias's constant parameter that
// its body's application decides, once the arguments before it are bound in
// `scope`. INVALID_TYPE, reported, when they do not bind as that application asks.
@(private = "file")
alias_dependent_type :: proc(
	k: ^Checker, template: ^Generic_Template, parameter: Generic_Param_Decl, scope: ^Scope, report: bool,
) -> Type_Id {
	saved := enter_instance(k, template, scope)
	defer k.location = saved
	// A copy, since the arguments resolve for this application and not the next.
	call := clone_expr(k.c, parameter.dependent_on).(^Expr_Call)
	applied := applied_parameters(k, call.callee)
	if parameter.dependent_index >= len(applied.params) {
		return INVALID_TYPE
	}
	return applied_parameter_type(k, call.args, applied, parameter.dependent_index, scope, report)
}

// The type of applied parameter `at`, with the arguments before it bound, as each is
// resolved in `scope`. INVALID_TYPE when they do not bind, which `report` reports.
// Leaves `k.scope` wherever the last step left it.
@(private)
applied_parameter_type :: proc(k: ^Checker, args: []Argument, applied: Applied_Parameters, at: int, scope: ^Scope, report: bool) -> Type_Id {
	inner := new_param_scope(k, applied.scope)
	if applied.first > 0 {
		subject := applied.params[0]
		bind_generic_name(k, inner, Generic_Binding{name = subject.name, span = subject.span, arg = Generic_Arg{is_type = true, type = TYPE_RAWPTR}})
	}
	bindings := make([dynamic]Generic_Binding, 0, len(applied.params), context.temp_allocator)
	for index in applied.first ..< at {
		wanted := parameter_type_in(k, applied, index, inner, report)
		k.scope = scope
		if wanted == INVALID_TYPE || index - applied.first >= len(args) {
			return INVALID_TYPE
		}
		if !bind_record_argument(k, applied.params[index], args[index - applied.first], wanted, inner, &bindings, report) {
			return INVALID_TYPE
		}
	}
	return parameter_type_in(k, applied, at, inner, report)
}

// The type of applied parameter `at`, with those before it bound in `inner`.
@(private = "file")
parameter_type_in :: proc(k: ^Checker, applied: Applied_Parameters, at: int, inner: ^Scope, report: bool) -> Type_Id {
	parameter := applied.params[at]
	if applied.alias != nil {
		if parameter.dependent_on != nil {
			return alias_dependent_type(k, applied.alias, parameter, inner, report)
		}
		return parameter.fixed_type
	}
	k.scope = inner
	return resolve_type_syntax(k, clone_expr(k.c, parameter.type_syntax))
}

// design.md "Parametric aliases": the rules an alias declaration must meet
// before any application of it is resolved. A rejected one is reported here
// once, and its applications report nothing more.
check_alias_template :: proc(k: ^Checker, d: ^Decl, template: ^Generic_Template) {
	body := d.values[0]
	name := identifier_text(k.c, symbol_of(k.c, template.symbol).name)
	if template.impl_type != INVALID_TYPE {
		errorf(k.c, d.span, "L0741", "a parametric alias is declared at package scope, not in an `impl` block")
		template.rejected = true
		return
	}
	if report_alias_distinct(k, body) {
		template.rejected = true
		return
	}
	saved := k.scope
	k.scope = template.scope
	defer k.scope = saved
	// Only a type constructor's application names a type by its arguments; a
	// call that computes one, `size_of($T)` or `Index_Type($N)`, is folded once.
	if call, is_call := body.(^Expr_Call); is_call && !alias_constructor_callee(k, call.callee) {
		errorf(k.c, expr_span(body), "L0744", "a parametric alias names a type; a call that computes one cannot bind `$` names")
		template.rejected = true
		return
	}

	uses := make([dynamic]Alias_Binding_Use, context.temp_allocator)
	alias_binding_uses(k, body, &uses)
	failed := report_unbindable_alias_names(k, body, name, uses[:])
	failed |= settle_alias_parameter_kinds(k, template, uses[:])

	// An application expands its body, so an alias reached again from inside its
	// own body never finishes expanding.
	if alias_refers_to(k, body, template.scope, template.symbol) {
		errorf(k.c, d.span, "L0745", "the type alias `%s` is defined in terms of itself", name)
		failed = true
	}
	if failed {
		template.rejected = true
	}
}

// What an inline definition holds: a record's fields and variants, and a
// procedure's signature.
@(private = "file")
inline_definition_any_name :: proc(node: Expr, data: rawptr, matches: Name_Match) -> bool {
	#partial switch v in node {
	case ^Type_Record:
		for field in v.fields {
			if type_syntax_any_name(field.type, data, matches) {
				return true
			}
		}
		for variant in v.variants {
			if type_syntax_any_name(variant.type, data, matches) {
				return true
			}
		}
	case ^Expr_Proc:
		return type_syntax_any_name(v.signature, data, matches)
	}
	return false
}

// At any depth, as `Option(distinct $T)` would denote a type no other spelling
// names, and a new one in each application.
@(private = "file")
report_alias_distinct :: proc(k: ^Checker, body: Expr) -> bool {
	fresh: Expr
	find_distinct :: proc(data: rawptr, node: Expr) -> bool {
		if v, is_distinct := node.(^Type_Distinct); is_distinct {
			(^Expr)(data)^ = v
			return true
		}
		return inline_definition_any_name(node, data, find_distinct)
	}
	if !type_syntax_any_name(body, &fresh, find_distinct) {
		return false
	}
	errorf(
		k.c, expr_span(fresh), "L0744",
		"a parametric alias names an existing type, so it cannot be `distinct`; declare a generic `struct` or `union` for a new one",
	)
	return true
}

// Every `$` name must be where an argument can bind it, or an application could
// never be matched against the type it denotes.
@(private = "file")
report_unbindable_alias_names :: proc(k: ^Checker, body: Expr, name: string, uses: []Alias_Binding_Use) -> bool {
	written := make([dynamic]^Type_Poly, context.temp_allocator)
	collect_poly :: proc(data: rawptr, node: Expr) -> bool {
		if v, is_poly := node.(^Type_Poly); is_poly {
			append((^[dynamic]^Type_Poly)(data), v)
		}
		// An inline definition holds `$` names no argument reaches.
		return inline_definition_any_name(node, data, collect_poly)
	}
	type_syntax_any_name(body, &written, collect_poly)
	failed := false
	for poly in written {
		bound := false
		for use in uses {
			bound ||= use.span == poly.span
		}
		if !bound {
			errorf(
				k.c, poly.span, "L0742",
				"`$%s` is not where an argument of `%s` can bind it: write it as a type, an array length, or an argument of a generic type",
				poly.name.text, name,
			)
			failed = true
		}
	}
	return failed
}

// Each parameter's kind from the places it is bound, and whether they disagree.
@(private = "file")
settle_alias_parameter_kinds :: proc(k: ^Checker, template: ^Generic_Template, uses: []Alias_Binding_Use) -> bool {
	failed := false
	for &parameter in template.params {
		kind := INVALID_TYPE
		dependent: ^Alias_Binding_Use
		for &use in uses {
			if use.name != parameter.name {
				continue
			}
			if use.dependent_on != nil {
				if kind == TYPE_TYPE {
					report_alias_binding_conflict(k, use.span, parameter.name, DEPENDENT_BINDING, kind)
					failed = true
					break
				}
				dependent = dependent == nil ? &use : dependent
				continue
			}
			if use.value_type == INVALID_TYPE {
				failed = true
				break
			}
			if dependent != nil && use.value_type == TYPE_TYPE {
				report_alias_binding_conflict(k, use.span, parameter.name, TYPE_TYPE, DEPENDENT_BINDING)
				failed = true
				break
			}
			if kind != INVALID_TYPE && kind != use.value_type {
				report_alias_binding_conflict(k, use.span, parameter.name, use.value_type, kind)
				failed = true
				break
			}
			kind = use.value_type
		}
		parameter.fixed_type = kind == INVALID_TYPE ? TYPE_TYPE : kind
		// A written type is the answer wherever one use gives it; the use whose
		// type depends then converts the constant as an application does.
		if kind == INVALID_TYPE && dependent != nil {
			parameter.dependent_on, parameter.dependent_index = dependent.dependent_on, dependent.dependent_index
		}
	}
	return failed
}

// A constant whose type an earlier argument decides, where a report names a kind.
@(private = "file")
DEPENDENT_BINDING :: INVALID_TYPE

@(private = "file")
report_alias_binding_conflict :: proc(k: ^Checker, span: Span, name: Identifier_Id, here, earlier: Type_Id) {
	errorf(
		k.c, span, "L0743",
		"`$%s` is bound by %s here and by %s earlier",
		identifier_text(k.c, name), alias_binding_text(k, here), alias_binding_text(k, earlier),
	)
}

@(private = "file")
alias_binding_text :: proc(k: ^Checker, value_type: Type_Id) -> string {
	switch value_type {
	case TYPE_TYPE:
		return "a type"
	case DEPENDENT_BINDING:
		return "a constant whose type an earlier argument decides"
	}
	return fmt.aprintf("a constant of type `%s`", type_name(k.c, value_type), allocator = k.c.semantic_allocator)
}

// Whether `body`, read in `scope`, applies the alias `target` directly or
// through other aliases. Aliases of one package can refer to each other; an
// import cannot refer back.
@(private = "file")
alias_refers_to :: proc(k: ^Checker, body: Expr, scope: ^Scope, target: Symbol_Id) -> bool {
	Refers :: struct {
		k:       ^Checker,
		scope:   ^Scope,
		target:  Symbol_Id,
		visited: ^map[Symbol_Id]bool,
	}
	reaches_target :: proc(data: rawptr, node: Expr) -> bool {
		data := (^Refers)(data)
		ident, is_ident := node.(^Expr_Ident)
		if !is_ident {
			return false
		}
		symbol := lookup_symbol(data.scope, identifier_of(data.k.c, ident))
		if symbol == data.target {
			return true
		}
		if symbol in data.visited {
			return false
		}
		data.visited[symbol] = true
		other := generic_template_for(data.k, symbol)
		if other == nil || other.kind != .Alias {
			return false
		}
		inner := Refers{k = data.k, scope = other.scope, target = data.target, visited = data.visited}
		return type_syntax_any_name(other.decl.values[0], &inner, reaches_target, skip_field_keys = true)
	}
	visited := make(map[Symbol_Id]bool, context.temp_allocator)
	refers := Refers{k = k, scope = scope, target = target, visited = &visited}
	return type_syntax_any_name(body, &refers, reaches_target, skip_field_keys = true)
}

// design.md "Parametric aliases": `Status(int)` is the type its body denotes
// with `$E` bound to `int`, and has no identity of its own. The body resolves
// where the alias is declared; the arguments, where they are written.
resolve_alias_application :: proc(k: ^Checker, v: ^Expr_Call, template: ^Generic_Template, report: bool) -> Type_Id {
	if template_rejected(k, template) || !generic_application_fits(k, v.args, v.span, template, report) {
		return INVALID_TYPE
	}
	// Most applications find their expansion, so a scope waits for a cache miss
	// unless a dependent parameter's type must be read in one.
	scope: ^Scope
	for parameter in template.params {
		if parameter.dependent_on != nil {
			scope = new_instance_scope(k, template)
			break
		}
	}
	bindings := make([dynamic]Generic_Binding, 0, len(template.params), context.temp_allocator)
	ok := true
	for parameter, index in template.params {
		wanted := parameter.fixed_type
		if parameter.dependent_on != nil {
			// The arguments it depends on are earlier ones, reported if they failed.
			if !ok {
				continue
			}
			// Resolving its type can apply this alias again, as through a record's
			// `$V: Alias(T, 0)`, so the limit counts it as it counts an expansion.
			if !push_application_frame(k, v.span, template.symbol, bindings[:], report) {
				return INVALID_TYPE
			}
			wanted = alias_dependent_type(k, template, parameter, scope, report)
			pop(&k.c.instantiation_stack)
			if wanted == INVALID_TYPE {
				ok = false
				continue
			}
		}
		if !bind_record_argument(k, parameter, v.args[index], wanted, scope, &bindings, report) {
			ok = false
		}
	}
	if !ok {
		return INVALID_TYPE
	}
	if cached, found := cached_alias_expansion(k.c, template.symbol, bindings[:]); found {
		mark_alias_application(v, template, cached)
		return cached
	}
	// No cycle check: an alias reaches itself only through a record (L0745), whose
	// instance already exists. New arguments each time hit this limit.
	if !push_application_frame(k, v.span, template.symbol, bindings[:], report) {
		return INVALID_TYPE
	}
	defer pop(&k.c.instantiation_stack)

	if scope == nil {
		scope = new_bound_instance_scope(k, template, bindings[:])
	}
	saved := enter_instance(k, template, scope)
	body := clone_expr(k.c, template.decl.values[0])
	before := k.c.error_count
	type := resolve_type_syntax(k, body)
	if type == INVALID_TYPE && report && k.c.error_count == before {
		report_unresolved_type(k, body)
	}
	k.location = saved
	if type == INVALID_TYPE {
		return INVALID_TYPE
	}
	k.c.alias_expansions[instance_key(k.c, template.symbol, bindings[:], k.c.semantic_allocator)] = type
	mark_alias_application(v, template, type)
	pend_template_private_read(k, template, scope)
	return type
}

// An application records the type it denotes, and its head the alias, so a
// query finds the declaration.
@(private = "file")
mark_alias_application :: proc(v: ^Expr_Call, template: ^Generic_Template, type: Type_Id) {
	v.denoted_type = type
	v.value_category = .Type
	v.resolution = Resolution{kind = .Type, symbol = template.symbol}
	if head, is_ident := v.callee.(^Expr_Ident); is_ident {
		head.symbol = template.symbol
		head.resolution = Resolution{kind = .Type, symbol = template.symbol}
	}
}

// design.md "Specialization": a pattern written through an alias,
// `s: Status($E)`, matches what its body matches. The body binds the alias's
// own `$` names against the argument's type, and each written argument is then
// matched against what its parameter bound.
match_alias_pattern :: proc(
	k: ^Checker, v: ^Expr_Call, template: ^Generic_Template, actual: Type_Id, scope: ^Scope, out: ^[dynamic]Generic_Binding,
) -> bool {
	if template_rejected(k, template) || len(v.args) != len(template.params) {
		return false
	}
	own := new_instance_scope(k, template)
	inner := make([dynamic]Generic_Binding, 0, len(template.params), context.temp_allocator)
	saved := k.scope
	k.scope = own
	matched := match_type_pattern(k, clone_expr(k.c, template.decl.values[0]), actual, own, &inner)
	k.scope = saved
	if !matched {
		return false
	}
	for parameter, index in template.params {
		for binding in inner {
			if binding.name == parameter.name && !match_generic_arg(k, v.args[index].value, binding.arg, scope, out) {
				return false
			}
		}
	}
	return true
}

// design.md "Parametric aliases": `pattern` with every alias application
// replaced by its body, the alias's `$` names by the written arguments. Only
// the shape-reading tie-breakers read it: the names in a body would resolve
// where the alias is declared, which a substituted copy no longer records.
alias_view :: proc(k: ^Checker, scope: ^Scope, pattern: Expr) -> Expr {
	if pattern == nil {
		return nil
	}
	saved_scope := k.scope
	k.scope = scope
	defer k.scope = saved_scope
	return clone_expr(k.c, pattern, {alias_view = k})
}

// The view of one application of an alias, or nil when `v` applies none. Its
// arguments are cloned under `rewrite`, the clone that met it.
alias_view_of_application :: proc(k: ^Checker, v: ^Expr_Call, rewrite: Clone_Rewrite) -> Expr {
	template := generic_template_of_callee(k, v.callee, {.Alias})
	if template == nil || template.rejected || template.expanding || len(v.args) != len(template.params) {
		return nil
	}
	// The arguments first, in the scope that wrote them.
	substitution := make(map[Identifier_Id]Expr, len(template.params), context.temp_allocator)
	for parameter, index in template.params {
		substitution[parameter.name] = clone_expr(k.c, v.args[index].value, rewrite)
	}
	saved_scope := k.scope
	k.scope = template.scope
	template.expanding = true
	defer {
		k.scope = saved_scope
		template.expanding = false
	}
	body := rewrite
	body.substitution = &substitution
	return clone_expr(k.c, template.decl.values[0], body)
}

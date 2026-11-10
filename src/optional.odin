// Checked extractions and the typed failure protocol.
package lokec

import "core:fmt"
import "core:slice"

// ----------------------------------------------------- failure operators --

Fallible :: struct {
	union_type:   Type_Id,
	failure:      int,
	success:      int,
	failure_type: Type_Id,
	success_type: Type_Id,
}

failure_assignment_borrows :: proc(c: ^Compiler, from, into: Type_Id) -> bool {
	return underlying_kind(c, from) == .String && underlying_kind(c, into) == .String_View
}

fallible_of :: proc(c: ^Compiler, type: Type_Id) -> (Fallible, bool) {
	info := underlying_info(c, type)
	if info == nil || info.kind != .Union || !info.failure_designated {
		return Fallible{}, false
	}
	failure := info.failure_variant
	success := 1 - failure
	return Fallible {
		union_type = type,
		failure = failure,
		success = success,
		failure_type = info.variants[failure],
		success_type = info.variants[success],
	}, true
}

// design.md "Anonymous unions": one carries no attributes, so no alternative
// is its failure.
@(private = "file")
note_anonymous_union_is_data :: proc(k: ^Checker, type: Type_Id, span: Span) {
	if info := underlying_info(k.c, type); info != nil && info.anonymous_union {
		add_notef(
			k.c, span,
			"an anonymous union is plain data; a failure is a `Result`, an `Option`, or a named union with `@(failure=name)`",
		)
	}
}

note_optional_replacement :: proc(k: ^Checker, e: Expr) {
	if index, is_index := e.(^Expr_Index); is_index && index.operand != nil && type_is_map(k.c, expr_base(index.operand).type) && !index.map_inserts {
		add_notef(k.c, expr_span(e), "`m[key]` reads one value; `m.lookup_value(key)` yields `Option(V)`")
	}
}

check_or_else :: proc(k: ^Checker, v: ^Expr_Or_Else) {
	if check_expr(k, v.value) == INVALID_TYPE {
		return
	}
	shape, is_fallible := fallible_of(k.c, expr_base(v.value).type)
	if !is_fallible {
		errorf(
			k.c,
			expr_span(v.value),
			"L0428",
			"`or_else` needs a union with a designated failure variant on its left, found `%s`",
			type_name(k.c, expr_base(v.value).type),
		)
		note_optional_replacement(k, v.value)
		note_anonymous_union_is_data(k, expr_base(v.value).type, expr_span(v.value))
		return
	}
	// design.md "or_else expression": a payloadless success yields `Unit`.
	payload := payload_value_type(k.c, shape.success_type)
	v.borrows = expr_base(v.value).value_category == .Place
	if v.borrows && type_clone_disabled(k.c, payload) {
		errorf(
			k.c, expr_span(v.value), "L0503",
			"`%s` is move-only, so `or_else` cannot copy it out of a place; write `move(...)`",
			type_name(k.c, payload),
		)
		return
	}
	if v.borrows {
		contribute_lifecycle_members(k, payload)
	}
	// design.md "or_else expression": a failure that leaves supplies no value.
	if v.exit != nil {
		if !check_or_else_exit(k, v) {
			return
		}
	} else {
		if !check_value_expr(k, v.fallback, payload, "supply") {
			return
		}
		v.fallback_clone = classify_costed_copy(k, v.fallback, payload, .Or_Else_Fallback)
		if type_clone_disabled(k.c, payload) && expression_is_borrowed_place(v.fallback) {
			return
		}
	}
	// design.md "Operator ownership": a place operand's success payload is
	// copied out, and only that copy is reported.
	if v.borrows {
		record_copy(k, .Or_Else, expr_span(v.value), v.value, payload)
	}
	v.type = payload
}

// ----------------------------------------------------------- or_return --

check_or_return :: proc(k: ^Checker, v: ^Expr_Postfix) {
	if k.proc_literal == nil {
		errorf(k.c, v.op_span, "L0429", "`or_return` is only valid inside a procedure")
		return
	}
	if k.in_defer {
		errorf(k.c, v.op_span, "L0429", "`or_return` cannot appear inside a deferred statement")
		return
	}
	if check_expr(k, v.operand) == INVALID_TYPE {
		return
	}
	base := expr_base(v.operand)
	shape, is_fallible := fallible_of(k.c, base.type)
	if !is_fallible {
		errorf(
			k.c,
			v.op_span,
			"L0429",
			"`or_return` needs a union with a designated failure variant, found `%s`",
			type_name(k.c, base.type),
		)
		note_anonymous_union_is_data(k, base.type, v.op_span)
		return
	}
	if v.failure != nil {
		if !check_or_return_failure(k, v, shape) {
			return
		}
	} else if !check_or_return_target(k, v, shape) {
		return
	}
	success := payload_value_type(k.c, shape.success_type)
	v.borrows = base.value_category == .Place
	if v.borrows {
		// A replacement leaves the error in its place, so only a mapped or
		// propagated one is copied out.
		replaces := v.failure != nil && !v.failure_maps
		for candidate, index in ([2]Type_Id{shape.success_type, shape.failure_type}) {
			if candidate == TYPE_VOID || (index == 1 && replaces) {
				continue
			}
			if type_clone_disabled(k.c, candidate) {
				errorf(
					k.c, v.op_span, "L0503",
					"`%s` is move-only, so `or_return` cannot copy it out of a place; write `move(...)`",
					type_name(k.c, candidate),
				)
				return
			}
			contribute_lifecycle_members(k, candidate)
		}
		// design.md "Operator ownership": the report names what may be copied out,
		// the whole fallible union unless the error stays.
		record_copy(k, .Or_Return, expr_span(v.operand), v.operand, replaces ? success : base.type)
	}
	v.type = success
}

// design.md "The failure operand": builds `v.failure_exit`, the `return` a failure takes.
@(private = "file")
check_or_return_failure :: proc(k: ^Checker, v: ^Expr_Postfix, shape: Fallible) -> bool {
	target := or_return_target(k, v) or_return
	into := target.failure_type
	if into == TYPE_VOID {
		errorf(
			k.c, expr_span(v.failure), "L0429",
			"`%s.%s` carries nothing, so this `or_return` takes no failure operand",
			type_name(k.c, k.result_type), union_variant_name(k.c, k.result_type, target.failure),
		)
		return false
	}
	from := shape.failure_type
	span := expr_span(v.failure)
	payload, constructs := or_return_constructs(k, v.failure, into)
	if constructs && (from == TYPE_VOID || !assignable(k.c, from, payload)) {
		errorf(
			k.c, span, "L0429", "`.%s` wraps `%s`, but this failure carries %s",
			v.failure.(^Expr_Selector).name.text, type_name(k.c, payload),
			from == TYPE_VOID ? "nothing" : fmt.tprintf("`%s`", type_name(k.c, from)),
		)
		if from != TYPE_VOID {
			note_union_widening(k, span, from, payload)
		}
		return false
	}
	replaces := !constructs && or_return_replaces(k, v.failure, into)
	// A failure that carries nothing takes only a replacement, so anything else
	// is checked as one and reports what is wrong with it.
	v.failure_maps = !replaces && from != TYPE_VOID
	value := v.failure
	if v.failure_maps {
		error := new(Expr_Propagated_Error, k.c.semantic_allocator)
		error.span = span
		error.owner = v
		value = synth_call(k.c, v.failure, {error}, span)
	}
	v.failure_exit = failure_return(k, target, value, span)
	errors := k.c.error_count
	check_stmt(k, v.failure_exit)
	if k.c.error_count == errors {
		return true
	}
	if !replaces && !v.failure_maps && expr_base(v.failure).type != INVALID_TYPE {
		add_notef(
			k.c, span, "`%s.%s` carries no error to map; write the failure to return instead",
			type_name(k.c, shape.union_type), union_variant_name(k.c, shape.union_type, shape.failure),
		)
	}
	// `f() or_return.len()` reads `.len()` as the operand.
	if operand := expr_span(v.operand); span.lo == v.op_span.hi && operand.file == span.file {
		text := k.c.sources[span.file].text
		add_notef(
			k.c, span, "after `or_return`, `%s` is its failure operand; to reach the success payload, write `(%s or_return)%s`",
			text[span.lo:span.hi], text[operand.lo:operand.hi], text[span.lo:span.hi],
		)
	}
	return false
}

// `return .failure(value);`, for the caller to check as the `return` it is.
@(private = "file")
failure_return :: proc(k: ^Checker, target: Fallible, value: Expr, span: Span) -> ^Stmt_Return {
	wrap := synth_call(k.c, variant_selector(k, target.union_type, target.failure, span), {value}, span)
	exit := new(Stmt_Return, k.c.semantic_allocator)
	exit.span = span
	exit.value = new(Return_Value, k.c.semantic_allocator)
	exit.value.span = span
	exit.value.expr = wrap
	return exit
}

// The payload of `.name` when it names a variant of the failure payload type
// that carries one: its constructor wraps the error (design.md "Constructing a
// variant").
@(private = "file")
or_return_constructs :: proc(k: ^Checker, failure: Expr, into: Type_Id) -> (payload: Type_Id, constructs: bool) {
	selector, is_selector := failure.(^Expr_Selector)
	if !is_selector || selector.operand != nil || !type_is_union(k.c, into) {
		return INVALID_TYPE, false
	}
	index := union_index_of(k.c, into, selector.name.text)
	if index < 0 {
		return INVALID_TYPE, false
	}
	payload = union_variant_payload(k.c, into, index)
	return payload, payload != TYPE_VOID && payload != k.c.unit_type
}

// Whether the failure operand is a value of the failure payload type, decided on
// a probe of a copy so the real operand is checked once, in its role.
@(private = "file")
or_return_replaces :: proc(k: ^Checker, failure: Expr, into: Type_Id) -> bool {
	#partial switch v in failure {
	case ^Expr_Literal, ^Expr_Composite:
		return true
	case ^Expr_Selector:
		if v.operand == nil {
			return true
		}
	}
	probe := begin_probe(k.c)
	defer end_probe(k.c, probe)
	trial := clone_expr(k.c, failure)
	errors := k.c.error_count
	type := check_single_expr(k, trial, into)
	return k.c.error_count == errors && type != INVALID_TYPE && assignable(k.c, type, into)
}

// The procedure's result a failure is returned as, or a report that it has none.
@(private = "file")
or_return_target :: proc(k: ^Checker, v: ^Expr_Postfix) -> (Fallible, bool) {
	if k.result_type == INVALID_TYPE {
		errorf(k.c, v.op_span, "L0429", "`or_return` needs a result to propagate the failure into")
		return Fallible{}, false
	}
	target, target_fallible := fallible_of(k.c, k.result_type)
	if !target_fallible {
		errorf(
			k.c,
			v.op_span,
			"L0429",
			"`or_return` needs this procedure's result to be a union with a designated failure variant, found `%s`",
			type_name(k.c, k.result_type),
		)
	}
	return target, target_fallible
}

@(private = "file")
check_or_return_target :: proc(k: ^Checker, v: ^Expr_Postfix, shape: Fallible) -> bool {
	target := or_return_target(k, v) or_return
	from := shape.failure_type
	into := target.failure_type
	if from != into && !(from != TYPE_VOID && into != TYPE_VOID && assignable(k.c, from, into)) {
		errorf(
			k.c,
			v.op_span,
			"L0429",
			"the failure payload `%s` cannot be returned as `%s`",
			from == TYPE_VOID ? "()" : type_name(k.c, from),
			into == TYPE_VOID ? "()" : type_name(k.c, into),
		)
		if from != TYPE_VOID && into != TYPE_VOID {
			note_union_widening(k, v.op_span, from, into)
		}
		return false
	}
	return true
}

// -------------------------------------------------------- success returns --

// design.md "One result": a body whose result is a fallible union whose
// success carries nothing or `Unit`, such as `Status(E)` or `Result(Unit, E)`,
// may reach its end, which returns that success. The `return` is appended, so
// every later phase sees the statement it means. Its span is empty, at the
// closing brace, so no query finds it.
implicit_success :: proc(k: ^Checker, literal: ^Expr_Proc, symbol: ^Symbol) -> bool {
	if literal.body == nil || !k.body.bare_success {
		return false
	}
	end := literal.body.span
	end.lo = max(end.hi, 1) - 1
	end.hi = end.lo
	exit := new(Stmt_Return, k.c.semantic_allocator)
	exit.span = end
	exit.value = bare_success_value(k, symbol.result, end)
	stmts := make([]Stmt, len(literal.body.stmts) + 1, k.c.semantic_allocator)
	copy(stmts, literal.body.stmts)
	stmts[len(stmts) - 1] = exit
	literal.body.stmts = stmts
	check_stmt(k, exit)
	return true
}

// The returned value that a body's bare success stands for, at an empty span.
bare_success_value :: proc(k: ^Checker, result: Type_Id, at: Span) -> ^Return_Value {
	shape, _ := fallible_of(k.c, result)
	value := new(Return_Value, k.c.semantic_allocator)
	value.span = at
	value.expr = variant_selector(k, result, shape.success, at)
	return value
}

// The unchecked `.name` of `result`'s variant `index`, as a compiler-written
// statement spells it. An empty `at` keeps it out of every query.
@(private = "file")
variant_selector :: proc(k: ^Checker, result: Type_Id, index: int, at: Span) -> ^Expr_Selector {
	return synth_selector(k.c, nil, union_variant_name(k.c, result, index), at)
}

// design.md "One result": whether a body may return its success by reaching
// its end or with `return;`. A payloadless success always may. A `Unit` one
// may when the result as written makes it `Unit`, so that a body generic over
// `Result(T, E)` means the same in an instance where `T` is `Unit` as in any
// other.
success_needs_no_value :: proc(k: ^Checker, scope: ^Scope, literal: ^Expr_Proc, symbol: ^Symbol) -> bool {
	if symbol.result_inout {
		return false
	}
	shape, fallible := fallible_of(k.c, symbol.result)
	if !fallible {
		return false
	}
	payload := shape.success_type
	if payload == TYPE_VOID {
		return true
	}
	if payload != k.c.unit_type {
		return false
	}
	result := literal.signature.result
	return result == nil || !success_names_generic(k, scope, result.type, shape.success)
}

// Whether the success payload of a written fallible result depends on a
// generic argument bound in `scope`. `Result(Unit, E)` does not, though `E` is
// one; `Result(T, E)` and a bare `R` do.
@(private = "file")
success_names_generic :: proc(k: ^Checker, scope: ^Scope, syntax: Expr, success: int) -> bool {
	if !type_syntax_names_generic(k, scope, syntax) {
		return false
	}
	read_alias :: proc(k: ^Checker, id: Symbol_Id, success: int) -> (depends, is_alias: bool) {
		target, target_scope := local_alias_target(k, id)
		if target == nil {
			return false, false
		}
		saved := k.scope
		k.scope = target_scope
		defer k.scope = saved
		return success_names_generic(k, target_scope, target, success), true
	}
	#partial switch v in syntax {
	case ^Expr_Ident:
		// An alias means what it names, so `Outcome :: Result(Unit, E)` leaves the
		// success as `Unit` as written, and `Outcome :: Result(T, E)` does not.
		if depends, is_alias := read_alias(k, lookup_symbol(scope, identifier_of(k.c, v)), success); is_alias {
			return depends
		}
	case ^Expr_Selector:
		// `Local.Outcome` reads the same way. `T.Outcome` and `Box(T).Outcome` do
		// not, since which member they select depends on the argument.
		if type_syntax_names_generic(k, scope, v.operand) {
			return true
		}
		if depends, is_alias := read_alias(k, v.resolution.symbol, success); is_alias {
			return depends
		}
	case ^Expr_Call:
		template := generic_template_of_callee(k, v.callee, TYPE_GENERICS)
		if template == nil || len(v.args) != len(template.params) {
			return true
		}
		depends := success_parameters(k, template, success)
		for arg, i in v.args {
			if depends[i] && type_syntax_names_generic(k, scope, arg.value) {
				return true
			}
		}
		return false
	case ^Type_Record:
		if success < len(v.variants) {
			payload := v.variants[success].type
			return payload != nil && type_syntax_names_generic(k, scope, payload)
		}
	}
	return true
}

// Whether type syntax names a generic argument bound in `scope`, as
// `Result(T, Error)`, `Result($T, Error)`, or `[N + 1]int` does in an instance
// generic over `T` or `N`. Outside an instance nothing is bound, so nothing is
// walked.
type_syntax_names_generic :: proc(k: ^Checker, scope: ^Scope, e: Expr) -> bool {
	if !scope_in_instance(scope) {
		return false
	}
	lookup := Generic_Lookup{k = k, scope = scope, from = scope, followed = make([dynamic]Symbol_Id, context.temp_allocator)}
	return type_syntax_any_name(e, &lookup, names_generic_binding)
}

@(private = "file")
scope_in_instance :: proc(scope: ^Scope) -> bool {
	for enclosing := scope; enclosing != nil; enclosing = enclosing.parent {
		if enclosing.instance != nil {
			return true
		}
	}
	return false
}

// What a constant declared in a generic body stands for wherever it is named,
// and the scope that reads it: `Result(T, E)` for `Outcome :: Result(T, E)`, or
// `N * 2` for `Twice :: N * 2`. A package-scope constant cannot name a binding,
// and a declaration that defines something, such as `Local :: struct { x: T }`,
// is one type in each instance rather than a spelling of its arguments.
@(private = "file")
local_alias_target :: proc(k: ^Checker, id: Symbol_Id) -> (target: Expr, scope: ^Scope) {
	symbol := symbol_of(k.c, id)
	if symbol == nil || symbol.generic || symbol.decl == nil || symbol.decl.kind != .Const || !scope_in_instance(symbol.def_scope) {
		return nil, nil
	}
	// grammar.md "Declarations": a constant binds one name, and an incomplete
	// declaration may have no initializer.
	if len(symbol.decl.symbols) != 1 || symbol.decl.symbols[0] != id || len(symbol.decl.values) == 0 {
		return nil, nil
	}
	#partial switch _ in symbol.decl.values[0] {
	case ^Type_Record, ^Type_Enum, ^Type_Distinct, ^Type_Interface, ^Expr_Proc, ^Expr_Proc_Group, ^Expr_Operator:
		return nil, nil
	}
	return symbol.decl.values[0], symbol.def_scope
}

@(private = "file")
Generic_Lookup :: struct {
	k:        ^Checker,
	scope:    ^Scope,
	// Where the syntax is written. A selected member can name a binding this
	// scope does not bind: `B.Outcome` for `B :: Box(Unit)` reads `Box`'s own `$U`,
	// which is not a generic argument here.
	from:     ^Scope,
	// The aliases already read, since each answers once and a cyclic one, which
	// its declaration reports, must not be read forever.
	followed: [dynamic]Symbol_Id,
}

// A `$` name is a generic argument, and a local alias, named or selected from a
// type, depends on one through what it names (design.md "Success returns").
@(private = "file")
names_generic_binding :: proc(data: rawptr, node: Expr) -> bool {
	lookup := (^Generic_Lookup)(data)
	#partial switch v in node {
	case ^Expr_Ident:
		id := lookup_symbol(lookup.scope, identifier_of(lookup.k.c, v))
		symbol := symbol_of(lookup.k.c, id)
		if symbol == nil {
			return false
		}
		if symbol.generic_binding {
			return lookup_symbol(lookup.from, symbol.name) == id
		}
		return alias_names_generic(lookup, id)
	case ^Expr_Selector:
		return alias_names_generic(lookup, v.resolution.symbol)
	case ^Type_Poly:
		return true
	case ^Expr_Proc:
		return type_syntax_any_name(v.signature, data, names_generic_binding)
	}
	// A declaration defines its own type; its contents name no argument here.
	return false
}

// Whether the local alias `id`, if it is one, names a generic argument.
@(private = "file")
alias_names_generic :: proc(lookup: ^Generic_Lookup, id: Symbol_Id) -> bool {
	target, target_scope := local_alias_target(lookup.k, id)
	if target == nil || slice.contains(lookup.followed[:], id) {
		return false
	}
	append(&lookup.followed, id)
	saved := lookup.scope
	lookup.scope = target_scope
	defer lookup.scope = saved
	return type_syntax_any_name(target, lookup, names_generic_binding)
}

// What a returned expression's form says it builds (design.md "Success
// returns"), decided before it has a type.
@(private = "file")
Return_Target :: enum u8 {
	// A variant construction or implicit selector: the whole result.
	Result,
	// A composite literal or an unfixed constant, from which no union is built.
	Payload,
	// An expression with a type of its own: the result when it is assignable.
	Either,
}

@(private = "file")
return_target :: proc(e: Expr) -> Return_Target {
	#partial switch v in e {
	case ^Expr_Selector:
		if v.operand == nil {
			return .Result
		}
	case ^Expr_Call:
		if is_implicit_selector(v.callee) {
			return .Result
		}
	case ^Expr_Cond:
		if return_target(v.then) == .Result || return_target(v.otherwise) == .Result {
			return .Result
		}
	case ^Expr_Composite, ^Expr_Literal:
		return .Payload
	}
	return .Either
}

// Checks a returned value against the result. In a procedure whose result is
// a fallible union with a success payload, a value that is not the whole
// result is checked against the payload, and the statement becomes the
// `.ok(value)` it stands for (design.md "Success returns").
check_returned_value :: proc(k: ^Checker, value: ^Return_Value) -> bool {
	result := k.result_type
	e := value.expr
	target := return_target(e)
	shape, fallible := fallible_of(k.c, result)
	payload := fallible ? shape.success_type : TYPE_VOID
	failure := fallible ? shape.failure_type : TYPE_VOID
	// In a generic body the two payloads may be one type in some instance, so a
	// value meant as the error would become the success there.
	wraps := payload != TYPE_VOID && !(k.result_generic && failure != TYPE_VOID)
	if !wraps || target == .Result {
		errors := k.c.error_count
		if check_value_expr(k, e, result, "return") {
			return true
		}
		if fallible && k.c.error_count > errors {
			note_success_return(k, e, shape, target, wraps)
		}
		return false
	}

	type := check_single_expr(k, e, payload)
	if type == INVALID_TYPE {
		return false
	}
	untyped := type_is_untyped(k.c, type)
	// A call that never returns stands in for any value, the result included.
	if call_diverges(k.c, e) {
		expr_base(e).type = result
		return materialize_value_expr(k, e, result, "return")
	}
	if target == .Either && !untyped && assignable(k.c, type, result) {
		return materialize_value_expr(k, e, result, "return")
	}
	success := union_variant_name(k.c, result, shape.success)
	if type == TYPE_UNTYPED_NIL {
		report_returned_nil(k, e, shape)
		return false
	}
	if !untyped && !assignable(k.c, type, payload) {
		errorf(
			k.c, expr_span(e), "L0310",
			"cannot return `%s` from a procedure that returns `%s`: it is neither the result nor its `.%s` payload `%s`",
			type_name(k.c, type), type_name(k.c, result), success, type_name(k.c, payload),
		)
		note_success_return(k, e, shape, target, wraps)
		return false
	}
	if !materialize_value_expr(k, e, payload, "return") {
		return false
	}
	e = transfer_returned_local(k, e)
	if base := expr_base(e); base.value_category == .Place && type_clone_disabled(k.c, payload) {
		errorf(
			k.c, expr_span(e), "L0502",
			"`%s` is move-only, so a borrowed value of it cannot be returned by value; return a `move` parameter or a local instead",
			type_name(k.c, payload),
		)
		return false
	}
	value.expr = wrap_returned_success(k, e, shape)
	return true
}

// design.md "Success returns": `nil` is never an implicit success, so `return
// nil;` cannot be read as absence and silently be `.some(nil)`. Only an unchecked
// address takes `nil`, so only there is the success a fix to suggest.
@(private = "file")
report_returned_nil :: proc(k: ^Checker, e: Expr, shape: Fallible) {
	result := k.result_type
	payload := shape.success_type
	success := union_variant_name(k.c, result, shape.success)
	failed := union_variant_name(k.c, result, shape.failure)
	if type_accepts_nil(k.c, payload) {
		errorf(
			k.c, expr_span(e), "L0310",
			"`nil` does not build `.%s` implicitly: write `.%s(nil)` for a success, or `.%s` for the failure",
			success, success, failed,
		)
	} else {
		errorf(
			k.c, expr_span(e), "L0310",
			"`nil` is not a value of `%s`, the `.%s` payload: write `.%s` for the failure",
			type_name(k.c, payload), success, failed,
		)
	}
}

// The checked `.ok(e)` a returned payload stands for.
@(private = "file")
wrap_returned_success :: proc(k: ^Checker, e: Expr, shape: Fallible) -> Expr {
	result := k.result_type
	at := expr_span(e)
	at.hi = at.lo
	callee := variant_selector(k, result, shape.success, at)
	call := synth_call(k.c, callee, {e}, at)
	call.args[0].span = expr_span(e)
	check_union_variant_selector(k, callee, result, callee = true)
	finish_union_construct(k, call, result, shape.success, e)
	return call
}

// After a returned value fit nothing: name the variant that would take it.
@(private = "file")
note_success_return :: proc(k: ^Checker, e: Expr, shape: Fallible, target: Return_Target, wraps: bool) {
	result := k.result_type
	success := union_variant_name(k.c, result, shape.success)
	failure := union_variant_name(k.c, result, shape.failure)
	payload := shape.success_type
	failure_payload := shape.failure_type
	if selector, is_selector := e.(^Expr_Selector); is_selector && selector.operand == nil {
		// `return .Bad_Digit;` names a member of a payload, not a variant.
		id := intern_identifier(k.c, selector.name.text)
		switch {
		case type_has_member(k.c, failure_payload, id):
			add_notef(k.c, selector.span, "`.%s` belongs to the `.%s` payload: write `.%s(.%s)`", selector.name.text, failure, failure, selector.name.text)
		case type_has_member(k.c, payload, id):
			add_notef(k.c, selector.span, "`.%s` belongs to the `.%s` payload: write `.%s(.%s)`", selector.name.text, success, success, selector.name.text)
		}
		return
	}
	if target == .Result {
		return
	}
	type := expr_base(e).type
	switch {
	case type == INVALID_TYPE:
	case !wraps && payload != TYPE_VOID:
		add_notef(
			k.c, expr_span(e), "this result names a generic argument, so a returned value is never wrapped: write `.%s(value)` or `.%s(value)`",
			success, failure,
		)
	case failure_payload != TYPE_VOID && assignable(k.c, type, failure_payload):
		if payload == TYPE_VOID {
			add_notef(k.c, expr_span(e), "`.%s` carries nothing here; write `.%s(value)` to fail", success, failure)
		} else {
			add_notef(k.c, expr_span(e), "a returned value builds only `.%s`; write `.%s(value)` to fail", success, failure)
		}
	}
}

// Whether `type` is an enum with member `name` or a union with variant `name`.
@(private = "file")
type_has_member :: proc(c: ^Compiler, type: Type_Id, name: Identifier_Id) -> bool {
	if type == TYPE_VOID || type == INVALID_TYPE {
		return false
	}
	underlying := type_underlying(c, type)
	if type_is_enum(c, underlying) {
		return field_named(c, underlying, name) != INVALID_SYMBOL
	}
	return union_variant_index(c, type, name) >= 0
}

// ------------------------------------------------------- or_else exits --

// design.md "or_else expression": `break`, `continue`, and `return value` in the
// fallback position are the statements, run where the failure is found.
@(private = "file")
check_or_else_exit :: proc(k: ^Checker, v: ^Expr_Or_Else) -> bool {
	exit_span := stmt_span(v.exit)
	_, is_return := v.exit.(^Stmt_Return)
	keyword := "return"
	if branch, is_branch := v.exit.(^Stmt_Branch); is_branch {
		keyword = branch.kind == .Break ? "break" : "continue"
	}
	if k.proc_literal == nil {
		errorf(k.c, exit_span, "L0718", "`or_else %s` is only valid inside a procedure", keyword)
		return false
	}
	if k.in_defer && (is_return || k.loop_depth <= k.defer_loop_depth) {
		errorf(k.c, exit_span, "L0369", "a deferred statement cannot leave the construct it is registered in")
		return false
	}
	if !is_return && k.loop_header {
		errorf(
			k.c, exit_span, "L0718",
			"`or_else %s` cannot appear in a loop's header; test the value in the body", keyword,
		)
		return false
	}
	errors := k.c.error_count
	flow := check_stmt(k, v.exit)
	if flow.breaks {
		k.loop_broken = true
	}
	return k.c.error_count == errors
}

// Statement checking: control flow, assignment and its `operator([]=)` lowerings,
// and the declarations a body writes.
package lokec

import "core:strconv"

check_block :: proc(k: ^Checker, b: ^Block) -> Flow_Info {
	if b == nil {
		return FLOWS
	}
	return check_stmts(k, b.stmts)
}

// The combined flow of a statement sequence: a block's, or one switch case's.
check_stmts :: proc(k: ^Checker, stmts: []Stmt) -> Flow_Info {
	outer_following := k.body.following
	k.body.following = nil
	defer k.body.following = outer_following
	flow := check_stmt_sequence(k, stmts)
	report_unread_required_results(k, stmts)
	report_local_copy_decisions(k, stmts)
	return flow
}

// A body-local record's copy decision, asked after the whole sequence, since its
// `impl` blocks are statements after it. Each instance of a generic procedure
// asks for its own copy of the declaration: its hooks and fields are that
// instance's, so one instance's answer says nothing about another's.
@(private = "file")
report_local_copy_decisions :: proc(k: ^Checker, stmts: []Stmt) {
	for_each_sequence_decl(k, stmts, check_copy_decision)
}

// Each declaration of a sequence, in source order: one written in it, one a
// `defer` wraps directly, which is checked here and stays visible to the
// sequence whatever runs it later (design.md "defer statement"), and one in a
// selected `when` branch, which has no scope of its own (design.md "when
// statement").
@(private = "file")
for_each_sequence_decl :: proc(k: ^Checker, stmts: []Stmt, visit: proc(k: ^Checker, d: ^Decl)) {
	for stmt in stmts {
		inner := stmt
		if deferred, is_deferred := stmt.(^Stmt_Defer); is_deferred {
			inner = deferred.stmt
		}
		#partial switch v in inner {
		case ^Stmt_When:
			if v.selected != nil {
				for_each_sequence_decl(k, v.selected.stmts, visit)
			}
		case ^Decl:
			visit(k, v)
		}
	}
}

// A sequence that does not end a scope: a selected `when` branch, whose
// bindings the enclosing sequence reports.
@(private = "file")
check_stmt_sequence :: proc(k: ^Checker, stmts: []Stmt) -> Flow_Info {
	flow := FLOWS
	outer := k.body.following
	defer k.body.following = outer
	following := Following_Stmts{outer = outer}
	k.body.following = &following
	for stmt, index in stmts {
		following.stmts = stmts[index + 1:]
		reachable, broken := flow.can_fall_through, k.loop_broken
		flow_then(&flow, check_stmt(k, stmt))
		// An `or_else break` nothing reaches ends no loop either.
		if !reachable {
			k.loop_broken = broken
		}
	}
	return flow
}

// design.md "@(require_results)": a required result bound and never read.
// Asked after the whole sequence is checked, in source order.
report_unread_required_results :: proc(k: ^Checker, stmts: []Stmt) {
	for_each_sequence_decl(k, stmts, report_unread_required_bindings)
}

@(private = "file")
report_unread_required_bindings :: proc(k: ^Checker, d: ^Decl) {
	if d.kind != .Var {
		return
	}
	for id, index in d.symbols {
		sym := symbol_of(k.c, id)
		if sym == nil || sym.named || sym.kind != .Var {
			continue
		}
		// Only a call's result is asked about, as `note_required_write` asks it.
		initializer, _ := declared_initializer(d, index)
		call := producing_call(initializer)
		if call == nil || call.type == INVALID_TYPE {
			continue
		}
		required := type_requires_results(k.c, sym.type)
		source := ""
		if !required && index < len(d.values) {
			source, required = required_result_of_call(k, call)
		}
		if !required {
			continue
		}
		span := index < len(d.names) ? d.names[index].span : d.span
		if source != "" {
			errorf(
				k.c, span, "L0698",
				"`%s` holds the result of `%s`, which is never used: inspect it, or discard it with `_ = ...`",
				identifier_text(k.c, sym.name), source,
			)
			continue
		}
		errorf(
			k.c, span, "L0698",
			"`%s` holds a `%s` that is never used: inspect it, or discard it with `_ = ...`",
			identifier_text(k.c, sym.name), type_name(k.c, sym.type),
		)
	}
}

check_scoped_block :: proc(k: ^Checker, b: ^Block) -> Flow_Info {
	return check_scoped_stmts(k, b.stmts if b != nil else nil)
}

// A statement sequence in a local scope of its own: a block, or a case.
check_scoped_stmts :: proc(k: ^Checker, stmts: []Stmt) -> Flow_Info {
	outer := k.scope
	k.scope = new_scope(k.c, outer, .Local)
	defer k.scope = outer
	return check_stmts(k, stmts)
}

// The backend emits only file-level procedures, so a local one (or a local
// `impl` method) is hoisted like a literal.
hoist_body_local_proc :: proc(k: ^Checker, d: ^Decl) {
	literal := decl_proc_literal(d)
	if literal == nil || !committing(k.c) || len(d.symbols) == 0 {
		return
	}
	if d.symbols[0] == INVALID_SYMBOL || symbol_is_generic(k, d.symbols[0]) {
		return
	}
	if pkg := package_of(k.c, k.pkg); pkg != nil {
		append(&pkg.hoisted_procs, literal)
	}
}

// The package phases, in the same order, for a declaration in a body: one
// written there, or a capture literal's record.
check_local_declaration :: proc(k: ^Checker, d: ^Decl) {
	// design.md "Receiver forms": a procedure declared in a method's body is no
	// member of its block, so `self` there is an ordinary parameter.
	outer_impl := k.impl_type
	k.impl_type = INVALID_TYPE
	defer k.impl_type = outer_impl
	// design.md "Capture literals": a capture runs where the literal is
	// evaluated, so a capture literal is a runtime value, never a constant.
	if d.kind == .Const {
		for value in d.values {
			if literal, is_composite := value.(^Expr_Composite); is_composite && literal.capture != nil {
				errorf(
					k.c, literal.capture.clause_span, "L0716",
					"a capture literal is a runtime value, so it is declared with `:=`, not `::`",
				)
				// Checked as the `:=` it should be, so its uses report nothing more.
				d.kind = .Var
				break
			}
		}
	}
	declare_all(k, d)
	install_symbols(k.scope, k.c, d.symbols)
	create_nominal_type_shell(k, d)
	resolve_declaration_signature(k, d)
	check_declaration_size(k, d)
	hoist_local_lifecycle_hooks(k, d)
	hoist_body_local_proc(k, d)
	// Local symbols do not exist during the package-wide attribute pass.
	validate_decl_attributes(k, d, .Local)
	check_decl(k, d)
	classify_declaration_copies(k, d)
}

// An unfinished statement is checked only so its names and types are recorded
// for editor queries. The syntax error is the one report: what checking says
// about the statement's own text is dropped. Later passes never see it.
@(private = "file")
check_partial_statement :: proc(k: ^Checker, s: ^Stmt_Error) {
	if s.partial == nil {
		return
	}
	mark := len(k.c.diagnostics)
	check_stmt(k, s.partial)
	// Reports elsewhere, such as from a declaration checked on demand, stay.
	kept := mark
	for index in kept ..< len(k.c.diagnostics) {
		diagnostic := k.c.diagnostics[index]
		span := diagnostic.span
		if span.file == s.span.file && span.lo >= s.span.lo && span.hi <= s.span.hi {
			discard_diagnostic(k.c, &k.c.diagnostics[index])
			continue
		}
		k.c.diagnostics[kept] = diagnostic
		kept += 1
	}
	shrink_diagnostics(k.c, kept)
}

check_stmt :: proc(k: ^Checker, stmt: Stmt) -> Flow_Info {
	#partial switch _ in stmt {
	case ^Decl, ^Item_Impl:
		// Validated with their members, by position.
	case:
		validate_attribute_list(k, stmt_base(stmt).attributes, .Statement)
	}
	switch s in stmt {
	case ^Stmt_Error:
		// Parser diagnostics already describe this retained recovery node.
		check_partial_statement(k, s)
		return FLOWS

	case ^Item_Impl:
		check_local_impl(k, s)
		return FLOWS

	case ^Decl:
		// compiler-architecture.md "Intrinsic declarations": a local one describes nothing, and a type
		// written `---` has no value to check.
		if attribute, found := find_attribute(s.attributes, "intrinsic"); found {
			report_misplaced_intrinsic(k, attribute.span)
			return FLOWS
		}
		check_local_declaration(k, s)
		return s.kind == .Var ? flow_past(k.c, s.values) : FLOWS

	case ^Stmt_Expr:
		for expr in s.exprs {
			check_expr(k, expr)
			if expr != nil && !expression_statement_has_effect(k.c, expr) {
				errorf(k.c, expr_span(expr), "L0313", "this expression statement has no effect")
			}
			report_discarded_required_results(k, expr)
		}
		return flow_past(k.c, s.exprs)

	case ^Stmt_Assign:
		check_assign(k, s)
		classify_assignment_copies(k, s)
		return assign_flow(k.c, s)

	case ^Stmt_If:
		return check_if(k, s)

	case ^Stmt_For:
		return check_for(k, s)

	case ^Stmt_Switch:
		return check_switch(k, s)

	case ^Stmt_Defer:
		return check_defer(k, s)

	case ^Stmt_Return:
		return check_return(k, s)

	case ^Stmt_Branch:
		return check_branch(k, s)

	case ^Stmt_Parallel:
		return check_parallel(k, s)

	case ^Stmt_Spawn:
		return check_spawn(k, s)

	case ^Block:
		return check_scoped_block(k, s)

	case ^Stmt_When:
		return check_when_stmt(k, s)

	case ^Stmt_Foreach:
		// A `$` binding, at any depth of the pattern, makes this a compile-time
		// expansion.
		if any_static_binding(s.bindings) {
			return check_static_foreach(k, s)
		}
		// The iterable is the header; `check_foreach_block` clears this for the body.
		outer_header := k.loop_header
		k.loop_header = true
		flow := check_runtime_foreach(k, s)
		k.loop_header = outer_header
		return flow
	}
	unsupported_construct(k, stmt_span(stmt))
	return FLOWS
}

any_static_binding :: proc(bindings: []Foreach_Binding) -> bool {
	for binding in bindings {
		if binding.is_static || any_static_binding(binding.group) {
			return true
		}
	}
	return false
}

// A procedure-scope `when` introduces no scope: the selected branch behaves as
// if written in its place.
@(private = "file")
check_when_stmt :: proc(k: ^Checker, s: ^Stmt_When) -> Flow_Info {
	if s.resolved {
		return FLOWS // already selected and checked
	}
	s.resolved = true
	value, ok := check_when_condition(k, s.cond)
	if !ok {
		return FLOWS
	}
	if value {
		s.selected = s.then
		return s.then == nil ? FLOWS : check_stmt_sequence(k, s.then.stmts)
	}
	#partial switch otherwise in s.otherwise {
	case ^Stmt_When:
		flow := check_when_stmt(k, otherwise)
		s.selected = otherwise.selected
		return flow
	case ^Block:
		s.selected = otherwise
		return check_stmt_sequence(k, otherwise.stmts)
	}
	return FLOWS
}

// design.md "Statements": a call, an `or_return`, or an `or_else` whose
// fallback leaves or never returns; anything else computes a value and drops it.
@(private = "file")
expression_statement_has_effect :: proc(c: ^Compiler, e: Expr) -> bool {
	#partial switch v in e {
	case ^Expr_Call:
		return true
	case ^Expr_Postfix:
		return v.op == .Or_Return
	case ^Expr_Or_Else:
		// Asked of a checked expression: whether a fallback call returns is
		// its resolution's to say.
		return v.exit != nil || call_diverges(c, v.fallback)
	}
	return false
}

// `panic`, or a call to a procedure declared `-> !` (design.md "Diverging
// procedures"). A call through a procedure value never diverges.
call_diverges :: proc(c: ^Compiler, e: Expr) -> bool {
	call, is_call := e.(^Expr_Call)
	if !is_call {
		return false
	}
	// design.md "Union argument expansion": an expansion is the switch it
	// stands for, which never returns when no selected call does.
	if call.dispatch != nil {
		for entry in call.dispatch.cases {
			if !call_diverges(c, entry.arm) {
				return false
			}
		}
		return len(call.dispatch.cases) > 0
	}
	symbol := symbol_of(c, call.resolution.symbol)
	if symbol == nil {
		return false
	}
	if symbol.kind == .Builtin {
		return symbol.builtin == .Panic || symbol.builtin == .Allocation_Failed
	}
	return symbol.kind == .Proc && symbol.diverges
}

// design.md "Diverging procedures": whether evaluating `e` certainly reaches a
// call that never returns. Only what is always evaluated counts: the left of
// `&&` and `||`, the value of `or_else`, and a conditional's condition, but none
// of what they may skip, and nothing of a folded constant.
expr_diverges :: proc(c: ^Compiler, e: Expr) -> bool {
	base := expr_base(e)
	if base == nil || base_is_const(base) {
		return false
	}
	if call_diverges(c, e) {
		return true
	}
	#partial switch v in e {
	case ^Expr_Binary:
		if v.op == .And_And || v.op == .Or_Or {
			return expr_diverges(c, v.lhs)
		}
	case ^Expr_Or_Else:
		return expr_diverges(c, v.value)
	case ^Expr_Cond:
		return expr_diverges(c, v.cond)
	case ^Expr_Postfix:
		// An `or_return` failure value is evaluated only on failure.
		return expr_diverges(c, v.operand)
	}
	return expr_children(e, c, proc(data: rawptr, child: Expr) -> bool {
		return expr_diverges((^Compiler)(data), child)
	})
}

// A statement that evaluates `exprs`, all of them, and then finishes unless one
// diverges.
@(private = "file")
flow_past :: proc(c: ^Compiler, exprs: ..[]Expr) -> Flow_Info {
	for group in exprs {
		for e in group {
			if expr_diverges(c, e) {
				return Flow_Info{}
			}
		}
	}
	return FLOWS
}

// An assignment, or the block its lowering checked in its place.
@(private = "file")
assign_flow :: proc(c: ^Compiler, s: ^Stmt_Assign) -> Flow_Info {
	if s.lowered == nil {
		return flow_past(c, s.lhs, s.rhs)
	}
	flow := FLOWS
	for stmt in s.lowered.stmts {
		#partial switch v in stmt {
		case ^Decl:
			flow_then(&flow, flow_past(c, v.values))
		case ^Stmt_Assign:
			flow_then(&flow, assign_flow(c, v))
		}
	}
	return flow
}

is_builtin_call :: proc(c: ^Compiler, e: Expr, kind: Builtin_Kind) -> bool {
	call, is_call := e.(^Expr_Call)
	if !is_call {
		return false
	}
	symbol := symbol_of(c, call.resolution.symbol)
	return symbol != nil && symbol.kind == .Builtin && symbol.builtin == kind
}

// design.md "Assignment statements": every right side is evaluated, then every
// destination address, then the writes happen. The checker records the pieces;
// the backend preserves the order.
@(private = "file")
check_assign :: proc(k: ^Checker, s: ^Stmt_Assign) {
	if s.op != .Assign {
		check_compound_assign(k, s)
		return
	}

	// `a, b = record`: one record value filling several destinations.
	if len(s.rhs) == 1 && len(s.lhs) > 1 {
		if lower_destructuring_setter_assign(k, s) {
			return
		}
		check_expr(k, s.rhs[0])
		if check_assign_destructure(k, s) {
			reject_replaced_destinations(k, s)
			return
		}
	}
	if len(s.lhs) != len(s.rhs) {
		errorf(
			k.c,
			s.span,
			"L0360",
			"%d destination%s but %d value%s",
			len(s.lhs),
			len(s.lhs) == 1 ? "" : "s",
			len(s.rhs),
			len(s.rhs) == 1 ? "" : "s",
		)
		if len(s.rhs) == 1 && len(s.lhs) > 1 {
			note_optional_replacement(k, s.rhs[0])
		}
		return
	}
	if lower_setter_assign(k, s) {
		return
	}
	for target, index in s.lhs {
		// A discard destination constrains nothing; its value is still evaluated
		// for whatever it does on the way.
		if is_discard(target) {
			ident := target.(^Expr_Ident)
			ident.type = check_single_expr(k, s.rhs[index])
			ident.immutable = .Discard
			if type_is_untyped(k.c, ident.type) {
				// An untyped value takes its default type, as in `x := value`, so
				// `_ = nil` is an error as `x := nil` is.
				final := inferred_type(k, s.rhs[index], ident.type)
				if final == INVALID_TYPE {
					ident.type = INVALID_TYPE
					continue
				}
				materialize(k, s.rhs[index], final)
				ident.type = expr_base(s.rhs[index]).type
			}
			continue
		}
		// `grid[x, y] = v` on a container with no location to hand out.
		if indexed, is_index := target.(^Expr_Index); is_index {
			if check_place_setter(k, s, index, indexed) {
				continue
			}
		}
		type := check_assign_target(k, target, INVALID_TYPE)
		if type == INVALID_TYPE {
			check_expr(k, s.rhs[index])
			continue
		}
		check_value_expr(k, s.rhs[index], type, "assign")
	}
	reject_replaced_destinations(k, s)
}

// `a, b = record`, once the value is checked; false when it is no record.
@(private = "file")
check_assign_destructure :: proc(k: ^Checker, s: ^Stmt_Assign) -> bool {
	if !type_is_destructurable(k.c, expr_base(s.rhs[0]).type) {
		return false
	}
	retained := make([]bool, len(s.lhs), k.c.semantic_allocator)
	for target, index in s.lhs {
		retained[index] = !is_discard(target)
	}
	plan, ok := destructure_plan(k, s.rhs[0], retained, "L0360", "bound by a destructuring assignment")
	if !ok {
		return true
	}
	s.destructure = plan
	for target, index in s.lhs {
		field := symbol_of(k.c, plan.fields[index])
		if field == nil {
			return true
		}
		type := check_assign_target(k, target, field.type)
		if type != INVALID_TYPE {
			reject_destructured_conversion(k, field.type, type, target)
		}
	}
	return true
}

@(private = "file")
reject_destructured_conversion :: proc(k: ^Checker, field, destination: Type_Id, target: Expr) {
	if destructure_cannot_convert(k.c, field, destination) {
		errorf(
			k.c, expr_span(target), "L0310",
			"a destructured field of type `%s` cannot be assigned to `%s`",
			type_name(k.c, field), type_name(k.c, destination),
		)
		add_notef(k.c, expr_span(target), "assign the field by name to view or splat it")
	}
}

// design.md "Indexing and slicing": `operator([]=)` is for containers that
// have no location to hand out. It is reached only when no `operator([])`
// returning `inout` exists, so a type that can supply an address still gets an
// ordinary store.
@(private = "file")
check_place_setter :: proc(k: ^Checker, s: ^Stmt_Assign, index: int, target: ^Expr_Index) -> bool {
	setters := place_setters(k, target)
	if setters == nil {
		return false
	}
	if s.setters == nil {
		s.setters = make([]Place_Setter, len(s.lhs), k.c.semantic_allocator)
	}
	chosen := &s.setters[index]
	chosen.symbol, chosen.bound = resolve_place_setter(k, s.op_span, target, s.rhs[index], setters)
	return true
}

// The `operator([]=)` that `target = value` calls, with its arguments bound, or
// INVALID_SYMBOL once reported.
@(private = "file")
resolve_place_setter :: proc(
	k: ^Checker, op_span: Span, target: ^Expr_Index, value: Expr, setters: []Symbol_Id,
) -> (Symbol_Id, []Expr) {
	if check_single_expr(k, target.operand, position = .Place) == INVALID_TYPE {
		return INVALID_SYMBOL, nil
	}
	// The value is the last of what follows the receiver.
	written := make([]Expr, len(target.indices) + 1, context.temp_allocator)
	copy(written, target.indices)
	written[len(target.indices)] = value
	args, ok := index_arguments(k, target.operand, written, setters)
	if !ok {
		return INVALID_SYMBOL, nil
	}
	return resolve_operator(k, op_span, "[]=", setters, args)
}

// The type `target = value` holds its value at: the selected setter's value
// parameter, or the destination's own type. Asked of copies under a probe;
// INVALID_TYPE when the assignment does not check, which its own check reports.
@(private = "file")
assigned_value_type :: proc(k: ^Checker, op_span: Span, target, value: Expr) -> Type_Id {
	probe := begin_probe(k.c)
	defer end_probe(k.c, probe)
	destination := clone_expr(k.c, target)
	indexed, is_index := destination.(^Expr_Index)
	setters := is_index ? place_setters(k, indexed) : nil
	if setters == nil {
		return check_assign_target(k, destination, INVALID_TYPE)
	}
	chosen, _ := resolve_place_setter(k, op_span, indexed, clone_expr(k.c, value), setters)
	sym := symbol_of(k.c, chosen)
	return sym != nil && len(sym.params) > 0 ? sym.params[len(sym.params) - 1] : INVALID_TYPE
}

// design.md "Indexing and slicing": with no location to hand out, `box[i] += v`
// reads through `operator([])` and writes back through `operator([]=)`. It is
// checked as the block
//
//     { r := &mut box; i0 := i; v0 := v; r^[i0] = r^[i0] + v0; }
//
// so the receiver and indices are evaluated once, then the right operand
// (design.md "Evaluation order"). A temporary is left out where evaluating the
// expression twice is the same: a variable or field path receiver, a literal,
// implicit selector, or constant, and a name other than a scalar variable's
// that the right operand does not name.
@(private = "file")
lower_compound_setter :: proc(k: ^Checker, s: ^Stmt_Assign, target: ^Expr_Index) -> bool {
	op := compound_operator(s.op)
	if op == .EOF || place_setters(k, target) == nil {
		return false
	}
	span := s.span
	stmts := make([dynamic]Stmt, 0, len(target.indices) + 3, k.c.semantic_allocator)
	// A constant right operand keeps its unfixed type for the operator to settle.
	constant := lowered_constant(k, s.rhs[0])
	changing := Changed_Names{}
	if !constant && !lowered_pure(s.rhs[0]) {
		changing.within = s.rhs[0]
	}
	receiver, index_names := bind_index_place(k, &stmts, target, "compound$", span, changing)
	value := clone_expr(k.c, s.rhs[0])
	if !constant && needs_temporary(k, s.rhs[0]) {
		append(&stmts, synth_decl(k.c, .Var, "compound$value", value, span))
		value = synth_ident(k.c, "compound$value", span)
	}

	read := lowered_index(k, target, index_names, receiver, span)
	combined := new(Expr_Binary, k.c.semantic_allocator)
	combined.span = span
	combined.op = op
	combined.op_span = s.op_span
	combined.lhs = read
	combined.rhs = value
	append(&stmts, synth_assign(k.c, {lowered_index(k, target, index_names, receiver, span)}, {combined}, s.op_span, span))
	check_lowered_block(k, s, stmts[:], new_scope(k.c, k.scope, .Local))
	return true
}

// design.md "Temporaries and procedure boundaries": `x op= y` on a whole local
// variable whose binary fallback produces a value `x` views, as a `string` for
// a `string_view`, is the assignment `x = x op y` to that local, so the result
// is extended to the end of its block. It is checked as that assignment, run
// in the scope that holds it (`lowered_inline`), so `y` is borrowed, dropped,
// and kept alive as written, and its `+` evaluates `y` before it reads `x`
// (`right_first`; design.md "Evaluation order").
@(private = "file")
lower_compound_view :: proc(k: ^Checker, s: ^Stmt_Assign) -> bool {
	op := compound_operator(s.op)
	if _, is_ident := s.lhs[0].(^Expr_Ident); !is_ident || op == .EOF {
		return false
	}
	probe := begin_probe(k.c)
	trial := synth_assign(k.c, {clone_expr(k.c, s.lhs[0])}, {clone_expr(k.c, s.rhs[0])}, s.op_span, s.span)
	trial.op = s.op
	type := check_assign_target(k, trial.lhs[0], INVALID_TYPE, inserts = false)
	viewed := type != INVALID_TYPE && extends_into_local(k.c, trial.lhs[0].(^Expr_Ident).symbol) &&
		!compound_applies(k.c, op, type) && check_user_compound(k, trial, op, type) == .Viewed
	end_probe(k.c, probe)
	if !viewed {
		return false
	}
	combined := new(Expr_Binary, k.c.semantic_allocator)
	combined.span = s.span
	combined.op = op
	combined.op_span = s.op_span
	combined.lhs = clone_expr(k.c, s.lhs[0])
	combined.rhs = clone_expr(k.c, s.rhs[0])
	combined.right_first = true
	stmts := make([]Stmt, 1, k.c.semantic_allocator)
	stmts[0] = synth_assign(k.c, {clone_expr(k.c, s.lhs[0])}, {combined}, s.op_span, s.span)
	check_lowered_block(k, s, stmts, k.scope)
	s.lowered_inline = true
	return true
}

// `s` as the block that stands for it, checked in `scope`, which holds the
// names of the types the lowering wrote.
@(private = "file")
check_lowered_block :: proc(k: ^Checker, s: ^Stmt_Assign, stmts: []Stmt, scope: ^Scope) {
	s.lowered = synth_block(k.c, stmts, s.span)
	outer := k.scope
	k.scope = scope
	defer k.scope = outer
	check_stmts(k, stmts)
}

// The variables a lowered statement may write between binding a destination's
// indices and using them: the roots of `written`, the statement's destinations,
// and any variable `within` names.
@(private = "file")
Changed_Names :: struct {
	written: []Expr,
	within:  Expr,
}

// Binds an indexed destination's receiver, by address, and its indices to
// temporaries named from `prefix`, so later statements reuse them rather than
// evaluate them again. What reads the same each time stays as written, its
// name "".
@(private = "file")
bind_index_place :: proc(
	k: ^Checker, stmts: ^[dynamic]Stmt, target: ^Expr_Index, prefix: string, span: Span, changing: Changed_Names,
) -> (receiver: string, index_names: []string) {
	if !is_effect_free_place(target.operand) || reached_through_changing(target.operand, changing) {
		receiver = concat(k.c, prefix, "receiver")
		append(stmts, synth_decl(k.c, .Var, receiver, lowered_address(k, target.operand, span), span))
	}
	index_names = make([]string, len(target.indices), k.c.semantic_allocator)
	for index, position in target.indices {
		if needs_temporary(k, index, changing) {
			index_names[position] = lowered_position_name(k, concat(k.c, prefix, "index"), position, "")
			append(stmts, synth_decl(k.c, .Var, index_names[position], clone_expr(k.c, index), span))
		}
	}
	return
}

// design.md "Evaluation order": what could read differently later is bound: what
// has an effect, a name of a scalar variable, since copying one costs nothing,
// and a name of any other variable `changing` may write. Any other variable is
// read where it is used.
@(private = "file")
needs_temporary :: proc(k: ^Checker, e: Expr, changing := Changed_Names{}) -> bool {
	if !lowered_pure(e) {
		return true
	}
	ident, is_ident := e.(^Expr_Ident)
	if !is_ident {
		return false
	}
	sym := ident_symbol(k, ident)
	if sym == nil || (sym.kind != .Var && sym.kind != .Parameter) {
		return false
	}
	return type_is_panic_free_scalar(k.c, sym.type) || name_changes(ident, changing)
}

// Whether `changing` may write the variable `name` names.
@(private = "file")
name_changes :: proc(name: ^Expr_Ident, changing: Changed_Names) -> bool {
	for target in changing.written {
		if root, is_root := written_root(target).(^Expr_Ident); is_root && root.name == name.name {
			return true
		}
	}
	return changing.within != nil && type_syntax_any_name(changing.within, name, proc(data: rawptr, node: Expr) -> bool {
		named, is_name := node.(^Expr_Ident)
		return is_name && named.name == (^Expr_Ident)(data).name
	})
}

// Whether `place` is reached through a pointer held in a variable `changing`
// may write, so its address is taken before that write.
@(private = "file")
reached_through_changing :: proc(place: Expr, changing: Changed_Names) -> bool {
	#partial switch v in place {
	case ^Expr_Selector:
		return reached_through_changing(v.operand, changing)
	case ^Expr_Index:
		return reached_through_changing(v.operand, changing)
	case ^Expr_Postfix:
		if v.op != .Caret {
			return false
		}
		if root, is_root := written_root(v.operand).(^Expr_Ident); is_root && name_changes(root, changing) {
			return true
		}
		return reached_through_changing(v.operand, changing)
	}
	return false
}

// The variable a written destination stores into, or nil: its field and element
// paths lead to it, and a dereference leads elsewhere.
@(private = "file")
written_root :: proc(e: Expr) -> Expr {
	#partial switch v in e {
	case ^Expr_Ident:
		return e
	case ^Expr_Selector:
		return written_root(v.operand)
	case ^Expr_Index:
		return written_root(v.operand)
	}
	return nil
}

// design.md "Evaluation order": an assignment with an `operator([]=)`
// destination is checked as the block
//
//     { v0: T0 = a; v1: T1 = b; r0^[i0], x = v0, v1; }
//
// so every value is evaluated first, at the type its destination gives it. The
// last statement, `prepared`, then prepares each destination from left to
// right, as an ordinary assignment does, a setter's by its `preparations`,
// `r0 := &mut grid; i0 := i;`, which bind what its call would otherwise read
// when it writes. Then it writes from left to right, calling each setter in its
// turn. A setter's receiver is bound by address unless it is an effect-free
// place no other destination's pointer leads it through, and a literal value is
// written where it is used. A lone setter destination is checked as written, as
// its call, unless both its value and its indices have effects to order.
@(private = "file")
lower_setter_assign :: proc(k: ^Checker, s: ^Stmt_Assign) -> bool {
	if s.prepared || !any_place_setter(k, s.lhs) {
		return false
	}
	if len(s.lhs) == 1 && !setter_order_matters(k, s.lhs[0].(^Expr_Index), s.rhs[0]) {
		return false
	}
	span := s.span
	scope := new_scope(k.c, k.scope, .Local)
	stmts := make([dynamic]Stmt, 0, 3 * len(s.lhs), k.c.semantic_allocator)
	values := make([]Expr, len(s.rhs), context.temp_allocator)
	for value, position in s.rhs {
		target := s.lhs[position]
		if is_discard(target) {
			append(&stmts, synth_assign(k.c, {clone_expr(k.c, target)}, {clone_expr(k.c, value)}, s.op_span, span))
			continue
		}
		if lowered_literal(value) {
			values[position] = clone_expr(k.c, value)
			continue
		}
		// The destination gives the value its context, as it does written in
		// place (design.md "Assignment statements").
		name := lowered_position_name(k, "assign$value", position, "")
		declared: Expr
		if type := assigned_value_type(k, s.op_span, target, value); type != INVALID_TYPE {
			declared = synth_type_name(k.c, scope, name, concat(k.c, name, "$type"), type, span)
		}
		append(&stmts, synth_decl(k.c, .Var, name, clone_expr(k.c, value), span, declared))
		values[position] = synth_ident(k.c, name, span)
	}
	changing := Changed_Names{written = s.lhs}
	destinations := make([dynamic]Expr, 0, len(s.lhs), context.temp_allocator)
	written := make([dynamic]Expr, 0, len(s.lhs), context.temp_allocator)
	preparations := make([][]Stmt, len(s.lhs), k.c.semantic_allocator)
	evaluated := len(stmts)
	for target, position in s.lhs {
		if is_discard(target) {
			continue
		}
		append(&written, values[position])
		indexed, is_index := target.(^Expr_Index)
		if !is_index || place_setters(k, indexed) == nil {
			append(&destinations, clone_expr(k.c, target))
			continue
		}
		// Checked here, before the last statement names what they bind, and
		// run by it.
		bound := make([dynamic]Stmt, 0, len(indexed.indices) + 1, k.c.semantic_allocator)
		receiver, index_names := bind_index_place(k, &bound, indexed, lowered_position_name(k, "assign$", position, "$"), span, changing)
		append(&destinations, lowered_index(k, indexed, index_names, receiver, span))
		preparations[len(destinations) - 1] = bound[:]
		append(&stmts, ..bound[:])
	}
	writes := synth_assign(k.c, destinations[:], written[:], s.op_span, span)
	writes.prepared = true
	writes.preparations = preparations[:len(destinations)]
	append(&stmts, writes)
	check_lowered_block(k, s, stmts[:], scope)
	kept := make([]Stmt, evaluated + 1, k.c.semantic_allocator)
	copy(kept, stmts[:evaluated])
	kept[evaluated] = writes
	s.lowered.stmts = kept
	return true
}

// Whether `target = value` must hold its value before preparing the
// destination: the value has an effect, or reads a scalar variable, and so does
// the receiver or an index.
@(private = "file")
setter_order_matters :: proc(k: ^Checker, target: ^Expr_Index, value: Expr) -> bool {
	if !needs_temporary(k, value) {
		return false
	}
	if !is_effect_free_place(target.operand) {
		return true
	}
	for index in target.indices {
		if !lowered_pure(index) {
			return true
		}
	}
	return false
}

// design.md "Destructuring": a record filling destinations, one of them an
// `operator([]=)`, is checked as the block
//
//     { f0, f1 := record; grid[i], x = f0, f1; }
//
// so its fields are taken once, and the assignment orders the rest. A record
// that fills none of this reports as any other destructure does.
@(private = "file")
lower_destructuring_setter_assign :: proc(k: ^Checker, s: ^Stmt_Assign) -> bool {
	if !any_place_setter(k, s.lhs) {
		return false
	}
	probe := begin_probe(k.c)
	record := check_single_expr(k, clone_expr(k.c, s.rhs[0]))
	fields: []Symbol_Id
	fills := type_is_destructurable(k.c, record)
	if fills {
		fields, fills = destructure_fields(k, record, len(s.lhs), expr_span(s.rhs[0]), "L0360", "bound by a destructuring assignment")
	}
	end_probe(k.c, probe)
	if !fills {
		return false
	}
	span := s.span
	take := new(Decl, k.c.semantic_allocator)
	take.span = span
	take.kind = .Var
	take.names = make([]Name, len(s.lhs), k.c.semantic_allocator)
	take.values = make([]Expr, 1, k.c.semantic_allocator)
	take.values[0] = clone_expr(k.c, s.rhs[0])
	destinations := make([dynamic]Expr, 0, len(s.lhs), context.temp_allocator)
	values := make([dynamic]Expr, 0, len(s.lhs), context.temp_allocator)
	for target, position in s.lhs {
		if is_discard(target) {
			take.names[position] = Name{text = "_", span = span}
			continue
		}
		reject_destructured_setter_target(k, target, fields[position])
		name := lowered_position_name(k, "assign$field", position, "")
		take.names[position] = synth_name(k.c, name, span)
		append(&destinations, clone_expr(k.c, target))
		append(&values, synth_ident(k.c, name, span))
	}
	stmts := make([]Stmt, 2, k.c.semantic_allocator)
	stmts[0], stmts[1] = take, synth_assign(k.c, destinations[:], values[:], s.op_span, span)
	check_lowered_block(k, s, stmts, new_scope(k.c, k.scope, .Local))
	return true
}

// A destination other than a setter takes a whole field, as `check_assign_destructure`
// has it. The lowered assignment sees a variable, which would convert.
@(private = "file")
reject_destructured_setter_target :: proc(k: ^Checker, target: Expr, field_id: Symbol_Id) {
	if indexed, is_index := target.(^Expr_Index); is_index && place_setters(k, indexed) != nil {
		return
	}
	field := symbol_of(k.c, field_id).type
	probe := begin_probe(k.c)
	destination := check_assign_target(k, clone_expr(k.c, target), INVALID_TYPE)
	end_probe(k.c, probe)
	if destination != INVALID_TYPE {
		reject_destructured_conversion(k, field, destination, target)
	}
}

// Whether a value has no effect to order and may keep its unfixed type for its
// destination to settle: a constant, however spelled, or an implicit selector,
// which has no type until then.
@(private = "file")
lowered_constant :: proc(k: ^Checker, e: Expr) -> bool {
	#partial switch v in e {
	case ^Expr_Unary:
		if (v.op == .Minus || v.op == .Plus || v.op == .Tilde || v.op == .Not) && lowered_constant(k, v.operand) {
			return true
		}
	case ^Expr_Binary:
		if lowered_constant(k, v.lhs) && lowered_constant(k, v.rhs) {
			return true
		}
	}
	if is_implicit_selector(e) {
		return true
	}
	probe := begin_probe(k.c)
	defer end_probe(k.c, probe)
	copy := clone_expr(k.c, e)
	return check_single_expr(k, copy) != INVALID_TYPE && is_const_expr(copy)
}

@(private = "file")
lowered_position_name :: proc(k: ^Checker, prefix: string, position: int, suffix: string) -> string {
	digits: [20]u8
	return concat(k.c, prefix, strconv.write_int(digits[:], i64(position), 10), suffix)
}

// `&mut place`.
@(private = "file")
lowered_address :: proc(k: ^Checker, place: Expr, span: Span) -> Expr {
	return synth_address(k.c, clone_expr(k.c, place), true, span)
}

// A literal or an implicit selector: it reads the same wherever it is written,
// and its destination settles its type.
@(private = "file")
lowered_literal :: proc(e: Expr) -> bool {
	_, is_literal := e.(^Expr_Literal)
	return is_literal || is_implicit_selector(e)
}

@(private = "file")
lowered_pure :: proc(e: Expr) -> bool {
	#partial switch _ in e {
	case ^Expr_Literal, ^Expr_Ident:
		return true
	}
	return is_implicit_selector(e)
}

// `r^[i0]`, or the written receiver and indices where they were not bound; a
// receiver bound to an address is named by `receiver`.
@(private = "file")
lowered_index :: proc(k: ^Checker, target: ^Expr_Index, index_names: []string, receiver: string, span: Span) -> Expr {
	out := new(Expr_Index, k.c.semantic_allocator)
	out.span = target.span
	if receiver != "" {
		out.operand = synth_deref(k.c, synth_ident(k.c, receiver, span), span)
	} else {
		out.operand = clone_expr(k.c, target.operand)
	}
	out.indices = make([]Expr, len(target.indices), k.c.semantic_allocator)
	for index, position in target.indices {
		if index_names[position] == "" {
			out.indices[position] = clone_expr(k.c, index)
		} else {
			out.indices[position] = synth_ident(k.c, index_names[position], span)
		}
	}
	return out
}

// The `operator([]=)` overloads a store to `target` calls, or nil for an ordinary
// store: design.md "Operator lookup and overload resolution" lets none shadow
// built-in indexing, and an `operator([])` returning a location is preferred.
// Asked of a copy under a probe, so that the check that commits, of whichever
// form the store takes, is the receiver's only one.
@(private = "file")
place_setters :: proc(k: ^Checker, target: ^Expr_Index) -> []Symbol_Id {
	probe := begin_probe(k.c)
	defer end_probe(k.c, probe)
	operand := check_single_expr(k, clone_expr(k.c, target.operand), position = .Place)
	if operand == INVALID_TYPE || index_is_builtin(k.c, operand, len(target.indices)) {
		return nil
	}
	setters := operator_candidates_for_receiver(k, "[]=", operand)
	if len(setters) == 0 {
		return nil
	}
	for candidate in operator_candidates_for_receiver(k, "[]", operand) {
		if operator_result_is_place(k, candidate) {
			return nil
		}
	}
	return setters
}

@(private = "file")
any_place_setter :: proc(k: ^Checker, targets: []Expr) -> bool {
	for target in targets {
		if indexed, is_index := target.(^Expr_Index); is_index && place_setters(k, indexed) != nil {
			return true
		}
	}
	return false
}

@(private = "file")
check_compound_assign :: proc(k: ^Checker, s: ^Stmt_Assign) {
	if len(s.lhs) != 1 || len(s.rhs) != 1 {
		errorf(k.c, s.op_span, "L0360", "a compound assignment takes one destination and one value")
		return
	}
	if indexed, is_index := s.lhs[0].(^Expr_Index); is_index && lower_compound_setter(k, s, indexed) {
		return
	}
	if lower_compound_view(k, s) {
		return
	}
	// design.md "Maps": `m[key] += 1` reads and writes one element, so the entry
	// must already be there; only `m[key] = elem` creates one.
	type := check_assign_target(k, s.lhs[0], INVALID_TYPE, inserts = false)
	if type == INVALID_TYPE {
		check_expr(k, s.rhs[0])
		return
	}
	op := compound_operator(s.op)
	if op == .EOF {
		unsupported_construct(k, s.op_span)
		return
	}
	// The built-in compound operation wins where it is defined; otherwise a
	// direct `+=` overload, and failing that the binary `+` fallback.
	if !compound_applies(k.c, op, type) {
		if check_user_compound(k, s, op, type) == .Absent {
			errorf(k.c, s.op_span, "L0318", "`%s` does not apply to `%s`", operator_text(op), type_name(k.c, type))
		}
		return
	}
	// Whether a SIMD operation is built in depends on the right operand, so it is
	// checked first.
	if type_is_simd(k.c, type) {
		hint := argument_needs_context(s.rhs[0]) ? type : INVALID_TYPE
		rhs_type := check_single_expr(k, s.rhs[0], hint)
		if rhs_type == INVALID_TYPE {
			return
		}
		if !simd_operand_is_builtin(k.c, type, rhs_type) && check_user_compound(k, s, op, type, rhs_type) != .Absent {
			return
		}
		if materialize_value_expr(k, s.rhs[0], type, "assign") {
			reject_negative_count_lanes(k, op, s.rhs[0])
			constant_zero_divisor(k, op, s.op_span, s.rhs[0])
		}
		return
	}
	if op == .Shl || op == .Shr {
		if !check_shift_count(k, s.rhs[0]) {
			return
		}
	} else if !check_value_expr(k, s.rhs[0], type, "assign") {
		return
	}
	constant_zero_divisor(k, op, s.op_span, s.rhs[0])
}

// What `check_user_compound` found: no user operator, one it checked, or a
// binary fallback whose result the destination would view.
@(private = "file")
User_Compound :: enum u8 {
	Absent,
	Checked,
	Viewed,
}

// A direct compound overload, or the binary operator plus an assignment.
@(private = "file")
check_user_compound :: proc(
	k: ^Checker, s: ^Stmt_Assign, op: Token_Kind, type: Type_Id,
	prechecked_rhs: Type_Id = INVALID_TYPE,
) -> User_Compound {
	rhs_type := prechecked_rhs
	if rhs_type == INVALID_TYPE {
		rhs_type = check_single_expr(k, s.rhs[0])
		if rhs_type == INVALID_TYPE {
			return .Checked // already reported; re-checking it would report a second time
		}
	}
	operands := []Type_Id{type, rhs_type}

	compound := operator_spelling(s.op)
	direct_args := make([]Arg_Info, 2, context.temp_allocator)
	direct_args[0] = arg_from_expr(s.lhs[0], .Inout)
	direct_args[1] = arg_from_expr(s.rhs[0])
	direct := form_operator_set(k, compound, operands, direct_args, s.op_span)
	if candidates_viable(direct.formed) {
		chosen, bound := resolve_operator_set(k, s.op_span, direct, direct_args)
		if chosen == INVALID_SYMBOL {
			return .Checked
		}
		s.lhs[0], s.rhs[0] = bound[0], bound[1]
		s.operator, s.operator_direct = chosen, true
		return .Checked
	}

	binary := operator_text(op)
	args := make([]Arg_Info, 2, context.temp_allocator)
	args[0] = arg_from_expr(s.lhs[0])
	args[1] = arg_from_expr(s.rhs[0])
	set := form_operator_set(k, binary, operands, args, s.op_span)
	if !candidates_viable(set.formed) {
		if operator_exists(k, direct.members, operands) {
			resolve_operator_set(k, s.op_span, direct, direct_args)
			return .Checked
		}
		if operator_exists(k, set.members, operands) {
			resolve_operator_set(k, s.op_span, set, args)
			return .Checked
		}
		return .Absent
	}
	chosen, bound := resolve_operator_set(k, s.op_span, set, args)
	if chosen == INVALID_SYMBOL {
		return .Checked
	}
	result := symbol_of(k.c, chosen)
	if result.result == INVALID_TYPE || !assignable(k.c, result.result, type) {
		errorf(
			k.c,
			s.op_span,
			"L0417",
			"`%s` produces `%s`, which cannot be assigned back to `%s`",
			binary,
			result.result == INVALID_TYPE ? "no value" : type_name(k.c, result.result),
			type_name(k.c, type),
		)
		return .Checked
	}
	// The result is converted as a value (`compound_result_as`); a view or a
	// `dyn proc` would borrow the operator's temporary, which only the written
	// assignment to a whole local keeps alive (`lower_compound_view`).
	erases := dyn_proc_signature(k.c, type) != INVALID_TYPE && !type_is_dyn(k.c, result.result)
	if erases || type_views_as(k.c, result.result, type) {
		errorf(
			k.c, s.op_span, "L0417",
			"`%s` produces `%s`, which a compound assignment cannot borrow as `%s`",
			binary, type_name(k.c, result.result), type_name(k.c, type),
		)
		add_notef(k.c, NO_SPAN, "only a whole local variable keeps the result it views alive")
		return .Viewed
	}
	s.lhs[0], s.rhs[0] = bound[0], bound[1]
	s.operator, s.operator_direct = chosen, false
	return .Checked
}

// design.md "Destructuring": a destination takes a whole field, cloned or
// transferred, so it cannot be a view of that field or a splat of it.
@(private = "file")
destructure_cannot_convert :: proc(c: ^Compiler, from, to: Type_Id) -> bool {
	if from == to {
		return false
	}
	return type_views_as(c, from, to) || dyn_proc_signature(c, to) != INVALID_TYPE || (type_is_simd(c, to) && !type_is_simd(c, from))
}

// The destination half of an assignment. A `_` on the left is a discard, which
// is a legal destination with no storage.
@(private = "file")
check_assign_target :: proc(k: ^Checker, target: Expr, from: Type_Id, inserts := true) -> Type_Id {
	if is_discard(target) {
		ident := target.(^Expr_Ident)
		ident.type = from
		ident.immutable = .Discard
		ident.value_category = .Invalid
		return from == INVALID_TYPE ? TYPE_VOID : from
	}
	type := check_single_expr(k, target, position = inserts ? .Insert : .Place)
	if type == INVALID_TYPE {
		return INVALID_TYPE
	}
	base := expr_base(target)
	if !base.assignable {
		report_not_assignable(k, base, "an assignment destination")
		return INVALID_TYPE
	}
	if from != INVALID_TYPE && !assignable(k.c, from, type) {
		errorf(
			k.c,
			expr_span(target),
			"L0310",
			"cannot assign `%s` with `%s`",
			type_name(k.c, type),
			type_name(k.c, from),
		)
		return INVALID_TYPE
	}
	if from != INVALID_TYPE { record_proc_contract_check(k.c, from, type, expr_span(target)) }
	return type
}

report_not_assignable :: proc(k: ^Checker, base: ^Expr_Base, what: string) {
	switch base.immutable {
	case .Constant:
		errorf(k.c, base.span, "L0358", "a constant cannot be %s", what)
	case .Value_Parameter:
		errorf(k.c, base.span, "L0358", "a value parameter is immutable and cannot be %s", what)
	case .Loop_Binding:
		errorf(
			k.c, base.span, "L0358",
			"a `foreach` binding names the element read-only and cannot be %s; bind it with `&mut` for mutable traversal",
			what,
		)
	case .Payload_Binding:
		errorf(
			k.c, base.span, "L0358",
			"a case binding names storage the subject still owns and cannot be %s; bind it with `&mut` for a mutable payload",
			what,
		)
	case .Read_Only_Name:
		errorf(k.c, base.span, "L0358", "this name is read-only and cannot be %s", what)
	case .Captured_Copy:
		errorf(
			k.c, base.span, "L0358",
			"this capture is the literal's own copy and cannot be %s; capture the local with `&mut` to write it, or write the record and a `self: inout` `call` by hand",
			what,
		)
	case .Temporary:
		errorf(k.c, base.span, "L0359", "a temporary value cannot be %s", what)
	case .Discard:
		errorf(k.c, base.span, "L0359", "`_` cannot be %s", what)
	case .Read_Only:
		errorf(k.c, base.span, "L0478", "this is read-only storage and cannot be %s", what)
	case .Through_Slice:
		errorf(
			k.c, base.span, "L0478",
			"this is an element of a read-only `[]T` and cannot be %s; writing through a slice takes a `[]mut T`, which `a[mut lo:hi]` makes",
			what,
		)
	case .Through_Pointer:
		errorf(
			k.c, base.span, "L0640",
			"this place is reached through a read-only `^T` and cannot be %s; borrow it with `&mut` for a `^mut T`",
			what,
		)
	case .None, .Not_A_Place:
		errorf(k.c, base.span, "L0359", "this expression cannot be %s", what)
	}
}

// The scope of a statement's header, which spans the rest of the statement, and
// its init statement checked. design.md "@(require_results)": a header binding's
// scope ends with the statement.
@(deferred_in_out = leave_statement_header)
enter_statement_header :: proc(k: ^Checker, init: Stmt) -> (outer: ^Scope) {
	outer = k.scope
	k.scope = new_scope(k.c, outer, .Local)
	if init != nil {
		check_stmt(k, init)
	}
	return outer
}

@(private = "file")
leave_statement_header :: proc(k: ^Checker, init: Stmt, outer: ^Scope) {
	if init != nil {
		report_unread_required_results(k, []Stmt{init})
	}
	k.scope = outer
}

// The init statement's scope spans the condition and both branches.
@(private = "file")
check_if :: proc(k: ^Checker, s: ^Stmt_If) -> Flow_Info {
	enter_statement_header(k, s.init)
	check_condition(k, s.cond)

	then_flow := check_scoped_block(k, s.then)
	if s.otherwise == nil {
		then_flow.can_fall_through = true
		return then_flow
	}
	flow_either(&then_flow, check_stmt(k, s.otherwise))
	return then_flow
}

// A statement's or a conditional expression's condition, which must be `bool`.
// A constant that is not one is reported once, by `materialize`. False only when
// the condition has no type at all; a missing `for` condition is none to check.
check_condition :: proc(k: ^Checker, cond: Expr) -> bool {
	if cond == nil {
		return true
	}
	type := check_single_expr(k, cond, TYPE_BOOL)
	if type == INVALID_TYPE {
		return false
	}
	if materialize(k, cond, TYPE_BOOL) && !type_is_boolean(k.c, expr_base(cond).type) {
		errorf(k.c, expr_span(cond), "L0355", "a condition must be `bool`, found `%s`", type_name(k.c, type))
	}
	return true
}

@(private = "file")
check_for :: proc(k: ^Checker, s: ^Stmt_For) -> Flow_Info {
	outer_header, outer_broken := k.loop_header, k.loop_broken
	defer k.loop_header, k.loop_broken = outer_header, outer_broken
	k.loop_header = true
	enter_statement_header(k, s.init)
	check_condition(k, s.cond)

	k.loop_depth += 1
	k.loop_header, k.loop_broken = false, false
	body := check_scoped_block(k, s.body)
	broken := k.loop_broken
	k.loop_header = true
	if s.post != nil {
		check_stmt(k, s.post)
	}
	k.loop_depth -= 1
	// `for (;;)` without a `break` never falls out of the loop; an `or_else`
	// exit in its body is one (design.md "or_else expression").
	infinite := s.cond == nil
	return Flow_Info{can_fall_through = !infinite || body.breaks || broken}
}

// design.md "defer statement": deferred code runs on the way out of its own
// scope, so it may not itself leave that scope.
@(private = "file")
check_defer :: proc(k: ^Checker, s: ^Stmt_Defer) -> Flow_Info {
	if k.in_defer {
		errorf(k.c, s.span, "L0369", "a deferred statement cannot contain another `%s`", s.on_failure ? "errdefer" : "defer")
		return FLOWS
	}
	// design.md "defer statement": `errdefer` runs on a failure exit, so the
	// procedure's result must have one.
	// A written result that did not resolve was already reported.
	written := k.proc_literal.signature.result
	unresolved := k.result_type == INVALID_TYPE && written != nil && !written.diverges
	if s.on_failure && !unresolved {
		if _, fallible := fallible_of(k.c, k.result_type); !fallible || k.result_inout {
			if k.result_type == INVALID_TYPE {
				errorf(k.c, s.span, "L0720", "`errdefer` needs a result with a failure variant; this procedure returns nothing")
			} else {
				errorf(
					k.c, s.span, "L0720",
					"`errdefer` needs a result with a failure variant, found `%s%s`",
					k.result_inout ? "inout " : "", type_name(k.c, k.result_type),
				)
			}
		}
	}
	s.slot = k.defer_slots
	k.defer_slots += 1
	k.in_defer = true
	k.defer_loop_depth = k.loop_depth
	check_stmt(k, s.stmt)
	k.in_defer = false
	return FLOWS
}

// design.md "defer statement": a `break` or `continue` in deferred code may
// only leave a loop that is itself inside the deferred code. Reported even
// where nothing reaches it.
branch_leaves_defer :: proc(k: ^Checker) -> bool {
	return k.in_defer && k.loop_depth <= k.defer_loop_depth
}

@(private = "file")
check_return :: proc(k: ^Checker, s: ^Stmt_Return) -> Flow_Info {
	terminated := Flow_Info{}
	if k.in_defer {
		errorf(k.c, s.span, "L0369", "a deferred statement cannot `return`")
		return terminated
	}

	if result := k.proc_literal.signature.result; result != nil && result.diverges {
		errorf(k.c, s.span, "L0710", "this procedure is declared `-> !`, so it cannot `return`")
		return terminated
	}
	// design.md "Success returns": `return;` returns a success that carries
	// nothing or `Unit`, as reaching the end of the body does.
	if s.value == nil && k.body.bare_success {
		at := s.span
		at.lo = at.hi
		s.value = bare_success_value(k, k.result_type, at)
	}
	if s.value == nil {
		if k.result_type != INVALID_TYPE {
			report_missing_return_value(k, s.span)
		}
		return terminated
	}
	if k.result_type == INVALID_TYPE {
		// A written result that did not resolve was already reported, and so was
		// a value the parser could not read.
		if k.proc_literal.signature.result != nil || expr_has_error(s.value.expr) {
			return terminated
		}
		errorf(k.c, s.span, "L0326", "this procedure returns nothing")
		return terminated
	}

	value := s.value
	// design.md "`inout` results": the mode is decided before anything else, so a
	// value is never read where a place is returned, or the reverse.
	if value.is_inout != k.result_inout {
		if k.result_inout {
			errorf(
				k.c, value.span, "L0418",
				"this procedure returns `inout %s`, so it returns a place: `return inout place`",
				type_name(k.c, k.result_type),
			)
		} else {
			errorf(k.c, value.span, "L0418", "this procedure returns a value, so `return` takes no `inout`")
		}
		check_expr(k, value.expr)
		return terminated
	}
	if !k.result_inout {
		if check_returned_value(k, value) {
			classify_return_value(k, value, k.result_type)
		}
		return terminated
	}
	// An assignable place of exactly the result type, checked as written: no
	// conversion may turn it into a temporary. In place position, `m[key]`
	// names an existing entry and a user `operator([])` is its `inout` overload.
	if check_single_expr(k, value.expr, k.result_type, .Place) == INVALID_TYPE {
		return terminated
	}
	base := expr_base(value.expr)
	switch {
	case base == nil || !base.addressable:
		errorf(k.c, expr_span(value.expr), "L0418", "an `inout` result must return a place")
	case !base.assignable:
		report_not_assignable(k, base, "returned as `inout`")
	case base.type != k.result_type:
		errorf(
			k.c, expr_span(value.expr), "L0418",
			"an `inout` result must return a place of exactly `%s`, found `%s`",
			type_name(k.c, k.result_type), type_name(k.c, base.type),
		)
	case:
		classify_return_value(k, value, k.result_type)
	}
	return terminated
}

@(private = "file")
report_missing_return_value :: proc(k: ^Checker, span: Span) {
	errorf(
		k.c, span, "L0326",
		"this procedure returns `%s`, so `return` needs a value; a result is anonymous and has no local to fill",
		type_name(k.c, k.result_type),
	)
	shape, fallible := fallible_of(k.c, k.result_type)
	if !fallible || k.result_inout {
		return
	}
	name := union_variant_name(k.c, k.result_type, shape.success)
	if shape.success_type == k.c.unit_type {
		add_notef(
			k.c, span, "`.%s` carries `Unit` here only through a generic argument, so `return;` cannot build it; write `return .%s;`",
			name, name,
		)
	} else {
		add_notef(
			k.c, span, "only a success that carries nothing or `Unit`, as `Status(E)`'s does, returns with `return;`; write `return .%s(value);`",
			name,
		)
	}
}

@(private = "file")
check_branch :: proc(k: ^Checker, s: ^Stmt_Branch) -> Flow_Info {
	if k.loop_depth == 0 {
		if !k.branches_reported {
			errorf(k.c, s.span, "L0368", "`%s` is only valid inside a loop", s.kind == .Break ? "break" : "continue")
		}
		return FLOWS
	}
	if branch_leaves_defer(k) {
		errorf(k.c, s.span, "L0369", "a deferred statement cannot leave the construct it is registered in")
		return FLOWS
	}
	return Flow_Info{breaks = s.kind == .Break}
}

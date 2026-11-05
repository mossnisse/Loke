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
	for stmt in stmts {
		// design.md "defer statement": what a `defer` wraps directly is checked here
		// and stays visible to this sequence, whatever runs it later.
		inner := stmt
		if deferred, is_deferred := stmt.(^Stmt_Defer); is_deferred {
			inner = deferred.stmt
		}
		// design.md "when statement": the selected branch has no scope of its own.
		if w, is_when := inner.(^Stmt_When); is_when {
			if w.selected != nil {
				report_local_copy_decisions(k, w.selected.stmts)
			}
			continue
		}
		d, is_decl := inner.(^Decl)
		if !is_decl || d.kind != .Const || len(d.values) != 1 {
			continue
		}
		if _, is_record := d.values[0].(^Type_Record); !is_record {
			continue
		}
		check_copy_decision(k, d)
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
		flow_then(&flow, check_stmt(k, stmt))
	}
	return flow
}

// design.md "@(require_results)": a required result bound and never read.
// Asked after the whole sequence is checked, in source order.
report_unread_required_results :: proc(k: ^Checker, stmts: []Stmt) {
	for stmt in stmts {
		// design.md "defer statement": what a `defer` wraps directly stays visible
		// to this sequence.
		inner := stmt
		if deferred, is_deferred := stmt.(^Stmt_Defer); is_deferred {
			inner = deferred.stmt
		}
		// design.md "when statement": the selected branch has no scope of its own.
		if w, is_when := inner.(^Stmt_When); is_when {
			if w.selected != nil {
				report_unread_required_results(k, w.selected.stmts)
			}
			continue
		}
		d, is_decl := inner.(^Decl)
		if !is_decl || d.kind != .Var {
			continue
		}
		for id, index in d.symbols {
			sym := symbol_of(k.c, id)
			if sym == nil || sym.named || sym.kind != .Var {
				continue
			}
			required := type_requires_results(k.c, sym.type)
			source := ""
			if !required && index < len(d.values) {
				if call, is_call := d.values[index].(^Expr_Call); is_call && call.type != INVALID_TYPE {
					source, required = required_result_of_call(k, call)
				}
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
}

check_scoped_block :: proc(k: ^Checker, b: ^Block) -> Flow_Info {
	outer := k.scope
	k.scope = new_scope(k.c, outer, .Local)
	defer k.scope = outer
	return check_block(k, b)
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
		// design.md "`@(intrinsic)`": a local one describes nothing, and a type
		// written `---` has no value to check.
		if attribute, found := find_attribute(s.attributes, "intrinsic"); found {
			report_misplaced_intrinsic(k, attribute.span)
			return FLOWS
		}
		check_local_declaration(k, s)
		return FLOWS

	case ^Stmt_Expr:
		flow := FLOWS
		for expr in s.exprs {
			if expr != nil && !expression_statement_has_effect(expr) {
				errorf(k.c, expr_span(expr), "L0313", "this expression statement has no effect")
			}
			check_expr(k, expr)
			report_discarded_required_results(k, expr)
			// A diverging call never returns, in either phase, so nothing after it
			// in this block is reachable.
			if call_diverges(k.c, expr) {
				flow.can_fall_through = false
			}
		}
		return flow

	case ^Stmt_Assign:
		check_assign(k, s)
		classify_assignment_copies(k, s)
		return FLOWS

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

// A call or an `or_return`; anything else computes a value and drops it.
@(private = "file")
expression_statement_has_effect :: proc(e: Expr) -> bool {
	#partial switch v in e {
	case ^Expr_Call:
		return true
	case ^Expr_Postfix:
		return v.op == .Or_Return
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
	if len(s.lhs) > 1 && lower_parallel_setter_assign(k, s) {
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
				materialize(k, s.rhs[index], default_type(k.c, ident.type))
				ident.type = expr_base(s.rhs[index]).type
			}
			continue
		}
		// `grid[x, y] = v` on a container with no location to hand out.
		if indexed, is_index := target.(^Expr_Index); is_index {
			if check_place_setter(k, s, indexed, s.rhs[index]) {
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
check_place_setter :: proc(k: ^Checker, s: ^Stmt_Assign, target: ^Expr_Index, value: Expr) -> bool {
	setters := place_setters(k, target)
	if setters == nil {
		return false
	}
	operand := check_single_expr(k, target.operand, position = .Place)
	if operand == INVALID_TYPE {
		return true
	}
	// The value is the last of what follows the receiver.
	written := make([]Expr, len(target.indices) + 1, context.temp_allocator)
	copy(written, target.indices)
	written[len(target.indices)] = value
	args, ok := index_arguments(k, target.operand, written, setters)
	if !ok {
		return true
	}
	chosen, bound := resolve_operator(k, s.op_span, "[]=", setters, args)
	if chosen == INVALID_SYMBOL {
		return true
	}
	s.place_setter = chosen
	s.setter_bound = bound
	return true
}

// design.md "Indexing and slicing": with no location to hand out, `box[i] += v`
// reads through `operator([])` and writes back through `operator([]=)`. It is
// checked as the block
//
//     { r := &mut box; i0 := i; v0 := v; r^[i0] = r^[i0] + v0; }
//
// so the receiver and indices are evaluated once, then the right operand
// (design.md "Evaluation order"). A temporary is left out where evaluating the
// expression twice is the same: a variable or field path receiver, and a
// literal, implicit selector, constant, or name other than a scalar variable's.
@(private = "file")
lower_compound_setter :: proc(k: ^Checker, s: ^Stmt_Assign, target: ^Expr_Index) -> bool {
	op := compound_operator(s.op)
	if op == .EOF || place_setters(k, target) == nil {
		return false
	}
	span := s.span
	stmts := make([dynamic]Stmt, 0, len(target.indices) + 3, k.c.semantic_allocator)
	receiver, index_names := bind_index_place(k, &stmts, target, "compound$", span)
	value := clone_expr(k.c, s.rhs[0])
	// A constant right operand keeps its unfixed type for the operator to settle.
	if !lowered_constant(k, s.rhs[0]) && needs_temporary(k, s.rhs[0]) {
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
	append(&stmts, lowered_assign(k, lowered_index(k, target, index_names, receiver, span), combined, s.op_span, span))
	check_lowered_block(k, s, stmts[:])
	return true
}

// `s` as the block that stands for it.
@(private = "file")
check_lowered_block :: proc(k: ^Checker, s: ^Stmt_Assign, stmts: []Stmt) {
	block := new(Block, k.c.semantic_allocator)
	block.span = s.span
	block.stmts = stmts
	s.lowered = block
	check_scoped_block(k, block)
}

// Binds an indexed destination's receiver, by address, and its indices to
// temporaries named from `prefix`, so later statements reuse them rather than
// evaluate them again. What reads the same each time stays as written, its
// name "".
@(private = "file")
bind_index_place :: proc(
	k: ^Checker, stmts: ^[dynamic]Stmt, target: ^Expr_Index, prefix: string, span: Span,
) -> (receiver: string, index_names: []string) {
	if !is_effect_free_place(target.operand) {
		receiver = concat(k.c, prefix, "receiver")
		append(stmts, synth_decl(k.c, .Var, receiver, lowered_address(k, target.operand, span), span))
	}
	index_names = make([]string, len(target.indices), k.c.semantic_allocator)
	for index, position in target.indices {
		if needs_temporary(k, index) {
			index_names[position] = lowered_position_name(k, concat(k.c, prefix, "index"), position, "")
			append(stmts, synth_decl(k.c, .Var, index_names[position], clone_expr(k.c, index), span))
		}
	}
	return
}

// design.md "Evaluation order": what could read differently later is bound. That
// includes a name of a scalar variable, read before the right operand or an
// earlier write can change it. Copying one costs nothing; any other variable is
// read where it is used.
@(private = "file")
needs_temporary :: proc(k: ^Checker, e: Expr) -> bool {
	if !lowered_pure(e) {
		return true
	}
	ident, is_ident := e.(^Expr_Ident)
	if !is_ident {
		return false
	}
	sym := ident_symbol(k, ident)
	return sym != nil && (sym.kind == .Var || sym.kind == .Parameter) && type_is_panic_free_scalar(k.c, sym.type)
}

// design.md "Evaluation order": a multiple assignment with an `operator([]=)`
// destination is checked as the block
//
//     { v0 := a; v1 := b; r0 := &mut grid; i0 := i; r0^[i0] = v0; x = v1; }
//
// so every value is evaluated, then every destination's receiver and indices,
// then each write, the setter call among them, from left to right. A
// destination that is neither indexed nor an effect-free place is bound by
// address, and a constant value is written where it is used.
@(private = "file")
lower_parallel_setter_assign :: proc(k: ^Checker, s: ^Stmt_Assign) -> bool {
	if !any_place_setter(k, s.lhs) {
		return false
	}
	span := s.span
	stmts := make([dynamic]Stmt, 0, 3 * len(s.lhs), k.c.semantic_allocator)
	values := make([]Expr, len(s.rhs), k.c.semantic_allocator)
	for value, position in s.rhs {
		if is_discard(s.lhs[position]) {
			append(&stmts, lowered_assign(k, clone_expr(k.c, s.lhs[position]), clone_expr(k.c, value), s.op_span, span))
			continue
		}
		// A constant has no effect to order and keeps its unfixed type for
		// its destination to settle (design.md "Implicit type conversions").
		if lowered_constant(k, value) {
			values[position] = clone_expr(k.c, value)
			continue
		}
		name := lowered_position_name(k, "assign$value", position, "")
		append(&stmts, synth_decl(k.c, .Var, name, clone_expr(k.c, value), span))
		values[position] = synth_ident(k.c, name, span)
	}
	destinations := make([]Expr, len(s.lhs), k.c.semantic_allocator)
	for target, position in s.lhs {
		if is_discard(target) {
			continue
		}
		prefix := lowered_position_name(k, "assign$", position, "$")
		if indexed, is_index := target.(^Expr_Index); is_index {
			receiver, index_names := bind_index_place(k, &stmts, indexed, prefix, span)
			destinations[position] = lowered_index(k, indexed, index_names, receiver, span)
		} else if is_effect_free_place(target) {
			destinations[position] = clone_expr(k.c, target)
		} else {
			name := concat(k.c, prefix, "place")
			append(&stmts, synth_decl(k.c, .Var, name, lowered_address(k, target, span), span))
			destinations[position] = synth_deref(k.c, synth_ident(k.c, name, span), span)
		}
	}
	for destination, position in destinations {
		if destination != nil {
			append(&stmts, lowered_assign(k, destination, values[position], s.op_span, span))
		}
	}
	check_lowered_block(k, s, stmts[:])
	return true
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
	store := new(Stmt_Assign, k.c.semantic_allocator)
	store.span = span
	store.op = .Assign
	store.op_span = s.op_span
	destinations := make([dynamic]Expr, 0, len(s.lhs), k.c.semantic_allocator)
	values := make([dynamic]Expr, 0, len(s.lhs), k.c.semantic_allocator)
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
	store.lhs, store.rhs = destinations[:], values[:]
	stmts := make([]Stmt, 2, k.c.semantic_allocator)
	stmts[0], stmts[1] = take, store
	check_lowered_block(k, s, stmts)
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

@(private = "file")
lowered_assign :: proc(k: ^Checker, target, value: Expr, op_span, span: Span) -> Stmt {
	assign := new(Stmt_Assign, k.c.semantic_allocator)
	assign.span = span
	assign.op = .Assign
	assign.op_span = op_span
	assign.lhs = make([]Expr, 1, k.c.semantic_allocator)
	assign.lhs[0] = target
	assign.rhs = make([]Expr, 1, k.c.semantic_allocator)
	assign.rhs[0] = value
	return assign
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
		if !check_user_compound(k, s, op, type) {
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
		if !simd_operand_is_builtin(k.c, type, rhs_type) && check_user_compound(k, s, op, type, rhs_type) {
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

// A direct compound overload, or the binary operator plus an assignment.
@(private = "file")
check_user_compound :: proc(
	k: ^Checker, s: ^Stmt_Assign, op: Token_Kind, type: Type_Id,
	prechecked_rhs: Type_Id = INVALID_TYPE,
) -> bool {
	rhs_type := prechecked_rhs
	if rhs_type == INVALID_TYPE {
		rhs_type = check_single_expr(k, s.rhs[0])
		if rhs_type == INVALID_TYPE {
			return true // already reported; re-checking it would report a second time
		}
	}
	operands := []Type_Id{type, rhs_type}

	compound := operator_spelling(s.op)
	direct_args := make([]Arg_Info, 2, k.c.semantic_allocator)
	direct_args[0] = arg_from_expr(s.lhs[0], .Inout)
	direct_args[1] = arg_from_expr(s.rhs[0])
	direct := form_operator_set(k, compound, operands, direct_args)
	if candidates_viable(direct.formed) {
		chosen, bound := resolve_operator_set(k, s.op_span, direct, direct_args)
		if chosen == INVALID_SYMBOL {
			return true
		}
		s.lhs[0], s.rhs[0] = bound[0], bound[1]
		s.operator, s.operator_direct = chosen, true
		return true
	}

	binary := operator_text(op)
	args := make([]Arg_Info, 2, k.c.semantic_allocator)
	args[0] = arg_from_expr(s.lhs[0])
	args[1] = arg_from_expr(s.rhs[0])
	set := form_operator_set(k, binary, operands, args)
	if !candidates_viable(set.formed) {
		if operator_exists(k, direct.members, operands) {
			resolve_operator_set(k, s.op_span, direct, direct_args)
			return true
		}
		if operator_exists(k, set.members, operands) {
			resolve_operator_set(k, s.op_span, set, args)
			return true
		}
		return false
	}
	chosen, bound := resolve_operator_set(k, s.op_span, set, args)
	if chosen == INVALID_SYMBOL {
		return true
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
		return true
	}
	s.lhs[0], s.rhs[0] = bound[0], bound[1]
	s.operator, s.operator_direct = chosen, false
	return true
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
			"this is an element of a read-only `[]T` and cannot be %s; writing through a slice takes a `[]mut T`, which `&mut a[lo:hi]` makes",
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

check_condition :: proc(k: ^Checker, cond: Expr) {
	if cond == nil {
		return
	}
	type := check_single_expr(k, cond, TYPE_BOOL)
	if type == INVALID_TYPE {
		return
	}
	materialize(k, cond, TYPE_BOOL)
	if !type_is_boolean(k.c, expr_base(cond).type) {
		errorf(k.c, expr_span(cond), "L0355", "a condition must be `bool`, found `%s`", type_name(k.c, type))
	}
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
	return Flow_Info {
		can_fall_through = !infinite || body.breaks || broken,
		returns          = body.returns,
	}
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
	flow := check_stmt(k, s.stmt)
	k.in_defer = false

	if flow.returns {
		errorf(k.c, s.span, "L0369", "a deferred statement cannot `return`")
	}
	if flow.breaks || flow.continues {
		errorf(k.c, s.span, "L0369", "a deferred statement cannot leave the construct it is registered in")
	}
	return FLOWS
}

@(private = "file")
check_return :: proc(k: ^Checker, s: ^Stmt_Return) -> Flow_Info {
	if k.in_defer {
		// Reported by `check_defer` from the flow summary; nothing to add here.
		return Flow_Info{returns = true}
	}
	terminated := Flow_Info{returns = true}

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
			errorf(
				k.c, s.span, "L0326",
				"this procedure returns `%s`, so `return` needs a value; a result is anonymous and has no local to fill",
				type_name(k.c, k.result_type),
			)
			if shape, fallible := fallible_of(k.c, k.result_type); fallible && !k.result_inout {
				name := union_variant_name(k.c, k.result_type, shape.success)
				if shape.success_type == k.c.unit_type {
					add_notef(
						k.c, s.span, "`.%s` carries `Unit` here only through a generic argument, so `return;` cannot build it; write `return .%s;`",
						name, name,
					)
				} else {
					add_notef(
						k.c, s.span, "only a success that carries nothing or `Unit`, as `Status(E)`'s does, returns with `return;`; write `return .%s(value);`",
						name,
					)
				}
			}
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
check_branch :: proc(k: ^Checker, s: ^Stmt_Branch) -> Flow_Info {
	if k.loop_depth == 0 {
		if !k.branches_reported {
			errorf(k.c, s.span, "L0368", "`%s` is only valid inside a loop", s.kind == .Break ? "break" : "continue")
		}
		return FLOWS
	}
	return s.kind == .Break ? Flow_Info{breaks = true} : Flow_Info{continues = true}
}

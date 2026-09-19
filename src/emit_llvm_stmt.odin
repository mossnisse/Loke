// Statement control flow, local bindings, assignment, and returns.
package lokec

import "core:fmt"

// -------------------------------------------------------------- statements --

@(private)
emit_scoped_block :: proc(e: ^Emitter, b: ^Block) {
	push_scope(e, b)
	emit_block_statements(e, b)
	pop_scope(e)
}

@(private)
emit_block_statements :: proc(e: ^Emitter, b: ^Block) {
	if b == nil {
		return
	}
	emit_statements(e, b.stmts)
}

// Code after a terminator gets a fresh block, which LLVM requires.
@(private = "file")
emit_statements :: proc(e: ^Emitter, stmts: []Stmt) {
	for stmt in stmts {
		if e.terminated {
			fmt.sbprintfln(&e.b, "unreachable.%d:", next_id(e))
			e.terminated = false
		}
		// A block statement's full-expression boundary; initial statements and loop
		// updates declare their own.
		push_temporaries(e)
		emit_stmt(e, stmt)
		pop_temporaries(e)
	}
}

@(private)
emit_stmt :: proc(e: ^Emitter, stmt: Stmt) {
	switch s in stmt {
	case ^Stmt_Error:

	// Its members are module functions, emitted with the hoisted procedures.
	case ^Item_Impl:

	case ^Decl:
		emit_local_decl(e, s)

	case ^Stmt_Expr:
		for expr in s.exprs {
			if call, is_call := expr.(^Expr_Call); is_call {
				if call_builtin_kind(e, call) == .Static_Assert {
					continue
				}
			}
			value := emit_expr(e, expr)
			emit_discarded_temporary(e, expr, value)
		}

	case ^Stmt_Assign:
		emit_assign(e, s)

	case ^Stmt_If:
		emit_if(e, s)

	case ^Stmt_For:
		emit_for(e, s)

	case ^Stmt_Switch:
		if s.kind != .Value {
			emit_type_switch(e, s)
		} else {
			emit_switch(e, s)
		}

	case ^Stmt_Defer:
		if s.slot < len(e.defer_flags) && len(e.cleanups) > 0 {
			entry := Deferred{flag = e.defer_flags[s.slot], stmt = s.stmt}
			unwind_reserve(e, &entry)
			e.unwind.slot_by_defer[s.slot] = entry.slot
			fmt.sbprintfln(&e.b, "  store i1 true, ptr %s", e.defer_flags[s.slot])
			unwind_register(e, entry)
			append(&e.cleanups[len(e.cleanups) - 1].entries, entry)
		}

	case ^Stmt_Return:
		emit_return_values(e, s)

	case ^Stmt_Branch:
		// Temporaries of an enclosing initial statement are owed on this path too.
		drain_temporaries(e, 0)
		if s.kind == .Break {
			run_cleanups(e, e.break_depth)
			branch(e, e.break_label)
		} else {
			run_cleanups(e, e.continue_depth)
			branch(e, e.continue_label)
		}

	case ^Block:
		emit_scoped_block(e, s)

	case ^Stmt_When:
		// The chosen branch shares the surrounding block's scope.
		emit_block_statements(e, when_selected_block(s))

	case ^Stmt_Foreach:
		if s.kind == .Unresolved {
			backend_fail(e, "an unresolved statement reached emission")
			return
		}
		emit_foreach(e, s)
	}
}

@(private = "file")
emit_local_decl :: proc(e: ^Emitter, d: ^Decl) {
	if d.destructure.active {
		emit_destructure_decl(e, d)
		return
	}
	for symbol_id, i in d.symbols {
		sym := symbol_of(e.c, symbol_id)
		// Constants fold at use; static storage lives at module level.
		if sym == nil || sym.kind != .Var || sym.duration != .None {
			continue
		}
		slot := declare_local(e, symbol_id)
		// No initializer, or `= ---`: the local starts dead, but a written `via`
		// still binds.
		if i >= len(d.values) || d.values[i] == nil {
			emit_eager_via_binding(e, symbol_id, slot)
			register_implicit_drop(e, symbol_id, live = false)
			continue
		}
		value := emit_expr(e, d.values[i])
		if i < len(d.value_clones) && d.value_clones[i] {
			value = emit_clone_value(e, sym.type, value, emit_destination_allocator(e, symbol_id))
		}
		store(e, sym.type, value, slot)
		// An empty literal has no allocator of its own, so a written `via` binds.
		if composite, empty_literal := d.values[i].(^Expr_Composite); empty_literal && len(composite.elements) == 0 {
			emit_eager_via_binding(e, symbol_id, slot)
		}
		register_implicit_drop(e, symbol_id)
	}
}

// design.md "Exchange": the replacement is fully evaluated before the
// destination is touched, and the old value is handed back, not dropped.
@(private)
emit_exchange :: proc(e: ^Emitter, v: ^Expr_Call, as_type: Type_Id) -> string {
	address := emit_address(e, v.bound[0])
	replacement := emit_expr(e, v.bound[1])
	previous := load(e, llvm_type(e, as_type), address)
	store(e, as_type, replacement, address)
	return previous
}

// `move` transfers the value and leaves a named source dead.
@(private)
emit_move :: proc(e: ^Emitter, v: ^Expr_Move) -> string {
	value := emit_expr(e, v.value)
	if ident, is_ident := v.value.(^Expr_Ident); is_ident {
		kill_place(e, ident.symbol)
	}
	return value
}

// design.md "Destructuring": the operand is evaluated once. From a place,
// retained managed fields are cloned (with each destination's allocator); a
// consumed record's fields transfer. Every owned field is guarded until bound.
@(private = "file")
emit_destructure_fields :: proc(
	e: ^Emitter, plan: ^Destructure, operand: Expr, destinations: []Symbol_Id,
) -> (values: []string, guards: []Deferred) {
	record := emit_expr(e, operand)
	aggregate := llvm_type(e, plan.record)
	values = make([]string, len(plan.fields))
	guards = make([]Deferred, len(plan.fields))
	for field_id, index in plan.fields {
		field := symbol_of(e.c, field_id)
		if field == nil {
			continue
		}
		value := extract(e, aggregate, record, index)
		retained := index < len(plan.retained) && plan.retained[index]
		if retained && index < len(plan.clones) && plan.clones[index] {
			value = emit_clone_value(
				e, field.type, value,
				emit_destination_allocator(e, index < len(destinations) ? destinations[index] : INVALID_SYMBOL),
			)
		}
		values[index] = value
		if !plan.from_place || (retained && index < len(plan.clones) && plan.clones[index]) {
			guards[index] = hold_temporary_value(e, field.type, value)
		}
	}
	return
}

// A consumed record's discarded fields drop in reverse order, after every
// retained field is bound.
@(private = "file")
emit_destructure_discards :: proc(e: ^Emitter, plan: ^Destructure, guards: []Deferred) {
	if plan.from_place {
		return
	}
	#reverse for _, index in plan.fields {
		if index >= len(plan.retained) || !plan.retained[index] {
			drop_temporary_value(e, guards[index])
		}
	}
}

@(private = "file")
emit_destructure_decl :: proc(e: ^Emitter, d: ^Decl) {
	plan := &d.destructure
	values, guards := emit_destructure_fields(e, plan, d.values[0], d.symbols)
	for symbol_id, index in d.symbols {
		if symbol_id == INVALID_SYMBOL {
			continue
		}
		field := symbol_of(e.c, plan.fields[index])
		slot := declare_local(e, symbol_id)
		if slot == "" || field == nil {
			continue
		}
		store(e, field.type, values[index], slot)
		register_implicit_drop(e, symbol_id)
		finish_temporary_drop(e, guards[index])
	}
	emit_destructure_discards(e, plan, guards)
}

@(private = "file")
emit_destructure_assign :: proc(e: ^Emitter, s: ^Stmt_Assign) {
	plan := &s.destructure
	destinations := make([]Symbol_Id, len(plan.fields))
	for target, index in s.lhs {
		destinations[index] = place_root_symbol(target)
	}
	values, guards := emit_destructure_fields(e, plan, s.rhs[0], destinations)
	addresses := make([]string, len(s.lhs))
	map_destinations := make([]Map_Assignment_Destination, len(s.lhs))
	for target, index in s.lhs {
		if index >= len(plan.retained) || !plan.retained[index] {
			continue
		}
		if entry := inserting_map_index(target); entry != nil {
			map_destinations[index] = prepare_map_assignment(e, entry, len(s.lhs) > 1)
			continue
		}
		addresses[index] = emit_address(e, target)
	}
	for target, index in s.lhs {
		if index >= len(plan.retained) || !plan.retained[index] {
			continue
		}
		if entry := inserting_map_index(target); entry != nil {
			emit_map_insert_store(e, map_destinations[index], values[index], guards[index])
			continue
		}
		if addresses[index] == "" {
			continue
		}
		field := symbol_of(e.c, plan.fields[index])
		if field == nil {
			continue
		}
		emit_replace_place(e, s, index, addresses[index])
		store(e, field.type, values[index], addresses[index])
		revive_place(e, s.lhs[index])
		finish_temporary_drop(e, guards[index])
	}
	emit_destructure_discards(e, plan, guards)
}

@(private = "file")
declare_local :: proc(e: ^Emitter, symbol_id: Symbol_Id) -> string {
	sym := symbol_of(e.c, symbol_id)
	if sym == nil || sym.kind != .Var {
		return ""
	}
	name := fmt.aprintf("%%%s.%d", identifier_text(e.c, sym.name), next_id(e))
	alloca_named(e, name, llvm_type(e, sym.type))
	bind_local(e, symbol_id, name)
	return name
}

// design.md "Assignment statements": every value, then every destination
// address, then the writes.
@(private = "file")
emit_assign :: proc(e: ^Emitter, s: ^Stmt_Assign) {
	if s.op != .Assign {
		emit_compound_assign(e, s)
		return
	}
	if s.place_setter != INVALID_SYMBOL {
		emit_operator_call(e, s.place_setter, s.setter_bound)
		return
	}
	if s.destructure.active {
		emit_destructure_assign(e, s)
		return
	}
	values := make([]string, len(s.rhs))
	map_guards := make([]Deferred, len(s.rhs))
	for value, index in s.rhs {
		map_guards[index] = Deferred{slot = -1}
		values[index] = emit_expr(e, value)
		if index < len(s.rhs_clones) && s.rhs_clones[index] {
			values[index] = emit_clone_value(
				e, expr_base(s.lhs[index]).type, values[index],
				emit_destination_allocator(e, place_root_symbol(s.lhs[index])),
			)
		}
		if index < len(s.lhs) && inserting_map_index(s.lhs[index]) != nil {
			map_guards[index] = hold_temporary_value(e, expr_base(s.lhs[index]).type, values[index])
		}
	}

	addresses := make([]string, len(s.lhs))
	map_destinations := make([]Map_Assignment_Destination, len(s.lhs))
	for target, index in s.lhs {
		if is_discard(target) {
			continue
		}
		if entry := inserting_map_index(target); entry != nil {
			map_destinations[index] = prepare_map_assignment(e, entry, len(s.lhs) > 1)
			continue
		}
		addresses[index] = emit_address(e, target)
	}
	for target, index in s.lhs {
		// `m[key] = elem` inserts rather than storing through an address.
		if entry := inserting_map_index(target); entry != nil && index < len(values) {
			emit_map_insert_store(e, map_destinations[index], values[index], map_guards[index])
			continue
		}
		if addresses[index] == "" || index >= len(values) {
			if is_discard(target) && index < len(values) {
				emit_discarded_temporary(e, s.rhs[index], values[index])
			}
			continue
		}
		emit_replace_place(e, s, index, addresses[index])
		store(e, expr_base(target).type, values[index], addresses[index])
		revive_place(e, target)
	}
}

// Drops the destination's old value before a write, as its state requires,
// and marks a flagged local live again.
@(private = "file")
emit_replace_place :: proc(e: ^Emitter, s: ^Stmt_Assign, index: int, address: string) {
	target := s.lhs[index]
	type := expr_base(target).type
	if !emit_lifecycle(e, type).managed {
		return
	}
	flag := ""
	if ident, is_ident := target.(^Expr_Ident); is_ident {
		flag = drop_flag_of(e, ident.symbol)
	}
	state := index < len(s.destination_live) ? s.destination_live[index] : Liveness.Live
	if state == .Live || (state != .Dead && flag == "") {
		emit_drop_place(e, type, address)
	} else if state != .Dead {
		live := load(e, "i1", flag)
		run, skip := new_label(e, "replace.drop"), new_label(e, "replace.done")
		branch_if(e, live, run, skip)
		place_label(e, run)
		emit_drop_place(e, type, address)
		branch(e, skip)
		place_label(e, skip)
	}
	if flag != "" {
		fmt.sbprintfln(&e.b, "  store i1 true, ptr %s", flag)
	}
}

// The destination is evaluated once, before the right operand.
@(private = "file")
emit_compound_assign :: proc(e: ^Emitter, s: ^Stmt_Assign) {
	target := s.lhs[0]
	type := expr_base(target).type
	if s.operator != INVALID_SYMBOL {
		operands := [2]Expr{target, s.rhs[0]}
		if s.operator_direct {
			// A direct `+=` overload writes through its `inout` destination.
			emit_operator_call(e, s.operator, operands[:])
			return
		}
		// The binary operator, then a replacing write.
		address := emit_address(e, target)
		value := emit_operator_call(e, s.operator, operands[:], left_place = address)
		if !operator_consumes_left(e, s.operator) {
			emit_replace_place(e, s, 0, address)
		}
		store(e, type, value, address)
		return
	}
	// design.md: the destination is read after the right operand.
	address := emit_address(e, target)
	rhs := emit_expr(e, s.rhs[0])
	current := load(e, llvm_type(e, type), address)
	op := compound_operator(s.op)
	result: string
	if type_is_simd(e.c, type) {
		result = emit_simd_binary_values(e, op, type, current, type, rhs, expr_base(s.rhs[0]).type)
	} else {
		result = emit_binary_op(e, op, type, expr_base(s.rhs[0]).type, current, rhs)
	}
	store(e, type, result, address)
}

// A `move` left operand already handed the old value to the operator.
@(private = "file")
operator_consumes_left :: proc(e: ^Emitter, operator: Symbol_Id) -> bool {
	symbol := symbol_of(e.c, operator)
	info := symbol == nil ? nil : type_of(e.c, symbol.proc_type)
	return info != nil && len(info.param_modes) > 0 && info.param_modes[0] == .Move
}

// The destination of `m[key] = elem`, which creates its element.
@(private = "file")
inserting_map_index :: proc(target: Expr) -> ^Expr_Index {
	index, ok := target.(^Expr_Index)
	if !ok || !index.map_inserts {
		return nil
	}
	return index
}

// `_` as a destination; its value is dropped.
is_discard :: proc(target: Expr) -> bool {
	ident, ok := target.(^Expr_Ident)
	return ok && ident.name == "_"
}

@(private = "file")
emit_if :: proc(e: ^Emitter, s: ^Stmt_If) {
	push_scope(e, nil)
	if s.init != nil {
		emit_stmt(e, s.init)
	}
	// The condition's temporaries end before either branch runs.
	push_temporaries(e)
	cond := emit_expr(e, s.cond)
	pop_temporaries(e)
	then_label := new_label(e, "if.then")
	else_label := new_label(e, "if.else")
	done_label := new_label(e, "if.done")
	branch_if(e, cond, then_label, s.otherwise == nil ? done_label : else_label)

	place_label(e, then_label)
	emit_scoped_block(e, s.then)
	branch(e, done_label)

	if s.otherwise != nil {
		place_label(e, else_label)
		emit_stmt(e, s.otherwise)
		branch(e, done_label)
	}
	place_label(e, done_label)
	pop_scope(e)
}

@(private = "file")
emit_for :: proc(e: ^Emitter, s: ^Stmt_For) {
	outer_break, outer_continue := e.break_label, e.continue_label
	outer_break_depth, outer_continue_depth := e.break_depth, e.continue_depth
	defer {
		e.break_label, e.continue_label = outer_break, outer_continue
		e.break_depth, e.continue_depth = outer_break_depth, outer_continue_depth
	}

	// The loop's own scope holds the init declaration; `break` leaves it too.
	e.break_depth = len(e.cleanups)
	push_scope(e, nil)
	if s.init != nil {
		emit_stmt(e, s.init)
	}

	head := new_label(e, "for.head")
	body := new_label(e, "for.body")
	post := new_label(e, "for.post")
	done := new_label(e, "for.done")
	e.break_label = done
	e.continue_label = post
	e.continue_depth = len(e.cleanups)

	place_label(e, head)
	if s.cond != nil {
		// A boundary per evaluation, since the temporaries' storage is reused.
		push_temporaries(e)
		cond := emit_expr(e, s.cond)
		pop_temporaries(e)
		branch_if(e, cond, body, done)
	} else {
		branch(e, body)
	}

	place_label(e, body)
	emit_scoped_block(e, s.body)
	branch(e, post)

	place_label(e, post)
	if s.post != nil {
		push_temporaries(e)
		emit_stmt(e, s.post)
		pop_temporaries(e)
	}
	branch(e, head)

	place_label(e, done)
	pop_scope(e)
}

// ponytail: one ordered comparison chain rather than an LLVM `switch` for the
// all-constant case — ranges and non-constant cases need the chain anyway, and a
// second lowering would have to agree with this one about source order. Add a
// jump table when a measured switch is hot.
@(private = "file")
emit_switch :: proc(e: ^Emitter, s: ^Stmt_Switch) {
	push_scope(e, nil)
	if s.init != nil {
		emit_stmt(e, s.init)
	}
	subject_type := expr_base(s.subject).type
	subject := emit_expr(e, s.subject)
	done := new_label(e, "switch.done")
	bodies, tests, order, fallback := switch_labels(e, s, "case", done)
	defer delete(order)
	closed_fallback := fallback == done && s.exhaustive
	if closed_fallback {
		fallback = new_label(e, "switch.invalid")
	}

	branch(e, len(order) > 0 ? tests[order[0]] : fallback)
	for case_index, position in order {
		place_label(e, tests[case_index])
		next := position + 1 < len(order) ? tests[order[position + 1]] : fallback
		matched := ""
		for value in s.cases[case_index].values {
			matched = or_match(e, matched, emit_case_test(e, subject, subject_type, value))
		}
		branch_if(e, matched, bodies[case_index], next)
	}

	if closed_fallback {
		place_label(e, fallback)
		fmt.sbprintfln(&e.b, "  unreachable")
		e.terminated = true
	}

	for entry, index in s.cases {
		place_label(e, bodies[index])
		push_scope_stmts(e, entry.stmts)
		emit_statements(e, entry.stmts)
		pop_scope(e)
		branch(e, done)
	}

	place_label(e, done)
	pop_scope(e)
}

// Value cases are tested in source order, falling through to the default body
// wherever it was written, or to `done`.
@(private = "file")
switch_labels :: proc(
	e: ^Emitter, s: ^Stmt_Switch, prefix, done: string,
) -> (bodies, tests: []string, order: [dynamic]int, fallback: string) {
	bodies = make([]string, len(s.cases))
	tests = make([]string, len(s.cases))
	fallback = done
	for entry, index in s.cases {
		bodies[index] = new_label(e, fmt.aprintf("%s.body", prefix))
		tests[index] = new_label(e, fmt.aprintf("%s.test", prefix))
		if len(entry.values) == 0 {
			fallback = bodies[index]
		} else {
			append(&order, index)
		}
	}
	return
}

@(private = "file")
or_match :: proc(e: ^Emitter, matched, test: string) -> string {
	if matched == "" {
		return test
	}
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = or i1 %s, %s", out, matched, test)
	return out
}

// A type switch dispatches on a union's tag or an `any_view`'s `typeid`. A case
// binds at the variant's type, or at the subject's type for several or default.
@(private = "file")
emit_type_switch :: proc(e: ^Emitter, s: ^Stmt_Switch) {
	push_scope(e, nil)
	if s.init != nil {
		emit_stmt(e, s.init)
	}
	union_type := expr_base(s.subject).type
	erased := union_type == TYPE_ANY_VIEW
	consumes := false
	tag_llvm := "i64"
	value := emit_expr(e, s.subject)
	slot, tag: string
	if erased {
		storage := llvm_type(e, TYPE_ANY_VIEW)
		slot, tag = extract(e, storage, value, ANY_VIEW_DATA), extract(e, storage, value, ANY_VIEW_ID)
	} else {
		tag_llvm = fmt.aprintf("i%d", union_layout(e.c, union_type).tag_bytes * 8)
		slot = emit_union_spill(e, union_type, value)
		tag = emit_union_tag(e, union_type, value)
		// A produced subject is the switch's to drop; a named place is borrowed.
		consumes = !expression_is_borrowed_place(s.subject)
	}
	done := new_label(e, "typeswitch.done")
	bodies, tests, order, fallback := switch_labels(e, s, "typecase", done)
	defer delete(order)

	branch(e, len(order) > 0 ? tests[order[0]] : fallback)
	for case_index, position in order {
		place_label(e, tests[case_index])
		next := position + 1 < len(order) ? tests[order[position + 1]] : fallback
		matched := ""
		entry := s.cases[case_index]
		count := erased ? len(entry.values) : len(entry.variant_indices)
		for value_index in 0 ..< count {
			discriminant := u64(0)
			if erased {
				discriminant = typeid_value(e.c, expr_base(entry.values[value_index]).denoted_type)
			} else {
				discriminant = u64(entry.variant_indices[value_index])
			}
			test := temp(e)
			fmt.sbprintfln(&e.b, "  %s = icmp eq %s %s, %d", test, tag_llvm, tag, discriminant)
			matched = or_match(e, matched, test)
		}
		branch_if(e, matched, bodies[case_index], next)
	}

	for entry, index in s.cases {
		place_label(e, bodies[index])
		push_scope_stmts(e, entry.stmts)
		emit_type_case_binding(e, entry, union_type, value, slot, erased)
		// A consumed payload drops with the binding, or with the case if unbound.
		if consumes {
			if entry.binding_symbol != INVALID_SYMBOL {
				register_implicit_drop(e, entry.binding_symbol)
			} else {
				register_scope_place(e, union_type, slot)
			}
		}
		emit_statements(e, entry.stmts)
		pop_scope(e)
		branch(e, done)
	}

	place_label(e, done)
	pop_scope(e)
}

@(private = "file")
emit_type_case_binding :: proc(e: ^Emitter, entry: Switch_Case, union_type: Type_Id, value, slot: string, erased := false) {
	if entry.binding_symbol == INVALID_SYMBOL {
		return
	}
	binding := fmt.aprintf("%%bind.%d", next_id(e))
	alloca_named(e, binding, llvm_type(e, entry.binding_type))
	bind_local(e, entry.binding_symbol, binding)
	if entry.binding_type == union_type {
		fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", llvm_type(e, union_type), value, binding)
		return
	}
	// A concrete erased case reads through the data pointer.
	payload := ""
	if erased {
		payload = load(e, llvm_type(e, entry.binding_type), slot)
	} else {
		payload = emit_union_payload(e, union_type, entry.binding_type, slot)
	}
	store(e, entry.binding_type, payload, binding)
}

@(private = "file")
emit_case_test :: proc(e: ^Emitter, subject: string, subject_type: Type_Id, value: Expr) -> string {
	if range, is_range := value.(^Expr_Range); is_range {
		lo := emit_expr(e, range.lo)
		hi := emit_expr(e, range.hi)
		low_ok := emit_compare(e, .Gt_Eq, subject_type, subject, lo)
		high_op := range.op == .Range_Excl ? Token_Kind.Lt : Token_Kind.Lt_Eq
		high_ok := emit_compare(e, high_op, subject_type, subject, hi)
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = and i1 %s, %s", out, low_ok, high_ok)
		return out
	}
	return emit_equal(e, subject_type, subject, emit_expr(e, value))
}

// ----------------------------------------------------------------- returns --

// The result is stored before any cleanup runs, so a `defer` cannot change it.
@(private)
emit_return_values :: proc(e: ^Emitter, s: ^Stmt_Return) {
	if s != nil && s.value != nil && e.result_slot != "" {
		value := s.value
		// An `inout` result hands back the place itself, not a copy of it.
		operand := e.result_inout ? emit_address(e, value.expr) : emit_expr(e, value.expr)
		if value.clone_on_return {
			operand = emit_clone_value(e, e.result_type, operand)
		}
		if e.result_inout {
			fmt.sbprintfln(&e.b, "  store ptr %s, ptr %s", operand, e.result_slot)
		} else {
			store(e, e.result_type, operand, e.result_slot)
		}
		// A returned local transferred out, so cleanup must not drop it.
		if !value.clone_on_return {
			if ident, is_ident := value.expr.(^Expr_Ident); is_ident {
				if sym := symbol_of(e.c, ident.symbol); sym != nil && emit_lifecycle(e, sym.type).managed {
					kill_place(e, ident.symbol)
				}
			}
		}
	}
	emit_epilogue(e)
}

@(private)
emit_epilogue :: proc(e: ^Emitter) {
	drain_temporaries(e, 0)
	run_cleanups(e, 0)
	emit_unwind_pop(e)
	if e.abi_foreign {
		emit_foreign_return(e)
		e.terminated = true
		return
	}
	if e.result_type == INVALID_TYPE {
		fmt.sbprintln(&e.b, "  ret void")
		e.terminated = true
		return
	}
	slot_type := e.result_inout ? "ptr" : llvm_type(e, e.result_type)
	value := load(e, slot_type, e.result_slot)
	fmt.sbprintfln(&e.b, "  ret %s %s", slot_type, value)
	e.terminated = true
}

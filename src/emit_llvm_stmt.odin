// Statement control flow, local bindings, assignment, and returns.
package lokec

import "core:fmt"

// -------------------------------------------------------------- statements --

@(private)
emit_scoped_block :: proc(e: ^Emitter, b: ^Block) {
	push_scope(e, b)
	emit_block_statements(e, b)
	if b != nil {
		debug_mark_end(e, b.span)
	}
	pop_scope(e)
}

@(private = "file")
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
			place_label(e, new_label(e, "unreachable"))
		}
		// A block statement's full-expression boundary, which also holds an initial
		// statement's temporaries; a loop update declares its own.
		push_temporaries(e)
		emit_stmt(e, stmt)
		pop_temporaries(e)
	}
}

@(private)
emit_stmt :: proc(e: ^Emitter, stmt: Stmt) {
	debug_mark_location(e, stmt_span(stmt))
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
		entry := Deferred{kind = .Written, flag = e.defer_flags[s.slot], stmt = s.stmt, on_failure = s.on_failure}
		unwind_reserve(e, &entry)
		e.unwind.slot_by_defer[s.slot] = entry.slot
		fmt.sbprintfln(&e.b, "  store i1 true, ptr %s", e.defer_flags[s.slot])
		unwind_register(e, entry)
		append(&e.cleanups[len(e.cleanups) - 1], entry)

	case ^Stmt_Return:
		emit_return_values(e, s)

	case ^Stmt_Branch:
		// This path owes what it leaves inside the loop. The statement holding the
		// loop owes the rest, since the loop's exit still falls through to its end.
		drain_temporaries(e, e.loop_frames, e.loop_held)
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
		emit_block_statements(e, s.selected)

	case ^Stmt_Foreach:
		if s.kind == .Unresolved {
			backend_fail(e, "an unresolved statement reached emission")
			return
		}
		emit_foreach(e, s)

	case ^Stmt_Parallel:
		if s.lowered == nil {
			backend_fail(e, "an unchecked `parallel` block reached emission")
			return
		}
		emit_scoped_block(e, s.lowered)

	case ^Stmt_Spawn:
		emit_spawn(e, s)
	}
}

// compiler-architecture.md "Lowering parallel blocks": the parent evaluates a
// procedure value it calls, then the callee's arguments in their order, into a
// frame from the default allocator, which the task's `run` takes apart and
// frees. A value the task owns is held
// for the unwind until `start` has handed the frame to a thread, so a failure
// to start drops it on the parent.
@(private = "file")
emit_spawn :: proc(e: ^Emitter, s: ^Stmt_Spawn) {
	task := s.task
	call, is_call := s.call.(^Expr_Call)
	if task == nil || !is_call {
		backend_fail(e, "an unchecked `spawn` reached emission")
		return
	}
	proc_type := call_proc_type(e.c, call)
	callee_type := underlying_info(e.c, proc_type)
	if type_of(e.c, task.frame) == nil || callee_type == nil {
		backend_fail(e, "a `spawn` has no frame")
		return
	}
	frame := emit_spawn_frame(e, task)
	unclaimed := begin_frame_release(e, task.frame, frame)
	if task.through_value {
		field := spawn_field_address(e, task.frame, frame, spawn_callee_field(task))
		store(e, proc_type, emit_expr(e, call.callee), field)
	}
	owned := emit_spawn_arguments(e, task, call, callee_type, frame)
	if task.result != INVALID_SYMBOL {
		field := spawn_field_address(e, task.frame, frame, spawn_result_field(task))
		fmt.sbprintfln(&e.b, "  store ptr %s, ptr %s", e.names[task.result], field)
	}
	fmt.sbprintfln(
		&e.b, "  call void %s(ptr %s, ptr %s, ptr %s)",
		symbol_name(e, task.start), e.names[task.scope], symbol_name(e, task.run), frame,
	)
	// The task has the frame now, and what it owns is its to drop.
	finish_temporary_drop(e, unclaimed)
	for entry in owned {
		finish_temporary_drop(e, entry)
	}
	// compiler-architecture.md "Lowering parallel blocks": a registered task
	// completes before the join, so the result is initialized from here, for
	// its enclosing scope's cleanup on every exit.
	if task.result != INVALID_SYMBOL {
		revive_place(e, s.result)
	}
}

@(private = "file")
spawn_field_address :: proc(e: ^Emitter, record: Type_Id, address: string, field: int) -> string {
	index := int(symbol_of(e.c, type_of(e.c, record).fields[field]).index)
	return gep_field(e, llvm_type(e, record), address, index)
}

@(private = "file")
emit_spawn_frame :: proc(e: ^Emitter, task: ^Spawn_Task) -> string {
	allocator := emit_default_allocator(e)
	frame, failed := emit_rt_alloc(e, allocator, type_size(e.c, task.frame), type_align(e.c, task.frame))
	fail_label, ok_label := new_label(e, "spawn.no_frame"), new_label(e, "spawn.frame")
	branch_if(e, failed, fail_label, ok_label)
	place_label(e, fail_label)
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_alloc_failed(ptr %s)", allocator)
	fmt.sbprintln(&e.b, "  unreachable")
	e.terminated = true
	place_label(e, ok_label)
	return frame
}

// The callee's arguments, each stored in the frame. Returns what the task owns,
// held until the frame is handed over.
@(private = "file")
emit_spawn_arguments :: proc(
	e: ^Emitter, task: ^Spawn_Task, call: ^Expr_Call, callee_type: ^Type_Info, frame: string,
) -> (owned: [dynamic]Deferred) {
	// A procedure value has no declaration: its call supplies every argument.
	callee := task.through_value ? nil : symbol_of(e.c, call.resolution.symbol)
	scope := begin_default_scope(e, callee)
	defer end_default_scope(e, &scope)
	for step in 0 ..< len(call.bound) {
		index := call_slot_at(call, step)
		argument := call.bound[index]
		type := callee_type.parameters[index]
		enter_default_scope(e, &scope, index, argument)
		field := spawn_field_address(e, task.frame, frame, spawn_argument_field(index))
		if call_packs(call, index) {
			pack := symbol_of(e.c, type_of(e.c, task.frame).fields[spawn_argument_field(index)]).type
			emit_spawn_pack(e, task, call, type, pack, field, &owned)
			continue
		}
		bound: string
		switch task.kinds[index] {
		case .Address:
			address := emit_address(e, argument)
			fmt.sbprintfln(&e.b, "  store ptr %s, ptr %s", address, field)
			mode := index < len(callee_type.param_modes) ? callee_type.param_modes[index] : Param_Mode.Value
			bound = param_mode_is_pointer(mode) ? address : load_place(e, type, address)
		case .Copy:
			bound = emit_expr(e, argument)
			store(e, type, bound, field)
		case .Owned:
			// A place here is in a temporary the parent drops, so the task gets a copy.
			bound = emit_copied_expr(e, argument, type, expression_is_borrowed_place(argument))
			append(&owned, hold_temporary_value(e, type, bound))
			store(e, type, bound, field)
		}
		bind_default_scope(e, &scope, index, bound)
	}
	return
}

// design.md "Spawn statements": a variadic pack's operands, evaluated in their
// written order into the frame's pack record. An element is copied as the pack
// would copy it, and one the task owns is held for the unwind like any owned
// argument; a spread stores the `[]T` it views.
@(private = "file")
emit_spawn_pack :: proc(
	e: ^Emitter, task: ^Spawn_Task, call: ^Expr_Call, slice, pack: Type_Id, record: string, owned: ^[dynamic]Deferred,
) {
	element := slice_element(e.c, slice)
	managed := emit_lifecycle(e, element).managed
	next_element, next_spread := 0, 0
	for is_spread, position in call.variadic_order {
		slot := spawn_field_address(e, pack, record, position)
		if is_spread {
			store(e, slice, emit_expr(e, call.variadic_spreads[next_spread]), slot)
			next_spread += 1
			continue
		}
		expr := call.variadic_elements[next_element]
		next_element += 1
		value := emit_copied_expr(e, expr, element, managed && expression_is_borrowed_place(expr))
		if task.pack[position] == .Owned {
			append(owned, hold_temporary_value(e, element, value))
		}
		store(e, element, value, slot)
	}
}

@(private = "file")
emit_local_decl :: proc(e: ^Emitter, d: ^Decl) {
	if d.destructure.active && d.duration == .None {
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
		clones := i < len(d.value_clones) && d.value_clones[i]
		if is_large_value(e, sym.type) && !clones && expression_is_borrowed_place(d.values[i]) {
			// Nothing runs between reading the place and writing the new local.
			copy_bytes(e, slot, emit_address(e, d.values[i]), type_size(e.c, sym.type))
		} else {
			value := emit_copied_expr(e, d.values[i], sym.type, clones, destination = symbol_id)
			store(e, sym.type, value, slot)
		}
		// An empty literal has no allocator of its own, so a written `via` binds.
		if composite, empty_literal := d.values[i].(^Expr_Composite); empty_literal && len(composite.elements) == 0 {
			emit_eager_via_binding(e, symbol_id, slot)
		}
		register_implicit_drop(e, symbol_id)
	}
}

// design.md "Destructuring": the operand is evaluated once. From a place,
// retained managed fields are cloned (with each destination's allocator); a
// consumed record's fields transfer. Every owned field is guarded until bound.
@(private = "file")
emit_destructure_fields :: proc(
	e: ^Emitter, plan: ^Destructure, operand: Expr, destinations: []Symbol_Id,
) -> (values: []string, guards: []Deferred) {
	record := emit_expr(e, operand)
	values = make([]string, len(plan.fields))
	guards = make([]Deferred, len(plan.fields))
	for field_id, index in plan.fields {
		field := symbol_of(e.c, field_id)
		// A padding field fills no binding, so the field's own slot is read.
		value := record_part(e, plan.record, record, int(field.index))
		clones := plan.retained[index] && index < len(plan.clones) && plan.clones[index]
		if clones {
			value = emit_clone_value(e, field.type, value, emit_destination_allocator(e, destinations[index]))
		}
		values[index] = value
		if !plan.from_place || clones {
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
		if !plan.retained[index] {
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
		slot := declare_local(e, symbol_id)
		if slot == "" {
			continue
		}
		store(e, symbol_of(e.c, plan.fields[index]).type, values[index], slot)
		register_implicit_drop(e, symbol_id)
		finish_temporary_drop(e, guards[index])
	}
	emit_destructure_discards(e, plan, guards)
}

@(private = "file")
emit_destructure_assign :: proc(e: ^Emitter, s: ^Stmt_Assign) {
	plan := &s.destructure
	roots := make([]Symbol_Id, len(plan.fields))
	for target, index in s.lhs {
		roots[index] = place_root_symbol(target)
	}
	values, guards := emit_destructure_fields(e, plan, s.rhs[0], roots)
	destinations := emit_destinations(e, s.lhs)
	for target, index in s.lhs {
		if is_discard(target) {
			continue
		}
		// design.md "Destructuring": a field is cloned or transferred at its own
		// type, and a narrower union then widens to its destination's.
		type, value := symbol_of(e.c, plan.fields[index]).type, values[index]
		if wider := expr_base(target).type; union_widens_to(e.c, type, wider) {
			type, value = wider, emit_union_widen(e, value, type, wider)
		}
		emit_destination_write(e, s, destinations, index, type, value, guards[index])
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
	if s.lowered != nil {
		emit_scoped_block(e, s.lowered)
		return
	}
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
	// A value waiting for its write is held for the unwind: a map insertion's
	// while later keys are evaluated, and with several destinations each one's
	// while an earlier write drops what it replaced.
	guards := make([]Deferred, len(s.rhs))
	for value, index in s.rhs {
		target := s.lhs[index]
		type := expr_base(target).type
		clones := index < len(s.rhs_clones) && s.rhs_clones[index]
		values[index] = emit_copied_expr(e, value, type, clones, destination = place_root_symbol(target))
		if inserting_map_index(target) != nil || (len(s.lhs) > 1 && !is_discard(target)) {
			guards[index] = hold_temporary_value(e, type, values[index])
		}
	}
	destinations := emit_destinations(e, s.lhs)
	for target, index in s.lhs {
		if is_discard(target) {
			emit_discarded_temporary(e, s.rhs[index], values[index])
			continue
		}
		emit_destination_write(e, s, destinations, index, expr_base(target).type, values[index], guards[index])
	}
}

// Where each write of an assignment goes: `addresses` for a place, `inserting`
// for `m[key] = elem`, and neither for a `_`.
@(private = "file")
Assign_Destinations :: struct {
	addresses: []string,
	inserting: []Map_Assignment_Destination,
}

@(private = "file")
emit_destinations :: proc(e: ^Emitter, targets: []Expr) -> Assign_Destinations {
	out := Assign_Destinations{make([]string, len(targets)), make([]Map_Assignment_Destination, len(targets))}
	for target, index in targets {
		if is_discard(target) {
			continue
		}
		if entry := inserting_map_index(target); entry != nil {
			out.inserting[index] = prepare_map_assignment(e, entry, len(targets) > 1)
			continue
		}
		out.addresses[index] = emit_address(e, target)
	}
	return out
}

@(private = "file")
emit_destination_write :: proc(
	e: ^Emitter, s: ^Stmt_Assign, destinations: Assign_Destinations, index: int, type: Type_Id, value: string, guard: Deferred,
) {
	if inserting_map_index(s.lhs[index]) != nil {
		emit_map_insert_store(e, destinations.inserting[index], value, guard)
		return
	}
	emit_replacing_store(e, s, index, type, value, destinations.addresses[index], guard)
}

// A destination's old value, moved aside by a write; `live` is the `i1` saying
// whether there was one, or "" when the checker knows there was.
@(private = "file")
Displaced :: struct {
	type:  Type_Id,
	aside: string,
	live:  string,
}

// design.md "What the unwind runs, and what it does not": the old value is
// moved aside, the replacement stored, and only then the old value dropped.
// The destination's cleanup owns the replacement before the drop hook runs, so
// a panicking hook unwinds through the replacement once and never replays the
// old value.
@(private = "file")
emit_replacing_store :: proc(
	e: ^Emitter, s: ^Stmt_Assign, index: int, type: Type_Id, value, address: string, guard := Deferred{},
) {
	displaced := displace_place(e, s, index, address)
	store(e, type, value, address)
	revive_place(e, s.lhs[index])
	finish_temporary_drop(e, guard)
	drop_displaced(e, displaced)
}

@(private = "file")
displace_place :: proc(e: ^Emitter, s: ^Stmt_Assign, index: int, address: string) -> Displaced {
	target := s.lhs[index]
	type := expr_base(target).type
	if !emit_lifecycle(e, type).managed {
		return {}
	}
	symbol := INVALID_SYMBOL
	if ident, is_ident := target.(^Expr_Ident); is_ident {
		symbol = ident.symbol
	}
	out := Displaced{type = type}
	state := index < len(s.destination_live) ? s.destination_live[index] : Liveness.Live
	if state != .Dead {
		if state != .Live && drop_flag_of(e, symbol) != "" {
			out.live = load(e, "i1", unwind_flag_address(e, symbol))
		}
		out.aside = alloca(e, llvm_type(e, type))
		copy_bytes(e, out.aside, address, type_size(e.c, type))
	}
	return out
}

@(private = "file")
drop_displaced :: proc(e: ^Emitter, displaced: Displaced) {
	if displaced.aside == "" {
		return
	}
	if displaced.live == "" {
		emit_drop_place(e, displaced.type, displaced.aside)
		return
	}
	run, skip := new_label(e, "replace.drop"), new_label(e, "replace.done")
	branch_if(e, displaced.live, run, skip)
	place_label(e, run)
	emit_drop_place(e, displaced.type, displaced.aside)
	branch(e, skip)
	place_label(e, skip)
}

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
		address := emit_address(e, target)
		value := emit_operator_call(e, s.operator, operands[:], left_place = address)
		emit_replacing_store(e, s, 0, type, value, address)
		return
	}
	// design.md "Evaluation order": the destination is read after the right operand.
	address := emit_address(e, target)
	rhs := emit_expr(e, s.rhs[0])
	current := load_place(e, type, address)
	op := compound_operator(s.op)
	result: string
	if type_is_simd(e.c, type) {
		result = emit_simd_binary_values(e, op, type, current, type, rhs, expr_base(s.rhs[0]).type)
	} else {
		result = emit_binary_op(e, op, type, expr_base(s.rhs[0]).type, current, rhs)
	}
	store(e, type, result, address)
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

// The scope of an `if`, `for` or `switch` header, holding what its initial
// statement declares.
@(private = "file")
push_init_scope :: proc(e: ^Emitter, init: Stmt) {
	push_scope(e, nil)
	if init != nil {
		emit_stmt(e, init)
	}
}

@(private = "file")
emit_if :: proc(e: ^Emitter, s: ^Stmt_If) {
	push_init_scope(e, s.init)
	debug_mark_location(e, expr_span(s.cond))
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
		// An `else if` is a statement of its own, so its initial statement's
		// temporaries end with it, on this path only.
		push_temporaries(e)
		emit_stmt(e, s.otherwise)
		pop_temporaries(e)
		branch(e, done_label)
	}
	place_label(e, done_label)
	debug_mark_end(e, s.span)
	pop_scope(e)
}

@(private = "file")
emit_for :: proc(e: ^Emitter, s: ^Stmt_For) {
	outer_break, outer_continue := e.break_label, e.continue_label
	outer_break_depth, outer_continue_depth := e.break_depth, e.continue_depth
	outer_frames, outer_held := e.loop_frames, e.loop_held
	defer {
		e.break_label, e.continue_label = outer_break, outer_continue
		e.break_depth, e.continue_depth = outer_break_depth, outer_continue_depth
		e.loop_frames, e.loop_held = outer_frames, outer_held
	}

	push_init_scope(e, s.init)

	head := new_label(e, "for.head")
	body := new_label(e, "for.body")
	post := new_label(e, "for.post")
	done := new_label(e, "for.done")
	// `break` lands in the loop's own scope, whose exit disposes of what the
	// initial statement declared once.
	e.break_label, e.continue_label = done, post
	e.break_depth, e.continue_depth = len(e.cleanups), len(e.cleanups)
	e.loop_frames, e.loop_held = len(e.temporaries), len(e.held)

	place_label(e, head)
	if s.cond != nil {
		debug_mark_location(e, expr_span(s.cond))
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
	debug_mark_end(e, s.span)
	pop_scope(e)
}

// ponytail: one ordered comparison chain rather than an LLVM `switch` for the
// all-constant case — ranges and non-constant cases need the chain anyway, and a
// second lowering would have to agree with this one about source order. Add a
// jump table when a measured switch is hot.
@(private = "file")
emit_switch :: proc(e: ^Emitter, s: ^Stmt_Switch) {
	push_init_scope(e, s.init)
	debug_mark_location(e, expr_span(s.subject))
	subject_type := expr_base(s.subject).type
	// design.md "Temporaries and procedure boundaries": a produced subject lives
	// until the statement ends.
	subject := emit_borrowed_operand(e, s.subject)
	done := new_label(e, "switch.done")
	bodies, tests, order, fallback := switch_labels(e, s, "case", done)
	closed_fallback := fallback == done && s.exhaustive
	if closed_fallback {
		fallback = new_label(e, "switch.invalid")
	}

	branch(e, len(order) > 0 ? tests[order[0]] : fallback)
	for case_index, position in order {
		place_label(e, tests[case_index])
		next := position + 1 < len(order) ? tests[order[position + 1]] : fallback
		values := s.cases[case_index].values
		// design.md "switch statement": testing stops at the first match. Each test
		// is a complete expression, since the next may not run.
		for value, value_index in values {
			push_temporaries(e)
			matched := emit_case_test(e, subject, subject_type, value)
			pop_temporaries(e)
			if value_index == len(values) - 1 {
				branch_if(e, matched, bodies[case_index], next)
			} else {
				more := new_label(e, "case.more")
				branch_if(e, matched, bodies[case_index], more)
				place_label(e, more)
			}
		}
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
	debug_mark_end(e, s.span)
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

// A type switch dispatches on a union's tag. A case binds at the variant's
// type, or at the subject's type for several or default.
// A union argument expansion's switch also yields the value of the arm that ran,
// at `result` (design.md "Union argument expansion").
@(private)
emit_type_switch :: proc(e: ^Emitter, s: ^Stmt_Switch, result := TYPE_VOID) -> string {
	push_init_scope(e, s.init)
	debug_mark_location(e, expr_span(s.subject))
	union_type := expr_base(s.subject).type
	// Over an addressable place a case binds the payload, or its fields, in the
	// subject's own storage (design.md "Switch ownership").
	place := ""
	if switch_binds_place(s) || binds_subject_storage(e, s) {
		place = emit_address(e, s.subject)
	}
	value := place != "" ? load_place(e, union_type, place) : emit_expr(e, s.subject)
	tag_llvm := fmt.aprintf("i%d", union_layout(e.c, union_type).tag_bytes * 8)
	slot := emit_union_spill(e, union_type, value)
	tag := emit_union_tag(e, union_type, value)
	// A produced subject is the switch's to drop; a named place is borrowed.
	consumes := !expression_is_borrowed_place(s.subject)
	joined := result != TYPE_VOID && result != INVALID_TYPE ? temporary_slot(e, result) : ""
	done := new_label(e, "typeswitch.done")
	bodies, tests, order, fallback := switch_labels(e, s, "typecase", done)

	branch(e, len(order) > 0 ? tests[order[0]] : fallback)
	for case_index, position in order {
		place_label(e, tests[case_index])
		next := position + 1 < len(order) ? tests[order[position + 1]] : fallback
		matched := ""
		entry := s.cases[case_index]
		for discriminant in entry.variant_indices {
			test := temp(e)
			fmt.sbprintfln(&e.b, "  %s = icmp eq %s %s, %d", test, tag_llvm, tag, discriminant)
			matched = or_match(e, matched, test)
		}
		branch_if(e, matched, bodies[case_index], next)
	}

	for entry, index in s.cases {
		place_label(e, bodies[index])
		push_scope_stmts(e, entry.stmts)
		if len(entry.fields) > 0 {
			emit_case_fields(e, entry, union_type, place, slot, consumes)
		} else if place != "" && names_storage(e, entry.binding_symbol) {
			bind_local(e, entry.binding_symbol, gep_field(e, llvm_type(e, union_type), place, 0))
		} else {
			emit_type_case_binding(e, entry, union_type, value, slot)
		}
		// A consumed payload drops with the binding, or with the case if unbound.
		if consumes && len(entry.fields) == 0 {
			if entry.binding_symbol != INVALID_SYMBOL {
				register_implicit_drop(e, entry.binding_symbol)
			} else {
				register_scope_place(e, union_type, slot)
			}
		}
		emit_statements(e, entry.stmts)
		if entry.arm != nil {
			// Its temporaries end with the enclosing full expression, if this arm ran.
			begin_conditional(e)
			yielded := emit_expr(e, entry.arm)
			end_conditional(e)
			if joined != "" && !e.terminated {
				store(e, result, yielded, joined)
			}
		}
		pop_scope(e)
		branch(e, done)
	}

	place_label(e, done)
	debug_mark_end(e, s.span)
	pop_scope(e)
	if joined == "" {
		return ""
	}
	return load_temporary(e, result, joined)
}

// A binding's own storage, for a value it holds rather than a place it names.
@(private = "file")
declare_case_binding :: proc(e: ^Emitter, symbol: Symbol_Id, type: Type_Id) -> string {
	binding := fmt.aprintf("%%bind.%d", next_id(e))
	alloca_named(e, binding, llvm_type(e, type))
	bind_local(e, symbol, binding)
	return binding
}

@(private = "file")
emit_type_case_binding :: proc(e: ^Emitter, entry: Switch_Case, union_type: Type_Id, value, slot: string) {
	if entry.binding_symbol == INVALID_SYMBOL {
		return
	}
	binding := declare_case_binding(e, entry.binding_symbol, entry.binding_type)
	if entry.binding_type == union_type {
		store(e, union_type, value, binding)
		return
	}
	store(e, entry.binding_type, emit_union_payload(e, union_type, entry.binding_type, slot), binding)
}

// A binding over a place names the subject's storage unless that storage is a
// packed field, which cannot be borrowed (design.md "@(packed)").
@(private = "file")
names_storage :: proc(e: ^Emitter, symbol: Symbol_Id) -> bool {
	sym := symbol_of(e.c, symbol)
	return sym != nil && sym.borrowed_binding == .Switch_Payload && sym.packed_field == ""
}

@(private = "file")
binds_subject_storage :: proc(e: ^Emitter, s: ^Stmt_Switch) -> bool {
	if !expr_base(s.subject).addressable {
		return false
	}
	for entry in s.cases {
		if names_storage(e, entry.binding_symbol) {
			return true
		}
		for field in entry.fields {
			if names_storage(e, field.symbol) {
				return true
			}
		}
	}
	return false
}

// design.md "Inspecting a union": over a place each field binding names its
// field of the stored payload. A consumed payload is taken apart: a retained
// field moves into its binding, which drops it, and a discarded one drops with
// the case.
@(private = "file")
emit_case_fields :: proc(e: ^Emitter, entry: Switch_Case, union_type: Type_Id, place, slot: string, consumes: bool) {
	storage := llvm_type(e, union_type)
	for field in entry.fields {
		if !consumes {
			if field.symbol == INVALID_SYMBOL {
				continue
			}
			// A packed field, or a subject with no address, is read from the copy.
			from := place != "" && names_storage(e, field.symbol) ? place : slot
			bind_local(e, field.symbol, element_address(e, entry.binding_type, gep_field(e, storage, from, 0), field.slot))
			continue
		}
		address := element_address(e, entry.binding_type, gep_field(e, storage, slot, 0), field.slot)
		if field.symbol == INVALID_SYMBOL {
			register_scope_place(e, field.type, address)
			continue
		}
		binding := declare_case_binding(e, field.symbol, field.type)
		store(e, field.type, load_place(e, field.type, address), binding)
		register_implicit_drop(e, field.symbol)
	}
}

@(private = "file")
emit_case_test :: proc(e: ^Emitter, subject: string, subject_type: Type_Id, value: Expr) -> string {
	if range, is_range := value.(^Expr_Range); is_range {
		lo := emit_borrowed_operand(e, range.lo)
		hi := emit_borrowed_operand(e, range.hi)
		low_ok := emit_compare(e, .Gt_Eq, subject_type, subject, lo)
		high_op := range.op == .Range_Excl ? Token_Kind.Lt : Token_Kind.Lt_Eq
		high_ok := emit_compare(e, high_op, subject_type, subject, hi)
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = and i1 %s, %s", out, low_ok, high_ok)
		return out
	}
	return emit_equal(e, subject_type, subject, emit_borrowed_operand(e, value))
}

// ----------------------------------------------------------------- returns --

// The result is stored before any cleanup runs, so a `defer` cannot change it.
@(private = "file")
emit_return_values :: proc(e: ^Emitter, s: ^Stmt_Return) {
	if s.value != nil && e.result_slot != "" {
		value := s.value
		if e.result_inout {
			// An `inout` result hands back the place itself, not a copy of it, and
			// the place stays live.
			fmt.sbprintfln(&e.b, "  store ptr %s, ptr %s", emit_address(e, value.expr), e.result_slot)
		} else {
			store(e, e.result_type, emit_copied_expr(e, value.expr, e.result_type, value.clone_on_return), e.result_slot)
			// A returned local transferred out, so cleanup must not drop it. A view
			// of it transfers nothing, and a borrowed binding names storage its
			// subject still owns (design.md "Switch ownership").
			if !value.clone_on_return && emit_lifecycle(e, e.result_type).managed {
				if ident, is_ident := value.expr.(^Expr_Ident); is_ident && expression_is_borrowed_place(ident) {
					if sym := symbol_of(e.c, ident.symbol); sym != nil && sym.borrowed_binding == .None &&
					   emit_lifecycle(e, sym.type).managed {
						kill_place(e, ident.symbol)
					}
				}
			}
		}
	}
	emit_epilogue(e)
}

// Whether the result being returned is the failure variant, when an `errdefer`
// is registered to ask; "" otherwise.
@(private = "file")
returned_failure :: proc(e: ^Emitter) -> string {
	if e.result_slot == "" || e.result_inout || !type_is_union(e.c, e.result_type) {
		return ""
	}
	pending := false
	for scope in e.cleanups {
		for entry in scope {
			pending ||= entry.on_failure
		}
	}
	if !pending {
		return ""
	}
	union_type := type_underlying(e.c, e.result_type)
	return emit_union_failed(e, union_type, load_temporary(e, union_type, e.result_slot))
}

@(private)
emit_epilogue :: proc(e: ^Emitter) {
	defer e.terminated = true
	drain_temporaries(e, 0, 0)
	run_cleanups(e, 0, returned_failure(e))
	emit_unwind_pop(e)
	if e.abi_foreign {
		emit_foreign_return(e)
		return
	}
	if e.result_type == INVALID_TYPE || returns_sret(e, e.result_type, e.result_inout) {
		fmt.sbprintln(&e.b, "  ret void")
		return
	}
	slot_type := e.result_inout ? "ptr" : llvm_type(e, e.result_type)
	value := load(e, slot_type, e.result_slot)
	fmt.sbprintfln(&e.b, "  ret %s %s", slot_type, value)
}

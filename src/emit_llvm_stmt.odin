// Statement control flow, local bindings, assignment, and returns.
//
// Part of the textual LLVM backend; see compiler-architecture.md.
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

// Unreachable code still needs a block to live in, or LLVM rejects the
// instructions after a terminator — switch case bodies have the same problem,
// so both go through here.
@(private = "file")
emit_statements :: proc(e: ^Emitter, stmts: []Stmt) {
	for stmt in stmts {
		if e.terminated {
			fmt.sbprintfln(&e.b, "unreachable.%d:", next_id(e))
			e.terminated = false
		}
		// The full-expression boundary of a statement written in a block. A
		// statement reached any other way — an initial statement, a loop update —
		// declares its own boundary where that construct decides it, which is why
		// this is here rather than in `emit_stmt`.
		push_temporaries(e)
		emit_stmt(e, stmt)
		pop_temporaries(e)
	}
}

@(private)
emit_stmt :: proc(e: ^Emitter, stmt: Stmt) {
	switch s in stmt {
	case ^Stmt_Error:

	case ^Decl:
		emit_local_decl(e, s)

	case ^Stmt_Expr:
		for expr in s.exprs {
			// `static_assert` is checked at compile time and has no runtime cost —
			// nothing here to emit.
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
		// Whatever the enclosing statement still holds is owed on this path too:
		// a frame opened by an initial statement outlives the body that breaks.
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
		// Structural selection: the checker-chosen branch is emitted in place with no
		// scope of its own — its declarations and `defer`s belong to the surrounding block.
		emit_block_statements(e, when_selected_block(s))

	case ^Stmt_Foreach:
		if s.kind == .Unresolved {
			// The checker's L0350 arm gates every statement missing here — reaching
			// this is a hole in that gate, silently emitting less than the source says.
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
		// Constants are folded at every use, so they need no storage.
		if sym == nil || sym.kind != .Var {
			continue
		}
		// Static-duration storage was emitted at module level and initialised
		// before any code ran, so reaching the declaration writes nothing.
		if sym.duration != .None {
			continue
		}
		slot := declare_local(e, symbol_id)
		// design.md "Variable declarations": a local with no initializer, and one
		// written `= ---`, both start dead. Nothing is written to the storage —
		// not even a zero — and a later full assignment initializes it.
		if i >= len(d.values) || d.values[i] == nil {
			// design.md "Managed values and storage": the declaration allocation
			// policy is retained while dead, so a written `via` still binds here.
			emit_eager_via_binding(e, symbol_id, slot)
			register_implicit_drop(e, symbol_id, live = false)
			continue
		}
		value := emit_expr(e, d.values[i])
		if i < len(d.value_clones) && d.value_clones[i] {
			value = emit_clone_value(e, sym.type, value, emit_destination_allocator(e, symbol_id))
		}
		store(e, sym.type, value, slot)
		// design.md "Allocators": a written `via` is *eager*, selected at the
		// declaration. `x: T via a = {}` is the zero the declaration used to get
		// implicitly, and an empty container literal writes no allocator of its
		// own, so the policy binds here. A value that arrives already owning
		// storage keeps the allocator it was built with.
		if composite, empty_literal := d.values[i].(^Expr_Composite); empty_literal && len(composite.elements) == 0 {
			emit_eager_via_binding(e, symbol_id, slot)
		}
		register_implicit_drop(e, symbol_id)
	}
}

// design.md "Exchange": the destination is evaluated once, then `replacement`
// fully evaluated before it's touched, so a failure or panic leaves the
// destination unchanged. Order is address, replacement, load, store — the old
// value moves to result storage and the replacement moves in as one lifecycle
// operation. No hook runs between the two moves, so the old value is handed
// back rather than dropped, and the destination is never observably dead.
@(private)
emit_exchange :: proc(e: ^Emitter, v: ^Expr_Call, as_type: Type_Id) -> string {
	address := emit_address(e, v.bound[0])
	replacement := emit_expr(e, v.bound[1])
	previous := load(e, llvm_type(e, as_type), address)
	store(e, as_type, replacement, address)
	return previous
}

// `move` transfers the representation, zeroes the lexical source, and marks it
// dead (design.md "Assignment statements").
@(private)
emit_move :: proc(e: ^Emitter, v: ^Expr_Move) -> string {
	value := emit_expr(e, v.value)
	if ident, is_ident := v.value.(^Expr_Ident); is_ident {
		kill_place(e, ident.symbol)
	}
	return value
}

// design.md "Destructuring": the operand is evaluated once, then each field is
// projected out. Place path: a retained managed field is cloned, source stays
// live. Consuming path: fields transfer; each discarded field drops once, in
// reverse declaration order, after every retained field is bound.
@(private = "file")
emit_destructure_fields :: proc(
	e: ^Emitter,
	plan: ^Destructure,
	operand: Expr,
	// The destination root of each binding, so a cloned field uses that
	// destination's written `via` allocator like an ordinary binding does.
	// INVALID_SYMBOL falls back to the default provider.
	destinations: []Symbol_Id,
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
				e, field.type, value, emit_destination_allocator(e, destinations[index]),
			)
		}
		values[index] = value
		// A successful clone must survive a later clone failing. On the consuming path
		// every managed field is already ours, so guard retained and discarded fields
		// before any user drop can unwind through this statement.
		if !plan.from_place || (retained && index < len(plan.clones) && plan.clones[index]) {
			guards[index] = hold_temporary_value(e, field.type, value)
		}
	}
	return
}

// The discarded fields of a consumed record. A cloning destructure took nothing
// from them, so only the consuming path owes them a drop, in reverse declaration
// order and after every retained binding is published — so a drop that panics
// cannot leave a half-bound statement behind.
@(private = "file")
emit_destructure_discards :: proc(e: ^Emitter, plan: ^Destructure, guards: []Deferred) {
	if plan.from_place {
		return
	}
	#reverse for field_id, index in plan.fields {
		if index < len(plan.retained) && plan.retained[index] {
			continue
		}
		field := symbol_of(e.c, field_id)
		if field == nil {
			continue
		}
		drop_temporary_value(e, guards[index])
	}
}

@(private = "file")
emit_destructure_decl :: proc(e: ^Emitter, d: ^Decl) {
	plan := &d.destructure
	destinations := make([]Symbol_Id, len(plan.fields))
	for symbol_id, index in d.symbols {
		destinations[index] = symbol_id
	}
	values, guards := emit_destructure_fields(e, plan, d.values[0], destinations)
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
		destinations[index] = place_root_symbol(e.c, target)
	}
	values, guards := emit_destructure_fields(e, plan, s.rhs[0], destinations)
	// design.md "Assignment statements": every value is prepared, then every
	// destination address, then the writes happen.
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
		// A destructured half lands in a map entry the same way a whole value
		// does: `m[key] = elem` commits its value rather than taking an address.
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

// design.md "Assignment statements": every right side is evaluated, then every
// destination address is computed, before anything is written.
@(private = "file")
emit_assign :: proc(e: ^Emitter, s: ^Stmt_Assign) {
	if s.op != .Assign {
		emit_compound_assign(e, s)
		return
	}
	// `operator([]=)`: a container with no location to hand out.
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
		// design.md: the clone happens before the destination is touched, so a
		// failure leaves a previously live destination unchanged.
		if index < len(s.rhs_clones) && s.rhs_clones[index] {
			values[index] = emit_clone_value(
				e, expr_base(s.lhs[index]).type, values[index],
				emit_destination_allocator(e, place_root_symbol(e.c, s.lhs[index])),
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
		// design.md "Maps": `m[key] = elem` writes the whole element, so it is an
		// insertion rather than a store into an address — an absent key has no
		// slot to take one from until the value is committed.
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
	}
}

// design.md "Assignment statements": `drop(destination)` runs between a successful
// clone and the write, gated by destination state — a definitely dead one holds
// nothing, a conditional one checks its hidden flag.
@(private = "file")
emit_replace_place :: proc(e: ^Emitter, s: ^Stmt_Assign, index: int, address: string) {
	target := s.lhs[index]
	type := expr_base(target).type
	if !emit_lifecycle(e, type).managed {
		return
	}
	state := index < len(s.destination_live) ? s.destination_live[index] : Liveness.Live
	if state == .Dead {
		return
	}
	flag := ""
	if ident, is_ident := target.(^Expr_Ident); is_ident {
		flag = drop_flag_of(e, ident.symbol)
	}
	if state == .Live || flag == "" {
		emit_drop_place(e, type, address)
	} else {
		live := load(e, "i1", flag)
		run, skip := new_label(e, "replace.drop"), new_label(e, "replace.done")
		branch_if(e, live, run, skip)
		place_label(e, run)
		emit_drop_place(e, type, address)
		branch(e, skip)
		place_label(e, skip)
	}
	// The place holds a value again from here.
	if _, is_ident := target.(^Expr_Ident); is_ident && flag != "" {
		fmt.sbprintfln(&e.b, "  store i1 true, ptr %s", flag)
	}
}

// The destination is evaluated once, before the right operand.
@(private = "file")
emit_compound_assign :: proc(e: ^Emitter, s: ^Stmt_Assign) {
	target := s.lhs[0]
	if s.operator != INVALID_SYMBOL {
		operands := [2]Expr{target, s.rhs[0]}
		if s.operator_direct {
			// A direct `+=` overload writes through its `inout` destination.
			emit_operator_call(e, s.operator, operands[:])
			return
		}
		// The fallback: the binary operator, then an ordinary assignment.
		address := emit_address(e, target)
		value := emit_operator_call(e, s.operator, operands[:])
		store(e, expr_base(target).type, value, address)
		return
	}
	type := expr_base(target).type
	address := emit_address(e, target)
	current := load(e, llvm_type(e, type), address)
	rhs := emit_expr(e, s.rhs[0])
	op := compound_operator(s.op)
	result: string
	// design.md "SIMD vectors": the operator is lane-wise, so it is the vector
	// path's, not the scalar one's — which would emit an integer mnemonic over
	// float lanes and skip the splat a scalar right operand needs.
	if type_is_simd(e.c, type) {
		result = emit_simd_binary_values(e, op, type, current, type, rhs, expr_base(s.rhs[0]).type)
	} else {
		result = emit_binary_op(e, op, type, expr_base(s.rhs[0]).type, current, rhs)
	}
	store(e, type, result, address)
}

// The destination of `m[key] = elem`, the one assignment target that creates
// its own element instead of naming one.
@(private = "file")
inserting_map_index :: proc(target: Expr) -> ^Expr_Index {
	index, ok := target.(^Expr_Index)
	if !ok || !index.map_inserts {
		return nil
	}
	return index
}

// `_` as a destination: written to nothing, and the value it would have taken
// is dropped instead.
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
	// design.md: the condition's own temporaries end with the condition, before
	// either branch runs.
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
		// Once per evaluation, not once per loop: the storage is one reused
		// alloca, so a boundary outside the head would drop the last iteration's
		// value and leak the rest.
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

	bodies := make([]string, len(s.cases))
	tests := make([]string, len(s.cases))
	for index in 0 ..< len(s.cases) {
		bodies[index] = new_label(e, "case.body")
		tests[index] = new_label(e, "case.test")
	}
	default_index := -1
	for entry, index in s.cases {
		if len(entry.values) == 0 {
			default_index = index
		}
	}

	// Value cases are tested in source order; the default is the fallthrough of
	// the last of them, wherever it was written.
	order := make([dynamic]int)
	defer delete(order)
	for entry, index in s.cases {
		if len(entry.values) > 0 {
			append(&order, index)
		}
	}
	fallback := default_index >= 0 ? bodies[default_index] : done
	closed_fallback := default_index < 0 && s.exhaustive
	if closed_fallback {
		fallback = new_label(e, "switch.invalid")
	}

	branch(e, len(order) > 0 ? tests[order[0]] : fallback)
	for case_index, position in order {
		place_label(e, tests[case_index])
		next := position + 1 < len(order) ? tests[order[position + 1]] : fallback
		matched := ""
		for value in s.cases[case_index].values {
			test := emit_case_test(e, subject, subject_type, value)
			if matched == "" {
				matched = test
			} else {
				combined := temp(e)
				fmt.sbprintfln(&e.b, "  %s = or i1 %s, %s", combined, matched, test)
				matched = combined
			}
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

// A type switch dispatches on the tag. Each case binds its own name: at the
// variant's type where one is known, and at the union's type where a case
// names several types or is the default.
@(private = "file")
emit_type_switch :: proc(e: ^Emitter, s: ^Stmt_Switch) {
	push_scope(e, nil)
	if s.init != nil {
		emit_stmt(e, s.init)
	}
	union_type := expr_base(s.subject).type
	// An `any_view` switch compares the stored `typeid` and reads through the
	// data pointer; a union switch compares its tag and reads its payload.
	erased := union_type == TYPE_ANY_VIEW
	consumes := false
	tag_llvm := "i64"
	value := emit_expr(e, s.subject)
	slot := ""
	tag := ""
	if erased {
		storage := llvm_type(e, TYPE_ANY_VIEW)
		slot = temp(e)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", slot, storage, value, ANY_VIEW_DATA)
		tag = temp(e)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", tag, storage, value, ANY_VIEW_ID)
	} else {
		shape := union_layout(e.c, union_type)
		tag_llvm = fmt.aprintf("i%d", shape.tag_bytes * 8)
		slot = emit_union_spill(e, union_type, value)
		tag = emit_union_tag(e, union_type, value)
		// A subject the switch produced is the switch's to drop; one that names
		// storage someone else owns is only borrowed.
		consumes = !expression_is_borrowed_place(e.c, s.subject)
	}

	done := new_label(e, "typeswitch.done")

	bodies := make([]string, len(s.cases))
	tests := make([]string, len(s.cases))
	for index in 0 ..< len(s.cases) {
		bodies[index] = new_label(e, "typecase.body")
		tests[index] = new_label(e, "typecase.test")
	}
	default_index := -1
	order := make([dynamic]int)
	defer delete(order)
	for entry, index in s.cases {
		if len(entry.values) == 0 {
			default_index = index
		} else {
			append(&order, index)
		}
	}
	fallback := default_index >= 0 ? bodies[default_index] : done

	branch(e, len(order) > 0 ? tests[order[0]] : fallback)
	for case_index, position in order {
		place_label(e, tests[case_index])
		next := position + 1 < len(order) ? tests[order[position + 1]] : fallback
		matched := ""
		entry := s.cases[case_index]
		count := erased ? len(entry.values) : len(entry.variant_indices)
		for value_index in 0 ..< count {
			test := temp(e)
			discriminant := u64(0)
			if erased {
				discriminant = typeid_value(e.c, expr_base(entry.values[value_index]).denoted_type)
			} else {
				discriminant = u64(entry.variant_indices[value_index])
			}
			fmt.sbprintfln(&e.b, "  %s = icmp eq %s %s, %d", test, tag_llvm, tag, discriminant)
			if matched == "" {
				matched = test
			} else {
				combined := temp(e)
				fmt.sbprintfln(&e.b, "  %s = or i1 %s, %s", combined, matched, test)
				matched = combined
			}
		}
		branch_if(e, matched, bodies[case_index], next)
	}

	for entry, index in s.cases {
		place_label(e, bodies[index])
		push_scope_stmts(e, entry.stmts)
		emit_type_case_binding(e, entry, union_type, value, slot, erased)
		// The consumed payload leaves through the case's binding, which drops it like
		// any other managed local. With no binding to hand it to, the case itself
		// owns the whole union.
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
	if erased {
		if entry.binding_type == union_type {
			fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", llvm_type(e, union_type), value, binding)
			return
		}
		// A concrete case reads the erased value through the data pointer.
		loaded := load(e, llvm_type(e, entry.binding_type), slot)
		store(e, entry.binding_type, loaded, binding)
		return
	}
	if entry.binding_type == union_type {
		fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", llvm_type(e, union_type), value, binding)
		return
	}
	payload := emit_union_payload(e, union_type, entry.binding_type, slot)
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

// Return values move into the result slots before any cleanup runs, so a
// deferred statement cannot change what is returned.
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
		// The result is in result storage before cleanup runs, so a transferred local
		// can be marked dead here without the epilogue dropping what was just handed
		// back (design.md "Managed values and storage").
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
	// The result is already in result storage, so an owned one survives both
	// halves of cleanup — and a drop hook that panics cannot take it with it.
	drain_temporaries(e, 0)
	run_cleanups(e, 0)
	// This frame is leaving normally, so it is no longer one a panic can call
	// back into.
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

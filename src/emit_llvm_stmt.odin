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
// instructions that follow a terminator. A switch case body has the same
// problem as a block, so both go through here.
@(private = "file")
emit_statements :: proc(e: ^Emitter, stmts: []Stmt) {
	for stmt in stmts {
		if e.terminated {
			fmt.sbprintfln(&e.b, "unreachable.%d:", next_id(e))
			e.terminated = false
		}
		emit_stmt(e, stmt)
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
			// `static_assert` is checked and answered at compile time and has no
			// runtime cost, so there is nothing here to emit.
			if call, is_call := expr.(^Expr_Call); is_call {
				if call_builtin_kind(e, call) == .Static_Assert {
					continue
				}
			}
			if base := expr_base(expr); base != nil && len(base.result_types) > 0 {
				values := emit_multi_value(e, expr)
				discard_owned_values(e, base.result_types, values)
			} else {
				value := emit_expr(e, expr)
				emit_discarded_temporary(e, expr, value)
			}
		}

	case ^Stmt_Assign:
		emit_assign(e, s)

	case ^Stmt_If:
		emit_if(e, s)

	case ^Stmt_For:
		emit_for(e, s)

	case ^Stmt_Switch:
		if s.kind == .Type {
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
		// Structural selection: the branch the checker chose is emitted in place,
		// with no scope of its own, so its declarations and `defer`s belong to
		// the surrounding block exactly as written.
		emit_block_statements(e, when_selected_block(s))

	case ^Stmt_Foreach:
		if s.kind == .Unresolved {
			// The checker's L0350 arm gates every statement missing here, so this
			// is a hole in that gate — and skipping it would emit a program that
			// silently does less than the source says.
			backend_fail(e, "an unresolved statement reached emission")
			return
		}
		emit_foreach(e, s)
	}
}

@(private = "file")
emit_local_decl :: proc(e: ^Emitter, d: ^Decl) {
	// A call filling several names evaluates once.
	if len(d.values) == 1 && len(d.symbols) > 1 {
		if base := expr_base(d.values[0]); base != nil && len(base.result_types) == len(d.symbols) {
			results := emit_multi_value(e, d.values[0])
			for symbol_id, index in d.symbols {
				slot := declare_local(e, symbol_id)
				if slot != "" {
					store(e, base.result_types[index], results[index], slot)
					register_implicit_drop(e, symbol_id)
				}
			}
			// Bind retained results before any discarded payload's drop can panic.
			for symbol_id, index in d.symbols {
				if symbol_id == INVALID_SYMBOL {
					drop_temporary_value(e, hold_temporary_value(e, base.result_types[index], results[index]))
				}
			}
			return
		}
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
		if i < len(d.values) && d.values[i] == nil {
			continue // `---`: storage without an initial value
		}
		if i < len(d.values) && d.values[i] != nil {
			value := emit_expr(e, d.values[i])
			if i < len(d.value_clones) && d.value_clones[i] {
				value = emit_clone_value(e, sym.type, value, emit_destination_allocator(e, symbol_id))
			}
			store(e, sym.type, value, slot)
			register_implicit_drop(e, symbol_id)
			continue
		}
		zero, ok := zero_const(e.c, sym.type)
		if ok {
			store(e, sym.type, llvm_const(e, zero, sym.type), slot)
		}
		// design.md "Allocators": a written `via` is *eager* — the provider is
		// selected where the declaration is evaluated, so a later operation on this
		// container allocates through it rather than lazily binding the default.
		emit_eager_via_binding(e, symbol_id, slot)
		register_implicit_drop(e, symbol_id)
	}
}

// design.md "Exchange": the destination place is evaluated once, then
// `replacement` is evaluated completely before the destination is touched — a
// failure or panic during that leaves the destination unchanged. Once the
// replacement is ready, the compiler moves the old value into result storage
// and moves the replacement into the destination as one lifecycle operation.
//
// So the order below is the specification: address, replacement, load, store. No
// hook runs between the two moves — the old value is handed back rather than
// dropped, and the destination is never observably dead.
@(private)
emit_exchange :: proc(e: ^Emitter, v: ^Expr_Call) -> string {
	address := emit_address(e, v.bound[0])
	replacement := emit_expr(e, v.bound[1])
	previous := load(e, llvm_type(e, v.type), address)
	store(e, v.type, replacement, address)
	return previous
}

// `move` transfers the representation, writes the inert zero representation to
// a lexical source, and marks that source dead (design.md "Assignment
// statements").
@(private)
emit_move :: proc(e: ^Emitter, v: ^Expr_Move) -> string {
	value := emit_expr(e, v.value)
	if ident, is_ident := v.value.(^Expr_Ident); is_ident {
		kill_place(e, ident.symbol)
	}
	return value
}

@(private = "file")
declare_local :: proc(e: ^Emitter, symbol_id: Symbol_Id) -> string {
	sym := symbol_of(e.c, symbol_id)
	if sym == nil || sym.kind != .Var {
		return ""
	}
	name := fmt.aprintf("%%%s.%d", identifier_text(e.c, sym.name), next_id(e))
	fmt.sbprintfln(&e.b, "  %s = alloca %s", name, llvm_type(e, sym.type))
	bind_local(e, symbol_id, name)
	return name
}

// design.md "Assignment statements": every right side is evaluated, then every
// destination address, then the writes happen. Nothing is written before all of
// both are prepared.
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
	values: []string
	types: []Type_Id
	if len(s.rhs) == 1 && len(s.lhs) > 1 {
		values = emit_multi_value(e, s.rhs[0])
		types = expr_base(s.rhs[0]).result_types
	} else {
		values = make([]string, len(s.rhs))
		types = make([]Type_Id, len(s.rhs))
		for value, index in s.rhs {
			values[index] = emit_expr(e, value)
			// design.md: the clone happens before the destination is touched, so a
			// failure leaves a previously live destination unchanged.
			if index < len(s.rhs_clones) && s.rhs_clones[index] {
				values[index] = emit_clone_value(
					e, expr_base(s.lhs[index]).type, values[index],
					emit_destination_allocator(e, place_root_symbol(e.c, s.lhs[index])),
				)
			}
			types[index] = expr_base(value).type
		}
	}

	addresses := make([]string, len(s.lhs))
	for target, index in s.lhs {
		if is_discard(target) {
			continue
		}
		addresses[index] = emit_address(e, target)
	}
	for target, index in s.lhs {
		if addresses[index] == "" || index >= len(values) {
			if is_discard(target) && index < len(values) {
				if len(s.rhs) == 1 && len(s.lhs) > 1 {
					drop_temporary_value(e, hold_temporary_value(e, types[index], values[index]))
				} else {
					emit_discarded_temporary(e, s.rhs[index], values[index])
				}
			}
			continue
		}
		emit_replace_place(e, s, index, addresses[index])
		store(e, expr_base(target).type, values[index], addresses[index])
	}
}

// design.md "Assignment statements": the assignment `drop(destination)` between
// a successful clone and the write. The destination's state decides whether it
// happens at all — a definitely dead one holds nothing, and a conditional one
// asks its hidden flag.
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
	if ident, is_ident := target.(^Expr_Ident); is_ident && flag != "" {
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
	result := emit_binary_op(e, op, type, expr_base(s.rhs[0]).type, current, rhs)
	store(e, type, result, address)
}

@(private = "file")
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
	cond := emit_expr(e, s.cond)
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
		branch_if(e, emit_expr(e, s.cond), body, done)
	} else {
		branch(e, body)
	}

	place_label(e, body)
	emit_scoped_block(e, s.body)
	branch(e, post)

	place_label(e, post)
	if s.post != nil {
		emit_stmt(e, s.post)
	}
	branch(e, head)

	place_label(e, done)
	pop_scope(e)
}

// ponytail: one ordered comparison chain rather than an LLVM `switch` for the
// all-constant case. Ranges and non-constant cases need the chain anyway, and a
// second lowering would have to agree with this one about source order. Add the
// jump table when a measured switch is hot.
@(private = "file")
emit_switch :: proc(e: ^Emitter, s: ^Stmt_Switch) {
	outer_break, outer_break_depth := e.break_label, e.break_depth
	defer {
		e.break_label = outer_break
		e.break_depth = outer_break_depth
	}

	e.break_depth = len(e.cleanups)
	push_scope(e, nil)
	if s.init != nil {
		emit_stmt(e, s.init)
	}
	subject_type := expr_base(s.subject).type
	subject := emit_expr(e, s.subject)

	done := new_label(e, "switch.done")
	e.break_label = done

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
// variant's type where one is known, and at the union's type where a case names
// several types or is the default.
@(private = "file")
emit_type_switch :: proc(e: ^Emitter, s: ^Stmt_Switch) {
	outer_break, outer_break_depth := e.break_label, e.break_depth
	defer {
		e.break_label = outer_break
		e.break_depth = outer_break_depth
	}

	e.break_depth = len(e.cleanups)
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
	e.break_label = done

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
		for position in 0 ..< count {
			test := temp(e)
			discriminant := u64(0)
			if erased {
				discriminant = typeid_value(e.c, expr_base(entry.values[position]).denoted_type)
			} else {
				discriminant = u64(entry.variant_indices[position])
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
		// The consumed payload leaves through the case's binding, which drops it
		// like any other managed local. With no binding to hand it to, the case
		// itself owns the whole union.
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
	fmt.sbprintfln(&e.b, "  %s = alloca %s", binding, llvm_type(e, entry.binding_type))
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
	if s != nil && len(s.values) > 0 {
		if len(s.values) == 1 && len(e.result_types) > 1 {
			if base := expr_base(s.values[0].expr); base != nil && len(base.result_types) == len(e.result_types) {
				results := emit_multi_value(e, s.values[0].expr)
				for value, index in results {
					store(e, e.result_types[index], value, e.result_slots[index])
				}
				emit_epilogue(e)
				return
			}
		}
		values := make([]string, len(s.values))
		for value, index in s.values {
			// An `inout` result hands back the place itself, not a copy of it.
			if emit_result_is_inout(e, index) {
				values[index] = emit_address(e, value.expr)
			} else {
				values[index] = emit_expr(e, value.expr)
			}
			if value.clone_on_return && index < len(e.result_types) {
				values[index] = emit_clone_value(e, e.result_types[index], values[index])
			}
		}
		for value, index in values {
			if index >= len(e.result_slots) {
				continue
			}
			if emit_result_is_inout(e, index) {
				fmt.sbprintfln(&e.b, "  store ptr %s, ptr %s", value, e.result_slots[index])
			} else {
				store(e, e.result_types[index], value, e.result_slots[index])
			}
		}
		// The result is in result storage before cleanup runs, so a transferred
		// local can be marked dead here without the epilogue dropping what was
		// just handed back (design.md "Managed values and storage").
		for value in s.values {
			if value.clone_on_return {
				continue
			}
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
	run_cleanups(e, 0)
	// This frame is leaving normally, so it is no longer one a panic can call
	// back into.
	emit_unwind_pop(e)
	if e.abi_foreign {
		emit_foreign_return(e)
		e.terminated = true
		return
	}
	slot_type :: proc(e: ^Emitter, index: int) -> string {
		return emit_result_is_inout(e, index) ? "ptr" : llvm_type(e, e.result_types[index])
	}
	switch len(e.result_types) {
	case 0:
		fmt.sbprintln(&e.b, "  ret void")
	case 1:
		value := load(e, slot_type(e, 0), e.result_slots[0])
		fmt.sbprintfln(&e.b, "  ret %s %s", slot_type(e, 0), value)
	case:
		aggregate := "undef"
		result_type := llvm_result_type(e, e.result_types, e.result_inout)
		for _, index in e.result_types {
			value := load(e, slot_type(e, index), e.result_slots[index])
			next := temp(e)
			fmt.sbprintfln(
				&e.b,
				"  %s = insertvalue %s %s, %s %s, %d",
				next, result_type, aggregate, slot_type(e, index), value, index,
			)
			aggregate = next
		}
		fmt.sbprintfln(&e.b, "  ret %s %s", result_type, aggregate)
	}
	e.terminated = true
}

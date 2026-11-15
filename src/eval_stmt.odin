// Compile-time statements: blocks, `defer`, declarations, assignment, loops,
// `switch`, and `return`.
package lokec

import "core:slice"
import "core:unicode/utf8"

@(private)
eval_block :: proc(ev: ^Evaluator, b: ^Block) -> Eval_Flow {
	return b == nil ? .Normal : eval_stmts(ev, b.stmts, true)
}

// Runs `stmts` until one leaves; a scope then runs the `defer`s it registered,
// in reverse.
@(private = "file")
eval_stmts :: proc(ev: ^Evaluator, stmts: []Stmt, scope: bool) -> Eval_Flow {
	frame := current_frame(ev)
	mark := len(frame.defers)
	flow := Eval_Flow.Normal
	for stmt in stmts {
		flow = eval_stmt(ev, stmt)
		if flow != .Normal {
			break
		}
	}
	if scope {
		flow = run_defers(ev, frame, mark, flow)
	}
	return flow
}

// An `errdefer` runs only when the scope is left by returning the failure
// variant (design.md "defer statement").
@(private = "file")
run_defers :: proc(ev: ^Evaluator, frame: ^Eval_Frame, mark: int, flow: Eval_Flow) -> Eval_Flow {
	result := flow
	failing := false
	if flow == .Return && frame.result_type != INVALID_TYPE {
		if shape, fallible := fallible_of(ev.k.c, frame.result_type); fallible {
			failing = frame.result.variant == shape.failure
		}
	}
	for index := len(frame.defers) - 1; index >= mark; index -= 1 {
		deferred := frame.defers[index]
		if deferred.on_failure && !failing {
			continue
		}
		if eval_stmt(ev, deferred.stmt) == .Fail {
			result = .Fail
		}
	}
	resize(&frame.defers, mark)
	return result
}

@(private)
eval_stmt :: proc(ev: ^Evaluator, stmt: Stmt) -> Eval_Flow {
	result := eval_stmt_inner(ev, stmt)
	if !eval_memory_ok(ev) {
		return .Fail
	}
	// The signal of an `or_return` or an `or_else` exit is spent here, so a later
	// failure is not one (design.md "or_else expression").
	if frame := current_frame(ev); result == .Fail && frame.exiting != .Normal && !ev.failed {
		flow := frame.exiting
		frame.exiting = .Normal
		return flow
	}
	return result
}

@(private = "file")
eval_stmt_inner :: proc(ev: ^Evaluator, stmt: Stmt) -> Eval_Flow {
	if !eval_step(ev, stmt_span(stmt)) {
		return .Fail
	}
	switch s in stmt {
	case ^Stmt_Error:
		return .Normal

	case ^Item_Impl:
		return .Normal

	case ^Decl:
		return eval_local_decl(ev, s)

	case ^Stmt_Expr:
		for expr in s.exprs {
			if _, ok := eval_expr(ev, expr); !ok {
				return .Fail
			}
		}
		return .Normal

	case ^Stmt_Assign:
		return eval_assign(ev, s)

	case ^Stmt_If:
		if s.init != nil {
			if flow := eval_stmt(ev, s.init); flow != .Normal {
				return flow
			}
		}
		cond, ok := eval_expr(ev, s.cond)
		if !ok {
			return .Fail
		}
		if cond.boolean {
			return eval_block(ev, s.then)
		}
		if s.otherwise != nil {
			return eval_stmt(ev, s.otherwise)
		}
		return .Normal

	case ^Stmt_For:
		return eval_for(ev, s)

	case ^Stmt_Switch:
		return eval_switch(ev, s)

	case ^Stmt_Defer:
		append(&current_frame(ev).defers, s)
		return .Normal

	case ^Stmt_Return:
		return eval_return(ev, s)

	case ^Stmt_Branch:
		return s.kind == .Break ? .Break : .Continue

	case ^Block:
		return eval_block(ev, s)

	case ^Stmt_When:
		// Not a scope: its `defer`s belong to the surrounding one.
		return s.selected == nil ? .Normal : eval_stmts(ev, s.selected.stmts, false)

	case ^Stmt_Foreach:
		return eval_foreach(ev, s)

	case ^Stmt_Parallel:
		// design.md "Parallel blocks": running the tasks serially would
		// not be a faithful substitute.
		eval_fail(ev, s.keyword, "L0341", "a `parallel` block cannot run during compile-time evaluation")
		return .Fail

	case ^Stmt_Spawn:
	}
	eval_fail(ev, stmt_span(stmt), "L0341", "this statement has no compile-time meaning")
	return .Fail
}

@(private = "file")
eval_local_decl :: proc(ev: ^Evaluator, d: ^Decl) -> Eval_Flow {
	frame := current_frame(ev)
	// design.md "Storage modifiers": the storage persists between calls, so it
	// is runtime state that evaluation can neither read nor modify.
	if d.duration != .None {
		eval_fail(
			ev, d.span, "L0341", "a `%s` local has no compile-time meaning",
			d.duration == .Static ? "static" : "thread_local",
		)
		return .Fail
	}
	if d.destructure.active {
		values, ok := eval_destructure(ev, &d.destructure, d.values[0])
		if !ok {
			return .Fail
		}
		for symbol_id, index in d.symbols {
			if !eval_bind_local(ev, frame, symbol_id, values[index]) {
				return .Fail
			}
		}
		return .Normal
	}
	for symbol_id, index in d.symbols {
		symbol := symbol_of(ev.k.c, symbol_id)
		// A body-local type holds no value.
		if symbol != nil && symbol.kind == .Type {
			continue
		}
		// Only a declaration without an initializer needs its type's zero; an
		// unfixed constant such as `N :: 3` has none, and `_: T` binds nothing.
		value: Eval_Value
		ok: bool
		if index < len(d.values) && d.values[index] != nil {
			value, ok = eval_copied(ev, d.values[index])
		} else if symbol == nil {
			continue
		} else {
			ok = eval_hooks_supported(ev, symbol.type, d.span)
			if ok {
				value, ok = zero_value(ev, symbol.type)
			}
		}
		if !ok || !eval_bind_local(ev, frame, symbol_id, value) {
			return .Fail
		}
	}
	return .Normal
}

@(private = "file")
eval_bind_local :: proc(ev: ^Evaluator, frame: ^Eval_Frame, symbol_id: Symbol_Id, value: Eval_Value) -> bool {
	if symbol_id == INVALID_SYMBOL {
		return true
	}
	// A fresh slot per declaration, so each loop iteration has its own.
	slot, ok := eval_slot(ev, value)
	if !ok {
		return false
	}
	frame.locals[symbol_id] = slot
	return true
}

// design.md "Destructuring": one evaluation; fields of a place are copied.
@(private = "file")
eval_destructure :: proc(ev: ^Evaluator, plan: ^Destructure, operand: Expr) -> (out: []Eval_Value, success: bool) {
	record := eval_expr(ev, operand) or_return
	if record.kind != .Aggregate || len(record.elements) < len(plan.fields) {
		return nil, eval_fail(ev, expr_span(operand), "L0341", "this value has no compile-time fields to destructure")
	}
	values, err := make([]Eval_Value, len(plan.fields), ev.alloc)
	if err != nil {
		return nil, false
	}
	for index in 0 ..< len(plan.fields) {
		if index < len(plan.retained) && !plan.retained[index] {
			continue
		}
		// A padding field fills no binding, so the field's own slot is read.
		slot := int(symbol_of(ev.k.c, plan.fields[index]).index)
		if !plan.from_place {
			values[index] = record.elements[slot]
			continue
		}
		copied := copy_value(ev, record.elements[slot]) or_return
		values[index] = copied
	}
	return values, true
}

@(private = "file")
eval_assign :: proc(ev: ^Evaluator, s: ^Stmt_Assign) -> Eval_Flow {
	if s.lowered != nil {
		return eval_block(ev, s.lowered)
	}
	// design.md "Indexing and slicing": `grid[x, y] = v` calls `operator([]=)`
	// with the arguments the checker bound.
	if s.place_setter != INVALID_SYMBOL {
		_, ok := eval_operator_call(ev, s.place_setter, s.setter_bound, s.op_span)
		return ok ? .Normal : .Fail
	}
	if s.op != .Assign {
		return eval_compound_assign(ev, s)
	}
	if s.destructure.active {
		values, ok := eval_destructure(ev, &s.destructure, s.rhs[0])
		if !ok {
			return .Fail
		}
		defer delete(values, ev.alloc)
		// design.md "Destructuring": a narrower union widens to its destination's.
		for target, index in s.lhs {
			from, to := symbol_of(ev.k.c, s.destructure.fields[index]).type, expr_base(target).type
			if !is_discard(target) && union_widens_to(ev.k.c, from, to) {
				values[index] = widen_eval_value(ev.k.c, values[index], from, to)
			}
		}
		return eval_write_targets(ev, s.lhs, values)
	}
	// The array is scratch: each write copies a value out.
	values, value_err := make([]Eval_Value, len(s.rhs), ev.alloc)
	if value_err != nil { return .Fail }
	defer delete(values, ev.alloc)
	for value, index in s.rhs {
		copied, ok := eval_copied(ev, value)
		if !ok {
			return .Fail
		}
		values[index] = copied
	}
	return eval_write_targets(ev, s.lhs, values)
}

// design.md "Assignment statements": values, then destinations, then writes.
@(private = "file")
eval_write_targets :: proc(ev: ^Evaluator, targets: []Expr, values: []Eval_Value) -> Eval_Flow {
	destinations, err := make([]Eval_Destination, len(targets), ev.alloc)
	if err != nil { return .Fail }
	defer delete(destinations, ev.alloc)
	for target, index in targets {
		destination, ok := eval_destination(ev, target)
		if !ok {
			return .Fail
		}
		destinations[index] = destination
	}
	for destination, index in destinations {
		slot, ok := destination_slot(ev, destination)
		if !ok {
			return .Fail
		}
		retyped := values[index]
		retyped.type = slot.type != INVALID_TYPE ? slot.type : retyped.type
		slot^ = retyped
	}
	return .Normal
}

// A prepared assignment destination. `m[key] = elem` keeps its map and key and
// inserts in the write phase, as at run time, so the insertion cannot move an
// entry that another destination already names.
@(private = "file")
Eval_Destination :: struct {
	slot:   ^Eval_Value,
	map_of: ^Eval_Value,
	key:    Eval_Value,
}

@(private = "file")
eval_destination :: proc(ev: ^Evaluator, target: Expr) -> (out: Eval_Destination, success: bool) {
	if index, is_index := target.(^Expr_Index); is_index && index.map_inserts {
		base := eval_aggregate_place(ev, index.operand) or_return
		if type_is_map(ev.k.c, base.type) {
			key := eval_copied(ev, index.indices[0]) or_return
			return Eval_Destination{map_of = base, key = key}, true
		}
	}
	slot := eval_place(ev, target) or_return
	return Eval_Destination{slot = slot}, true
}

@(private = "file")
destination_slot :: proc(ev: ^Evaluator, destination: Eval_Destination) -> (^Eval_Value, bool) {
	if destination.map_of != nil {
		return map_entry_place(ev, destination.map_of, destination.key)
	}
	return destination.slot, true
}

@(private = "file")
eval_compound_assign :: proc(ev: ^Evaluator, s: ^Stmt_Assign) -> Eval_Flow {
	// A direct user `+=` writes through its `inout` destination.
	if s.operator != INVALID_SYMBOL && s.operator_direct {
		operands := [2]Expr{s.lhs[0], s.rhs[0]}
		_, ok := eval_operator_call(ev, s.operator, operands[:], s.op_span)
		return ok ? .Normal : .Fail
	}
	slot, ok := eval_place(ev, s.lhs[0])
	if !ok {
		return .Fail
	}
	operand, operand_ok := eval_expr(ev, s.rhs[0])
	if !operand_ok {
		return .Fail
	}
	// design.md "Evaluation order": the destination is read after the right operand.
	result: Eval_Value
	switch {
	case s.operator != INVALID_SYMBOL:
		// The user `+` it falls back to, its destination evaluated once, then a
		// replacing write.
		result, ok = eval_operator_call(ev, s.operator, nil, s.op_span, []Eval_Value{slot^, operand})
	case type_is_simd(ev.k.c, slot.type):
		// Lane-wise, since `constant` carries no lanes.
		result, ok = eval_simd_binary_values(ev, compound_operator(s.op), s.op_span, slot.type, slot^, operand)
	case:
		result, ok = eval_scalar_binary(ev, compound_operator(s.op), s.op_span, slot^, operand, slot.type, slot.type)
	}
	if !ok {
		return .Fail
	}
	slot^ = result
	return .Normal
}

@(private = "file")
eval_for :: proc(ev: ^Evaluator, s: ^Stmt_For) -> Eval_Flow {
	if s.init != nil {
		if flow := eval_stmt(ev, s.init); flow != .Normal {
			return flow
		}
	}
	for {
		if !eval_step(ev, s.span) {
			return .Fail
		}
		if s.cond != nil {
			cond, ok := eval_expr(ev, s.cond)
			if !ok {
				return .Fail
			}
			if !cond.boolean {
				return .Normal
			}
		}
		flow := eval_block(ev, s.body)
		#partial switch flow {
		case .Fail, .Return:
			return flow
		case .Break:
			return .Normal
		}
		if s.post != nil {
			// An `or_return` in the post statement leaves the loop too.
			if post := eval_stmt(ev, s.post); post != .Normal {
				return post
			}
		}
	}
}

// design.md "foreach statement": a range walks its endpoints; other kinds
// already hold their elements.
@(private = "file")
eval_foreach :: proc(ev: ^Evaluator, s: ^Stmt_Foreach) -> Eval_Flow {
	#partial switch s.kind {
	case .Static:
		// The checked copies run in order.
		for copy_block in s.expansion {
			if flow := eval_block(ev, copy_block); flow != .Normal {
				return flow
			}
		}
		return .Normal

	case .Range, .Stored_Range:
		return eval_range_foreach(ev, s)

	case .Array, .Slice, .Dynamic:
		// A `&mut` loop needs the container's own storage, and so does a
		// borrowed binding over a place (design.md "Borrowing iteration"). A
		// slice is a view of that storage, whichever expression made it.
		if s.kind != .Slice && (foreach_is_place_loop(s) || s.borrows && eval_frame_place(ev, s.iterable)) {
			container, ok := eval_place(ev, s.iterable)
			if !ok {
				return .Fail
			}
			return eval_sequence_foreach(ev, s, container.elements)
		}
		container, ok := eval_expr(ev, s.iterable)
		if !ok {
			return .Fail
		}
		return eval_sequence_foreach(ev, s, container.elements)

	case .Text:
		return eval_text_foreach(ev, s)

	case .Map:
		// design.md "Maps": the order is unspecified.
		eval_fail(
			ev, s.span, "L0593",
			"a map cannot be iterated at compile time: its iteration order is unspecified",
		)
		return .Fail

	case .Protocol:
		eval_fail(ev, s.span, "L0341", "a user iterator has no compile-time meaning yet")
		return .Fail
	}
	eval_fail(ev, s.span, "L0341", "this `foreach` has no compile-time meaning")
	return .Fail
}

// Counts out from the low end, so `..= max` needs no `max + 1`. `reversed()`
// mirrors the value; `indexed()` still counts up (design.md "Reverse iteration").
@(private = "file")
eval_range_foreach :: proc(ev: ^Evaluator, s: ^Stmt_Foreach) -> Eval_Flow {
	lo, hi: Eval_Value
	closed := false
	if written, is_range := s.iterable.(^Expr_Range); is_range {
		low, low_ok := eval_expr(ev, written.lo)
		if !low_ok { return .Fail }
		high, high_ok := eval_expr(ev, written.hi)
		if !high_ok { return .Fail }
		lo, hi = low, high
		closed = written.op == .Range_Incl
	} else {
		stored, ok := eval_expr(ev, s.iterable)
		if !ok { return .Fail }
		if stored.kind != .Aggregate || len(stored.elements) <= RANGE_CLOSED || stored.elements[RANGE_CLOSED].kind != .Boolean {
			eval_fail(ev, expr_span(s.iterable), "L0341", "this range has no compile-time meaning")
			return .Fail
		}
		lo = stored.elements[RANGE_LOW]
		hi = stored.elements[RANGE_HIGH]
		closed = stored.elements[RANGE_CLOSED].boolean
	}
	if lo.kind != .Integer && lo.kind != .Rune {
		eval_fail(ev, expr_span(s.iterable), "L0341", "this range has no compile-time meaning")
		return .Fail
	}
	one := bi_from_i64(ev.alloc, 1)
	span := bi_sub(ev.alloc, hi.integer, lo.integer)
	if closed {
		open_span := span
		span = bi_add(ev.alloc, open_span, one)
		bi_release(open_span)
	}
	// Only a reversed range counts down from its last offset.
	last: Big_Int
	if s.reversed {
		last = bi_sub(ev.alloc, span, one)
	}
	defer bi_release(last)
	count, fits := bi_to_i64(ev.alloc, span)
	if !fits {
		// A high endpoint far below the low one yields nothing; the step limit
		// ends a very long range first.
		count = bi_sign(span) < 0 ? 0 : max(i64)
	}
	bi_release(one, span)
	for index in 0 ..< int(min(count, i64(max(int)))) {
		offset := bi_from_i64(ev.alloc, i64(index))
		if s.reversed {
			forward := offset
			offset = bi_sub(ev.alloc, last, forward)
			bi_release(forward)
		}
		value := lo
		// The loop variable holds the sum, which the body may keep; the offset
		// is only this step's.
		value.integer = bi_add(ev.alloc, lo.integer, offset)
		bi_release(offset)
		flow := eval_foreach_step(ev, s, &value, index)
		if flow != .Normal {
			return flow == .Break ? .Normal : flow
		}
	}
	return .Normal
}

// design.md "String iteration": yields Unicode scalar values.
@(private = "file")
eval_text_foreach :: proc(ev: ^Evaluator, s: ^Stmt_Foreach) -> Eval_Flow {
	subject, ok := eval_expr(ev, s.iterable)
	if !ok {
		return .Fail
	}
	elements, allocated := eval_elements(ev, utf8.rune_count_in_string(subject.text))
	if !allocated {
		return .Fail
	}
	next := 0
	for point in subject.text {
		elements[next] = Eval_Value{
			kind    = .Rune,
			type    = TYPE_RUNE,
			integer = bi_from_i64(ev.alloc, i64(point)),
		}
		next += 1
	}
	return eval_sequence_foreach(ev, s, elements)
}

@(private = "file")
eval_sequence_foreach :: proc(ev: ^Evaluator, s: ^Stmt_Foreach, elements: []Eval_Value) -> Eval_Flow {
	for index in 0 ..< len(elements) {
		at := s.reversed ? len(elements) - 1 - index : index
		flow := eval_foreach_step(ev, s, &elements[at], index)
		if flow != .Normal {
			return flow == .Break ? .Normal : flow
		}
	}
	return .Normal
}

// `continue` ends only the step.
@(private = "file")
eval_foreach_step :: proc(ev: ^Evaluator, s: ^Stmt_Foreach, element: ^Eval_Value, index: int) -> Eval_Flow {
	if !eval_step(ev, s.span) {
		return .Fail
	}
	if !bind_foreach_element(ev, s, element, index) {
		return .Fail
	}
	flow := eval_block(ev, s.body)
	return flow == .Continue ? .Normal : flow
}

// design.md "Element bindings": an owned binding copies; a borrowed or `&mut`
// binding is the container's storage. A single name over a lent `indexed()`
// record receives a fresh record whose `value` points at the element.
@(private = "file")
bind_foreach_element :: proc(ev: ^Evaluator, s: ^Stmt_Foreach, element: ^Eval_Value, index: int) -> bool {
	frame := current_frame(ev)
	if foreach_is_place_loop(s) || s.borrows && (!s.indexed || len(s.bindings) == 2) {
		if s.indexed && len(s.bindings) == 2 {
			bind_eval_pattern(ev, frame, s.bindings[:1], element, s.span) or_return
			return eval_bind_local(ev, frame, s.bindings[1].symbol, eval_count_value(ev, index))
		}
		return bind_eval_pattern(ev, frame, s.bindings, element, s.span)
	}
	value: Eval_Value
	if s.borrows {
		pointer := element_type_at(ev.k.c, s.element_type, ELEMENT_FIRST, 0)
		value = Eval_Value{kind = .Nil, type = pointer, target = element}
	} else {
		value = copy_value(ev, element^) or_return
	}
	if s.indexed {
		pair := eval_elements(ev, 2) or_return
		pair[ELEMENT_FIRST] = value
		pair[ELEMENT_SECOND] = eval_count_value(ev, index)
		value = Eval_Value{kind = .Aggregate, type = s.element_type, elements = pair}
	}
	slot := eval_slot(ev, value) or_return
	return bind_eval_pattern(ev, frame, s.bindings, slot, s.span)
}

// Each name is the part of `value` it destructures.
@(private = "file")
bind_eval_pattern :: proc(
	ev: ^Evaluator, frame: ^Eval_Frame, bindings: []Foreach_Binding, value: ^Eval_Value, span: Span,
) -> bool {
	if len(bindings) == 1 {
		if len(bindings[0].group) > 0 {
			return bind_eval_pattern(ev, frame, bindings[0].group, value, span)
		}
		if bindings[0].symbol != INVALID_SYMBOL {
			frame.locals[bindings[0].symbol] = value
		}
		return true
	}
	if value.kind != .Aggregate || len(value.elements) != len(bindings) {
		return eval_fail(ev, span, "L0341", "this element has no compile-time fields to destructure")
	}
	for slot in 0 ..< len(bindings) {
		bind_eval_pattern(ev, frame, bindings[slot:][:1], &value.elements[slot], span) or_return
	}
	return true
}

@(private = "file")
eval_switch :: proc(ev: ^Evaluator, s: ^Stmt_Switch) -> Eval_Flow {
	if s.init != nil {
		if flow := eval_stmt(ev, s.init); flow != .Normal {
			return flow
		}
	}
	// A `.name(&mut binding)` case binds the payload in the subject's own storage,
	// and so does any binding over a place (design.md "Switch ownership").
	if switch_binds_place(s) || s.kind == .Pattern && eval_frame_place(ev, s.subject) {
		place, ok := eval_place(ev, s.subject)
		if !ok {
			return .Fail
		}
		return eval_variant_switch(ev, s, place^, place)
	}
	subject, ok := eval_expr(ev, s.subject)
	if !ok {
		return .Fail
	}
	if s.kind == .Pattern {
		return eval_variant_switch(ev, s, subject)
	}
	default_index := -1
	for entry, index in s.cases {
		if len(entry.values) == 0 {
			default_index = index
			continue
		}
		for value in entry.values {
			matched, match_ok := eval_case_matches(ev, subject, value)
			if !match_ok {
				return .Fail
			}
			if matched {
				return eval_stmts(ev, s.cases[index].stmts, true)
			}
		}
	}
	if default_index >= 0 {
		return eval_stmts(ev, s.cases[default_index].stmts, true)
	}
	return .Normal
}

// Dispatches on the variant index, as the emitter compares the tag.
@(private = "file")
eval_variant_switch :: proc(ev: ^Evaluator, s: ^Stmt_Switch, subject: Eval_Value, place: ^Eval_Value = nil) -> Eval_Flow {
	chosen := -1
	fallback := -1
	for entry, index in s.cases {
		if len(entry.variant_indices) == 0 {
			fallback = index
			continue
		}
		if slice.contains(entry.variant_indices, subject.variant) {
			chosen = index
			break
		}
	}
	if chosen < 0 {
		chosen = fallback
	}
	if chosen < 0 {
		return .Normal
	}
	entry := s.cases[chosen]
	if len(entry.fields) > 0 {
		return eval_case_fields(ev, s, entry, subject, place)
	}
	if entry.binding_symbol != INVALID_SYMBOL && !eval_bind_case_payload(ev, current_frame(ev), entry, subject, place) {
		return .Fail
	}
	return eval_stmts(ev, entry.stmts, true)
}

// design.md "Switch ownership": a binding over a place names the payload in the
// subject's storage, and any other binding owns a copy.
@(private = "file")
eval_bind_case_payload :: proc(
	ev: ^Evaluator, frame: ^Eval_Frame, entry: Switch_Case, subject: Eval_Value, place: ^Eval_Value,
) -> bool {
	if place != nil && len(place.elements) > 0 {
		frame.locals[entry.binding_symbol] = &place.elements[0]
		return true
	}
	bound, copied := copy_value(ev, eval_union_payload(subject))
	return copied && eval_bind_local(ev, frame, entry.binding_symbol, bound)
}

// design.md "Union argument expansion": the arm for the subject's variant, with
// the payload bound as the switch it stands for binds it.
@(private)
eval_dispatch :: proc(ev: ^Evaluator, s: ^Stmt_Switch) -> (out: Eval_Value, success: bool) {
	subject: Eval_Value
	place: ^Eval_Value
	if eval_frame_place(ev, s.subject) {
		found := eval_place(ev, s.subject) or_return
		subject, place = found^, found
	} else {
		value := eval_expr(ev, s.subject) or_return
		subject = value
	}
	for entry in s.cases {
		if len(entry.variant_indices) != 1 || entry.variant_indices[0] != subject.variant {
			continue
		}
		if entry.binding_symbol == INVALID_SYMBOL {
			return eval_expr(ev, entry.arm)
		}
		// A constant initialiser has no frame, so the payload gets one of its own.
		frame := current_frame(ev)
		own_frame := frame == nil
		if own_frame {
			frame = eval_push_frame(ev, INVALID_SYMBOL, s.span) or_return
		}
		defer if own_frame {
			pop(&ev.frames)
			eval_release_frame(ev, frame)
		}
		eval_bind_case_payload(ev, frame, entry, subject, place) or_return
		return eval_expr(ev, entry.arm)
	}
	return {}, eval_fail(ev, s.span, "L0341", "this union value has no variant to dispatch")
}

// Whether `subject` is a place rooted in this frame's storage, which a binding then
// names rather than copies.
@(private = "file")
eval_frame_place :: proc(ev: ^Evaluator, subject: Expr) -> bool {
	if !expression_is_borrowed_place(subject) {
		return false
	}
	frame := current_frame(ev)
	if frame == nil {
		return false
	}
	cur := subject
	for {
		#partial switch v in cur {
		case ^Expr_Ident:
			_, local := frame.locals[v.symbol]
			return local
		case ^Expr_Selector:
			if v.operand == nil || type_is_pointer(ev.k.c, expr_base(v.operand).type) {
				return false
			}
			cur = v.operand
		case ^Expr_Index:
			if v.resolution.kind == .User_Operator || underlying_kind(ev.k.c, expr_base(v.operand).type) != .Array {
				return false
			}
			cur = v.operand
		case ^Expr_Postfix:
			// A pointer's target is storage wherever it lives; a box's payload is
			// its own.
			if v.op != .Caret {
				return false
			}
			if !v.boxed {
				return true
			}
			cur = v.operand
		case:
			return false
		}
	}
}

// design.md "Inspecting a union": each field binding names its field of the
// payload in the subject's storage when the subject is a place, and reads a
// copy otherwise.
@(private = "file")
eval_case_fields :: proc(ev: ^Evaluator, s: ^Stmt_Switch, entry: Switch_Case, subject: Eval_Value, place: ^Eval_Value) -> Eval_Flow {
	frame := current_frame(ev)
	payload := place != nil && len(place.elements) > 0 ? &place.elements[0] : nil
	record := payload^ if payload != nil else eval_union_payload(subject)
	for field in entry.fields {
		if field.symbol == INVALID_SYMBOL {
			continue
		}
		if record.kind != .Aggregate || field.slot >= len(record.elements) {
			eval_fail(ev, s.span, "L0341", "this payload has no compile-time fields to bind")
			return .Fail
		}
		if payload != nil {
			frame.locals[field.symbol] = &payload.elements[field.slot]
			continue
		}
		bound, copied := copy_value(ev, record.elements[field.slot])
		if !copied || !eval_bind_local(ev, frame, field.symbol, bound) {
			return .Fail
		}
	}
	return eval_stmts(ev, entry.stmts, true)
}

@(private = "file")
eval_case_matches :: proc(ev: ^Evaluator, subject: Eval_Value, value: Expr) -> (out: bool, success: bool) {
	if range, is_range := value.(^Expr_Range); is_range {
		lo := eval_expr(ev, range.lo) or_return
		hi := eval_expr(ev, range.hi) or_return
		above, above_ok := eval_compare(ev, .Gt_Eq, subject, lo)
		below, below_ok := eval_compare(ev, range.op == .Range_Excl ? .Lt : .Lt_Eq, subject, hi)
		if !above_ok || !below_ok {
			return false, eval_fail(ev, expr_span(value), "L0341", "this case has no compile-time meaning")
		}
		return above && below, true
	}
	other := eval_expr(ev, value) or_return
	matched, compare_ok := eval_compare(ev, .Eq_Eq, subject, other)
	if !compare_ok {
		return false, eval_fail(ev, expr_span(value), "L0341", "this case has no compile-time meaning")
	}
	return matched, true
}

@(private = "file")
eval_return :: proc(ev: ^Evaluator, s: ^Stmt_Return) -> Eval_Flow {
	frame := current_frame(ev)
	if s.value == nil {
		return .Return
	}
	computed: Eval_Value
	if s.value.is_inout {
		place, place_ok := eval_place(ev, s.value.expr)
		if !place_ok {
			return .Fail
		}
		frame.result_place = place
		computed = place^
	} else {
		value, ok := eval_expr(ev, s.value.expr)
		if !ok {
			return .Fail
		}
		computed = value
	}
	copied, copied_ok := copy_value(ev, computed)
	if !copied_ok {
		return .Fail
	}
	frame.result = copied
	return .Return
}

// Iteration lowering and synthesized iterator bodies.
//
// Part of the textual LLVM backend; see compiler-architecture.md.
package lokec

import "core:fmt"

// A stored `a ..< b` or `a ..= b`: the endpoints plus the closed flag.
@(private)
emit_range_value :: proc(e: ^Emitter, v: ^Expr_Range, as_type: Type_Id) -> string {
	element := llvm_type(e, type_of(e.c, as_type).element)
	low := emit_expr(e, v.lo)
	high := emit_expr(e, v.hi)
	closed := v.op == .Range_Incl ? "true" : "false"
	storage := llvm_type(e, as_type)
	step1 := insert(e, storage, "undef", element, low, RANGE_LOW)
	step2 := insert(e, storage, step1, element, high, RANGE_HIGH)
	return insert(e, storage, step2, "i1", closed, RANGE_CLOSED)
}

// design.md "Ranges": evaluates x, then r, once each.
@(private)
emit_range_membership :: proc(e: ^Emitter, v: ^Expr_Binary) -> string {
	range := expr_base(v.rhs).type
	element := type_of(e.c, range).element
	x := emit_expr(e, v.lhs)
	value := emit_expr(e, v.rhs)
	storage := llvm_type(e, range)
	low := extract(e, storage, value, RANGE_LOW)
	high := extract(e, storage, value, RANGE_HIGH)
	closed := extract(e, storage, value, RANGE_CLOSED)
	above := emit_compare(e, .Lt_Eq, element, low, x)
	below := emit_compare(e, .Lt, element, x, high)
	at := emit_compare(e, .Eq_Eq, element, x, high)
	at_closed, within, out := temp(e), temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = and i1 %s, %s", at_closed, closed, at)
	fmt.sbprintfln(&e.b, "  %s = or i1 %s, %s", within, below, at_closed)
	fmt.sbprintfln(&e.b, "  %s = and i1 %s, %s", out, above, within)
	return out
}

@(private)
emit_foreach :: proc(e: ^Emitter, s: ^Stmt_Foreach) {
	if s.kind == .Static {
		// An expansion is not a loop: its checked copies run in iterable order.
		// Each copy is its own scope, as it was checked and walked.
		for copy_block in s.expansion {
			emit_scoped_block(e, copy_block)
		}
		return
	}

	outer := e.loop
	defer e.loop = outer
	push_scope(e, nil)

	switch s.kind {
	case .Protocol:
		emit_protocol_foreach(e, s)
	case .Text:
		emit_text_foreach(e, s)
	case .Map:
		emit_map_foreach(e, s)
	case .Range, .Stored_Range:
		emit_range_foreach(e, s)
	case .Array, .Slice, .Dynamic:
		emit_sequence_foreach(e, s)
	case .Unresolved, .Static:
		backend_fail(e, "an unresolved `foreach` reached emission")
	}
	debug_mark_end(e, s.span)
	pop_scope(e)
}

@(private = "file")
Loop_Labels :: struct {
	head, body, post, done: string,
	// `indexed()`'s ordinal, or a sequence's cursor; `close_loop` steps it.
	counter: string,
}

@(private)
new_counter :: proc(e: ^Emitter) -> string {
	slot := alloca(e, "i64")
	fmt.sbprintfln(&e.b, "  store i64 0, ptr %s", slot)
	return slot
}

@(private = "file")
open_loop :: proc(e: ^Emitter, counted: bool) -> Loop_Labels {
	loop := Loop_Labels{
		head = new_label(e, "foreach.head"), body = new_label(e, "foreach.body"),
		post = new_label(e, "foreach.post"), done = new_label(e, "foreach.done"),
	}
	if counted {
		loop.counter = new_counter(e)
	}
	// `break` lands in the loop scope, whose exit disposes of the iterator once.
	enter_loop(e, loop.done, loop.post)
	return loop
}

// Each step has its own cleanup scope at the depth `continue` unwinds to, so a
// value the step owns is disposed of once per step on every exit path.
@(private = "file")
begin_step :: proc(e: ^Emitter, loop: Loop_Labels) {
	place_label(e, loop.body)
	push_scope(e, nil)
}

@(private = "file")
finish_step :: proc(e: ^Emitter, s: ^Stmt_Foreach, loop: Loop_Labels) {
	emit_scoped_block(e, s.body)
	pop_scope(e)
	place_label(e, loop.post)
	// The step to the next element is the header's.
	debug_mark_location(e, s.span)
}

@(private = "file")
close_loop :: proc(e: ^Emitter, loop: Loop_Labels) {
	if loop.counter != "" {
		step_counter(e, loop.counter, "i64")
	}
	branch(e, loop.head)
	place_label(e, loop.done)
}

// One source of a bound name: a place to read, a value in hand, or a place the
// binding *is* (`&value`). `stored` means the source is the container's own
// storage, so a managed value is cloned out for the step rather than loaded
// (design.md "Element bindings").
@(private = "file")
Foreach_Field :: struct {
	type:    Type_Id,
	address: string,
	value:   string,
	place:   bool,
	stored:  bool,
	children: []Foreach_Field,
}

@(private = "file")
owned_field_value :: proc(e: ^Emitter, field: Foreach_Field) -> string {
	value := field_value(e, field)
	if field.stored && emit_lifecycle(e, field.type).managed {
		return emit_clone_value(e, field.type, value)
	}
	return value
}

// One binding names the whole `Element`; N bindings name its fields. A
// destructuring loop never builds the record it takes apart. `indexed()` pairs
// `element` with the counter.
@(private = "file")
bind_foreach_element :: proc(e: ^Emitter, s: ^Stmt_Foreach, loop: Loop_Labels, element: Foreach_Field) {
	source := element
	pair: [2]Foreach_Field
	if s.indexed {
		pair = {element, {type = TYPE_INT, value = load(e, "i64", loop.counter)}}
		source = Foreach_Field{type = s.element_type, children = pair[:]}
	}
	bind_foreach_pattern(e, s.bindings, s.element_type, s.item_type, source)
}

@(private = "file")
bind_foreach_pattern :: proc(
	e: ^Emitter, bindings: []Foreach_Binding, logical, item: Type_Id, source: Foreach_Field,
) {
	if len(bindings) == 1 {
		if len(bindings[0].group) > 0 {
			bind_foreach_pattern(e, bindings[0].group, logical, item, source)
			return
		}
		bound := logical
		projected := foreach_projected_record(e.c, logical, item)
		if projected || len(source.children) > 0 {
			if projected { bound = item }
			slot := materialize_foreach_record(e, logical, bound, source)
			own_foreach_slot(e, bindings[0].symbol, bound, slot)
			return
		}
		bind_foreach_field(e, bindings[0].symbol, source)
		return
	}
	parts := foreach_field_children(e, logical, source)
	logical_info := underlying_info(e.c, logical)
	for position in 0 ..< len(bindings) {
		// A padding field fills no binding, so each binding takes its field's slot.
		index := named_field_slot(e.c, logical_info, position)
		field := symbol_of(e.c, logical_info.fields[index])
		projected := foreach_projected_field(e.c, item, index)
		bind_foreach_pattern(e, bindings[position:position + 1], field.type, projected, parts[index])
	}
}

@(private = "file")
foreach_field_children :: proc(e: ^Emitter, logical: Type_Id, source: Foreach_Field) -> []Foreach_Field {
	if len(source.children) > 0 { return source.children }
	info := underlying_info(e.c, logical)
	fields := make([]Foreach_Field, len(info.fields), context.temp_allocator)
	address := source.address
	if address == "" {
		address = alloca(e, llvm_type(e, logical))
		store(e, logical, source.value, address)
	}
	for field_id, index in info.fields {
		field := symbol_of(e.c, field_id)
		fields[index] = Foreach_Field{
			type = field.type,
			address = element_address(e, logical, address, index),
			place = source.place,
			stored = source.stored,
		}
	}
	return fields
}

@(private = "file")
materialize_foreach_record :: proc(
	e: ^Emitter, logical, item: Type_Id, source: Foreach_Field,
) -> string {
	logical_info := underlying_info(e.c, logical)
	item_info := underlying_info(e.c, item)
	parts := foreach_field_children(e, logical, source)
	llvm := llvm_type(e, item)
	slot := alloca(e, llvm)
	for item_field_id, index in item_info.fields {
		want := symbol_of(e.c, item_field_id).type
		have := symbol_of(e.c, logical_info.fields[index]).type
		at := element_address(e, item, slot, index)
		if want == have {
			store(e, want, owned_field_value(e, parts[index]), at)
		} else if type_is_pointer(e.c, want) {
			store(e, want, parts[index].address, at)
		} else {
			nested := materialize_foreach_record(e, have, want, parts[index])
			store(e, want, load_place(e, want, nested), at)
		}
	}
	return slot
}

@(private = "file")
bind_foreach_field :: proc(e: ^Emitter, symbol: Symbol_Id, field: Foreach_Field) {
	// A by-reference binding names the container's slot and owns nothing.
	if field.place {
		// design.md "@(packed)": a misaligned slot is read into an aligned
		// copy, which the checker never lets be borrowed.
		if sym := symbol_of(e.c, symbol); sym != nil && sym.packed_field != "" {
			if type_align(e.c, field.type) > 1 {
				e.place_align[field.address] = 1
			}
			slot := spill(e, field.type, load_place(e, field.type, field.address))
			bind_foreach_place(e, symbol, slot)
			return
		}
		bind_foreach_place(e, symbol, field.address)
		return
	}
	// Otherwise the binding is the step's own copy, disposed of even if ignored.
	slot := spill(e, field.type, owned_field_value(e, field))
	own_foreach_slot(e, symbol, field.type, slot)
}

// An owned leaf is a local of its step, whose drop `move` and `drop` cancel
// (design.md "Element bindings"); a discarded or lent one is dropped with it.
@(private = "file")
own_foreach_slot :: proc(e: ^Emitter, symbol: Symbol_Id, type: Type_Id, slot: string) {
	bind_foreach_place(e, symbol, slot)
	if sym := symbol_of(e.c, symbol); sym != nil && sym.borrowed_binding == .None {
		register_implicit_drop(e, symbol)
	} else {
		register_scope_place(e, type, slot)
	}
}

@(private = "file")
bind_foreach_place :: proc(e: ^Emitter, symbol: Symbol_Id, address: string) {
	if symbol == INVALID_SYMBOL {
		return // the discard binding names nothing
	}
	bind_local(e, symbol, address)
}

// What the loop yields before `indexed()` numbers it.
@(private = "file")
foreach_yielded_type :: proc(e: ^Emitter, s: ^Stmt_Foreach) -> Type_Id {
	if !s.indexed {
		return s.element_type
	}
	return symbol_of(e.c, underlying_info(e.c, s.element_type).fields[ELEMENT_FIRST]).type
}

@(private = "file")
field_value :: proc(e: ^Emitter, field: Foreach_Field) -> string {
	if field.value != "" {
		return field.value
	}
	return load_place(e, field.type, field.address)
}

// Decodes the code point at `offset` into `decoded`, answering the bytes it
// spans. Text is valid UTF-8 by construction, so a zero means that broke.
@(private = "file")
emit_decode_rune :: proc(e: ^Emitter, data, length, offset, decoded: string) -> string {
	used := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = call i64 @loke_rt_v1_rune_at(ptr %s, i64 %s, i64 %s, ptr %s)",
		used, data, length, offset, decoded,
	)
	stalled := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq i64 %s, 0", stalled, used)
	panic_if(e, stalled, "text.invalid", "invalid UTF-8 in a string")
	return used
}

// Whether the cursor is live, by the run-time closed flag.
@(private = "file")
emit_range_live :: proc(e: ^Emitter, signed, reverse: bool, type, current, limit, closed: string) -> string {
	open_op, closed_op := signed ? "slt" : "ult", signed ? "sle" : "ule"
	if reverse {
		open_op, closed_op = signed ? "sgt" : "ugt", signed ? "sge" : "uge"
	}
	open_test, closed_test, live := temp(e), temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp %s %s %s, %s", open_test, open_op, type, current, limit)
	fmt.sbprintfln(&e.b, "  %s = icmp %s %s %s, %s", closed_test, closed_op, type, current, limit)
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, i1 %s, i1 %s", live, closed, closed_test, open_test)
	return live
}

// Decoded code points; indexed() adds the ordinal (design.md "String iteration").
@(private = "file")
emit_text_foreach :: proc(e: ^Emitter, s: ^Stmt_Foreach) {
	type := type_underlying(e.c, expr_base(s.iterable).type)
	storage := llvm_type(e, type)
	value := load_place(e, type, spill_foreach_iterable(e, s.iterable))
	data := extract(e, storage, value, STRING_DATA)
	length := extract(e, storage, value, STRING_LEN)
	offset := new_counter(e)
	decoded := alloca(e, "i32")

	loop := open_loop(e, s.indexed)
	place_label(e, loop.head)
	current := load(e, "i64", offset)
	at_end := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp sge i64 %s, %s", at_end, current, length)
	branch_if(e, at_end, loop.done, loop.body)

	begin_step(e, loop)
	used := emit_decode_rune(e, data, length, current, decoded)
	bind_foreach_element(e, s, loop, Foreach_Field{type = TYPE_RUNE, address = decoded})
	finish_step(e, s, loop)

	advanced := temp(e)
	fmt.sbprintfln(&e.b, "  %s = add i64 %s, %s", advanced, current, used)
	fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", advanced, offset)
	close_loop(e, loop)
}

// A slot walk over a map in unspecified order (design.md "Maps"), with the
// runtime's slot position as the only cursor.
@(private = "file")
emit_map_foreach :: proc(e: ^Emitter, s: ^Stmt_Foreach) {
	container := expr_base(s.iterable).type
	ops := container_ops_global(e, container)
	header := load_place(e, container, spill_foreach_iterable(e, s.iterable))
	table := extract(e, llvm_type(e, container), header, CONTAINER_STORAGE)
	cursor := new_counter(e)
	key_out := alloca(e, "ptr")
	value_out := alloca(e, "ptr")

	loop := open_loop(e, s.indexed)
	place_label(e, loop.head)
	next := emit_map_scan(e, table, ops, load(e, "i64", cursor), key_out, value_out, cursor)
	finished := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq i64 %s, 0", finished, next)
	branch_if(e, finished, loop.done, loop.body)

	begin_step(e, loop)
	// The halves bind where the table stores them; `key, &value` makes the value
	// a place, and the key stays read-only. One name gets a built entry.
	place := s.borrows || foreach_is_place_loop(s)
	halves := []Foreach_Field{
		{type = container_key(e.c, container), address = load(e, "ptr", key_out),
		 place = place, stored = true},
		{type = container_element(e.c, container), address = load(e, "ptr", value_out),
		 place = place, stored = true},
	}
	bind_foreach_element(e, s, loop, Foreach_Field{type = foreach_yielded_type(e, s), children = halves})
	finish_step(e, s, loop)
	close_loop(e, loop)
}

// A range: the cursor is its value, so `indexed()` needs a counter of its own.
@(private = "file")
emit_range_foreach :: proc(e: ^Emitter, s: ^Stmt_Foreach) {
	yielded := foreach_yielded_type(e, s)
	element := llvm_type(e, yielded)
	low, high, closed: string
	if s.kind == .Range {
		written := s.iterable.(^Expr_Range)
		low = emit_expr(e, written.lo)
		high = emit_expr(e, written.hi)
		closed = written.op == .Range_Incl ? "true" : "false"
	} else {
		range_type := llvm_type(e, expr_base(s.iterable).type)
		value := emit_expr(e, s.iterable)
		low = extract(e, range_type, value, RANGE_LOW)
		high = extract(e, range_type, value, RANGE_HIGH)
		closed = extract(e, range_type, value, RANGE_CLOSED)
	}
	cursor := alloca(e, element)
	fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", element, low, cursor)

	loop := open_loop(e, s.indexed)
	place_label(e, loop.head)
	current := load(e, element, cursor)
	signed := type_signed(e.c, yielded) || type_is_rune(e.c, yielded)
	live := emit_range_live(e, signed, false, element, current, high, closed)
	branch_if(e, live, loop.body, loop.done)

	begin_step(e, loop)
	at := current
	if s.reversed {
		// The cursor still counts up; the value is mirrored as
		// `low + last - current`, where `last` is the final forward value.
		open_high, last, sum, mirrored := temp(e), temp(e), temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = sub %s %s, 1", open_high, element, high)
		fmt.sbprintfln(&e.b, "  %s = select i1 %s, %s %s, %s %s", last, closed, element, high, element, open_high)
		fmt.sbprintfln(&e.b, "  %s = add %s %s, %s", sum, element, low, last)
		fmt.sbprintfln(&e.b, "  %s = sub %s %s, %s", mirrored, element, sum, current)
		at = mirrored
	}
	bind_foreach_element(e, s, loop, Foreach_Field{type = yielded, value = at})
	finish_step(e, s, loop)

	// A closed range ending at the type's maximum cannot represent high+1, so
	// it finishes right after yielding high.
	at_high, finished := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq %s %s, %s", at_high, element, current, high)
	fmt.sbprintfln(&e.b, "  %s = and i1 %s, %s", finished, closed, at_high)
	step := new_label(e, "foreach.step")
	branch_if(e, finished, loop.done, step)
	place_label(e, step)
	step_counter(e, cursor, element)
	close_loop(e, loop)
}

// The next occupied slot after `current`, 0 at the end, kept in `cursor`.
@(private)
emit_map_scan :: proc(e: ^Emitter, table, ops, current, key_out, value_out, cursor: string) -> string {
	next := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = call i64 @loke_rt_v1_map_scan(ptr %s, ptr %s, i64 %s, ptr %s, ptr %s)",
		next, table, ops, current, key_out, value_out,
	)
	fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", next, cursor)
	return next
}

@(private)
step_counter :: proc(e: ^Emitter, slot, type: string) {
	current := load(e, type, slot)
	next := temp(e)
	fmt.sbprintfln(&e.b, "  %s = add %s %s, 1", next, type, current)
	fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", type, next, slot)
}

// A loop over `0 ..< count` in an `i64` cursor. `index` is the current value;
// `close_counted_loop` steps it and places `done`.
@(private)
Counted_Loop :: struct {
	cursor, index, head, done: string,
}

// `cursor` comes from `new_counter`, so a caller can publish it to a cleanup
// before the loop's first test. `compare` is the `icmp` predicate.
@(private)
open_counted_loop :: proc(e: ^Emitter, cursor, prefix, count: string, compare := "slt") -> Counted_Loop {
	head := new_label(e, fmt.aprintf("%s.head", prefix))
	body := new_label(e, fmt.aprintf("%s.body", prefix))
	done := new_label(e, fmt.aprintf("%s.done", prefix))
	place_label(e, head)
	index := load(e, "i64", cursor)
	more := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp %s i64 %s, %s", more, compare, index, count)
	branch_if(e, more, body, done)
	place_label(e, body)
	return Counted_Loop{cursor = cursor, index = index, head = head, done = done}
}

@(private)
close_counted_loop :: proc(e: ^Emitter, loop: Counted_Loop) {
	next := temp(e)
	fmt.sbprintfln(&e.b, "  %s = add i64 %s, 1", next, loop.index)
	fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", next, loop.cursor)
	branch(e, loop.head)
	place_label(e, loop.done)
}

// A fixed array, a slice or a dynamic array: an index loop, with no iterator
// object at all, whose cursor doubles as the `indexed()` counter.
@(private = "file")
emit_sequence_foreach :: proc(e: ^Emitter, s: ^Stmt_Foreach) {
	yielded := foreach_yielded_type(e, s)
	source := expr_base(s.iterable).type
	base, limit: string
	#partial switch s.kind {
	case .Array:
		// A place, so `&value` names the element itself rather than a copy.
		base = spill_foreach_iterable(e, s.iterable)
		limit = fmt.aprintf("%d", s.count)

	case .Slice:
		// Evaluated once; the loop walks the root through the data word.
		value := emit_expr(e, s.iterable)
		base, limit = ptr_len_parts(e, llvm_type(e, source), value)

	case .Dynamic:
		// The current allocation up to `len`, kept current by the loop's loan.
		header := load_place(e, source, spill_foreach_iterable(e, s.iterable))
		base = extract(e, llvm_type(e, source), header, CONTAINER_STORAGE)
		limit = extract(e, llvm_type(e, source), header, CONTAINER_LEN)
	}

	loop := open_loop(e, true)
	place_label(e, loop.head)
	current := load(e, "i64", loop.counter)
	test := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp slt i64 %s, %s", test, current, limit)
	branch_if(e, test, loop.body, loop.done)

	begin_step(e, loop)
	// `reversed()` flips only the element reached, so `indexed()` still counts
	// from zero (design.md "Reverse iteration").
	at := current
	if s.reversed {
		last, flipped := temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = sub i64 %s, 1", last, limit)
		fmt.sbprintfln(&e.b, "  %s = sub i64 %s, %s", flipped, last, current)
		at = flipped
	}
	// `&value` and a lending traversal bind the element's address; only a
	// copying loop owns a clone for the step (design.md "Borrowing iteration").
	bind_foreach_element(e, s, loop, Foreach_Field{
		type = yielded, address = gep_at(e, llvm_type(e, yielded), base, at),
		place = foreach_is_place_loop(s) || s.borrows, stored = true,
	})
	finish_step(e, s, loop)
	close_loop(e, loop)
}

// A user iterable: `it := x.iter()`, then `next(&it)` per step.
@(private = "file")
emit_protocol_foreach :: proc(e: ^Emitter, s: ^Stmt_Foreach) {
	iter_sym := symbol_of(e.c, s.iter_symbol)
	subject_type := iter_sym.params[0]
	subject_mode := symbol_param_mode(e.c, iter_sym, 0)
	// However `iter` takes it, a temporary source moves into the loop scope for
	// the statement's duration.
	subject := spill_foreach_iterable_at(e, s.iterable, subject_type)
	if !param_mode_is_pointer(subject_mode) {
		subject = load_place(e, subject_type, subject)
	}
	iterator_type := llvm_type(e, s.iterator_type)
	iterator := alloca(e, iterator_type)
	made := emit_call_result(
		e, s.iterator_type, callee_name(e, s.iter_symbol),
		fmt.aprintf("%s %s", param_llvm(e, subject_type, subject_mode), subject),
	)
	store(e, s.iterator_type, made, iterator)
	register_scope_place(e, s.iterator_type, iterator)

	loop := open_loop(e, s.indexed)
	place_label(e, loop.head)
	option := symbol_of(e.c, s.next_symbol).result
	produced := emit_call_result(e, option, callee_name(e, s.next_symbol), fmt.aprintf("ptr %s", iterator))
	ok := emit_union_tag_is(e, option, produced, union_index_of(e.c, option, "some"))
	slot := emit_union_spill(e, option, produced)
	branch_if(e, ok, loop.body, loop.done)

	begin_step(e, loop)
	payload := option_payload(e.c, option)
	element := lent_yield_field(e, foreach_yielded_type(e, s), payload, emit_union_payload(e, option, payload, slot))
	bind_foreach_element(e, s, loop, element)
	finish_step(e, s, loop)
	close_loop(e, loop)
}

// What `next` hands over: an owned `Element` or part is the value, which the step
// takes without a copy; a lent one is the place its pointer names, and `stored`
// because one name over a record copies it in; a record `Yield` has one per part.
@(private = "file")
lent_yield_field :: proc(e: ^Emitter, logical, payload: Type_Id, value: string) -> Foreach_Field {
	if logical == payload {
		return Foreach_Field{type = logical, value = value}
	}
	if type_is_pointer(e.c, payload) {
		return Foreach_Field{type = logical, address = value, place = true, stored = true}
	}
	logical_info := underlying_info(e.c, logical)
	payload_info := underlying_info(e.c, payload)
	children := make([]Foreach_Field, len(logical_info.fields), context.temp_allocator)
	for logical_field_id, index in logical_info.fields {
		logical_field := symbol_of(e.c, logical_field_id)
		payload_field := symbol_of(e.c, payload_info.fields[index])
		children[index] = lent_yield_field(e, logical_field.type, payload_field.type, record_part(e, payload, value, index))
	}
	return Foreach_Field{type = logical, children = children}
}

@(private = "file")
spill_foreach_iterable :: proc(e: ^Emitter, expr: Expr) -> string {
	return spill_foreach_iterable_at(e, expr, expr_base(expr).type)
}

// A foreach borrows its source for the whole statement: a place has its owner,
// and a produced value moves into the loop scope.
@(private = "file")
spill_foreach_iterable_at :: proc(e: ^Emitter, expr: Expr, as_type: Type_Id) -> string {
	base := expr_base(expr)
	if materialization_of(e.c, expr) != nil || base.value_category == .Place {
		return emit_address_at(e, expr, as_type)
	}
	value := emit_expr_at(e, expr, as_type)
	slot := spill(e, as_type, value)
	if !base_is_const(base) {
		register_scope_place(e, as_type, slot)
	}
	return slot
}

@(private)
emit_synth_iter :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	source := llvm_type(e, symbol.params[0])
	iterator := llvm_type(e, symbol.result)
	reversed := symbol.synth == .Range_Iter_Reverse ||
	            symbol.synth == .Array_Iter_Reverse ||
	            symbol.synth == .Dynamic_Iter_Reverse
	open_function(
		e, "define %s%s %s(%s %%arg0)",
		llvm_linkage(name), iterator, name, synth_param_llvm(e, symbol, 0),
	)
	self := synth_receiver_value(e, symbol)
	out := ""
	#partial switch symbol.synth {
	case .Array_Iter, .Array_Iter_Reverse, .Dynamic_Iter, .Dynamic_Iter_Reverse:
		// `{ view, index, reversed }`. A reverse cursor starts one past the end and
		// decrements before use.
		view_type := llvm_type(e, symbol_of(e.c, type_of(e.c, symbol.result).fields[ITER_ARRAY_DATA]).type)
		view, index := self, "0"
		source_info := underlying_info(e.c, symbol.params[0])
		switch {
		case symbol.synth == .Dynamic_Iter || symbol.synth == .Dynamic_Iter_Reverse:
			// The current allocation as a slice; capacity and allocator stay behind.
			length := extract(e, source, self, CONTAINER_LEN)
			view = emit_ptr_len(e, view_type, extract(e, source, self, CONTAINER_STORAGE), length)
			index = length
		case source_info.kind == .Array:
			index = fmt.aprintf("%d", source_info.count)
			view = emit_ptr_len(e, view_type, "%arg0", index)
		case:
			index = extract(e, source, self, SLICE_LEN)
		}
		first := insert(e, iterator, "undef", view_type, view, ITER_ARRAY_DATA)
		second := insert(e, iterator, first, "i64", reversed ? index : "0", ITER_ARRAY_INDEX)
		out = insert(e, iterator, second, "i1", reversed ? "true" : "false", ITER_ARRAY_REVERSED)

	case .Map_Iter, .Map_View_Iter:
		// `{ table, 0 }`. A view already is the table pointer; a null table is the
		// empty map, which the runtime's scan finishes at once.
		field := symbol.synth == .Map_View_Iter ? VIEW_SOURCE : CONTAINER_STORAGE
		first := insert(e, iterator, "undef", "ptr", extract(e, source, self, field), ITER_MAP_TABLE)
		out = insert(e, iterator, first, "i64", "0", ITER_MAP_CURSOR)

	case .Text_Iter:
		// A `string`, a `string_view` and the rune-offset view all hold `{ data, len }`.
		view := ""
		if underlying_info(e.c, symbol.params[0]).kind == .Struct {
			view = extract(e, source, self, VIEW_SOURCE)
		} else {
			data := extract(e, source, self, STRING_DATA)
			length := extract(e, source, self, STRING_LEN)
			view = emit_ptr_len(e, STRING_VIEW_TYPE, data, length)
		}
		first := insert(e, iterator, "undef", STRING_VIEW_TYPE, view, ITER_TEXT_VIEW)
		out = insert(e, iterator, first, "i64", "0", ITER_TEXT_OFFSET)

	case:
		element := llvm_type(e, type_of(e.c, symbol.params[0]).element)
		low := extract(e, source, self, RANGE_LOW)
		high := extract(e, source, self, RANGE_HIGH)
		closed := extract(e, source, self, RANGE_CLOSED)
		current, bound := reversed ? high : low, reversed ? low : high
		step1 := insert(e, iterator, "undef", element, current, ITER_RANGE_CURRENT)
		step2 := insert(e, iterator, step1, element, bound, ITER_RANGE_HIGH)
		step3 := insert(e, iterator, step2, "i1", closed, ITER_RANGE_CLOSED)
		out = insert(e, iterator, step3, "i1", reversed ? "true" : "false", ITER_RANGE_REVERSED)
	}
	fmt.sbprintfln(&e.b, "  ret %s %s", iterator, out)
	fmt.sbprintln(&e.b, "}")
}

// The end of a synthesized `next`: exhaustion is `.none`, `Option`'s all-zero
// designated zero.
@(private)
close_synth_next :: proc(e: ^Emitter, option: Type_Id, stop_label: string) {
	place_label(e, stop_label)
	emit_ret(e, option, "zeroinitializer")
	fmt.sbprintln(&e.b, "}")
}

@(private)
emit_synth_range_next :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	option := symbol.result
	step := option_payload(e.c, option)
	element := llvm_type(e, step)
	iterator := llvm_type(e, symbol.params[0])
	signed := type_signed(e.c, step) || type_is_rune(e.c, step)

	open_synth_receiver(e, name, option)
	current_ptr := gep_field(e, iterator, "%arg0", ITER_RANGE_CURRENT)
	current := load(e, element, current_ptr)
	high_ptr := gep_field(e, iterator, "%arg0", ITER_RANGE_HIGH)
	high := load(e, element, high_ptr)
	closed_ptr := gep_field(e, iterator, "%arg0", ITER_RANGE_CLOSED)
	closed := load(e, "i1", closed_ptr)
	reversed_ptr := gep_field(e, iterator, "%arg0", ITER_RANGE_REVERSED)
	reversed := load(e, "i1", reversed_ptr)
	forward_label, reverse_label := new_label(e, "next.forward"), new_label(e, "next.reverse")
	stop_label := new_label(e, "next.stop")
	branch_if(e, reversed, reverse_label, forward_label)

	place_label(e, forward_label)
	live := emit_range_live(e, signed, false, element, current, high, closed)
	yield_label := new_label(e, "next.forward.yield")
	branch_if(e, live, yield_label, stop_label)

	// Yielding a closed range's high clears `closed` instead of stepping past it.
	place_label(e, yield_label)
	stepped, at_high, last := temp(e), temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = add %s %s, 1", stepped, element, current)
	fmt.sbprintfln(&e.b, "  %s = icmp eq %s %s, %s", at_high, element, current, high)
	fmt.sbprintfln(&e.b, "  %s = and i1 %s, %s", last, closed, at_high)
	next_current, next_closed := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, %s %s, %s %s", next_current, last, element, current, element, stepped)
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, i1 false, i1 %s", next_closed, last, closed)
	fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", element, next_current, current_ptr)
	fmt.sbprintfln(&e.b, "  store i1 %s, ptr %s", next_closed, closed_ptr)
	emit_ret(e, option, emit_option_some(e, option, current))

	place_label(e, reverse_label)
	reverse_live := emit_range_live(e, signed, true, element, current, high, closed)
	reverse_yield := new_label(e, "next.reverse.yield")
	branch_if(e, reverse_live, reverse_yield, stop_label)

	place_label(e, reverse_yield)
	previous, yielded := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = sub %s %s, 1", previous, element, current)
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, %s %s, %s %s", yielded, closed, element, current, element, previous)
	fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", element, yielded, current_ptr)
	fmt.sbprintfln(&e.b, "  store i1 false, ptr %s", closed_ptr)
	emit_ret(e, option, emit_option_some(e, option, yielded))

	close_synth_next(e, option, stop_label)
}

// `next` for a slice, or an array viewed as one, over a `{ data, index, reversed }`
// cursor: the element's address.
@(private)
emit_synth_slice_next :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	option := symbol.result
	element := llvm_type(e, type_of(e.c, option_payload(e.c, option)).element)
	iterator := llvm_type(e, symbol.params[0])
	stored := llvm_type(e, symbol_of(e.c, type_of(e.c, symbol.params[0]).fields[ITER_ARRAY_DATA]).type)

	open_synth_receiver(e, name, option)
	index_ptr := gep_field(e, iterator, "%arg0", ITER_ARRAY_INDEX)
	index := load(e, "i64", index_ptr)
	reversed := load(e, "i1", gep_field(e, iterator, "%arg0", ITER_ARRAY_REVERSED))
	slice := load(e, stored, gep_field(e, iterator, "%arg0", ITER_ARRAY_DATA))
	bound := extract(e, stored, slice, SLICE_LEN)
	forward_live, reverse_live, live := temp(e), temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp slt i64 %s, %s", forward_live, index, bound)
	fmt.sbprintfln(&e.b, "  %s = icmp sgt i64 %s, 0", reverse_live, index)
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, i1 %s, i1 %s", live, reversed, reverse_live, forward_live)
	yield_label, stop_label := new_label(e, "next.yield"), new_label(e, "next.stop")
	branch_if(e, live, yield_label, stop_label)

	place_label(e, yield_label)
	base := extract(e, stored, slice, SLICE_DATA)
	previous, at := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = sub i64 %s, 1", previous, index)
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, i64 %s, i64 %s", at, reversed, previous, index)
	slot := gep_at(e, element, base, at)
	stepped, next_index := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = add i64 %s, 1", stepped, index)
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, i64 %s, i64 %s", next_index, reversed, previous, stepped)
	fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", next_index, index_ptr)
	emit_ret(e, option, emit_option_some(e, option, slot))

	close_synth_next(e, option, stop_label)
}

// `next` for a map's entries, `keys()` and `values()`, in the same slot order a
// direct `foreach` walks.
@(private)
emit_synth_map_next :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	option := symbol.result
	yielded := option_payload(e.c, option)
	element := llvm_type(e, yielded)
	iterator := llvm_type(e, symbol.params[0])
	subject := type_of(e.c, symbol.params[0]).key
	ops := container_ops_global(e, subject)

	open_synth_receiver(e, name, option)
	table_ptr := gep_field(e, iterator, "%arg0", ITER_MAP_TABLE)
	table := load(e, "ptr", table_ptr)
	cursor_ptr := gep_field(e, iterator, "%arg0", ITER_MAP_CURSOR)
	cursor := load(e, "i64", cursor_ptr)
	key_out := alloca(e, "ptr")
	value_out := alloca(e, "ptr")
	next := emit_map_scan(e, table, ops, cursor, key_out, value_out, cursor_ptr)
	finished := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq i64 %s, 0", finished, next)
	yield_label, stop_label := new_label(e, "next.yield"), new_label(e, "next.stop")
	branch_if(e, finished, stop_label, yield_label)

	place_label(e, yield_label)
	out := ""
	#partial switch symbol.synth {
	case .Map_Keys_Next:
		out = load(e, "ptr", key_out)
	case .Map_Values_Next:
		out = load(e, "ptr", value_out)
	case:
		// The table stores the two halves, so an entry is a record of their addresses.
		built := insert(e, element, "undef", "ptr", load(e, "ptr", key_out), ELEMENT_FIRST)
		out = insert(e, element, built, "ptr", load(e, "ptr", value_out), ELEMENT_SECOND)
	}
	emit_ret(e, option, emit_option_some(e, option, out))

	close_synth_next(e, option, stop_label)
}

// One decoded code point per step; `rune_offsets()` also yields its byte offset.
@(private)
emit_synth_text_next :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	option := symbol.result
	yielded := option_payload(e.c, option)
	iterator := llvm_type(e, symbol.params[0])
	open_synth_receiver(e, name, option)

	view := load(e, STRING_VIEW_TYPE, gep_field(e, iterator, "%arg0", ITER_TEXT_VIEW))
	data, length := ptr_len_parts(e, STRING_VIEW_TYPE, view)
	offset_ptr := gep_field(e, iterator, "%arg0", ITER_TEXT_OFFSET)
	offset := load(e, "i64", offset_ptr)
	at_end := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp sge i64 %s, %s", at_end, offset, length)
	yield_label, stop_label := new_label(e, "next.yield"), new_label(e, "next.stop")
	branch_if(e, at_end, stop_label, yield_label)

	place_label(e, yield_label)
	decoded := alloca(e, "i32")
	used := emit_decode_rune(e, data, length, offset, decoded)
	advanced := temp(e)
	fmt.sbprintfln(&e.b, "  %s = add i64 %s, %s", advanced, offset, used)
	fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", advanced, offset_ptr)
	value := load(e, "i32", decoded)
	if symbol.synth == .Rune_Offsets_Next {
		record := llvm_type(e, yielded)
		built := insert(e, record, "undef", "i32", value, ELEMENT_FIRST)
		value = insert(e, record, built, "i64", offset, ELEMENT_SECOND)
	}
	emit_ret(e, option, emit_option_some(e, option, value))

	close_synth_next(e, option, stop_label)
}

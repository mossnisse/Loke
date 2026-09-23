// Iteration lowering and synthesized iterator bodies.
//
// Part of the textual LLVM backend; see compiler-architecture.md.
package lokec

import "core:fmt"

// ============================================================== iteration ==

// design.md "Iteration protocol": `next` yields `Option(Element)`.
@(private)
option_payload :: proc(c: ^Compiler, option_type: Type_Id) -> Type_Id {
	return union_variant_payload(c, option_type, union_index_of(c, option_type, "some"))
}

@(private)
emit_option_some :: proc(e: ^Emitter, option_type: Type_Id, payload: string) -> string {
	return emit_union_value(e, option_type, union_index_of(e.c, option_type, "some"), payload)
}

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

	outer_break, outer_continue := e.break_label, e.continue_label
	outer_break_depth, outer_continue_depth := e.break_depth, e.continue_depth
	defer {
		e.break_label, e.continue_label = outer_break, outer_continue
		e.break_depth, e.continue_depth = outer_break_depth, outer_continue_depth
	}
	push_scope(e, nil)
	defer pop_scope(e)
	// `break` lands in the loop scope, whose exit disposes of the iterator once.
	e.break_depth = len(e.cleanups)

	#partial switch s.kind {
	case .Protocol:
		emit_protocol_foreach(e, s)
	case .Text:
		emit_text_foreach(e, s)
	case .Map:
		emit_map_foreach(e, s)
	case:
		emit_indexed_foreach(e, s)
	}
}

@(private = "file")
Loop_Labels :: struct {
	head, body, post, done: string,
}

// The labels every loop shape uses, with `break` and `continue` aimed at them.
@(private = "file")
open_loop :: proc(e: ^Emitter) -> Loop_Labels {
	loop := Loop_Labels{
		new_label(e, "foreach.head"), new_label(e, "foreach.body"),
		new_label(e, "foreach.post"), new_label(e, "foreach.done"),
	}
	e.break_label, e.continue_label = loop.done, loop.post
	e.continue_depth = len(e.cleanups)
	return loop
}

// Each step has its own cleanup scope at the depth `continue` unwinds to, so a
// value the step owns is disposed of once per step on every exit path.
@(private = "file")
begin_step :: proc(e: ^Emitter, loop: Loop_Labels) {
	place_label(e, loop.body)
	push_scope(e, nil)
}

// Runs the body, closes the step, and opens the `post` block.
@(private = "file")
finish_step :: proc(e: ^Emitter, s: ^Stmt_Foreach, loop: Loop_Labels) {
	emit_scoped_block(e, s.body)
	pop_scope(e)
	branch(e, loop.post)
	place_label(e, loop.post)
}

@(private = "file")
close_loop :: proc(e: ^Emitter, loop: Loop_Labels) {
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
// destructuring loop never builds the record it takes apart.
@(private = "file")
bind_foreach_fields :: proc(e: ^Emitter, s: ^Stmt_Foreach, fields: []Foreach_Field) {
	source := Foreach_Field{type = s.element_type, children = fields}
	if len(fields) == 1 && fields[0].type == s.element_type {
		source = fields[0]
	}
	bind_foreach_pattern(e, s.bindings, s.element_type, s.item_type, source)
}

@(private = "file")
bind_foreach_pattern :: proc(
	e: ^Emitter, bindings: []Foreach_Binding, logical, item: Type_Id, source: Foreach_Field,
) {
	if len(bindings) == 1 && len(bindings[0].group) > 0 {
		bind_foreach_pattern(e, bindings[0].group, logical, item, source)
		return
	}
	if len(bindings) == 1 && len(bindings[0].group) == 0 {
		bound := logical
		projected := foreach_projected_record(e.c, logical, item)
		if projected || len(source.children) > 0 {
			if projected { bound = item }
			slot := materialize_foreach_record(e, logical, bound, source)
			register_scope_place(e, bound, slot)
			bind_foreach_place(e, bindings[0].symbol, slot)
			return
		}
		bind_foreach_field(e, bindings[0].symbol, source)
		return
	}
	parts := foreach_field_children(e, logical, source)
	logical_info := type_of(e.c, type_underlying(e.c, logical))
	item_info := type_of(e.c, type_underlying(e.c, item))
	for binding, index in bindings {
		field := symbol_of(e.c, logical_info.fields[index])
		projected := INVALID_TYPE
		if item_info != nil && item_info.kind == .Struct && index < len(item_info.fields) {
			if projected_field := symbol_of(e.c, item_info.fields[index]); projected_field != nil {
				projected = projected_field.type
			}
		}
		if len(binding.group) > 0 {
			bind_foreach_pattern(e, binding.group, field.type, projected, parts[index])
		} else if foreach_projected_record(e.c, field.type, projected) {
			slot := materialize_foreach_record(e, field.type, projected, parts[index])
			register_scope_place(e, projected, slot)
			bind_foreach_place(e, binding.symbol, slot)
		} else {
			bind_foreach_field(e, binding.symbol, parts[index])
		}
	}
}

@(private = "file")
foreach_projected_record :: proc(c: ^Compiler, logical, item: Type_Id) -> bool {
	if logical == INVALID_TYPE || item == INVALID_TYPE || logical == item { return false }
	a, b := underlying_info(c, logical), underlying_info(c, item)
	return a != nil && b != nil && a.kind == .Struct && b.kind == .Struct
}

@(private = "file")
foreach_field_children :: proc(e: ^Emitter, logical: Type_Id, source: Foreach_Field) -> []Foreach_Field {
	if len(source.children) > 0 { return source.children }
	info := type_of(e.c, type_underlying(e.c, logical))
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
			address = gep_field(e, llvm_type(e, logical), address, index),
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
	logical_info := type_of(e.c, type_underlying(e.c, logical))
	item_info := type_of(e.c, type_underlying(e.c, item))
	parts := foreach_field_children(e, logical, source)
	llvm := llvm_type(e, item)
	slot := alloca(e, llvm)
	for item_field_id, index in item_info.fields {
		want := symbol_of(e.c, item_field_id).type
		have := symbol_of(e.c, logical_info.fields[index]).type
		at := gep_field(e, llvm, slot, index)
		if want == have {
			store(e, want, owned_field_value(e, parts[index]), at)
		} else if type_is_pointer(e.c, want) {
			store(e, want, parts[index].address, at)
		} else {
			nested := materialize_foreach_record(e, have, want, parts[index])
			store(e, want, load(e, llvm_type(e, want), nested), at)
		}
	}
	return slot
}

@(private = "file")
bind_foreach_field :: proc(e: ^Emitter, symbol: Symbol_Id, field: Foreach_Field) {
	// A by-reference binding names the container's slot and owns nothing.
	if field.place {
		bind_foreach_place(e, symbol, field.address)
		return
	}
	// Otherwise the binding is the step's own copy, disposed of even if ignored.
	slot := alloca(e, llvm_type(e, field.type))
	store(e, field.type, owned_field_value(e, field), slot)
	register_scope_place(e, field.type, slot)
	bind_foreach_place(e, symbol, slot)
}

@(private = "file")
bind_foreach_place :: proc(e: ^Emitter, symbol: Symbol_Id, address: string) {
	if symbol == INVALID_SYMBOL {
		return // the discard binding names nothing
	}
	bind_local(e, symbol, address)
}

// `indexed()` pairs the wrapped element (one field again, even if the
// traversal produced several) with the counter.
@(private = "file")
with_index :: proc(e: ^Emitter, s: ^Stmt_Foreach, fields: []Foreach_Field, counter: string) -> []Foreach_Field {
	if !s.indexed {
		return fields
	}
	inner := fields[0]
	if len(fields) > 1 {
		inner = Foreach_Field{type = foreach_yielded_type(e, s), children = fields}
	}
	out := make([dynamic]Foreach_Field, 0, 2, context.temp_allocator)
	append(&out, inner)
	append(&out, Foreach_Field{type = TYPE_INT, value = counter})
	return out[:]
}

// What the loop yields before `indexed()` numbers it.
@(private = "file")
foreach_yielded_type :: proc(e: ^Emitter, s: ^Stmt_Foreach) -> Type_Id {
	if !s.indexed {
		return s.element_type
	}
	return symbol_of(e.c, type_of(e.c, type_underlying(e.c, s.element_type)).fields[ELEMENT_FIRST]).type
}

@(private = "file")
field_value :: proc(e: ^Emitter, field: Foreach_Field) -> string {
	if field.value != "" {
		return field.value
	}
	return load(e, llvm_type(e, field.type), field.address)
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

// Whether a range cursor is still in range: `<`/`<=` forward, `>`/`>=` in
// reverse, chosen by the run-time `closed` flag.
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

// Decoded code points; `rune_offsets()` adds the byte offset and `indexed()`
// the rune ordinal (design.md "String iteration").
@(private = "file")
emit_text_foreach :: proc(e: ^Emitter, s: ^Stmt_Foreach) {
	type := type_underlying(e.c, expr_base(s.iterable).type)
	storage := llvm_type(e, type)
	value := load(e, storage, spill_foreach_iterable(e, s.iterable))
	data := extract(e, storage, value, STRING_DATA)
	length := extract(e, storage, value, STRING_LEN)
	offset := alloca(e, "i64")
	decoded := temp(e)
	fmt.sbprintfln(&e.b, "  store i64 0, ptr %s", offset)
	alloca_named(e, decoded, "i32")

	ordinal := ""
	if s.indexed {
		ordinal = alloca(e, "i64")
		fmt.sbprintfln(&e.b, "  store i64 0, ptr %s", ordinal)
	}

	loop := open_loop(e)
	place_label(e, loop.head)
	current := load(e, "i64", offset)
	at_end := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp sge i64 %s, %s", at_end, current, length)
	branch_if(e, at_end, loop.done, loop.body)

	begin_step(e, loop)
	used := emit_decode_rune(e, data, length, current, decoded)
	fields := []Foreach_Field{{type = TYPE_RUNE, address = decoded}}
	counter := ordinal == "" ? "" : load(e, "i64", ordinal)
	bind_foreach_fields(e, s, with_index(e, s, fields, counter))
	finish_step(e, s, loop)

	advanced := temp(e)
	fmt.sbprintfln(&e.b, "  %s = add i64 %s, %s", advanced, current, used)
	fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", advanced, offset)
	if ordinal != "" {
		step_counter(e, ordinal, "i64")
	}
	close_loop(e, loop)
}

// A slot walk over a map in unspecified order (design.md "Maps"), with the
// runtime's slot position as the only cursor.
@(private = "file")
emit_map_foreach :: proc(e: ^Emitter, s: ^Stmt_Foreach) {
	container := expr_base(s.iterable).type
	ops := container_ops_global(e, container)
	header := spill_foreach_iterable(e, s.iterable)
	table := load(e, "ptr", header)
	cursor := alloca(e, "i64")
	fmt.sbprintfln(&e.b, "  store i64 0, ptr %s", cursor)
	key_out := alloca(e, "ptr")
	value_out := alloca(e, "ptr")
	counter := ""
	if s.indexed {
		counter = alloca(e, "i64")
		fmt.sbprintfln(&e.b, "  store i64 0, ptr %s", counter)
	}

	loop := open_loop(e)
	place_label(e, loop.head)
	current := load(e, "i64", cursor)
	next := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = call i64 @loke_rt_v1_map_scan(ptr %s, ptr %s, i64 %s, ptr %s, ptr %s)",
		next, table, ops, current, key_out, value_out,
	)
	fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", next, cursor)
	finished := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq i64 %s, 0", finished, next)
	branch_if(e, finished, loop.done, loop.body)

	begin_step(e, loop)
	// The halves bind where the table stores them; `key, &value` makes the value
	// a place, and the key stays read-only. One name gets a built entry.
	place := s.borrows || foreach_is_place_loop(s)
	fields := []Foreach_Field{
		{type = container_key(e.c, container), address = load(e, "ptr", key_out),
		 place = place, stored = true},
		{type = container_element(e.c, container), address = load(e, "ptr", value_out),
		 place = place, stored = true},
	}
	numbered := counter == "" ? "" : load(e, "i64", counter)
	bind_foreach_fields(e, s, with_index(e, s, fields, numbered))
	finish_step(e, s, loop)
	if counter != "" {
		step_counter(e, counter, "i64")
	}
	close_loop(e, loop)
}

// A range or a sequence: an index loop, with no iterator object at all.
@(private = "file")
emit_indexed_foreach :: proc(e: ^Emitter, s: ^Stmt_Foreach) {
	yielded := foreach_yielded_type(e, s)
	element := llvm_type(e, yielded)
	cursor := temp(e)
	limit, closed, array_slot, floor := "", "", "", ""
	counter_type := element
	is_range := s.kind == .Range || s.kind == .Stored_Range

	switch s.kind {
	case .Range:
		written := s.iterable.(^Expr_Range)
		floor = emit_expr(e, written.lo)
		limit = emit_expr(e, written.hi)
		closed = written.op == .Range_Incl ? "true" : "false"

	case .Stored_Range:
		range_type := llvm_type(e, expr_base(s.iterable).type)
		value := emit_expr(e, s.iterable)
		floor = extract(e, range_type, value, RANGE_LOW)
		limit = extract(e, range_type, value, RANGE_HIGH)
		closed = extract(e, range_type, value, RANGE_CLOSED)

	case .Array:
		// A place, so `&value` names the element itself rather than a copy.
		array_slot = spill_foreach_iterable(e, s.iterable)
		limit = fmt.aprintf("%d", s.count)

	case .Slice:
		// Evaluated once; the loop walks the root through the data word.
		slice_type := llvm_type(e, expr_base(s.iterable).type)
		value := emit_expr(e, s.iterable)
		array_slot = extract(e, slice_type, value, SLICE_DATA)
		limit = extract(e, slice_type, value, SLICE_LEN)

	case .Dynamic:
		// The current allocation up to `len`, kept current by the loop's loan.
		header := spill_foreach_iterable(e, s.iterable)
		array_slot = load(e, "ptr", header)
		limit = load(e, "i64", gep_field(e, CONTAINER_TYPE, header, CONTAINER_LEN))

	case .Unresolved, .Static, .Protocol, .Text, .Map:
		backend_fail(e, "an unresolved `foreach` reached emission")
		return
	}
	if is_range {
		alloca_named(e, cursor, element)
		fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", element, floor, cursor)
	} else {
		counter_type = "i64"
		alloca_named(e, cursor, "i64")
		fmt.sbprintfln(&e.b, "  store i64 0, ptr %s", cursor)
	}

	loop := open_loop(e)

	// A range's cursor is its value, so `indexed()` needs a counter of its own.
	counter := ""
	if s.indexed && is_range {
		counter = alloca(e, "i64")
		fmt.sbprintfln(&e.b, "  store i64 0, ptr %s", counter)
	}

	place_label(e, loop.head)
	current := load(e, counter_type, cursor)
	test := ""
	if is_range {
		signed := type_signed(e.c, yielded) || type_is_rune(e.c, yielded)
		test = emit_range_live(e, signed, false, counter_type, current, limit, closed)
	} else {
		test = temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp slt i64 %s, %s", test, current, limit)
	}
	branch_if(e, test, loop.body, loop.done)

	begin_step(e, loop)
	numbered := counter == "" ? current : load(e, "i64", counter)
	bind_indexed_value(e, s, current, array_slot, element, limit, floor, closed, numbered)
	finish_step(e, s, loop)

	if is_range {
		// A closed range ending at the type's maximum cannot represent high+1, so
		// it finishes right after yielding high.
		at_high, finished := temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp eq %s %s, %s", at_high, counter_type, current, limit)
		fmt.sbprintfln(&e.b, "  %s = and i1 %s, %s", finished, closed, at_high)
		step := new_label(e, "foreach.step")
		branch_if(e, finished, loop.done, step)
		place_label(e, step)
	}
	step_counter(e, cursor, counter_type)
	if counter != "" {
		step_counter(e, counter, "i64")
	}
	close_loop(e, loop)
}

@(private = "file")
step_counter :: proc(e: ^Emitter, slot, type: string) {
	current := load(e, type, slot)
	next := temp(e)
	fmt.sbprintfln(&e.b, "  %s = add %s %s, 1", next, type, current)
	fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", type, next, slot)
}

@(private = "file")
bind_indexed_value :: proc(
	e: ^Emitter,
	s: ^Stmt_Foreach,
	current, array_slot, element: string,
	limit, floor, closed: string,
	numbered: string,
) {
	yielded := foreach_yielded_type(e, s)
	field: Foreach_Field
	if s.kind == .Range || s.kind == .Stored_Range {
		at := current
		if s.adapter == .Reversed {
			// The cursor still counts up; the value is mirrored as
			// `low + last - current`, where `last` is the final forward value.
			last, mirrored := temp(e), temp(e)
			open_high := temp(e)
			fmt.sbprintfln(&e.b, "  %s = sub %s %s, 1", open_high, element, limit)
			fmt.sbprintfln(&e.b, "  %s = select i1 %s, %s %s, %s %s", last, closed, element, limit, element, open_high)
			sum := temp(e)
			fmt.sbprintfln(&e.b, "  %s = add %s %s, %s", sum, element, floor, last)
			fmt.sbprintfln(&e.b, "  %s = sub %s %s, %s", mirrored, element, sum, current)
			at = mirrored
		}
		field = Foreach_Field{type = yielded, value = at}
	} else {
		// `reversed()` flips only the element reached, so `indexed()` still counts
		// from zero (design.md "Reverse iteration").
		at := current
		if s.adapter == .Reversed {
			last, flipped := temp(e), temp(e)
			fmt.sbprintfln(&e.b, "  %s = sub i64 %s, 1", last, limit)
			fmt.sbprintfln(&e.b, "  %s = sub i64 %s, %s", flipped, last, current)
			at = flipped
		}
		address := temp(e)
		if s.kind == .Slice || s.kind == .Dynamic {
			fmt.sbprintfln(
				&e.b,
				"  %s = getelementptr inbounds %s, ptr %s, i64 %s",
				address, element, array_slot, at,
			)
		} else {
			fmt.sbprintfln(
				&e.b,
				"  %s = getelementptr inbounds [%d x %s], ptr %s, i64 0, i64 %s",
				address, s.count, element, array_slot, at,
			)
		}
		// `&value` and a lending traversal bind the element's address; only a
		// copying loop owns a clone for the step (design.md "Borrowing iteration").
		field = Foreach_Field{
			type = yielded, address = address, place = foreach_is_place_loop(s) || s.borrows, stored = true,
		}
	}
	bind_foreach_fields(e, s, with_index(e, s, []Foreach_Field{field}, numbered))
}

// A user iterable: `it := x.iter()`, then `next(&it)` per step.
@(private = "file")
emit_protocol_foreach :: proc(e: ^Emitter, s: ^Stmt_Foreach) {
	iter_sym := symbol_of(e.c, s.iter_symbol)
	// An immutable `iter` receiver takes the source's address; a temporary
	// source moves into the loop scope for the statement's duration.
	subject_by_ptr := param_mode_is_pointer(symbol_param_mode(e.c, iter_sym, 0))
	subject := subject_by_ptr ? spill_foreach_iterable_at(e, s.iterable, iter_sym.params[0]) : emit_expr(e, s.iterable)
	subject_type := subject_by_ptr ? "ptr" : llvm_type(e, iter_sym.params[0])
	iterator_type := llvm_type(e, s.iterator_type)
	iterator := alloca(e, iterator_type)
	made := temp(e)
	fmt.sbprintfln(
		&e.b,
		"  %s = call %s %s(%s %s)",
		made, iterator_type, symbol_name(e, s.iter_symbol), subject_type, subject,
	)
	fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", iterator_type, made, iterator)
	register_scope_place(e, s.iterator_type, iterator)

	counter := ""
	if s.indexed || (foreach_is_place_loop(s) && len(s.bindings) == 2) {
		counter = alloca(e, "i64")
		fmt.sbprintfln(&e.b, "  store i64 0, ptr %s", counter)
	}

	loop := open_loop(e)
	place_label(e, loop.head)
	yielded := foreach_yielded_type(e, s)
	option := symbol_of(e.c, s.next_symbol).result
	option_llvm := llvm_type(e, option)
	produced := temp(e)
	fmt.sbprintfln(&e.b, "  %s = call %s %s(ptr %s)", produced, option_llvm, symbol_name(e, s.next_symbol), iterator)
	ok := temp(e)
	shape := union_layout(e.c, option)
	tag := emit_union_tag(e, option, produced)
	fmt.sbprintfln(
		&e.b, "  %s = icmp eq i%d %s, %d",
		ok, shape.tag_bytes * 8, tag, union_index_of(e.c, option, "some"),
	)
	slot := emit_union_spill(e, option, produced)
	branch_if(e, ok, loop.body, loop.done)

	begin_step(e, loop)
	numbered := counter == "" ? "" : load(e, "i64", counter)
	payload := option_payload(e.c, option)
	// `next` hands over an owned `Element`, so the step takes it without a copy.
	if foreach_is_place_loop(s) && !type_is_pointer(e.c, payload) {
		// A record `Yield` with a mutable part: each lent part is a place.
		bind_foreach_fields(e, s, with_index(e, s, lent_record_fields(e, s, emit_union_payload(e, option, payload, slot), payload), numbered))
	} else if foreach_is_place_loop(s) {
		logical := s.indexed ? foreach_yielded_type(e, s) : s.element_type
		address := emit_union_payload(e, option, pointer_to(e.c, logical, true), slot)
		fields := []Foreach_Field{{type = logical, address = address, place = true, stored = true}}
		bind_foreach_fields(e, s, with_index(e, s, fields, numbered))
	} else if s.borrows && !type_is_pointer(e.c, payload) {
		// A record `Yield` is a record of pointers, one per lent part.
		bind_foreach_fields(e, s, lent_record_fields(e, s, emit_union_payload(e, option, payload, slot), payload))
	} else if s.borrows {
		// The payload points into the source, and the loop owns nothing. It is
		// `stored` because one name over an `indexed()` pair copies it into a record.
		address := emit_union_payload(e, option, pointer_to(e.c, yielded, false), slot)
		fields := []Foreach_Field{{type = yielded, address = address, place = true, stored = true}}
		bind_foreach_fields(e, s, with_index(e, s, fields, numbered))
	} else {
		value := emit_union_payload(e, option, yielded, slot)
		fields := []Foreach_Field{{type = yielded, value = value}}
		bind_foreach_fields(e, s, with_index(e, s, fields, numbered))
	}
	finish_step(e, s, loop)
	if counter != "" {
		step_counter(e, counter, "i64")
	}
	close_loop(e, loop)
}

// Addressable storage for `expr` at `as_type`. A non-addressable value gets a
// slot, and an owned temporary is dropped when its full expression ends.
@(private)
spill_iterable_at :: proc(e: ^Emitter, expr: Expr, as_type: Type_Id) -> string {
	base := expr_base(expr)
	if base.addressable {
		return emit_address_at(e, expr, as_type)
	}
	value := emit_expr_at(e, expr, as_type)
	slot := alloca(e, llvm_type(e, as_type))
	fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", llvm_type(e, as_type), value, slot)
	if !base.is_const {
		hold_addressed_temporary(e, expr, as_type, slot)
	}
	return slot
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
	slot := alloca(e, llvm_type(e, as_type))
	store(e, as_type, value, slot)
	if !base.is_const {
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
			count := fmt.aprintf("%d", source_info.count)
			if !type_is_compile_time_only(e.c, source_info.element) {
				view = emit_ptr_len(e, view_type, "%arg0", count)
			} else {
				view_type = source
			}
			index = count
		case:
			view_type = source
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

@(private)
emit_synth_range_next :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	option := symbol.result
	step := option_payload(e.c, option)
	element := llvm_type(e, step)
	iterator := llvm_type(e, symbol.params[0])
	signed := type_signed(e.c, step) || type_is_rune(e.c, step)

	pair_type := llvm_type(e, option)
	open_function(e, "define %s%s %s(ptr %%arg0)", llvm_linkage(name), pair_type, name)
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
	fmt.sbprintfln(&e.b, "  br i1 %s, label %%%s, label %%%s", reversed, reverse_label, forward_label)

	fmt.sbprintfln(&e.b, "%s:", forward_label)
	live := emit_range_live(e, signed, false, element, current, high, closed)
	yield_label := new_label(e, "next.forward.yield")
	fmt.sbprintfln(&e.b, "  br i1 %s, label %%%s, label %%%s", live, yield_label, stop_label)

	// Yielding a closed range's high clears `closed` instead of stepping past it.
	fmt.sbprintfln(&e.b, "%s:", yield_label)
	stepped, at_high, last := temp(e), temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = add %s %s, 1", stepped, element, current)
	fmt.sbprintfln(&e.b, "  %s = icmp eq %s %s, %s", at_high, element, current, high)
	fmt.sbprintfln(&e.b, "  %s = and i1 %s, %s", last, closed, at_high)
	next_current, next_closed := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, %s %s, %s %s", next_current, last, element, current, element, stepped)
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, i1 false, i1 %s", next_closed, last, closed)
	fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", element, next_current, current_ptr)
	fmt.sbprintfln(&e.b, "  store i1 %s, ptr %s", next_closed, closed_ptr)
	fmt.sbprintfln(&e.b, "  ret %s %s", pair_type, emit_option_some(e, option, current))

	fmt.sbprintfln(&e.b, "%s:", reverse_label)
	reverse_live := emit_range_live(e, signed, true, element, current, high, closed)
	reverse_yield := new_label(e, "next.reverse.yield")
	fmt.sbprintfln(&e.b, "  br i1 %s, label %%%s, label %%%s", reverse_live, reverse_yield, stop_label)

	fmt.sbprintfln(&e.b, "%s:", reverse_yield)
	previous, yielded := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = sub %s %s, 1", previous, element, current)
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, %s %s, %s %s", yielded, closed, element, current, element, previous)
	fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", element, yielded, current_ptr)
	fmt.sbprintfln(&e.b, "  store i1 false, ptr %s", closed_ptr)
	fmt.sbprintfln(&e.b, "  ret %s %s", pair_type, emit_option_some(e, option, yielded))

	// Exhaustion is `.none`, `Option`'s all-zero designated zero.
	fmt.sbprintfln(&e.b, "%s:", stop_label)
	fmt.sbprintfln(&e.b, "  ret %s zeroinitializer", pair_type)
	fmt.sbprintln(&e.b, "}")
}

// `next` for an array or a slice over one `{ data, index, reversed }` cursor;
// only the bound and the element address differ.
@(private)
emit_synth_indexed_next :: proc(e: ^Emitter, symbol: ^Symbol, name: string, slice: bool) {
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	option := symbol.result
	by_ref := symbol.synth == .Slice_Mut_Next || symbol.synth == .Slice_Ref_Next
	payload := option_payload(e.c, option)
	element := llvm_type(e, by_ref ? type_of(e.c, payload).element : payload)
	iterator := llvm_type(e, symbol.params[0])
	iterator_info := type_of(e.c, symbol.params[0])
	stored := symbol_of(e.c, iterator_info.fields[ITER_ARRAY_DATA]).type
	stored_llvm := llvm_type(e, stored)

	pair_type := llvm_type(e, option)
	open_function(e, "define %s%s %s(ptr %%arg0)", llvm_linkage(name), pair_type, name)
	index_ptr := gep_field(e, iterator, "%arg0", ITER_ARRAY_INDEX)
	index := load(e, "i64", index_ptr)
	reversed_ptr := gep_field(e, iterator, "%arg0", ITER_ARRAY_REVERSED)
	reversed := load(e, "i1", reversed_ptr)
	// A slice's bound is its length; a fixed array's is a constant.
	slice_value: string
	bound: string
	if slice {
		slice_value = load(e, stored_llvm, gep_field(e, iterator, "%arg0", ITER_ARRAY_DATA))
		bound = extract(e, stored_llvm, slice_value, SLICE_LEN)
	} else {
		bound = fmt.tprintf("%d", type_of(e.c, stored).count)
	}
	forward_live, reverse_live, live := temp(e), temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp slt i64 %s, %s", forward_live, index, bound)
	fmt.sbprintfln(&e.b, "  %s = icmp sgt i64 %s, 0", reverse_live, index)
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, i1 %s, i1 %s", live, reversed, reverse_live, forward_live)
	yield_label, stop_label := new_label(e, "next.yield"), new_label(e, "next.stop")
	fmt.sbprintfln(&e.b, "  br i1 %s, label %%%s, label %%%s", live, yield_label, stop_label)

	fmt.sbprintfln(&e.b, "%s:", yield_label)
	base: string
	if slice {
		base = extract(e, stored_llvm, slice_value, SLICE_DATA)
	} else {
		base = gep_field(e, iterator, "%arg0", ITER_ARRAY_DATA)
	}
	previous, at := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = sub i64 %s, 1", previous, index)
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, i64 %s, i64 %s", at, reversed, previous, index)
	slot: string
	if slice {
		slot = gep_at(e, element, base, at)
	} else {
		slot = temp(e)
		fmt.sbprintfln(&e.b, "  %s = getelementptr inbounds %s, ptr %s, i64 0, i64 %s", slot, stored_llvm, base, at)
	}
	// What `next` hands back is owned, so a managed element is cloned out.
	value := by_ref ? slot : load(e, element, slot)
	if !by_ref && emit_lifecycle(e, payload).managed {
		value = emit_clone_value(e, payload, value)
	}
	stepped, next_index := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = add i64 %s, 1", stepped, index)
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, i64 %s, i64 %s", next_index, reversed, previous, stepped)
	fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", next_index, index_ptr)
	fmt.sbprintfln(&e.b, "  ret %s %s", pair_type, emit_option_some(e, option, value))

	fmt.sbprintfln(&e.b, "%s:", stop_label)
	fmt.sbprintfln(&e.b, "  ret %s zeroinitializer", pair_type)
	fmt.sbprintln(&e.b, "}")
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

	pair_type := llvm_type(e, option)
	open_function(e, "define %s%s %s(ptr %%arg0)", llvm_linkage(name), pair_type, name)
	table_ptr := gep_field(e, iterator, "%arg0", ITER_MAP_TABLE)
	table := load(e, "ptr", table_ptr)
	cursor_ptr := gep_field(e, iterator, "%arg0", ITER_MAP_CURSOR)
	cursor := load(e, "i64", cursor_ptr)
	key_out := alloca(e, "ptr")
	value_out := alloca(e, "ptr")
	next := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = call i64 @loke_rt_v1_map_scan(ptr %s, ptr %s, i64 %s, ptr %s, ptr %s)",
		next, table, ops, cursor, key_out, value_out,
	)
	fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", next, cursor_ptr)
	finished := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq i64 %s, 0", finished, next)
	yield_label, stop_label := new_label(e, "next.yield"), new_label(e, "next.stop")
	fmt.sbprintfln(&e.b, "  br i1 %s, label %%%s, label %%%s", finished, stop_label, yield_label)

	fmt.sbprintfln(&e.b, "%s:", yield_label)
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
	fmt.sbprintfln(&e.b, "  ret %s %s", pair_type, emit_option_some(e, option, out))

	fmt.sbprintfln(&e.b, "%s:", stop_label)
	fmt.sbprintfln(&e.b, "  ret %s zeroinitializer", pair_type)
	fmt.sbprintln(&e.b, "}")
}

// One field per part of a record `Yield`: a lent part is the place its pointer
// names, an owned one the value itself.
@(private = "file")
lent_record_fields :: proc(e: ^Emitter, s: ^Stmt_Foreach, record: string, payload: Type_Id) -> []Foreach_Field {
	root := lent_yield_field(e, foreach_yielded_type(e, s), payload, record)
	return root.children
}

@(private = "file")
lent_yield_field :: proc(e: ^Emitter, logical, payload: Type_Id, value: string) -> Foreach_Field {
	if logical == payload {
		return Foreach_Field{type = logical, value = value}
	}
	if type_is_pointer(e.c, payload) {
		return Foreach_Field{type = logical, address = value, place = true, stored = true}
	}
	logical_info := type_of(e.c, type_underlying(e.c, logical))
	payload_info := type_of(e.c, type_underlying(e.c, payload))
	children := make([]Foreach_Field, len(logical_info.fields), context.temp_allocator)
	llvm := llvm_type(e, payload)
	for logical_field_id, index in logical_info.fields {
		logical_field := symbol_of(e.c, logical_field_id)
		payload_field := symbol_of(e.c, payload_info.fields[index])
		children[index] = lent_yield_field(
			e, logical_field.type, payload_field.type, extract(e, llvm, value, index),
		)
	}
	return Foreach_Field{type = logical, children = children}
}

// One decoded code point per step; `rune_offsets()` also yields its byte offset.
@(private)
emit_synth_text_next :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	option := symbol.result
	yielded := option_payload(e.c, option)
	iterator := llvm_type(e, symbol.params[0])
	pair_type := llvm_type(e, option)
	open_function(e, "define %s%s %s(ptr %%arg0)", llvm_linkage(name), pair_type, name)

	view := load(e, STRING_VIEW_TYPE, gep_field(e, iterator, "%arg0", ITER_TEXT_VIEW))
	data := extract(e, STRING_VIEW_TYPE, view, STRING_DATA)
	length := extract(e, STRING_VIEW_TYPE, view, STRING_LEN)
	offset_ptr := gep_field(e, iterator, "%arg0", ITER_TEXT_OFFSET)
	offset := load(e, "i64", offset_ptr)
	at_end := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp sge i64 %s, %s", at_end, offset, length)
	yield_label, stop_label := new_label(e, "next.yield"), new_label(e, "next.stop")
	fmt.sbprintfln(&e.b, "  br i1 %s, label %%%s, label %%%s", at_end, stop_label, yield_label)

	fmt.sbprintfln(&e.b, "%s:", yield_label)
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
	fmt.sbprintfln(&e.b, "  ret %s %s", pair_type, emit_option_some(e, option, value))

	fmt.sbprintfln(&e.b, "%s:", stop_label)
	fmt.sbprintfln(&e.b, "  ret %s zeroinitializer", pair_type)
	fmt.sbprintln(&e.b, "}")
}

// Iteration lowering and synthesized iterator bodies.
//
// Part of the textual LLVM backend; see compiler-architecture.md.
package lokec

import "core:fmt"
import "core:strings"

// ============================================================== iteration ==

// design.md "Iteration protocol": `next` yields `Option(Element)`. These two
// helpers name the parts of that instance so no synthesized body re-derives it.
@(private)
option_payload :: proc(c: ^Compiler, option_type: Type_Id) -> Type_Id {
	return union_variant_payload(c, option_type, union_index_of(c, option_type, "some"))
}

@(private)
emit_option_some :: proc(e: ^Emitter, option_type: Type_Id, payload: string) -> string {
	return emit_union_value(e, option_type, union_index_of(e.c, option_type, "some"), payload)
}

// `a ..< b` and `a ..= b` as a stored value: the endpoints plus the closed flag,
// so a range keeps its kind after being assigned or passed to a generic
// procedure.
@(private)
emit_range_value :: proc(e: ^Emitter, v: ^Expr_Range) -> string {
	info := type_of(e.c, v.type)
	element := info.element
	low := emit_expr(e, v.lo)
	high := emit_expr(e, v.hi)
	closed := v.op == .Range_Incl ? "true" : "false"
	storage := llvm_type(e, v.type)
	step1 := temp(e)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s undef, %s %s, %d", step1, storage, llvm_type(e, element), low, RANGE_LOW)
	step2 := temp(e)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s %s, %s %s, %d", step2, storage, step1, llvm_type(e, element), high, RANGE_HIGH)
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s %s, i1 %s, %d", out, storage, step2, closed, RANGE_CLOSED)
	return out
}

@(private)
emit_foreach :: proc(e: ^Emitter, s: ^Stmt_Foreach) {
	if s.kind == .Static {
		// An expansion is not a loop: its checked copies run in iterable order,
		// and an empty iterable emits nothing.
		for copy_block in s.expansion {
			emit_block_statements(e, copy_block)
		}
		return
	}

	outer_break, outer_continue := e.break_label, e.continue_label
	outer_break_depth, outer_continue_depth := e.break_depth, e.continue_depth
	defer {
		e.break_label, e.continue_label = outer_break, outer_continue
		e.break_depth, e.continue_depth = outer_break_depth, outer_continue_depth
	}
	e.break_depth = len(e.cleanups)
	push_scope(e, nil)
	defer pop_scope(e)

	if s.kind == .Protocol {
		emit_protocol_foreach(e, s)
		return
	}
	if s.kind == .Text {
		emit_text_foreach(e, s)
		return
	}
	if s.kind == .Map {
		emit_map_foreach(e, s)
		return
	}
	emit_indexed_foreach(e, s)
}

// One source of a bound name: a place to read from, a value already in hand, or
// a place the binding *is* (`&value`, and a map key, which is immutable and so
// borrows the stored key rather than copying it).
@(private = "file")
Foreach_Field :: struct {
	type:    Type_Id,
	address: string,
	value:   string,
	place:   bool,
}

// design.md "Element bindings": one binding names the whole `Element`, and N
// bindings name its fields positionally. The sources are whatever the lowering
// already has, so a destructuring loop never materializes the record it is
// taking apart, and only a one-name loop over a synthesized element pays for
// building it.
@(private = "file")
bind_foreach_fields :: proc(e: ^Emitter, s: ^Stmt_Foreach, fields: []Foreach_Field) {
	if len(s.bindings) == len(fields) {
		for field, index in fields {
			bind_foreach_field(e, s.bindings[index].symbol, field)
		}
		return
	}
	record := llvm_type(e, s.element_type)
	if len(s.bindings) == 1 {
		symbol := s.bindings[0].symbol
		if symbol == INVALID_SYMBOL {
			return
		}
		slot := alloca(e, record)
		for field, index in fields {
			store(e, field.type, field_value(e, field), gep_field(e, record, slot, index))
		}
		bind_local(e, symbol, slot)
		return
	}
	// Several names over one record element: each one reads its field in place.
	source := fields[0]
	address := source.address
	if address == "" {
		address = alloca(e, record)
		store(e, s.element_type, source.value, address)
	}
	info := type_of(e.c, type_underlying(e.c, s.element_type))
	for binding, index in s.bindings {
		field := symbol_of(e.c, info.fields[index])
		bind_foreach_field(
			e,
			binding.symbol,
			Foreach_Field{type = field.type, address = gep_field(e, record, address, index)},
		)
	}
}

@(private = "file")
bind_foreach_field :: proc(e: ^Emitter, symbol: Symbol_Id, field: Foreach_Field) {
	if symbol == INVALID_SYMBOL {
		return // the discard binding names nothing
	}
	if field.place {
		bind_local(e, symbol, field.address)
		return
	}
	// By default each iterated value is a copy, and assignment to the copy does
	// not modify the source.
	slot := alloca(e, llvm_type(e, field.type))
	store(e, field.type, field_value(e, field), slot)
	bind_local(e, symbol, slot)
}

// `indexed()` numbers whatever traversal it wraps, so the wrapped element
// becomes one field again — built here when the traversal produced several — and
// the counter follows it.
@(private = "file")
with_index :: proc(e: ^Emitter, s: ^Stmt_Foreach, fields: []Foreach_Field, counter: string) -> []Foreach_Field {
	if !s.indexed {
		return fields
	}
	inner := fields[0]
	if len(fields) > 1 {
		wrapped := foreach_yielded_type(e, s)
		llvm := llvm_type(e, wrapped)
		slot := alloca(e, llvm)
		for field, index in fields {
			store(e, field.type, field_value(e, field), gep_field(e, llvm, slot, index))
		}
		inner = Foreach_Field{type = wrapped, address = slot}
	}
	out := make([dynamic]Foreach_Field, 0, 2, context.temp_allocator)
	append(&out, inner)
	append(&out, Foreach_Field{type = TYPE_INT, value = counter})
	return out[:]
}

// The value this loop yields, before `indexed()` numbers it.
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

// The loop yields decoded code points. A byte offset — the index where the
// yielded code point begins, advancing by 1 to 4 per step — comes from
// `rune_offsets()`, and a rune ordinal from `indexed()` (design.md "String
// iteration").
@(private = "file")
emit_text_foreach :: proc(e: ^Emitter, s: ^Stmt_Foreach) {
	data, length := emit_text_parts(e, s.iterable)
	offset := alloca(e, "i64")
	decoded := temp(e)
	fmt.sbprintfln(&e.b, "  store i64 0, ptr %s", offset)
	fmt.sbprintfln(&e.b, "  %s = alloca i32", decoded)

	// `indexed()` counts the runes it yields, so its counter lives across
	// iterations rather than being rebuilt per step.
	ordinal := ""
	if s.indexed {
		ordinal = alloca(e, "i64")
		fmt.sbprintfln(&e.b, "  store i64 0, ptr %s", ordinal)
	}

	head := new_label(e, "foreach.head")
	body := new_label(e, "foreach.body")
	post := new_label(e, "foreach.post")
	done := new_label(e, "foreach.done")
	e.break_label, e.continue_label = done, post
	e.continue_depth = len(e.cleanups)

	place_label(e, head)
	current := load(e, "i64", offset)
	at_end := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp sge i64 %s, %s", at_end, current, length)
	branch_if(e, at_end, done, body)

	place_label(e, body)
	used := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = call i64 @loke_rt_v1_rune_at(ptr %s, i64 %s, i64 %s, ptr %s)",
		used, data, length, current, decoded,
	)
	// A `string` is valid UTF-8 by construction and every borrowed view of one is
	// checked where it is created, so a zero here would mean the invariant was
	// already broken.
	stalled := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq i64 %s, 0", stalled, used)
	panic_if(e, stalled, "text.invalid", "invalid UTF-8 in a string")

	fields := make([dynamic]Foreach_Field, 0, 2, context.temp_allocator)
	append(&fields, Foreach_Field{type = TYPE_RUNE, address = decoded})
	if s.adapter == .Rune_Offsets {
		append(&fields, Foreach_Field{type = TYPE_INT, value = current})
	}
	counter := ordinal == "" ? "" : load(e, "i64", ordinal)
	bind_foreach_fields(e, s, with_index(e, s, fields[:], counter))
	emit_scoped_block(e, s.body)
	branch(e, post)

	place_label(e, post)
	advanced := temp(e)
	fmt.sbprintfln(&e.b, "  %s = add i64 %s, %s", advanced, current, used)
	fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", advanced, offset)
	if ordinal != "" {
		step_counter(e, ordinal, "i64")
	}
	branch(e, head)
	place_label(e, done)
}

// A slot walk over a map; iteration order is unspecified (design.md "Maps").
// The cursor is one integer the runtime hands back; the table's controls, seed,
// and slot count stay entirely inside `runtime/container.c`.
//
// One name binds the whole `{key, value}` entry and two destructure it; `keys()`
// and `values()` name the single-field traversals. A value binding written `&` is
// a place loop, naming the stored slot rather than a copy.
@(private = "file")
emit_map_foreach :: proc(e: ^Emitter, s: ^Stmt_Foreach) {
	container := expr_base(s.iterable).type
	ops := container_ops_global(e, container)
	header := emit_address(e, s.iterable)
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

	head := new_label(e, "foreach.head")
	body := new_label(e, "foreach.body")
	post := new_label(e, "foreach.post")
	done := new_label(e, "foreach.done")
	e.break_label, e.continue_label = done, post
	e.continue_depth = len(e.cleanups)

	place_label(e, head)
	current := load(e, "i64", cursor)
	next := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = call i64 @loke_rt_v1_map_scan(ptr %s, ptr %s, i64 %s, ptr %s, ptr %s)",
		next, table, ops, current, key_out, value_out,
	)
	fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", next, cursor)
	finished := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq i64 %s, 0", finished, next)
	branch_if(e, finished, done, body)

	place_label(e, body)
	if foreach_is_place_loop(s) {
		// The place forms, unchanged: `&value`, or `key, &value`.
		key_binding, value_binding := -1, 0
		if len(s.bindings) == 2 {
			key_binding, value_binding = 0, 1
		}
		if key_binding >= 0 {
			// The key binding is immutable, so it borrows the stored key in place: no
			// per-iteration clone, and therefore no per-iteration drop either.
			bind_foreach_field(e, s.bindings[key_binding].symbol, Foreach_Field{
				type = container_key(e.c, container), address = load(e, "ptr", key_out), place = true,
			})
		}
		// `&value` names the stored slot, so a write reaches the table.
		bind_foreach_field(e, s.bindings[value_binding].symbol, Foreach_Field{
			type = container_element(e.c, container), address = load(e, "ptr", value_out), place = true,
		})
	} else {
		key := Foreach_Field{type = container_key(e.c, container), address = load(e, "ptr", key_out), place = true}
		value := Foreach_Field{type = container_element(e.c, container), address = load(e, "ptr", value_out)}
		fields := make([dynamic]Foreach_Field, 0, 2, context.temp_allocator)
		switch s.adapter {
		case .Keys:
			append(&fields, key)
		case .Values:
			append(&fields, value)
		case .None, .Entries, .Reversed, .Runes, .Rune_Offsets:
			// The map's own `Element` is its `{key, value}` entry. Binding the whole
			// entry copies the key rather than borrowing it.
			if len(s.bindings) == 1 || s.indexed {
				key.place = false
			}
			append(&fields, key)
			append(&fields, value)
		}
		numbered := counter == "" ? "" : load(e, "i64", counter)
		bind_foreach_fields(e, s, with_index(e, s, fields[:], numbered))
	}
	emit_scoped_block(e, s.body)
	branch(e, post)
	place_label(e, post)
	if counter != "" {
		step_counter(e, counter, "i64")
	}
	branch(e, head)
	place_label(e, done)
}

// A range or a fixed array: an index loop, with no iterator object at all.
@(private = "file")
emit_indexed_foreach :: proc(e: ^Emitter, s: ^Stmt_Foreach) {
	yielded := foreach_yielded_type(e, s)
	element := llvm_type(e, yielded)
	cursor := temp(e)
	limit := ""
	closed := ""
	array_slot := ""
	floor := ""
	counter_type := element

	switch s.kind {
	case .Range:
		written := s.iterable.(^Expr_Range)
		low := emit_expr(e, written.lo)
		high := emit_expr(e, written.hi)
		fmt.sbprintfln(&e.b, "  %s = alloca %s", cursor, element)
		fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", element, low, cursor)
		limit = high
		floor = low
		closed = written.op == .Range_Incl ? "true" : "false"

	case .Stored_Range:
		range_type := llvm_type(e, expr_base(s.iterable).type)
		value := emit_expr(e, s.iterable)
		low := extract(e, range_type, value, RANGE_LOW)
		high := extract(e, range_type, value, RANGE_HIGH)
		flag := extract(e, range_type, value, RANGE_CLOSED)
		fmt.sbprintfln(&e.b, "  %s = alloca %s", cursor, element)
		fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", element, low, cursor)
		limit = high
		floor = low
		closed = flag

	case .Array:
		// `&value` names the element in place, so the array must be a place
		// rather than a copy.
		array_slot = spill_iterable(e, s.iterable)
		counter_type = "i64"
		fmt.sbprintfln(&e.b, "  %s = alloca i64", cursor)
		fmt.sbprintfln(&e.b, "  store i64 0, ptr %s", cursor)
		limit = fmt.aprintf("%d", s.count)

	case .Slice:
		// The slice is evaluated once; the loop then walks its root through the
		// data word, so `&value` reaches the root rather than a copy.
		slice_type := llvm_type(e, expr_base(s.iterable).type)
		value := emit_expr(e, s.iterable)
		array_slot = temp(e)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", array_slot, slice_type, value, SLICE_DATA)
		length := extract(e, slice_type, value, SLICE_LEN)
		counter_type = "i64"
		fmt.sbprintfln(&e.b, "  %s = alloca i64", cursor)
		fmt.sbprintfln(&e.b, "  store i64 0, ptr %s", cursor)
		limit = length

	case .Dynamic:
		// design.md "Dynamic arrays": the loop views the *current* allocation and
		// stops at the length, never at the capacity. The whole-container loan the
		// loop holds is what keeps that snapshot true for its duration.
		header := emit_address(e, s.iterable)
		array_slot = temp(e)
		fmt.sbprintfln(&e.b, "  %s = load ptr, ptr %s", array_slot, header)
		length_slot := gep_field(e, CONTAINER_TYPE, header, CONTAINER_LEN)
		length := load(e, "i64", length_slot)
		counter_type = "i64"
		fmt.sbprintfln(&e.b, "  %s = alloca i64", cursor)
		fmt.sbprintfln(&e.b, "  store i64 0, ptr %s", cursor)
		limit = length

	case .Unresolved, .Static, .Protocol, .Text, .Map:
		backend_fail(e, "an unresolved `foreach` reached emission")
		return
	}

	head := new_label(e, "foreach.head")
	body := new_label(e, "foreach.body")
	post := new_label(e, "foreach.post")
	done := new_label(e, "foreach.done")
	e.break_label, e.continue_label = done, post
	e.continue_depth = len(e.cleanups)

	// A place loop's index is a counter the loop maintains, so it lives across
	// iterations rather than being rebuilt per step.
	index_slot := ""
	if foreach_is_place_loop(s) && len(s.bindings) == 2 && s.bindings[1].symbol != INVALID_SYMBOL {
		index_slot = temp(e)
		fmt.sbprintfln(&e.b, "  %s = alloca i64", index_slot)
		fmt.sbprintfln(&e.b, "  store i64 0, ptr %s", index_slot)
		bind_local(e, s.bindings[1].symbol, index_slot)
	}
	// A sequence's cursor is already the index `indexed()` wants. A range's cursor
	// is its *value*, so numbering one needs a counter of its own.
	counter := ""
	if s.indexed && (s.kind == .Range || s.kind == .Stored_Range) {
		counter = alloca(e, "i64")
		fmt.sbprintfln(&e.b, "  store i64 0, ptr %s", counter)
	}

	place_label(e, head)
	current := load(e, counter_type, cursor)
	test := temp(e)
	if s.kind == .Array || s.kind == .Slice || s.kind == .Dynamic {
		fmt.sbprintfln(&e.b, "  %s = icmp slt i64 %s, %s", test, current, limit)
	} else {
		// `..<` stops before the high endpoint and `..=` includes it; a stored
		// range carries which at run time.
		signed := type_signed(e.c, yielded) || type_is_rune(e.c, yielded)
		open_test, closed_test := temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp %s %s %s, %s", open_test, signed ? "slt" : "ult", counter_type, current, limit)
		fmt.sbprintfln(&e.b, "  %s = icmp %s %s %s, %s", closed_test, signed ? "sle" : "ule", counter_type, current, limit)
		fmt.sbprintfln(&e.b, "  %s = select i1 %s, i1 %s, i1 %s", test, closed, closed_test, open_test)
	}
	branch_if(e, test, body, done)

	place_label(e, body)
	numbered := counter == "" ? current : load(e, "i64", counter)
	bind_indexed_value(e, s, current, array_slot, element, limit, floor, closed, numbered)
	emit_scoped_block(e, s.body)
	branch(e, post)

	place_label(e, post)
	if s.kind != .Array && s.kind != .Slice && s.kind != .Dynamic {
		// An inclusive range whose high endpoint is the integer maximum cannot
		// represent high+1. Finish directly after yielding high instead.
		at_high, finished := temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp eq %s %s, %s", at_high, counter_type, current, limit)
		fmt.sbprintfln(&e.b, "  %s = and i1 %s, %s", finished, closed, at_high)
		step := new_label(e, "foreach.step")
		branch_if(e, finished, done, step)
		place_label(e, step)
	}
	step_counter(e, cursor, counter_type)
	if index_slot != "" {
		step_counter(e, index_slot, "i64")
	}
	if counter != "" {
		step_counter(e, counter, "i64")
	}
	branch(e, head)

	place_label(e, done)
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
	fields := make([dynamic]Foreach_Field, 0, 2, context.temp_allocator)
	if s.kind != .Array && s.kind != .Slice && s.kind != .Dynamic {
		at := current
		if s.adapter == .Reversed {
			// The cursor still counts up from the low endpoint; only the value it
			// names is mirrored, so `low + high' - current` walks the range backwards
			// without a second loop shape. `high'` is the last value the forward loop
			// would yield.
			last, mirrored := temp(e), temp(e)
			open_high := temp(e)
			fmt.sbprintfln(&e.b, "  %s = sub %s %s, 1", open_high, element, limit)
			fmt.sbprintfln(&e.b, "  %s = select i1 %s, %s %s, %s %s", last, closed, element, limit, element, open_high)
			sum := temp(e)
			fmt.sbprintfln(&e.b, "  %s = add %s %s, %s", sum, element, floor, last)
			fmt.sbprintfln(&e.b, "  %s = sub %s %s, %s", mirrored, element, sum, current)
			at = mirrored
		}
		append(&fields, Foreach_Field{type = yielded, value = at})
	} else {
		// `reversed()` walks the same cursor and flips only the element it reaches,
		// so an `indexed()` over it still counts from zero (design.md "Reverse
		// iteration").
		at := current
		if s.adapter == .Reversed {
			last, flipped := temp(e), temp(e)
			fmt.sbprintfln(&e.b, "  %s = sub i64 %s, 1", last, limit)
			fmt.sbprintfln(&e.b, "  %s = sub i64 %s, %s", flipped, last, current)
			at = flipped
		}
		address := temp(e)
		if s.kind == .Slice || s.kind == .Dynamic {
			// `array_slot` is the slice's data pointer, so the element index walks it
			// directly rather than indexing into an inline array.
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
		// `&value` is the element itself, so the binding is its address and a store
		// through it reaches the array.
		append(&fields, Foreach_Field{type = yielded, address = address, place = s.bindings[0].is_ref})
	}
	if foreach_is_place_loop(s) {
		bind_foreach_field(e, s.bindings[0].symbol, fields[0])
		return // the place form's index is its own counter, bound before the loop
	}
	bind_foreach_fields(e, s, with_index(e, s, fields[:], numbered))
}

// A user iterable: `it := x.iter()`, then `next(&it)` per step. `indexed()` adds
// its counter around the yielded Element.
@(private = "file")
emit_protocol_foreach :: proc(e: ^Emitter, s: ^Stmt_Foreach) {
	iter_sym := symbol_of(e.c, s.iter_symbol)
	subject := emit_expr(e, s.iterable)
	iterator_type := llvm_type(e, s.iterator_type)
	iterator := alloca(e, iterator_type)
	made := temp(e)
	fmt.sbprintfln(
		&e.b,
		"  %s = call %s %s(%s %s)",
		made, iterator_type, e.names[s.iter_symbol], llvm_type(e, iter_sym.params[0]), subject,
	)
	fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", iterator_type, made, iterator)

	counter := ""
	if s.indexed {
		counter = alloca(e, "i64")
		fmt.sbprintfln(&e.b, "  store i64 0, ptr %s", counter)
	}

	head := new_label(e, "foreach.head")
	body := new_label(e, "foreach.body")
	post := new_label(e, "foreach.post")
	done := new_label(e, "foreach.done")
	e.break_label, e.continue_label = done, post
	e.continue_depth = len(e.cleanups)

	place_label(e, head)
	yielded := foreach_yielded_type(e, s)
	option := symbol_of(e.c, s.next_symbol).results[0]
	option_llvm := llvm_type(e, option)
	produced := temp(e)
	fmt.sbprintfln(&e.b, "  %s = call %s %s(ptr %s)", produced, option_llvm, e.names[s.next_symbol], iterator)
	ok := temp(e)
	shape := union_layout(e.c, option)
	tag := emit_union_tag(e, option, produced)
	fmt.sbprintfln(
		&e.b, "  %s = icmp eq i%d %s, %d",
		ok, shape.tag_bytes * 8, tag, union_index_of(e.c, option, "some"),
	)
	slot := emit_union_spill(e, option, produced)
	branch_if(e, ok, body, done)

	place_label(e, body)
	value := emit_union_payload(e, option, yielded, slot)
	fields := []Foreach_Field{{type = yielded, value = value}}
	numbered := counter == "" ? "" : load(e, "i64", counter)
	bind_foreach_fields(e, s, with_index(e, s, fields, numbered))
	emit_scoped_block(e, s.body)
	branch(e, post)

	place_label(e, post)
	if counter != "" {
		step_counter(e, counter, "i64")
	}
	branch(e, head)

	place_label(e, done)
}

// An array the loop indexes: its own storage when it has any, and a spill
// otherwise.
@(private)
spill_iterable :: proc(e: ^Emitter, expr: Expr) -> string {
	base := expr_base(expr)
	if base.addressable {
		return emit_address(e, expr)
	}
	value := emit_expr(e, expr)
	slot := alloca(e, llvm_type(e, base.type))
	fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", llvm_type(e, base.type), value, slot)
	return slot
}

@(private)
emit_synth_iter :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	source := llvm_type(e, symbol.params[0])
	iterator := llvm_type(e, symbol.results[0])
	reversed := symbol.synth == .Range_Iter_Reverse ||
	            symbol.synth == .Array_Iter_Reverse ||
	            symbol.synth == .Dynamic_Iter_Reverse
	fmt.sbprintf(&e.b, "define %s %s(%s %%arg0)", iterator, name, source)
	fmt.sbprintln(&e.b, " {")
	fmt.sbprintln(&e.b, "entry:")
	if symbol.synth == .Array_Iter || symbol.synth == .Array_Iter_Reverse {
		// Iteration is by value, so the iterator owns the array/slice view. A
		// reverse cursor starts one past the last element and decrements before use.
		index := "0"
		if reversed {
			source_info := underlying_info(e.c, symbol.params[0])
			if source_info.kind == .Array {
				index = fmt.aprintf("%d", source_info.count)
			} else {
				index = extract(e, source, "%arg0", SLICE_LEN)
			}
		}
		first := temp(e)
		fmt.sbprintfln(&e.b, "  %s = insertvalue %s undef, %s %%arg0, %d", first, iterator, source, ITER_ARRAY_DATA)
		second, out := temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = insertvalue %s %s, i64 %s, %d", second, iterator, first, index, ITER_ARRAY_INDEX)
		fmt.sbprintfln(&e.b, "  %s = insertvalue %s %s, i1 %s, %d", out, iterator, second, reversed ? "true" : "false", ITER_ARRAY_REVERSED)
		fmt.sbprintfln(&e.b, "  ret %s %s", iterator, out)
		fmt.sbprintln(&e.b, "}")
		return
	}
	if symbol.synth == .Dynamic_Iter || symbol.synth == .Dynamic_Iter_Reverse {
		// `{ {storage, len}, 0 }`: the current allocation, viewed as a slice. The
		// capacity and the allocator stay behind, which is what keeps the iterator
		// a borrow rather than a second header.
		view_type := llvm_type(e, symbol_of(e.c, type_of(e.c, symbol.results[0]).fields[ITER_ARRAY_DATA]).type)
		storage := extract(e, source, "%arg0", CONTAINER_STORAGE)
		length := extract(e, source, "%arg0", CONTAINER_LEN)
		filled := emit_ptr_len(e, view_type, storage, length)
		index := reversed ? length : "0"
		first, second, out := temp(e), temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = insertvalue %s undef, %s %s, %d", first, iterator, view_type, filled, ITER_ARRAY_DATA)
		fmt.sbprintfln(&e.b, "  %s = insertvalue %s %s, i64 %s, %d", second, iterator, first, index, ITER_ARRAY_INDEX)
		fmt.sbprintfln(&e.b, "  %s = insertvalue %s %s, i1 %s, %d", out, iterator, second, reversed ? "true" : "false", ITER_ARRAY_REVERSED)
		fmt.sbprintfln(&e.b, "  ret %s %s", iterator, out)
		fmt.sbprintln(&e.b, "}")
		return
	}
	if symbol.synth == .Map_Iter {
		// `{ table, 0 }`. A null table is the empty map, and the runtime's scan
		// answers "finished" for it without touching anything.
		table := extract(e, source, "%arg0", CONTAINER_STORAGE)
		first, out := temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = insertvalue %s undef, ptr %s, %d", first, iterator, table, ITER_MAP_TABLE)
		fmt.sbprintfln(&e.b, "  %s = insertvalue %s %s, i64 0, %d", out, iterator, first, ITER_MAP_CURSOR)
		fmt.sbprintfln(&e.b, "  ret %s %s", iterator, out)
		fmt.sbprintln(&e.b, "}")
		return
	}
	element := llvm_type(e, type_of(e.c, symbol.params[0]).element)
	low := extract(e, source, "%arg0", RANGE_LOW)
	high := extract(e, source, "%arg0", RANGE_HIGH)
	closed := extract(e, source, "%arg0", RANGE_CLOSED)
	current, bound := reversed ? high : low, reversed ? low : high
	step1, step2, step3, out := temp(e), temp(e), temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s undef, %s %s, %d", step1, iterator, element, current, ITER_RANGE_CURRENT)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s %s, %s %s, %d", step2, iterator, step1, element, bound, ITER_RANGE_HIGH)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s %s, i1 %s, %d", step3, iterator, step2, closed, ITER_RANGE_CLOSED)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s %s, i1 %s, %d", out, iterator, step3, reversed ? "true" : "false", ITER_RANGE_REVERSED)
	fmt.sbprintfln(&e.b, "  ret %s %s", iterator, out)
	fmt.sbprintln(&e.b, "}")
}

@(private)
emit_synth_range_next :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	option := symbol.results[0]
	step := option_payload(e.c, option)
	element := llvm_type(e, step)
	iterator := llvm_type(e, symbol.params[0])
	signed := type_signed(e.c, step) || type_is_rune(e.c, step)

	pair_type := llvm_type(e, option)
	fmt.sbprintf(&e.b, "define %s %s(ptr %%arg0)", pair_type, name)
	fmt.sbprintln(&e.b, " {")
	fmt.sbprintln(&e.b, "entry:")
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
	open_test, closed_test, live := temp(e), temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp %s %s %s, %s", open_test, signed ? "slt" : "ult", element, current, high)
	fmt.sbprintfln(&e.b, "  %s = icmp %s %s %s, %s", closed_test, signed ? "sle" : "ule", element, current, high)
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, i1 %s, i1 %s", live, closed, closed_test, open_test)
	yield_label := new_label(e, "next.forward.yield")
	fmt.sbprintfln(&e.b, "  br i1 %s, label %%%s, label %%%s", live, yield_label, stop_label)

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
	reverse_open, reverse_closed, reverse_live := temp(e), temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp %s %s %s, %s", reverse_open, signed ? "sgt" : "ugt", element, current, high)
	fmt.sbprintfln(&e.b, "  %s = icmp %s %s %s, %s", reverse_closed, signed ? "sge" : "uge", element, current, high)
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, i1 %s, i1 %s", reverse_live, closed, reverse_closed, reverse_open)
	reverse_yield := new_label(e, "next.reverse.yield")
	fmt.sbprintfln(&e.b, "  br i1 %s, label %%%s, label %%%s", reverse_live, reverse_yield, stop_label)

	fmt.sbprintfln(&e.b, "%s:", reverse_yield)
	previous, yielded := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = sub %s %s, 1", previous, element, current)
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, %s %s, %s %s", yielded, closed, element, current, element, previous)
	fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", element, yielded, current_ptr)
	fmt.sbprintfln(&e.b, "  store i1 false, ptr %s", closed_ptr)
	fmt.sbprintfln(&e.b, "  ret %s %s", pair_type, emit_option_some(e, option, yielded))

	// design.md "Typed fallibility": exhaustion is `.none`, which is `Option`'s
	// designated zero and therefore the all-zero representation.
	fmt.sbprintfln(&e.b, "%s:", stop_label)
	fmt.sbprintfln(&e.b, "  ret %s zeroinitializer", pair_type)
	fmt.sbprintln(&e.b, "}")
}

@(private)
emit_synth_array_next :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	option := symbol.results[0]
	element := llvm_type(e, option_payload(e.c, option))
	iterator := llvm_type(e, symbol.params[0])
	iterator_info := type_of(e.c, symbol.params[0])
	array_type := symbol_of(e.c, iterator_info.fields[ITER_ARRAY_DATA]).type
	data_type := llvm_type(e, array_type)
	count := type_of(e.c, array_type).count

	pair_type := llvm_type(e, option)
	fmt.sbprintf(&e.b, "define %s %s(ptr %%arg0)", pair_type, name)
	fmt.sbprintln(&e.b, " {")
	fmt.sbprintln(&e.b, "entry:")
	index_ptr := gep_field(e, iterator, "%arg0", ITER_ARRAY_INDEX)
	index := load(e, "i64", index_ptr)
	reversed_ptr := gep_field(e, iterator, "%arg0", ITER_ARRAY_REVERSED)
	reversed := load(e, "i1", reversed_ptr)
	forward_live, reverse_live, live := temp(e), temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp slt i64 %s, %d", forward_live, index, count)
	fmt.sbprintfln(&e.b, "  %s = icmp sgt i64 %s, 0", reverse_live, index)
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, i1 %s, i1 %s", live, reversed, reverse_live, forward_live)
	yield_label, stop_label := new_label(e, "next.yield"), new_label(e, "next.stop")
	fmt.sbprintfln(&e.b, "  br i1 %s, label %%%s, label %%%s", live, yield_label, stop_label)

	fmt.sbprintfln(&e.b, "%s:", yield_label)
	data_ptr := gep_field(e, iterator, "%arg0", ITER_ARRAY_DATA)
	previous, at := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = sub i64 %s, 1", previous, index)
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, i64 %s, i64 %s", at, reversed, previous, index)
	slot, value := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = getelementptr inbounds %s, ptr %s, i64 0, i64 %s", slot, data_type, data_ptr, at)
	fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", value, element, slot)
	stepped, next_index := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = add i64 %s, 1", stepped, index)
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, i64 %s, i64 %s", next_index, reversed, previous, stepped)
	fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", next_index, index_ptr)
	fmt.sbprintfln(&e.b, "  ret %s %s", pair_type, emit_option_some(e, option, value))

	fmt.sbprintfln(&e.b, "%s:", stop_label)
	fmt.sbprintfln(&e.b, "  ret %s zeroinitializer", pair_type)
	fmt.sbprintln(&e.b, "}")
}

// The slice half of `next`. Same `{ data, index }` iterator as an array's; the
// bound is the slice's own length word and the element address goes through its
// data pointer rather than into an inline array.
@(private)
emit_synth_slice_next :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	option := symbol.results[0]
	element := llvm_type(e, option_payload(e.c, option))
	iterator := llvm_type(e, symbol.params[0])
	iterator_info := type_of(e.c, symbol.params[0])
	slice_type := symbol_of(e.c, iterator_info.fields[ITER_ARRAY_DATA]).type
	slice_llvm := llvm_type(e, slice_type)

	pair_type := llvm_type(e, option)
	fmt.sbprintf(&e.b, "define %s %s(ptr %%arg0)", pair_type, name)
	fmt.sbprintln(&e.b, " {")
	fmt.sbprintln(&e.b, "entry:")
	index_ptr := gep_field(e, iterator, "%arg0", ITER_ARRAY_INDEX)
	index := load(e, "i64", index_ptr)
	reversed_ptr := gep_field(e, iterator, "%arg0", ITER_ARRAY_REVERSED)
	reversed := load(e, "i1", reversed_ptr)
	slice_ptr := gep_field(e, iterator, "%arg0", ITER_ARRAY_DATA)
	slice_value := load(e, slice_llvm, slice_ptr)
	length := extract(e, slice_llvm, slice_value, SLICE_LEN)
	forward_live, reverse_live, live := temp(e), temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp slt i64 %s, %s", forward_live, index, length)
	fmt.sbprintfln(&e.b, "  %s = icmp sgt i64 %s, 0", reverse_live, index)
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, i1 %s, i1 %s", live, reversed, reverse_live, forward_live)
	yield_label, stop_label := new_label(e, "next.yield"), new_label(e, "next.stop")
	fmt.sbprintfln(&e.b, "  br i1 %s, label %%%s, label %%%s", live, yield_label, stop_label)

	fmt.sbprintfln(&e.b, "%s:", yield_label)
	data := extract(e, slice_llvm, slice_value, SLICE_DATA)
	previous, at := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = sub i64 %s, 1", previous, index)
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, i64 %s, i64 %s", at, reversed, previous, index)
	slot := gep_at(e, element, data, at)
	value := load(e, element, slot)
	stepped, next_index := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = add i64 %s, 1", stepped, index)
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, i64 %s, i64 %s", next_index, reversed, previous, stepped)
	fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", next_index, index_ptr)
	fmt.sbprintfln(&e.b, "  ret %s %s", pair_type, emit_option_some(e, option, value))

	fmt.sbprintfln(&e.b, "%s:", stop_label)
	fmt.sbprintfln(&e.b, "  ret %s zeroinitializer", pair_type)
	fmt.sbprintln(&e.b, "}")
}

// The map half of `next`. Iteration order is unspecified (design.md "Maps").
// The cursor is the runtime's own slot position, so the walk is the same one a
// direct `foreach` performs; the protocol's `Element` is the `{key, value}` entry.
@(private)
emit_synth_map_next :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	option := symbol.results[0]
	entry_type := option_payload(e.c, option)
	element := llvm_type(e, entry_type)
	iterator := llvm_type(e, symbol.params[0])
	ops := container_ops_global(e, type_of(e.c, symbol.params[0]).key)

	pair_type := llvm_type(e, option)
	fmt.sbprintf(&e.b, "define %s %s(ptr %%arg0)", pair_type, name)
	fmt.sbprintln(&e.b, " {")
	fmt.sbprintln(&e.b, "entry:")
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

	// design.md "Iteration adapters": a map's `Element` is its `{key, value}`
	// entry, so the protocol path hands back the same record a direct loop
	// destructures.
	fmt.sbprintfln(&e.b, "%s:", yield_label)
	entry := type_of(e.c, type_underlying(e.c, entry_type))
	key_type := llvm_type(e, symbol_of(e.c, entry.fields[ELEMENT_FIRST]).type)
	value_type := llvm_type(e, symbol_of(e.c, entry.fields[ELEMENT_SECOND]).type)
	key := load(e, key_type, load(e, "ptr", key_out))
	value := load(e, value_type, load(e, "ptr", value_out))
	built, whole := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s undef, %s %s, %d", built, element, key_type, key, ELEMENT_FIRST)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s %s, %s %s, %d", whole, element, built, value_type, value, ELEMENT_SECOND)
	fmt.sbprintfln(&e.b, "  ret %s %s", pair_type, emit_option_some(e, option, whole))

	fmt.sbprintfln(&e.b, "%s:", stop_label)
	fmt.sbprintfln(&e.b, "  ret %s zeroinitializer", pair_type)
	fmt.sbprintln(&e.b, "}")
}

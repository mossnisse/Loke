// Iteration lowering and synthesized iterator bodies.
//
// Part of the textual LLVM backend; see compiler-architecture.md.
package lokec

import "core:fmt"

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
emit_range_value :: proc(e: ^Emitter, v: ^Expr_Range, as_type: Type_Id) -> string {
	info := type_of(e.c, as_type)
	element := info.element
	low := emit_expr(e, v.lo)
	high := emit_expr(e, v.hi)
	closed := v.op == .Range_Incl ? "true" : "false"
	storage := llvm_type(e, as_type)
	step1 := temp(e)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s undef, %s %s, %d", step1, storage, llvm_type(e, element), low, RANGE_LOW)
	step2 := temp(e)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s %s, %s %s, %d", step2, storage, step1, llvm_type(e, element), high, RANGE_HIGH)
	out := insert(e, storage, step2, "i1", closed, RANGE_CLOSED)
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
// a place the binding *is* (`&value` in a by-reference loop).
//
// `stored` says the source is still the container's own storage, so a managed
// value has to be *cloned* out of it rather than loaded: the loop owns its copy
// for the length of one step and drops it at the end (design.md "Element
// bindings"). A value an iterator's `next` already handed over is owned
// already, and moving it costs nothing.
@(private = "file")
Foreach_Field :: struct {
	type:    Type_Id,
	address: string,
	value:   string,
	place:   bool,
	stored:  bool,
}

// The owned value one step yields for this field, cloning when the source is
// the container's own storage.
@(private = "file")
owned_field_value :: proc(e: ^Emitter, field: Foreach_Field) -> string {
	value := field_value(e, field)
	if field.stored && emit_lifecycle(e, field.type).managed {
		return emit_clone_value(e, field.type, value)
	}
	return value
}

// One step's own cleanup scope. It sits directly above the loop's, at the depth
// `continue` unwinds to, so a value the step owns is disposed of at the end of
// that step rather than at the end of the loop. Registering an owned place in it
// is what makes falling out, `continue`, `break`, a `return`, a propagated
// error, and a panic each replay that disposal exactly once.
@(private = "file")
begin_iteration :: proc(e: ^Emitter) {
	push_scope(e, nil)
}

@(private = "file")
end_iteration :: proc(e: ^Emitter) {
	pop_scope(e)
}

// design.md "Element bindings": one binding names the whole `Element`; N
// bindings name its fields positionally. Sources come from what the lowering
// already has, so a destructuring loop never materializes the record it takes
// apart — only a one-name loop over a synthesized element pays to build it.
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
		// One name over a several-field traversal: the record is materialized, and
		// the loop owns the whole of it for the step. It is built even when the
		// name is `_`, so a field with a copy hook is produced and disposed of
		// exactly as it would be when bound (design.md "Element bindings").
		slot := alloca(e, record)
		for field, index in fields {
			store(e, field.type, owned_field_value(e, field), gep_field(e, record, slot, index))
		}
		register_scope_place(e, s.element_type, slot)
		if symbol := s.bindings[0].symbol; symbol != INVALID_SYMBOL {
			bind_local(e, symbol, slot)
		}
		return
	}
	// Several names over one record element: each one takes its field, which is a
	// move out of the record rather than a second copy.
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
			Foreach_Field{
				type = field.type,
				address = gep_field(e, record, address, index),
				stored = source.stored,
			},
		)
	}
}

@(private = "file")
bind_foreach_field :: proc(e: ^Emitter, symbol: Symbol_Id, field: Foreach_Field) {
	if field.place {
		// A by-reference binding names the container's own slot; the loop owns
		// nothing and there is nothing to dispose of.
		bind_foreach_place(e, symbol, field.address)
		return
	}
	// By default each iterated value is a copy, and assignment to the copy does
	// not modify the source. An ignored field is still produced and disposed of.
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

// `indexed()` numbers whatever traversal it wraps: the wrapped element becomes
// one field again (built here when the traversal produced several), with the
// counter following it.
@(private = "file")
with_index :: proc(e: ^Emitter, s: ^Stmt_Foreach, fields: []Foreach_Field, counter: string) -> []Foreach_Field {
	if !s.indexed {
		return fields
	}
	inner := fields[0]
	if len(fields) > 1 {
		// The wrapped traversal becomes one field again, which materializes it: the
		// copy out of container storage happens here, and what comes back is owned.
		wrapped := foreach_yielded_type(e, s)
		llvm := llvm_type(e, wrapped)
		slot := alloca(e, llvm)
		for field, index in fields {
			store(e, field.type, owned_field_value(e, field), gep_field(e, llvm, slot, index))
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

// The loop yields decoded code points: a byte offset (where the yielded code
// point begins, advancing 1 to 4 per step) comes from `rune_offsets()`, and a
// rune ordinal from `indexed()` (design.md "String iteration").
@(private = "file")
emit_text_foreach :: proc(e: ^Emitter, s: ^Stmt_Foreach) {
	data, length := emit_text_parts(e, s.iterable)
	offset := alloca(e, "i64")
	decoded := temp(e)
	fmt.sbprintfln(&e.b, "  store i64 0, ptr %s", offset)
	alloca_named(e, decoded, "i32")

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
	begin_iteration(e)
	used := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = call i64 @loke_rt_v1_rune_at(ptr %s, i64 %s, i64 %s, ptr %s)",
		used, data, length, current, decoded,
	)
	// A `string` is valid UTF-8 by construction, and every borrowed view is
	// checked where it's created — a zero here means that invariant already broke.
	stalled := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq i64 %s, 0", stalled, used)
	panic_if(e, stalled, "text.invalid", "invalid UTF-8 in a string")

	fields := []Foreach_Field{{type = TYPE_RUNE, address = decoded}}
	counter := ordinal == "" ? "" : load(e, "i64", ordinal)
	bind_foreach_fields(e, s, with_index(e, s, fields, counter))
	emit_scoped_block(e, s.body)
	end_iteration(e)
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
// The cursor is one integer the runtime hands back — the table's controls,
// seed, and slot count stay entirely inside `runtime/container.c`.
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
	begin_iteration(e)
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
		// The map's own `Element` is its `{key, value}` entry, and a value loop
		// yields an owned one: both halves are copied out of the slot, whether the
		// loop binds the entry whole or destructures it. `m.entries()` is the same
		// traversal reached through the protocol, and produces the same copies.
		fields := []Foreach_Field{
			{type = container_key(e.c, container), address = load(e, "ptr", key_out), stored = true},
			{type = container_element(e.c, container), address = load(e, "ptr", value_out), stored = true},
		}
		numbered := counter == "" ? "" : load(e, "i64", counter)
		bind_foreach_fields(e, s, with_index(e, s, fields, numbered))
	}
	emit_scoped_block(e, s.body)
	end_iteration(e)
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
		alloca_named(e, cursor, element)
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
		alloca_named(e, cursor, element)
		fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", element, low, cursor)
		limit = high
		floor = low
		closed = flag

	case .Array:
		// `&value` names the element in place, so the array must be a place
		// rather than a copy.
		array_slot = spill_iterable(e, s.iterable)
		counter_type = "i64"
		alloca_named(e, cursor, "i64")
		fmt.sbprintfln(&e.b, "  store i64 0, ptr %s", cursor)
		limit = fmt.aprintf("%d", s.count)

	case .Slice:
		// The slice is evaluated once; the loop walks its root through the data
		// word, so `&value` reaches the root, not a copy.
		slice_type := llvm_type(e, expr_base(s.iterable).type)
		value := emit_expr(e, s.iterable)
		array_slot = temp(e)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", array_slot, slice_type, value, SLICE_DATA)
		length := extract(e, slice_type, value, SLICE_LEN)
		counter_type = "i64"
		alloca_named(e, cursor, "i64")
		fmt.sbprintfln(&e.b, "  store i64 0, ptr %s", cursor)
		limit = length

	case .Dynamic:
		// design.md "Dynamic arrays": the loop views the *current* allocation,
		// stopping at the length, never the capacity — kept true for the loop's
		// duration by the whole-container loan it holds.
		header := emit_address(e, s.iterable)
		array_slot = temp(e)
		fmt.sbprintfln(&e.b, "  %s = load ptr, ptr %s", array_slot, header)
		length_slot := gep_field(e, CONTAINER_TYPE, header, CONTAINER_LEN)
		length := load(e, "i64", length_slot)
		counter_type = "i64"
		alloca_named(e, cursor, "i64")
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
		alloca_named(e, index_slot, "i64")
		fmt.sbprintfln(&e.b, "  store i64 0, ptr %s", index_slot)
		bind_local(e, s.bindings[1].symbol, index_slot)
	}
	// A sequence's cursor is already the index `indexed()` wants; a range's
	// cursor is its *value*, so numbering it needs a counter of its own.
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
	begin_iteration(e)
	numbered := counter == "" ? current : load(e, "i64", counter)
	bind_indexed_value(e, s, current, array_slot, element, limit, floor, closed, numbered)
	emit_scoped_block(e, s.body)
	end_iteration(e)
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
			// The cursor still counts up from the low endpoint; only the value it names
			// is mirrored, so `low + high' - current` walks it backwards without a
			// second loop shape (`high'` is the last value the forward loop would yield).
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
		// through it reaches the array. A value binding copies out of that same
		// storage instead, and owns what it copied for the step.
		append(&fields, Foreach_Field{
			type = yielded, address = address, place = s.bindings[0].is_ref, stored = true,
		})
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
	option := symbol_of(e.c, s.next_symbol).result
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
	begin_iteration(e)
	// `next` handed over an owned `Element`, so nothing here is a copy: the loop
	// takes what it was given and disposes of it at the end of the step.
	value := emit_union_payload(e, option, yielded, slot)
	fields := []Foreach_Field{{type = yielded, value = value}}
	numbered := counter == "" ? "" : load(e, "i64", counter)
	bind_foreach_fields(e, s, with_index(e, s, fields, numbered))
	emit_scoped_block(e, s.body)
	end_iteration(e)
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
	return spill_iterable_at(e, expr, expr_base(expr).type)
}

@(private)
spill_iterable_at :: proc(e: ^Emitter, expr: Expr, as_type: Type_Id) -> string {
	base := expr_base(expr)
	if base.addressable {
		return emit_address_at(e, expr, as_type)
	}
	value := emit_expr_at(e, expr, as_type)
	slot := alloca(e, llvm_type(e, as_type))
	fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", llvm_type(e, as_type), value, slot)
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
	open_function(e, "define %s %s(%s %%arg0)", iterator, name, source)
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
		second := insert(e, iterator, first, "i64", index, ITER_ARRAY_INDEX)
		out := insert(e, iterator, second, "i1", reversed ? "true" : "false", ITER_ARRAY_REVERSED)
		fmt.sbprintfln(&e.b, "  ret %s %s", iterator, out)
		fmt.sbprintln(&e.b, "}")
		return
	}
	if symbol.synth == .Dynamic_Iter || symbol.synth == .Dynamic_Iter_Reverse {
		// `{ {storage, len}, 0 }`: the current allocation, viewed as a slice.
		// Capacity and allocator stay behind, keeping the iterator a borrow, not a
		// second header.
		view_type := llvm_type(e, symbol_of(e.c, type_of(e.c, symbol.result).fields[ITER_ARRAY_DATA]).type)
		storage := extract(e, source, "%arg0", CONTAINER_STORAGE)
		length := extract(e, source, "%arg0", CONTAINER_LEN)
		filled := emit_ptr_len(e, view_type, storage, length)
		index := reversed ? length : "0"
		first := insert(e, iterator, "undef", view_type, filled, ITER_ARRAY_DATA)
		second := insert(e, iterator, first, "i64", index, ITER_ARRAY_INDEX)
		out := insert(e, iterator, second, "i1", reversed ? "true" : "false", ITER_ARRAY_REVERSED)
		fmt.sbprintfln(&e.b, "  ret %s %s", iterator, out)
		fmt.sbprintln(&e.b, "}")
		return
	}
	if symbol.synth == .Map_View_Iter {
		// A view already *is* the table pointer, so its `iter` only pairs it with a
		// fresh cursor. Every `iter()` starts a new traversal.
		table := extract(e, source, "%arg0", VIEW_SOURCE)
		first := insert(e, iterator, "undef", "ptr", table, ITER_MAP_TABLE)
		out := insert(e, iterator, first, "i64", "0", ITER_MAP_CURSOR)
		fmt.sbprintfln(&e.b, "  ret %s %s", iterator, out)
		fmt.sbprintln(&e.b, "}")
		return
	}
	if symbol.synth == .Text_Iter {
		// A `string`, a `string_view`, and the rune-offset view all reach the same
		// borrowed `{ data, len }`; only where it sits in the receiver differs.
		view := ""
		if underlying_info(e.c, symbol.params[0]).kind == .Struct {
			view = extract(e, source, "%arg0", VIEW_SOURCE)
		} else {
			data := extract(e, source, "%arg0", STRING_DATA)
			length := extract(e, source, "%arg0", STRING_LEN)
			view = emit_ptr_len(e, STRING_VIEW_TYPE, data, length)
		}
		first := insert(e, iterator, "undef", STRING_VIEW_TYPE, view, ITER_TEXT_VIEW)
		out := insert(e, iterator, first, "i64", "0", ITER_TEXT_OFFSET)
		fmt.sbprintfln(&e.b, "  ret %s %s", iterator, out)
		fmt.sbprintln(&e.b, "}")
		return
	}
	if symbol.synth == .Map_Iter {
		// `{ table, 0 }`. A null table is the empty map, and the runtime's scan
		// answers "finished" for it without touching anything.
		table := extract(e, source, "%arg0", CONTAINER_STORAGE)
		first := insert(e, iterator, "undef", "ptr", table, ITER_MAP_TABLE)
		out := insert(e, iterator, first, "i64", "0", ITER_MAP_CURSOR)
		fmt.sbprintfln(&e.b, "  ret %s %s", iterator, out)
		fmt.sbprintln(&e.b, "}")
		return
	}
	element := llvm_type(e, type_of(e.c, symbol.params[0]).element)
	low := extract(e, source, "%arg0", RANGE_LOW)
	high := extract(e, source, "%arg0", RANGE_HIGH)
	closed := extract(e, source, "%arg0", RANGE_CLOSED)
	current, bound := reversed ? high : low, reversed ? low : high
	step1 := insert(e, iterator, "undef", element, current, ITER_RANGE_CURRENT)
	step2 := insert(e, iterator, step1, element, bound, ITER_RANGE_HIGH)
	step3 := insert(e, iterator, step2, "i1", closed, ITER_RANGE_CLOSED)
	out := insert(e, iterator, step3, "i1", reversed ? "true" : "false", ITER_RANGE_REVERSED)
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
	open_function(e, "define %s %s(ptr %%arg0)", pair_type, name)
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

// `next` for an array or a slice. One cursor — `{ data, index, reversed }` —
// and one forward/reverse step serve both; only the bound and the way an
// element address is formed differ, which is the whole of the `slice` branch
// below. They were two 48-line copies that agreed on the other 40.
@(private)
emit_synth_indexed_next :: proc(e: ^Emitter, symbol: ^Symbol, name: string, slice: bool) {
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	option := symbol.result
	element := llvm_type(e, option_payload(e.c, option))
	iterator := llvm_type(e, symbol.params[0])
	iterator_info := type_of(e.c, symbol.params[0])
	stored := symbol_of(e.c, iterator_info.fields[ITER_ARRAY_DATA]).type
	stored_llvm := llvm_type(e, stored)

	pair_type := llvm_type(e, option)
	open_function(e, "define %s %s(ptr %%arg0)", pair_type, name)
	index_ptr := gep_field(e, iterator, "%arg0", ITER_ARRAY_INDEX)
	index := load(e, "i64", index_ptr)
	reversed_ptr := gep_field(e, iterator, "%arg0", ITER_ARRAY_REVERSED)
	reversed := load(e, "i1", reversed_ptr)
	// A slice carries its own length, so the header is loaded once here and the
	// data pointer is read back out of it in the yield block. A fixed array's
	// bound is a constant and its storage is the iterator field itself.
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
	// The element is still the container's, so a managed one is cloned out of it:
	// what `next` hands back is owned, exactly as a by-value loop's copy is.
	value := load(e, element, slot)
	if payload := option_payload(e.c, option); emit_lifecycle(e, payload).managed {
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

// The map half of `next`, serving the whole-entry walk and the two half walks
// `keys()` and `values()` name. Iteration order is unspecified (design.md
// "Maps"). The cursor is the runtime's own slot position, so the walk is the
// same one a direct `foreach` performs.
//
// What it yields is *owned*: a managed half is cloned out of the slot, exactly
// as a by-value loop over the map copies it, so the two agree by construction.
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
	open_function(e, "define %s %s(ptr %%arg0)", pair_type, name)
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
	key_type := container_key(e.c, subject)
	value_type := container_element(e.c, subject)
	out := ""
	#partial switch symbol.synth {
	case .Map_Keys_Next:
		out = copy_map_half(e, key_type, load(e, "ptr", key_out))
	case .Map_Values_Next:
		out = copy_map_half(e, value_type, load(e, "ptr", value_out))
	case:
		// design.md "Iteration adapters": a map's `Element` is its `{key, value}`
		// entry, so this hands back the same record a direct loop destructures.
		key := copy_map_half(e, key_type, load(e, "ptr", key_out))
		value := copy_entry_value(e, key_type, key, value_type, load(e, "ptr", value_out))
		built := insert(e, element, "undef", llvm_type(e, key_type), key, ELEMENT_FIRST)
		out = insert(e, element, built, llvm_type(e, value_type), value, ELEMENT_SECOND)
	}
	fmt.sbprintfln(&e.b, "  ret %s %s", pair_type, emit_option_some(e, option, out))

	fmt.sbprintfln(&e.b, "%s:", stop_label)
	fmt.sbprintfln(&e.b, "  ret %s zeroinitializer", pair_type)
	fmt.sbprintln(&e.b, "}")
}

// One half of a slot, as an owned value: the map keeps its own storage, so a
// managed half is cloned rather than aliased.
@(private = "file")
copy_map_half :: proc(e: ^Emitter, type: Type_Id, address: string) -> string {
	value := load(e, llvm_type(e, type), address)
	if !emit_lifecycle(e, type).managed {
		return value
	}
	return emit_clone_value(e, type, value)
}

// The second half of an entry. If copying it fails, the first half is already an
// owned value that nothing else will ever see, so it is destroyed before the
// allocator's failure policy runs (design.md "Allocation failure").
@(private = "file")
copy_entry_value :: proc(
	e: ^Emitter, key_type: Type_Id, key: string, value_type: Type_Id, address: string,
) -> string {
	if !emit_lifecycle(e, key_type).managed || !emit_lifecycle(e, value_type).managed {
		return copy_map_half(e, value_type, address)
	}
	value_llvm := llvm_type(e, value_type)
	staged := alloca(e, value_llvm)
	provider := emit_default_allocator(e)
	ok := emit_try_clone_into(e, value_type, staged, address, provider)
	fail_label, done_label := new_label(e, "entry.failed"), new_label(e, "entry.done")
	branch_if(e, ok, done_label, fail_label)

	place_label(e, fail_label)
	held := alloca(e, llvm_type(e, key_type))
	store(e, key_type, key, held)
	emit_drop_place(e, key_type, held)
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_alloc_failed(ptr %s)", provider)
	fmt.sbprintln(&e.b, "  unreachable")
	e.terminated = true

	place_label(e, done_label)
	return load(e, value_llvm, staged)
}

// design.md "String iteration": one decoded code point per step, advancing the
// cursor by the 1 to 4 bytes it spanned. `rune_offsets()` yields the byte offset
// the code point began at beside it; the plain rune walk yields the value alone.
@(private)
emit_synth_text_next :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	option := symbol.result
	yielded := option_payload(e.c, option)
	iterator := llvm_type(e, symbol.params[0])
	pair_type := llvm_type(e, option)
	open_function(e, "define %s %s(ptr %%arg0)", pair_type, name)

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
	used := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = call i64 @loke_rt_v1_rune_at(ptr %s, i64 %s, i64 %s, ptr %s)",
		used, data, length, offset, decoded,
	)
	// A `string` is valid UTF-8 by construction, and every borrowed view is
	// checked where it is created — a zero here means that invariant already broke.
	stalled := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq i64 %s, 0", stalled, used)
	panic_if(e, stalled, "text.invalid", "invalid UTF-8 in a string")
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

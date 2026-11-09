// Printing: a printable type's thunk and body, the `core:fmt` sink, and the
// reports of formatted panics and failed entries.
package lokec

import "core:fmt"

// standard-library.md "Printed forms": each `typeid`'s name, so a `typeid`
// prints without a `base:runtime` import.
TYPE_NAMES :: "@.loke.type_names"

// The constant message a `panic`/`assert` was written with.
@(private = "file")
panic_message_text :: proc(v: ^Expr_Call, index: int, fallback: string) -> string {
	if index < len(v.bound) && v.bound[index] != nil {
		return expr_base(v.bound[index]).const_value.text
	}
	return fallback
}

// design.md "Built-in procedures": the arguments after the message follow it on
// the report line, each after a space, as `fmt.eprintln` would print them. They
// are evaluated before the report starts, so one that panics is its own panic.
@(private)
emit_formatted_panic :: proc(e: ^Emitter, v: ^Expr_Call, message_index: int, fallback: string) {
	message := panic_message_text(v, message_index, fallback)
	if len(v.bound) <= message_index + 1 {
		emit_panic(e, message)
		return
	}
	// The arguments' temporaries belong to this path, which never reaches the
	// statement's end; the unwind drops them.
	push_temporaries(e)
	defer pop_temporaries(e)
	args := v.bound[message_index + 1:]
	addresses := make([]string, len(args), context.temp_allocator)
	for arg, index in args {
		addresses[index] = emit_viewed_address(e, arg, expr_base(arg).type)
	}
	writer := emit_stderr_writer(e)
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_panic_begin(ptr %s)", text_literal_global(e, message))
	for arg, index in args {
		emit_format_literal_to(e, writer, " ")
		emit_format_thunk_call(e, expr_base(arg).type, addresses[index], writer, generated_name(e, PANIC_OPTIONS))
	}
	fmt.sbprintln(&e.b, "  call void @loke_rt_v1_panic_end()")
	emit_unreachable(e)
}

// A `fmt.Writer` on standard error, in a slot of its own.
@(private = "file")
emit_stderr_writer :: proc(e: ^Emitter) -> string {
	writer := alloca(e, "{ ptr, ptr }")
	fmt.sbprintfln(
		&e.b, "  store {{ ptr, ptr }} {{ ptr inttoptr (i64 %d to ptr), ptr %s }}, ptr %s",
		SINK_STDERR, generated_name(e, SINK_STD_WITNESS), writer,
	)
	return writer
}

// design.md "Program entry and exit": a `main` returning a fallible union
// exits 0 on success. On failure, after `main`'s own cleanup, the startup code
// prints `error: ` and the failure to standard error as a formatted panic
// prints its arguments, drops it, and exits 1.
@(private)
emit_entry_failure_report :: proc(e: ^Emitter, entry: string, result, failure: Type_Id, attributes: string) -> string {
	under := type_underlying(e.c, result)
	value := ""
	if returns_sret(e, result, false) {
		value = temporary_slot(e, result)
		fmt.sbprintfln(&e.b, "  call void %s(ptr %s)%s", entry, value, attributes)
	} else {
		value = temp(e)
		fmt.sbprintfln(&e.b, "  %s = call %s %s()%s", value, llvm_type(e, result), entry, attributes)
	}
	slot := emit_union_spill(e, under, value)
	failed := emit_union_failed(e, under, value)
	status := alloca(e, "i32")
	fmt.sbprintfln(&e.b, "  store i32 0, ptr %s", status)
	report, done := new_label(e, "main.failed"), new_label(e, "main.done")
	branch_if(e, failed, report, done)

	place_label(e, report)
	// What the program printed comes first, even when both streams are redirected.
	fmt.sbprintln(&e.b, "  call void @loke_rt_v1_flush_stdout()")
	writer := emit_stderr_writer(e)
	emit_format_literal_to(e, writer, "error: ")
	data := slot
	if failure != result {
		data = gep_field(e, llvm_type(e, under), slot, 0)
	}
	// A formatter that panics still drops the failure.
	held := Deferred{}
	if emit_lifecycle(e, failure).managed {
		held = begin_temporary_drop(e, failure, data)
	}
	emit_format_thunk_call(e, failure, data, writer, generated_name(e, PANIC_OPTIONS))
	emit_format_literal_to(e, writer, "\n")
	drop_temporary_value(e, held)
	fmt.sbprintfln(&e.b, "  store i32 1, ptr %s", status)
	branch(e, done)

	place_label(e, done)
	return load(e, "i32", status)
}

// `fmt.DEFAULT_OPTIONS`, for a formatted panic, which has no `core:fmt` to ask.
@(private = "file")
PANIC_OPTIONS :: "@loke.fmt.panic_options"

@(private = "file")
fmt_thunk_name :: proc(e: ^Emitter, type: Type_Id) -> string {
	return generated_name(e, fmt.aprintf("@loke.f.%d", typeid_value(e.c, type)))
}

// Runtime-ABI wrappers for recursive aggregate formatting, one per printable
// type, which a formatted panic calls without core:fmt.
@(private)
emit_format_thunks :: proc(e: ^Emitter) {
	if !e.c.format_requested {
		return
	}
	// Private `typeid` names, so printing needs no `base:runtime` import.
	names := make([]string, len(e.c.typeid_order) + 1)
	for type in e.c.typeid_order {
		names[typeid_value(e.c, type)] = text_view_constant(e, type_name(e.c, type))
		if type_is_printable(e.c, type) {
			emit_one_format_thunk(e, type)
		}
	}
	append(&e.globals, fmt.aprintf(
		"%s = private unnamed_addr constant {{ i64, i8, [7 x i8] }} {{ i64 10, i8 0, [7 x i8] zeroinitializer }}\n",
		generated_name(e, PANIC_OPTIONS),
	))
	append_constant_array(e, generated_name(e, TYPE_NAMES), STRING_VIEW_TYPE, names)
}

// Aggregates print as `[elements]`, `Name{field = value}`, `(field = value)`,
// and enum members by name.
@(private = "file")
emit_one_format_thunk :: proc(e: ^Emitter, type: Type_Id) {
	frame := begin_function_emission(e)
	defer finish_pending_thunk(e, frame)

	open_function(e, "define private void %s(ptr %%data, ptr %%w, ptr %%o)", fmt_thunk_name(e, type))
	if witness := e.c.formatters[type]; witness != nil {
		// The same slot ABI ordinary dyn calls use, with the C runtime's spilled
		// writer and options loaded back into Loke values.
		target := emit_witness_slot(e, e.witness_names[witness], 0)
		w, o := e.c.runtime_types["Writer"], e.c.runtime_types["Options"]
		w_value, o_value := load_place(e, w, "%w"), load_place(e, o, "%o")
		fmt.sbprintfln(
			&e.b, "  call void %s(ptr %%data, %s %s, %s %s)", target, llvm_type(e, w), w_value, llvm_type(e, o), o_value,
		)
	} else {
		emit_format_body(e, type, "%data")
	}
	fmt.sbprintln(&e.b, "  ret void")
	fmt.sbprintln(&e.b, "}")
	fmt.sbprintln(&e.b, "")
}

@(private = "file")
emit_format_literal :: proc(e: ^Emitter, text: string) {
	emit_format_literal_to(e, "%w", text)
}

@(private = "file")
emit_format_literal_to :: proc(e: ^Emitter, writer, text: string) {
	global := text_literal_global(e, text)
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_fmt_bytes(ptr %s, ptr %s, i64 %d)", writer, global, len(text))
}

@(private = "file")
emit_format_call :: proc(e: ^Emitter, type: Type_Id, address: string) {
	emit_format_thunk_call(e, type, address, "%w", "%o")
}

// Formats the value at `address` through its type's thunk, which forwards to
// the type's coherent `Formattable` witness or spells it.
@(private = "file")
emit_format_thunk_call :: proc(e: ^Emitter, type: Type_Id, address, writer, options: string) {
	if !type_is_printable(e.c, type) || typeid_value(e.c, type) == 0 {
		emit_format_literal_to(e, writer, "<unformattable>")
		return
	}
	fmt.sbprintfln(&e.b, "  call void %s(ptr %s, ptr %s, ptr %s)", fmt_thunk_name(e, type), address, writer, options)
}

// An element, field, key, or payload. A string or rune here prints quoted, so
// `["a b", "c"]` cannot be read as three elements; a type with its own `format`
// prints as that method says.
@(private = "file")
emit_format_nested :: proc(e: ^Emitter, type: Type_Id, address: string) {
	under := type_underlying(e.c, type)
	info := type_of(e.c, under)
	if info == nil || type_has_written_format(e.c, type) {
		emit_format_call(e, type, address)
		return
	}
	#partial switch info.kind {
	case .String, .String_View, .CString_View:
		emit_format_text(e, under, address, "loke_rt_v1_fmt_quoted")
	case .Rune:
		value := load(e, "i32", address)
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_fmt_quoted_rune(ptr %%w, i32 %s)", value)
	case .Box, .Pointer:
		// A chain that returns to itself, as `P :: distinct ^P` does, ends in no
		// string to quote, so its own formatter prints it rather than an
		// endless inline expansion.
		if referent_chain_cycles(e.c, under) {
			emit_format_call(e, type, address)
		} else if info.kind == .Box {
			emit_format_nested(e, info.element, emit_box_payload_address(e, under, load(e, "ptr", address)))
		} else {
			emit_format_nested(e, info.element, load(e, "ptr", address))
		}
	case:
		emit_format_call(e, type, address)
	}
}

// The text of a `string`, `string_view`, or `cstring_view` at `address`, through
// a runtime entry taking its data and length.
@(private = "file")
emit_format_text :: proc(e: ^Emitter, under: Type_Id, address, callee: string) {
	data, length: string
	if type_kind(e.c, under) == .CString_View {
		data = load(e, "ptr", address)
		length = temp(e)
		fmt.sbprintfln(&e.b, "  %s = call i64 @loke_rt_v1_cstring_len(ptr %s)", length, data)
	} else {
		data, length = load_pair(e, llvm_type(e, under), address, STRING_DATA, STRING_LEN)
	}
	fmt.sbprintfln(&e.b, "  call void @%s(ptr %%w, ptr %s, i64 %s)", callee, data, length)
}

// Whether following boxes and checked pointers from `type` comes back to a
// type already passed.
@(private = "file")
referent_chain_cycles :: proc(c: ^Compiler, type: Type_Id) -> bool {
	seen := make(map[Type_Id]bool)
	defer delete(seen)
	current := type_underlying(c, type)
	for {
		info := type_of(c, current)
		if info == nil || (info.kind != .Box && info.kind != .Pointer) {
			return false
		}
		if current in seen {
			return true
		}
		seen[current] = true
		current = type_underlying(c, info.element)
	}
}

@(private = "file")
emit_format_body :: proc(e: ^Emitter, type: Type_Id, address: string) {
	// A `distinct` type prints as the shape it wraps.
	under := type_underlying(e.c, type)
	info := type_of(e.c, under)
	if info == nil {
		emit_format_literal(e, "<unformattable>")
		return
	}

	#partial switch info.kind {
	case .Bool:
		value := load(e, "i1", address)
		widened := temp(e)
		fmt.sbprintfln(&e.b, "  %s = zext i1 %s to i32", widened, value)
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_fmt_bool(ptr %%w, i32 %s)", widened)

	case .Int, .Allocator_Error:
		emit_format_integer(e, under, load(e, llvm_type(e, under), address))

	case .Typeid:
		value := load(e, "i64", address)
		emit_format_type_name(e, value)

	case .Rune:
		value := load(e, "i32", address)
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_fmt_rune(ptr %%w, i32 %s)", value)

	case .Float:
		llvm := llvm_type(e, under)
		value := load(e, llvm, address)
		// A float prints at its own precision: widened, its shortest spelling
		// would carry the binary noise of the narrower type.
		switch llvm {
		case "double":
			fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_fmt_f64(ptr %%w, double %s)", value)
		case "float":
			fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_fmt_f32(ptr %%w, float %s)", value)
		case:
			widened := temp(e)
			fmt.sbprintfln(&e.b, "  %s = fpext %s %s to float", widened, llvm, value)
			fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_fmt_f16(ptr %%w, float %s)", widened)
		}

	// standard-library.md "Printed forms": a checked pointer always names a
	// value, so it prints that value, as a box does; an unchecked address prints
	// as one.
	case .Pointer:
		emit_format_call(e, info.element, load(e, "ptr", address))

	case .C_Pointer, .Raw_Pointer, .Proc, .Allocator:
		value := load(e, "ptr", address)
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_fmt_ptr(ptr %%w, ptr %s)", value)

	case .String, .String_View, .CString_View:
		emit_format_text(e, under, address, "loke_rt_v1_fmt_bytes")

	case .Enum:
		emit_format_enum(e, under, address)

	case .Array, .Simd:
		emit_format_sequence(e, info.element, address, fmt.aprintf("%d", info.count))

	case .Slice:
		data, length := load_pair(e, llvm_type(e, under), address, SLICE_DATA, SLICE_LEN)
		emit_format_sequence(e, info.element, data, length)

	case .Dynamic_Array:
		data, length := load_pair(e, llvm_type(e, under), address, CONTAINER_STORAGE, CONTAINER_LEN)
		emit_format_sequence(e, info.element, data, length)

	case .Map:
		emit_format_map(e, under, address)

	case .Box:
		// design.md "Owned values": a box is a value, so it prints its payload.
		emit_format_call(e, info.element, emit_box_payload_address(e, under, load(e, "ptr", address)))

	case .Struct:
		emit_format_struct(e, type, under, address)

	case .Union:
		emit_format_union(e, under, address)

	case:
		// A `dyn` view and anything else without a fixed spelling prints its type name.
		emit_format_literal(e, type_name(e.c, type))
	}
}

// An integer or an enum's underlying value, as its width and signedness print.
@(private = "file")
emit_format_integer :: proc(e: ^Emitter, under: Type_Id, value: string) {
	signed := type_signed(e.c, under)
	if type_bits(e.c, under) > 64 {
		llvm := llvm_type(e, under)
		low, shifted, high := temp(e), temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = trunc %s %s to i64", low, llvm, value)
		fmt.sbprintfln(&e.b, "  %s = lshr %s %s, 64", shifted, llvm, value)
		fmt.sbprintfln(&e.b, "  %s = trunc %s %s to i64", high, llvm, shifted)
		callee := signed ? "loke_rt_v1_fmt_i128" : "loke_rt_v1_fmt_u128"
		fmt.sbprintfln(&e.b, "  call void @%s(ptr %%w, i64 %s, i64 %s, ptr %%o)", callee, low, high)
		return
	}
	callee := signed ? "loke_rt_v1_fmt_i64" : "loke_rt_v1_fmt_u64"
	fmt.sbprintfln(&e.b, "  call void @%s(ptr %%w, i64 %s, ptr %%o)", callee, widen_to_i64(e, value, under))
}

// `.name` or `.name(payload)` for the active variant, chained like enums. A
// `Unit` payload prints as `.name`, as a payloadless variant does (standard-library.md
// "Printed forms").
@(private = "file")
emit_format_union :: proc(e: ^Emitter, under: Type_Id, address: string) {
	info := type_of(e.c, under)
	value := load_place(e, under, address)
	tag := emit_union_tag(e, under, value)
	slot := emit_union_spill(e, under, value)
	done := new_label(e, "fmt.union.done")
	hits := variant_labels(e, info, "fmt.union.hit")
	emit_union_switch(e, under, tag, hits, done)
	for variant, index in info.variants {
		place_label(e, hits[index])
		emit_format_literal(e, fmt.aprintf(".%s", identifier_text(e.c, info.variant_names[index])))
		if variant != TYPE_VOID && variant != e.c.unit_type {
			emit_format_literal(e, "(")
			payload := gep_field(e, llvm_type(e, under), slot, 0)
			emit_format_nested(e, variant, payload)
			emit_format_literal(e, ")")
		}
		branch(e, done)
	}
	place_label(e, done)
}

// A `typeid` prints its type's name, or its number when it has none.
@(private = "file")
emit_format_type_name :: proc(e: ^Emitter, id: string) {
	view := gep_at(e, STRING_VIEW_TYPE, generated_name(e, TYPE_NAMES), typeid_index(e, id))
	data, length := load_pair(e, STRING_VIEW_TYPE, view, VIEW_DATA, VIEW_LEN)
	missing := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq i64 %s, 0", missing, length)
	numeric, named, done := new_label(e, "fmt.typeid.number"), new_label(e, "fmt.typeid.named"), new_label(e, "fmt.typeid.done")
	branch_if(e, missing, numeric, named)

	place_label(e, named)
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_fmt_bytes(ptr %%w, ptr %s, i64 %s)", data, length)
	branch(e, done)

	place_label(e, numeric)
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_fmt_u64(ptr %%w, i64 %s, ptr %%o)", id)
	place_label(e, done)
}

// Enum members need not be contiguous, so this is a chain of comparisons.
@(private = "file")
emit_format_enum :: proc(e: ^Emitter, under: Type_Id, address: string) {
	info := type_of(e.c, under)
	llvm := llvm_type(e, under)
	value := load(e, llvm, address)
	done := new_label(e, "fmt.enum.done")
	for field in info.fields {
		sym := symbol_of(e.c, field)
		if sym == nil || sym.const_value.kind != .Integer {
			continue
		}
		matched := temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = icmp eq %s %s, %s",
			matched, llvm, value, bi_text(e.c, sym.const_value.integer),
		)
		hit, next := new_label(e, "fmt.enum.hit"), new_label(e, "fmt.enum.next")
		branch_if(e, matched, hit, next)
		place_label(e, hit)
		emit_format_literal(e, identifier_text(e.c, sym.name))
		branch(e, done)
		place_label(e, next)
	}
	// An unnamed value prints as its number.
	emit_format_integer(e, under, value)
	place_label(e, done)
}

@(private = "file")
emit_format_sequence :: proc(e: ^Emitter, element: Type_Id, base, count: string) {
	emit_format_literal(e, "[")
	loop := open_counted_loop(e, new_counter(e), "fmt.seq", count)
	emit_format_separator(e, loop.index)
	slot := gep_at(e, llvm_type(e, element), base, loop.index)
	emit_format_nested(e, element, slot)
	close_counted_loop(e, loop)
	emit_format_literal(e, "]")
}

// `, ` before every element but the first, whose `index` is zero.
@(private = "file")
emit_format_separator :: proc(e: ^Emitter, index: string) {
	first := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq i64 %s, 0", first, index)
	separator, element := new_label(e, "fmt.sep"), new_label(e, "fmt.element")
	branch_if(e, first, element, separator)
	place_label(e, separator)
	emit_format_literal(e, ", ")
	place_label(e, element)
}

// `[key = value, ...]` in slot-walk order.
@(private = "file")
emit_format_map :: proc(e: ^Emitter, under: Type_Id, address: string) {
	info := type_of(e.c, under)
	ops := container_ops_global(e, under)
	table := load(e, "ptr", address)
	cursor := alloca(e, "i64")
	fmt.sbprintfln(&e.b, "  store i64 0, ptr %s", cursor)
	key_out := alloca(e, "ptr")
	value_out := alloca(e, "ptr")
	emit_format_literal(e, "[")

	head, body, done := new_label(e, "fmt.map.head"), new_label(e, "fmt.map.body"), new_label(e, "fmt.map.done")
	place_label(e, head)
	current := load(e, "i64", cursor)
	next := emit_map_scan(e, table, ops, current, key_out, value_out, cursor)
	more := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp ne i64 %s, 0", more, next)
	branch_if(e, more, body, done)

	place_label(e, body)
	emit_format_separator(e, current)
	key_slot := load(e, "ptr", key_out)
	emit_format_nested(e, info.key, key_slot)
	emit_format_literal(e, " = ")
	emit_format_nested(e, info.element, load(e, "ptr", value_out))
	branch(e, head)

	place_label(e, done)
	emit_format_literal(e, "]")
}

@(private = "file")
emit_format_struct :: proc(e: ^Emitter, type, under: Type_Id, address: string) {
	info := type_of(e.c, under)
	// An anonymous record's type is its field list, so it prints as `(x = 1)`
	// rather than spelling that list out again as a name, and an unlabelled one
	// as `(1, true)`.
	anonymous := type_of(e.c, type).anonymous_record
	if anonymous {
		emit_format_literal(e, "(")
	} else {
		emit_format_literal(e, type_name(e.c, type))
		emit_format_literal(e, "{")
	}
	written := 0
	for field, index in info.fields {
		sym := symbol_of(e.c, field)
		if sym == nil || !sym.public {
			continue // the same public rule the metadata table follows
		}
		if written > 0 {
			emit_format_literal(e, ", ")
		}
		written += 1
		if label := field_label(e.c, field); label != "" {
			emit_format_literal(e, label)
			emit_format_literal(e, " = ")
		}
		slot := gep_field(e, llvm_type(e, under), address, index)
		// A formatter reads its value at the type's alignment, which a packed
		// field may not have (design.md "@(packed)"), so it reads an aligned copy.
		record_field_align(e, under, address, slot, sym.type)
		if _, unaligned := e.place_align[slot]; unaligned {
			aligned := alloca(e, llvm_type(e, sym.type))
			copy_bytes(e, aligned, slot, type_size(e.c, sym.type))
			slot = aligned
		}
		// Only the live prefix of an `@(initialized)` array holds values.
		if counter := symbol_of(e.c, sym.initialized_by); counter != nil {
			counter_slot := gep_field(e, llvm_type(e, under), address, int(counter.index))
			record_field_align(e, under, address, counter_slot, counter.type)
			count := widen_to_i64(e, load_place(e, counter.type, counter_slot), counter.type)
			emit_prefix_count_check(e, count, sym.type)
			element := underlying_info(e.c, sym.type).element
			emit_format_sequence(e, element, slot, count)
			continue
		}
		emit_format_nested(e, sym.type, slot)
	}
	emit_format_literal(e, anonymous ? ")" : "}")
}

// `fmt.Writer` is `dyn mut fmt.Sink`, whose one slot takes `[]u8`. The runtime's
// formatters end at `loke_rt_v1_sink_write`, which builds that slice here, in
// LLVM, so no C prototype has to agree with how a two-word aggregate is passed.
// The process streams are a witness of their own whose data pointer is the
// stream selector `loke_rt_v1_write_std` expects. Every module defines both:
// the runtime's `fmt_bytes` calls the first whether or not `core:fmt` is used.
SINK_STD_WITNESS :: "@loke.fmt.std_sink"
// runtime/loke_rt.h `LOKE_RT_STDOUT` and `LOKE_RT_STDERR`: a process sink's
// data word selects its stream, and a `dyn` view's data word is never null
// (design.md "Representation").
SINK_STDOUT :: 1
SINK_STDERR :: 2

@(private)
emit_sink_bridge :: proc(e: ^Emitter) {
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_write_std(ptr, ptr, i64)")
	fmt.sbprintln(&e.b, `define void @loke_rt_v1_sink_write(ptr %w, ptr %bytes, i64 %count) {
entry:
  %data = load ptr, ptr %w
  %witness.at = getelementptr inbounds { ptr, ptr }, ptr %w, i32 0, i32 1
  %witness = load ptr, ptr %witness.at
  %write = load ptr, ptr %witness
  %s.0 = insertvalue { ptr, i64 } undef, ptr %bytes, 0
  %s = insertvalue { ptr, i64 } %s.0, i64 %count, 1
  call void %write(ptr %data, { ptr, i64 } %s)
  ret void
}

`)
	std_write := generated_name(e, "@loke.fmt.std_write")
	fmt.sbprintfln(&e.b, "define private void %s(ptr %%stream, {{ ptr, i64 }} %%s) {{", std_write)
	fmt.sbprintln(&e.b, `entry:
  %bytes = extractvalue { ptr, i64 } %s, 0
  %count = extractvalue { ptr, i64 } %s, 1
  call void @loke_rt_v1_write_std(ptr %stream, ptr %bytes, i64 %count)
  ret void
}
`)
	fmt.sbprintfln(&e.b, "%s = private unnamed_addr constant [1 x ptr] [ptr %s]", generated_name(e, SINK_STD_WITNESS), std_write)
	fmt.sbprintln(&e.b, "")
}

// The compiler-owned `core:fmt` entry points.
@(private)
emit_fmt_builtin :: proc(e: ^Emitter, v: ^Expr_Call, kind: Builtin_Kind) -> string {
	if kind == .Fmt_Write_Bytes {
		writer := spill(e, e.c.runtime_types["Writer"], emit_expr(e, v.bound[0]))
		data, length := emit_text_parts(e, v.bound[1])
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_fmt_bytes(ptr %s, ptr %s, i64 %s)", writer, data, length)
		return "0"
	}
	stream := fmt.aprintf("inttoptr (i64 %d to ptr)", kind == .Fmt_Stdout_Writer ? SINK_STDOUT : SINK_STDERR)
	return dyn_view_value(e, llvm_type(e, e.c.runtime_types["Writer"]), stream, generated_name(e, SINK_STD_WITNESS))
}

@(private = "file")
load_pair :: proc(e: ^Emitter, storage, address: string, first, second: int) -> (string, string) {
	value := load(e, storage, address)
	return extract(e, storage, value, first), extract(e, storage, value, second)
}

@(private)
emit_synth_format :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	w, o := llvm_type(e, symbol.params[1]), llvm_type(e, symbol.params[2])
	open_function(e, "define %svoid %s(ptr %%data, %s %%writer, %s %%options)", llvm_linkage(name), name, w, o)
	fmt.sbprintfln(&e.b, "  %%w = alloca %s", w)
	fmt.sbprintfln(&e.b, "  %%o = alloca %s", o)
	store(e, symbol.params[1], "%writer", "%w")
	store(e, symbol.params[2], "%options", "%o")
	emit_format_body(e, symbol.owner_type, "%data")
	fmt.sbprintln(&e.b, "  ret void")
	fmt.sbprintln(&e.b, "}")
}

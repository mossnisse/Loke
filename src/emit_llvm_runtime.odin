// Runtime declarations, globals, formatting, metadata, and erased witnesses.
package lokec

import "core:fmt"
import "core:strings"

// design.md "String format printing": formatter thunks per `typeid`, kept out of
// the public `Type_Info` so `base:runtime` needs no `core:fmt`.
FMT_THUNKS :: "@.loke.fmt_thunks"
FMT_THUNK_COUNT :: "@.loke.fmt_thunks.count"
TYPE_NAMES :: "@.loke.type_names"

@(private)
emit_preamble :: proc(e: ^Emitter) {
	fmt.sbprintfln(&e.b, `target triple = "%s"`, e.c.target.triple)
	fmt.sbprintln(&e.b, "")
	emit_runtime_declarations(e)
	fmt.sbprintln(&e.b, "")
}

// An `Allocator` is a pointer to a `loke_rt_allocator_v1` record, dispatched
// only through the runtime helpers.
RT_DEFAULT_ALLOCATOR :: "@loke_rt_v1_default_allocator"

// The published build-selected allocator, or the fallback record above.
emit_default_allocator :: proc(e: ^Emitter) -> string {
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = call ptr @loke_rt_v1_selected_allocator()", out)
	return out
}

RT_ALLOCATOR_RECORD :: "{ i32, i32, ptr, ptr, ptr, i32, i32 }"

@(private = "file")
emit_runtime_declarations :: proc(e: ^Emitter) {
	fmt.sbprintfln(&e.b, "%s = external global %s", RT_DEFAULT_ALLOCATOR, RT_ALLOCATOR_RECORD)
	fmt.sbprintln(&e.b, "declare ptr @loke_rt_v1_alloc(ptr, i64, i64)")
	fmt.sbprintln(&e.b, "declare ptr @loke_rt_v1_alloc_zeroed(ptr, i64, i64)")
	fmt.sbprintln(&e.b, "declare ptr @loke_rt_v1_resize(ptr, ptr, i64, i64, i64)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_free(ptr, ptr, i64, i64)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_reset(ptr)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_alloc_failed(ptr)")
	fmt.sbprintln(&e.b, "declare ptr @loke_rt_v1_selected_allocator()")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_publish_allocator(ptr)")
	fmt.sbprintln(&e.b, "declare i32 @loke_rt_v1_provider_init_begin()")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_provider_init_end()")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_panic(ptr)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_abort(ptr)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_thread_attach()")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_thread_detach()")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_args_init(i32, ptr)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_frame_push(ptr, ptr, ptr)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_frame_pop(ptr)")
	fmt.sbprintln(&e.b, "declare void @llvm.memset.p0.i64(ptr, i8, i64, i1)")
	fmt.sbprintln(&e.b, "declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_write_std(ptr, ptr, i64)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_fmt_bytes(ptr, ptr, i64)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_fmt_i64(ptr, i64, ptr)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_fmt_u64(ptr, i64, ptr)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_fmt_i128(ptr, i64, i64, ptr)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_fmt_u128(ptr, i64, i64, ptr)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_fmt_f64(ptr, double)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_fmt_bool(ptr, i32)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_fmt_rune(ptr, i32)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_fmt_ptr(ptr, ptr)")
	emit_carrier_types(e)
	emit_text_declarations(e)
	emit_container_declarations(e)
	emit_atomic_declarations(e)
}

// design.md "string type": `string` is data, length, and owner flags;
// `string_view` is data and length.
STRING_TYPE :: "%loke.string"

STRING_VIEW_TYPE :: "%loke.string_view"

STRING_DATA :: 0

STRING_LEN :: 1

STRING_OWNER :: 2

VIEW_DATA :: 0

VIEW_LEN :: 1

#assert(SLICE_DATA == VIEW_DATA && SLICE_LEN == VIEW_LEN)

// `owner_flags` of a literal; zero is the empty value.
STRING_STATIC :: 1

// One zero-terminated constant per distinct literal, so it also initializes a
// `cstring_view`.
@(private)
text_literal_global :: proc(e: ^Emitter, text: string) -> string {
	if existing, found := e.literals[text]; found {
		return existing
	}
	name := fmt.aprintf("@.str.%d", len(e.literals))
	e.literals[text] = name
	append(&e.globals, fmt.aprintf(
		"%s = private unnamed_addr constant [%d x i8] c\"%s\\00\"\n",
		name, len(text) + 1, llvm_escape(text),
	))
	return name
}

// The global backing array of a file-scope slice literal. Never shared: a
// write through one `[]mut T` literal must not show up in another.
@(private)
slice_literal_constant :: proc(e: ^Emitter, value: Const_Value, info: ^Type_Info) -> string {
	count := len(value.aggregate.elements)
	if count == 0 {
		return "zeroinitializer"
	}
	element := llvm_type(e, info.element)
	b := strings.builder_make()
	fmt.sbprintf(&b, "[%d x %s] [", count, element)
	for slot, index in value.aggregate.elements {
		fmt.sbprintf(&b, "%s %s %s", index > 0 ? "," : "", element, llvm_const(e, slot, info.element))
	}
	strings.write_string(&b, " ]")
	name := fmt.aprintf("@.slice.%d", len(e.globals))
	append(&e.globals, fmt.aprintf(
		"%s = private %s %s\n",
		name, info.mutable ? "global" : "unnamed_addr constant", strings.to_string(b),
	))
	return slice_constant(name, count)
}

// `{ ptr name, i64 count }`, concatenated because `{` is a core:fmt directive.
@(private = "file")
slice_constant :: proc(name: string, count: int) -> string {
	return strings.concatenate({"{ ptr ", name, ", i64 ", fmt.aprintf("%d", count), " }"})
}

// A literal `string` or `string_view`: static owner flags, no allocation.
@(private)
text_constant :: proc(e: ^Emitter, value: Const_Value, owning: bool) -> string {
	if value.kind != .String || value.text == "" {
		return "zeroinitializer"
	}
	b := strings.builder_make()
	strings.write_string(&b, "{ ptr ")
	strings.write_string(&b, text_literal_global(e, value.text))
	fmt.sbprintf(&b, ", i64 %d", len(value.text))
	if owning {
		fmt.sbprintf(&b, ", i64 %d", STRING_STATIC)
	}
	strings.write_string(&b, " }")
	return strings.to_string(b)
}

// Carrier shapes every module needs, so the layout probe defines them too.
emit_carrier_types :: proc(e: ^Emitter) {
	fmt.sbprint(&e.b, STRING_TYPE)
	fmt.sbprintln(&e.b, " = type { ptr, i64, i64 }")
	fmt.sbprint(&e.b, STRING_VIEW_TYPE)
	fmt.sbprintln(&e.b, " = type { ptr, i64 }")
	fmt.sbprint(&e.b, CONTAINER_TYPE)
	fmt.sbprintln(&e.b, " = type { ptr, i64, i64, ptr }")
	fmt.sbprint(&e.b, CONTAINER_OPS_TYPE)
	fmt.sbprintln(&e.b, " = type { i64, i64, ptr, ptr, i64, i64, ptr, ptr, ptr, ptr }")
}

@(private = "file")
emit_text_declarations :: proc(e: ^Emitter) {
	fmt.sbprintln(&e.b, "declare i32 @loke_rt_v1_string_from_bytes(ptr, ptr, i64, ptr)")
	fmt.sbprintln(&e.b, "declare i32 @loke_rt_v1_string_concat(ptr, ptr, i64, ptr, i64, ptr)")
	fmt.sbprintln(&e.b, "declare i32 @loke_rt_v1_string_clone(ptr, ptr, i64, ptr)")
	fmt.sbprintln(&e.b, "declare i32 @loke_rt_v1_string_from_runes(ptr, ptr, i64, ptr)")
	fmt.sbprintln(&e.b, "declare i32 @loke_rt_v1_string_to_runes(ptr, ptr, ptr, i64, ptr)")
	fmt.sbprintln(&e.b, "declare ptr @loke_rt_v1_arena_open(ptr)")
	fmt.sbprintln(&e.b, "declare ptr @loke_rt_v1_arena_open_fixed(ptr, i64)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_arena_drop(ptr)")
	fmt.sbprintln(&e.b, "declare ptr @loke_rt_v1_arena_allocator(ptr)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_string_retain(i64)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_string_release(i64)")
	fmt.sbprintln(&e.b, "declare i32 @loke_rt_v1_utf8_valid(ptr, i64)")
	fmt.sbprintln(&e.b, "declare i64 @loke_rt_v1_rune_count(ptr, i64)")
	fmt.sbprintln(&e.b, "declare i64 @loke_rt_v1_rune_at(ptr, i64, i64, ptr)")
	fmt.sbprintln(&e.b, "declare i32 @loke_rt_v1_bytes_compare(ptr, i64, ptr, i64)")
	fmt.sbprintln(&e.b, "declare i64 @loke_rt_v1_cstring_len(ptr)")
}

// ---------------------------------------------------------------- globals --

// `static` and `thread_local` locals, in design.md's teardown order.
@(private)
emit_static_locals :: proc(e: ^Emitter) {
	for symbol_id, index in e.c.static_locals {
		sym := symbol_of(e.c, symbol_id)
		if sym == nil || sym.kind != .Var {
			continue
		}
		name := fmt.aprintf("@loke.s.%d.%s", index, llvm_safe(identifier_text(e.c, sym.name)))
		e.names[symbol_id] = name
		value := "zeroinitializer"
		if zero, ok := zero_const(e.c, sym.type); ok {
			value = llvm_const(e, zero, sym.type)
		}
		if sym.decl != nil {
			for initialiser, position in sym.decl.values {
				if position < len(sym.decl.symbols) && sym.decl.symbols[position] == symbol_id &&
				   initialiser != nil && is_const_expr(initialiser) {
					value = llvm_const(e, const_value_of(initialiser), sym.type)
				}
			}
		}
		qualifier := sym.duration == .Thread_Local ? "thread_local " : ""
		fmt.sbprintfln(&e.b, "%s = %sglobal %s %s", name, qualifier, llvm_type(e, sym.type), value)
	}
	if len(e.c.static_locals) > 0 {
		fmt.sbprintln(&e.b, "")
	}
}

// Called by the runtime from `thread_detach` to drop the detaching thread's
// thread-local values.
@(private)
emit_thread_local_teardown :: proc(e: ^Emitter) {
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	fmt.sbprintln(&e.b, "define void @loke_rt_v1_program_tls_cleanup() {")
	fmt.sbprintln(&e.b, "entry:")
	for index := len(e.c.static_locals) - 1; index >= 0; index -= 1 {
		symbol_id := e.c.static_locals[index]
		sym := symbol_of(e.c, symbol_id)
		if sym == nil || sym.duration != .Thread_Local {
			continue
		}
		if !emit_lifecycle(e, sym.type).managed {
			continue
		}
		emit_drop_place(e, sym.type, symbol_name(e, symbol_id))
	}
	fmt.sbprintln(&e.b, "  ret void")
	fmt.sbprintln(&e.b, "}")
	fmt.sbprintln(&e.b, "")
}

emit_global :: proc(e: ^Emitter, d: ^Decl) {
	for symbol_id, i in d.symbols {
		sym := symbol_of(e.c, symbol_id)
		if sym == nil || sym.kind != .Var {
			continue
		}
		name := symbol_name(e, symbol_id)
		value := ""
		if i < len(d.values) && d.values[i] != nil && is_const_expr(d.values[i]) {
			value = llvm_const(e, const_value_of(d.values[i]), sym.type)
		} else {
			zero, ok := zero_const(e.c, sym.type)
			if !ok {
				backend_fail(e, "a global type was not gated by the checker")
				continue
			}
			value = llvm_const(e, zero, sym.type)
		}
		fmt.sbprintfln(&e.b, "%s = global %s %s", name, llvm_type(e, sym.type), value)
	}
	fmt.sbprintln(&e.b, "")
}

// ------------------------------------------------------ runtime failures --

// One message constant per distinct text.
@(private = "file")
message_global :: proc(e: ^Emitter, text: string) -> string {
	if existing, found := e.messages[text]; found {
		return existing
	}
	name := fmt.aprintf("@.msg.%d", len(e.messages))
	e.messages[text] = name
	append(&e.globals, fmt.aprintf(
		"%s = private unnamed_addr constant [%d x i8] c\"%s\\00\"\n",
		name, len(text) + 1, llvm_escape(text),
	))
	return name
}

@(private)
llvm_escape :: proc(text: string) -> string {
	b := strings.builder_make()
	for index in 0 ..< len(text) {
		ch := text[index]
		if ch < 0x20 || ch >= 0x7f || ch == '"' || ch == '\\' {
			fmt.sbprintf(&b, "\\%02X", ch)
			continue
		}
		strings.write_byte(&b, ch)
	}
	return strings.to_string(b)
}

// The constant message a `panic`/`assert` was written with.
@(private)
panic_message_text :: proc(e: ^Emitter, v: ^Expr_Call, index: int, fallback: string) -> string {
	if index < len(v.bound) && v.bound[index] != nil {
		if base := expr_base(v.bound[index]); base != nil && base.is_const && base.const_value.kind == .String {
			return base.const_value.text
		}
	}
	return fallback
}

// design.md "Panics and unwinding": under `unwind` the runtime replays each
// frame's cleanup first; under `abort` it terminates here.
@(private)
emit_panic :: proc(e: ^Emitter, message: string) {
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_panic(ptr %s)", message_global(e, message))
	fmt.sbprintln(&e.b, "  unreachable")
	e.terminated = true
}

// A synthesized body copying a move-only value is dead (L0491), so it aborts
// instead of failing the build. Anywhere else it is a compiler bug.
@(private)
emit_dead_move_only_copy :: proc(e: ^Emitter, type: Type_Id) -> bool {
	if !e.synth_bodies || !emit_lifecycle(e, type).clone_disabled {
		return false
	}
	fmt.sbprintfln(
		&e.b, "  call void @loke_rt_v1_abort(ptr %s)", message_global(e, "a move-only value was copied"),
	)
	return true
}

// Panics when `cond` holds, and continues in a fresh block otherwise.
@(private)
panic_if :: proc(e: ^Emitter, cond: string, prefix: string, message: string) {
	fail := new_label(e, prefix)
	ok := new_label(e, "ok")
	branch_if(e, cond, fail, ok)
	place_label(e, fail)
	emit_panic(e, message)
	place_label(e, ok)
}

@(private = "file")
fmt_thunk_name :: proc(e: ^Emitter, type: Type_Id) -> string {
	return fmt.aprintf("@loke.f.%d", typeid_value(e.c, type))
}

// One generated formatter per requested printable type, then the table that
// dispatches an erased value to it.
@(private)
emit_format_thunks :: proc(e: ^Emitter) {
	if !e.c.format_requested {
		return
	}
	count := len(e.c.typeid_order)
	entries := make([]string, count + 1)
	for &entry in entries {
		entry = "null"
	}
	for type in e.c.typeid_order {
		id := typeid_value(e.c, type)
		if id == 0 || int(id) > count || !type_is_printable(e.c, type) {
			continue
		}
		emit_one_format_thunk(e, type)
		entries[id] = fmt_thunk_name(e, type)
	}

	// Private `typeid` names, so printing needs no `base:runtime` import.
	names := make([]string, count + 1)
	for type in e.c.typeid_order {
		id := typeid_value(e.c, type)
		if id != 0 && int(id) <= count {
			names[id] = type_name(e.c, type)
		}
	}

	b := strings.builder_make()
	fmt.sbprintf(&b, "%s = private unnamed_addr constant [%d x ptr] [", FMT_THUNKS, count + 1)
	for entry, index in entries {
		if index > 0 {
			strings.write_string(&b, ",")
		}
		fmt.sbprintf(&b, " ptr %s", entry)
	}
	strings.write_string(&b, " ]\n")
	fmt.sbprintf(&b, "%s = private unnamed_addr constant i64 %d\n", FMT_THUNK_COUNT, count)
	fmt.sbprintf(&b, "%s = private unnamed_addr constant [%d x %s] [", TYPE_NAMES, count + 1, STRING_VIEW_TYPE)
	for name, index in names {
		if index > 0 {
			strings.write_string(&b, ",")
		}
		if name == "" {
			fmt.sbprintf(&b, " %s zeroinitializer", STRING_VIEW_TYPE)
			continue
		}
		strings.write_string(&b, strings.concatenate({
			" ", STRING_VIEW_TYPE, " { ptr ", text_literal_global(e, name),
			", i64 ", fmt.aprintf("%d", len(name)), " }",
		}))
	}
	strings.write_string(&b, " ]\n")
	append(&e.globals, strings.to_string(b))
}

// Aggregates print as `[elements]`, `Name{field = value}`, and enum members
// by name.
@(private = "file")
emit_one_format_thunk :: proc(e: ^Emitter, type: Type_Id) {
	frame := begin_function_emission(e)
	defer finish_pending_thunk(e, frame)

	open_function(e, "define private void %s(ptr %%data, ptr %%w, ptr %%o)", fmt_thunk_name(e, type))
	emit_format_body(e, type, "%data")
	fmt.sbprintln(&e.b, "  ret void")
	fmt.sbprintln(&e.b, "}")
	fmt.sbprintln(&e.b, "")
}

@(private = "file")
emit_format_literal :: proc(e: ^Emitter, text: string) {
	global := text_literal_global(e, text)
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_fmt_bytes(ptr %%w, ptr %s, i64 %d)", global, len(text))
}

// A compile-time-only type has no runtime value to print.
@(private = "file")
type_is_printable :: proc(c: ^Compiler, type: Type_Id) -> bool {
	return type != INVALID_TYPE && type_is_supported(c, type) && !type_is_compile_time_only(c, type)
}

@(private = "file")
emit_format_call :: proc(e: ^Emitter, type: Type_Id, address: string) {
	if !type_is_printable(e.c, type) || typeid_value(e.c, type) == 0 {
		emit_format_literal(e, "<unformattable>")
		return
	}
	fmt.sbprintfln(&e.b, "  call void %s(ptr %s, ptr %%w, ptr %%o)", fmt_thunk_name(e, type), address)
}

@(private = "file")
emit_format_body :: proc(e: ^Emitter, type: Type_Id, address: string) {
	// A `format` declared in the type's own package is its formatter.
	if hook := e.c.formatters[type]; hook != INVALID_SYMBOL {
		receiver_type, receiver := "ptr", address
		if hook_sym := symbol_of(e.c, hook);
		   hook_sym == nil || !param_mode_is_pointer(symbol_param_mode(e.c, hook_sym, 0)) {
			receiver_type = llvm_type(e, type)
			receiver = load(e, receiver_type, address)
		}
		writer := load(e, llvm_type(e, e.c.runtime_types["Writer"]), "%w")
		options := load(e, llvm_type(e, e.c.runtime_types["Options"]), "%o")
		fmt.sbprintfln(
			&e.b, "  call void %s(%s %s, %s %s, %s %s)",
			symbol_name(e, hook),
			receiver_type, receiver,
			llvm_type(e, e.c.runtime_types["Writer"]), writer,
			llvm_type(e, e.c.runtime_types["Options"]), options,
		)
		return
	}
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
		llvm := llvm_type(e, under)
		value := load(e, llvm, address)
		signed := type_signed(e.c, under)
		if type_bits(e.c, under) > 64 {
			low, shifted, high := temp(e), temp(e), temp(e)
			fmt.sbprintfln(&e.b, "  %s = trunc %s %s to i64", low, llvm, value)
			fmt.sbprintfln(&e.b, "  %s = lshr %s %s, 64", shifted, llvm, value)
			fmt.sbprintfln(&e.b, "  %s = trunc %s %s to i64", high, llvm, shifted)
			callee := signed ? "loke_rt_v1_fmt_i128" : "loke_rt_v1_fmt_u128"
			fmt.sbprintfln(&e.b, "  call void @%s(ptr %%w, i64 %s, i64 %s, ptr %%o)", callee, low, high)
			return
		}
		widened := widen_to_i64(e, value, under)
		if signed {
			fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_fmt_i64(ptr %%w, i64 %s, ptr %%o)", widened)
		} else {
			fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_fmt_u64(ptr %%w, i64 %s, ptr %%o)", widened)
		}

	case .Typeid:
		value := load(e, "i64", address)
		emit_format_type_name(e, value)

	case .Rune:
		value := load(e, "i32", address)
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_fmt_rune(ptr %%w, i32 %s)", value)

	case .Float:
		llvm := llvm_type(e, under)
		value := load(e, llvm, address)
		widened := value
		if llvm != "double" {
			widened = temp(e)
			fmt.sbprintfln(&e.b, "  %s = fpext %s %s to double", widened, llvm, value)
		}
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_fmt_f64(ptr %%w, double %s)", widened)

	case .Pointer, .C_Pointer, .Raw_Pointer, .Proc, .Allocator:
		value := load(e, "ptr", address)
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_fmt_ptr(ptr %%w, ptr %s)", value)

	case .String, .String_View:
		data, length := load_pair(e, llvm_type(e, under), address, STRING_DATA, STRING_LEN)
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_fmt_bytes(ptr %%w, ptr %s, i64 %s)", data, length)

	case .CString_View:
		value := load(e, "ptr", address)
		length := temp(e)
		fmt.sbprintfln(&e.b, "  %s = call i64 @loke_rt_v1_cstring_len(ptr %s)", length, value)
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_fmt_bytes(ptr %%w, ptr %s, i64 %s)", value, length)

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

	case .Struct:
		emit_format_struct(e, type, under, address)

	case .Any_View:
		data, id := load_pair(e, llvm_type(e, under), address, ANY_VIEW_DATA, ANY_VIEW_ID)
		emit_format_dispatch_at(e, data, id, "%w", "%o")

	case .Union:
		emit_format_union(e, under, address)

	case:
		// A `dyn` view and anything else without a fixed spelling prints its type name.
		emit_format_literal(e, type_name(e.c, type))
	}
}

// `.name` or `.name(payload)` for the active variant, chained like enums.
@(private = "file")
emit_format_union :: proc(e: ^Emitter, under: Type_Id, address: string) {
	info := type_of(e.c, under)
	shape := union_layout(e.c, under)
	tag_llvm := fmt.aprintf("i%d", shape.tag_bytes * 8)
	value := load(e, llvm_type(e, under), address)
	tag := emit_union_tag(e, under, value)
	slot := emit_union_spill(e, under, value)
	done := new_label(e, "fmt.union.done")
	for variant, index in info.variants {
		matched := temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp eq %s %s, %d", matched, tag_llvm, tag, index)
		hit, next := new_label(e, "fmt.union.hit"), new_label(e, "fmt.union.next")
		branch_if(e, matched, hit, next)
		place_label(e, hit)
		emit_format_literal(e, fmt.aprintf(".%s", identifier_text(e.c, info.variant_names[index])))
		if variant != TYPE_VOID {
			emit_format_literal(e, "(")
			payload := gep_field(e, llvm_type(e, under), slot, 0)
			emit_format_body(e, variant, payload)
			emit_format_literal(e, ")")
		}
		branch(e, done)
		place_label(e, next)
	}
	branch(e, done)
	place_label(e, done)
}

// A `typeid` prints its type's name, or its number when it has none.
@(private = "file")
emit_format_type_name :: proc(e: ^Emitter, id: string) {
	safe, _ := typeid_index(e, id, FMT_THUNK_COUNT)
	view := gep_at(e, STRING_VIEW_TYPE, TYPE_NAMES, safe)
	data := load(e, "ptr", view)
	stride := gep_field(e, STRING_VIEW_TYPE, view, STRING_LEN)
	length := load(e, "i64", stride)
	missing := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq i64 %s, 0", missing, length)
	numeric, named, done := new_label(e, "fmt.typeid.number"), new_label(e, "fmt.typeid.named"), new_label(e, "fmt.typeid.done")
	branch_if(e, missing, numeric, named)

	place_label(e, named)
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_fmt_bytes(ptr %%w, ptr %s, i64 %s)", data, length)
	branch(e, done)

	place_label(e, numeric)
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_fmt_u64(ptr %%w, i64 %s, ptr %%o)", id)
	branch(e, done)
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
	widened := widen_to_i64(e, value, under)
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_fmt_i64(ptr %%w, i64 %s, ptr %%o)", widened)
	branch(e, done)
	place_label(e, done)
}

@(private = "file")
emit_format_sequence :: proc(e: ^Emitter, element: Type_Id, base, count: string) {
	emit_format_literal(e, "[")
	cursor := alloca(e, "i64")
	fmt.sbprintfln(&e.b, "  store i64 0, ptr %s", cursor)
	head, body, done := new_label(e, "fmt.seq.head"), new_label(e, "fmt.seq.body"), new_label(e, "fmt.seq.done")
	place_label(e, head)
	index := load(e, "i64", cursor)
	more := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp slt i64 %s, %s", more, index, count)
	branch_if(e, more, body, done)
	place_label(e, body)
	first := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq i64 %s, 0", first, index)
	separator, formatted := new_label(e, "fmt.seq.sep"), new_label(e, "fmt.seq.item")
	branch_if(e, first, formatted, separator)
	place_label(e, separator)
	emit_format_literal(e, ", ")
	branch(e, formatted)
	place_label(e, formatted)
	slot := gep_at(e, llvm_type(e, element), base, index)
	emit_format_call(e, element, slot)
	advanced := temp(e)
	fmt.sbprintfln(&e.b, "  %s = add i64 %s, 1", advanced, index)
	fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", advanced, cursor)
	branch(e, head)
	place_label(e, done)
	emit_format_literal(e, "]")
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
	next := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = call i64 @loke_rt_v1_map_scan(ptr %s, ptr %s, i64 %s, ptr %s, ptr %s)",
		next, table, ops, current, key_out, value_out,
	)
	fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", next, cursor)
	more := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp ne i64 %s, 0", more, next)
	branch_if(e, more, body, done)

	place_label(e, body)
	first := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq i64 %s, 0", first, current)
	separator, entry := new_label(e, "fmt.map.sep"), new_label(e, "fmt.map.entry")
	branch_if(e, first, entry, separator)
	place_label(e, separator)
	emit_format_literal(e, ", ")
	branch(e, entry)
	place_label(e, entry)
	key_slot := load(e, "ptr", key_out)
	emit_format_call(e, info.key, key_slot)
	emit_format_literal(e, " = ")
	emit_format_call(e, info.element, load(e, "ptr", value_out))
	branch(e, head)

	place_label(e, done)
	emit_format_literal(e, "]")
}

@(private = "file")
emit_format_struct :: proc(e: ^Emitter, type, under: Type_Id, address: string) {
	info := type_of(e.c, under)
	emit_format_literal(e, type_name(e.c, type))
	emit_format_literal(e, "{")
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
		emit_format_literal(e, identifier_text(e.c, sym.name))
		emit_format_literal(e, " = ")
		slot := gep_field(e, llvm_type(e, under), address, index)
		// Only the live prefix of an `@(initialized)` array holds values.
		if counter := symbol_of(e.c, sym.initialized_by); counter != nil {
			count := load(
				e, llvm_type(e, counter.type),
				gep_field(e, llvm_type(e, under), address, int(counter.index)),
			)
			element := underlying_info(e.c, sym.type).element
			emit_format_sequence(e, element, slot, count)
			continue
		}
		emit_format_call(e, sym.type, slot)
	}
	emit_format_literal(e, "}")
}

// The four compiler-owned `core:fmt` entry points.
@(private)
emit_fmt_builtin :: proc(e: ^Emitter, v: ^Expr_Call, kind: Builtin_Kind) -> string {
	writer_type := llvm_type(e, e.c.runtime_types["Writer"])
	#partial switch kind {
	case .Fmt_Stdout_Writer, .Fmt_Stderr_Writer:
		stream := kind == .Fmt_Stdout_Writer ? 0 : 1
		first, out := temp(e), temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = insertvalue %s undef, ptr @loke_rt_v1_write_std, 0",
			first, writer_type,
		)
		fmt.sbprintfln(&e.b, "  %s = insertvalue %s %s, ptr inttoptr (i64 %d to ptr), 1", out, writer_type, first, stream)
		return out

	case .Fmt_Write_Bytes:
		writer := spill_value(e, e.c.runtime_types["Writer"], emit_expr(e, v.bound[0]))
		data, length := emit_text_parts(e, v.bound[1])
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_fmt_bytes(ptr %s, ptr %s, i64 %s)", writer, data, length)
		return "0"

	case .Fmt_Format_Any:
		view := emit_expr(e, v.bound[0])
		storage := llvm_type(e, TYPE_ANY_VIEW)
		data := extract(e, storage, view, ANY_VIEW_DATA)
		id := extract(e, storage, view, ANY_VIEW_ID)
		writer := spill_value(e, e.c.runtime_types["Writer"], emit_expr(e, v.bound[1]))
		options := spill_value(e, e.c.runtime_types["Options"], emit_expr(e, v.bound[2]))
		saved_w, saved_o := e.fmt_writer, e.fmt_options
		e.fmt_writer, e.fmt_options = writer, options
		emit_format_dispatch_at(e, data, id, writer, options)
		e.fmt_writer, e.fmt_options = saved_w, saved_o
		return "0"
	}
	return "0"
}

// Dispatches an erased value to its thunk, printing `<nil>` for no thunk.
@(private = "file")
emit_format_dispatch_at :: proc(e: ^Emitter, data, id, writer, options: string) {
	safe, _ := typeid_index(e, id, FMT_THUNK_COUNT)
	thunk := load(e, "ptr", gep_at(e, "ptr", FMT_THUNKS, safe))
	missing := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq ptr %s, null", missing, thunk)
	none, call, done := new_label(e, "fmt.none"), new_label(e, "fmt.call"), new_label(e, "fmt.done")
	branch_if(e, missing, none, call)
	place_label(e, none)
	nil_text := text_literal_global(e, "<nil>")
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_fmt_bytes(ptr %s, ptr %s, i64 5)", writer, nil_text)
	branch(e, done)
	place_label(e, call)
	fmt.sbprintfln(&e.b, "  call void %s(ptr %s, ptr %s, ptr %s)", thunk, data, writer, options)
	branch(e, done)
	place_label(e, done)
}

@(private = "file")
load_pair :: proc(e: ^Emitter, storage, address: string, first, second: int) -> (string, string) {
	value := load(e, storage, address)
	return extract(e, storage, value, first), extract(e, storage, value, second)
}

@(private = "file")
spill_value :: proc(e: ^Emitter, type: Type_Id, value: string) -> string {
	slot := alloca(e, llvm_type(e, type))
	store(e, type, value, slot)
	return slot
}

// ==================================================== runtime metadata ==

// design.md "`type` and `typeid`": one entry per requested `typeid`, indexed
// by id, with an empty entry 0.
TYPE_INFO_TABLE :: "@.loke.type_info"

TYPE_INFO_COUNT :: "@.loke.type_info.count"

@(private)
emit_type_info_tables :: proc(e: ^Emitter) {
	if !e.c.type_info_requested {
		return
	}
	record, has_record := e.c.runtime_types["Type_Info"]
	member, has_member := e.c.runtime_types["Member_Info"]
	if !has_record || !has_member {
		backend_fail(e, "`type_info_of` was checked without the `base:runtime` layouts")
		return
	}
	count := len(e.c.typeid_order)
	entries := make([]string, count + 1)
	entries[0] = "zeroinitializer"
	for type in e.c.typeid_order {
		id := typeid_value(e.c, type)
		if id == 0 || int(id) > count {
			continue
		}
		entries[id] = type_info_entry(e, record, member, type)
	}
	for index in 0 ..< len(entries) {
		if entries[index] == "" {
			entries[index] = "zeroinitializer"
		}
	}

	b := strings.builder_make()
	fmt.sbprintf(&b, "%s = private unnamed_addr constant [%d x %s] [", TYPE_INFO_TABLE, count + 1, struct_name(e, record))
	for entry, index in entries {
		if index > 0 {
			strings.write_string(&b, ",")
		}
		fmt.sbprintf(&b, " %s %s", struct_name(e, record), entry)
	}
	strings.write_string(&b, " ]\n")
	fmt.sbprintf(&b, "%s = private unnamed_addr constant i64 %d\n", TYPE_INFO_COUNT, count)
	append(&e.globals, strings.to_string(b))
}

@(private = "file")
type_info_entry :: proc(e: ^Emitter, record, member, type: Type_Id) -> string {
	shape := underlying_info(e.c, type)
	members := type_info_members(e, member, type)

	values := make(map[string]string)
	defer delete(values)
	values["id"] = fmt.aprintf("%d", typeid_value(e.c, type))
	values["kind"] = fmt.aprintf("%d", public_type_kind(e.c, type))
	values["name"] = text_constant(e, Const_Value{kind = .String, text = type_name(e.c, type)}, false)
	values["size"] = fmt.aprintf("%d", type_size(e.c, type))
	values["align"] = fmt.aprintf("%d", type_align(e.c, type))
	values["bits"] = fmt.aprintf("%d", shape == nil ? 0 : shape.bits)
	values["signed"] = shape != nil && shape.signed ? "true" : "false"
	values["element"] = fmt.aprintf("%d", typeid_value(e.c, shape == nil ? INVALID_TYPE : shape.element))
	values["key"] = fmt.aprintf("%d", typeid_value(e.c, shape == nil ? INVALID_TYPE : shape.key))
	values["count"] = fmt.aprintf("%d", shape == nil ? 0 : shape.count)
	values["members"] = members
	return named_field_constant(e, record, values)
}

// The public `Type_Kind`, whose order is frozen by `base/runtime`.
@(private = "file")
public_type_kind :: proc(c: ^Compiler, type: Type_Id) -> int {
	PUBLIC_KINDS :: []string {
		"Invalid", "Void", "Bool", "Signed_Int", "Unsigned_Int", "Float", "Rune",
		"Raw_Pointer", "Pointer", "C_Pointer", "Array", "Slice", "Dynamic_Array", "Map",
		"Struct", "Enum", "Union", "Proc", "String", "String_View", "CString_View",
		"Typeid", "Any_View", "Dyn", "Distinct", "Simd", "Allocator", "Allocator_Error",
	}
	wanted := "Invalid"
	under := type_underlying(c, type)
	if type_kind(c, type) == .Distinct {
		wanted = "Distinct"
	} else {
		#partial switch type_kind(c, under) {
		case .Void:            wanted = "Void"
		case .Bool:            wanted = "Bool"
		case .Int:             wanted = type_signed(c, under) ? "Signed_Int" : "Unsigned_Int"
		case .Float:           wanted = "Float"
		case .Rune:            wanted = "Rune"
		case .Raw_Pointer:     wanted = "Raw_Pointer"
		case .Pointer:         wanted = "Pointer"
		case .C_Pointer:       wanted = "C_Pointer"
		case .Array:           wanted = "Array"
		case .Simd:            wanted = "Simd"
		case .Slice:           wanted = "Slice"
		case .Dynamic_Array:   wanted = "Dynamic_Array"
		case .Map:             wanted = "Map"
		case .Struct:          wanted = "Struct"
		case .Enum:            wanted = "Enum"
		case .Union:           wanted = "Union"
		case .Proc:            wanted = "Proc"
		case .String:          wanted = "String"
		case .String_View:     wanted = "String_View"
		case .CString_View:    wanted = "CString_View"
		case .Typeid:          wanted = "Typeid"
		case .Any_View:        wanted = "Any_View"
		case .Dyn:             wanted = "Dyn"
		case .Allocator:       wanted = "Allocator"
		case .Allocator_Error: wanted = "Allocator_Error"
		}
	}
	for name, index in PUBLIC_KINDS {
		if name == wanted {
			return index
		}
	}
	return 0
}

// The `[]Member_Info` of a struct, enum, union, or procedure.
@(private = "file")
type_info_members :: proc(e: ^Emitter, member, type: Type_Id) -> string {
	shape := underlying_info(e.c, type)
	if shape == nil {
		return "zeroinitializer"
	}
	entries := make([dynamic]string)
	#partial switch shape.kind {
	case .Struct:
		for field, index in shape.fields {
			sym := symbol_of(e.c, field)
			if sym == nil || !sym.public {
				continue // design.md: member tables expose public fields only
			}
			values := make(map[string]string)
			defer delete(values)
			values["kind"] = "0" // Field
			values["name"] = text_constant(e, Const_Value{kind = .String, text = identifier_text(e.c, sym.name)}, false)
			values["type"] = fmt.aprintf("%d", typeid_value(e.c, sym.type))
			values["offset"] = fmt.aprintf("%d", type_field_offset(e.c, type, index))
			append(&entries, named_field_constant(e, member, values))
		}
	case .Enum:
		for field in shape.fields {
			sym := symbol_of(e.c, field)
			if sym == nil {
				continue
			}
			low, high := enum_raw_words(e.c, sym.const_value)
			values := make(map[string]string)
			defer delete(values)
			values["kind"] = "1" // Enum_Value
			values["name"] = text_constant(e, Const_Value{kind = .String, text = identifier_text(e.c, sym.name)}, false)
			values["type"] = fmt.aprintf("%d", typeid_value(e.c, type))
			values["value_low"] = low
			values["value_high"] = high
			append(&entries, named_field_constant(e, member, values))
		}
	case .Union:
		for variant, index in shape.variants {
			values := make(map[string]string)
			defer delete(values)
			// A payloadless variant reports `Unit`.
			payload := variant == TYPE_VOID ? e.c.unit_type : variant
			values["kind"] = "2" // Union_Variant
			values["name"] = text_constant(
				e, Const_Value{kind = .String, text = identifier_text(e.c, shape.variant_names[index])}, false,
			)
			values["type"] = fmt.aprintf("%d", typeid_value(e.c, payload))
			values["offset"] = fmt.aprintf("%d", index)
			append(&entries, named_field_constant(e, member, values))
		}
	case .Proc:
		for parameter in shape.parameters {
			values := make(map[string]string)
			defer delete(values)
			values["kind"] = "3" // Parameter
			values["type"] = fmt.aprintf("%d", typeid_value(e.c, parameter))
			append(&entries, named_field_constant(e, member, values))
		}
		if shape.result != INVALID_TYPE {
			values := make(map[string]string)
			defer delete(values)
			values["kind"] = "4" // Result
			values["type"] = fmt.aprintf("%d", typeid_value(e.c, shape.result))
			append(&entries, named_field_constant(e, member, values))
		}
	}
	if len(entries) == 0 {
		return "zeroinitializer"
	}
	name := fmt.aprintf("@.loke.members.%d", len(e.globals))
	b := strings.builder_make()
	fmt.sbprintf(&b, "%s = private unnamed_addr constant [%d x %s] [", name, len(entries), struct_name(e, member))
	for entry, index in entries {
		if index > 0 {
			strings.write_string(&b, ",")
		}
		fmt.sbprintf(&b, " %s %s", struct_name(e, member), entry)
	}
	strings.write_string(&b, " ]\n")
	append(&e.globals, strings.to_string(b))
	return slice_constant(name, len(entries))
}

// An enum value's low and high 64-bit words, unnarrowed.
@(private = "file")
enum_raw_words :: proc(c: ^Compiler, value: Const_Value) -> (low: string, high: string) {
	if value.kind != .Integer {
		return "0", "0"
	}
	mask := bi_sub(c, bi_pow2(c, 64), bi_from_i64(c, 1))
	low_bits := bi_and(c, value.integer, mask)
	high_bits := bi_and(c, bi_shr(c, value.integer, 64), mask)
	low_value, low_ok := bi_to_u64(c, low_bits)
	high_value, high_ok := bi_to_u64(c, high_bits)
	if !low_ok || !high_ok {
		return "0", "0" // both halves were masked to 64 bits; defensive only
	}
	return fmt.aprintf("%d", low_value), fmt.aprintf("%d", high_value)
}

// A record constant filled by field name, so the layout stays authoritative.
@(private = "file")
named_field_constant :: proc(e: ^Emitter, record: Type_Id, values: map[string]string) -> string {
	info := underlying_info(e.c, record)
	if info == nil {
		backend_fail(e, "a runtime metadata record has no fields")
		return "zeroinitializer"
	}
	b := strings.builder_make()
	strings.write_string(&b, "{")
	for field, index in info.fields {
		sym := symbol_of(e.c, field)
		if sym == nil {
			continue
		}
		if index > 0 {
			strings.write_string(&b, ",")
		}
		name := identifier_text(e.c, sym.name)
		value, supplied := values[name]
		if !supplied {
			zero, ok := zero_const(e.c, sym.type)
			value = ok ? llvm_const(e, zero, sym.type) : "zeroinitializer"
		}
		fmt.sbprintf(&b, " %s %s", llvm_type(e, sym.type), value)
	}
	strings.write_string(&b, " }")
	return strings.to_string(b)
}

// design.md: a nil, out-of-range, or forged id gives nil.
@(private)
emit_type_info_of :: proc(e: ^Emitter, v: ^Expr_Call) -> string {
	safe, bad := typeid_index(e, emit_expr(e, v.bound[0]), TYPE_INFO_COUNT)
	address := gep_at(e, struct_name(e, e.c.runtime_types["Type_Info"]), TYPE_INFO_TABLE, safe)
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, ptr null, ptr %s", out, bad, address)
	return out
}

// `id` clamped into a table of `count` entries: a nil or out-of-range id maps to
// the empty entry 0, and `bad` says so.
@(private = "file")
typeid_index :: proc(e: ^Emitter, id, count: string) -> (safe, bad: string) {
	limit := load(e, "i64", count)
	zero, past := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq i64 %s, 0", zero, id)
	fmt.sbprintfln(&e.b, "  %s = icmp ugt i64 %s, %s", past, id, limit)
	bad, safe = temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = or i1 %s, %s", bad, zero, past)
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, i64 0, i64 %s", safe, bad, id)
	return
}

// ------------------------------------------- compiler-contributed procedures --

// Compiler-provided members of built-in types, emitted once after all packages.
@(private)
emit_synth_procs :: proc(e: ^Emitter) {
	e.synth_bodies = true
	defer e.synth_bodies = false
	for symbol_id in e.c.synth_procs {
		symbol := symbol_of(e.c, symbol_id)
		if symbol == nil || symbol.synth == .None {
			continue
		}
		if len(symbol.params) > 0 && type_is_compile_time_only(e.c, symbol.params[0]) { continue }
		e.terminated = false
		name := symbol_name(e, symbol_id)
		switch symbol.synth {
		case .Adapter_View, .Adapter_Iter, .Indexed_Next, .Copied_Next, .Iterator_Copy:
			emit_synth_adapter(e, symbol, name)
		case .Standard_Len, .Standard_Cap, .Standard_Hash:
			emit_synth_standard_customization(e, symbol, name)
		case .Range_Iter, .Range_Iter_Reverse,
		     .Array_Iter, .Array_Iter_Reverse,
		     .Dynamic_Iter, .Dynamic_Iter_Reverse, .Map_Iter,
		     .Map_View_Iter, .Text_Iter:
			emit_synth_iter(e, symbol, name)
		case .Range_Next:
			emit_synth_range_next(e, symbol, name)
		case .Array_Next:
			emit_synth_indexed_next(e, symbol, name, slice = false)
		case .Slice_Next, .Slice_Mut_Next, .Slice_Ref_Next:
			emit_synth_indexed_next(e, symbol, name, slice = true)
		case .Map_Next, .Map_Keys_Next, .Map_Values_Next:
			emit_synth_map_next(e, symbol, name)
		case .Text_Next, .Rune_Offsets_Next:
			emit_synth_text_next(e, symbol, name)
		case .Try_Clone:
			emit_synth_try_clone(e, symbol, name)
		case .Clone:
			emit_synth_clone(e, symbol, name)
		case .Dyn_Forward:
			emit_dyn_forwarding_slot(e, symbol, name)
		case .Container_Op:
			emit_synth_container_op(e, symbol, name)
			if e.consuming_ops[symbol_id] {
				fmt.sbprintln(&e.b, "")
				emit_synth_container_op(e, symbol, consuming_op_name(e, symbol_id), consuming = true)
			}
		case .Provider_Op:
			emit_synth_provider_op(e, symbol, name)
		case .None:
		}
		fmt.sbprintln(&e.b, "")
	}
}

@(private = "file")
emit_synth_standard_customization :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	result := llvm_type(e, symbol.result)
	fmt.sbprintf(&e.b, "define %s%s %s(", llvm_linkage(name), result, name)
	for _, index in symbol.params {
		if index > 0 { fmt.sbprint(&e.b, ", ") }
		fmt.sbprintf(&e.b, "%s %%arg%d", synth_param_llvm(e, symbol, index), index)
	}
	open_function(e, ")")

	#partial switch symbol.synth {
	case .Standard_Len:
		info := underlying_info(e.c, symbol.params[0])
		if info.kind == .Array || info.kind == .Simd {
			fmt.sbprintfln(&e.b, "  ret %s %d", result, info.count)
		} else {
			field := info.kind == .Dynamic_Array || info.kind == .Map ? CONTAINER_LEN :
			         info.kind == .String || info.kind == .String_View ? STRING_LEN : SLICE_LEN
			length := extract(e, llvm_type(e, symbol.params[0]), synth_receiver_value(e, symbol), field)
			fmt.sbprintfln(&e.b, "  ret %s %s", result, length)
		}

	case .Standard_Cap:
		capacity := extract(e, llvm_type(e, symbol.params[0]), synth_receiver_value(e, symbol), CONTAINER_CAP)
		fmt.sbprintfln(&e.b, "  ret %s %s", result, capacity)

	case .Standard_Hash:
		mixed := emit_hash_value(e, symbol.params[0], synth_receiver_value(e, symbol), "%arg1")
		fmt.sbprintfln(&e.b, "  ret %s %s", result, mixed)

	case:
		backend_fail(e, "unknown standard customization member")
		fmt.sbprintfln(&e.b, "  ret %s zeroinitializer", result)
	}
	fmt.sbprintln(&e.b, "}")
}

// ============================================================ erased views ==

// `{ ptr data, typeid id }`, pairing the source's address with its `typeid`.
@(private)
emit_any_view_value :: proc(e: ^Emitter, address: string, concrete: Type_Id) -> string {
	storage := llvm_type(e, TYPE_ANY_VIEW)
	first := insert(e, storage, "undef", "ptr", address, ANY_VIEW_DATA)
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s %s, i64 %d, %d", out, storage, first, typeid_value(e.c, concrete), ANY_VIEW_ID)
	return out
}

// `.(T)` traps on a `typeid` mismatch; `.as(T)` yields `Option(T)`.
@(private)
emit_any_view_extract :: proc(e: ^Emitter, v: ^Expr_Checked_Extract, as_type: Type_Id) -> []string {
	single := make([]string, 1)
	single[0] = "zeroinitializer"
	view := emit_expr(e, v.operand)
	storage := llvm_type(e, TYPE_ANY_VIEW)
	data := extract(e, storage, view, ANY_VIEW_DATA)
	id := extract(e, storage, view, ANY_VIEW_ID)
	matched := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq i64 %s, %d", matched, id, typeid_value(e.c, v.payload))

	target := llvm_type(e, v.payload)
	if v.mode == .Trap {
		failed := temp(e)
		fmt.sbprintfln(&e.b, "  %s = xor i1 %s, true", failed, matched)
		panic_if(e, failed, "anyview.mismatch", "checked extraction failed")
		out := load(e, target, data)
		if emit_lifecycle(e, v.payload).managed {
			out = emit_clone_value(e, v.payload, out)
		}
		single[0] = out
		return single
	}

	option := as_type
	info := underlying_info(e.c, option)
	if info == nil || info.kind != .Union || !info.failure_designated ||
	   len(info.variants) != 2 || info.failure_variant < 0 || info.failure_variant >= 2 {
		backend_fail(e, "an optional extraction has no checked failure variant")
		return single
	}
	some := 1 - info.failure_variant
	if info.variants[some] != v.payload {
		backend_fail(e, "an optional extraction has the wrong success payload")
		return single
	}
	slot := alloca(e, llvm_type(e, option))
	fmt.sbprintfln(&e.b, "  store %s zeroinitializer, ptr %s", llvm_type(e, option), slot)
	then_label, done_label := new_label(e, "anyview.match"), new_label(e, "anyview.done")
	fmt.sbprintfln(&e.b, "  br i1 %s, label %%%s, label %%%s", matched, then_label, done_label)
	fmt.sbprintfln(&e.b, "%s:", then_label)
	loaded := load(e, target, data)
	if emit_lifecycle(e, v.payload).managed {
		loaded = emit_clone_value(e, v.payload, loaded)
	}
	wrapped := emit_union_value(e, option, some, loaded)
	fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", llvm_type(e, option), wrapped, slot)
	branch(e, done_label)
	place_label(e, done_label)
	single[0] = load(e, llvm_type(e, option), slot)
	return single
}

// `(dyn I)(&value)`: the data pointer plus the witness; nil gives the nil view.
@(private)
emit_dyn_value :: proc(e: ^Emitter, v: ^Expr_Call, as_type: Type_Id) -> string {
	storage := llvm_type(e, as_type)
	if v.operation.(Call_Dyn_Conversion).witness == nil {
		return "zeroinitializer"
	}
	data := emit_expr(e, v.bound[0])
	first := insert(e, storage, "undef", "ptr", data, DYN_DATA)
	out := insert(e, storage, first, "ptr", v.operation.(Call_Dyn_Conversion).witness.name, DYN_WITNESS)
	return out
}

// A slot call: load the thunk from the witness table, trapping first if the
// view is nil, and call it with the view's data pointer as the receiver.
@(private)
emit_dyn_slot_call :: proc(e: ^Emitter, v: ^Expr_Call) -> []string {
	view := emit_expr(e, v.bound[0])
	storage := llvm_type(e, expr_base(v.bound[0]).type)
	data := extract(e, storage, view, DYN_DATA)
	thunk := emit_witness_slot(e, extract(e, storage, view, DYN_WITNESS), v.operation.(Call_Dyn_Slot).index)
	signature := type_of(e.c, expr_base(v.callee).type)
	return emit_bound_call(e, INVALID_SYMBOL, thunk, signature, v.bound, v, receiver = data, receiver_type = "ptr")
}

@(private = "file")
emit_witness_slot :: proc(e: ^Emitter, witness: string, index: int) -> string {
	is_nil := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq ptr %s, null", is_nil, witness)
	panic_if(e, is_nil, "dyn.nil", "call through a nil dyn view")
	return load(e, "ptr", gep_at(e, "ptr", witness, fmt.aprintf("%d", index)))
}

// One private constant global per materialised constant.
@(private)
emit_materialized_constants :: proc(e: ^Emitter) {
	if len(e.c.materialized_order) == 0 {
		return
	}
	for entry in e.c.materialized_order {
		fmt.sbprintfln(
			&e.b,
			"%s = private constant %s %s",
			entry.name, llvm_type(e, entry.type), llvm_const(e, entry.value, entry.type),
		)
	}
	fmt.sbprintln(&e.b, "")
}

// One witness table per `(Interface, Concrete, arguments)`, holding a thunk per
// slot that re-types the erased receiver.
@(private)
emit_witnesses :: proc(e: ^Emitter) {
	for witness in e.c.witness_order {
		for slot, index in witness.slots {
			emit_witness_thunk(e, witness, slot, index)
		}
	}
	for witness in e.c.witness_order {
		fmt.sbprintf(&e.b, "%s = private unnamed_addr constant [%d x ptr] [", witness.name, len(witness.slots))
		for _, index in witness.slots {
			if index > 0 {
				fmt.sbprint(&e.b, ",")
			}
			fmt.sbprintf(&e.b, " ptr %s", witness_thunk_name(e, witness, index))
		}
		fmt.sbprintln(&e.b, " ]")
	}
	fmt.sbprintln(&e.b, "")
}

@(private = "file")
witness_thunk_name :: proc(e: ^Emitter, witness: ^Witness, index: int) -> string {
	return fmt.aprintf("%s.thunk.%d", witness.name, index)
}

@(private = "file")
emit_witness_thunk :: proc(e: ^Emitter, witness: ^Witness, slot: Witness_Slot, index: int) {
	target := symbol_of(e.c, slot.target)
	if target == nil {
		return
	}
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	e.terminated = false
	signature := type_of(e.c, target.proc_type)
	result_type := llvm_result_type(e, target.result, signature.result_inout)
	fmt.sbprintf(&e.b, "define private %s %s(ptr %%arg0", result_type, witness_thunk_name(e, witness, index))
	write_forwarded_params(e, target.params, signature.param_modes)
	open_function(e, ")")

	// The receiver arrives as a pointer; a target taking its receiver by value
	// gets it loaded.
	receiver_type, receiver := "ptr", "%arg0"
	if !param_mode_is_pointer(symbol_param_mode(e.c, target, 0)) {
		receiver_type = llvm_type(e, target.params[0])
		receiver = load(e, receiver_type, "%arg0")
	}
	emit_forwarding_call(e, target, signature, symbol_name(e, slot.target), receiver_type, receiver)
	fmt.sbprintln(&e.b, "")
}

// `dyn I` satisfies `I` through forwarding slots that take the view, trap on a
// nil witness, and call the slot's thunk with the view's data pointer.
@(private = "file")
emit_dyn_forwarding_slot :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	signature := type_of(e.c, symbol.proc_type)
	result_type := llvm_result_type(e, symbol.result, signature.result_inout)
	view_type := llvm_type(e, symbol.params[0])
	receiver_by_ptr := len(signature.param_modes) > 0 && param_mode_is_pointer(signature.param_modes[0])
	fmt.sbprintf(
		&e.b, "define %s%s %s(%s %%arg0", llvm_linkage(name), result_type, name, receiver_by_ptr ? "ptr" : view_type,
	)
	write_forwarded_params(e, symbol.params, signature.param_modes)
	open_function(e, ")")

	view := receiver_by_ptr ? load(e, view_type, "%arg0") : "%arg0"
	thunk := emit_witness_slot(e, extract(e, view_type, view, DYN_WITNESS), int(symbol.index))
	emit_forwarding_call(e, symbol, signature, thunk, "ptr", extract(e, view_type, view, DYN_DATA))
}

// `, T %argN` for every parameter after the receiver.
@(private = "file")
write_forwarded_params :: proc(e: ^Emitter, params: []Type_Id, modes: []Param_Mode) {
	for position in 1 ..< len(params) {
		type := param_mode_is_pointer(modes[position]) ? "ptr" : llvm_type(e, params[position])
		fmt.sbprintf(&e.b, ", %s %%arg%d", type, position)
	}
}

// Calls `callee` with the receiver and the forwarded parameters, returns its
// result, and closes the function.
@(private = "file")
emit_forwarding_call :: proc(
	e: ^Emitter, symbol: ^Symbol, signature: ^Type_Info, callee, receiver_type, receiver: string,
) {
	result_type := llvm_result_type(e, symbol.result, signature.result_inout)
	call := ""
	if symbol.result != INVALID_TYPE {
		call = temp(e)
		fmt.sbprintf(&e.b, "  %s = call %s %s(%s %s", call, result_type, callee, receiver_type, receiver)
	} else {
		fmt.sbprintf(&e.b, "  call void %s(%s %s", callee, receiver_type, receiver)
	}
	write_forwarded_params(e, symbol.params, signature.param_modes)
	fmt.sbprintln(&e.b, ")")
	if symbol.result == INVALID_TYPE {
		fmt.sbprintln(&e.b, "  ret void")
	} else {
		fmt.sbprintfln(&e.b, "  ret %s %s", result_type, call)
	}
	fmt.sbprintln(&e.b, "}")
}

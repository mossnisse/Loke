// Runtime declarations, globals, formatting, metadata, and erased witnesses.
//
// Part of the textual LLVM backend; see compiler-architecture.md.
package lokec

import "core:fmt"
import "core:strings"

@(private)
emit_preamble :: proc(e: ^Emitter) {
	fmt.sbprintfln(&e.b, `target triple = "%s"`, e.c.target.triple)
	fmt.sbprintln(&e.b, "")
	// Every defined runtime failure — division by zero, an index out of range, a
	// nil dereference or nil indirect call — reaches the seed runtime's panic or
	// abort entry rather than inheriting LLVM poison, a target-specific hardware
	// exception, or the `llvm.trap` that stood in for both before M6a.
	emit_runtime_declarations(e)
	fmt.sbprintln(&e.b, "")
}

// The seed runtime's allocator surface. An `Allocator` value is a pointer to
// a `loke_rt_allocator_v1` record and nothing else, so copying a handle
// preserves the provider's state, its canonical region identity, and its
// failure policy without any per-copy tag.
//
// The record's own fields are never loaded here: dispatch goes through the
// runtime helpers, which keeps the layout to one reader and lets the record grow
// behind its version/size prefix.
RT_DEFAULT_ALLOCATOR :: "@loke_rt_v1_default_allocator"

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
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_panic(ptr)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_abort(ptr)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_thread_attach()")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_thread_detach()")
	// design.md "Program entry and exit" (m7-plan step 5): the generated `wmain`
	// converts the argument vector once; `core:os` reads it through its own foreign
	// block, so only the initializer is declared here.
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
}

// design.md "string type" and "string type conversions". The two named types are
// the frozen carriers: an owning `string` is data, byte length, and owner flags;
// a borrowed `string_view` is data and byte length, with no allocator and no
// ownership.
STRING_TYPE :: "%loke.string"

STRING_VIEW_TYPE :: "%loke.string_view"

STRING_DATA :: 0

STRING_LEN :: 1

STRING_OWNER :: 2

VIEW_DATA :: 0

VIEW_LEN :: 1

// `owner_flags` of a literal. Zero is the empty value; anything else is the
// address of a runtime buffer's header.
STRING_STATIC :: 1

// One zero-terminated static constant per distinct literal. A string literal
// uses static storage (design.md), and its bytes are already zero-terminated,
// which is what lets the same global initialize a `cstring_view`.
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

// A literal `string` or `string_view` value. A literal costs no allocation and
// no handle accounting: its owner flags say "static", which is exactly what a
// retain and a release both ignore.
@(private)
text_constant :: proc(e: ^Emitter, value: Const_Value, owning: bool) -> string {
	if value.kind != .String || value.text == "" {
		// The empty value is all zero (design.md), and a nil view has length 0 and
		// points at no storage.
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

// The named carrier shapes every module needs, whether or not it emits a body:
// a struct with a `string` or a container field mentions them, so the layout
// probe has to define them exactly as the real module does.
//
// `{` is a directive to core:fmt, so the record shapes are written literally.
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

// A `static` local has one instance for the process's whole life, and a
// `thread_local` one has one per thread (design.md "Storage modifiers"), so
// neither lives in the frame. The checker recorded them in declaration order,
// which is also the order design.md gives thread-local teardown.
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

// The fixed callback the runtime invokes from `thread_detach`. It addresses
// LLVM thread-local globals, so the same function drops the values belonging to
// whichever initial, runtime-created, or foreign-attached thread is detaching.
@(private)
emit_thread_local_teardown :: proc(e: ^Emitter) {
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	fmt.sbprintln(&e.b, "define void @loke_rt_v1_program_tls_cleanup() {")
	fmt.sbprintln(&e.b, "entry:")
	for index := len(e.c.static_locals) - 1; index >= 0; index -= 1 {
		symbol_id := e.c.static_locals[index]
		sym := symbol_of(e.c, symbol_id)
		if sym == nil || sym.duration != .Thread_Local || sym.manual {
			continue // the runtime does not drop a manual TLS owner
		}
		if !emit_lifecycle(e, sym.type).managed {
			continue
		}
		emit_drop_place(e, sym.type, e.names[symbol_id])
	}
	fmt.sbprintln(&e.b, "  ret void")
	fmt.sbprintln(&e.b, "}")
	fmt.sbprintln(&e.b, "")
}

// File-scope variables need constant initialisers (design.md "Values that
// outlive every scope"), so folding has already produced the value.
emit_global :: proc(e: ^Emitter, pkg: ^Package, d: ^Decl) {
	for symbol_id, i in d.symbols {
		sym := symbol_of(e.c, symbol_id)
		if sym == nil || sym.kind != .Var {
			continue
		}
		// design.md "@(export)": an exported global emits under its written or
		// `@(link_name)` symbol, not the mangled one (m7-plan step 5).
		name := sym.exported \
			? fmt.aprintf("@%s", sym.link_name) \
			: llvm_global_name(pkg, identifier_text(e.c, sym.name))
		e.names[symbol_id] = name
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

// One zero-terminated message constant per distinct text, so the same failure
// reported from twenty places is one global.
@(private = "file")
message_global :: proc(e: ^Emitter, text: string) -> string {
	if existing, found := e.messages[text]; found {
		return existing
	}
	name := fmt.aprintf("@.msg.%d", len(e.messages))
	e.messages[text] = name
	// Module scope, appended at the end: a message is first needed while a
	// function body is being written, and a global cannot be defined inside one.
	append(&e.globals, fmt.aprintf(
		"%s = private unnamed_addr constant [%d x i8] c\"%s\\00\"\n",
		name, len(text) + 1, llvm_escape(text),
	))
	return name
}

// Only printable ASCII reaches here — every message is a compiler-owned literal
// — so the one thing that must be escaped is the quote LLVM's own syntax uses.
@(private = "file")
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

// The compile-time string a `panic`/`assert` was written with. design.md makes
// it a constant, so the runtime message is a module global rather than anything
// the program has to build.
@(private)
panic_message_text :: proc(e: ^Emitter, v: ^Expr_Call, index: int, fallback: string) -> string {
	if index < len(v.bound) && v.bound[index] != nil {
		if base := expr_base(v.bound[index]); base != nil && base.is_const && base.const_value.kind == .String {
			return base.const_value.text
		}
	}
	return fallback
}

// design.md "Panics and unwinding" enumerates exactly which runtime faults are
// panics. They take the program's panic strategy: under `unwind` the runtime
// replays each active frame's registered cleanup first, and under `abort` no
// frames were ever registered, so the same call terminates at the fault.
@(private)
emit_panic :: proc(e: ^Emitter, message: string) {
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_panic(ptr %s)", message_global(e, message))
	fmt.sbprintln(&e.b, "  unreachable")
	e.terminated = true
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
	entries[0] = "null"
	for index in 1 ..< len(entries) {
		entries[index] = "null"
	}
	for type in e.c.typeid_order {
		id := typeid_value(e.c, type)
		if id == 0 || int(id) > count || !type_is_printable(e.c, type) {
			continue
		}
		emit_one_format_thunk(e, type)
		entries[id] = fmt_thunk_name(e, type)
	}

	// The names a `typeid` prints as. This is the same text `runtime.Type_Info`
	// carries, but it is a private table so that printing does not oblige a
	// program to import `base:runtime` for a public record it never names.
	names := make([]string, count + 1)
	for index in 0 ..< len(names) {
		names[index] = ""
	}
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
	// Built with the same `{ptr, len}` shape a `string_view` has, so the formatter
	// reads it with the loads it already emits for one.
	fmt.sbprintf(&b, "%s = private unnamed_addr constant [%d x %s] [", TYPE_NAMES, count + 1, STRING_VIEW_TYPE)
	for name, index in names {
		if index > 0 {
			strings.write_string(&b, ",")
		}
		if name == "" {
			fmt.sbprintf(&b, " %s zeroinitializer", STRING_VIEW_TYPE)
			continue
		}
		// `{` is a core:fmt format directive, so this row is concatenated.
		strings.write_string(&b, strings.concatenate({
			" ", STRING_VIEW_TYPE, " { ptr ", text_literal_global(e, name),
			", i64 ", fmt.aprintf("%d", len(name)), " }",
		}))
	}
	strings.write_string(&b, " ]\n")
	append(&e.globals, strings.to_string(b))
}

// design.md gives no spelling for an aggregate, so these are the ones the
// library's own examples imply: elements between brackets, fields named inside
// braces, and an enum by the member's own name.
@(private = "file")
emit_one_format_thunk :: proc(e: ^Emitter, type: Type_Id) {
	saved_body, saved_terminated := e.b, e.terminated
	e.b = strings.builder_make()
	e.terminated = false

	fmt.sbprintf(&e.b, "define private void %s(ptr %%data, ptr %%w, ptr %%o)", fmt_thunk_name(e, type))
	fmt.sbprintln(&e.b, " {")
	fmt.sbprintln(&e.b, "entry:")
	emit_format_body(e, type, "%data")
	fmt.sbprintln(&e.b, "  ret void")
	fmt.sbprintln(&e.b, "}")
	fmt.sbprintln(&e.b, "")

	text := hoist_fixed_allocas(strings.to_string(e.b))
	e.b, e.terminated = saved_body, saved_terminated
	append(&e.pending_thunks, text)
}

// A literal separator: `[`, `, `, ` = ` and friends all go through the same
// static storage the string literals already use.
@(private = "file")
emit_format_literal :: proc(e: ^Emitter, text: string) {
	global := text_literal_global(e, text)
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_fmt_bytes(ptr %%w, ptr %s, i64 %d)", global, len(text))
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
	// design.md's coherence rule: a `format` declared in the value type's own
	// package *is* the formatter for that type, so the thunk is a call to it.
	if hook := e.c.formatters[type]; hook != INVALID_SYMBOL {
		value := load(e, llvm_type(e, type), address)
		writer := load(e, llvm_type(e, e.c.runtime_types["Writer"]), "%w")
		options := load(e, llvm_type(e, e.c.runtime_types["Options"]), "%o")
		fmt.sbprintfln(
			&e.b, "  call void %s(%s %s, %s %s, %s %s)",
			e.names[hook],
			llvm_type(e, type), value,
			llvm_type(e, e.c.runtime_types["Writer"]), writer,
			llvm_type(e, e.c.runtime_types["Options"]), options,
		)
		return
	}
	// A `distinct` type prints as the shape it wraps: it has a fresh identity,
	// not a fresh representation.
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

	case .Pointer, .Multi_Pointer, .Raw_Pointer, .Proc, .Allocator:
		value := load(e, "ptr", address)
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_fmt_ptr(ptr %%w, ptr %s)", value)

	case .String, .String_View:
		value, data, length := temp(e), temp(e), temp(e)
		storage := llvm_type(e, under)
		fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", value, storage, address)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", data, storage, value, STRING_DATA)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", length, storage, value, STRING_LEN)
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_fmt_bytes(ptr %%w, ptr %s, i64 %s)", data, length)

	case .CString_View:
		value := load(e, "ptr", address)
		length := temp(e)
		fmt.sbprintfln(&e.b, "  %s = call i64 @loke_rt_v1_cstring_len(ptr %s)", length, value)
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_fmt_bytes(ptr %%w, ptr %s, i64 %s)", value, length)

	case .Enum:
		emit_format_enum(e, under, address)

	case .Array:
		emit_format_sequence(e, info.element, address, fmt.aprintf("%d", info.count), inline_array = true)

	case .Slice:
		value, data, length := temp(e), temp(e), temp(e)
		storage := llvm_type(e, under)
		fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", value, storage, address)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", data, storage, value, SLICE_DATA)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", length, storage, value, SLICE_LEN)
		emit_format_sequence(e, info.element, data, length, inline_array = false)

	case .Dynamic_Array:
		// The current allocation up to the length word, which is the same thing a
		// slice of it prints. Nesting is free: the element's own thunk runs.
		value, data, length := temp(e), temp(e), temp(e)
		storage := llvm_type(e, under)
		fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", value, storage, address)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", data, storage, value, CONTAINER_STORAGE)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", length, storage, value, CONTAINER_LEN)
		emit_format_sequence(e, info.element, data, length, inline_array = false)

	case .Map:
		emit_format_map(e, under, address)

	case .Struct:
		emit_format_struct(e, type, under, address)

	case .Any_View:
		// design.md: the erased view is a pointer plus a `typeid`, which is exactly
		// what the dispatch needs — so a nested `any_view` formats its subject.
		value, data, id := temp(e), temp(e), temp(e)
		storage := llvm_type(e, under)
		fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", value, storage, address)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", data, storage, value, ANY_VIEW_DATA)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", id, storage, value, ANY_VIEW_ID)
		emit_format_dispatch(e, data, id)

	case .Union:
		emit_format_union(e, under, address)

	case:
		// A `dyn` view, and anything else whose spelling design.md does not fix,
		// prints as its type name, which is still coherent.
		emit_format_literal(e, type_name(e.c, type))
	}
}

// A union prints as `.name` for a payloadless variant and `.name(payload)` for
// a payload one — the variant identity a type switch would see, not the payload
// type's own spelling, because two variants may share a payload type. The chain
// is over variants for the same reason the enum one is: the tag is not an index
// into anything the formatter can address.
//
// Only the active variant's payload is ever loaded or formatted.
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
	// A union always holds a variant, so this is unreachable; emitting nothing
	// keeps the block well-formed.
	branch(e, done)
	place_label(e, done)
}

// `type_info_of` accepts a runtime `typeid` and returns runtime metadata
// (design.md), and that metadata carries the type's name — so a `typeid` prints as
// the name of what it identifies. An id with no entry, including the nil one and
// a forged one, has no name to print and falls back to its numeric identity.
@(private = "file")
emit_format_type_name :: proc(e: ^Emitter, id: string) {
	limit := load(e, "i64", FMT_THUNK_COUNT)
	zero, past, bad := temp(e), temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq i64 %s, 0", zero, id)
	fmt.sbprintfln(&e.b, "  %s = icmp ugt i64 %s, %s", past, id, limit)
	fmt.sbprintfln(&e.b, "  %s = or i1 %s, %s", bad, zero, past)
	safe := temp(e)
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, i64 0, i64 %s", safe, bad, id)
	view := gep_at(e, STRING_VIEW_TYPE, TYPE_NAMES, safe)
	data := load(e, "ptr", view)
	stride := gep_field(e, STRING_VIEW_TYPE, view, STRING_LEN)
	length := load(e, "i64", stride)
	// An id with no name — the nil one, a forged one, or a type this program
	// never requested — has nothing to spell, so it prints its numeric identity.
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

// An enum's members are named constants that need not be contiguous
// (design.md), so the spelling is a chain of comparisons rather than an index.
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
	// A value no member names is still a value: print the number rather than
	// nothing.
	widened := widen_to_i64(e, value, under)
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_fmt_i64(ptr %%w, i64 %s, ptr %%o)", widened)
	branch(e, done)
	place_label(e, done)
}

@(private = "file")
emit_format_sequence :: proc(e: ^Emitter, element: Type_Id, base, count: string, inline_array: bool) {
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

// Map iteration order is unspecified (design.md "Maps"). A printed map is
// therefore `[key = value, ...]` in whatever order the slot walk finds, which is
// the same walk `foreach` performs. Both halves go through their own thunks, so
// a map of maps prints.
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
	value_slot := temp(e)
	emit_format_call(e, info.key, key_slot)
	emit_format_literal(e, " = ")
	fmt.sbprintfln(&e.b, "  %s = load ptr, ptr %s", value_slot, value_out)
	emit_format_call(e, info.element, value_slot)
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
		emit_format_call(e, sym.type, slot)
	}
	emit_format_literal(e, "}")
}

// The erased dispatch itself: look the concrete formatter up by `typeid`, which
// is the only thing an `any_view` carries. A nil or forged id has no formatter,
// so it prints as nil rather than reading past the table.
@(private = "file")
emit_format_dispatch :: proc(e: ^Emitter, data, id: string) {
	limit := load(e, "i64", FMT_THUNK_COUNT)
	zero, past, bad := temp(e), temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq i64 %s, 0", zero, id)
	fmt.sbprintfln(&e.b, "  %s = icmp ugt i64 %s, %s", past, id, limit)
	fmt.sbprintfln(&e.b, "  %s = or i1 %s, %s", bad, zero, past)
	safe := temp(e)
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, i64 0, i64 %s", safe, bad, id)
	slot, thunk := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = getelementptr inbounds ptr, ptr %s, i64 %s", slot, FMT_THUNKS, safe)
	fmt.sbprintfln(&e.b, "  %s = load ptr, ptr %s", thunk, slot)
	missing := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq ptr %s, null", missing, thunk)
	none, call, done := new_label(e, "fmt.none"), new_label(e, "fmt.call"), new_label(e, "fmt.done")
	branch_if(e, missing, none, call)
	place_label(e, none)
	emit_format_literal(e, "<nil>")
	branch(e, done)
	place_label(e, call)
	fmt.sbprintfln(&e.b, "  call void %s(ptr %s, ptr %%w, ptr %%o)", thunk, data)
	branch(e, done)
	place_label(e, done)
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
		// The thunks name `%w` and `%o`, so the two records are spilled to storage
		// the call can address.
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

// The dispatch, written at a call site rather than inside a thunk, so the two
// records are named operands instead of the thunk's own parameters.
@(private = "file")
emit_format_dispatch_at :: proc(e: ^Emitter, data, id, writer, options: string) {
	limit := load(e, "i64", FMT_THUNK_COUNT)
	zero, past, bad := temp(e), temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq i64 %s, 0", zero, id)
	fmt.sbprintfln(&e.b, "  %s = icmp ugt i64 %s, %s", past, id, limit)
	fmt.sbprintfln(&e.b, "  %s = or i1 %s, %s", bad, zero, past)
	safe := temp(e)
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, i64 0, i64 %s", safe, bad, id)
	slot, thunk := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = getelementptr inbounds ptr, ptr %s, i64 %s", slot, FMT_THUNKS, safe)
	fmt.sbprintfln(&e.b, "  %s = load ptr, ptr %s", thunk, slot)
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
spill_value :: proc(e: ^Emitter, type: Type_Id, value: string) -> string {
	slot := alloca(e, llvm_type(e, type))
	store(e, type, value, slot)
	return slot
}

// ==================================================== runtime metadata ==

// design.md "`type` and `typeid`": one dense entry per requested runtime type,
// keyed by the frozen `typeid`, plus a zero entry at index 0 so the nil id
// resolves to nothing. `base:runtime` owns the layouts; this fills them.
//
// The table is emitted only for a program that asked for it, and every entry is
// a type the compilation already requested a `typeid` for -- which
// `close_type_info_requests` has extended to everything the public metadata
// names, so a member type is always resolvable too.
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
	// Frozen ids are 1..N and dense, so the table is indexed directly.
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

// The public `Type_Kind` a compiler kind maps to. The order is frozen by
// `base/runtime`'s declaration; adding a member there requires a runtime ABI
// version bump. The untyped kinds never reach here: a `typeid` is only ever
// requested for a concrete runtime type.
@(private = "file")
public_type_kind :: proc(c: ^Compiler, type: Type_Id) -> int {
	PUBLIC_KINDS :: []string {
		"Invalid", "Void", "Bool", "Signed_Int", "Unsigned_Int", "Float", "Rune",
		"Raw_Pointer", "Pointer", "Multi_Pointer", "Array", "Slice", "Dynamic_Array", "Map",
		"Struct", "Enum", "Union", "Proc", "String", "String_View", "CString_View",
		"Typeid", "Any_View", "Dyn", "Distinct", "Simd", "Allocator", "Allocator_Error",
	}
	wanted := "Invalid"
	// A `distinct` type is its own public kind: it has a fresh identity, and the
	// shape it wraps stays reachable through `element`.
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
		case .Multi_Pointer:   wanted = "Multi_Pointer"
		case .Array:           wanted = "Array"
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

// The `[]Member_Info` of one aggregate: a struct's public fields, an enum's
// members, a union's variants, or a procedure's parameters and results, in
// declaration order.
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
			// The variant's *name* is its identity; a payloadless one reports
			// `Unit` so every entry names a real type.
			payload := variant == TYPE_VOID ? unit_type(e.c) : variant
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
		for result in shape.results {
			values := make(map[string]string)
			defer delete(values)
			values["kind"] = "4" // Result
			values["type"] = fmt.aprintf("%d", typeid_value(e.c, result))
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
	// `{` is a directive to core:fmt, so the slice constant is built rather than
	// formatted.
	slice := strings.builder_make()
	strings.write_string(&slice, "{ ptr ")
	strings.write_string(&slice, name)
	fmt.sbprintf(&slice, ", i64 %d ", len(entries))
	strings.write_string(&slice, "}")
	return strings.to_string(slice)
}

// Enum values use the two raw words without narrowing signed or unsigned
// 128-bit values (design.md).
//
// ponytail: the low word carries the value and the high word its sign
// extension. Every enum backing this compiler accepts fits in 64 bits today; a
// 128-bit backing needs the real split here and nowhere else.
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

// One aggregate constant, filled by *name* against the record's declared
// fields. design.md's layouts are the ABI authority, so matching by name means a
// reordered or renamed field produces a differently ordered constant rather than
// a silently wrong table.
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

// design.md: `type_info_of(0)` and an out-of-range or forged id return nil. The
// builtin lowers to a checked table address, not a runtime call.
@(private)
emit_type_info_of :: proc(e: ^Emitter, v: ^Expr_Call) -> string {
	id := emit_expr(e, v.bound[0])
	limit := load(e, "i64", TYPE_INFO_COUNT)
	zero, past := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq i64 %s, 0", zero, id)
	fmt.sbprintfln(&e.b, "  %s = icmp ugt i64 %s, %s", past, id, limit)
	bad := temp(e)
	fmt.sbprintfln(&e.b, "  %s = or i1 %s, %s", bad, zero, past)
	record := e.c.runtime_types["Type_Info"]
	address := gep_at(e, struct_name(e, record), TYPE_INFO_TABLE, id)
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, ptr null, ptr %s", out, bad, address)
	return out
}

// ------------------------------------------------------------------- text --

// A `{ptr, i64}` view value, built field by field. A slice and a `string_view`
// are the same shape, so one builder serves both; `storage` is the LLVM type
// text and `length` an already-spelled operand.
#assert(SLICE_DATA == VIEW_DATA && SLICE_LEN == VIEW_LEN)

// ------------------------------------------- compiler-contributed procedures --

// design.md: built-ins satisfy the same static interface a user type does, so
// their `iter` and `next` are real procedures rather than a checker fiction.
// Emitted once for the whole compilation, after every package's items.
@(private)
emit_synth_procs :: proc(e: ^Emitter) {
	for symbol_id in e.c.synth_procs {
		symbol := symbol_of(e.c, symbol_id)
		if symbol == nil || symbol.synth == .None {
			continue
		}
		e.terminated = false
		name := e.names[symbol_id]
		switch symbol.synth {
		case .Standard_Len, .Standard_Cap, .Standard_Hash:
			emit_synth_standard_customization(e, symbol, name)
		case .Range_Iter, .Range_Iter_Reverse,
		     .Array_Iter, .Array_Iter_Reverse,
		     .Dynamic_Iter, .Dynamic_Iter_Reverse, .Map_Iter:
			emit_synth_iter(e, symbol, name)
		case .Range_Next:
			emit_synth_range_next(e, symbol, name)
		case .Array_Next:
			emit_synth_array_next(e, symbol, name)
		case .Slice_Next:
			emit_synth_slice_next(e, symbol, name)
		case .Map_Next:
			emit_synth_map_next(e, symbol, name)
		case .Try_Clone:
			emit_synth_try_clone(e, symbol, name)
		case .Clone:
			emit_synth_clone(e, symbol, name)
		case .Dyn_Forward:
			emit_dyn_forwarding_slot(e, symbol, name)
		case .Container_Op:
			emit_synth_container_op(e, symbol, name)
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
	result := llvm_type(e, symbol.results[0])
	fmt.sbprintf(&e.b, "define %s %s(", result, name)
	for parameter, index in symbol.params {
		if index > 0 { fmt.sbprint(&e.b, ", ") }
		fmt.sbprintf(&e.b, "%s %%arg%d", llvm_type(e, parameter), index)
	}
	fmt.sbprintln(&e.b, ") {")
	fmt.sbprintln(&e.b, "entry:")

	#partial switch symbol.synth {
	case .Standard_Len:
		info := underlying_info(e.c, symbol.params[0])
		if info.kind == .Array {
			fmt.sbprintfln(&e.b, "  ret %s %d", result, info.count)
		} else {
			field := info.kind == .Dynamic_Array || info.kind == .Map ? CONTAINER_LEN :
			         info.kind == .String || info.kind == .String_View ? STRING_LEN : SLICE_LEN
			length := extract(e, llvm_type(e, symbol.params[0]), "%arg0", field)
			fmt.sbprintfln(&e.b, "  ret %s %s", result, length)
		}

	case .Standard_Cap:
		capacity := extract(e, llvm_type(e, symbol.params[0]), "%arg0", CONTAINER_CAP)
		fmt.sbprintfln(&e.b, "  ret %s %s", result, capacity)

	case .Standard_Hash:
		mixed := emit_hash_value(e, symbol.params[0], "%arg0", "%arg1")
		fmt.sbprintfln(&e.b, "  ret %s %s", result, mixed)

	case:
		backend_fail(e, "unknown standard customization member")
		fmt.sbprintfln(&e.b, "  ret %s zeroinitializer", result)
	}
	fmt.sbprintln(&e.b, "}")
}

// ============================================================ erased views ==

// `{ ptr data, typeid id }`. The conversion never allocates: it pairs the
// source's address with its frozen `typeid`.
@(private)
emit_any_view_value :: proc(e: ^Emitter, address: string, concrete: Type_Id) -> string {
	storage := llvm_type(e, TYPE_ANY_VIEW)
	first := temp(e)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s undef, ptr %s, %d", first, storage, address, ANY_VIEW_DATA)
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s %s, i64 %d, %d", out, storage, first, typeid_value(e.c, concrete), ANY_VIEW_ID)
	return out
}

// A checked extraction from an `any_view`: compare the stored `typeid`, then
// read the data pointer as the requested type. `.(T)` traps on a mismatch;
// `.as(T)` yields a zeroed payload and `false`.
@(private)
emit_any_view_extract :: proc(e: ^Emitter, v: ^Expr_Checked_Extract) -> []string {
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
		if type_is_managed(e.c, v.payload) {
			out = emit_clone_value(e, v.payload, out)
		}
		single := make([]string, 1)
		single[0] = out
		return single
	}

	// design.md "Typed fallibility": `.as(T)` produces `Option(T)`, so the miss
	// is `.none` rather than a zeroed payload paired with `false`. Nothing is
	// read through the data pointer unless the `typeid` matched.
	option := v.type
	slot := alloca(e, llvm_type(e, option))
	fmt.sbprintfln(&e.b, "  store %s zeroinitializer, ptr %s", llvm_type(e, option), slot)
	then_label, done_label := new_label(e, "anyview.match"), new_label(e, "anyview.done")
	fmt.sbprintfln(&e.b, "  br i1 %s, label %%%s, label %%%s", matched, then_label, done_label)
	fmt.sbprintfln(&e.b, "%s:", then_label)
	loaded := load(e, target, data)
	if type_is_managed(e.c, v.payload) {
		loaded = emit_clone_value(e, v.payload, loaded)
	}
	some := union_variant_index(e.c, option, intern_identifier(e.c, "some"))
	wrapped := emit_union_value(e, option, some, loaded)
	fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", llvm_type(e, option), wrapped, slot)
	branch(e, done_label)
	place_label(e, done_label)
	single := make([]string, 1)
	single[0] = load(e, llvm_type(e, option), slot)
	return single
}

// `(dyn I)(&value)`: the data pointer plus the coherent witness for the erased
// type. A nil concrete pointer produces the nil view and retains no witness.
@(private)
emit_dyn_value :: proc(e: ^Emitter, v: ^Expr_Call) -> string {
	storage := llvm_type(e, v.type)
	if v.dyn_witness == nil {
		return "zeroinitializer"
	}
	data := emit_expr(e, v.bound[0])
	first := temp(e)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s undef, ptr %s, %d", first, storage, data, DYN_DATA)
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = insertvalue %s %s, ptr %s, %d", out, storage, first, v.dyn_witness.name, DYN_WITNESS)
	return out
}

// A slot call: load the thunk from the witness table and call it indirectly,
// trapping first if the view is nil.
@(private)
emit_dyn_slot_call :: proc(e: ^Emitter, v: ^Expr_Call) -> []string {
	view := emit_expr(e, v.bound[0])
	storage := llvm_type(e, expr_base(v.bound[0]).type)
	data := extract(e, storage, view, DYN_DATA)
	witness := extract(e, storage, view, DYN_WITNESS)

	// design.md: calling a slot on nil panics.
	is_nil := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq ptr %s, null", is_nil, witness)
	panic_if(e, is_nil, "dyn.nil", "call through a nil dyn view")

	entry, thunk := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = getelementptr inbounds ptr, ptr %s, i64 %d", entry, witness, v.dyn_slot)
	fmt.sbprintfln(&e.b, "  %s = load ptr, ptr %s", thunk, entry)

	signature := type_of(e.c, expr_base(v.callee).type)
	result_type := llvm_result_type(e, signature.results, nil)
	operands := make([dynamic]string, 0, len(v.bound), context.temp_allocator)
	append(&operands, data)
	for index in 1 ..< len(v.bound) {
		if signature.param_modes[index] == .Inout {
			append(&operands, emit_address(e, v.bound[index]))
		} else {
			append(&operands, emit_expr(e, v.bound[index]))
		}
	}

	call := ""
	if len(signature.results) > 0 {
		call = temp(e)
		fmt.sbprintf(&e.b, "  %s = call %s %s(", call, result_type, thunk)
	} else {
		fmt.sbprintf(&e.b, "  call void %s(", thunk)
	}
	for operand, index in operands {
		if index > 0 {
			fmt.sbprint(&e.b, ", ")
		}
		type := index == 0 || signature.param_modes[index] == .Inout ? "ptr" : llvm_type(e, signature.parameters[index])
		fmt.sbprintf(&e.b, "%s %s", type, operand)
	}
	fmt.sbprintln(&e.b, ")")

	switch len(signature.results) {
	case 0:
		return nil
	case 1:
		single := make([]string, 1)
		single[0] = call
		return single
	}
	out := make([]string, len(signature.results))
	for index in 0 ..< len(signature.results) {
		out[index] = temp(e)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", out[index], result_type, call, index)
	}
	return out
}

// One private immutable global per materialised constant, in registration order
// (design.md "Materialization"). A constant used only at constant indices never
// registered one and so occupies no space in the program.
@(private)
emit_materialized_constants :: proc(e: ^Emitter) {
	if len(e.c.materialized_order) == 0 {
		return
	}
	for entry in e.c.materialized_order {
		fmt.sbprintfln(
			&e.b,
			"%s = private unnamed_addr constant %s %s",
			entry.name, llvm_type(e, entry.type), llvm_const(e, entry.value, entry.type),
		)
	}
	fmt.sbprintln(&e.b, "")
}

// One private immutable global per `(Interface, Concrete, arguments)`, holding a
// compiler-generated thunk per slot. A thunk takes the erased receiver pointer
// and re-types it for the concrete implementation.
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
	name := witness_thunk_name(e, witness, index)
	signature := type_of(e.c, target.proc_type)
	result_type := llvm_result_type(e, target.results, nil)

	fmt.sbprintf(&e.b, "define private %s %s(ptr %%arg0", result_type, name)
	for position in 1 ..< len(target.params) {
		mode := signature.param_modes[position]
		type := mode == .Inout ? "ptr" : llvm_type(e, target.params[position])
		fmt.sbprintf(&e.b, ", %s %%arg%d", type, position)
	}
	fmt.sbprint(&e.b, ")")
	fmt.sbprintln(&e.b, " {")
	fmt.sbprintln(&e.b, "entry:")

	// The receiver arrives erased. An immutable `self` is a value parameter, so
	// it is loaded; an `inout self` is already the alias the callee wants.
	receiver := "%arg0"
	if slot.mode != .Inout {
		loaded := load(e, llvm_type(e, target.params[0]), "%arg0")
		receiver = loaded
	}

	call := ""
	if len(target.results) > 0 {
		call = temp(e)
		fmt.sbprintf(&e.b, "  %s = call %s %s(", call, result_type, e.names[slot.target])
	} else {
		fmt.sbprintf(&e.b, "  call void %s(", e.names[slot.target])
	}
	receiver_type := slot.mode == .Inout ? "ptr" : llvm_type(e, target.params[0])
	fmt.sbprintf(&e.b, "%s %s", receiver_type, receiver)
	for position in 1 ..< len(target.params) {
		mode := signature.param_modes[position]
		type := mode == .Inout ? "ptr" : llvm_type(e, target.params[position])
		fmt.sbprintf(&e.b, ", %s %%arg%d", type, position)
	}
	fmt.sbprintln(&e.b, ")")

	if len(target.results) == 0 {
		fmt.sbprintln(&e.b, "  ret void")
	} else {
		fmt.sbprintfln(&e.b, "  ret %s %s", result_type, call)
	}
	fmt.sbprintln(&e.b, "}")
	fmt.sbprintln(&e.b, "")
}

// design.md: `dyn I` satisfies `I` through compiler-provided forwarding slots.
// The forwarder takes the view by value, traps on a nil witness, and calls the
// slot's thunk with the view's own data pointer.
@(private = "file")
emit_dyn_forwarding_slot :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	signature := type_of(e.c, symbol.proc_type)
	result_type := llvm_result_type(e, symbol.results, nil)
	view_type := llvm_type(e, symbol.params[0])

	receiver_inout := len(signature.param_modes) > 0 && signature.param_modes[0] == .Inout
	receiver_type := receiver_inout ? "ptr" : view_type
	fmt.sbprintf(&e.b, "define %s %s(%s %%arg0", result_type, name, receiver_type)
	for position in 1 ..< len(symbol.params) {
		mode := signature.param_modes[position]
		type := mode == .Inout ? "ptr" : llvm_type(e, symbol.params[position])
		fmt.sbprintf(&e.b, ", %s %%arg%d", type, position)
	}
	fmt.sbprint(&e.b, ")")
	fmt.sbprintln(&e.b, " {")
	fmt.sbprintln(&e.b, "entry:")

	view := "%arg0"
	if receiver_inout {
		view = temp(e)
		fmt.sbprintfln(&e.b, "  %s = load %s, ptr %%arg0", view, view_type)
	}
	data := extract(e, view_type, view, DYN_DATA)
	witness := extract(e, view_type, view, DYN_WITNESS)
	is_nil := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq ptr %s, null", is_nil, witness)
	panic_if(e, is_nil, "dyn.nil", "call through a nil dyn view")

	entry, thunk := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = getelementptr inbounds ptr, ptr %s, i64 %d", entry, witness, symbol.index)
	fmt.sbprintfln(&e.b, "  %s = load ptr, ptr %s", thunk, entry)

	call := ""
	if len(symbol.results) > 0 {
		call = temp(e)
		fmt.sbprintf(&e.b, "  %s = call %s %s(ptr %s", call, result_type, thunk, data)
	} else {
		fmt.sbprintf(&e.b, "  call void %s(ptr %s", thunk, data)
	}
	for position in 1 ..< len(symbol.params) {
		mode := signature.param_modes[position]
		type := mode == .Inout ? "ptr" : llvm_type(e, symbol.params[position])
		fmt.sbprintf(&e.b, ", %s %%arg%d", type, position)
	}
	fmt.sbprintln(&e.b, ")")

	if len(symbol.results) == 0 {
		fmt.sbprintln(&e.b, "  ret void")
	} else {
		fmt.sbprintfln(&e.b, "  ret %s %s", result_type, call)
	}
	fmt.sbprintln(&e.b, "}")
}

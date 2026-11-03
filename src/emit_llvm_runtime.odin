// Runtime declarations, static-storage globals, runtime failures, reflection
// metadata, and the dispatch of compiler-contributed procedures.
package lokec

import "core:fmt"
import "core:slice"
import "core:strings"

@(private)
emit_preamble :: proc(e: ^Emitter) {
	fmt.sbprintfln(&e.b, `target triple = "%s"`, e.c.target.triple)
	fmt.sbprintln(&e.b, "")
	emit_runtime_declarations(e)
	fmt.sbprintln(&e.b, "")
}

// An `Allocator` is a pointer to a `loke_rt_allocator_v1` record, dispatched
// only through the runtime helpers. This is the published build-selected one,
// or the runtime's fallback.
emit_default_allocator :: proc(e: ^Emitter) -> string {
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = call ptr @loke_rt_v1_selected_allocator()", out)
	return out
}

// The runtime entries that end the program, as `LOKE_RT_FAILURE` in
// runtime/loke_rt.h declares them.
@(private = "file")
FAILURE_ATTRIBUTES :: "cold noreturn"

@(private = "file")
emit_runtime_declarations :: proc(e: ^Emitter) {
	fmt.sbprintln(&e.b, "declare ptr @loke_rt_v1_alloc(ptr, i64, i64)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_free(ptr, ptr, i64, i64)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_reset(ptr)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_alloc_failed(ptr) " + FAILURE_ATTRIBUTES)
	fmt.sbprintln(&e.b, "declare i64 @loke_rt_v1_take_refusal()")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_restore_refusal(ptr, i64)")
	fmt.sbprintln(&e.b, "declare ptr @loke_rt_v1_selected_allocator()")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_publish_allocator(ptr)")
	fmt.sbprintln(&e.b, "declare i32 @loke_rt_v1_provider_init_begin()")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_provider_init_end()")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_panic(ptr) " + FAILURE_ATTRIBUTES)
	// It returns, to let the report's arguments be formatted, but only on the
	// way to `panic_end`.
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_panic_begin(ptr) cold")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_panic_end() " + FAILURE_ATTRIBUTES)
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_enable_panic_trace()")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_abort(ptr) " + FAILURE_ATTRIBUTES)
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_thread_attach()")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_thread_detach()")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_flush_stdout()")
	fmt.sbprintln(&e.b, "declare i32 @loke_rt_v1_cpu_dispatch(i32)")
	// Only where the entry or an object's constructor calls it, so a baseline
	// program's own binding is its only declaration; above baseline,
	// `emit_foreign_declarations` skips that binding.
	if e.c.target.cpu != .X86_64 {
		fmt.sbprintln(&e.b, "declare void @loke_rt_v1_require_cpu(i32)")
	}
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_args_init(i32, ptr)")
	fmt.sbprintln(&e.b, "declare i64 @loke_rt_v1_test_select(ptr, i64)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_frame_push(ptr, ptr, ptr)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_frame_pop(ptr)")
	fmt.sbprintln(&e.b, "declare void @llvm.memset.p0.i64(ptr, i8, i64, i1)")
	fmt.sbprintln(&e.b, "declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)")
	fmt.sbprintln(&e.b, "declare ptr @llvm.stacksave.p0()")
	fmt.sbprintln(&e.b, "declare void @llvm.stackrestore.p0(ptr)")
	// A foreign entry's guard and `-debug`'s check after a foreign call
	// (design.md "Floating-point operators").
	fmt.sbprintln(&e.b, "declare void @llvm.x86.sse.stmxcsr(ptr)")
	fmt.sbprintln(&e.b, "declare void @llvm.x86.sse.ldmxcsr(ptr)")
	for bits in ([]int{8, 16, 32, 64, 128}) {
		for operation in ([]string{"sadd", "ssub", "smul", "uadd", "usub", "umul"}) {
			fmt.sbprintfln(&e.b, "declare {{ i%d, i1 }} @llvm.%s.with.overflow.i%d(i%d, i%d)", bits, operation, bits, bits, bits)
		}
	}
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_fmt_bytes(ptr, ptr, i64)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_fmt_i64(ptr, i64, ptr)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_fmt_u64(ptr, i64, ptr)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_fmt_i128(ptr, i64, i64, ptr)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_fmt_u128(ptr, i64, i64, ptr)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_fmt_f64(ptr, double)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_fmt_f32(ptr, float)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_fmt_f16(ptr, float)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_fmt_bool(ptr, i32)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_fmt_rune(ptr, i32)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_fmt_quoted(ptr, ptr, i64)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_fmt_quoted_rune(ptr, i32)")
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
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_arena_set_failure(ptr, i64)")
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

// `static` and `thread_local` locals.
@(private)
emit_static_locals :: proc(e: ^Emitter) {
	for symbol_id, index in e.c.static_locals {
		sym := symbol_of(e.c, symbol_id)
		if sym == nil || sym.kind != .Var || omitted_with_test(e.c, symbol_id) {
			continue
		}
		name := claim_name(e, fmt.aprintf("@loke.s.%d.%s", index, llvm_safe(identifier_text(e.c, sym.name))))
		e.names[symbol_id] = name
		position, _ := slice.linear_search(sym.decl.symbols, symbol_id)
		emit_var_global(e, name, sym, sym.decl, position)
	}
	if len(e.c.static_locals) > 0 {
		fmt.sbprintln(&e.b, "")
	}
}

// Called by the runtime from `thread_detach` to drop the detaching thread's
// thread-local values. A host thread detaches in its own environment, so the
// drops run behind a guard (design.md "Floating-point operators").
@(private)
emit_thread_local_teardown :: proc(e: ^Emitter) {
	body := entry_body_name(e, "@loke_rt_v1_program_tls_cleanup")
	emit_thread_local_drops(e, body)
	emit_entry_guard(e, "@loke_rt_v1_program_tls_cleanup", "void", nil, body)
}

@(private = "file")
emit_thread_local_drops :: proc(e: ^Emitter, name: string) {
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	open_function(e, "define internal void %s() noinline", name)
	owners := thread_local_owners(e)
	for index := len(owners) - 1; index >= 0; index -= 1 {
		sym := symbol_of(e.c, owners[index].symbol)
		emit_drop_place(e, sym.type, symbol_name(e, owners[index].symbol))
	}
	fmt.sbprintln(&e.b, "  ret void")
	fmt.sbprintln(&e.b, "}")
	fmt.sbprintln(&e.b, "")
}

@(private = "file")
Thread_Local_Owner :: struct {
	symbol:   Symbol_Id,
	pkg_key:  string,
	file:     int, // the position in its package's files, which are sorted by path
	position: u32,
}

// design.md "Values that outlive every scope": every managed `thread_local`,
// at file scope or in a procedure, in initialization order: by package path,
// then file path, then source position.
@(private = "file")
thread_local_owners :: proc(e: ^Emitter) -> []Thread_Local_Owner {
	owners := make([dynamic]Thread_Local_Owner, context.temp_allocator)
	add := proc(e: ^Emitter, owners: ^[dynamic]Thread_Local_Owner, symbol_id: Symbol_Id) {
		sym := symbol_of(e.c, symbol_id)
		if sym == nil || sym.kind != .Var || sym.duration != .Thread_Local {
			return
		}
		if !emit_lifecycle(e, sym.type).managed {
			return
		}
		pkg := package_of(e.c, sym.pkg)
		file := 0
		for candidate, index in pkg.files {
			if candidate.file == sym.span.file {
				file = index
			}
		}
		append(owners, Thread_Local_Owner{symbol_id, pkg.key, file, sym.span.lo})
	}
	for symbol_id in e.c.static_locals {
		if !omitted_with_test(e.c, symbol_id) {
			add(e, &owners, symbol_id)
		}
	}
	for index in 1 ..< len(e.c.packages) {
		for file in package_of(e.c, Package_Id(index)).files {
			for item in file.active_items {
				if d, ok := item.(^Decl); ok && decl_proc_literal(d) == nil {
					for symbol_id in d.symbols {
						add(e, &owners, symbol_id)
					}
				}
			}
		}
	}
	slice.sort_by(owners[:], proc(a, b: Thread_Local_Owner) -> bool {
		if a.pkg_key != b.pkg_key {
			return a.pkg_key < b.pkg_key
		}
		if a.file != b.file {
			return a.file < b.file
		}
		return a.position < b.position
	})
	return owners[:]
}

emit_global :: proc(e: ^Emitter, d: ^Decl) {
	for symbol_id, i in d.symbols {
		sym := symbol_of(e.c, symbol_id)
		if sym == nil || sym.kind != .Var {
			continue
		}
		emit_var_global(e, symbol_name(e, symbol_id), sym, d, i)
	}
	fmt.sbprintln(&e.b, "")
}

// A static-duration variable, starting from its constant or its zero.
@(private = "file")
emit_var_global :: proc(e: ^Emitter, name: string, sym: ^Symbol, d: ^Decl, position: int) {
	value_type, value, align := llvm_type(e, sym.type), "", ""
	if initial, constant := binding_initial_const(e.c, d, position); constant {
		value_type, value, align = global_initializer(e, initial, sym.type)
	} else {
		zero, ok := llvm_zero(e, sym.type)
		if !ok {
			backend_fail(e, "a global type was not gated by the checker")
			return
		}
		value = zero
	}
	qualifier := sym.duration == .Thread_Local ? "thread_local " : ""
	fmt.sbprintfln(&e.b, "%s = %sglobal %s %s%s", name, qualifier, value_type, value, align)
}

@(private)
emit_materialized_constants :: proc(e: ^Emitter) {
	if len(e.c.materialized_order) == 0 {
		return
	}
	for entry in e.c.materialized_order {
		value_type, value, align := global_initializer(e, entry.value, entry.type)
		fmt.sbprintfln(&e.b, "%s = private constant %s %s%s", entry.name, value_type, value, align)
	}
	fmt.sbprintln(&e.b, "")
}

// The constant a static-duration binding starts with: its own initializer, or
// for `a, b := record` its field of the folded record (design.md
// "Destructuring").
@(private = "file")
binding_initial_const :: proc(c: ^Compiler, d: ^Decl, position: int) -> (Const_Value, bool) {
	if !d.destructure.active {
		if position < len(d.values) && d.values[position] != nil && is_const_expr(d.values[position]) {
			return expr_base(d.values[position]).const_value, true
		}
		return {}, false
	}
	if len(d.values) != 1 || !is_const_expr(d.values[0]) || position >= len(d.destructure.fields) {
		return {}, false
	}
	record := expr_base(d.values[0]).const_value
	field := symbol_of(c, d.destructure.fields[position])
	if record.kind != .Aggregate || record.aggregate == nil || field == nil ||
	   int(field.index) >= len(record.aggregate.elements) {
		return {}, false
	}
	return record.aggregate.elements[field.index], true
}

// ------------------------------------------------------ runtime failures --

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

// design.md "Panics and unwinding": under `unwind` the runtime replays each
// frame's cleanup first; under `abort` it terminates here.
@(private)
emit_panic :: proc(e: ^Emitter, message: string) {
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_panic(ptr %s)", text_literal_global(e, message))
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
		&e.b, "  call void @loke_rt_v1_abort(ptr %s)", text_literal_global(e, "a move-only value was copied"),
	)
	return true
}

@(private)
panic_if :: proc(e: ^Emitter, cond: string, prefix: string, message: string) {
	fail := new_label(e, prefix)
	ok := new_label(e, "ok")
	branch_if_unlikely(e, cond, fail, ok)
	place_label(e, fail)
	emit_panic(e, message)
	place_label(e, ok)
}

// ==================================================== runtime metadata ==

// design.md "`type` and `typeid`": one entry per requested `typeid`, indexed
// by id, with an empty entry 0.
TYPE_INFO_TABLE :: "@.loke.type_info"

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
	entries := make([]string, len(e.c.typeid_order) + 1)
	for type in e.c.typeid_order {
		entries[typeid_value(e.c, type)] = type_info_entry(e, record, member, type)
	}
	append_constant_array(e, TYPE_INFO_TABLE, struct_name(e, record), entries)
}

// A private constant array; an empty entry is the element's zero.
@(private)
append_constant_array :: proc(e: ^Emitter, name, element: string, entries: []string) {
	b := strings.builder_make()
	fmt.sbprintf(&b, "%s = private unnamed_addr constant [%d x %s] [", name, len(entries), element)
	for entry, index in entries {
		fmt.sbprintf(&b, "%s %s %s", index > 0 ? "," : "", element, entry == "" ? "zeroinitializer" : entry)
	}
	strings.write_string(&b, " ]\n")
	append(&e.globals, strings.to_string(b))
}

@(private = "file")
type_info_entry :: proc(e: ^Emitter, record, member, type: Type_Id) -> string {
	id := fmt.aprintf("%d", typeid_value(e.c, type))
	kind := fmt.aprintf("%d", int(public_type_kind(e.c, type)))
	name := text_view_constant(e, type_name(e.c, type))
	size := fmt.aprintf("%d", type_size(e.c, type))
	align := fmt.aprintf("%d", type_align(e.c, type))
	// design.md: a `distinct` entry's `element` is the type it is declared over,
	// and the shape is that type's to report.
	if info := type_of(e.c, type); info.kind == .Distinct {
		element := fmt.aprintf("%d", typeid_value(e.c, info.element))
		return record_constant(e, record, {id, kind, name, size, align, "", "", element, "", "", ""})
	}
	shape := underlying_info(e.c, type)
	return record_constant(e, record, {
		id, kind, name, size, align,
		fmt.aprintf("%d", shape.bits),
		shape.signed ? "true" : "false",
		fmt.aprintf("%d", typeid_value(e.c, shape.element)),
		fmt.aprintf("%d", typeid_value(e.c, shape.key)),
		fmt.aprintf("%d", shape.count),
		type_info_members(e, member, type),
	})
}

// The public `Type_Kind`, whose order the checker verified against `base/runtime`.
@(private = "file")
public_type_kind :: proc(c: ^Compiler, type: Type_Id) -> Runtime_Type_Kind {
	if type_kind(c, type) == .Distinct {
		return .Distinct
	}
	under := type_underlying(c, type)
	#partial switch type_kind(c, under) {
	case .Void:            return .Void
	case .Bool:            return .Bool
	case .Int:             return type_signed(c, under) ? .Signed_Int : .Unsigned_Int
	case .Float:           return .Float
	case .Rune:            return .Rune
	case .Raw_Pointer:     return .Raw_Pointer
	case .Pointer:         return .Pointer
	case .C_Pointer:       return .C_Pointer
	case .Array:           return .Array
	case .Simd:            return .Simd
	case .Slice:           return .Slice
	case .Dynamic_Array:   return .Dynamic_Array
	case .Map:             return .Map
	case .Struct:          return .Struct
	case .Enum:            return .Enum
	case .Union:           return .Union
	case .Proc:            return .Proc
	case .String:          return .String
	case .String_View:     return .String_View
	case .CString_View:    return .CString_View
	case .Typeid:          return .Typeid
	case .Dyn:             return .Dyn
	case .Allocator:       return .Allocator
	case .Allocator_Error: return .Allocator_Error
	case .Box:             return .Box
	}
	return .Invalid
}

// The `[]Member_Info` of a struct, enum, union, or procedure.
@(private = "file")
type_info_members :: proc(e: ^Emitter, member, type: Type_Id) -> string {
	shape := underlying_info(e.c, type)
	entries := make([dynamic]string)
	#partial switch shape.kind {
	case .Struct:
		for field, index in shape.fields {
			sym := symbol_of(e.c, field)
			if sym == nil || !sym.public {
				continue // design.md: member tables expose public fields only
			}
			offset := fmt.aprintf("%d", type_field_offset(e.c, type, index))
			append(&entries, member_constant(e, member, .Field, field_label(e.c, field), sym.type, offset))
		}
	case .Enum:
		for field in shape.fields {
			sym := symbol_of(e.c, field)
			if sym == nil {
				continue
			}
			low, high := enum_raw_words(e.c, sym.const_value)
			append(&entries, member_constant(e, member, .Enum_Value, identifier_text(e.c, sym.name), type, "", low, high))
		}
	case .Union:
		for variant, index in shape.variants {
			// A payloadless variant reports `Unit`.
			payload := variant == TYPE_VOID ? e.c.unit_type : variant
			name := identifier_text(e.c, shape.variant_names[index])
			append(&entries, member_constant(e, member, .Union_Variant, name, payload, fmt.aprintf("%d", index)))
		}
	case .Proc:
		for parameter in shape.parameters {
			append(&entries, member_constant(e, member, .Parameter, "", parameter))
		}
		if shape.result != INVALID_TYPE {
			append(&entries, member_constant(e, member, .Result, "", shape.result))
		}
	}
	if len(entries) == 0 {
		return "zeroinitializer"
	}
	name := fmt.aprintf("@.loke.members.%d", len(e.globals))
	append_constant_array(e, name, struct_name(e, member), entries[:])
	return slice_constant(name, len(entries))
}

@(private = "file")
member_constant :: proc(
	e: ^Emitter, member: Type_Id, kind: Runtime_Member_Kind, name: string, type: Type_Id, offset := "", low := "", high := "",
) -> string {
	return record_constant(e, member, {
		fmt.aprintf("%d", int(kind)), text_view_constant(e, name), fmt.aprintf("%d", typeid_value(e.c, type)), offset, low, high,
	})
}

// An enum value's low and high 64-bit words, unnarrowed.
@(private = "file")
enum_raw_words :: proc(c: ^Compiler, value: Const_Value) -> (low: string, high: string) {
	if value.kind != .Integer {
		return "0", "0"
	}
	mask := bi_sub(c, bi_pow2(c, 64), bi_from_i64(c, 1))
	low_value, _ := bi_to_u64(c, bi_and(c, value.integer, mask))
	high_value, _ := bi_to_u64(c, bi_and(c, bi_shr(c, value.integer, 64), mask))
	return fmt.aprintf("%d", low_value), fmt.aprintf("%d", high_value)
}

// A metadata record from its fields in `TYPE_INFO_LAYOUT` or `MEMBER_INFO_LAYOUT`
// order, which the checker pinned. An empty value is that field's zero
// (design.md "Zero values").
@(private = "file")
record_constant :: proc(e: ^Emitter, record: Type_Id, values: []string) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "{")
	for field, index in underlying_info(e.c, record).fields {
		value := values[index]
		fmt.sbprintf(
			&b, "%s %s %s", index > 0 ? "," : "", llvm_type(e, symbol_of(e.c, field).type),
			value == "" ? "zeroinitializer" : value,
		)
	}
	strings.write_string(&b, " }")
	return strings.to_string(b)
}

// design.md "`type` and `typeid`": the zero, an out-of-range, or a forged id
// gives the `Invalid` entry, which is entry 0.
@(private)
emit_type_info_of :: proc(e: ^Emitter, v: ^Expr_Call) -> string {
	safe := typeid_index(e, emit_expr(e, v.bound[0]))
	return gep_at(e, struct_name(e, e.c.runtime_types["Type_Info"]), TYPE_INFO_TABLE, safe)
}

// `id` clamped into a table of every `typeid`: a nil or out-of-range id maps to
// the empty entry 0.
@(private)
typeid_index :: proc(e: ^Emitter, id: string) -> string {
	past, safe := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp ugt i64 %s, %d", past, id, len(e.c.typeid_order))
	fmt.sbprintfln(&e.b, "  %s = select i1 %s, i64 0, i64 %s", safe, past, id)
	return safe
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
		case .Standard_Format:
			emit_synth_format(e, symbol, name)
		case .Range_Iter, .Range_Iter_Reverse,
		     .Array_Iter, .Array_Iter_Reverse,
		     .Dynamic_Iter, .Dynamic_Iter_Reverse, .Map_Iter,
		     .Map_View_Iter, .Text_Iter:
			emit_synth_iter(e, symbol, name)
		case .Range_Next:
			emit_synth_range_next(e, symbol, name)
		case .Array_Next:
			emit_synth_indexed_next(e, symbol, name, slice = false)
		case .Slice_Mut_Next, .Slice_Ref_Next:
			emit_synth_indexed_next(e, symbol, name, slice = true)
		case .Map_Next, .Map_Keys_Next, .Map_Values_Next:
			emit_synth_map_next(e, symbol, name)
		case .Text_Next, .Rune_Offsets_Next:
			emit_synth_text_next(e, symbol, name)
		case .Chunks_Next:
			emit_synth_chunks_next(e, symbol, name)
		case .Try_Clone:
			emit_synth_try_clone(e, symbol, name)
		case .Clone:
			emit_synth_clone(e, symbol, name)
		case .Dyn_Forward:
			emit_dyn_forwarding_slot(e, symbol, name)
		case .Dyn_Proc_Adapter:
			emit_dyn_proc_adapter(e, symbol, name)
		case .Container_Op:
			emit_synth_container_op(e, symbol, name)
			if e.consuming_ops[symbol_id] {
				fmt.sbprintln(&e.b, "")
				emit_synth_container_op(e, symbol, consuming_op_name(e, symbol_id), consuming = true)
			}
		case .Provider_Op:
			emit_synth_provider_op(e, symbol, name)
		case .Variant_Construct:
			emit_synth_variant_construct(e, symbol, name)
		case .None:
		}
		fmt.sbprintln(&e.b, "")
	}
}

// `U.name` as a value. The payload arrives owned, so it becomes the variant
// as it is, with nothing cloned and nothing left to drop.
@(private = "file")
emit_synth_variant_construct :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	open_function(
		e, "define %s%s %s(%s%s %%arg0)", llvm_linkage(name), llvm_result_type(e, symbol.result), name,
		sret_param(e, symbol.result), synth_param_llvm(e, symbol, 0),
	)
	index := union_variant_index(e.c, symbol.result, symbol.name)
	variant := emit_union_value(e, symbol.result, index, synth_receiver_value(e, symbol))
	emit_ret(e, symbol.result, variant)
	fmt.sbprintln(&e.b, "}")
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
	}
	fmt.sbprintln(&e.b, "}")
}

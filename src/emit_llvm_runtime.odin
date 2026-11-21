// Runtime declarations, static-storage globals, runtime failures, and the
// dispatch of compiler-contributed procedures.
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
	return emit_value(e, "call ptr @loke_rt_v1_selected_allocator()")
}

// design.md "Allocators": the zero `Allocator` selects the default provider. An
// owner that records its allocator records the provider selected now, so one
// published later is not handed what this one allocated.
@(private)
emit_concrete_allocator :: proc(e: ^Emitter, allocator: string) -> string {
	selected := emit_default_allocator(e)
	return emit_value(e, "select i1 %s, ptr %s, ptr %s", is_null(e, allocator), selected, allocator)
}

// A block from the runtime, and whether it was refused.
@(private)
emit_rt_alloc :: proc(e: ^Emitter, allocator: string, size, align: u64) -> (block, failed: string) {
	return emit_rt_alloc_sized(e, allocator, fmt.tprintf("%d", size), align)
}

// As `emit_rt_alloc`, for a size known only at run time.
@(private)
emit_rt_alloc_sized :: proc(e: ^Emitter, allocator, size: string, align: u64) -> (block, failed: string) {
	block = emit_value(e, "call ptr @loke_rt_v1_alloc(ptr %s, i64 %s, i64 %d)", allocator, size, align)
	return block, is_null(e, block)
}

@(private)
emit_rt_free :: proc(e: ^Emitter, allocator, block: string, size, align: u64) {
	emit_rt_free_sized(e, allocator, block, fmt.tprintf("%d", size), align)
}

@(private)
emit_rt_free_sized :: proc(e: ^Emitter, allocator, block, size: string, align: u64) {
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_free(ptr %s, ptr %s, i64 %s, i64 %d)", allocator, block, size, align)
}

// The runtime entries that end the program, as `LOKE_RT_FAILURE` in
// runtime/loke_rt.h declares them.
@(private = "file")
FAILURE_ATTRIBUTES :: "cold noreturn"

// One runtime entry or LLVM intrinsic a module declares:
// `declare result @name(params) attributes`.
Runtime_Declaration :: struct {
	result, name, params, attributes: string,
}

// Writes `table`'s declarations, in order.
@(private)
declare_runtime :: proc(e: ^Emitter, table: []Runtime_Declaration) {
	for declaration in table {
		declare_runtime_entry(e, declaration)
	}
}

// Writes one declaration and registers it, so a foreign symbol bound to the
// same name refers to it (`emit_foreign_declarations`) and `declare_intrinsic`
// does not declare it again. Only the preamble and the layout probe call it,
// both ahead of the foreign declarations.
@(private)
declare_runtime_entry :: proc(e: ^Emitter, declaration: Runtime_Declaration) {
	name := strings.concatenate({"@", declaration.name})
	if !register_declaration(e, name, function_type(declaration.result, declaration.params)) {
		return
	}
	fmt.sbprintf(&e.b, "declare %s %s(%s)", declaration.result, name, declaration.params)
	if declaration.attributes != "" {
		fmt.sbprintf(&e.b, " %s", declaration.attributes)
	}
	fmt.sbprintln(&e.b)
}

@(private = "file", rodata)
RUNTIME_DECLARATIONS := [?]Runtime_Declaration {
	{"ptr", "loke_rt_v1_alloc", "ptr, i64, i64", ""},
	{"void", "loke_rt_v1_free", "ptr, ptr, i64, i64", ""},
	{"void", "loke_rt_v1_reset", "ptr", ""},
	{"void", "loke_rt_v1_alloc_failed", "ptr", FAILURE_ATTRIBUTES},
	{"i64", "loke_rt_v1_take_refusal", "", ""},
	{"void", "loke_rt_v1_restore_refusal", "ptr, i64", ""},
	{"ptr", "loke_rt_v1_selected_allocator", "", ""},
	{"void", "loke_rt_v1_publish_allocator", "ptr", ""},
	{"i32", "loke_rt_v1_provider_init_begin", "", ""},
	{"void", "loke_rt_v1_provider_init_end", "", ""},
	{"void", "loke_rt_v1_panic", "ptr", FAILURE_ATTRIBUTES},
	// It returns, to let the report's arguments be formatted, but only on the
	// way to `panic_end`.
	{"void", "loke_rt_v1_panic_begin", "ptr", "cold"},
	{"void", "loke_rt_v1_panic_end", "", FAILURE_ATTRIBUTES},
	{"void", "loke_rt_v1_enable_panic_trace", "", ""},
	{"void", "loke_rt_v1_abort", "ptr", FAILURE_ATTRIBUTES},
	{"void", "loke_rt_v1_thread_attach", "", ""},
	{"void", "loke_rt_v1_thread_detach", "", ""},
	{"void", "loke_rt_v1_flush_stdout", "", ""},
	{"i32", "loke_rt_v1_cpu_dispatch", "i32", ""},
}

@(private = "file", rodata)
ENTRY_DECLARATIONS := [?]Runtime_Declaration {
	{"void", "loke_rt_v1_args_init", "i32, ptr", ""},
	{"i64", "loke_rt_v1_test_select", "ptr, i64", ""},
	{"void", "loke_rt_v1_frame_push", "ptr, ptr, ptr", ""},
	{"void", "loke_rt_v1_frame_pop", "ptr", ""},
	{"void", "llvm.memset.p0.i64", "ptr, i8, i64, i1", ""},
	{"void", "llvm.memcpy.p0.p0.i64", "ptr, ptr, i64, i1", ""},
	{"ptr", "llvm.stacksave.p0", "", ""},
	{"void", "llvm.stackrestore.p0", "ptr", ""},
	// A foreign entry's guard and `-debug`'s check after a foreign call
	// (design.md "Floating-point operators").
	{"void", "llvm.x86.sse.stmxcsr", "ptr", ""},
	{"void", "llvm.x86.sse.ldmxcsr", "ptr", ""},
}

@(private = "file", rodata)
FORMAT_DECLARATIONS := [?]Runtime_Declaration {
	{"void", "loke_rt_v1_fmt_bytes", "ptr, ptr, i64", ""},
	{"void", "loke_rt_v1_fmt_i64", "ptr, i64, ptr", ""},
	{"void", "loke_rt_v1_fmt_u64", "ptr, i64, ptr", ""},
	{"void", "loke_rt_v1_fmt_i128", "ptr, i64, i64, ptr", ""},
	{"void", "loke_rt_v1_fmt_u128", "ptr, i64, i64, ptr", ""},
	{"void", "loke_rt_v1_fmt_f64", "ptr, double", ""},
	{"void", "loke_rt_v1_fmt_f32", "ptr, float", ""},
	{"void", "loke_rt_v1_fmt_f16", "ptr, float", ""},
	{"void", "loke_rt_v1_fmt_bool", "ptr, i32", ""},
	{"void", "loke_rt_v1_fmt_rune", "ptr, i32", ""},
	{"void", "loke_rt_v1_fmt_quoted", "ptr, ptr, i64", ""},
	{"void", "loke_rt_v1_fmt_quoted_rune", "ptr, i32", ""},
	{"void", "loke_rt_v1_fmt_ptr", "ptr, ptr", ""},
}

@(private = "file")
emit_runtime_declarations :: proc(e: ^Emitter) {
	declare_runtime(e, RUNTIME_DECLARATIONS[:])
	// Only where the entry or an object's constructor calls it, so a baseline
	// program's own binding is its only declaration; above baseline,
	// `emit_foreign_declarations` skips that binding.
	if e.c.target.cpu != .X86_64 {
		declare_runtime_entry(e, {"void", "loke_rt_v1_require_cpu", "i32", ""})
	}
	declare_runtime(e, ENTRY_DECLARATIONS[:])
	declare_runtime(e, FORMAT_DECLARATIONS[:])
	declare_runtime_entry(e, WRITE_STD_DECLARATION)
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
	name := claim_name(e, fmt.aprintf("@.str.%d", len(e.literals)))
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
	declare_runtime(e, TEXT_DECLARATIONS[:])
}

@(private = "file", rodata)
TEXT_DECLARATIONS := [?]Runtime_Declaration {
	{"i32", "loke_rt_v1_string_from_bytes", "ptr, ptr, i64, ptr", ""},
	{"i32", "loke_rt_v1_string_concat", "ptr, ptr, i64, ptr, i64, ptr", ""},
	{"i32", "loke_rt_v1_string_clone", "ptr, ptr, i64, ptr", ""},
	{"i32", "loke_rt_v1_string_from_runes", "ptr, ptr, i64, ptr", ""},
	{"i32", "loke_rt_v1_string_to_runes", "ptr, ptr, ptr, i64, ptr", ""},
	{"ptr", "loke_rt_v1_arena_open", "ptr, i64", ""},
	{"ptr", "loke_rt_v1_arena_open_fixed", "ptr, i64, i64", ""},
	{"void", "loke_rt_v1_arena_drop", "ptr", ""},
	{"ptr", "loke_rt_v1_arena_allocator", "ptr", ""},
	{"void", "loke_rt_v1_string_retain", "i64", ""},
	{"void", "loke_rt_v1_string_release", "i64", ""},
	{"i64", "loke_rt_v1_utf8_prefix", "ptr, i64", ""},
	{"i64", "loke_rt_v1_rune_count", "ptr, i64", ""},
	{"i64", "loke_rt_v1_rune_at", "ptr, i64, i64, ptr", ""},
	{"i32", "loke_rt_v1_bytes_compare", "ptr, i64, ptr, i64", ""},
	{"i64", "loke_rt_v1_cstring_len", "ptr", ""},
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
		emit_var_global(e, name, symbol_id, sym.decl, position)
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

// Called by the runtime when a thread first attaches, before it runs Loke code:
// points each `thread_local` slice literal at the thread's own array
// (`Thread_Local_Pointer`). It only stores addresses, so it needs no guard.
@(private)
emit_thread_local_setup :: proc(e: ^Emitter) {
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	open_function(e, "define void @loke_rt_v1_program_tls_init()")
	for pointer in e.thread_local_pointers {
		field := emit_value(e, "getelementptr inbounds i8, ptr %s, i64 %d", pointer.global, pointer.offset)
		fmt.sbprintfln(&e.b, "  store ptr %s, ptr %s, align 1", pointer.target, field)
	}
	fmt.sbprintln(&e.b, "  ret void")
	fmt.sbprintln(&e.b, "}")
	fmt.sbprintln(&e.b, "")
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
		emit_var_global(e, symbol_name(e, symbol_id), symbol_id, d, i)
	}
	fmt.sbprintln(&e.b, "")
}

// A static-duration variable, starting from its constant or its zero.
@(private = "file")
emit_var_global :: proc(e: ^Emitter, name: string, symbol_id: Symbol_Id, d: ^Decl, position: int) {
	sym := symbol_of(e.c, symbol_id)
	value_type, value, align := llvm_type(e, sym.type), "", ""
	if initial, constant := binding_initial_const(e.c, d, position); constant {
		e.thread_local_initializer = sym.duration == .Thread_Local
		value_type, value, align, _ = global_initializer(e, initial, sym.type)
		e.thread_local_initializer = false
		claim_thread_local_pointers(e, name)
	} else {
		zero, ok := llvm_zero(e, sym.type)
		if !ok {
			backend_fail(e, "a global type was not gated by the checker")
			return
		}
		value = zero
	}
	qualifier := sym.duration == .Thread_Local ? "thread_local " : ""
	debug_mark_global(e, symbol_id)
	fmt.sbprintfln(&e.b, "%s = %sglobal %s %s%s", name, qualifier, value_type, value, align)
}

@(private)
emit_materialized_constants :: proc(e: ^Emitter) {
	if len(e.c.materialized_order) == 0 {
		return
	}
	for entry in e.c.materialized_order {
		value_type, value, align, _ := global_initializer(e, entry.value, entry.type)
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
	emit_unreachable(e)
}

// design.md "Allocation failure": the provider applies its own policy, which does
// not return.
@(private)
emit_alloc_failed :: proc(e: ^Emitter, provider: string) {
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_alloc_failed(ptr %s)", provider)
	emit_unreachable(e)
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

// Panics with `message` unless the i64 `index` is below `count`, or with
// `inclusive`, at most `count`. Unsigned, so a negative index fails the same
// comparison as an oversized one.
@(private)
emit_bounds_check :: proc(e: ^Emitter, index, count, message: string, inclusive := false) {
	panic_if(e, emit_value(e, "icmp %s i64 %s, %s", inclusive ? "ugt" : "uge", index, count), "bounds", message)
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

@(private)
alloc_failed_if :: proc(e: ^Emitter, cond: string, provider: string, prefix: string) {
	fail := new_label(e, prefix)
	ok := new_label(e, "ok")
	branch_if(e, cond, fail, ok)
	place_label(e, fail)
	emit_alloc_failed(e, provider)
	place_label(e, ok)
}

// ------------------------------------------- compiler-contributed procedures --

// A compiler-provided member of a built-in type, or with `consuming` the body
// of an insertion member that takes its element owned, which only a container
// operation has (`consuming_op_name`).
@(private)
emit_synth_proc :: proc(e: ^Emitter, symbol_id: Symbol_Id, consuming: bool) {
	symbol := symbol_of(e.c, symbol_id)
	if symbol == nil || symbol.synth == .None || consuming && symbol.synth != .Container_Op {
		return
	}
	if len(symbol.params) > 0 && type_is_compile_time_only(e.c, symbol.params[0]) { return }
	e.synth_bodies = true
	defer e.synth_bodies = false
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
	case .Slice_Mut_Next, .Slice_Ref_Next:
		emit_synth_slice_next(e, symbol, name)
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
		emit_synth_container_op(e, symbol, consuming ? consuming_op_name(e, symbol_id) : name, consuming = consuming)
	case .Provider_Op:
		emit_synth_provider_op(e, symbol, name)
	case .Variant_Construct:
		emit_synth_variant_construct(e, symbol, name)
	case .None, .Array_Next:
		// `.Array_Next`'s iterator is compile-time-only, so it was skipped above.
	}
	fmt.sbprintln(&e.b, "")
}

// `U.name` as a value. The payload arrives owned, so it becomes the variant
// as it is, with nothing cloned and nothing left to drop.
@(private = "file")
emit_synth_variant_construct :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	open_synth_function(e, symbol, name)
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
	open_synth_function(e, symbol, name)

	#partial switch symbol.synth {
	case .Standard_Len:
		info := underlying_info(e.c, symbol.params[0])
		if info.kind == .Array || info.kind == .Simd {
			fmt.sbprintfln(&e.b, "  ret %s %d", result, info.count)
		} else {
			field := SLICE_LEN
			#partial switch info.kind {
			case .Dynamic_Array, .Map:
				field = CONTAINER_LEN
			case .String, .String_View:
				field = STRING_LEN
			}
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

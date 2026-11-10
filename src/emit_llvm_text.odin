// Slices and text: pointer-and-length values, text operations, and the
// validating text conversions.
//
// Part of the textual LLVM backend; see compiler-architecture.md.
package lokec

import "core:fmt"

@(private)
emit_ptr_len :: proc(e: ^Emitter, storage, data, length: string) -> string {
	first := insert(e, storage, "undef", "ptr", data, SLICE_DATA)
	out := insert(e, storage, first, "i64", length, SLICE_LEN)
	return out
}

// A `string` or `string_view`'s data pointer and byte length.
@(private)
string_parts :: proc(e: ^Emitter, storage, value: string) -> (data: string, length: string) {
	return extract(e, storage, value, STRING_DATA), extract(e, storage, value, STRING_LEN)
}

// A `string` borrowed as a `string_view`: the owning word is dropped.
@(private)
string_as_view :: proc(e: ^Emitter, storage, value: string) -> string {
	data, length := string_parts(e, storage, value)
	return emit_ptr_len(e, STRING_VIEW_TYPE, data, length)
}

@(private)
ptr_len_parts :: proc(e: ^Emitter, storage, value: string) -> (data: string, length: string) {
	return extract(e, storage, value, SLICE_DATA), extract(e, storage, value, SLICE_LEN)
}

@(private)
emit_slice_value :: proc(e: ^Emitter, slice_type: Type_Id, data, length: string) -> string {
	return emit_ptr_len(e, llvm_type(e, slice_type), data, length)
}

@(private)
emit_slice_parts :: proc(e: ^Emitter, operand: Expr) -> (data: string, length: string) {
	storage := llvm_type(e, expr_base(operand).type)
	value := emit_expr(e, operand)
	return ptr_len_parts(e, storage, value)
}

// The data pointer and byte length of a text operand.
@(private)
emit_text_parts :: proc(e: ^Emitter, operand: Expr) -> (data: string, length: string) {
	type := type_underlying(e.c, expr_base(operand).type)
	value := emit_borrowed_operand(e, operand)
	if type_kind(e.c, type) == .CString_View {
		// A C string view is terminated, not measured.
		length = temp(e)
		fmt.sbprintfln(&e.b, "  %s = call i64 @loke_rt_v1_cstring_len(ptr %s)", length, value)
		return value, length
	}
	return string_parts(e, llvm_type(e, type), value)
}

@(private)
emit_text_operation :: proc(e: ^Emitter, v: ^Expr_Call, as_type: Type_Id) -> string {
	out := "0"
	switch v.operation.(Call_Text).op {
	case .None:
		backend_fail(e, "a text call has no operation")

	case .Byte_Len:
		_, length := emit_text_parts(e, v.bound[0])
		out = length

	case .Rune_Count:
		data, length := emit_text_parts(e, v.bound[0])
		out = temp(e)
		fmt.sbprintfln(&e.b, "  %s = call i64 @loke_rt_v1_rune_count(ptr %s, i64 %s)", out, data, length)

	case .Bytes:
		// A read-only `[]u8` over the same storage.
		data, length := emit_text_parts(e, v.bound[0])
		out = emit_slice_value(e, as_type, data, length)

	case .Runes:
		// The same borrow as `bytes()`, viewed as text (design.md "String iteration").
		data, length := emit_text_parts(e, v.bound[0])
		out = emit_ptr_len(e, STRING_VIEW_TYPE, data, length)

	case .Rune_Offsets:
		// The view holds the bytes; the cursor belongs to its iterator.
		data, length := emit_text_parts(e, v.bound[0])
		view := emit_ptr_len(e, STRING_VIEW_TYPE, data, length)
		out = insert(e, llvm_type(e, as_type), "undef", STRING_VIEW_TYPE, view, VIEW_SOURCE)

	case .Copy:
		data, length := emit_text_parts(e, v.bound[0])
		provider := emit_default_allocator(e)
		out = emit_text_allocating_call(
			e, "loke_rt_v1_string_clone",
			fmt.aprintf("ptr %s, i64 %s, ptr %s", data, length, provider),
			provider,
		)

	case .To_C_View:
		// design.md "C string views": every `string` buffer and literal carries a
		// terminator, so the view is the string's own data, borrowed like `bytes()`.
		// The empty string has no buffer, and C needs a pointer to read.
		data, _ := emit_text_parts(e, v.bound[0])
		missing := is_null(e, data)
		out = emit_value(e, "select i1 %s, ptr %s, ptr %s", missing, text_literal_global(e, ""), data)

	case .To_Runes:
		// The helper releases its partial buffer before the policy applies.
		data, length := emit_text_parts(e, v.bound[0])
		ops := container_ops_global(e, as_type)
		slot := alloca(e, CONTAINER_TYPE)
		provider := emit_default_allocator(e)
		ok := temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call i32 @loke_rt_v1_string_to_runes(ptr %s, ptr %s, ptr %s, i64 %s, ptr %s)",
			ok, slot, ops, data, length, provider,
		)
		emit_alloc_check(e, ok, provider)
		out = load(e, CONTAINER_TYPE, slot)

	}
	return out
}

// An implicit allocation has nowhere to report failure, so a zero `status`
// applies the provider's own policy (design.md "Allocation failure").
@(private = "file")
emit_alloc_check :: proc(e: ^Emitter, status, provider: string) {
	alloc_failed_if(e, icmp_zero(e, "i32", status), provider, "text.failed")
}

// A runtime call that fills a `string` out-parameter and answers 1 on success.
// Pointers and integers only, so C and LLVM cannot disagree on returning a
// 24-byte aggregate.
@(private = "file")
emit_text_call_slot :: proc(e: ^Emitter, callee: string, arguments: string) -> (slot: string, ok: string) {
	slot = alloca(e, STRING_TYPE)
	ok = temp(e)
	fmt.sbprintfln(&e.b, "  %s = call i32 @%s(ptr %s, %s)", ok, callee, slot, arguments)
	return slot, ok
}

@(private)
emit_text_allocating_call :: proc(e: ^Emitter, callee, arguments, provider: string) -> string {
	slot, ok := emit_text_call_slot(e, callee, arguments)
	emit_alloc_check(e, ok, provider)
	return load(e, STRING_TYPE, slot)
}

// On failure the runtime has already published the zero value into the slot.
@(private = "file")
emit_text_optional_ok :: proc(e: ^Emitter, option: Type_Id, callee, arguments: string) -> string {
	slot, ok := emit_text_call_slot(e, callee, arguments)
	value := load(e, STRING_TYPE, slot)
	return emit_option_value(e, option, icmp_zero(e, "i32", ok, equal = false), value)
}

// `Option(string_view)` over bytes that are borrowed, not copied: `.some` only
// when they are valid UTF-8.
@(private)
emit_checked_view :: proc(e: ^Emitter, option: Type_Id, data, length: string) -> string {
	valid := emit_value(e, "call i32 @loke_rt_v1_utf8_valid(ptr %s, i64 %s)", data, length)
	ok := icmp_zero(e, "i32", valid, equal = false)
	kept_data := emit_value(e, "select i1 %s, ptr %s, ptr null", ok, data)
	kept_len := emit_value(e, "select i1 %s, i64 %s, i64 0", ok, length)
	view := emit_ptr_len(e, STRING_VIEW_TYPE, kept_data, kept_len)
	return emit_option_value(e, option, ok, view)
}

// `strings.allocate_string(text, allocator)`: `.copy()` into the caller's
// allocator, reporting failure instead of applying its policy. The header
// records the allocator, so release returns the block to it.
@(private)
emit_strings_allocate :: proc(e: ^Emitter, v: ^Expr_Call, as_type: Type_Id) -> string {
	data, length := emit_text_parts(e, v.bound[0])
	allocator := emit_expr(e, v.bound[1])
	slot, ok := emit_text_call_slot(
		e, "loke_rt_v1_string_clone", fmt.aprintf("ptr %s, i64 %s, ptr %s", data, length, allocator),
	)
	copied := load(e, STRING_TYPE, slot)
	return emit_alloc_result(e, as_type, icmp_zero(e, "i32", ok), copied)
}

@(private = "file")
emit_string_from_bytes :: proc(e: ^Emitter, option: Type_Id, data, length: string) -> string {
	return emit_text_optional_ok(
		e, option, "loke_rt_v1_string_from_bytes",
		fmt.aprintf("ptr %s, i64 %s, ptr %s", data, length, emit_default_allocator(e)),
	)
}

// design.md "string type conversions": each validates and returns `Option(T)`.
@(private)
emit_text_conversion :: proc(e: ^Emitter, v: ^Expr_Call, as_type: Type_Id) -> string {
	switch v.operation.(Call_Text_Conversion).op {
	case .String_From_Bytes:
		data, length := emit_slice_parts(e, v.bound[0])
		return emit_string_from_bytes(e, as_type, data, length)

	case .View_From_Bytes:
		// A borrow of the slice's root, which `src/borrow.odin` keeps alive.
		data, length := emit_slice_parts(e, v.bound[0])
		return emit_checked_view(e, as_type, data, length)

	case .C_View_From_Bytes:
		// Also a borrow of the slice's root. C reads to the first zero, so a
		// zero last byte keeps every read inside the slice.
		data, length := emit_slice_parts(e, v.bound[0])
		terminated := alloca(e, "i1")
		fmt.sbprintfln(&e.b, "  store i1 false, ptr %s", terminated)
		nonempty := temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp sgt i64 %s, 0", nonempty, length)
		check, done := new_label(e, "cview.check"), new_label(e, "cview.done")
		branch_if(e, nonempty, check, done)
		place_label(e, check)
		last := emit_value(e, "sub i64 %s, 1", length)
		zero := icmp_zero(e, "i8", load(e, "i8", gep_at(e, "i8", data, last)))
		fmt.sbprintfln(&e.b, "  store i1 %s, ptr %s", zero, terminated)
		place_label(e, done)
		ok, kept := load(e, "i1", terminated), temp(e)
		fmt.sbprintfln(&e.b, "  %s = select i1 %s, ptr %s, ptr null", kept, ok, data)
		return emit_option_value(e, as_type, ok, kept)

	case .String_From_C_View:
		data, length := emit_text_parts(e, v.bound[0])
		return emit_string_from_bytes(e, as_type, data, length)

	case .String_From_Runes:
		data, count := emit_slice_parts(e, v.bound[0])
		return emit_text_optional_ok(
			e, as_type, "loke_rt_v1_string_from_runes",
			fmt.aprintf("ptr %s, i64 %s, ptr %s", data, count, emit_default_allocator(e)),
		)
	}
	backend_fail(e, "an unclassified text conversion reached emission")
	return "zeroinitializer"
}

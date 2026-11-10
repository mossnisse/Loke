// The contributed `mem.Arena` and `mem.Scratch` provider bodies.
//
// Part of the textual LLVM backend; see compiler-architecture.md.
package lokec

import "core:fmt"

// One contributed `mem.Arena`/`mem.Scratch` operation. The value is one pointer
// to an address-stable control block.
@(private)
emit_synth_provider_op :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	// `try_arena` returns `Result(Arena, Allocator_Error)`; the provider is `.ok`.
	produced := symbol.result
	if symbol.provider_op == .Try_Open {
		produced = union_variant_payload(e.c, produced, union_index_of(e.c, produced, "ok"))
	}
	provider := llvm_type(e, produced == TYPE_ALLOCATOR ? symbol.params[0] : produced)
	result := llvm_result_type(e, symbol.result, symbol.result_inout)
	open_synth_function(e, symbol, name)

	switch symbol.provider_op {
	case .None:
	case .Open:
		opened := temp(e)
		fmt.sbprintfln(&e.b, "  %s = call ptr @loke_rt_v1_arena_open(ptr %%arg0)", opened)
		emit_provider_open_check(e, opened, "%arg0")
		emit_provider_policy(e, opened)
		out := insert(e, provider, "undef", "ptr", opened, PROVIDER_CONTROL)
		fmt.sbprintfln(&e.b, "  ret %s %s", provider, out)

	case .Open_Fixed:
		// Fixed storage cannot run out; a too-small buffer is a runtime fault.
		buffer := llvm_type(e, symbol.params[0])
		data, length := ptr_len_parts(e, buffer, "%arg0")
		opened := temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call ptr @loke_rt_v1_arena_open_fixed(ptr %s, i64 %s)", opened, data, length,
		)
		emit_provider_policy(e, opened)
		out := insert(e, provider, "undef", "ptr", opened, PROVIDER_CONTROL)
		fmt.sbprintfln(&e.b, "  ret %s %s", provider, out)

	case .Try_Open:
		opened := temp(e)
		fmt.sbprintfln(&e.b, "  %s = call ptr @loke_rt_v1_arena_open(ptr %%arg0)", opened)
		emit_provider_policy(e, opened)
		value := insert(e, provider, "undef", "ptr", opened, PROVIDER_CONTROL)
		failed := is_null(e, opened)
		fmt.sbprintfln(
			&e.b, "  ret %s %s", result, emit_alloc_result(e, symbol.result, failed, value),
		)

	case .Handle:
		control := extract(e, provider, "%arg0", PROVIDER_CONTROL)
		handle := temp(e)
		fmt.sbprintfln(&e.b, "  %s = call ptr @loke_rt_v1_arena_allocator(ptr %s)", handle, control)
		fmt.sbprintfln(&e.b, "  ret ptr %s", handle)
	}
	fmt.sbprintln(&e.b, "}")
}

// The constructor's `policy`, its second parameter. A failed `try_` open has no
// control block, which the runtime ignores.
@(private = "file")
emit_provider_policy :: proc(e: ^Emitter, control: string) {
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_arena_set_failure(ptr %s, i64 %%arg1)", control)
}

@(private = "file")
emit_provider_open_check :: proc(e: ^Emitter, control, allocator: string) {
	alloc_failed_if(e, is_null(e, control), allocator, "arena.failed")
}

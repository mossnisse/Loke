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
	case .Open, .Try_Open:
		// The constructor's `policy` is its second parameter.
		opened := emit_value(e, "call ptr @loke_rt_v1_arena_open(ptr %%arg0, i64 %%arg1)")
		value := insert(e, provider, "undef", "ptr", opened, PROVIDER_CONTROL)
		failed := is_null(e, opened)
		if symbol.provider_op == .Try_Open {
			fmt.sbprintfln(
				&e.b, "  ret %s %s", result, emit_alloc_result(e, symbol.result, failed, value),
			)
		} else {
			alloc_failed_if(e, failed, "%arg0", "arena.failed")
			fmt.sbprintfln(&e.b, "  ret %s %s", provider, value)
		}

	case .Open_Fixed:
		// Fixed storage cannot run out; a too-small buffer is a runtime fault.
		buffer := llvm_type(e, symbol.params[0])
		data, length := ptr_len_parts(e, buffer, "%arg0")
		opened := emit_value(
			e, "call ptr @loke_rt_v1_arena_open_fixed(ptr %s, i64 %s, i64 %%arg1)", data, length,
		)
		out := insert(e, provider, "undef", "ptr", opened, PROVIDER_CONTROL)
		fmt.sbprintfln(&e.b, "  ret %s %s", provider, out)

	case .Handle:
		control := extract(e, provider, "%arg0", PROVIDER_CONTROL)
		handle := emit_value(e, "call ptr @loke_rt_v1_arena_allocator(ptr %s)", control)
		fmt.sbprintfln(&e.b, "  ret ptr %s", handle)
	}
	fmt.sbprintln(&e.b, "}")
}

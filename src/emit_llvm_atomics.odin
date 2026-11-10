// LLVM handles 8-64-bit atomics; runtime/atomic.c serializes every 128-bit operation.
package lokec

import "core:fmt"

@(private = "file")
llvm_ordering :: proc(order: Memory_Order) -> string {
	switch order {
	case .Relaxed:                 return "monotonic"
	case .Acquire:                 return "acquire"
	case .Release:                 return "release"
	case .Acquire_Release:         return "acq_rel"
	case .Sequentially_Consistent: return "seq_cst"
	}
	return "seq_cst"
}

@(private = "file")
atomic_rmw_opcode :: proc(kind: Builtin_Kind) -> string {
	#partial switch kind {
	case .Atomic_Exchange: return "xchg"
	case .Atomic_Add:      return "add"
	case .Atomic_Sub:      return "sub"
	case .Atomic_And:      return "and"
	case .Atomic_Or:       return "or"
	case .Atomic_Xor:      return "xor"
	}
	return ""
}

emit_atomic_declarations :: proc(e: ^Emitter) {
	declare_runtime(e, ATOMIC_DECLARATIONS[:])
}

@(private = "file", rodata)
ATOMIC_DECLARATIONS := [?]Runtime_Declaration {
	{"void", "loke_rt_v1_atomic128_load", "ptr, ptr, i32", ""},
	{"void", "loke_rt_v1_atomic128_store", "ptr, ptr, i32", ""},
	{"void", "loke_rt_v1_atomic128_exchange", "ptr, ptr, ptr, i32", ""},
	{"i32", "loke_rt_v1_atomic128_compare_exchange", "ptr, ptr, ptr, i32, i32", ""},
	{"void", "loke_rt_v1_atomic128_add", "ptr, ptr, ptr, i32", ""},
	{"void", "loke_rt_v1_atomic128_sub", "ptr, ptr, ptr, i32", ""},
	{"void", "loke_rt_v1_atomic128_and", "ptr, ptr, ptr, i32", ""},
	{"void", "loke_rt_v1_atomic128_or", "ptr, ptr, ptr, i32", ""},
	{"void", "loke_rt_v1_atomic128_xor", "ptr, ptr, ptr, i32", ""},
}

emit_atomic_builtin :: proc(e: ^Emitter, v: ^Expr_Call, kind: Builtin_Kind, as_type: Type_Id) -> string {
	checked := v.operation.(Call_Atomic)
	if kind == .Atomic_Fence {
		fmt.sbprintfln(&e.b, "  fence %s", llvm_ordering(checked.order))
		return "0"
	}

	bits := atomic_width_bits(e.c, checked.type)
	address := emit_expr(e, v.bound[0])
	// LLVM's Windows x64 lowering needs unavailable `__atomic_*_16` helpers.
	if bits == 128 {
		return emit_fallback_atomic(e, v, checked, kind, address, as_type)
	}
	return emit_native_atomic(e, v, checked, kind, address, bits, as_type)
}

@(private = "file")
atomic_to_storage :: proc(e: ^Emitter, type: Type_Id, value: string) -> string {
	kind := underlying_kind(e.c, type)
	if kind == .Bool {
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = zext i1 %s to i8", out, value)
		return out
	}
	// A one-word `Option` is its address word.
	if kind == .Union {
		return extract(e, llvm_type(e, type), value, 0)
	}
	return value
}

@(private = "file")
atomic_from_storage :: proc(e: ^Emitter, type: Type_Id, storage: string, value: string) -> string {
	kind := underlying_kind(e.c, type)
	if kind == .Bool {
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp ne i8 %s, 0", out, value)
		return out
	}
	if kind == .Union {
		return insert(e, llvm_type(e, type), "undef", storage, value, 0)
	}
	return value
}

@(private = "file")
emit_native_atomic :: proc(
	e: ^Emitter,
	v: ^Expr_Call,
	checked: Call_Atomic,
	kind: Builtin_Kind,
	address: string,
	bits: int,
	as_type: Type_Id,
) -> string {
	storage := fmt.aprintf("i%d", bits)
	#partial switch underlying_kind(e.c, checked.type) {
	case .Pointer, .C_Pointer, .Raw_Pointer:
		storage = "ptr"
	}
	order := llvm_ordering(checked.order)
	align := bits / 8

	if kind == .Atomic_Load {
		raw := temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = load atomic %s, ptr %s %s, align %d",
			raw, storage, address, order, align,
		)
		return atomic_from_storage(e, checked.type, storage, raw)
	}

	if kind == .Atomic_Store {
		value := atomic_to_storage(e, checked.type, emit_expr(e, v.bound[1]))
		fmt.sbprintfln(
			&e.b, "  store atomic %s %s, ptr %s %s, align %d",
			storage, value, address, order, align,
		)
		return "0"
	}

	if kind == .Atomic_Compare_Exchange {
		expected := atomic_to_storage(e, checked.type, emit_expr(e, v.bound[1]))
		desired := atomic_to_storage(e, checked.type, emit_expr(e, v.bound[2]))
		pair := temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = cmpxchg ptr %s, %s %s, %s %s %s %s, align %d",
			pair, address, storage, expected, storage, desired,
			order, llvm_ordering(checked.failure_order), align,
		)
		pair_type := fmt.aprintf("{{ %s, i1 }}", storage)
		observed := extract(e, pair_type, pair, 0)
		swapped := extract(e, pair_type, pair, 1)
		return emit_atomic_exchange_result(e, checked.type, storage, observed, swapped, as_type)
	}

	opcode := atomic_rmw_opcode(kind)
	value := atomic_to_storage(e, checked.type, emit_expr(e, v.bound[1]))
	previous := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = atomicrmw %s ptr %s, %s %s %s, align %d",
		previous, opcode, address, storage, value, order, align,
	)
	return atomic_from_storage(e, checked.type, storage, previous)
}

// Pass 128-bit operands by address to the C helpers.
@(private = "file")
emit_fallback_atomic :: proc(
	e: ^Emitter,
	v: ^Expr_Call,
	checked: Call_Atomic,
	kind: Builtin_Kind,
	address: string,
	as_type: Type_Id,
) -> string {
	storage := llvm_type(e, checked.type)

	if kind == .Atomic_Load {
		out := alloca(e, storage)
		fmt.sbprintfln(
			&e.b, "  call void @loke_rt_v1_atomic128_load(ptr %s, ptr %s, i32 %d)",
			address, out, int(checked.order),
		)
		return load(e, storage, out)
	}

	if kind == .Atomic_Store {
		value := alloca(e, storage)
		store(e, checked.type, emit_expr(e, v.bound[1]), value)
		fmt.sbprintfln(
			&e.b, "  call void @loke_rt_v1_atomic128_store(ptr %s, ptr %s, i32 %d)",
			address, value, int(checked.order),
		)
		return "0"
	}

	if kind == .Atomic_Compare_Exchange {
		expected := alloca(e, storage)
		desired := alloca(e, storage)
		store(e, checked.type, emit_expr(e, v.bound[1]), expected)
		store(e, checked.type, emit_expr(e, v.bound[2]), desired)
		status, swapped := temp(e), temp(e)
		// Failure writes the observed value back into `expected`.
		fmt.sbprintfln(
			&e.b,
			"  %s = call i32 @loke_rt_v1_atomic128_compare_exchange(ptr %s, ptr %s, ptr %s, i32 %d, i32 %d)",
			status, address, expected, desired, int(checked.order), int(checked.failure_order),
		)
		fmt.sbprintfln(&e.b, "  %s = icmp ne i32 %s, 0", swapped, status)
		observed := load(e, storage, expected)
		return emit_atomic_exchange_result(e, checked.type, storage, observed, swapped, as_type)
	}

	helper := kind == .Atomic_Exchange ? "exchange" : atomic_rmw_opcode(kind)
	value, out := alloca(e, storage), alloca(e, storage)
	store(e, checked.type, emit_expr(e, v.bound[1]), value)
	fmt.sbprintfln(
		&e.b, "  call void @loke_rt_v1_atomic128_%s(ptr %s, ptr %s, ptr %s, i32 %d)",
		helper, address, value, out, int(checked.order),
	)
	return load(e, storage, out)
}

// `.none` means swapped; `.some(observed)` means failed.
@(private = "file")
emit_atomic_exchange_result :: proc(
	e: ^Emitter,
	type: Type_Id,
	storage: string,
	observed: string,
	swapped: string,
	as_type: Type_Id,
) -> string {
	failed := temp(e)
	fmt.sbprintfln(&e.b, "  %s = xor i1 %s, true", failed, swapped)
	value := atomic_from_storage(e, type, storage, observed)
	return emit_option_value(e, as_type, failed, value)
}

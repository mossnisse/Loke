// LLVM handles 8-64-bit atomics; runtime/atomic.c serializes every 128-bit operation.
package lokec

import "core:fmt"

// LLVM's Windows x64 lowering needs unavailable `__atomic_*_16` helpers.
@(private = "file")
atomic_width_is_native :: proc(bits: int) -> bool {
	switch bits {
	case 8, 16, 32, 64:
		return true
	}
	return false
}

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

@(private = "file")
atomic_helper_name :: proc(kind: Builtin_Kind) -> string {
	#partial switch kind {
	case .Atomic_Load:             return "load"
	case .Atomic_Store:            return "store"
	case .Atomic_Exchange:         return "exchange"
	case .Atomic_Compare_Exchange: return "compare_exchange"
	case .Atomic_Add:              return "add"
	case .Atomic_Sub:              return "sub"
	case .Atomic_And:              return "and"
	case .Atomic_Or:               return "or"
	case .Atomic_Xor:              return "xor"
	}
	return ""
}

emit_atomic_declarations :: proc(e: ^Emitter) {
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_atomic128_load(ptr, ptr, i32)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_atomic128_store(ptr, ptr, i32)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_atomic128_exchange(ptr, ptr, ptr, i32)")
	fmt.sbprintln(&e.b, "declare i32 @loke_rt_v1_atomic128_compare_exchange(ptr, ptr, ptr, i32, i32)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_atomic128_add(ptr, ptr, ptr, i32)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_atomic128_sub(ptr, ptr, ptr, i32)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_atomic128_and(ptr, ptr, ptr, i32)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_atomic128_or(ptr, ptr, ptr, i32)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_atomic128_xor(ptr, ptr, ptr, i32)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_atomic_fence(i32)")
}

emit_atomic_builtin :: proc(e: ^Emitter, v: ^Expr_Call, kind: Builtin_Kind, as_type: Type_Id) -> string {
	checked := v.operation.(Call_Atomic)
	order := Memory_Order(checked.order)
	if kind == .Atomic_Fence {
		// Fences have no width-specific lowering.
		fmt.sbprintfln(&e.b, "  fence %s", llvm_ordering(order))
		return "0"
	}

	bits := atomic_width_bits(e.c, checked.type)
	address := emit_expr(e, v.bound[0])
	if atomic_width_is_native(bits) {
		return emit_native_atomic(e, v, kind, address, bits, order, as_type)
	}
	return emit_fallback_atomic(e, v, kind, address, order, as_type)
}

// Booleans occupy one byte in memory; pointers use their integer representation.
@(private = "file")
atomic_storage_type :: proc(e: ^Emitter, type: Type_Id, bits: int) -> string {
	if underlying_kind(e.c, type) == .Bool {
		return "i8"
	}
	if underlying_kind(e.c, type) == .Pointer || underlying_kind(e.c, type) == .C_Pointer ||
	   underlying_kind(e.c, type) == .Raw_Pointer {
		return fmt.aprintf("i%d", bits)
	}
	return llvm_type(e, type)
}

@(private = "file")
atomic_to_storage :: proc(e: ^Emitter, type: Type_Id, storage: string, value: string) -> string {
	kind := underlying_kind(e.c, type)
	if kind == .Bool {
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = zext i1 %s to i8", out, value)
		return out
	}
	if kind == .Pointer || kind == .C_Pointer || kind == .Raw_Pointer {
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = ptrtoint ptr %s to %s", out, value, storage)
		return out
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
	if kind == .Pointer || kind == .C_Pointer || kind == .Raw_Pointer {
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = inttoptr %s %s to ptr", out, storage, value)
		return out
	}
	return value
}

@(private = "file")
emit_native_atomic :: proc(
	e: ^Emitter,
	v: ^Expr_Call,
	kind: Builtin_Kind,
	address: string,
	bits: int,
	order: Memory_Order,
	as_type: Type_Id,
) -> string {
	checked := v.operation.(Call_Atomic)
	storage := atomic_storage_type(e, checked.type, bits)
	align := bits / 8

	if kind == .Atomic_Load {
		raw := temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = load atomic %s, ptr %s %s, align %d",
			raw, storage, address, llvm_ordering(order), align,
		)
		return atomic_from_storage(e, checked.type, storage, raw)
	}

	if kind == .Atomic_Store {
		value := atomic_to_storage(e, checked.type, storage, emit_expr(e, v.bound[1]))
		fmt.sbprintfln(
			&e.b, "  store atomic %s %s, ptr %s %s, align %d",
			storage, value, address, llvm_ordering(order), align,
		)
		return "0"
	}

	if kind == .Atomic_Compare_Exchange {
		expected := atomic_to_storage(e, checked.type, storage, emit_expr(e, v.bound[1]))
		desired := atomic_to_storage(e, checked.type, storage, emit_expr(e, v.bound[2]))
		pair, observed, swapped := temp(e), temp(e), temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = cmpxchg ptr %s, %s %s, %s %s %s %s, align %d",
			pair, address, storage, expected, storage, desired,
			llvm_ordering(order), llvm_ordering(Memory_Order(checked.failure_order)), align,
		)
		// `{` is a directive to core:fmt, so the pair type is concatenated.
		pair_type := fmt.aprintf("%s%s, i1 }", "{ ", storage)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, 0", observed, pair_type, pair)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, 1", swapped, pair_type, pair)
		return emit_atomic_exchange_result(e, v, storage, observed, swapped, as_type)
	}

	opcode := atomic_rmw_opcode(kind)
	value := atomic_to_storage(e, checked.type, storage, emit_expr(e, v.bound[1]))
	previous := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = atomicrmw %s ptr %s, %s %s %s, align %d",
		previous, opcode, address, storage, value, llvm_ordering(order), align,
	)
	return atomic_from_storage(e, checked.type, storage, previous)
}

// Pass 128-bit operands by address to the C helpers.
@(private = "file")
emit_fallback_atomic :: proc(
	e: ^Emitter,
	v: ^Expr_Call,
	kind: Builtin_Kind,
	address: string,
	order: Memory_Order,
	as_type: Type_Id,
) -> string {
	checked := v.operation.(Call_Atomic)
	storage := llvm_type(e, checked.type)
	helper := atomic_helper_name(kind)
	out := alloca(e, storage)

	if kind == .Atomic_Load {
		fmt.sbprintfln(
			&e.b, "  call void @loke_rt_v1_atomic128_load(ptr %s, ptr %s, i32 %d)",
			address, out, int(order),
		)
		result := load(e, storage, out)
		return result
	}

	if kind == .Atomic_Store {
		value := alloca(e, storage)
		store(e, checked.type, emit_expr(e, v.bound[1]), value)
		fmt.sbprintfln(
			&e.b, "  call void @loke_rt_v1_atomic128_store(ptr %s, ptr %s, i32 %d)",
			address, value, int(order),
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
			status, address, expected, desired, int(order), checked.failure_order,
		)
		fmt.sbprintfln(&e.b, "  %s = icmp ne i32 %s, 0", swapped, status)
		observed := load(e, storage, expected)
		return emit_atomic_exchange_result(e, v, storage, observed, swapped, as_type)
	}

	value := alloca(e, storage)
	store(e, checked.type, emit_expr(e, v.bound[1]), value)
	fmt.sbprintfln(
		&e.b, "  call void @loke_rt_v1_atomic128_%s(ptr %s, ptr %s, ptr %s, i32 %d)",
		helper, address, value, out, int(order),
	)
	result := load(e, storage, out)
	return result
}

// `.none` means swapped; `.some(observed)` means failed.
@(private = "file")
emit_atomic_exchange_result :: proc(
	e: ^Emitter,
	v: ^Expr_Call,
	storage: string,
	observed: string,
	swapped: string,
	as_type: Type_Id,
) -> string {
	failed := temp(e)
	fmt.sbprintfln(&e.b, "  %s = xor i1 %s, true", failed, swapped)
	value := atomic_from_storage(e, v.operation.(Call_Atomic).type, storage, observed)
	return emit_option_value(e, as_type, failed, value)
}

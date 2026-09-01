// Lowering the atomic intrinsics (design.md "Concurrency and the memory
// model", m8-plan step 4).
//
// Two paths, chosen by width. A width the target has a native instruction for
// becomes `load atomic`, `store atomic`, `atomicrmw`, or `cmpxchg` with the
// ordering the checker settled. A width it does not — 128 bits on Windows x64 —
// calls a versioned helper in `runtime/atomic.c`, because LLVM's own 128-bit
// atomic lowering emits `__atomic_*_16` calls that this link does not supply.
// Emitting valid IR is not the same as implementing the promised type set.
//
// *Every* operation on a fallback width takes the fallback path, loads and
// stores included: mixing a locked read-modify-write with an unlocked wide load
// would lose the atomicity the lock is there to provide.
package lokec

import "core:fmt"

// The widths Windows x64 has native atomics for. 128-bit `cmpxchg16b` exists,
// but reaching it through LLVM requires the `__atomic_*_16` library this link
// does not have, so 128 bits goes to the runtime.
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

// The `atomicrmw` opcode, or "" for an operation that is not one.
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

// The runtime helper suffix for the fallback path, which names the operation
// rather than the opcode so `runtime/atomic.c` reads as a list of operations.
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

emit_atomic_builtin :: proc(e: ^Emitter, v: ^Expr_Call, kind: Builtin_Kind) -> string {
	order := Memory_Order(v.atomic_order)
	if kind == .Atomic_Fence {
		// A fence has no operand and no width, so both paths agree: LLVM emits the
		// barrier natively, and the runtime helper exists only so the fallback
		// widths order against the same one.
		fmt.sbprintfln(&e.b, "  fence %s", llvm_ordering(order))
		return "0"
	}

	bits := atomic_width_bits(e.c, v.atomic_type)
	address := emit_expr(e, v.bound[0])
	if atomic_width_is_native(bits) {
		return emit_native_atomic(e, v, kind, address, bits, order)
	}
	return emit_fallback_atomic(e, v, kind, address, order)
}

// The storage type one operation runs at. A `bool` is `i1` in a register and
// one byte in memory, and an atomic operation is on the byte — design.md's
// "byte-sized storage for atomic booleans", with the conversions below.
@(private = "file")
atomic_storage_type :: proc(e: ^Emitter, type: Type_Id, bits: int) -> string {
	if underlying_kind(e.c, type) == .Bool {
		return "i8"
	}
	if underlying_kind(e.c, type) == .Pointer || underlying_kind(e.c, type) == .Multi_Pointer ||
	   underlying_kind(e.c, type) == .Raw_Pointer {
		// A pointer is atomically an integer of its own width: `atomicrmw` has no
		// pointer form, and `cmpxchg` on `ptr` needs no conversion but is simpler
		// kept on one path with the rest.
		return fmt.aprintf("i%d", bits)
	}
	return llvm_type(e, type)
}

// A Loke value in its atomic storage form.
@(private = "file")
atomic_to_storage :: proc(e: ^Emitter, type: Type_Id, storage: string, value: string) -> string {
	kind := underlying_kind(e.c, type)
	if kind == .Bool {
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = zext i1 %s to i8", out, value)
		return out
	}
	if kind == .Pointer || kind == .Multi_Pointer || kind == .Raw_Pointer {
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = ptrtoint ptr %s to %s", out, value, storage)
		return out
	}
	return value
}

// And back.
@(private = "file")
atomic_from_storage :: proc(e: ^Emitter, type: Type_Id, storage: string, value: string) -> string {
	kind := underlying_kind(e.c, type)
	if kind == .Bool {
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp ne i8 %s, 0", out, value)
		return out
	}
	if kind == .Pointer || kind == .Multi_Pointer || kind == .Raw_Pointer {
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
) -> string {
	storage := atomic_storage_type(e, v.atomic_type, bits)
	align := bits / 8

	if kind == .Atomic_Load {
		raw := temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = load atomic %s, ptr %s %s, align %d",
			raw, storage, address, llvm_ordering(order), align,
		)
		return atomic_from_storage(e, v.atomic_type, storage, raw)
	}

	if kind == .Atomic_Store {
		value := atomic_to_storage(e, v.atomic_type, storage, emit_expr(e, v.bound[1]))
		fmt.sbprintfln(
			&e.b, "  store atomic %s %s, ptr %s %s, align %d",
			storage, value, address, llvm_ordering(order), align,
		)
		return "0"
	}

	if kind == .Atomic_Compare_Exchange {
		expected := atomic_to_storage(e, v.atomic_type, storage, emit_expr(e, v.bound[1]))
		desired := atomic_to_storage(e, v.atomic_type, storage, emit_expr(e, v.bound[2]))
		pair, observed, swapped := temp(e), temp(e), temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = cmpxchg ptr %s, %s %s, %s %s %s %s, align %d",
			pair, address, storage, expected, storage, desired,
			llvm_ordering(order), llvm_ordering(Memory_Order(v.atomic_failure_order)), align,
		)
		// `{` is a directive to core:fmt, so the pair type is concatenated.
		pair_type := fmt.aprintf("%s%s, i1 }", "{ ", storage)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, 0", observed, pair_type, pair)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, 1", swapped, pair_type, pair)
		return emit_atomic_exchange_result(e, v, storage, observed, swapped)
	}

	opcode := atomic_rmw_opcode(kind)
	value := atomic_to_storage(e, v.atomic_type, storage, emit_expr(e, v.bound[1]))
	previous := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = atomicrmw %s ptr %s, %s %s %s, align %d",
		previous, opcode, address, storage, value, llvm_ordering(order), align,
	)
	return atomic_from_storage(e, v.atomic_type, storage, previous)
}

// The runtime path. Every operand travels by address, because the helper is one
// C function per operation rather than one per width and type.
@(private = "file")
emit_fallback_atomic :: proc(
	e: ^Emitter,
	v: ^Expr_Call,
	kind: Builtin_Kind,
	address: string,
	order: Memory_Order,
) -> string {
	storage := llvm_type(e, v.atomic_type)
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
		store(e, v.atomic_type, emit_expr(e, v.bound[1]), value)
		fmt.sbprintfln(
			&e.b, "  call void @loke_rt_v1_atomic128_store(ptr %s, ptr %s, i32 %d)",
			address, value, int(order),
		)
		return "0"
	}

	if kind == .Atomic_Compare_Exchange {
		expected := alloca(e, storage)
		desired := alloca(e, storage)
		store(e, v.atomic_type, emit_expr(e, v.bound[1]), expected)
		store(e, v.atomic_type, emit_expr(e, v.bound[2]), desired)
		status, swapped := temp(e), temp(e)
		// The helper writes the observed value back into `expected`, which is what
		// a failed compare-exchange has to report.
		fmt.sbprintfln(
			&e.b,
			"  %s = call i32 @loke_rt_v1_atomic128_compare_exchange(ptr %s, ptr %s, ptr %s, i32 %d, i32 %d)",
			status, address, expected, desired, int(order), v.atomic_failure_order,
		)
		fmt.sbprintfln(&e.b, "  %s = icmp ne i32 %s, 0", swapped, status)
		observed := load(e, storage, expected)
		return emit_atomic_exchange_result(e, v, storage, observed, swapped)
	}

	value := alloca(e, storage)
	store(e, v.atomic_type, emit_expr(e, v.bound[1]), value)
	fmt.sbprintfln(
		&e.b, "  call void @loke_rt_v1_atomic128_%s(ptr %s, ptr %s, ptr %s, i32 %d)",
		helper, address, value, out, int(order),
	)
	result := load(e, storage, out)
	return result
}

// design.md: the compare-exchange answers `.none` when it swapped and
// `.some(observed)` when it did not, so a caller cannot read an observed value
// on a path where there was none.
@(private = "file")
emit_atomic_exchange_result :: proc(
	e: ^Emitter,
	v: ^Expr_Call,
	storage: string,
	observed: string,
	swapped: string,
) -> string {
	failed := temp(e)
	fmt.sbprintfln(&e.b, "  %s = xor i1 %s, true", failed, swapped)
	value := atomic_from_storage(e, v.atomic_type, storage, observed)
	return emit_option_value(e, v.type, failed, value)
}

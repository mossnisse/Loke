// Resolved calls, argument packing, conversions, and allocation builtins.
//
// Part of the textual LLVM backend; see compiler-architecture.md.
package lokec

import "core:fmt"

// ------------------------------------------------------------------- calls --

@(private)
emit_call :: proc(e: ^Emitter, v: ^Expr_Call, as_type: Type_Id) -> string {
	switch operation in v.operation {
	case Call_Enum_From_Int:
		value := emit_expr(e, v.bound[0])
		present := "false"
		for member in underlying_info(e.c, operation.type).fields {
			sym := symbol_of(e.c, member)
			matches := temp(e)
			fmt.sbprintfln(&e.b, "  %s = icmp eq %s %s, %s", matches,
				llvm_type(e, operation.type), value, bi_text(e.c, sym.const_value.integer))
			if present == "false" {
				present = matches
			} else {
				joined := temp(e)
				fmt.sbprintfln(&e.b, "  %s = or i1 %s, %s", joined, present, matches)
				present = joined
			}
		}
		return emit_option_value(e, as_type, present, value)
	case Call_Extract:
		return emit_any_view_extract(e, operation.node, operation.node.type)[0]
	case Call_Dyn_Slot:
		results := emit_dyn_slot_call(e, v)
		return len(results) == 0 ? "0" : results[0]
	case Call_Dyn_Conversion:
		return emit_dyn_value(e, v, as_type)
	case Call_Text_Conversion:
		return emit_text_conversion(e, v, as_type)[0]
	case Call_Conversion:
		return emit_conversion(e, v, as_type)
	case Call_Reflect:
		return emit_descriptor_operation(e, v)
	case Call_Union_Construct:
		return emit_union_operation(e, v, as_type)
	case Call_Text:
		return emit_text_operation(e, v, as_type)[0]
	case Call_Procedure:
		results := emit_direct_call(e, v)
		return len(results) == 0 ? "0" : results[0]
	case Call_Builtin, Call_Atomic, Call_Allocation, Call_Sort_By, Call_Simd_Reduce:
		// These intrinsic families retain their exact operation's symbol.
	case nil, Call_Compile_Time:
		backend_fail(e, "an unchecked or compile-time call reached emission")
		return "0"
	}
	symbol := symbol_of(e.c, v.resolution.symbol)
	if symbol != nil && symbol.kind == .Builtin {
		switch symbol.builtin {
		case .Assert:
			// The runtime half of a phase-neutral built-in. design.md makes the
			// message a compile-time string, so it is a module global here and the
			// failure takes the program's panic strategy like every other one.
			cond := emit_expr(e, v.bound[0])
			failed := temp(e)
			fmt.sbprintfln(&e.b, "  %s = xor i1 %s, true", failed, cond)
			panic_if(e, failed, "assert.failed", panic_message_text(e, v, 1, "assertion failed"))
			return "0"
		case .Panic:
			emit_panic(e, panic_message_text(e, v, 0, "explicit panic"))
			return "0"
		case .Default_Allocator:
			// design.md "Build-selected providers": the handle the build selected —
			// the runtime's fallback record until a factory publishes another, and
			// that factory's own handle afterwards.
			return emit_default_allocator(e)
		case .New, .New_Clone:
			return emit_allocation_pair(e, v, symbol.builtin, as_type)[0]
		case .Make:
			return emit_make_container(e, v, as_type)[0]
		case .Drop:
			emit_explicit_drop(e, v)
			return "0"
		case .Exchange:
			return emit_exchange(e, v, as_type)
		case .Unsafe_Raw_Data, .Unsafe_String_View, .Unsafe_C_String_View:
			return emit_unsafe_builtin(e, v, symbol.builtin, as_type)[0]
		case .Unsafe_Transmute:
			return emit_transmute(e, v, as_type)
		case .Unsafe_Take:
			// The value leaves; the storage keeps the bits nobody may read again.
			return load_place(e, as_type, emit_address(e, v.bound[0]))
		case .Unsafe_Write:
			// A store and nothing else: the storage held no value, so there is
			// nothing there to drop first. The value still arrives the way any
			// initialization takes it -- a place keeps its own value and the storage
			// receives a clone, a temporary or a `move` hands ownership over.
			written := expr_base(v.bound[0]).type
			address := emit_address(e, v.bound[0])
			value := emit_expr(e, v.bound[1])
			if emit_lifecycle(e, written).managed && expression_is_borrowed_place(e.c, v.bound[1]) {
				value = emit_clone_value(e, written, value)
			}
			store(e, written, value, address)
			return "0"
		case .Unsafe_Forget:
			// The feature's whole meaning is the call that is *not* made: the operand
			// is evaluated for its side effects, but skips the `emit_discarded_temporary`
			// an owned temporary would otherwise get. A `move(place)` operand still
			// zeroes and kills its source through `emit_move`, like any other transfer.
			emit_expr(e, v.bound[0])
			return "0"
		case .Type_Info_Of:
			return emit_type_info_of(e, v)
		case .Fmt_Stdout_Writer, .Fmt_Stderr_Writer, .Fmt_Write_Bytes, .Fmt_Format_Any:
			return emit_fmt_builtin(e, v, symbol.builtin)
		case .Strings_Allocate:
			return emit_strings_allocate(e, v, as_type)[0]
		case .Slice_Sort_By:
			emit_slice_sort_by(e, v)
			return "0"
		case .Atomic_Load, .Atomic_Store, .Atomic_Exchange, .Atomic_Compare_Exchange,
		     .Atomic_Add, .Atomic_Sub, .Atomic_And, .Atomic_Or, .Atomic_Xor, .Atomic_Fence:
			return emit_atomic_builtin(e, v, symbol.builtin, as_type)
		case .Simd_Cast, .Simd_Select, .Simd_Reduce:
			return emit_simd_builtin(e, v, symbol.builtin, as_type)
		case .Free, .Unsafe_Free:
			emit_free(e, v)
			return "0"
		case .Free_All:
			emit_region_reset(e, v)
			return "0"
		case .None, .Size_Of, .Align_Of, .Offset_Of, .Is_Copyable,
		     .Static_Assert, .Build_Config, .Source_Location, .Caller_Location,
		     .Type_Of, .Typeid_Of, .Fields_Of, .Enum_Values_Of:
			// These fold to a constant in every reachable case; arriving here
			// would mean emitting a runtime call for a layout query.
			backend_fail(e, "an unfrozen compile-time built-in reached emission")
			return "0"
		}
	}
	backend_fail(e, "an intrinsic call has no builtin symbol")
	return "0"
}

// `field.get(value)` and `field.pointer(value)`. The descriptor selected one
// field at check time, so both are an ordinary member address, plus a load for
// `get`.
@(private = "file")
emit_descriptor_operation :: proc(e: ^Emitter, v: ^Expr_Call) -> string {
	checked := v.operation.(Call_Reflect)
	base := emit_expr(e, v.bound[0])
	owner := underlying_info(e.c, expr_base(v.bound[0]).type)
	field := symbol_of(e.c, checked.field)
	address := gep_field(e, llvm_type(e, owner.element), base, int(field.index))
	if checked.op == .Field_Pointer {
		return address
	}
	out := load(e, llvm_type(e, field.type), address)
	return out
}

emit_hash_value :: proc(e: ^Emitter, type: Type_Id, value, seed: string) -> string {
	under := type_underlying(e.c, type)
	info := type_of(e.c, under)
	if info != nil && info.kind == .Array {
		current := seed
		for index in 0 ..< int(info.count) {
			element := extract(e, llvm_type(e, under), value, index)
			current = emit_hash_value(e, info.element, element, current)
		}
		return current
	}
	// design.md: `string` and `string_view` hash byte-wise, which is the coherent
	// partner of the byte-wise `==` they already have.
	if type_is_utf8_text(e.c, under) {
		storage := llvm_type(e, under)
		data := extract(e, storage, value, STRING_DATA)
		length := extract(e, storage, value, STRING_LEN)
		out := temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call i64 @loke_rt_v1_hash_bytes(ptr %s, i64 %s, i64 %s)",
			out, data, length, seed,
		)
		return out
	}
	bits := emit_hash_bits(e, under, value)
	mixed := temp(e)
	fmt.sbprintfln(&e.b, "  %s = xor i64 %s, %s", mixed, seed, bits)
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = mul i64 %s, %d", out, mixed, HASH_MULTIPLIER)
	return out
}

// One scalar's 64-bit integer image.
@(private = "file")
emit_hash_bits :: proc(e: ^Emitter, under: Type_Id, value: string) -> string {
	info := type_of(e.c, under)
	out := temp(e)
	#partial switch info.kind {
	case .Bool:
		fmt.sbprintfln(&e.b, "  %s = zext i1 %s to i64", out, value)
	case .Raw_Pointer, .Pointer, .C_Pointer, .Proc:
		fmt.sbprintfln(&e.b, "  %s = ptrtoint ptr %s to i64", out, value)
	case .Float:
		// design.md: `+0` and `-0` hash identically because they compare equal.
		llvm := llvm_type(e, under)
		pattern := temp(e)
		width := int(info.bits)
		fmt.sbprintfln(&e.b, "  %s = bitcast %s %s to i%d", pattern, llvm, value, width)
		widened := pattern
		if width < 64 {
			widened = temp(e)
			fmt.sbprintfln(&e.b, "  %s = zext i%d %s to i64", widened, width, pattern)
		}
		zero := temp(e)
		fmt.sbprintfln(&e.b, "  %s = fcmp oeq %s %s, 0.0", zero, llvm, value)
		fmt.sbprintfln(&e.b, "  %s = select i1 %s, i64 0, i64 %s", out, zero, widened)
	case:
		width := type_bits(e.c, under)
		if info.kind == .Rune {
			width = 32
		}
		switch {
		case width == 64:
			return value
		case width > 64:
			fmt.sbprintfln(&e.b, "  %s = trunc i%d %s to i64", out, width, value)
		case type_signed(e.c, under) || info.kind == .Rune:
			fmt.sbprintfln(&e.b, "  %s = sext i%d %s to i64", out, width, value)
		case:
			fmt.sbprintfln(&e.b, "  %s = zext i%d %s to i64", out, width, value)
		}
	}
	return out
}

// An operator, index, or slice call. Operator lookup has already chosen one
// named procedure, so this is an ordinary direct call — except for a `delegate`
// overload, which has no body and applies the underlying type's operation to the
// unwrapped operands instead.
@(private)
emit_operator_call :: proc(e: ^Emitter, symbol_id: Symbol_Id, bound: []Expr) -> string {
	symbol := symbol_of(e.c, symbol_id)
	if symbol == nil {
		return "0"
	}
	if symbol.delegated {
		return emit_delegated(e, symbol, bound)
	}
	info := type_of(e.c, symbol.proc_type)
	results := emit_bound_call(e, symbol_id, symbol_name(e, symbol_id), info, bound)
	return len(results) == 0 ? "0" : results[0]
}

// A `distinct` newtype's forwarding overload: unwrap, apply the underlying
// operation, and let the wrap back into the distinct type be the no-op it is —
// the two share a representation.
@(private = "file")
emit_delegated :: proc(e: ^Emitter, symbol: ^Symbol, bound: []Expr) -> string {
	// The underlying type's own overload takes the operands as they stand: a
	// distinct type and what it wraps lower to one LLVM type, so unwrapping is
	// the no-op the representation already makes it.
	if symbol.delegate_target != INVALID_SYMBOL {
		return emit_operator_call(e, symbol.delegate_target, bound)
	}
	op := operator_token(symbol.operator)
	underlying := symbol.delegate_underlying
	if len(bound) == 1 {
		out := temp(e)
		fmt.sbprintfln(&e.b, "  %s = xor i1 %s, true", out, emit_expr(e, bound[0]))
		return out
	}
	lhs := emit_expr(e, bound[0])
	rhs := emit_expr(e, bound[1])
	#partial switch op {
	case .Eq_Eq, .Not_Eq, .Lt, .Lt_Eq, .Gt, .Gt_Eq:
		return emit_compare(e, op, underlying, lhs, rhs)
	}
	return emit_binary_op(e, op, underlying, underlying, lhs, rhs)
}

// The value of a producer whose lowering is not the ordinary `emit_expr` one:
// an extraction, a slot call, an allocation, a container `make`, a text
// operation, an `or_else`, or an `or_return`. Each of those has its own
// sequence; this is the one place that picks between them.
@(private)
emit_producer_value :: proc(e: ^Emitter, expr: Expr, as_type: Type_Id) -> []string {
	#partial switch v in expr {
	case ^Expr_Call:
		#partial switch operation in v.operation {
		case Call_Extract:
			return emit_any_view_extract(e, operation.node, operation.node.type)
		case Call_Dyn_Slot:
			return emit_dyn_slot_call(e, v)
		case Call_Allocation:
			kind := call_builtin_kind(e, v)
			if kind == .Make { return emit_make_container(e, v, as_type) }
			return emit_allocation_pair(e, v, kind, as_type)
		case Call_Text:
			return emit_text_operation(e, v, as_type)
		case Call_Text_Conversion:
			return emit_text_conversion(e, v, as_type)
		}
		if kind := call_builtin_kind(e, v); kind == .Unsafe_String_View {
			return emit_unsafe_builtin(e, v, kind, as_type)
		}
		if call_builtin_kind(e, v) == .Strings_Allocate {
			return emit_strings_allocate(e, v, as_type)
		}
		single := make([]string, 1)
		single[0] = emit_expr_at(e, expr, as_type)
		return single
	case ^Expr_Checked_Extract:
		return emit_any_view_extract(e, v, as_type)
	case ^Expr_Or_Else:
		return emit_or_else(e, v)
	case ^Expr_Postfix:
		if v.op == .Or_Return {
			return emit_or_return(e, v)
		}
	}
	single := make([]string, 1)
	single[0] = emit_expr_at(e, expr, as_type)
	return single
}

@(private)
call_builtin_kind :: proc(e: ^Emitter, v: ^Expr_Call) -> Builtin_Kind {
	#partial switch _ in v.operation {
	case Call_Builtin, Call_Atomic, Call_Allocation, Call_Sort_By, Call_Simd_Reduce:
		sym := symbol_of(e.c, v.resolution.symbol)
		return sym != nil && sym.kind == .Builtin ? sym.builtin : Builtin_Kind.None
	case:
		return .None
	}
}

// `new` and `new_clone` always return an error instead of invoking the allocator
// failure policy (design.md "Allocation failure"), so there is no policy branch
// here — the caller gets a null pointer and a non-nil error and decides.
@(private = "file")
emit_allocation_pair :: proc(e: ^Emitter, v: ^Expr_Call, kind: Builtin_Kind, as_type: Type_Id) -> []string {
	checked := v.operation.(Call_Allocation)
	// `new_clone` creates a new allocation root containing a clone of the value
	// (design.md), so a record whose clone can fail goes through its hook rather
	// than through a shallow store of the representation.
	if kind == .New_Clone && emit_lifecycle(e, checked.type).clone_fallible {
		return emit_new_clone_hook(e, v, as_type)
	}
	// `new(T)` binds only an allocator; `new_clone(v)` binds the value first.
	allocator := emit_allocator_operand(e, v, kind == .New ? 0 : 1)
	size, align := type_size(e.c, checked.type), type_align(e.c, checked.type)
	pointer := temp(e)
	if kind == .New {
		// design.md: `new` zero-initialises.
		fmt.sbprintfln(
			&e.b, "  %s = call ptr @loke_rt_v1_alloc_zeroed(ptr %s, i64 %d, i64 %d)",
			pointer, allocator, size, align,
		)
	} else {
		fmt.sbprintfln(
			&e.b, "  %s = call ptr @loke_rt_v1_alloc(ptr %s, i64 %d, i64 %d)",
			pointer, allocator, size, align,
		)
	}
	failed := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq ptr %s, null", failed, pointer)

	if kind == .New_Clone {
		// A failed allocation has nothing to clone into, so the copy is guarded. This
		// arm only runs for a value whose clone is the copy its representation
		// already is, so nothing is left partially built on that path.
		store_label, done_label := new_label(e, "newclone.store"), new_label(e, "newclone.done")
		fmt.sbprintfln(&e.b, "  br i1 %s, label %%%s, label %%%s", failed, done_label, store_label)
		place_label(e, store_label)
		store(e, checked.type, emit_expr(e, v.bound[0]), pointer)
		branch(e, done_label)
		place_label(e, done_label)
		e.terminated = false
	}

	out := make([]string, 1)
	out[0] = emit_alloc_result(e, as_type, failed, pointer)
	return out
}

// The clone-through-a-hook half of `new_clone`, and the only path with a
// partially cloned allocation to destroy: the hook already cleaned its own
// temporary, leaving only the block it was going to be published into. The
// result travels through storage rather than phi nodes, so the three exits
// need no predecessor-label tracking.
@(private = "file")
emit_new_clone_hook :: proc(e: ^Emitter, v: ^Expr_Call, as_type: Type_Id) -> []string {
	checked := v.operation.(Call_Allocation)
	value := emit_expr(e, v.bound[0])
	allocator := emit_allocator_operand(e, v, 1)
	size, align := type_size(e.c, checked.type), type_align(e.c, checked.type)

	pointer_slot := alloca(e, "ptr")
	error_slot := alloca(e, "i64")
	fmt.sbprintfln(&e.b, "  store ptr null, ptr %s", pointer_slot)
	fmt.sbprintfln(&e.b, "  store i64 1, ptr %s", error_slot)

	pointer := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = call ptr @loke_rt_v1_alloc(ptr %s, i64 %d, i64 %d)",
		pointer, allocator, size, align,
	)
	no_memory := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq ptr %s, null", no_memory, pointer)
	clone_label := new_label(e, "newclone.clone")
	done_label := new_label(e, "newclone.done")
	branch_if(e, no_memory, done_label, clone_label)

	place_label(e, clone_label)
	hook := emit_lifecycle(e, checked.type).try_clone
	if hook == INVALID_SYMBOL {
		backend_fail(e, "a fallible `new_clone` has no `try_clone` member")
		failed := make([]string, 1)
		failed[0] = "zeroinitializer"
		return failed
	}
	clone_result := symbol_of(e.c, hook).result
	receiver_type, receiver := call_receiver_operand(e, hook, checked.type, value)
	returned := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = call %s %s(%s %s, ptr %s)",
		returned, llvm_type(e, clone_result), symbol_name(e, hook), receiver_type, receiver, allocator,
	)
	clone_slot := emit_union_spill(e, clone_result, returned)
	failed := emit_union_failed(e, clone_result, returned)
	cloned := emit_union_payload(e, clone_result, checked.type, clone_slot)
	release_label, publish_label := new_label(e, "newclone.release"), new_label(e, "newclone.publish")
	branch_if(e, failed, release_label, publish_label)

	place_label(e, release_label)
	fmt.sbprintfln(
		&e.b, "  call void @loke_rt_v1_free(ptr %s, ptr %s, i64 %d, i64 %d)",
		allocator, pointer, size, align,
	)
	fmt.sbprintfln(&e.b, "  store i64 1, ptr %s", error_slot)
	branch(e, done_label)

	place_label(e, publish_label)
	store(e, checked.type, cloned, pointer)
	fmt.sbprintfln(&e.b, "  store ptr %s, ptr %s", pointer, pointer_slot)
	fmt.sbprintfln(&e.b, "  store i64 0, ptr %s", error_slot)
	branch(e, done_label)

	place_label(e, done_label)
	e.terminated = false
	published, code, broke := temp(e), temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = load ptr, ptr %s", published, pointer_slot)
	fmt.sbprintfln(&e.b, "  %s = load i64, ptr %s", code, error_slot)
	fmt.sbprintfln(&e.b, "  %s = icmp ne i64 %s, 0", broke, code)
	out := make([]string, 1)
	out[0] = emit_alloc_result(e, as_type, broke, published)
	return out
}

// `make(T, counts..., allocator)`. The checker bound the counts in written
// order followed by the allocator, so this only has to run them.
//
// The header is built in storage and published complete: the provider handle is
// written first because the reserve below allocates *through* it, so a failed
// reserve leaves an empty container bound to that provider rather than
// something half-built.
@(private = "file")
emit_make_container :: proc(e: ^Emitter, v: ^Expr_Call, as_type: Type_Id) -> []string {
	checked := v.operation.(Call_Allocation)
	is_map := type_is_map(e.c, checked.type)
	counts := is_map ? 1 : 2
	values := make([]string, counts)
	for index in 0 ..< counts {
		values[index] = v.bound[index] == nil ? "" : emit_expr(e, v.bound[index])
	}
	allocator := v.bound[counts] == nil ? emit_default_allocator(e) : emit_expr(e, v.bound[counts])

	header := alloca(e, CONTAINER_TYPE)
	fmt.sbprintfln(&e.b, "  store %s zeroinitializer, ptr %s", CONTAINER_TYPE, header)
	provider := gep_field(e, CONTAINER_TYPE, header, CONTAINER_ALLOC)
	fmt.sbprintfln(&e.b, "  store ptr %s, ptr %s", allocator, provider)

	// design.md: `cap` defaults to `len`, and a `len > cap` relationship is an
	// ordinary program fault rather than an allocation failure.
	length := values[0] == "" ? "0" : values[0]
	capacity := length
	if !is_map && len(values) > 1 && values[1] != "" {
		capacity = values[1]
		bad := temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp sgt i64 %s, %s", bad, length, capacity)
		panic_if(e, bad, "make.len_gt_cap", "a container's length cannot exceed its capacity")
	}
	negative := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp slt i64 %s, 0", negative, length)
	panic_if(e, negative, "make.negative", "a container's length cannot be negative")

	helper := is_map ? "loke_rt_v1_map_reserve" : "loke_rt_v1_dyn_reserve"
	status := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = call i32 @%s(ptr %s, ptr %s, i64 %s)",
		status, helper, header, container_ops_global(e, checked.type), capacity,
	)
	failed := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq i32 %s, 0", failed, status)
	fill_label, done_label := new_label(e, "make.fill"), new_label(e, "make.done")
	branch_if(e, failed, done_label, fill_label)

	// A dynamic array's initial length is `len` zero values. Every Loke zero
	// value is all-zero bits, so this is one memset rather than a per-element
	// loop, and dropping those zeros is the no-op every hook must already handle.
	place_label(e, fill_label)
	if !is_map {
		element := container_element(e.c, checked.type)
		data := load(e, "ptr", header)
		bytes := temp(e)
		fmt.sbprintfln(&e.b, "  %s = mul i64 %s, %d", bytes, length, type_size(e.c, element))
		fmt.sbprintfln(&e.b, "  call void @llvm.memset.p0.i64(ptr %s, i8 0, i64 %s, i1 false)", data, bytes)
		count_slot := gep_field(e, CONTAINER_TYPE, header, CONTAINER_LEN)
		fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", length, count_slot)
	}
	branch(e, done_label)
	place_label(e, done_label)
	e.terminated = false

	built := temp(e)
	fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", built, CONTAINER_TYPE, header)
	out := make([]string, 1)
	out[0] = emit_alloc_result(e, as_type, failed, built)
	return out
}

// Deallocation operations such as `free` and `drop` return no status (design.md).
// The checker restricts the operand to a binding holding a fresh allocation
// base, so the pointee type supplies the size and alignment given at `new`.
//
// The allocator is the written one, or the default provider when it was
// omitted; design.md makes matching the creating allocator the program's
// obligation either way. An arena allocation is normally released by that
// region's reset instead.
@(private = "file")
emit_free :: proc(e: ^Emitter, v: ^Expr_Call) {
	pointer := emit_expr(e, v.bound[0])
	allocator := emit_allocator_operand(e, v, 1)
	info := underlying_info(e.c, expr_base(v.bound[0]).type)
	if info == nil || info.kind != .Pointer {
		backend_fail(e, "`free` did not receive an allocation pointer")
		return
	}
	fmt.sbprintfln(
		&e.b, "  call void @loke_rt_v1_free(ptr %s, ptr %s, i64 %d, i64 %d)",
		allocator, pointer, type_size(e.c, info.element), type_align(e.c, info.element),
	)
}

// Whether this union value holds its designated failure variant.
@(private)
emit_union_failed :: proc(e: ^Emitter, union_type: Type_Id, value: string) -> string {
	info := type_of(e.c, type_underlying(e.c, union_type))
	shape := union_layout(e.c, union_type)
	tag := emit_union_tag(e, union_type, value)
	out := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = icmp eq i%d %s, %d",
		out, shape.tag_bytes * 8, tag, info.failure_variant,
	)
	return out
}

// The checker accepts the same implicit assignment conversions for propagated
// failures as for an ordinary destination. Most preserve the LLVM
// representation; the two erased/view conversions need explicit construction
// because `or_return` has an extracted SSA value, not an expression node for
// `materialize` to annotate.
@(private = "file")
emit_failure_conversion :: proc(e: ^Emitter, value: string, from, into: Type_Id, source_address := "") -> string {
	if from == into || value == "" {
		return value
	}
	if underlying_kind(e.c, from) == .String && underlying_kind(e.c, into) == .String_View {
		data := extract(e, STRING_TYPE, value, STRING_DATA)
		length := extract(e, STRING_TYPE, value, STRING_LEN)
		return emit_ptr_len(e, STRING_VIEW_TYPE, data, length)
	}
	if into == TYPE_ANY_VIEW {
		concrete := any_view_source_type(e.c, from)
		slot := source_address
		if slot == "" {
			slot = alloca(e, llvm_type(e, concrete))
			store(e, concrete, value, slot)
		}
		return emit_any_view_value(e, slot, concrete)
	}
	// Carrier weakening, procedure escape weakening, checked/C-pointer
	// interchange, and pointer-to-rawptr all share one backend representation.
	return value
}

// design.md "or_else expression": the fallback is evaluated only when the
// operand holds its failure variant, which is why it lives in its own block.
@(private = "file")
emit_or_else :: proc(e: ^Emitter, v: ^Expr_Or_Else) -> []string {
	operand_type := type_underlying(e.c, expr_base(v.value).type)
	info := type_of(e.c, operand_type)
	success := 1 - info.failure_variant
	payload_type := info.variants[success]

	value := emit_expr(e, v.value)
	slot := emit_union_spill(e, operand_type, value)

	entry := new_label(e, "orelse.entry")
	success_label := new_label(e, "orelse.success")
	fallback_label := new_label(e, "orelse.fallback")
	done := new_label(e, "orelse.done")
	branch(e, entry)
	place_label(e, entry)
	failed := emit_union_failed(e, operand_type, value)
	branch_if(e, failed, fallback_label, success_label)

	// The success payload is read only on the path where it is the active one.
	place_label(e, success_label)
	taken := emit_union_payload(e, operand_type, payload_type, slot)
	// A place keeps owning what it holds, so what leaves is a copy of it. A
	// trivially copied payload is already its own copy.
	if v.borrows && emit_lifecycle(e, payload_type).managed {
		taken = emit_clone_value(e, payload_type, taken)
	}
	success_exit := new_label(e, "orelse.success.exit")
	branch(e, success_exit)
	place_label(e, success_exit)
	branch(e, done)

	place_label(e, fallback_label)
	// design.md: `or_else` never copies the error, so a managed failure payload of
	// a *temporary* is dropped here, before the fallback runs, since the operand's
	// value is discarded on this path. A place still owns its own.
	if failure_type := info.variants[info.failure_variant];
	   !v.borrows && emit_lifecycle(e, failure_type).managed {
		emit_drop_place(e, failure_type, gep_field(e, llvm_type(e, operand_type), slot, 0))
	}
	fallback := emit_expr(e, v.fallback)
	if v.fallback_clone {
		fallback = emit_clone_value(e, payload_type, fallback)
	}
	fallback_exit := new_label(e, "orelse.fallback.exit")
	branch(e, fallback_exit)
	place_label(e, fallback_exit)
	branch(e, done)

	place_label(e, done)
	joined := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = phi %s [ %s, %%%s ], [ %s, %%%s ]",
		joined, llvm_type(e, payload_type), taken, success_exit, fallback, fallback_exit,
	)
	out := make([]string, 1)
	out[0] = joined
	return out
}

// design.md "or_return operator": on failure the operand's error payload is
// rewrapped as the enclosing procedure's failure variant and control leaves
// through the ordinary epilogue, so `defer` ordering stays in one
// implementation.
@(private = "file")
emit_or_return :: proc(e: ^Emitter, v: ^Expr_Postfix) -> []string {
	operand_type := type_underlying(e.c, expr_base(v.operand).type)
	info := type_of(e.c, operand_type)
	success := 1 - info.failure_variant
	operand_address := ""
	value := ""
	if v.borrows {
		// A place is evaluated once and retained as an address. Borrowing failure
		// conversions such as `T -> any_view` must point into that proven-live
		// source rather than into the temporary union spill below.
		operand_address = emit_address(e, v.operand)
		value = load(e, llvm_type(e, operand_type), operand_address)
	} else {
		value = emit_expr(e, v.operand)
	}
	slot := emit_union_spill(e, operand_type, value)
	failed := emit_union_failed(e, operand_type, value)

	fail_label := new_label(e, "orreturn.fail")
	ok_label := new_label(e, "orreturn.ok")
	branch_if(e, failed, fail_label, ok_label)

	place_label(e, fail_label)
	if e.result_slot != "" {
		target := type_underlying(e.c, e.result_type)
		target_info := type_of(e.c, target)
		// `or_return` constructs the enclosing error directly: the operand's error
		// payload is moved into the new variant without a second clone.
		error := ""
		if failure_type := info.variants[info.failure_variant]; failure_type != TYPE_VOID {
			error = emit_union_payload(e, operand_type, failure_type, slot)
			// A place keeps its value, so the error the caller sees is a copy.
			failure_into := target_info.variants[target_info.failure_variant]
			if v.borrows && emit_lifecycle(e, failure_type).managed &&
			   !failure_assignment_borrows(e.c, failure_type, failure_into) {
				error = emit_clone_value(e, failure_type, error)
			}
			source_address := ""
			if v.borrows && failure_assignment_borrows(e.c, failure_type, failure_into) {
				source_address = gep_field(e, llvm_type(e, operand_type), operand_address, 0)
			}
			error = emit_failure_conversion(e, error, failure_type, failure_into, source_address)
		}
		wrapped := emit_union_value(e, e.result_type, target_info.failure_variant, error)
		store(e, e.result_type, wrapped, e.result_slot)
	}
	emit_epilogue(e)

	place_label(e, ok_label)
	out := make([]string, 1)
	if info.variants[success] == TYPE_VOID {
		// A payloadless success yields `Unit`, which is zero-sized.
		out[0] = "zeroinitializer"
		return out
	}
	out[0] = emit_union_payload(e, operand_type, info.variants[success], slot)
	if v.borrows && emit_lifecycle(e, info.variants[success]).managed {
		out[0] = emit_clone_value(e, info.variants[success], out[0])
	}
	return out
}

// Emits the call and returns its one result operand, or nothing.
@(private = "file")
emit_direct_call :: proc(e: ^Emitter, v: ^Expr_Call) -> []string {
	callee_type := underlying_info(e.c, expr_base(v.callee).type)
	symbol := symbol_of(e.c, v.resolution.symbol)

	callee := ""
	if symbol != nil && symbol.kind == .Proc {
		callee = symbol_name(e, v.resolution.symbol)
	} else {
		callee = emit_expr(e, v.callee)
		// A procedure value may be nil; the call takes the same trap seam every
		// other defined runtime failure does.
		is_nil := temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp eq ptr %s, null", is_nil, callee)
		panic_if(e, is_nil, "nil.call", "call through a nil procedure value")
	}

	return emit_bound_call(e, v.resolution.symbol, callee, callee_type, v.bound, v)
}

// design.md "Variadic parameters": the callee always receives one read-only
// slice, so the caller either forwards a compatible spread as-is or builds
// compiler-owned contiguous storage and hands over a slice of it. That storage
// is a stack buffer — fixed-size when the element count is static, a checked
// dynamic `alloca` when a spread makes it runtime-sized. A pack is a borrow of
// that buffer, so it never involves a dynamic array.
@(private = "file")
Variadic_Pack :: struct {
	value:   string,
	cleanup: Deferred,
}

@(private = "file")
checked_variadic_total :: proc(e: ^Emitter, total, added: string) -> string {
	negative := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp slt i64 %s, 0", negative, added)
	panic_if(e, negative, "variadic.length", "invalid variadic spread length")
	sum := temp(e)
	fmt.sbprintfln(&e.b, "  %s = add i64 %s, %s", sum, total, added)
	overflow := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp ult i64 %s, %s", overflow, sum, total)
	panic_if(e, overflow, "variadic.size", "variadic argument pack is too large")
	return sum
}

@(private = "file")
emit_variadic_pack :: proc(e: ^Emitter, v: ^Expr_Call, pack_type: Type_Id) -> Variadic_Pack {
	// A sole compatible spread forwards its slice directly, which is what makes
	// `println(..args)` inside a variadic procedure cost nothing.
	if v.variadic_forwards {
		return Variadic_Pack{value = emit_expr(e, v.bound[v.variadic_slot])}
	}
	element := slice_element(e.c, pack_type)
	element_llvm := llvm_type(e, element)
	static_count := len(v.variadic_elements)
	if len(v.variadic_spreads) == 0 && static_count == 0 {
		// design.md's `sum()` case: an empty pack is a nil slice, which has length
		// 0 and points at no storage.
		return Variadic_Pack{value = "zeroinitializer"}
	}
	managed := emit_lifecycle(e, element).managed

	// Managed explicit operands first enter fixed staging storage. That storage
	// is already registered while later operands are evaluated, so a panic cannot
	// strand an owned temporary before the runtime-sized final buffer exists.
	staging, staging_flags, staging_count := "", "", ""
	staging_cleanup := Deferred{slot = -1}
	if managed && static_count > 0 {
		staging, staging_flags, staging_count = temp(e), temp(e), temp(e)
		alloca_named(e, staging, fmt.aprintf("[%d x %s]", static_count, element_llvm))
		alloca_named(e, staging_flags, fmt.aprintf("[%d x i1]", static_count))
		fmt.sbprintfln(
			&e.b, "  call void @llvm.memset.p0.i64(ptr %s, i8 0, i64 %d, i1 false)",
			staging_flags, static_count,
		)
		alloca_named(e, staging_count, "i64")
		fmt.sbprintfln(&e.b, "  store i64 %d, ptr %s", static_count, staging_count)
		staging_cleanup = register_variadic_cleanup(e, element, staging, staging_flags, staging_count)
	}

	// Every operand is evaluated once, in written order, before any storage is
	// formed: a spread's length is part of the size the buffer needs.
	elements := make([]string, static_count)
	spreads := make([]string, len(v.variadic_spreads))
	spread_data := make([]string, len(v.variadic_spreads))
	spread_len := make([]string, len(v.variadic_spreads))
	next_element, next_spread := 0, 0
	total := fmt.aprintf("%d", static_count)
	for is_spread in v.variadic_order {
		if is_spread {
			expr := v.variadic_spreads[next_spread]
			spreads[next_spread] = emit_expr(e, expr)
			storage := llvm_type(e, expr_base(expr).type)
			data := extract(e, storage, spreads[next_spread], SLICE_DATA)
			length := extract(e, storage, spreads[next_spread], SLICE_LEN)
			spread_data[next_spread], spread_len[next_spread] = data, length
			total = checked_variadic_total(e, total, length)
			next_spread += 1
			continue
		}
		expr := v.variadic_elements[next_element]
		value := emit_expr(e, expr)
		// A borrowed owner is cloned; a temporary or move already owns the value
		// transferred into staging.
		if managed && expression_is_borrowed_place(e.c, expr) {
			value = emit_clone_value(e, element, value)
		}
		elements[next_element] = value
		if managed {
			slot, flag := temp(e), temp(e)
			fmt.sbprintfln(
				&e.b, "  %s = getelementptr inbounds [%d x %s], ptr %s, i64 0, i64 %d",
				slot, static_count, element_llvm, staging, next_element,
			)
			store(e, element, value, slot)
			fmt.sbprintfln(&e.b, "  %s = getelementptr i1, ptr %s, i64 %d", flag, staging_flags, next_element)
			fmt.sbprintfln(&e.b, "  store i1 true, ptr %s", flag)
		}
		next_element += 1
	}

	buffer := temp(e)
	if len(v.variadic_spreads) == 0 {
		alloca_named(e, buffer, fmt.aprintf("[%d x %s]", static_count, element_llvm))
	} else {
		limit := u64(max(i64)) / max(type_size(e.c, element), 1)
		too_large := temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp ugt i64 %s, %d", too_large, total, limit)
		panic_if(e, too_large, "variadic.size", "variadic argument pack is too large")
		alloca_count(e, buffer, element_llvm, total)
	}
	final_flags, final_count := "", ""
	cleanup := Deferred{slot = -1}
	if managed {
		final_flags, final_count = temp(e), temp(e)
		alloca_count(e, final_flags, "i1", total)
		fmt.sbprintfln(&e.b, "  call void @llvm.memset.p0.i64(ptr %s, i8 0, i64 %s, i1 false)", final_flags, total)
		alloca_named(e, final_count, "i64")
		fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", total, final_count)
		cleanup = register_variadic_cleanup(e, element, buffer, final_flags, final_count)
	}

	cursor := "0"
	cursor_slot := ""
	if managed {
		cursor_slot = temp(e)
		alloca_named(e, cursor_slot, "i64")
		fmt.sbprintfln(&e.b, "  store i64 0, ptr %s", cursor_slot)
	}
	next_element, next_spread = 0, 0
	for is_spread in v.variadic_order {
		if managed {
			if is_spread {
				index_slot := alloca(e, "i64")
				fmt.sbprintfln(&e.b, "  store i64 0, ptr %s", index_slot)
				head, body, done := new_label(e, "vararg.copy.head"), new_label(e, "vararg.copy.body"), new_label(e, "vararg.copy.done")
				branch(e, head)
				place_label(e, head)
				index := load(e, "i64", index_slot)
				more := temp(e)
				fmt.sbprintfln(&e.b, "  %s = icmp ult i64 %s, %s", more, index, spread_len[next_spread])
				branch_if(e, more, body, done)
				place_label(e, body)
				source := gep_at(e, element_llvm, spread_data[next_spread], index)
				loaded := load(e, element_llvm, source)
				cloned := emit_clone_value(e, element, loaded)
				position := load(e, "i64", cursor_slot)
				destination := gep_at(e, element_llvm, buffer, position)
				store(e, element, cloned, destination)
				flag := temp(e)
				fmt.sbprintfln(&e.b, "  %s = getelementptr i1, ptr %s, i64 %s", flag, final_flags, position)
				fmt.sbprintfln(&e.b, "  store i1 true, ptr %s", flag)
				next_index, next_position := temp(e), temp(e)
				fmt.sbprintfln(&e.b, "  %s = add i64 %s, 1", next_index, index)
				fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", next_index, index_slot)
				fmt.sbprintfln(&e.b, "  %s = add i64 %s, 1", next_position, position)
				fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", next_position, cursor_slot)
				branch(e, head)
				place_label(e, done)
				next_spread += 1
				continue
			}
			position := load(e, "i64", cursor_slot)
			destination := gep_at(e, element_llvm, buffer, position)
			source := temp(e)
			fmt.sbprintfln(
				&e.b, "  %s = getelementptr inbounds [%d x %s], ptr %s, i64 0, i64 %d",
				source, static_count, element_llvm, staging, next_element,
			)
			loaded := load(e, element_llvm, source)
			store(e, element, loaded, destination)
			final_flag, staging_flag := temp(e), temp(e)
			fmt.sbprintfln(&e.b, "  %s = getelementptr i1, ptr %s, i64 %s", final_flag, final_flags, position)
			fmt.sbprintfln(&e.b, "  store i1 true, ptr %s", final_flag)
			fmt.sbprintfln(&e.b, "  %s = getelementptr i1, ptr %s, i64 %d", staging_flag, staging_flags, next_element)
			fmt.sbprintfln(&e.b, "  store i1 false, ptr %s", staging_flag)
			next_position := temp(e)
			fmt.sbprintfln(&e.b, "  %s = add i64 %s, 1", next_position, position)
			fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", next_position, cursor_slot)
			next_element += 1
			continue
		}
		slot := gep_at(e, element_llvm, buffer, cursor)
		if is_spread {
			bytes := temp(e)
			fmt.sbprintfln(
				&e.b, "  %s = mul i64 %s, %d",
				bytes, spread_len[next_spread], type_size(e.c, element),
			)
			fmt.sbprintfln(
				&e.b, "  call void @llvm.memcpy.p0.p0.i64(ptr %s, ptr %s, i64 %s, i1 false)",
				slot, spread_data[next_spread], bytes,
			)
			advanced := temp(e)
			fmt.sbprintfln(&e.b, "  %s = add i64 %s, %s", advanced, cursor, spread_len[next_spread])
			cursor = advanced
			next_spread += 1
			continue
		}
		store(e, element, elements[next_element], slot)
		advanced := temp(e)
		fmt.sbprintfln(&e.b, "  %s = add i64 %s, 1", advanced, cursor)
		cursor = advanced
		next_element += 1
	}
	if staging_cleanup.array_cleanup {
		unwind_clear(e, staging_cleanup.slot)
	}
	return Variadic_Pack{value = emit_slice_value(e, pack_type, buffer, total), cleanup = cleanup}
}

// The call side of the Windows x64 classification. Operands are already
// evaluated; this materializes each into its ABI register or caller-owned
// temporary, emits the call, and reconstructs the aggregate result the loke
// caller consumes. `loke`-convention calls never reach here.
@(private)
param_is_by_ptr :: proc(info: ^Type_Info, index: int) -> bool {
	return info != nil && index < len(info.param_by_ptr) && info.param_by_ptr[index]
}

@(private)
proc_result_is_inout :: proc(info: ^Type_Info) -> bool {
	return info != nil && info.result_inout
}

// design.md "Container insertion": the argument through which a container
// insertion takes a move-only element, or -1. Such an element is handed over
// rather than lent, so the caller registers no cleanup for it.
@(private = "file")
consumed_element_slot :: proc(e: ^Emitter, symbol: ^Symbol) -> int {
	if symbol == nil || len(symbol.params) == 0 {
		return -1
	}
	slot := -1
	#partial switch symbol.container_op {
	case .Append:
		slot = 1
	case .Insert, .Map_Find_Or_Insert, .Map_Try_Insert:
		slot = 2
	case:
		return -1
	}
	if !emit_lifecycle(e, container_element(e.c, symbol.params[0])).clone_disabled {
		return -1
	}
	return slot
}

// The shared call sequence: bind the operands left to right, emit the call, and
// hand back one operand per result.
@(private = "file")
emit_bound_call :: proc(
	e: ^Emitter,
	symbol_id: Symbol_Id,
	callee: string,
	callee_type: ^Type_Info,
	bound: []Expr,
	call_node: ^Expr_Call = nil,
) -> []string {
	symbol := symbol_of(e.c, symbol_id)
	if callee_type == nil {
		return nil
	}
	// Arguments are bound left to right. A default that names a parameter to its
	// left reads the value bound a moment ago, which is why this map exists.
	outer_params := e.param_values
	e.param_values = make(map[Symbol_Id]string)
	defer {
		delete(e.param_values)
		e.param_values = outer_params
	}

	operands := make([]string, len(bound))
	// design.md "Variadic parameters": the pack is materialised where it appears
	// in the argument order, so the explicit arguments and the spreads are
	// evaluated exactly once, left to right, together with the fixed ones.
	pack := -1
	if call_node != nil && call_node.is_variadic {
		pack = call_node.variadic_slot
	}
	pack_cleanup := Deferred{slot = -1}
	consumed := consumed_element_slot(e, symbol)
	argument_cleanups := make([dynamic]Deferred)
	defer delete(argument_cleanups)
	handoff_cleanups := make([dynamic]Deferred)
	defer delete(handoff_cleanups)
	// design.md "Evaluation order": supplied operands run in source order and
	// are staged into their matched slots; omitted defaults follow in parameter
	// order. Only the final operand list is parameter-ordered.
	for step in 0 ..< len(bound) {
		index := call_node != nil ? call_slot_at(call_node, step) : step
		argument := bound[index]
		if index == pack {
			packed := emit_variadic_pack(e, call_node, callee_type.parameters[index])
			operands[index] = packed.value
			pack_cleanup = packed.cleanup
			continue
		}
		mode := index < len(callee_type.param_modes) ? callee_type.param_modes[index] : Param_Mode.Value
		if param_mode_is_pointer(mode) {
			operands[index] = emit_address(e, argument)
			if _, composite := argument.(^Expr_Composite); mode == .Borrow && composite {
				// A composite borrowed directly by this call is owned by the
				// complete expression. Ordinary composite construction transfers
				// into its destination and must not register this extra cleanup.
				hold_addressed_temporary(e, argument, callee_type.parameters[index], operands[index])
			}
		} else {
			operands[index] = emit_expr(e, argument)
		}
		// design.md "Parameter semantics and ABI lowering": an ordinary `value: T`
		// parameter is a non-owning borrow, so the callee never cleans one up
		// (`move` is a different, excluded mode). When the argument is an owned
		// temporary rather than somebody else's place, that cleanup belongs to the
		// caller — only the caller can tell the two apart. A C-variadic call passes
		// arguments past the declared parameter list, which have no parameter type
		// to clean up against.
		if mode == .Move && index < len(callee_type.parameters) {
			// The callee owns this value only once the call begins. Until then a
			// later argument can panic, so keep the completed handoff live for unwind.
			entry := hold_temporary_value(e, callee_type.parameters[index], operands[index])
			if entry.place != "" { append(&handoff_cleanups, entry) }
		} else if mode == .Value && index < len(callee_type.parameters) && index != consumed &&
		   !expression_is_borrowed_place(e.c, argument) {
			entry := hold_temporary_value(e, callee_type.parameters[index], operands[index])
			if entry.place != "" { append(&argument_cleanups, entry) }
		}
		// design.md "Receiver forms": an immutable receiver is a borrow of the
		// caller's storage, not a copy of it, so a temporary one is still the
		// caller's to clean up. `emit_address` gave it a slot and registered it in
		// the full-expression frame, which outlives the call whether or not the
		// result borrows it — so the split between a delayed scope drop and a
		// call-local one is gone, and with it the case that dropped a receiver
		// before its enclosing expression finished.
		// design.md: method-call syntax supplies the receiver's `move` marker
		// implicitly, so the source is read and then killed here rather than by an
		// `Expr_Move` the caller wrote.
		if index == 0 && symbol != nil && symbol.receiver == .Move {
			if ident, is_ident := argument.(^Expr_Ident); is_ident {
				kill_place(e, ident.symbol)
			}
		}
		if symbol != nil && index < len(symbol.param_symbols) && symbol.param_symbols[index] != INVALID_SYMBOL {
			e.param_values[symbol.param_symbols[index]] = operands[index]
		}
	}

	// A move-only pack is handed over at the call: from here the callee owns it,
	// and drops whatever it could not store.
	if consumed >= 0 && consumed == pack && pack_cleanup.array_cleanup {
		unwind_clear(e, pack_cleanup.slot)
		pack_cleanup = Deferred{slot = -1}
	}
	// Argument evaluation completed, so ownership now crosses the call boundary.
	// A panic in the callee drops its own `move` parameters, not these guards.
	for entry in handoff_cleanups {
		finish_temporary_drop(e, entry)
	}

	if convention_is_foreign(callee_type.convention) {
		return emit_foreign_call(e, callee, callee_type, operands, symbol, bound)
	}

	result_type := llvm_result_type(e, callee_type.result, callee_type.result_inout)
	call := ""
	if callee_type.result != INVALID_TYPE {
		call = temp(e)
		fmt.sbprintf(&e.b, "  %s = call %s %s(", call, result_type, callee)
	} else {
		fmt.sbprintf(&e.b, "  call void %s(", callee)
	}
	for operand, index in operands {
		if index > 0 {
			fmt.sbprint(&e.b, ", ")
		}
		mode := index < len(callee_type.param_modes) ? callee_type.param_modes[index] : Param_Mode.Value
		type := param_mode_is_pointer(mode) ? "ptr" : llvm_type(e, callee_type.parameters[index])
		fmt.sbprintf(&e.b, "%s %s", type, operand)
	}
	fmt.sbprintln(&e.b, ")")
	if pack_cleanup.array_cleanup {
		emit_drop_flagged_array(
			e, pack_cleanup.type, pack_cleanup.array_buffer,
			pack_cleanup.array_flags, pack_cleanup.array_count,
		)
		unwind_clear(e, pack_cleanup.slot)
	}

	results: []string
	if callee_type.result != INVALID_TYPE {
		results = make([]string, 1)
		results[0] = call
	}
	if len(argument_cleanups) > 0 {
		// A drop hook can panic after the call has produced an owned result.
		// Protect that result until all borrowed argument temporaries are gone.
		guard: Deferred
		if len(results) == 1 {
			guard = hold_temporary_value(e, callee_type.result, results[0])
		}
		for index := len(argument_cleanups) - 1; index >= 0; index -= 1 {
			drop_temporary_value(e, argument_cleanups[index])
		}
		if guard.place != "" { finish_temporary_drop(e, guard) }
	}
	return results
}

@(private = "file")
emit_conversion :: proc(e: ^Emitter, v: ^Expr_Call, as_type: Type_Id) -> string {
	source_expr := v.bound[0]
	source := expr_base(source_expr).type
	target := as_type
	value := emit_expr(e, source_expr)

	from := type_underlying(e.c, source)
	to := type_underlying(e.c, target)
	if llvm_type(e, from) == llvm_type(e, to) {
		return value
	}

	// design.md "SIMD vectors": a lane-wise conversion, which is the same LLVM
	// cast instruction over a vector operand — so only the types it reads about
	// come from the lanes.
	from_lane, to_lane := from, to
	if type_is_simd(e.c, from) && type_is_simd(e.c, to) {
		from_lane = type_underlying(e.c, type_of(e.c, from).element)
		to_lane = type_underlying(e.c, type_of(e.c, to).element)
	}
	from_float := type_is_float(e.c, from_lane)
	to_float := type_is_float(e.c, to_lane)
	from_bits, to_bits := type_bits(e.c, from_lane), type_bits(e.c, to_lane)
	from_signed := type_signed(e.c, from_lane) || type_is_rune(e.c, from_lane)
	to_signed := type_signed(e.c, to_lane) || type_is_rune(e.c, to_lane)

	operation := ""
	switch {
	case from_float && to_float:
		operation = from_bits > to_bits ? "fptrunc" : "fpext"
	case from_float:
		operation = to_signed ? "fptosi" : "fptoui"
		guard_float_to_int(e, value, from, from_lane, to_lane)
	case to_float:
		operation = from_signed ? "sitofp" : "uitofp"
	case from_bits > to_bits:
		operation = "trunc"
	case from_bits < to_bits:
		operation = from_signed ? "sext" : "zext"
	case:
		return value
	}
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = %s %s %s to %s", out, operation, llvm_type(e, from), value, llvm_type(e, to))
	return out
}

// design.md "Type conversion": a float converts to an integer type only when the
// value is in that type's range. LLVM's `fptosi`/`fptoui` yield poison for every
// other input -- a NaN, an infinity, or a magnitude that does not fit -- which
// is not a value this language has, so the range is tested first and an invalid
// conversion panics (design.md "Panics and unwinding"). Both tests are unordered
// so a NaN trips them, and the upper bound is exclusive because it is the first
// power of two past the destination's maximum.
@(private = "file")
guard_float_to_int :: proc(e: ^Emitter, value: string, from, from_lane, to_lane: Type_Id) {
	width := u16(type_bits(e.c, from_lane))
	signed := type_signed(e.c, to_lane) || type_is_rune(e.c, to_lane)
	magnitude := int(type_bits(e.c, to_lane)) - (signed ? 1 : 0)
	low_value := signed ? -power_of_two(magnitude) : 0
	high_value := power_of_two(magnitude)

	// A destination wider than the source's exponent range rounds its bound to an
	// infinity. Every finite value is then in range and only the infinity itself
	// is not, so an equal operand has to fail rather than pass.
	below := float_from_pattern(float_pattern(low_value, width), width) == low_value ? "ult" : "ule"
	low := llvm_float(float_pattern(low_value, width), width)
	high := llvm_float(float_pattern(high_value, width), width)

	info := underlying_info(e.c, from)
	lanes := type_is_simd(e.c, from)
	if lanes {
		low, high = simd_repeated(e, info, low), simd_repeated(e, info, high)
	}
	llvm := llvm_type(e, from)
	under, over, bad := temp(e), temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = fcmp %s %s %s, %s", under, below, llvm, value, low)
	fmt.sbprintfln(&e.b, "  %s = fcmp uge %s %s, %s", over, llvm, value, high)
	predicate := lanes ? fmt.aprintf("<%d x i1>", info.count) : "i1"
	fmt.sbprintfln(&e.b, "  %s = or %s %s, %s", bad, predicate, under, over)
	// A panic is not lane-wise, so one invalid lane faults the whole conversion.
	if lanes {
		bad = simd_any_lane(e, info, bad)
	}
	panic_if(e, bad, "cast.range", "a float outside the destination integer type's range")
}

// `U.name(payload)`: evaluate the payload and write it plus the variant's tag.
@(private = "file")
emit_union_operation :: proc(e: ^Emitter, v: ^Expr_Call, as_type: Type_Id) -> string {
	operation, construction := v.operation.(Call_Union_Construct)
	if !construction || len(v.bound) != 1 {
		backend_fail(e, "a union call has no construction operand")
		return "0"
	}
	payload := emit_expr(e, v.bound[0])
	if operation.clone {
		payload = emit_clone_value(e, expr_base(v.bound[0]).type, payload)
	}
	return emit_union_value(e, as_type, operation.index, payload)
}

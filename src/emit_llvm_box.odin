// `box(T)` (design.md "Owned values"): one address naming an allocation that
// holds the allocator, then the payload at `box_payload_offset`. Drop and clone
// are per-type thunks, which is also what lets a type reach itself through a
// box without the emitter recursing forever.
package lokec

import "core:fmt"

// `box(value[, allocator])` and `try_box(...)`, and the headerless allocation
// `unsafe.new` and `unsafe.try_new` hand out as a `[^]T`. The payload is held as
// a temporary until the allocation publishes it, so a failure or a panic on the
// way drops it exactly once.
@(private)
emit_box_new :: proc(e: ^Emitter, v: ^Expr_Call, as_type: Type_Id) -> string {
	checked := v.operation.(Call_Allocation)
	payload := checked.type
	base, _ := allocation_builtin(call_builtin_kind(e, v))
	header := base == .Box_New
	size, align := box_block_size(e.c, payload), box_block_align(e.c, payload)
	if !header {
		size, align = type_size(e.c, payload), type_align(e.c, payload)
	}
	operations := emit_lifecycle(e, payload)
	value := emit_expr(e, v.bound[0])
	copies := operations.managed && expression_is_borrowed_place(v.bound[0])
	guard := Deferred{slot = -1}
	if !copies {
		guard = hold_temporary_value(e, payload, value)
	}
	allocator := emit_allocator_operand(e, v, 1)

	block_slot := alloca(e, "ptr")
	fmt.sbprintfln(&e.b, "  store ptr null, ptr %s", block_slot)
	done_label := new_label(e, "box.done")
	if copies {
		// The copy allocates from the box's own allocator, as a copy into any
		// destination does.
		if checked.fallible && operations.clone_fallible {
			cloned, broke, error := emit_clone_call(e, operations.try_clone, payload, value, allocator)
			refused_label, cloned_label := new_label(e, "box.refused"), new_label(e, "box.cloned")
			branch_if(e, broke, refused_label, cloned_label)
			place_label(e, refused_label)
			emit_restore_refusal(e, allocator, error)
			branch(e, done_label)
			place_label(e, cloned_label)
			value = cloned
		} else {
			value = emit_clone_value(e, payload, value, allocator)
		}
		guard = hold_temporary_value(e, payload, value)
	}

	block := temp(e)
	fmt.sbprintfln(&e.b, "  %s = call ptr @loke_rt_v1_alloc(ptr %s, i64 %d, i64 %d)", block, allocator, size, align)
	no_memory := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq ptr %s, null", no_memory, block)
	release_label, publish_label := new_label(e, "box.release"), new_label(e, "box.publish")
	branch_if(e, no_memory, release_label, publish_label)

	place_label(e, release_label)
	drop_temporary_value(e, guard)
	branch(e, done_label)

	place_label(e, publish_label)
	if header {
		fmt.sbprintfln(&e.b, "  store ptr %s, ptr %s", allocator, block)
		store(e, payload, value, box_payload_at(e, payload, block))
	} else {
		store(e, payload, value, block)
	}
	finish_temporary_drop(e, guard)
	fmt.sbprintfln(&e.b, "  store ptr %s, ptr %s", block, block_slot)
	branch(e, done_label)

	place_label(e, done_label)
	e.terminated = false
	published := load(e, "ptr", block_slot)
	failed := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq ptr %s, null", failed, published)
	if checked.fallible {
		return emit_alloc_result(e, as_type, failed, published)
	}
	fail_label, ok_label := new_label(e, "box.failed"), new_label(e, "box.ok")
	branch_if(e, failed, fail_label, ok_label)
	place_label(e, fail_label)
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_alloc_failed(ptr %s)", allocator)
	fmt.sbprintln(&e.b, "  unreachable")
	e.terminated = true
	place_label(e, ok_label)
	return published
}

// The payload's address inside a box's allocation.
@(private)
box_payload_at :: proc(e: ^Emitter, payload: Type_Id, block: string) -> string {
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = getelementptr inbounds i8, ptr %s, i64 %d", out, block, box_payload_offset(e.c, payload))
	return out
}

// The payload a box value names: `b^`.
@(private)
emit_box_payload_address :: proc(e: ^Emitter, box_type: Type_Id, box_value: string) -> string {
	return box_payload_at(e, box_element(e.c, box_type), box_value)
}

// Drops the box at `address` and leaves the inert null behind, so dropping a
// moved-from or already dropped box does nothing.
@(private)
emit_box_drop :: proc(e: ^Emitter, box_type: Type_Id, address: string) {
	fmt.sbprintfln(&e.b, "  call void %s(ptr %s)", box_drop_thunk(e, box_type), address)
}

// Clones the box at `src` into `out` from `allocator`; the result is the `i1`
// success flag, and `out` is written only on success.
@(private)
emit_box_try_clone_into :: proc(e: ^Emitter, box_type: Type_Id, out, src, allocator: string) -> string {
	status, ok := temp(e), temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = call i32 %s(ptr %s, ptr %s, ptr %s)",
		status, box_clone_thunk(e, box_type), out, src, allocator,
	)
	fmt.sbprintfln(&e.b, "  %s = icmp ne i32 %s, 0", ok, status)
	return ok
}

@(private = "file")
box_drop_thunk :: proc(e: ^Emitter, box_type: Type_Id) -> string {
	return container_thunk(
		e, fmt.aprintf("@loke.boxdrop.%d", int(type_underlying(e.c, box_type))), box_type,
		"void", "ptr %p",
		proc(e: ^Emitter, box_type: Type_Id) {
			payload := box_element(e.c, box_type)
			block := load(e, "ptr", "%p")
			empty := temp(e)
			fmt.sbprintfln(&e.b, "  %s = icmp eq ptr %s, null", empty, block)
			release_label, done_label := new_label(e, "boxdrop.release"), new_label(e, "boxdrop.done")
			branch_if(e, empty, done_label, release_label)
			place_label(e, release_label)
			// Inert first: a payload drop hook that panics leaves nothing to drop twice.
			fmt.sbprintfln(&e.b, "  store ptr null, ptr %%p")
			emit_drop_place(e, payload, box_payload_at(e, payload, block))
			allocator := load(e, "ptr", block)
			fmt.sbprintfln(
				&e.b, "  call void @loke_rt_v1_free(ptr %s, ptr %s, i64 %d, i64 %d)",
				allocator, block, box_block_size(e.c, payload), box_block_align(e.c, payload),
			)
			branch(e, done_label)
			place_label(e, done_label)
			fmt.sbprintln(&e.b, "  ret void")
		},
	)
}

// The payload is cloned before the allocation is made, as `box(place)` does,
// so a copy hook that panics leaves no unpublished block behind.
@(private = "file")
box_clone_thunk :: proc(e: ^Emitter, box_type: Type_Id) -> string {
	return container_thunk(
		e, fmt.aprintf("@loke.boxclone.%d", int(type_underlying(e.c, box_type))), box_type,
		"i32", "ptr %out, ptr %src, ptr %a",
		proc(e: ^Emitter, box_type: Type_Id) {
			payload := box_element(e.c, box_type)
			origin := box_payload_at(e, payload, load(e, "ptr", "%src"))
			managed := emit_lifecycle(e, payload).managed
			value: string
			staged := ""
			if managed {
				staged = alloca(e, llvm_type(e, payload))
				ok := emit_try_clone_into(e, payload, staged, origin, "%a")
				cloned_label, refused_label := new_label(e, "boxclone.cloned"), new_label(e, "boxclone.refused")
				branch_if(e, ok, cloned_label, refused_label)
				place_label(e, refused_label)
				fmt.sbprintln(&e.b, "  ret i32 0")
				place_label(e, cloned_label)
				value = load_place(e, payload, staged)
			} else {
				// Plain data is its own clone.
				value = load_place(e, payload, origin)
			}
			block := temp(e)
			fmt.sbprintfln(
				&e.b, "  %s = call ptr @loke_rt_v1_alloc(ptr %%a, i64 %d, i64 %d)",
				block, box_block_size(e.c, payload), box_block_align(e.c, payload),
			)
			no_memory := temp(e)
			fmt.sbprintfln(&e.b, "  %s = icmp eq ptr %s, null", no_memory, block)
			undo_label, publish_label := new_label(e, "boxclone.undo"), new_label(e, "boxclone.publish")
			branch_if(e, no_memory, undo_label, publish_label)
			place_label(e, undo_label)
			if managed {
				emit_drop_place(e, payload, staged)
			}
			fmt.sbprintln(&e.b, "  ret i32 0")
			place_label(e, publish_label)
			fmt.sbprintfln(&e.b, "  store ptr %%a, ptr %s", block)
			store(e, payload, value, box_payload_at(e, payload, block))
			fmt.sbprintfln(&e.b, "  store ptr %s, ptr %%out", block)
			fmt.sbprintln(&e.b, "  ret i32 1")
		},
	)
}

// `move(b).unbox()`: the payload leaves, then the allocation is released.
@(private)
emit_box_unbox :: proc(e: ^Emitter, v: ^Expr_Call) -> string {
	box_type := expr_base(v.bound[0]).type
	payload := box_element(e.c, box_type)
	block := emit_expr(e, v.bound[0])
	value := load_place(e, payload, box_payload_at(e, payload, block))
	allocator := load(e, "ptr", block)
	fmt.sbprintfln(
		&e.b, "  call void @loke_rt_v1_free(ptr %s, ptr %s, i64 %d, i64 %d)",
		allocator, block, box_block_size(e.c, payload), box_block_align(e.c, payload),
	)
	return value
}

// `Box(T)` (design.md "Owned values"): one address naming an allocation that
// holds the allocator, then the payload at `box_payload_offset`. Drop and clone
// are per-type thunks, which is also what lets a type reach itself through a
// box without the emitter recursing forever.
package lokec

import "core:fmt"

// The allocation behind a box: the allocator, then the payload at its own
// alignment.
@(private = "file")
box_payload_offset :: proc(c: ^Compiler, element: Type_Id) -> u64 {
	return align_to(u64(c.target.pointer_bits) / 8, type_align(c, element))
}

@(private = "file")
box_block_size :: proc(c: ^Compiler, element: Type_Id) -> u64 {
	return align_to(box_payload_offset(c, element) + type_size(c, element), box_block_align(c, element))
}

@(private = "file")
box_block_align :: proc(c: ^Compiler, element: Type_Id) -> u64 {
	return max(u64(c.target.pointer_bits) / 8, type_align(c, element))
}

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
	// design.md "Widening by label": a widened place is copied at its own type,
	// and the copy remapped into the payload.
	copied := copied_type(v.bound[0], payload)
	widened := copied != payload
	operations := emit_lifecycle(e, copied)
	copies := operations.managed && expression_is_borrowed_place(v.bound[0])
	value := copies && widened ? emit_expr_at(e, v.bound[0], copied) : emit_expr(e, v.bound[0])
	guard := Deferred{}
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
			cloned, broke, error := emit_clone_call(e, operations.try_clone, copied, value, allocator)
			refused_label, cloned_label := new_label(e, "box.refused"), new_label(e, "box.cloned")
			branch_if(e, broke, refused_label, cloned_label)
			place_label(e, refused_label)
			emit_restore_refusal(e, allocator, error)
			branch(e, done_label)
			place_label(e, cloned_label)
			value = cloned
		} else {
			value = emit_clone_value(e, copied, value, allocator)
		}
		if widened {
			value = emit_union_widen(e, value, copied, payload)
		}
		guard = hold_temporary_value(e, payload, value)
	}

	block, no_memory := emit_rt_alloc(e, allocator, size, align)
	release_label, publish_label := new_label(e, "box.release"), new_label(e, "box.publish")
	branch_if(e, no_memory, release_label, publish_label)

	place_label(e, release_label)
	// The drop may allocate, which would replace the refusal just noted.
	refused := emit_take_refusal(e)
	drop_temporary_value(e, guard)
	emit_restore_refusal(e, allocator, refused)
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
	published := load(e, "ptr", block_slot)
	return emit_alloc_outcome(e, v, as_type, is_null(e, published), published, allocator)
}

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

// The boxed case of `emit_try_clone_into`.
@(private)
emit_box_try_clone_into :: proc(e: ^Emitter, box_type: Type_Id, out, src, allocator: string) -> string {
	ok := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = call i1 %s(ptr %s, ptr %s, ptr %s)",
		ok, box_clone_thunk(e, box_type), out, src, allocator,
	)
	return ok
}

@(private = "file")
box_drop_thunk :: proc(e: ^Emitter, box_type: Type_Id) -> string {
	return container_thunk(
		e, generated_name(e, fmt.aprintf("@loke.boxdrop.%d", int(type_underlying(e.c, box_type)))), box_type,
		"void", "ptr %p",
		proc(e: ^Emitter, box_type: Type_Id) {
			payload := box_element(e.c, box_type)
			block := load(e, "ptr", "%p")
			empty := is_null(e, block)
			release_label, done_label := new_label(e, "boxdrop.release"), new_label(e, "boxdrop.done")
			branch_if(e, empty, done_label, release_label)
			place_label(e, release_label)
			// Inert first: a payload drop hook that panics leaves nothing to drop twice.
			fmt.sbprintfln(&e.b, "  store ptr null, ptr %%p")
			// design.md "What the unwind runs, and what it does not": the payload's
			// drop registers its parts not yet dropped, and the allocation stays
			// registered until the payload is gone.
			release := begin_box_release(e, payload, block)
			emit_drop_place(e, payload, box_payload_at(e, payload, block))
			finish_temporary_drop(e, release)
			emit_box_release(e, payload, block)
			place_label(e, done_label)
			emit_unwind_pop(e)
			fmt.sbprintln(&e.b, "  ret void")
		},
		framed = true,
	)
}

// Returns a box's allocation, whose payload is already dropped or moved out, to
// the allocator stored at its start.
@(private)
emit_box_release :: proc(e: ^Emitter, payload: Type_Id, block: string) {
	emit_rt_free(e, load(e, "ptr", block), block, box_block_size(e.c, payload), box_block_align(e.c, payload))
}

// The payload is cloned before the allocation is made, as `box(place)` does,
// so a copy hook that panics leaves no unpublished block behind.
@(private = "file")
box_clone_thunk :: proc(e: ^Emitter, box_type: Type_Id) -> string {
	return container_thunk(
		e, generated_name(e, fmt.aprintf("@loke.boxclone.%d", int(type_underlying(e.c, box_type)))), box_type,
		"i1", "ptr %out, ptr %src, ptr %a",
		proc(e: ^Emitter, box_type: Type_Id) {
			payload := box_element(e.c, box_type)
			origin := box_payload_at(e, payload, load(e, "ptr", "%src"))
			managed := emit_lifecycle(e, payload).managed
			// Plain data is its own clone.
			source := origin
			if managed {
				source = alloca(e, llvm_type(e, payload))
				ok := emit_try_clone_into(e, payload, source, origin, "%a")
				cloned_label, refused_label := new_label(e, "boxclone.cloned"), new_label(e, "boxclone.refused")
				branch_if(e, ok, cloned_label, refused_label)
				place_label(e, refused_label)
				emit_unwind_pop(e)
				fmt.sbprintln(&e.b, "  ret i1 false")
				e.terminated = true
				place_label(e, cloned_label)
			}
			value := load_place(e, payload, source)
			block, no_memory := emit_rt_alloc(e, "%a", box_block_size(e.c, payload), box_block_align(e.c, payload))
			undo_label, publish_label := new_label(e, "boxclone.undo"), new_label(e, "boxclone.publish")
			branch_if(e, no_memory, undo_label, publish_label)
			place_label(e, undo_label)
			if managed {
				// The drop may allocate, which would replace the refusal just noted.
				refused := emit_take_refusal(e)
				emit_drop_place(e, payload, source)
				emit_restore_refusal(e, "%a", refused)
			}
			emit_unwind_pop(e)
			fmt.sbprintln(&e.b, "  ret i1 false")
			e.terminated = true
			place_label(e, publish_label)
			fmt.sbprintfln(&e.b, "  store ptr %%a, ptr %s", block)
			store(e, payload, value, box_payload_at(e, payload, block))
			fmt.sbprintfln(&e.b, "  store ptr %s, ptr %%out", block)
			emit_unwind_pop(e)
			fmt.sbprintln(&e.b, "  ret i1 true")
		},
		framed = true,
	)
}

// `move(b).unbox()`.
@(private)
emit_box_unbox :: proc(e: ^Emitter, v: ^Expr_Call) -> string {
	box_type := expr_base(v.bound[0]).type
	payload := box_element(e.c, box_type)
	block := emit_expr(e, v.bound[0])
	value := load_place(e, payload, box_payload_at(e, payload, block))
	emit_box_release(e, payload, block)
	return value
}

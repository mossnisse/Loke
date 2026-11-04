// Lifecycle bodies: value clones and drops, and the generated `try_clone` and
// `clone` members.
//
// Part of the textual LLVM backend; see compiler-architecture.md.
package lokec

import "core:fmt"
import "core:strings"

// Deep-copies `src` into `out`, answering an `i1` that is true on success. On
// failure `out` is left untouched, so the caller can destroy exactly the prefix
// it did build.
@(private)
emit_try_clone_into :: proc(e: ^Emitter, type: Type_Id, out, src, allocator: string) -> string {
	operations := emit_lifecycle(e, type)
	if operations.boxed {
		return emit_box_try_clone_into(e, type, out, src, allocator)
	}
	if operations.container {
		helper := type_is_map(e.c, type) ? "loke_rt_v1_map_clone" : "loke_rt_v1_dyn_clone"
		status, ok := temp(e), temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call i32 @%s(ptr %s, ptr %s, ptr %s, ptr %s)",
			status, helper, out, src, container_ops_global(e, type), allocator,
		)
		fmt.sbprintfln(&e.b, "  %s = icmp ne i32 %s, 0", ok, status)
		return ok
	}
	value := load_place(e, type, src)
	if !operations.clone_fallible {
		store(e, type, emit_clone_value(e, type, value, allocator), out)
		return "true"
	}
	hook := operations.try_clone
	if hook == INVALID_SYMBOL {
		if emit_dead_move_only_copy(e, type) {
			return "false"
		}
		backend_fail(e, "a fallible container element has no `try_clone` member")
		return "false"
	}
	cloned, broke, error := emit_clone_call(e, hook, type, value, allocator)
	ok := temp(e)
	fmt.sbprintfln(&e.b, "  %s = xor i1 %s, true", ok, broke)
	// A failed clone returns an inert zero the caller must not count as
	// initialised, so the value is stored only on success.
	store_label, fail_label, done_label := new_label(e, "clone.store"), new_label(e, "clone.refused"), new_label(e, "clone.done")
	branch_if(e, ok, store_label, fail_label)
	place_label(e, store_label)
	store(e, type, cloned, out)
	branch(e, done_label)
	place_label(e, fail_label)
	emit_restore_refusal(e, allocator, error)
	branch(e, done_label)
	place_label(e, done_label)
	return ok
}

// An implicit copy goes through `clone`, which calls `try_clone` once and
// applies the allocator's failure policy (design.md "Allocation failure"). An
// empty `allocator` means the build-selected default.
@(private)
emit_clone_value :: proc(e: ^Emitter, type: Type_Id, value: string, allocator := "") -> string {
	entry := emit_lifecycle(e, type)
	// A string copy retains a shared handle; only `.copy()` allocates.
	if entry.intrinsic && !entry.container {
		owner := extract(e, STRING_TYPE, value, STRING_OWNER)
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_string_retain(i64 %s)", owner)
		return value
	}
	provider := allocator == "" ? emit_default_allocator(e) : allocator
	if entry.container || entry.boxed {
		shape := llvm_type(e, type)
		source := alloca(e, shape)
		destination := alloca(e, shape)
		fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", shape, value, source)
		ok := emit_try_clone_into(e, type, destination, source, provider)
		fail_label, done_label := new_label(e, "cclone.fail"), new_label(e, "cclone.done")
		branch_if(e, ok, done_label, fail_label)
		place_label(e, fail_label)
		emit_alloc_failed(e, provider)
		place_label(e, done_label)
		return load(e, shape, destination)
	}
	// Fixed arrays have a generated `try_clone` but no public `clone` member.
	if info := underlying_info(e.c, type); info != nil && info.kind == .Array {
		return emit_clone_with_policy(e, type, value, provider)
	}
	hook := entry.clone
	if hook == INVALID_SYMBOL {
		if emit_dead_move_only_copy(e, type) {
			return "undef"
		}
		backend_fail(e, fmt.aprintf("an implicit copy of `%s` has no `clone` member", type_name(e.c, type)))
		return "0"
	}
	receiver_type, receiver := call_receiver_operand(e, hook, type, value)
	return emit_call_result(
		e, type, callee_name(e, hook), fmt.aprintf("%s %s, ptr %s", receiver_type, receiver, provider),
	)
}

// Calls one `try_clone`, which returns `Result(T, Allocator_Error)`. `cloned` is
// only meaningful where `failed` is false, and `error`, the `Allocator_Error`,
// only where it is true.
@(private)
emit_clone_call :: proc(
	e: ^Emitter, hook: Symbol_Id, subject: Type_Id, value, allocator: string,
) -> (cloned: string, failed: string, error: string) {
	result := symbol_of(e.c, hook).result
	receiver_type, receiver := call_receiver_operand(e, hook, subject, value)
	returned := emit_call_result(
		e, result, callee_name(e, hook), fmt.aprintf("%s %s, ptr %s", receiver_type, receiver, allocator),
	)
	slot := emit_union_spill(e, result, returned)
	failed = emit_union_failed(e, result, returned)
	cloned = emit_union_payload(e, result, subject, slot)
	error = emit_union_payload(e, result, TYPE_ALLOCATOR_ERROR, slot)
	return
}

// Generated field-wise `try_clone`: clones every owning part, destroys the
// partial result on failure, and returns zero plus the error
// (design.md "Lifecycle hooks and resource types").
@(private)
emit_synth_try_clone :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	subject := symbol.params[0]
	operations := emit_lifecycle(e, subject)
	value_type := llvm_type(e, subject)
	result := symbol.result
	open_function(
		e, "define %s%s %s(%s%s %%arg0, ptr %%arg1)",
		llvm_linkage(name), llvm_result_type(e, result), name, sret_param(e, result), synth_param_llvm(e, symbol, 0),
	)
	subject_value := synth_receiver_value(e, symbol)
	info := underlying_info(e.c, subject)
	framed := false
	header: strings.Builder

	if hook := operations.custom_try_clone; hook != INVALID_SYMBOL {
		// A user `hook(copy)` is the primitive; forward the receiver in its own mode.
		hook_type, hook_receiver := value_type, subject_value
		if hook_sym := symbol_of(e.c, hook);
		   hook_sym != nil && param_mode_is_pointer(symbol_param_mode(e.c, hook_sym, 0)) {
			hook_type, hook_receiver = "ptr", "%arg0"
		}
		custom := emit_call_result(e, result, symbol_name(e, hook), fmt.aprintf("%s %s, ptr %%arg1", hook_type, hook_receiver))
		emit_ret(e, result, custom)
	} else if !operations.managed {
		// An unmanaged value is its own clone. (A `string` part is infallible but
		// managed: it still needs a retain.)
		emit_ret(e, result, emit_alloc_result(e, result, "false", subject_value))
	} else if info != nil && info.kind == .Union {
		emit_union_try_clone_body(e, subject, info, result, value_type, subject_value)
	} else if operations.intrinsic || operations.boxed {
		// `string`, `[dynamic]T`, `map[K]V` and `Box(T)` carry a `try_clone` whose
		// body is the same intrinsic copy the implicit paths use.
		self, built := alloca(e, value_type), alloca(e, value_type)
		store(e, subject, subject_value, self)
		store(e, subject, "zeroinitializer", built)
		ok := emit_try_clone_into(e, subject, built, self, "%arg1")
		value := load_temporary(e, subject, built)
		broke := temp(e)
		fmt.sbprintfln(&e.b, "  %s = xor i1 %s, true", broke, ok)
		emit_ret(e, result, emit_alloc_result(e, result, broke, value))
	} else {
		framed, header = true, begin_generated_frame(e, name)
		emit_fieldwise_try_clone_body(e, subject, info, result, value_type, subject_value)
	}
	fmt.sbprintln(&e.b, "}")
	if framed {
		end_generated_frame(e, header)
	}
}

// Both sides live in memory: a failure path drops what the destination holds,
// and it starts zeroed so every hook sees the inert value, never garbage.
// A panicking hook leaves the completed parts to the unwind, apart from the
// incomplete result, whose own drop hook must not run.
@(private = "file")
emit_fieldwise_try_clone_body :: proc(
	e: ^Emitter, subject: Type_Id, info: ^Type_Info, result: Type_Id, value_type: string,
	subject_value: string,
) {
	self := alloca(e, value_type)
	out := temp(e)
	store(e, subject, subject_value, self)
	alloca_named(e, out, value_type)
	store(e, subject, "zeroinitializer", out)
	if info != nil && info.kind == .Array {
		guard := emit_clone_elements(e, info.element, self, out, fmt.aprintf("%d", info.count), subject, out, nil, result)
		finish_temporary_drop(e, guard)
	} else {
		emit_clone_record_parts(e, subject, self, out, result)
	}
	built := load_temporary(e, subject, out)
	emit_ret(e, result, emit_alloc_result(e, result, "false", built))
}

// Clones a record's parts in order into `out`, leaving each completed one to the
// unwind until the whole record is built.
@(private = "file")
emit_clone_record_parts :: proc(e: ^Emitter, subject: Type_Id, self, out: string, result: Type_Id) {
	guards := make([]Deferred, clone_part_count(e.c, subject))
	for index in 0 ..< len(guards) {
		part := clone_part(e.c, subject, index)
		part_operations := emit_lifecycle(e, part)
		source := element_address(e, subject, self, index)
		destination := element_address(e, subject, out, index)
		// An unmanaged `@(initialized)` field is copied whole as bytes below.
		if field, counter, prefixed := record_prefix_part(e, subject, index); prefixed &&
		   part_operations.managed {
			guards[index] = emit_clone_prefix(e, subject, self, out, field, counter, guards[:index], result)
			continue
		}
		if !part_operations.managed {
			loaded := load_place(e, part, source)
			store(e, part, loaded, destination)
			continue
		}
		if !part_operations.clone_fallible {
			loaded := load_place(e, part, source)
			store(e, part, emit_clone_value(e, part, loaded, "%arg1"), destination)
			guards[index] = guard_record_part(e, subject, out, index)
			continue
		}
		cloned, failed, error := emit_part_clone(e, part, source)
		unwind, ok := new_label(e, "clone.unwind"), new_label(e, "clone.ok")
		branch_if(e, failed, unwind, ok)

		// Drop the parts already built, in reverse; later ones are still zero.
		place_label(e, unwind)
		drop_built_parts(e, subject, out, guards[:index])
		emit_ret(e, result, emit_alloc_result(e, result, "true", error = error))
		// Only a successful part is published, so a hook that returns a live value
		// beside an error cannot leak it into the temporary.
		place_label(e, ok)
		store(e, part, cloned, destination)
		guards[index] = guard_record_part(e, subject, out, index)
	}
	for guard in guards {
		finish_temporary_drop(e, guard)
	}
}

// Drops a record's completed parts, last first, each unregistered just before
// its drop, so a panic in one still leaves the others to the unwind.
@(private = "file")
drop_built_parts :: proc(e: ^Emitter, record: Type_Id, out: string, guards: []Deferred) {
	for done := len(guards) - 1; done >= 0; done -= 1 {
		finish_temporary_drop(e, guards[done])
		emit_drop_record_part(e, record, out, done)
	}
}

// design.md "Uninitialized capacity": `@(initialized = count)` makes only the
// first `count` elements of a fixed array field values; the capacity behind
// them is never read as one.
@(private = "file")
record_prefix_part :: proc(
	e: ^Emitter, record: Type_Id, index: int,
) -> (field: ^Symbol, counter: ^Symbol, prefixed: bool) {
	info := underlying_info(e.c, record)
	if info == nil || info.kind != .Struct {
		return nil, nil, false
	}
	field = symbol_of(e.c, info.fields[index])
	if field == nil || field.initialized_by == INVALID_SYMBOL {
		return nil, nil, false
	}
	counter = symbol_of(e.c, field.initialized_by)
	return field, counter, counter != nil
}

@(private = "file")
emit_prefix_count :: proc(e: ^Emitter, record: Type_Id, base: string, counter: ^Symbol, array: Type_Id) -> string {
	address := element_address(e, record, base, int(counter.index))
	count := load_place(e, counter.type, address)
	emit_prefix_count_check(e, count, array)
	return count
}

// A count outside `0 ..= N` panics before a traversal reads past the array. It
// cannot show that the prefix holds values; that stays the author's promise.
@(private)
emit_prefix_count_check :: proc(e: ^Emitter, count: string, array: Type_Id) {
	out_of_range := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp ugt i64 %s, %d", out_of_range, count, underlying_info(e.c, array).count)
	panic_if(e, out_of_range, "prefix.count", "an `@(initialized)` count is outside its array")
}

// Drops the first `count` elements, last first. Without `flags`, the unwind still
// owns the elements before the one whose drop is running. With them, an element
// is live only where its flag says so, and the flag is cleared before its hook
// runs, so a panic from that hook cannot replay the same element.
@(private)
emit_drop_elements_reversed :: proc(e: ^Emitter, element: Type_Id, items, count: string, flags := "") {
	cursor := alloca(e, "i64")
	fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", count, cursor)
	guard := Deferred{}
	if flags == "" && emit_lifecycle(e, element).drop_may_panic {
		guard = register_array_cleanup(e, element, items, "", cursor)
	}
	head := new_label(e, "elements.drop.head")
	body, done := new_label(e, "elements.drop.body"), new_label(e, "elements.drop.done")
	branch(e, head)
	place_label(e, head)
	remaining := load(e, "i64", cursor)
	more := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp sgt i64 %s, 0", more, remaining)
	branch_if(e, more, body, done)
	place_label(e, body)
	index := temp(e)
	fmt.sbprintfln(&e.b, "  %s = sub i64 %s, 1", index, remaining)
	fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", index, cursor)
	if flags != "" {
		flag_address, live := temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = getelementptr i1, ptr %s, i64 %s", flag_address, flags, index)
		fmt.sbprintfln(&e.b, "  %s = load i1, ptr %s", live, flag_address)
		run := new_label(e, "elements.drop.run")
		branch_if(e, live, run, head)
		place_label(e, run)
		fmt.sbprintfln(&e.b, "  store i1 false, ptr %s", flag_address)
	}
	emit_drop_place(e, element, gep_at(e, llvm_type(e, element), items, index))
	branch(e, head)
	place_label(e, done)
	finish_temporary_drop(e, guard)
}

// Drops what a variadic call's staged array, `entry`, still flags as owned.
@(private)
emit_drop_staged_array :: proc(e: ^Emitter, entry: Deferred) {
	emit_drop_elements_reversed(e, entry.type, entry.array_buffer, load(e, "i64", entry.array_count), entry.array_flags)
}

// Registers one completed part of a record for the unwind, apart from the
// record, whose own hook must not run for it.
@(private)
guard_record_part :: proc(e: ^Emitter, record: Type_Id, base: string, index: int) -> Deferred {
	if !unwind_enabled(e) || !emit_lifecycle(e, clone_part(e.c, record, index)).managed {
		return Deferred{}
	}
	if field, counter, prefixed := record_prefix_part(e, record, index); prefixed {
		// Replay reads the count field itself: the record's drop hook shortens it
		// as it takes elements out (design.md "Uninitialized capacity").
		return register_array_cleanup(
			e, underlying_info(e.c, field.type).element,
			element_address(e, record, base, int(field.index)), "",
			element_address(e, record, base, int(counter.index)), field.type,
		)
	}
	return begin_temporary_drop(e, clone_part(e.c, record, index), element_address(e, record, base, index))
}

// design.md "What the unwind runs, and what it does not": a panic from the
// record's hook, or from one part's drop, still leaves the parts not yet
// dropped to the unwind. Each is registered until its own drop starts.
@(private = "file")
guard_record_parts :: proc(e: ^Emitter, record: Type_Id, base: string, hook: bool) -> []Deferred {
	guards := make([]Deferred, clone_part_count(e.c, record))
	if !unwind_enabled(e) {
		return guards
	}
	at_risk := make([]bool, len(guards))
	risky := hook
	for index := len(guards) - 1; index >= 0; index -= 1 {
		at_risk[index] = risky
		risky ||= emit_lifecycle(e, clone_part(e.c, record, index)).drop_may_panic
	}
	// Registered in declaration order, so the unwind replays them in drop order.
	for index in 0 ..< len(guards) {
		if at_risk[index] {
			guards[index] = guard_record_part(e, record, base, index)
		}
	}
	return guards
}

@(private = "file")
emit_drop_prefix :: proc(e: ^Emitter, record: Type_Id, base: string, field, counter: ^Symbol) {
	element := underlying_info(e.c, field.type).element
	items := element_address(e, record, base, int(field.index))
	count := emit_prefix_count(e, record, base, counter, field.type)
	emit_drop_elements_reversed(e, element, items, count)
}

@(private = "file")
emit_drop_record_part :: proc(e: ^Emitter, record: Type_Id, base: string, index: int) {
	part := clone_part(e.c, record, index)
	if !emit_lifecycle(e, part).managed {
		return
	}
	if field, counter, prefixed := record_prefix_part(e, record, index); prefixed {
		emit_drop_prefix(e, record, base, field, counter)
		return
	}
	emit_drop_place(e, part, element_address(e, record, base, index))
}

// Clones the live prefix of an `@(initialized)` field element by element. The
// full destination count is published first, so a later failure can clean every
// completed prefix sharing it.
@(private = "file")
emit_clone_prefix :: proc(
	e: ^Emitter, record: Type_Id, self, out: string, field, counter: ^Symbol, built_parts: []Deferred, result: Type_Id,
) -> Deferred {
	source := element_address(e, record, self, int(field.index))
	destination := element_address(e, record, out, int(field.index))
	built := element_address(e, record, out, int(counter.index))
	total := emit_prefix_count(e, record, self, counter, field.type)
	store(e, counter.type, total, built)
	return emit_clone_elements(e, underlying_info(e.c, field.type).element, source, destination, total, record, out, built_parts, result)
}

// Clones the first `total` elements from `source` in one runtime loop. A cursor
// counts the completed elements, and so is also their registration, which the
// caller clears once what holds them is complete. A failure drops exactly the
// progress the cursor holds, then `built_parts`, the parts of `record` at `out`
// finished before these, and returns the error.
@(private = "file")
emit_clone_elements :: proc(
	e: ^Emitter, element: Type_Id, source, destination, total: string,
	record: Type_Id, out: string, built_parts: []Deferred, result: Type_Id,
) -> Deferred {
	element_llvm := llvm_type(e, element)
	cursor := alloca(e, "i64")
	fmt.sbprintfln(&e.b, "  store i64 0, ptr %s", cursor)
	guard := register_array_cleanup(e, element, destination, "", cursor)
	head := new_label(e, "elements.clone.head")
	body, done := new_label(e, "elements.clone.body"), new_label(e, "elements.clone.done")
	branch(e, head)
	place_label(e, head)
	at := load(e, "i64", cursor)
	more := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp slt i64 %s, %s", more, at, total)
	branch_if(e, more, body, done)

	place_label(e, body)
	from := gep_at(e, element_llvm, source, at)
	into := gep_at(e, element_llvm, destination, at)
	cloned := ""
	if !emit_lifecycle(e, element).clone_fallible {
		cloned = emit_clone_value(e, element, load_place(e, element, from), "%arg1")
	} else {
		value, failed, error := emit_part_clone(e, element, from)
		fail, ok := new_label(e, "elements.clone.fail"), new_label(e, "elements.clone.ok")
		branch_if(e, failed, fail, ok)
		place_label(e, fail)
		finish_temporary_drop(e, guard)
		emit_drop_elements_reversed(e, element, destination, at)
		drop_built_parts(e, record, out, built_parts)
		emit_ret(e, result, emit_alloc_result(e, result, "true", error = error))
		place_label(e, ok)
		cloned = value
	}
	store(e, element, cloned, into)
	next := temp(e)
	fmt.sbprintfln(&e.b, "  %s = add i64 %s, 1", next, at)
	fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", next, cursor)
	branch(e, head)
	place_label(e, done)
	return guard
}

// Clones one part through its own `try_clone`. Returns the value, the error
// flag, and the `Allocator_Error`, empty when the failure is still a status in
// the runtime's note; the caller publishes the value only on success.
@(private = "file")
emit_part_clone :: proc(e: ^Emitter, part: Type_Id, source: string) -> (string, string, string) {
	operations := emit_lifecycle(e, part)
	if operations.container || operations.boxed {
		shape := llvm_type(e, part)
		destination := alloca(e, shape)
		ok := emit_try_clone_into(e, part, destination, source, "%arg1")
		cloned := load(e, shape, destination)
		failed := temp(e)
		fmt.sbprintfln(&e.b, "  %s = xor i1 %s, true", failed, ok)
		return cloned, failed, ""
	}
	hook := operations.try_clone
	if hook == INVALID_SYMBOL {
		backend_fail(e, "a fallible clone part has no `try_clone` member")
		return "0", "true", ""
	}
	loaded := load_place(e, part, source)
	return emit_clone_call(e, hook, part, loaded, "%arg1")
}

@(private)
emit_synth_clone :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	subject := symbol.params[0]
	open_function(
		e, "define %s%s %s(%s%s %%arg0, ptr %%arg1)",
		llvm_linkage(name), llvm_result_type(e, subject), name, sret_param(e, subject), synth_param_llvm(e, symbol, 0),
	)
	cloned := emit_clone_with_policy(e, subject, synth_receiver_value(e, symbol), "%arg1")
	emit_ret(e, subject, cloned)
	fmt.sbprintln(&e.b, "}")
}

// An implicit copy has nowhere to return an error, so the runtime applies the
// allocator's own policy (design.md "Allocation failure").
@(private = "file")
emit_clone_with_policy :: proc(e: ^Emitter, subject: Type_Id, value, allocator: string) -> string {
	hook := emit_lifecycle(e, subject).try_clone
	if hook == INVALID_SYMBOL {
		backend_fail(e, "a policy-following copy has no `try_clone` operation")
		return "0"
	}
	cloned, failed, error := emit_clone_call(e, hook, subject, value, allocator)
	fail, ok := new_label(e, "clone.failed"), new_label(e, "ok")
	branch_if(e, failed, fail, ok)
	place_label(e, fail)
	emit_restore_refusal(e, allocator, error)
	emit_alloc_failed(e, allocator)
	place_label(e, ok)
	return cloned
}

// Lifecycle decisions come from the completed semantic snapshot.
@(private)
emit_lifecycle :: proc(e: ^Emitter, type: Type_Id) -> Lifecycle_Operations {
	if type == INVALID_TYPE { return Lifecycle_Operations{} }
	operations, resolved := resolved_lifecycle_operations(e.c, type)
	if !resolved {
		backend_fail(e, "lifecycle operations were not finalized during checking")
		return Lifecycle_Operations{}
	}
	return operations
}

// `drop(value)` runs the user hook, then drops fields in reverse declaration
// order (design.md "Lifecycle hooks and resource types").
@(private)
emit_drop_place :: proc(e: ^Emitter, type: Type_Id, address: string) {
	operations := emit_lifecycle(e, type)
	if !operations.managed {
		return
	}
	if operations.boxed {
		emit_box_drop(e, type, address)
		return
	}
	// The container helper leaves the inert zero, and dropping zero is a no-op.
	// design.md "What the unwind runs, and what it does not": the container
	// stays registered while the helper runs, which takes each element out
	// before its hook, so a panicking hook leaves the rest to the unwind.
	if operations.container {
		helper := type_is_map(e.c, type) ? "loke_rt_v1_map_drop" : "loke_rt_v1_dyn_drop"
		guard := Deferred{}
		if unwind_enabled(e) && operations.drop_may_panic {
			guard = begin_temporary_drop(e, type, address)
		}
		fmt.sbprintfln(&e.b, "  call void @%s(ptr %s, ptr %s)", helper, address, container_ops_global(e, type))
		finish_temporary_drop(e, guard)
		return
	}
	// Ending a local region releases every block it handed out.
	if operations.provider {
		control := load(e, "ptr", address)
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_arena_drop(ptr %s)", control)
		fmt.sbprintfln(&e.b, "  store ptr null, ptr %s", address)
		return
	}
	if operations.intrinsic {
		value := load_place(e, type, address)
		owner := extract(e, STRING_TYPE, value, STRING_OWNER)
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_string_release(i64 %s)", owner)
		return
	}
	info := underlying_info(e.c, type)
	if info != nil && info.kind == .Array {
		emit_drop_elements_reversed(e, info.element, address, fmt.aprintf("%d", info.count))
		return
	}
	if info != nil && info.kind == .Union {
		emit_union_drop(e, type, info, address)
		return
	}
	hook := operations.custom_drop
	guards := guard_record_parts(e, type, address, hook != INVALID_SYMBOL)
	emit_drop_hook(e, hook, address)
	for index := len(guards) - 1; index >= 0; index -= 1 {
		finish_temporary_drop(e, guards[index])
		emit_drop_record_part(e, type, address, index)
	}
}

@(private = "file")
emit_drop_hook :: proc(e: ^Emitter, hook: Symbol_Id, address: string) {
	if hook != INVALID_SYMBOL {
		fmt.sbprintfln(&e.b, "  call void %s(ptr %s)", callee_name(e, hook), address)
	}
}

// Drops the active variant's payload only, then leaves the union inert so a
// second drop is a no-op.
@(private = "file")
emit_union_drop :: proc(e: ^Emitter, type: Type_Id, info: ^Type_Info, address: string) {
	shape := union_layout(e.c, type)
	value := load_place(e, type, address)
	tag := emit_union_tag(e, type, value)
	done := new_label(e, "uniondrop.done")
	for variant, index in info.variants {
		if variant == TYPE_VOID || !emit_lifecycle(e, variant).managed {
			continue
		}
		matched := temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp eq i%d %s, %d", matched, shape.tag_bytes * 8, tag, index)
		hit, next := new_label(e, "uniondrop.hit"), new_label(e, "uniondrop.next")
		branch_if(e, matched, hit, next)
		place_label(e, hit)
		emit_drop_place(e, variant, gep_field(e, llvm_type(e, type), address, 0))
		branch(e, done)
		place_label(e, next)
	}
	branch(e, done)
	place_label(e, done)
	store(e, type, "zeroinitializer", address)
}

// Each managed variant clones its one payload and rebuilds the union; there is
// no partial result to unwind.
@(private = "file")
emit_union_try_clone_body :: proc(
	e: ^Emitter, subject: Type_Id, info: ^Type_Info, result: Type_Id, value_type: string,
	subject_value: string,
) {
	shape := union_layout(e.c, subject)
	self := alloca(e, value_type)
	store(e, subject, subject_value, self)
	tag := emit_union_tag(e, subject, subject_value)

	for variant, index in info.variants {
		if variant == TYPE_VOID || !emit_lifecycle(e, variant).managed {
			continue
		}
		matched := temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp eq i%d %s, %d", matched, shape.tag_bytes * 8, tag, index)
		hit, next := new_label(e, "unionclone.hit"), new_label(e, "unionclone.next")
		branch_if(e, matched, hit, next)

		place_label(e, hit)
		source := gep_field(e, value_type, self, 0)
		cloned := ""
		if !emit_lifecycle(e, variant).clone_fallible {
			cloned = emit_clone_value(e, variant, load_place(e, variant, source), "%arg1")
		} else {
			value, failed, error := emit_part_clone(e, variant, source)
			broke, ok := new_label(e, "unionclone.failed"), new_label(e, "unionclone.ok")
			branch_if(e, failed, broke, ok)
			place_label(e, broke)
			emit_ret(e, result, emit_alloc_result(e, result, "true", error = error))
			place_label(e, ok)
			cloned = value
		}
		built := emit_union_value(e, subject, index, cloned)
		emit_ret(e, result, emit_alloc_result(e, result, "false", built))
		place_label(e, next)
	}

	// Every remaining tag holds a payload the representation already copies.
	emit_ret(e, result, emit_alloc_result(e, result, "false", subject_value))
}

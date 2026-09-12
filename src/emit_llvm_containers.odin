// Container operation tables, construction, and synthesized runtime bodies.
//
// Part of the textual LLVM backend; see compiler-architecture.md.
package lokec

import "core:fmt"
import "core:strings"

@(private)
emit_container_declarations :: proc(e: ^Emitter) {
	fmt.sbprintln(&e.b, "declare i32 @loke_rt_v1_dyn_reserve(ptr, ptr, i64)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_dyn_bind(ptr)")
	fmt.sbprintln(&e.b, "declare i32 @loke_rt_v1_dyn_append(ptr, ptr, ptr, i64)")
	fmt.sbprintln(&e.b, "declare i32 @loke_rt_v1_dyn_insert(ptr, ptr, i64, ptr, i64)")
	fmt.sbprintln(&e.b, "declare i32 @loke_rt_v1_dyn_pop(ptr, ptr, ptr)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_dyn_remove(ptr, ptr, i64, ptr, i32)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_dyn_clear(ptr, ptr)")
	fmt.sbprintln(&e.b, "declare i32 @loke_rt_v1_dyn_resize(ptr, ptr, i64)")
	fmt.sbprintln(&e.b, "declare i32 @loke_rt_v1_dyn_shrink(ptr, ptr, i64)")
	fmt.sbprintln(&e.b, "declare i32 @loke_rt_v1_dyn_clone(ptr, ptr, ptr, ptr)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_dyn_drop(ptr, ptr)")
	fmt.sbprintln(&e.b, "declare i32 @loke_rt_v1_map_reserve(ptr, ptr, i64)")
	fmt.sbprintln(&e.b, "declare i32 @loke_rt_v1_map_clone(ptr, ptr, ptr, ptr)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_map_drop(ptr, ptr)")
	fmt.sbprintln(&e.b, "declare i32 @loke_rt_v1_checked_add(i64, i64, ptr)")
	fmt.sbprintln(&e.b, "declare i32 @loke_rt_v1_checked_bytes(i64, i64, ptr)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_container_fault(ptr)")
	fmt.sbprintln(&e.b, "declare i64 @loke_rt_v1_hash_bytes(ptr, i64, i64)")
	fmt.sbprintln(&e.b, "declare i64 @loke_rt_v1_map_scan(ptr, ptr, i64, ptr, ptr)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_map_bind(ptr)")
	fmt.sbprintln(&e.b, "declare ptr @loke_rt_v1_map_find(ptr, ptr, ptr)")
	fmt.sbprintln(&e.b, "declare ptr @loke_rt_v1_map_entry(ptr, ptr, ptr, ptr)")
	fmt.sbprintln(&e.b, "declare i32 @loke_rt_v1_map_remove(ptr, ptr, ptr, ptr)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_map_clear(ptr, ptr)")
	fmt.sbprintln(&e.b, "declare i32 @loke_rt_v1_map_shrink(ptr, ptr, i64)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_sort(ptr, i64, i64, ptr, i32)")
	fmt.sbprintln(&e.b, "declare void @loke_rt_v1_sort_by(ptr, i64, i64, ptr, ptr)")
}

// The operation table for one concrete container type, made once and reused.
// Its element and key thunks are generated alongside it, so requesting the
// table is all a caller has to do.
@(private)
container_ops_global :: proc(e: ^Emitter, type: Type_Id) -> string {
	under := type_underlying(e.c, type)
	if existing, found := e.container_ops[under]; found {
		return existing
	}
	name := fmt.aprintf("@.loke.ops.%d", int(under))
	// Registered before the thunks are generated: a container whose element is
	// itself a container would otherwise recurse forever.
	e.container_ops[under] = name

	element := container_element(e.c, under)
	key := container_key(e.c, under)
	elem_drop := container_drop_thunk(e, element)
	// A move-only element has no clone. The container is then move-only too, so
	// no whole-container clone reaches the slot, and every insertion hands such an
	// element over rather than lending it (design.md "Container insertion"): the
	// memcpy NULL asks for is exactly that move.
	elem_clone := "null"
	if element == INVALID_TYPE || !emit_lifecycle(e, element).clone_disabled {
		elem_clone = container_clone_thunk(e, element)
	}
	key_drop, key_clone, key_hash, key_equal := "null", "null", "null", "null"
	key_size, key_align := u64(0), u64(0)
	if key != INVALID_TYPE {
		key_drop = container_drop_thunk(e, key)
		key_clone = container_clone_thunk(e, key)
		key_hash = container_hash_thunk(e, key)
		key_equal = container_equal_thunk(e, key)
		key_size, key_align = type_size(e.c, key), type_align(e.c, key)
	}
	// `{` is a directive to core:fmt, so the row is concatenated rather than
	// formatted.
	b := strings.builder_make()
	fmt.sbprintf(&b, "%s = private unnamed_addr constant %s ", name, CONTAINER_OPS_TYPE)
	strings.write_string(&b, "{")
	fmt.sbprintf(
		&b, " i64 %d, i64 %d, ptr %s, ptr %s, i64 %d, i64 %d, ptr %s, ptr %s, ptr %s, ptr %s }\n",
		type_size(e.c, element), type_align(e.c, element), elem_drop, elem_clone,
		key_size, key_align, key_drop, key_clone, key_hash, key_equal,
	)
	append(&e.globals, strings.to_string(b))
	return name
}

// `xs.sort()` and `s.sort()`: the data pointer, the element count, the element
// size, one generated comparison, and whether the order is reversed. Everything
// above that is `runtime/container.c`'s introsort.
@(private = "file")
emit_synth_sort :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	receiver := symbol.params[0]
	element := container_element(e.c, receiver)
	through_header := element != INVALID_TYPE
	if !through_header {
		element = slice_element(e.c, receiver)
	}

	argument := llvm_type(e, receiver)
	open_function(e, "define %svoid %s(%s %%arg0)", llvm_linkage(name), name, synth_param_llvm(e, symbol, 0))
	e.terminated = false

	// Every contributed member is emitted whether or not the program calls it,
	// and only a call resolves an element's `<`. So no settled comparison here
	// means this sort has no call site anywhere — a called one would have been
	// resolved by the checker's gate, or would have stopped the compile before
	// emission — and the body it needs is the empty one.
	#partial switch resolved_element_order_policy(e.c, element).kind {
	case .Builtin, .Inherent:
	case:
		fmt.sbprintln(&e.b, "  ret void")
		fmt.sbprintln(&e.b, "}")
		return
	}

	data, count := "", ""
	if through_header {
		// A mutating receiver arrives as the header's address, so both words are
		// loads rather than extracts.
		storage, length := temp(e), temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = getelementptr inbounds %s, ptr %%arg0, i32 0, i32 %d",
			storage, CONTAINER_TYPE, CONTAINER_STORAGE,
		)
		fmt.sbprintfln(
			&e.b, "  %s = getelementptr inbounds %s, ptr %%arg0, i32 0, i32 %d",
			length, CONTAINER_TYPE, CONTAINER_LEN,
		)
		data, count = temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = load ptr, ptr %s", data, storage)
		fmt.sbprintfln(&e.b, "  %s = load i64, ptr %s", count, length)
	} else {
		// A slice receiver is a borrow of the caller's header, so the two words are
		// read out of the loaded header rather than out of a by-value argument.
		self := synth_receiver_value(e, symbol)
		data, count = temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", data, argument, self, SLICE_DATA)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %s, %d", count, argument, self, SLICE_LEN)
	}

	fmt.sbprintfln(
		&e.b, "  call void @loke_rt_v1_sort(ptr %s, i64 %s, i64 %d, ptr %s, i32 %d)",
		data, count, type_size(e.c, element), container_less_thunk(e, element),
		symbol.container_op == .Reverse_Sort ? 1 : 0,
	)
	fmt.sbprintln(&e.b, "  ret void")
	fmt.sbprintln(&e.b, "}")
}

// `core:slice.sort_by` keeps its comparator typed in source. Its private
// intrinsic reaches here with a checked pointer to that value and the concrete
// immutable `call` method selected by the checker. Only this C ABI seam erases
// the comparator and element addresses; the runtime retains neither.
@(private)
emit_slice_sort_by :: proc(e: ^Emitter, v: ^Expr_Call) {
	if len(v.bound) != 2 || v.operation.(Call_Sort_By).comparator == INVALID_SYMBOL {
		backend_fail(e, "a checked slice sort_by has no comparator")
		return
	}

	slice_type := expr_base(v.bound[0]).type
	element := slice_element(e.c, slice_type)
	value := emit_expr(e, v.bound[0])
	storage := llvm_type(e, slice_type)
	data := extract(e, storage, value, SLICE_DATA)
	count := extract(e, storage, value, SLICE_LEN)
	ctx := emit_expr(e, v.bound[1])
	less := sort_by_thunk(e, element, v.operation.(Call_Sort_By).comparator)
	fmt.sbprintfln(
		&e.b, "  call void @loke_rt_v1_sort_by(ptr %s, i64 %s, i64 %d, ptr %s, ptr %s)",
		data, count, type_size(e.c, element), ctx, less,
	)
}

// One adapter per concrete comparator method. The method symbol already fixes
// both `C` and `T` — a generic `call` cannot satisfy the interface slot — but
// the element is keyed too, so a later relaxation of that would collide loudly
// instead of reusing an adapter that loads the wrong type.
@(private = "file")
sort_by_thunk :: proc(e: ^Emitter, element: Type_Id, method: Symbol_Id) -> string {
	name := fmt.aprintf("@loke.csortby.%d.%d", int(method), int(element))
	if e.container_thunks[name] {
		return name
	}
	e.container_thunks[name] = true
	// A thunk is shared with user code, so it never inherits a dead body's licence
	// to abort on a move-only copy, exactly as `container_thunk` does not.
	saved := e.synth_bodies
	e.synth_bodies = false
	defer e.synth_bodies = saved

	frame := begin_function_emission(e)
	open_function(e, "define private i32 %s(ptr %%state, ptr %%a, ptr %%b)", name)
	llvm := llvm_type(e, element)
	left := load(e, llvm, "%a")
	right := load(e, llvm, "%b")
	before := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = call i1 %s(ptr %%state, %s %s, %s %s)",
		before, symbol_name(e, method), llvm, left, llvm, right,
	)
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = zext i1 %s to i32", out, before)
	fmt.sbprintfln(&e.b, "  ret i32 %s", out)
	fmt.sbprintln(&e.b, "}")
	fmt.sbprintln(&e.b, "")
	finish_pending_thunk(e, frame)
	return name
}

// One comparison per element type, memoised exactly as the clone and drop
// thunks are. The policy behind it was settled during checking, so this never
// re-decides which `<` a type sorts by.
@(private = "file")
container_less_thunk :: proc(e: ^Emitter, element: Type_Id) -> string {
	return container_thunk(
		e, fmt.aprintf("@loke.cless.%d", int(element)), element,
		"i32", "ptr %a, ptr %b",
		proc(e: ^Emitter, element: Type_Id) {
			llvm := llvm_type(e, element)
			left := load(e, llvm, "%a")
			right := load(e, llvm, "%b")
			before := ""
			if policy := resolved_element_order_policy(e.c, element); policy.kind == .Inherent {
				before = temp(e)
				fmt.sbprintfln(
					&e.b, "  %s = call i1 %s(%s %s, %s %s)",
					before, symbol_name(e, policy.less), llvm, left, llvm, right,
				)
			} else {
				before = emit_compare(e, .Lt, element, left, right)
			}
			out := temp(e)
			fmt.sbprintfln(&e.b, "  %s = zext i1 %s to i32", out, before)
			fmt.sbprintfln(&e.b, "  ret i32 %s", out)
		},
	)
}

// Every part thunk is the same frame — a private definition with one entry
// block, parked because a function can't be defined inside the one that
// needed it. Only the signature and body differ, and each body writes its own
// `ret`.
@(private = "file")
container_thunk :: proc(
	e: ^Emitter,
	name: string,
	part: Type_Id,
	result, params: string,
	body: proc(e: ^Emitter, part: Type_Id),
) -> string {
	if e.container_thunks[name] {
		return name
	}
	e.container_thunks[name] = true
	// A thunk is shared with user code, so it never inherits a dead body's licence
	// to abort on a move-only copy.
	saved := e.synth_bodies
	e.synth_bodies = false
	defer e.synth_bodies = saved
	frame := begin_function_emission(e)
	open_function(e, "define private %s %s(%s)", result, name, params)
	body(e, part)
	fmt.sbprintln(&e.b, "}")
	fmt.sbprintln(&e.b, "")
	finish_pending_thunk(e, frame)
	return name
}

// A NULL `drop` means the part is trivially destroyed, which is what keeps the
// C loop out of the way entirely for a `[dynamic]int`.
@(private = "file")
container_drop_thunk :: proc(e: ^Emitter, part: Type_Id) -> string {
	if part == INVALID_TYPE || !emit_lifecycle(e, part).managed {
		return "null"
	}
	return container_thunk(
		e, fmt.aprintf("@loke.cdrop.%d", int(type_underlying(e.c, part))), part,
		"void", "ptr %p",
		proc(e: ^Emitter, part: Type_Id) {
			emit_drop_place(e, part, "%p")
			fmt.sbprintln(&e.b, "  ret void")
		},
	)
}

// A NULL `clone` means the part's clone is the copy its representation already
// is, so the C helper memcpys the whole run instead of calling back per element.
@(private = "file")
container_clone_thunk :: proc(e: ^Emitter, part: Type_Id) -> string {
	if part == INVALID_TYPE || !emit_lifecycle(e, part).managed {
		return "null"
	}
	return container_thunk(
		e, fmt.aprintf("@loke.cclone.%d", int(type_underlying(e.c, part))), part,
		"i32", "ptr %out, ptr %src, ptr %a",
		proc(e: ^Emitter, part: Type_Id) {
			ok := emit_try_clone_into(e, part, "%out", "%src", "%a")
			widened := temp(e)
			fmt.sbprintfln(&e.b, "  %s = zext i1 %s to i32", widened, ok)
			fmt.sbprintfln(&e.b, "  ret i32 %s", widened)
		},
	)
}

// The concrete operation table *freezes* the key's `==`/`hash` selection, so a
// map that travels between packages keeps one policy; the checker has already
// rejected a key with no coherent inherent pair, so this only emits whichever
// pair it settled on.
//
// Keyed by the key type itself, not its underlying one: a `distinct` key may
// carry its own inherent `==`/`hash` pair, so `map[Meters]` and `map[f64]` need
// two thunks, not whichever was emitted first.
@(private = "file")
container_hash_thunk :: proc(e: ^Emitter, key: Type_Id) -> string {
	return container_thunk(
		e, fmt.aprintf("@loke.chash.%d", int(key)), key,
		"i64", "ptr %p, i64 %seed",
		proc(e: ^Emitter, key: Type_Id) {
			value := load(e, llvm_type(e, key), "%p")
			out := ""
			if hook := key_policy_member(e, key, false); hook != INVALID_SYMBOL {
				// A user `hash` takes an immutable receiver, which wants the address
				// of the key (design.md "Receiver forms"). The thunk was handed that
				// address, so it forwards it rather than the loaded value.
				receiver_type, receiver := llvm_type(e, key), value
				if sym := symbol_of(e.c, hook);
				   sym != nil && param_mode_is_pointer(symbol_param_mode(e.c, sym, 0)) {
					receiver_type, receiver = "ptr", "%p"
				}
				out = temp(e)
				fmt.sbprintfln(
					&e.b, "  %s = call i64 %s(%s %s, i64 %%seed)",
					out, symbol_name(e, hook), receiver_type, receiver,
				)
			} else {
				out = emit_hash_value(e, key, value, "%seed")
			}
			fmt.sbprintfln(&e.b, "  ret i64 %s", out)
		},
	)
}

@(private = "file")
container_equal_thunk :: proc(e: ^Emitter, key: Type_Id) -> string {
	return container_thunk(
		e, fmt.aprintf("@loke.cequal.%d", int(key)), key,
		"i32", "ptr %a, ptr %b",
		proc(e: ^Emitter, key: Type_Id) {
			llvm := llvm_type(e, key)
			left := load(e, llvm, "%a")
			right := load(e, llvm, "%b")
			same := ""
			if hook := key_policy_member(e, key, true); hook != INVALID_SYMBOL {
				same = temp(e)
				fmt.sbprintfln(
					&e.b, "  %s = call i1 %s(%s %s, %s %s)",
					same, symbol_name(e, hook), llvm, left, llvm, right,
				)
			} else {
				same = emit_compare(e, .Eq_Eq, key, left, right)
			}
			out := temp(e)
			fmt.sbprintfln(&e.b, "  %s = zext i1 %s to i32", out, same)
			fmt.sbprintfln(&e.b, "  ret i32 %s", out)
		},
	)
}

// The key type's own inherent `hash` or `operator(==)`, or INVALID_SYMBOL when
// the compiler supplies the pair. An extension member is never one of these.
@(private = "file")
key_policy_member :: proc(e: ^Emitter, key: Type_Id, want_equal: bool) -> Symbol_Id {
	policy := resolved_map_key_policy(e.c, key)
	if policy.kind == .Unresolved {
		backend_fail(e, "a map key operation was not resolved during checking")
	}
	return want_equal ? policy.equal : policy.hash
}

// Writes a container declaration's written `via` into its header at the
// declaration point. A declaration with no policy is left allocator-unbound,
// which is what makes the lazy default binding observable.
@(private)
emit_eager_via_binding :: proc(e: ^Emitter, symbol_id: Symbol_Id, address: string) {
	sym := symbol_of(e.c, symbol_id)
	if sym == nil || sym.via == nil || !type_is_container(e.c, sym.type) {
		return
	}
	provider, slot := emit_expr(e, sym.via), temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = getelementptr inbounds %s, ptr %s, i32 0, i32 %d",
		slot, CONTAINER_TYPE, address, CONTAINER_ALLOC,
	)
	fmt.sbprintfln(&e.b, "  store ptr %s, ptr %s", provider, slot)
}

// The provider a construction into one destination selects: the declaration's
// written `via`, or the default when it has no policy. The policy belongs to
// the destination's own symbol, not anything the source value carries.
@(private)
emit_destination_allocator :: proc(e: ^Emitter, symbol_id: Symbol_Id) -> string {
	written := symbol_via_allocator(e.c, symbol_id)
	return written == nil ? emit_default_allocator(e) : emit_expr(e, written)
}

// The allocator a call selected: the one it was given, or the default provider
// when the argument was omitted. The checker already bound whichever it was, so
// this never re-derives the choice.
@(private)
emit_allocator_operand :: proc(e: ^Emitter, v: ^Expr_Call, index: int) -> string {
	if len(v.bound) > index {
		return emit_expr(e, v.bound[index])
	}
	return emit_default_allocator(e)
}

// `free_all` frees every allocation in the allocator's region, and not every
// allocator supports it (design.md). One call through the provider's reset
// callback, never a guessed sequence of `free` calls — only the provider knows
// what its region contains. A provider that answers "no region" fails at run
// time, distinct from the compile-time rejection when a dependant would
// survive the reset.
@(private)
emit_region_reset :: proc(e: ^Emitter, v: ^Expr_Call) {
	handle := emit_expr(e, v.bound[0])
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_reset(ptr %s)", handle)
}

// `[dynamic]T{a, b, c}` over the header this expression has already zeroed.
// Each element is appended as soon as it is evaluated, so the container owns
// the initialized prefix; a temporary unwind action covers that prefix while
// later expressions run, and destination ownership takes over only once the
// literal is complete.
@(private)
emit_dynamic_literal_into :: proc(e: ^Emitter, v: ^Expr_Composite, address: string, element: Type_Id, as_type: Type_Id) {
	if len(v.elements) == 0 {
		return
	}
	ops := container_ops_global(e, as_type)
	// The destination's own policy is written before the first reservation, so
	// the literal never allocates through a default-backed provider first.
	if v.via != nil {
		provider, slot := emit_expr(e, v.via), temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = getelementptr inbounds %s, ptr %s, i32 0, i32 %d",
			slot, CONTAINER_TYPE, address, CONTAINER_ALLOC,
		)
		fmt.sbprintfln(&e.b, "  store ptr %s, ptr %s", provider, slot)
	}
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_dyn_bind(ptr %s)", address)
	reserved := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = call i32 @loke_rt_v1_dyn_reserve(ptr %s, ptr %s, i64 %d)",
		reserved, address, ops, len(v.elements),
	)
	emit_container_policy_failure(e, address, reserved)
	cleanup := begin_temporary_drop(e, as_type, address)

	slot := alloca(e, llvm_type(e, element))
	for written, index in v.elements {
		value := emit_expr(e, written.value)
		if index < len(v.element_clones) && v.element_clones[index] {
			value = emit_clone_value(e, element, value)
		}
		store(e, element, value, slot)
		status := temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call i32 @loke_rt_v1_dyn_append(ptr %s, ptr %s, ptr %s, i64 1)",
			status, address, ops, slot,
		)
		emit_container_policy_failure(e, address, status)
		// The staged copy was cloned into the container, so this frame still owns
		// the temporary it appended from — unless the element is move-only, when
		// the append moved it and the container is its one owner.
		if !emit_lifecycle(e, element).clone_disabled {
			emit_drop_place(e, element, slot)
		}
	}
	finish_temporary_drop(e, cleanup)
}

// `map[K]V{ key = value, ... }` over the header this expression has already
// zeroed. Each entry is inserted as soon as it is evaluated, so a temporary
// unwind action lets the map destroy the prefix if a later key/value panics.
@(private)
emit_map_literal_into :: proc(e: ^Emitter, v: ^Expr_Composite, address: string, key, element: Type_Id, as_type: Type_Id) {
	if len(v.elements) == 0 {
		return
	}
	ops := container_ops_global(e, as_type)
	if v.via != nil {
		provider, slot := emit_expr(e, v.via), temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = getelementptr inbounds %s, ptr %s, i32 0, i32 %d",
			slot, CONTAINER_TYPE, address, CONTAINER_ALLOC,
		)
		fmt.sbprintfln(&e.b, "  store ptr %s, ptr %s", provider, slot)
	}
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_map_bind(ptr %s)", address)
	reserved := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = call i32 @loke_rt_v1_map_reserve(ptr %s, ptr %s, i64 %d)",
		reserved, address, ops, len(v.elements),
	)
	emit_container_policy_failure(e, address, reserved)
	cleanup := begin_temporary_drop(e, as_type, address)

	for written, index in v.elements {
		key_slot := alloca(e, llvm_type(e, key))
		store(e, key, emit_expr(e, written.key), key_slot)
		value := emit_expr(e, written.value)
		if index < len(v.element_clones) && v.element_clones[index] {
			value = emit_clone_value(e, element, value)
		}
		place, inserted := emit_map_entry(e, ops, address, key_slot)
		missing := temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp eq ptr %s, null", missing, place)
		fail_label, store_label, done_label :=
			new_label(e, "mlit.fail"), new_label(e, "mlit.store"), new_label(e, "mlit.done")
		branch_if(e, missing, fail_label, store_label)
		place_label(e, fail_label)
		emit_drop_place(e, key, key_slot)
		provider, slot := temp(e), temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = getelementptr inbounds %s, ptr %s, i32 0, i32 %d",
			slot, CONTAINER_TYPE, address, CONTAINER_ALLOC,
		)
		fmt.sbprintfln(&e.b, "  %s = load ptr, ptr %s", provider, slot)
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_alloc_failed(ptr %s)", provider)
		branch(e, done_label)
		place_label(e, store_label)
		// A new entry contains only inert zeroed storage. Only a duplicate key has
		// a live value that replacement must destroy.
		is_new := temp(e)
		replace_label, write_label := new_label(e, "mlit.replace"), new_label(e, "mlit.write")
		fmt.sbprintfln(&e.b, "  %s = icmp ne i32 %s, 0", is_new, inserted)
		branch_if(e, is_new, write_label, replace_label)
		place_label(e, replace_label)
		emit_drop_place(e, element, place)
		branch(e, write_label)
		place_label(e, write_label)
		store(e, element, value, place)
		emit_drop_place(e, key, key_slot)
		branch(e, done_label)
		place_label(e, done_label)
		e.terminated = false
	}
	finish_temporary_drop(e, cleanup)
}

// A container operation with no result to report through applies the provider's
// own failure policy, exactly as an implicit allocation does.
@(private = "file")
emit_container_policy_failure :: proc(e: ^Emitter, header, status: string) {
	failed := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq i32 %s, 0", failed, status)
	fail_label, done_label := new_label(e, "clit.fail"), new_label(e, "clit.done")
	branch_if(e, failed, fail_label, done_label)
	place_label(e, fail_label)
	slot := gep_field(e, CONTAINER_TYPE, header, CONTAINER_ALLOC)
	provider := load(e, "ptr", slot)
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_alloc_failed(ptr %s)", provider)
	branch(e, done_label)
	place_label(e, done_label)
	e.terminated = false
}

// ------------------------------------------------------- provider bodies --

// One contributed `mem.Arena`/`mem.Scratch` operation. The Loke value is one
// pointer to an address-stable control block, so each of these is a single
// runtime call and an `insertvalue`.
@(private)
emit_synth_provider_op :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	// `try_arena` returns `Result(Arena, Allocator_Error)`, so the provider type
	// is that result's success payload rather than the result itself.
	produced := symbol.result
	if symbol.provider_op == .Try_Open {
		produced = union_variant_payload(e.c, produced, union_index_of(e.c, produced, "ok"))
	}
	provider := llvm_type(e, produced == TYPE_ALLOCATOR ? symbol.params[0] : produced)
	result := llvm_result_type(e, symbol.result, symbol.result_inout)
	fmt.sbprintf(&e.b, "define %s%s %s(", llvm_linkage(name), result, name)
	for parameter, index in symbol.params {
		if index > 0 {
			fmt.sbprint(&e.b, ", ")
		}
		fmt.sbprintf(&e.b, "%s %%arg%d", llvm_type(e, parameter), index)
	}
	open_function(e, ")")
	e.terminated = false

	switch symbol.provider_op {
	case .None:
	case .Open:
		// Both temporaries are reserved before the open check, whose branch
		// consumes labels of its own; `insert` would otherwise number the result
		// after them.
		opened, out := temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = call ptr @loke_rt_v1_arena_open(ptr %%arg0)", opened)
		emit_provider_open_check(e, opened, "%arg0")
		fmt.sbprintfln(&e.b, "  %s = insertvalue %s undef, ptr %s, %d", out, provider, opened, PROVIDER_CONTROL)
		fmt.sbprintfln(&e.b, "  ret %s %s", provider, out)

	case .Open_Fixed:
		// Fixed storage cannot fail for want of memory. A buffer too small for the
		// control block is a program fault raised by the runtime.
		buffer := llvm_type(e, symbol.params[0])
		data := extract(e, buffer, "%arg0", SLICE_DATA)
		length := extract(e, buffer, "%arg0", SLICE_LEN)
		opened := temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call ptr @loke_rt_v1_arena_open_fixed(ptr %s, i64 %s)", opened, data, length,
		)
		out := insert(e, provider, "undef", "ptr", opened, PROVIDER_CONTROL)
		fmt.sbprintfln(&e.b, "  ret %s %s", provider, out)

	case .Try_Open:
		opened := temp(e)
		fmt.sbprintfln(&e.b, "  %s = call ptr @loke_rt_v1_arena_open(ptr %%arg0)", opened)
		value := insert(e, provider, "undef", "ptr", opened, PROVIDER_CONTROL)
		failed := temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp eq ptr %s, null", failed, opened)
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
	e.terminated = true
}

@(private = "file")
emit_provider_open_check :: proc(e: ^Emitter, control, allocator: string) {
	failed := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq ptr %s, null", failed, control)
	fail, done := new_label(e, "arena.failed"), new_label(e, "ok")
	branch_if(e, failed, fail, done)
	place_label(e, fail)
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_alloc_failed(ptr %s)", allocator)
	fmt.sbprintln(&e.b, "  unreachable")
	e.terminated = true
	place_label(e, done)
}

// ------------------------------------------------------ container bodies --

// One contributed container operation. Every one is a call into the versioned
// C helper with this type's operation table; what differs is how the
// arguments arrive and what comes back.
//
// A fallible operation has two forms: `try_` returns the error and lets the
// caller decide, while the ordinary one has nowhere to report it, so it
// applies the *allocator's* failure policy, as design.md's "Allocation
// failure" requires of an implicit allocation.
@(private)
emit_synth_container_op :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	// A sort is the one contributed operation that also serves a `[]mut T`, so it
	// reads its data and count from whichever of the two receivers it has rather
	// than from the operation table, which a slice has none of.
	#partial switch symbol.container_op {
	case .Sort, .Reverse_Sort:
		emit_synth_sort(e, symbol, name)
		return
	}
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	container := symbol.params[0]
	element := container_element(e.c, container)
	element_llvm := llvm_type(e, element)
	ops := container_ops_global(e, container)
	fallible := symbol.result != INVALID_TYPE && type_is_union(e.c, symbol.result)
	// design.md "Container insertion": a move-only element is handed over, not
	// lent, so it is stored without a clone and this body owns it until then.
	moves := emit_lifecycle(e, element).clone_disabled

	result := llvm_result_type(e, symbol.result, symbol.result_inout)
	fmt.sbprintf(&e.b, "define %s%s %s(", llvm_linkage(name), result, name)
	for parameter, index in symbol.params {
		if index > 0 {
			fmt.sbprint(&e.b, ", ")
		}
		// Both receiver modes arrive as the address of the caller's storage
		// (design.md "Receiver forms"); every other parameter crosses by value.
		_ = parameter
		fmt.sbprintf(&e.b, "%s %%arg%d", synth_param_llvm(e, symbol, index), index)
	}
	open_function(e, ")")
	e.terminated = false

	// A single value entering the container is spilled so the helper can read it
	// through a pointer, exactly as it reads a `..T` pack's storage.
	value_storage :: proc(e: ^Emitter, element: Type_Id, argument: string) -> string {
		slot := alloca(e, llvm_type(e, element))
		fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", llvm_type(e, element), argument, slot)
		return slot
	}

	status := ""
	switch symbol.container_op {
	case .Append:
		data, count := temp(e), temp(e)
		pack := llvm_type(e, symbol.params[1])
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %%arg1, %d", data, pack, SLICE_DATA)
		fmt.sbprintfln(&e.b, "  %s = extractvalue %s %%arg1, %d", count, pack, SLICE_LEN)
		status = temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call i32 @loke_rt_v1_dyn_append(ptr %%arg0, ptr %s, ptr %s, i64 %s)",
			status, ops, data, count,
		)
		if moves {
			kept := branch_on_failure(e, status)
			emit_drop_run(e, element, data, count)
			rejoin(e, kept)
		}

	case .Insert:
		slot := value_storage(e, element, "%arg2")
		status = temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call i32 @loke_rt_v1_dyn_insert(ptr %%arg0, ptr %s, i64 %%arg1, ptr %s, i64 1)",
			status, ops, slot,
		)
		// A copyable value parameter is borrowed, and its caller owns any
		// temporary cleanup. A move-only one was handed over.
		if moves {
			kept := branch_on_failure(e, status)
			emit_drop_place(e, element, slot)
			rejoin(e, kept)
		}

	case .Pop:
		out := alloca(e, element_llvm)
		found := temp(e)
		fmt.sbprintfln(&e.b, "  %s = call i32 @loke_rt_v1_dyn_pop(ptr %%arg0, ptr %s, ptr %s)", found, ops, out)
		value, ok := temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = load %s, ptr %s", value, element_llvm, out)
		fmt.sbprintfln(&e.b, "  %s = icmp ne i32 %s, 0", ok, found)
		fmt.sbprintfln(&e.b, "  ret %s %s", result, emit_option_value(e, symbol.result, ok, value))
		fmt.sbprintln(&e.b, "}")
		return

	case .Remove, .Remove_Unordered:
		out := alloca(e, element_llvm)
		fmt.sbprintfln(
			&e.b, "  call void @loke_rt_v1_dyn_remove(ptr %%arg0, ptr %s, i64 %%arg1, ptr %s, i32 %d)",
			ops, out, symbol.container_op == .Remove_Unordered ? 1 : 0,
		)
		value := load(e, element_llvm, out)
		fmt.sbprintfln(&e.b, "  ret %s %s", element_llvm, value)
		fmt.sbprintln(&e.b, "}")
		return

	case .Clear:
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_dyn_clear(ptr %%arg0, ptr %s)", ops)
		fmt.sbprintln(&e.b, "  ret void")
		fmt.sbprintln(&e.b, "}")
		return

	case .Resize:
		status = temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call i32 @loke_rt_v1_dyn_resize(ptr %%arg0, ptr %s, i64 %%arg1)", status, ops,
		)

	case .Reserve:
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_dyn_bind(ptr %%arg0)")
		status = temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call i32 @loke_rt_v1_dyn_reserve(ptr %%arg0, ptr %s, i64 %%arg1)", status, ops,
		)

	case .Shrink:
		status = temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call i32 @loke_rt_v1_dyn_shrink(ptr %%arg0, ptr %s, i64 %%arg1)", status, ops,
		)

	case .Map_Find:
		// Returns a pointer to the existing value and `true`, or `nil` and `false`;
		// never inserts (design.md).
		slot := value_storage(e, container_key(e.c, container), "%arg1")
		found, ok := temp(e), temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call ptr @loke_rt_v1_map_find(ptr %%arg0, ptr %s, ptr %s)", found, ops, slot,
		)
		fmt.sbprintfln(&e.b, "  %s = icmp ne ptr %s, null", ok, found)
		fmt.sbprintfln(&e.b, "  ret %s %s", result, emit_option_value(e, symbol.result, ok, found))
		fmt.sbprintln(&e.b, "}")
		return

	case .Map_Lookup_Value:
		// design.md "Maps": one probe, no insertion, and an independently owned
		// payload on a hit. The immutable receiver is already the address of the
		// caller's header, which is what the C probe reads; nothing writes through
		// it (design.md "Receiver forms").
		key_type := container_key(e.c, container)
		header := "%arg0"
		if !param_mode_is_pointer(symbol_param_mode(e.c, symbol, 0)) {
			header = alloca(e, CONTAINER_TYPE)
			fmt.sbprintfln(&e.b, "  store %s %%arg0, ptr %s", CONTAINER_TYPE, header)
		}
		key_slot := value_storage(e, key_type, "%arg1")
		found := temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call ptr @loke_rt_v1_map_find(ptr %s, ptr %s, ptr %s)", found, header, ops, key_slot,
		)
		present := temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp ne ptr %s, null", present, found)

		// The result is built the same way whether the caller keeps it or not, and
		// the clone happens *here* — exactly once, on the hit path only, so the map
		// keeps its own storage and the destination must not copy again.
		out := alloca(e, element_llvm)
		fmt.sbprintfln(&e.b, "  store %s zeroinitializer, ptr %s", element_llvm, out)
		if zero, zeroed := zero_const(e.c, element); zeroed {
			fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", element_llvm, llvm_const(e, zero, element), out)
		}
		hit_label, done_label := new_label(e, "mlookup.hit"), new_label(e, "mlookup.done")
		branch_if(e, present, hit_label, done_label)
		place_label(e, hit_label)
		stored := load(e, element_llvm, found)
		if emit_lifecycle(e, element).managed {
			stored = emit_clone_value(e, element, stored)
		}
		store(e, element, stored, out)
		branch(e, done_label)
		place_label(e, done_label)
		e.terminated = false

		value := load(e, element_llvm, out)
		fmt.sbprintfln(&e.b, "  ret %s %s", result, emit_option_value(e, symbol.result, present, value))
		fmt.sbprintln(&e.b, "}")
		return

	case .Map_Find_Or_Insert:
		// design.md "Maps": the slot either way. An existing entry is answered
		// without touching the table; an absent key inserts the supplied element,
		// which the map must then own, so it is cloned exactly as `try_insert`
		// clones — or, being move-only, moved in, and dropped on a hit instead.
		// Nothing manufactures a zero, so a no-zero element is insertable.
		key_slot := value_storage(e, container_key(e.c, container), "%arg1")
		found, present := temp(e), temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call ptr @loke_rt_v1_map_find(ptr %%arg0, ptr %s, ptr %s)", found, ops, key_slot,
		)
		fmt.sbprintfln(&e.b, "  %s = icmp ne ptr %s, null", present, found)
		hit_label, miss_label := new_label(e, "mfoi.hit"), new_label(e, "mfoi.miss")
		branch_if(e, present, hit_label, miss_label)
		place_label(e, hit_label)
		if moves {
			emit_drop_place(e, element, value_storage(e, element, "%arg2"))
		}
		emit_map_slot_result(e, symbol.result, result, found, fallible)

		place_label(e, miss_label)
		staged := alloca(e, element_llvm)
		cloned := "true"
		if moves {
			store(e, element, "%arg2", staged)
		} else if emit_lifecycle(e, element).managed {
			cloned = emit_try_clone_into(
				e, element, staged, value_storage(e, element, "%arg2"), emit_map_allocator(e, "%arg0"),
			)
		} else {
			store(e, element, "%arg2", staged)
		}
		clone_ready, clone_failed := new_label(e, "mfoi.cloned"), new_label(e, "mfoi.clone_failed")
		branch_if(e, cloned, clone_ready, clone_failed)
		place_label(e, clone_failed)
		emit_map_slot_failure(e, symbol.result, result, "%arg0", fallible)

		place_label(e, clone_ready)
		place, _ := emit_map_entry(e, ops, "%arg0", key_slot)
		missing := temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp eq ptr %s, null", missing, place)
		entry_failed, entry_ok := new_label(e, "mfoi.failed"), new_label(e, "mfoi.ok")
		branch_if(e, missing, entry_failed, entry_ok)
		place_label(e, entry_failed)
		emit_drop_place(e, element, staged)
		emit_map_slot_failure(e, symbol.result, result, "%arg0", fallible)

		place_label(e, entry_ok)
		// The key was absent a moment ago, so this slot is new: inert bytes with
		// no live value to drop before the clone is committed.
		store(e, element, load(e, element_llvm, staged), place)
		emit_map_slot_result(e, symbol.result, result, place, fallible)
		fmt.sbprintln(&e.b, "}")
		return

	case .Map_Try_Insert:
		key_type := container_key(e.c, container)
		// Stage the value clone before asking the runtime for an inserting place.
		// A fallible clone must leave an existing entry untouched, and must not
		// publish a new key whose value could not be constructed.
		allocator := emit_map_allocator(e, "%arg0")
		staged := alloca(e, element_llvm)
		cloned := "true"
		if moves {
			store(e, element, "%arg2", staged)
		} else if emit_lifecycle(e, element).managed {
			source := value_storage(e, element, "%arg2")
			cloned = emit_try_clone_into(e, element, staged, source, allocator)
		} else {
			store(e, element, "%arg2", staged)
		}
		clone_ready, clone_failed := new_label(e, "mins.cloned"), new_label(e, "mins.clone_failed")
		branch_if(e, cloned, clone_ready, clone_failed)
		place_label(e, clone_failed)
		fmt.sbprintfln(&e.b, "  ret %s %s", result, emit_alloc_result(e, symbol.result, "true"))
		e.terminated = true

		place_label(e, clone_ready)
		key_slot := value_storage(e, key_type, "%arg1")
		place, inserted := emit_map_entry(e, ops, "%arg0", key_slot)
		missing, ok_label, failed_label := temp(e), new_label(e, "mins.ok"), new_label(e, "mins.failed")
		fmt.sbprintfln(&e.b, "  %s = icmp eq ptr %s, null", missing, place)
		branch_if(e, missing, failed_label, ok_label)
		place_label(e, failed_label)
		emit_drop_place(e, element, staged)
		fmt.sbprintfln(&e.b, "  ret %s %s", result, emit_alloc_result(e, symbol.result, "true"))
		e.terminated = true

		place_label(e, ok_label)
		// The clone is complete, so replacement can now commit without a failure
		// point between destroying the old value and publishing the new one. A new
		// slot contains inert bytes, not a live element, and must not be dropped.
		is_new := temp(e)
		replace_label, store_label := new_label(e, "mins.replace"), new_label(e, "mins.store")
		fmt.sbprintfln(&e.b, "  %s = icmp ne i32 %s, 0", is_new, inserted)
		branch_if(e, is_new, store_label, replace_label)
		place_label(e, replace_label)
		emit_drop_place(e, element, place)
		branch(e, store_label)
		place_label(e, store_label)
		stored := load(e, element_llvm, staged)
		store(e, element, stored, place)
		fmt.sbprintfln(&e.b, "  ret %s %s", result, emit_alloc_result(e, symbol.result, "false"))
		fmt.sbprintln(&e.b, "}")
		e.terminated = true
		return

	case .Map_Entries, .Map_Keys, .Map_Values:
		// design.md "Iteration adapters": a view is the table pointer and nothing
		// else — no allocation, no element copy, and no second header for anything
		// to drop. The `iter` it answers to turns it into `{ table, 0 }`.
		table := extract(e, llvm_type(e, container), synth_receiver_value(e, symbol), CONTAINER_STORAGE)
		view := insert(e, result, "undef", "ptr", table, VIEW_SOURCE)
		fmt.sbprintfln(&e.b, "  ret %s %s", result, view)
		fmt.sbprintln(&e.b, "}")
		return

	case .Map_Remove:
		key_type := container_key(e.c, container)
		key_slot := value_storage(e, key_type, "%arg1")
		out := alloca(e, element_llvm)
		found := temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call i32 @loke_rt_v1_map_remove(ptr %%arg0, ptr %s, ptr %s, ptr %s)",
			found, ops, key_slot, out,
		)
		value := load(e, element_llvm, out)
		ok := temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp ne i32 %s, 0", ok, found)
		fmt.sbprintfln(&e.b, "  ret %s %s", result, emit_option_value(e, symbol.result, ok, value))
		fmt.sbprintln(&e.b, "}")
		return

	case .Map_Clear:
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_map_clear(ptr %%arg0, ptr %s)", ops)
		fmt.sbprintln(&e.b, "  ret void")
		fmt.sbprintln(&e.b, "}")
		return

	case .Map_Reserve:
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_map_bind(ptr %%arg0)")
		status = temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call i32 @loke_rt_v1_map_reserve(ptr %%arg0, ptr %s, i64 %%arg1)", status, ops,
		)

	case .Map_Shrink:
		status = temp(e)
		fmt.sbprintfln(
			&e.b, "  %s = call i32 @loke_rt_v1_map_shrink(ptr %%arg0, ptr %s, i64 %%arg1)", status, ops,
		)

	case .None, .Sort, .Reverse_Sort:
		// `.Sort`/`.Reverse_Sort` returned above; reaching here is a dispatch bug.
		backend_fail(e, "a contributed container member has no operation")
		fmt.sbprintln(&e.b, "  ret void")
		fmt.sbprintln(&e.b, "}")
		return
	}

	failed := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq i32 %s, 0", failed, status)
	if fallible {
		fmt.sbprintfln(&e.b, "  ret %s %s", result, emit_alloc_result(e, symbol.result, failed))
		fmt.sbprintln(&e.b, "}")
		return
	}
	// The ordinary form has no result to report through, so the provider's own
	// policy decides: `.Panic` follows the program strategy, `.Trap` terminates.
	provider, fail_label, done_label := temp(e), new_label(e, "cop.fail"), new_label(e, "cop.done")
	branch_if(e, failed, fail_label, done_label)
	place_label(e, fail_label)
	slot := gep_field(e, CONTAINER_TYPE, "%arg0", CONTAINER_ALLOC)
	fmt.sbprintfln(&e.b, "  %s = load ptr, ptr %s", provider, slot)
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_alloc_failed(ptr %s)", provider)
	branch(e, done_label)
	place_label(e, done_label)
	e.terminated = false
	fmt.sbprintln(&e.b, "  ret void")
	fmt.sbprintln(&e.b, "}")
}

// A move-only element that failed to enter the container was never stored, so
// the body it was handed to still owns it. `branch_on_failure` opens the block
// that drops it; `rejoin` closes that block and continues past it.
@(private = "file")
branch_on_failure :: proc(e: ^Emitter, status: string) -> string {
	failed := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq i32 %s, 0", failed, status)
	drop_label, kept_label := new_label(e, "cop.unconsumed"), new_label(e, "cop.kept")
	branch_if(e, failed, drop_label, kept_label)
	place_label(e, drop_label)
	return kept_label
}

@(private = "file")
rejoin :: proc(e: ^Emitter, kept_label: string) {
	branch(e, kept_label)
	place_label(e, kept_label)
	e.terminated = false
}

// Every element of a `..T` pack, in order.
@(private = "file")
emit_drop_run :: proc(e: ^Emitter, element: Type_Id, data, count: string) {
	index_slot := alloca(e, "i64")
	fmt.sbprintfln(&e.b, "  store i64 0, ptr %s", index_slot)
	head, body, done := new_label(e, "unconsumed.head"), new_label(e, "unconsumed.body"), new_label(e, "unconsumed.done")
	branch(e, head)
	place_label(e, head)
	index := load(e, "i64", index_slot)
	more := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp ult i64 %s, %s", more, index, count)
	branch_if(e, more, body, done)
	place_label(e, body)
	at := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = getelementptr inbounds %s, ptr %s, i64 %s", at, llvm_type(e, element), data, index,
	)
	emit_drop_place(e, element, at)
	next := temp(e)
	fmt.sbprintfln(&e.b, "  %s = add i64 %s, 1", next, index)
	fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", next, index_slot)
	branch(e, head)
	place_label(e, done)
	e.terminated = false
}

// `key in m`: one probe, no insertion and no value.
@(private)
emit_map_membership :: proc(e: ^Emitter, v: ^Expr_Binary) -> string {
	container := expr_base(v.rhs).type
	key := container_key(e.c, container)
	ops := container_ops_global(e, container)
	header := emit_address(e, v.rhs)
	value := emit_expr(e, v.lhs)
	key_slot := alloca(e, llvm_type(e, key))
	store(e, key, value, key_slot)
	cleanup := Deferred{slot = -1}
	if emit_lifecycle(e, key).managed && !expression_is_borrowed_place(e.c, v.lhs) {
		cleanup = begin_temporary_drop(e, key, key_slot)
	}
	found, out := temp(e), temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = call ptr @loke_rt_v1_map_find(ptr %s, ptr %s, ptr %s)", found, header, ops, key_slot,
	)
	drop_temporary_value(e, cleanup)
	fmt.sbprintfln(&e.b, "  %s = icmp ne ptr %s, null", out, found)
	return out
}

// The map's own provider, or the build-selected default when it is unbound.
@(private = "file")
emit_map_allocator :: proc(e: ^Emitter, header: string) -> string {
	bound := load(e, "ptr", gep_field(e, CONTAINER_TYPE, header, CONTAINER_ALLOC))
	unbound, allocator := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq ptr %s, null", unbound, bound)
	fmt.sbprintfln(
		&e.b, "  %s = select i1 %s, ptr %s, ptr %s", allocator, unbound, emit_default_allocator(e), bound,
	)
	return allocator
}

// `find_or_insert` answers the slot itself; `try_find_or_insert` answers it as
// `.ok` (design.md "Map container operations").
@(private = "file")
emit_map_slot_result :: proc(e: ^Emitter, result_type: Type_Id, result, slot: string, fallible: bool) {
	if fallible {
		fmt.sbprintfln(&e.b, "  ret %s %s", result, emit_alloc_result(e, result_type, "false", slot))
	} else {
		fmt.sbprintfln(&e.b, "  ret %s %s", result, slot)
	}
	e.terminated = true
}

// Its failure: the error for the `try_` spelling, and the provider's own policy
// for the one that has nowhere to report it (design.md "Allocation failure").
@(private = "file")
emit_map_slot_failure :: proc(e: ^Emitter, result_type: Type_Id, result, header: string, fallible: bool) {
	if fallible {
		fmt.sbprintfln(&e.b, "  ret %s %s", result, emit_alloc_result(e, result_type, "true", "null"))
		e.terminated = true
		return
	}
	provider := load(e, "ptr", gep_field(e, CONTAINER_TYPE, header, CONTAINER_ALLOC))
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_alloc_failed(ptr %s)", provider)
	fmt.sbprintfln(&e.b, "  ret %s null", result)
	e.terminated = true
}

// `m[key] = elem` (design.md "Maps"): the one index form that creates an entry.
// The written value is committed into the slot the runtime hands back, so no
// element zero is ever manufactured and a no-zero element inserts like any
// other. A new slot holds inert bytes; only an existing entry holds a live
// value that replacement must drop first. The insertion allocates, and an
// assignment has nowhere to report a failure, so the provider's policy decides.
// Capture the receiver and key with the other assignment destinations. Delay
// insertion until the write phase, without reevaluating either expression.
@(private)
Map_Assignment_Destination :: struct {
	container: Type_Id,
	header, key_slot: string,
	key_cleanup: Deferred,
}

@(private)
prepare_map_assignment :: proc(e: ^Emitter, v: ^Expr_Index, snapshot_key: bool) -> Map_Assignment_Destination {
	container := expr_base(v.operand).type
	header := emit_address(e, v.operand)
	key_slot, cleanup := emit_map_key_slot(e, v, container)
	key := container_key(e.c, container)
	// An earlier destination can replace the variable supplying this key. Keep
	// an independent snapshot when a multiple assignment may write it first.
	if snapshot_key && emit_lifecycle(e, key).managed && expression_is_borrowed_place(e.c, v.indices[0]) {
		value := emit_clone_value(e, key, load(e, llvm_type(e, key), key_slot))
		store(e, key, value, key_slot)
		cleanup = begin_temporary_drop(e, key, key_slot)
	}
	return Map_Assignment_Destination{container, header, key_slot, cleanup}
}

@(private)
emit_map_insert_store :: proc(e: ^Emitter, destination: Map_Assignment_Destination, value: string, guard: Deferred) {
	container, header, key_slot := destination.container, destination.header, destination.key_slot
	element := container_element(e.c, container)
	ops := container_ops_global(e, container)
	place, inserted := emit_map_entry(e, ops, header, key_slot)
	missing := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq ptr %s, null", missing, place)
	fail_label, store_label, done_label :=
		new_label(e, "mset.fail"), new_label(e, "mset.store"), new_label(e, "mset.done")
	branch_if(e, missing, fail_label, store_label)
	place_label(e, fail_label)
	provider := load(e, "ptr", gep_field(e, CONTAINER_TYPE, header, CONTAINER_ALLOC))
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_alloc_failed(ptr %s)", provider)
	branch(e, done_label)
	place_label(e, store_label)
	is_new := temp(e)
	replace_label, write_label := new_label(e, "mset.replace"), new_label(e, "mset.write")
	fmt.sbprintfln(&e.b, "  %s = icmp ne i32 %s, 0", is_new, inserted)
	branch_if(e, is_new, write_label, replace_label)
	place_label(e, replace_label)
	emit_drop_place(e, element, place)
	branch(e, write_label)
	place_label(e, write_label)
	store(e, element, value, place)
	// The map owns a live value before a user key destructor can panic. The
	// incoming value's guard covers all failures before this ownership transfer.
	finish_temporary_drop(e, guard)
	drop_temporary_value(e, destination.key_cleanup)
	branch(e, done_label)
	place_label(e, done_label)
	e.terminated = false
}

// The address of `m[key]` in every position but that one: the existing slot.
// A read, a field or index chain, a compound assignment, an `inout` argument
// and `&m[key]` all name a location inside an element that must already be
// there, so a missing key panics exactly as a dynamic array's index does
// (design.md "Maps").
@(private)
emit_map_element_address :: proc(e: ^Emitter, v: ^Expr_Index) -> string {
	container := expr_base(v.operand).type
	ops := container_ops_global(e, container)
	header := emit_address(e, v.operand)
	key_slot, cleanup := emit_map_key_slot(e, v, container)

	found := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = call ptr @loke_rt_v1_map_find(ptr %s, ptr %s, ptr %s)", found, header, ops, key_slot,
	)
	drop_temporary_value(e, cleanup)
	absent := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp eq ptr %s, null", absent, found)
	panic_if(e, absent, "mkey", "map key not found")
	return found
}

// `m[key]` as a read. Always one value: `m.lookup_value(key)` is the `Option(V)`
// form, and it is a call rather than an index.
@(private)
emit_map_lookup :: proc(e: ^Emitter, v: ^Expr_Index) -> string {
	element_llvm := llvm_type(e, container_element(e.c, expr_base(v.operand).type))
	return load(e, element_llvm, emit_map_element_address(e, v))
}

// The C helper borrows the spilled key. Only an owned temporary needs cleanup;
// spilling a borrowed place does not transfer its ownership to the probe.
@(private = "file")
emit_map_key_slot :: proc(e: ^Emitter, v: ^Expr_Index, container: Type_Id) -> (string, Deferred) {
	key := container_key(e.c, container)
	value := emit_expr(e, v.indices[0])
	slot := alloca(e, llvm_type(e, key))
	store(e, key, value, slot)
	cleanup := Deferred{slot = -1}
	if emit_lifecycle(e, key).managed && !expression_is_borrowed_place(e.c, v.indices[0]) {
		cleanup = begin_temporary_drop(e, key, slot)
	}
	return slot, cleanup
}

// Finds or creates a map slot. The runtime distinguishes a newly inserted
// inert slot from an existing live value. Every inserting caller must commit
// its supplied value before invoking hooks that could observe the new entry.
@(private = "file")
emit_map_entry :: proc(e: ^Emitter, ops, header, key_slot: string) -> (string, string) {
	inserted := alloca(e, "i32")
	place := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = call ptr @loke_rt_v1_map_entry(ptr %s, ptr %s, ptr %s, ptr %s)",
		place, header, ops, key_slot, inserted,
	)
	was_inserted := load(e, "i32", inserted)
	return place, was_inserted
}

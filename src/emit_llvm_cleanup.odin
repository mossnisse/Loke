// Cleanup registration: scopes, full-expression frames, and held values.
//
// Part of the textual LLVM backend; see compiler-architecture.md.
package lokec

import "core:fmt"
import "core:slice"

// What a registered cleanup action runs.
@(private)
Deferred_Kind :: enum {
	// A managed local's implicit drop of `place`.
	Local,
	// A written `defer`, `stmt`.
	Written,
	// A compiler-owned temporary, which has no symbol; its address is published
	// at `place_env` so panic replay can reach it.
	Temporary,
	// A compiler-owned variadic buffer with per-element flags, or, with no flags,
	// the first `count` elements of an array that a drop or a clone is working
	// through. The env indices serve the unwind thunk; the direct names serve
	// normal cleanup.
	Array,
	// A box's allocation, published at `place_env`, whose payload `type` is being
	// dropped: replay releases the allocation and nothing else.
	Box_Release,
	// A spawn's frame of record `type`, published at `place_env`, which no task
	// has claimed: replay returns it to the default provider.
	Frame_Release,
	// A variadic pack's storage, whose `PACK_RELEASE_TYPE` record at `place` (and
	// published at `place_env`) names a block to release, or null for one on the
	// stack.
	Pack_Release,
}

// One registered cleanup action. The zero value registers nothing. Written
// `defer`s and implicit drops share one reverse registration order
// (design.md "Managed values and storage").
@(private)
Deferred :: struct {
	kind: Deferred_Kind,
	// Empty when the CFG proved the slot reached unconditionally.
	flag: string,
	stmt:  Stmt,
	// `errdefer`: run only on an exit returning the failure variant, or by
	// panic replay.
	on_failure: bool,
	place: string,
	place_env:       int,
	place_symbol:    Symbol_Id,
	type:  Type_Id,
	array_buffer:   string,
	array_flags:    string,
	array_count:    string,
	array_buffer_env: int,
	array_flags_env:  int,
	array_count_env:  int,
	// The `@(initialized)` array whose count field `array_count` addresses, which
	// replay reads when it runs and range-checks; INVALID_TYPE for a count the
	// compiler keeps itself.
	array_counted: Type_Id,
	// Index + 1 in the procedure's registration state; 0 when not registered,
	// as under `-panic=abort`.
	slot: int,
	// When a compiler-owned value was registered, so an exit that owes several
	// drops them newest first (design.md "Evaluation order").
	order: int,
}

// Registers `entry`, whose storage the thunk finds through one env slot.
@(private = "file")
register_published :: proc(e: ^Emitter, entry: ^Deferred, address: string) {
	if !unwind_enabled(e) {
		return
	}
	if !unwind_reuse(e, entry) {
		entry.place_env = unwind_reserve_env(e)
		unwind_reserve(e, entry)
	}
	unwind_publish_env(e, entry.place_env, address)
	unwind_register(e, entry^)
}

// Registers a partially constructed compiler-owned value for panic replay only;
// the builder clears it once complete.
@(private)
begin_temporary_drop :: proc(e: ^Emitter, type: Type_Id, place: string) -> Deferred {
	entry := Deferred{kind = .Temporary, type = type, place = place, order = next_id(e)}
	register_published(e, &entry, place)
	return entry
}

// design.md "Failure to start a task": a spawn's frame is the
// parent's until `Task_Scope.start` returns, so a panic before then, in an
// argument or in starting the thread, releases it.
@(private)
begin_frame_release :: proc(e: ^Emitter, frame_type: Type_Id, frame: string) -> Deferred {
	entry := Deferred{kind = .Frame_Release, type = frame_type}
	register_published(e, &entry, frame)
	return entry
}

@(private)
emit_frame_release :: proc(e: ^Emitter, frame_type: Type_Id, frame: string) {
	emit_rt_free(e, emit_default_allocator(e), frame, type_size(e.c, frame_type), type_align(e.c, frame_type))
}

// A pack's storage record: the provider, the block or null, and its size in bytes.
PACK_RELEASE_TYPE :: "{ ptr, ptr, i64 }"

// design.md "Variadic parameters": a pack allocated from the default provider is
// its call's until the call returns, so a panic in the callee releases it.
@(private)
begin_pack_release :: proc(e: ^Emitter, element: Type_Id, record: string) -> Deferred {
	entry := Deferred{kind = .Pack_Release, type = element, place = record, order = next_id(e)}
	register_published(e, &entry, record)
	return entry
}

// Releases the block `record` names, if any.
@(private)
emit_pack_release :: proc(e: ^Emitter, element: Type_Id, record: string) {
	block := load(e, "ptr", gep_field(e, PACK_RELEASE_TYPE, record, 1))
	taken := not_null(e, block)
	release, done := new_label(e, "pack.release"), new_label(e, "pack.done")
	branch_if(e, taken, release, done)
	place_label(e, release)
	allocator := load(e, "ptr", gep_field(e, PACK_RELEASE_TYPE, record, 0))
	bytes := load(e, "i64", gep_field(e, PACK_RELEASE_TYPE, record, 2))
	emit_rt_free_sized(e, allocator, block, bytes, type_align(e.c, element))
	fmt.sbprintfln(&e.b, "  store ptr null, ptr %s", gep_field(e, PACK_RELEASE_TYPE, record, 1))
	place_label(e, done)
}

// Registers a box's allocation for panic replay while its payload is dropped,
// so a payload drop that panics still releases it.
@(private)
begin_box_release :: proc(e: ^Emitter, payload: Type_Id, block: string) -> Deferred {
	entry := Deferred{kind = .Box_Release, type = payload}
	if emit_lifecycle(e, payload).drop_may_panic {
		register_published(e, &entry, block)
	}
	return entry
}

@(private)
register_array_cleanup :: proc(
	e: ^Emitter, element: Type_Id, buffer, flags, count: string, counted := INVALID_TYPE,
) -> Deferred {
	entry := Deferred {
		kind          = .Array,
		type          = element,
		array_buffer  = buffer,
		array_flags   = flags,
		array_count   = count,
		array_counted = counted,
		order         = next_id(e),
	}
	if !unwind_enabled(e) {
		return entry
	}
	entry.array_buffer_env = unwind_reserve_env(e)
	if flags != "" {
		entry.array_flags_env = unwind_reserve_env(e)
	}
	entry.array_count_env = unwind_reserve_env(e)
	unwind_reserve(e, &entry)
	unwind_publish_env(e, entry.array_buffer_env, buffer)
	if flags != "" {
		unwind_publish_env(e, entry.array_flags_env, flags)
	}
	unwind_publish_env(e, entry.array_count_env, count)
	unwind_register(e, entry)
	return entry
}

@(private)
finish_temporary_drop :: proc(e: ^Emitter, entry: Deferred) {
	unwind_clear(e, entry.slot)
	release_held(e, entry)
}

// An operation no longer holds `entry`: it consumed or dropped it.
@(private)
release_held :: proc(e: ^Emitter, entry: Deferred) {
	if entry.order == 0 {
		return
	}
	for index := len(e.held) - 1; index >= 0; index -= 1 {
		if e.held[index].order == entry.order {
			ordered_remove(&e.held, index)
			break
		}
	}
}

// One completed element of an array still being built, registered for the
// unwind until the whole array owns it.
@(private)
guard_built_element :: proc(e: ^Emitter, element: Type_Id, place: string) -> Deferred {
	if !unwind_enabled(e) || !emit_lifecycle(e, element).managed {
		return Deferred{}
	}
	return begin_temporary_drop(e, element, place)
}

// A completed owned value borrowed by an operation, in `storage` when the caller
// has one to reuse. Register it before evaluating later arguments.
@(private)
hold_temporary_value :: proc(e: ^Emitter, type: Type_Id, value: string, storage := "") -> Deferred {
	if !emit_lifecycle(e, type).managed { return Deferred{} }
	place := storage != "" ? storage : alloca(e, llvm_type(e, type))
	store(e, type, value, place)
	entry := begin_temporary_drop(e, type, place)
	append(&e.held, entry)
	return entry
}

// A place whose drop belongs to the innermost lexical scope, such as a variant
// switch's subject, which its case bindings only borrow.
@(private)
register_scope_place :: proc(e: ^Emitter, type: Type_Id, place: string) {
	if !emit_lifecycle(e, type).managed || len(e.cleanups) == 0 {
		return
	}
	entry := begin_temporary_drop(e, type, place)
	entry.flag = conditional_flag(e)
	append(&e.cleanups[len(e.cleanups) - 1], entry)
}

@(private)
drop_temporary_value :: proc(e: ^Emitter, entry: Deferred) {
	if entry.place == "" { return }
	skip := ""
	if entry.flag != "" {
		run := new_label(e, "temp.made")
		skip = new_label(e, "temp.done")
		branch_if(e, load(e, "i1", entry.flag), run, skip)
		place_label(e, run)
		fmt.sbprintfln(&e.b, "  store i1 false, ptr %s", entry.flag)
	}
	// Clear before invoking a user drop hook, which can itself panic.
	finish_temporary_drop(e, entry)
	emit_drop_place(e, entry.type, entry.place)
	if skip != "" {
		place_label(e, skip)
	}
}

// ------------------------------------------------ full-expression frames --

// design.md "Borrows and lifetimes": a borrowed owned temporary lives until the
// end of its complete expression. The storage is a hoisted alloca, so a
// scope-registered drop inside a loop would leak every earlier iteration;
// every construct that evaluates an expression declares its own frame instead.
@(private)
push_temporaries :: proc(e: ^Emitter) {
	append(&e.temporaries, make([dynamic]Deferred))
	append(&e.large_marks, len(e.large_taken))
	append(&e.stack_saves, "")
}

@(private)
pop_temporaries :: proc(e: ^Emitter) {
	if !e.terminated {
		drain_temporaries(e, len(e.temporaries) - 1, len(e.held))
	}
	delete(pop(&e.temporaries))
	// Nothing reads a value temporary after its full expression.
	mark := pop(&e.large_marks)
	append(&e.large_free, ..e.large_taken[mark:])
	resize(&e.large_taken, mark)
	// Runtime-sized storage, such as a variadic pack's, ends here too, so a loop
	// does not keep every iteration's. The slot is null on paths that took none.
	if saved := pop(&e.stack_saves); saved != "" && !e.terminated {
		pointer := load(e, "ptr", saved)
		taken := not_null(e, pointer)
		restore, done := new_label(e, "stack.restore"), new_label(e, "stack.done")
		branch_if(e, taken, restore, done)
		place_label(e, restore)
		fmt.sbprintfln(&e.b, "  call void @llvm.stackrestore.p0(ptr %s)", pointer)
		fmt.sbprintfln(&e.b, "  store ptr null, ptr %s", saved)
		place_label(e, done)
	}
}

// Where one operand's temporaries start within the open full expression
// (`end_operand_temporaries`).
@(private)
Operand_Temporaries :: struct {
	large, temporaries, scope, held, actions, lent: int,
}

@(private)
begin_operand_temporaries :: proc(e: ^Emitter) -> Operand_Temporaries {
	return {
		large       = len(e.large_taken),
		temporaries = len(e.temporaries) > 0 ? len(e.temporaries[len(e.temporaries) - 1]) : 0,
		scope       = len(e.cleanups) > 0 ? len(e.cleanups[len(e.cleanups) - 1]) : 0,
		held        = len(e.held),
		actions     = unwind_next_action(e),
		lent        = e.lent_to_calls,
	}
}

// design.md "Temporaries and procedure boundaries": a temporary lives until its
// full expression ends, which nothing tells from an earlier end once nothing can
// name it. An operand consumed whole and owing no drop at the end of its full
// expression or its block can name its temporaries in two ways only: through its
// value, unless its types hold no address, and through a call it made that was
// handed one, which may keep it, by `unsafe` means, in a global or an out
// parameter (`note_lent_arguments`). With neither, its large slots serve the
// operands after it; each element of a long literal of large calls otherwise kept
// a slot of its own in the frame. A borrow is not the only address: a `[^]T` from
// `unsafe.raw_data` names its temporary with no borrow to show it
// (`type_may_hold_address`). One that owes no drop has also cleared the unwind
// actions of its temporaries, which the next one takes again (`unwind_rewind`),
// whatever it borrows; a long map literal's entries each kept their own. A caller
// ends the reuse once its operands are done (`unwind_stop_reusing`).
@(private)
end_operand_temporaries :: proc(e: ^Emitter, mark: Operand_Temporaries, types: ..Type_Id) {
	now := begin_operand_temporaries(e)
	if now.temporaries != mark.temporaries || now.scope != mark.scope || now.held != mark.held {
		return
	}
	unwind_rewind(e, mark.actions)
	if now.lent != mark.lent {
		return
	}
	for type in types {
		if type_may_hold_address(e.c, type) {
			return
		}
	}
	append(&e.large_free, ..e.large_taken[mark.large:])
	resize(&e.large_taken, mark.large)
}

// Counts a call handed an address it may keep past its return
// (`end_operand_temporaries`): an argument passed by reference, as a borrowed
// receiver, or one whose type may hold an address. A built-in, which has no
// `callee_type`, keeps only what its `bound` values hold, as `exchange` does. A
// large value passed by value is the address of a copy only the callee reads,
// which ends with the call.
@(private)
note_lent_arguments :: proc(e: ^Emitter, callee_type: ^Type_Info, bound: []Expr) {
	lends := false
	if callee_type != nil {
		for parameter, index in callee_type.parameters {
			lends ||= param_mode_is_pointer(param_mode_at(callee_type, index)) || type_may_hold_address(e.c, parameter)
		}
	} else {
		for argument in bound {
			// An omitted argument, as `make`'s allocator, passes nothing.
			lends ||= argument != nil && type_may_hold_address(e.c, expr_base(argument).type)
		}
	}
	if lends {
		e.lent_to_calls += 1
	}
}

// Saves the stack pointer for the open full expression before a runtime-sized
// alloca, unless a path through it already has; `pop_temporaries` restores it.
@(private)
save_stack_for_expression :: proc(e: ^Emitter) {
	if len(e.stack_saves) == 0 {
		return
	}
	slot := &e.stack_saves[len(e.stack_saves) - 1]
	if slot^ == "" {
		slot^ = temp(e)
		alloca_named(e, slot^, "ptr")
		append(&e.prologue, fmt.aprintf("  store ptr null, ptr %s", slot^))
	}
	now := emit_value(e, "call ptr @llvm.stacksave.p0()")
	held := load(e, "ptr", slot^)
	kept := emit_value(e, "select i1 %s, ptr %s, ptr %s", is_null(e, held), now, held)
	fmt.sbprintfln(&e.b, "  store ptr %s, ptr %s", kept, slot^)
}

// Drops the frames from `frame` up, innermost first, without closing them: an
// exit that branches away owes their drops, while the fall-through path pops.
@(private)
drain_temporaries :: proc(e: ^Emitter, frame, first_held: int) {
	// An exit from inside an operation also owes what it holds from `first_held`
	// up; its other paths still drop those values themselves, so the list
	// survives. Both kinds are dropped newest first, across the two lists
	// (design.md "Evaluation order").
	if !temporaries_owed(e, frame, first_held) {
		return
	}
	owed := make([dynamic]Deferred, context.temp_allocator)
	held := slice.clone(e.held[:], context.temp_allocator)
	append(&owed, ..held[first_held:])
	for depth in frame ..< len(e.temporaries) {
		append(&owed, ..e.temporaries[depth][:])
	}
	slice.stable_sort_by(owed[:], proc(a, b: Deferred) -> bool { return a.order > b.order })
	for entry in owed {
		if entry.kind == .Array {
			// A variadic call's staged elements, each flagged while it is owned, so
			// it stays registered: a panicking hook leaves the rest to the unwind.
			emit_drop_staged_array(e, entry)
			unwind_clear(e, entry.slot)
		} else {
			drop_temporary_value(e, entry)
		}
	}
	clear(&e.held)
	append(&e.held, ..held)
}

// Whether `drain_temporaries` has anything to drop, so the common case of
// nothing held copies nothing.
@(private = "file")
temporaries_owed :: proc(e: ^Emitter, frame, first_held: int) -> bool {
	if len(e.held) > first_held {
		return true
	}
	for depth in frame ..< len(e.temporaries) {
		if len(e.temporaries[depth]) > 0 {
			return true
		}
	}
	return false
}

@(private)
register_temporary_place :: proc(e: ^Emitter, type: Type_Id, place: string) {
	if !emit_lifecycle(e, type).managed {
		return
	}
	entry := begin_temporary_drop(e, type, place)
	entry.flag = conditional_flag(e)
	append(&e.temporaries[len(e.temporaries) - 1], entry)
}

// A temporary made in an operand that may not run is dropped only if it was
// made: its flag is false from the entry block, set here, and cleared by the
// drop, so a later pass through the same code starts false again.
@(private = "file")
conditional_flag :: proc(e: ^Emitter) -> string {
	if e.conditional == 0 {
		return ""
	}
	flag := fmt.aprintf("%%made%d", next_id(e))
	alloca_named(e, flag, "i1")
	append(&e.prologue, fmt.aprintf("  store i1 false, ptr %s", flag))
	fmt.sbprintfln(&e.b, "  store i1 true, ptr %s", flag)
	return flag
}

// Brackets an operand that may not run (`conditional`).
@(private)
begin_conditional :: proc(e: ^Emitter) { e.conditional += 1 }
@(private)
end_conditional :: proc(e: ^Emitter) { e.conditional -= 1 }

// -------------------------------------------------------------- cleanups --

@(private)
push_scope :: proc(e: ^Emitter, b: ^Block) {
	push_scope_stmts(e, b == nil ? nil : b.stmts)
}

@(private)
push_scope_stmts :: proc(e: ^Emitter, stmts: []Stmt) {
	append(&e.cleanups, make([dynamic]Deferred))
	debug_mark_scope(e, true)
	reset_defer_flags(e, stmts)
}

// Flag storage is reused across loop iterations, so every flag written directly
// in a scope (including inside a selected `when`) is reset on entry.
@(private = "file")
reset_defer_flags :: proc(e: ^Emitter, stmts: []Stmt) {
	for stmt in stmts {
		#partial switch s in stmt {
		case ^Stmt_Defer:
			if s.slot < len(e.defer_flags) {
				fmt.sbprintfln(&e.b, "  store i1 false, ptr %s", e.defer_flags[s.slot])
			}
			unwind_clear(e, e.unwind.slot_by_defer[s.slot])
		case ^Decl:
			for symbol_id in s.symbols {
				if flag := drop_flag_of(e, symbol_id); flag != "" {
					fmt.sbprintfln(&e.b, "  store i1 false, ptr %s", flag)
				}
				unwind_clear(e, e.unwind.slot_by_symbol[symbol_id])
			}
		case ^Stmt_When:
			if s.selected != nil {
				reset_defer_flags(e, s.selected.stmts)
			}
		}
	}
}

@(private)
pop_scope :: proc(e: ^Emitter) {
	if len(e.cleanups) == 0 {
		return
	}
	if !e.terminated {
		run_cleanups(e, len(e.cleanups) - 1)
	}
	pop(&e.cleanups)
	debug_mark_scope(e, false)
}

// Runs every scope above `down_to`, innermost first and in reverse registration
// order within each. `failed` is the `i1` saying a returning exit carries the
// failure variant; "" for an exit that does not return, which discards an
// `errdefer` (design.md "defer statement").
@(private)
run_cleanups :: proc(e: ^Emitter, down_to: int, failed := "") {
	for depth := len(e.cleanups) - 1; depth >= down_to; depth -= 1 {
		entries := e.cleanups[depth]
		for index := len(entries) - 1; index >= 0; index -= 1 {
			entry := entries[index]
			if entry.on_failure && failed == "" {
				// Its scope ends without a failure, so no panic replays it either.
				unwind_clear(e, entry.slot)
				continue
			}
			if entry.flag == "" {
				run_one_cleanup(e, entry)
				continue
			}
			if entry.on_failure {
				// Passing its place retires it either way, so a panic in an older
				// cleanup does not replay one a success return skipped.
				unwind_clear(e, entry.slot)
			}
			flag := load(e, "i1", entry.flag)
			if entry.on_failure {
				flag = combine_and(e, flag, failed)
			}
			run := new_label(e, "defer.run")
			skip := new_label(e, "defer.skip")
			branch_if(e, flag, run, skip)
			place_label(e, run)
			// A conditional temporary's flag is set again only if it is made again.
			fmt.sbprintfln(&e.b, "  store i1 false, ptr %s", entry.flag)
			run_one_cleanup(e, entry)
			place_label(e, skip)
		}
	}
}

@(private = "file")
run_one_cleanup :: proc(e: ^Emitter, entry: Deferred) {
	unwind_clear(e, entry.slot)
	if entry.kind == .Written {
		// A deferred statement steps at its own line, then the exit continues.
		// design.md "Evaluation order": it is its own complete expression, so its
		// temporaries end with it, before the walk goes on.
		exit := e.debug_span
		push_temporaries(e)
		emit_stmt(e, entry.stmt)
		pop_temporaries(e)
		debug_mark_location(e, exit)
		return
	}
	emit_drop_place(e, entry.type, entry.place)
}

// A managed local's implicit conditional `defer drop(value)`
// (design.md "Managed values and storage").
// `live` is false for a declaration with no initializer: the cleanup is still
// registered, since a later assignment can make the place live, but a panic
// must not replay it until `revive_place` says so.
@(private)
register_implicit_drop :: proc(e: ^Emitter, symbol_id: Symbol_Id, live := true) {
	sym := symbol_of(e.c, symbol_id)
	if sym == nil {
		return
	}
	flag := drop_flag_of(e, symbol_id)
	if flag != "" {
		fmt.sbprintfln(&e.b, "  store i1 %v, ptr %s", live, flag)
	}
	if !sym.drop_at_exit && !sym.drop_on_unwind || len(e.cleanups) == 0 {
		return
	}
	entry := Deferred{flag = flag, place = symbol_name(e, symbol_id), place_symbol = symbol_id, type = sym.type}
	unwind_reserve(e, &entry)
	e.unwind.slot_by_symbol[symbol_id] = entry.slot
	if live {
		unwind_register(e, entry)
	}
	if sym.drop_at_exit {
		append(&e.cleanups[len(e.cleanups) - 1], entry)
	}
}

// A whole-local assignment makes the place hold a value again, so a flagged
// local is marked live and its implicit drop registered for panic replay once
// more.
@(private)
revive_place :: proc(e: ^Emitter, target: Expr) {
	ident, is_ident := target.(^Expr_Ident)
	if !is_ident {
		return
	}
	if flag := drop_flag_of(e, ident.symbol); flag != "" {
		fmt.sbprintfln(&e.b, "  store i1 true, ptr %s", flag)
	}
	unwind_revive(e, ident.symbol)
}

// The hidden `i1` of a conditionally live local, or "" when its state is
// definite at every cleanup point.
@(private)
drop_flag_of :: proc(e: ^Emitter, symbol_id: Symbol_Id) -> string {
	sym := symbol_of(e.c, symbol_id)
	if sym == nil || !sym.drop_conditional || sym.cleanup_slot >= len(e.defer_flags) {
		return ""
	}
	return e.defer_flags[sym.cleanup_slot]
}

// `move(x)` and `drop(x)` leave the source dead: the inert zero is written and
// neither the flag nor a panic will run its cleanup again.
@(private)
kill_place :: proc(e: ^Emitter, symbol_id: Symbol_Id) {
	sym := symbol_of(e.c, symbol_id)
	if sym == nil {
		return
	}
	if zero, ok := llvm_zero(e, sym.type); ok {
		store(e, sym.type, zero, symbol_name(e, symbol_id))
	}
	if flag := drop_flag_of(e, symbol_id); flag != "" {
		fmt.sbprintfln(&e.b, "  store i1 false, ptr %s", flag)
	}
	unwind_clear(e, e.unwind.slot_by_symbol[symbol_id])
}

// `drop(value)` runs the cleanup operation, writes the inert zero, and marks the
// variable dead (design.md "Storage modifiers").
@(private)
emit_explicit_drop :: proc(e: ^Emitter, v: ^Expr_Call) {
	ident, is_ident := v.bound[0].(^Expr_Ident)
	if !is_ident {
		backend_fail(e, "`drop` has no named operand")
		return
	}
	sym := symbol_of(e.c, ident.symbol)
	if sym == nil {
		return
	}
	// The owner's unwind action is cleared before the hook runs, so a panicking
	// hook cannot be replayed on the same value; the hook still reads it intact.
	unwind_clear(e, e.unwind.slot_by_symbol[ident.symbol])
	emit_drop_place(e, sym.type, symbol_name(e, ident.symbol))
	kill_place(e, ident.symbol)
}

// An owning temporary nothing binds is still cleaned up exactly once.
//
// ponytail: dropped at its full-expression boundary rather than in the scope's
// reverse order; nothing can name it, so only ordering against other cleanups
// differs.
@(private)
emit_discarded_temporary :: proc(e: ^Emitter, expr: Expr, value: string) {
	base := expr_base(expr)
	if base == nil || !emit_lifecycle(e, base.type).managed {
		return
	}
	if expression_is_borrowed_place(expr) {
		return
	}
	slot := spill(e, base.type, value)
	emit_drop_place(e, base.type, slot)
}

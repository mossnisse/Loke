// Cleanup registration, panic replay, and lifecycle clone/drop emission.
//
// Part of the textual LLVM backend; see compiler-architecture.md.
package lokec

import "core:fmt"
import "core:strings"

@(private)
// One registered cleanup action. design.md gives explicit `defer` and a managed
// local's implicit drop one reverse registration order, so they share one entry
// and one stack instead of a second, parallel-list mechanism.
//
// `flag` is empty when the CFG proved the slot reached unconditionally: a
// definite state needs no flag.
Deferred :: struct {
	flag: string,
	// A written `defer`, or nil for an implicit drop of `place`.
	stmt:  Stmt,
	place: string,
	// A compiler-owned temporary has no lexical symbol. Its address is published
	// directly through `place_env` so panic replay can still destroy it while it
	// is only partially built.
	temporary_place: bool,
	place_env:       int,
	// The local whose storage `place` is. A cleanup thunk reaches it through the
	// env rather than by name, so the symbol travels with the entry.
	place_symbol: Symbol_Id,
	type:  Type_Id,
	// A compiler-owned variadic buffer uses one cleanup action with per-element
	// flags. The three env indices let the unwind thunk reach its dynamic buffer,
	// flag array, and runtime count; the direct names serve normal cleanup.
	array_cleanup:  bool,
	array_buffer:   string,
	array_flags:    string,
	array_count:    string,
	array_buffer_env: int,
	array_flags_env:  int,
	array_count_env:  int,
	// This action's index in the procedure's runtime registration state, or -1
	// when the procedure registers no frame at all (`-panic=abort`).
	slot: int,
}

// One procedure's runtime-visible cleanup registration.
//
// design.md: a panic has no way to resume, so the runtime never unwinds the
// native stack — it calls back into each still-live frame through a generated
// thunk. The thunk needs the frame's *state* (which actions are registered, and
// where their storage is), so a procedure with a cleanup carries two arrays and
// pushes a `{previous, thunk, context}` record. The arrays are separate allocas,
// not record fields, because their lengths are known only once the whole body is
// emitted, and `getelementptr` over `i8`/`ptr` needs no length in its type.
Unwind_Env_Binding :: struct {
	symbol: Symbol_Id,
	index:  int,
}

Unwind_State :: struct {
	// `[live x i1]`: whether action `i` is registered right now. Set only after
	// the action is fully registered, cleared before normal control flow runs it.
	live: string,
	// `[env x ptr]`: the storage each replayed action addresses. A cleanup thunk
	// is a separate function, so it cannot name the parent's allocas directly.
	env:   string,
	frame: string, // the `{previous, cleanup, context}` record this frame pushes
	ctx:   string, // `[2 x ptr]` = {live, env}, the thunk's one argument
	thunk: string,
	// Every action, in source order. A live action's registration point always
	// precedes any later live one lexically (an inner scope's actions clear on
	// exit), so descending-index replay is reverse registration order.
	actions: [dynamic]Deferred,
	// Env index per local symbol whose address a cleanup may need.
	env_index: map[Symbol_Id]int,
	// Symbol bindings in assignment order. Non-symbol env slots may be
	// interleaved, so each entry retains its actual slot index.
	env_bindings: [dynamic]Unwind_Env_Binding,
	env_count: int,
	// The registration slot of a managed local's implicit drop, and of a written
	// `defer`, so `move`/`drop` and a re-entered scope can clear the same
	// registration the drop flags clear.
	slot_by_symbol: map[Symbol_Id]int,
	slot_by_defer:  map[int]int,
	// True while the thunk itself is being emitted, so replayed code does not
	// register a second time into the state it is replaying.
	replaying: bool,
}

@(private)
Cleanup_Scope :: struct {
	entries: [dynamic]Deferred,
}

// Deep-copy the value at `src` into the storage at `out`, answering an `i1` that
// is true on success. This is the one place that knows how the three kinds of
// managed part differ: a container clones through its C helper, a fallible hook
// returns its own error, and everything else has a clone that cannot fail.
//
// On failure `out` is left untouched, which is what lets the caller destroy
// exactly the prefix it did build.
@(private)
emit_try_clone_into :: proc(e: ^Emitter, type: Type_Id, out, src, allocator: string) -> string {
	operations := emit_lifecycle(e, type)
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
	value := load(e, llvm_type(e, type), src)
	if !operations.clone_fallible {
		store(e, type, emit_clone_value(e, type, value, allocator), out)
		return "true"
	}
	hook := operations.try_clone
	if hook == INVALID_SYMBOL {
		backend_fail(e, "a fallible container element has no `try_clone` member")
		return "false"
	}
	cloned, broke := emit_clone_call(e, hook, type, value, allocator)
	ok := temp(e)
	fmt.sbprintfln(&e.b, "  %s = xor i1 %s, true", ok, broke)
	// The hook already cleaned its own temporary on the failing path, and a
	// failed clone returns the zero value, so publishing it unconditionally would
	// leave an inert value the caller must not count as initialised. Store it
	// only where it is real.
	store_label, done_label := new_label(e, "clone.store"), new_label(e, "clone.done")
	branch_if(e, ok, store_label, done_label)
	place_label(e, store_label)
	store(e, type, cloned, out)
	branch(e, done_label)
	place_label(e, done_label)
	e.terminated = false
	return ok
}

// ---------------------------------------------------------- panic unwind --

// Whether this procedure body registers a runtime-visible frame at all. Under
// `-panic=abort` design.md guarantees no cleanup, so nothing is registered and
// no thunk is generated: the strategy is the difference between the two, not a
// runtime flag the frames carry.
@(private = "file")
unwind_enabled :: proc(e: ^Emitter) -> bool {
	return e.c.panic_unwind && !e.unwind.replaying
}

// Fresh registration state for one procedure. The names are chosen before the
// body is emitted, because the body refers to storage whose size — and therefore
// whose defining instruction — is only settled afterwards.
@(private)
begin_unwind_frame :: proc(e: ^Emitter, llvm_name: string) {
	e.unwind = Unwind_State {
		actions        = make([dynamic]Deferred),
		env_index      = make(map[Symbol_Id]int),
		env_bindings   = make([dynamic]Unwind_Env_Binding),
		slot_by_symbol = make(map[Symbol_Id]int),
		slot_by_defer  = make(map[int]int),
	}
	if !e.c.panic_unwind {
		return
	}
	id := next_id(e)
	e.unwind.frame = fmt.aprintf("%%uframe.%d", id)
	e.unwind.live = fmt.aprintf("%%ulive.%d", id)
	e.unwind.env = fmt.aprintf("%%uenv.%d", id)
	e.unwind.ctx = fmt.aprintf("%%uctx.%d", id)
	e.unwind.thunk = fmt.aprintf("@loke.u%d.%s", id, strings.trim_prefix(llvm_name, "@"))
}

// Reserves this action's registration slot. Called where the existing cleanup
// entry is built, so the two orders cannot drift apart.
@(private)
unwind_reserve :: proc(e: ^Emitter, entry: ^Deferred) {
	entry.slot = -1
	if !unwind_enabled(e) {
		return
	}
	entry.slot = len(e.unwind.actions)
	append(&e.unwind.actions, entry^)
}

// The env index of a local, assigning one on first use. A cleanup thunk is a
// separate function, so the only way it can reach the parent's storage is
// through a pointer the parent wrote here.
@(private = "file")
unwind_env_slot :: proc(e: ^Emitter, symbol_id: Symbol_Id) -> int {
	if index, found := e.unwind.env_index[symbol_id]; found {
		return index
	}
	index := e.unwind.env_count
	e.unwind.env_count += 1
	e.unwind.env_index[symbol_id] = index
	append(&e.unwind.env_bindings, Unwind_Env_Binding{symbol = symbol_id, index = index})
	return index
}

@(private = "file")
unwind_reserve_env :: proc(e: ^Emitter) -> int {
	index := e.unwind.env_count
	e.unwind.env_count += 1
	return index
}

@(private = "file")
unwind_publish_env :: proc(e: ^Emitter, index: int, address: string) {
	if !unwind_enabled(e) || index < 0 || address == "" {
		return
	}
	fmt.sbprintfln(&e.b, "  store ptr %s, ptr %s", address, unwind_env_address(e, index))
}

// Names a local and, when the procedure carries a frame, publishes its address
// into the env so a replayed `defer` can reach it.
//
// ponytail: every local is published, not just the ones a cleanup names. Picking
// the smaller set means a free-variable walk over every deferred statement; one
// extra store per local is cheaper than that pass and cannot be wrong about it.
@(private)
bind_local :: proc(e: ^Emitter, symbol_id: Symbol_Id, name: string) {
	e.names[symbol_id] = name
	if symbol_id == INVALID_SYMBOL || !unwind_enabled(e) || e.unwind.env == "" {
		return
	}
	fmt.sbprintfln(
		&e.b, "  store ptr %s, ptr %s",
		name, unwind_env_address(e, unwind_env_slot(e, symbol_id)),
	)
}

@(private = "file")
unwind_live_address :: proc(e: ^Emitter, slot: int) -> string {
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = getelementptr i8, ptr %s, i64 %d", out, e.unwind.live, slot)
	return out
}

@(private = "file")
unwind_env_address :: proc(e: ^Emitter, index: int) -> string {
	out := temp(e)
	fmt.sbprintfln(&e.b, "  %s = getelementptr ptr, ptr %s, i64 %d", out, e.unwind.env, index)
	return out
}

// Publishes an action as registered. design.md: the flag is set only once the
// action is *fully* registered, so a panic between "this storage exists" and
// "this value is complete" replays nothing for it. The action's storage is
// already published — `bind_local` did that when the local was named.
@(private)
unwind_register :: proc(e: ^Emitter, entry: Deferred) {
	if entry.slot < 0 || !unwind_enabled(e) {
		return
	}
	fmt.sbprintfln(&e.b, "  store i1 true, ptr %s", unwind_live_address(e, entry.slot))
}

// Clears a registration. Called before the action's own code runs on the normal
// path, so a panic raised *by* a cleanup cannot ask for that cleanup again.
@(private)
unwind_clear :: proc(e: ^Emitter, slot: int) {
	if slot < 0 || !unwind_enabled(e) {
		return
	}
	fmt.sbprintfln(&e.b, "  store i1 false, ptr %s", unwind_live_address(e, slot))
}

// The frame prologue, written once the body is emitted and the two array
// lengths are finally known.
@(private)
emit_unwind_prologue :: proc(e: ^Emitter) {
	u := &e.unwind
	if u.frame == "" {
		return // `-panic=abort`: design.md guarantees no cleanup, so none is tracked
	}
	// `{` is a directive to core:fmt, so the record type is written literally.
	FRAME :: "{ ptr, ptr, ptr }"
	alloca_named(e, u.frame, FRAME)
	fmt.sbprint(&e.b, "  store ")
	fmt.sbprint(&e.b, FRAME)
	fmt.sbprint(&e.b, " zeroinitializer, ptr ")
	fmt.sbprintln(&e.b, u.frame)
	if len(u.actions) == 0 && u.env_count == 0 {
		// Nothing to replay and nothing published, so nothing is pushed. The zeroed
		// record still makes the epilogue's pop a no-op rather than a special case.
		return
	}
	// A procedure with locals but no cleanup still published their addresses, so
	// the env exists even where the live array would be empty. LLVM drops both
	// when nothing reads them.
	alloca_named(e, u.live, fmt.aprintf("[%d x i1]", max(len(u.actions), 1)))
	fmt.sbprintfln(
		&e.b, "  call void @llvm.memset.p0.i64(ptr %s, i8 0, i64 %d, i1 false)",
		u.live, max(len(u.actions), 1),
	)
	alloca_named(e, u.env, fmt.aprintf("[%d x ptr]", max(u.env_count, 1)))
	alloca_named(e, u.ctx, "[2 x ptr]")
	if len(u.actions) == 0 {
		return
	}
	fmt.sbprintfln(&e.b, "  store ptr %s, ptr %s", u.live, u.ctx)
	slot := temp(e)
	fmt.sbprintfln(&e.b, "  %s = getelementptr ptr, ptr %s, i64 1", slot, u.ctx)
	fmt.sbprintfln(&e.b, "  store ptr %s, ptr %s", u.env, slot)
	fmt.sbprintfln(
		&e.b, "  call void @loke_rt_v1_frame_push(ptr %s, ptr %s, ptr %s)",
		u.frame, u.thunk, u.ctx,
	)
}

// Leaving the frame normally. Passing the record rather than popping blindly is
// what lets a procedure that registered nothing share this one path.
@(private)
emit_unwind_pop :: proc(e: ^Emitter) {
	if !unwind_enabled(e) || e.unwind.frame == "" {
		return
	}
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_frame_pop(ptr %s)", e.unwind.frame)
}

// The generated thunk: replay every still-registered action of one frame,
// newest first. Emitted into `e.pending` because LLVM functions do not nest.
@(private)
emit_unwind_thunk :: proc(e: ^Emitter) {
	u := &e.unwind
	if len(u.actions) == 0 {
		return
	}
	// The one nested function that does not go through `begin_function_emission`:
	// it replays *this* frame's actions and re-emits the parent's own `defer`
	// statements, so it needs the enclosing procedure's unwind state and result
	// slot rather than a cleared set. Only the three it really owns are swapped.
	saved_body, saved_terminated := e.b, e.terminated
	saved_cleanups, saved_prologue := e.cleanups, e.prologue
	e.b = strings.builder_make()
	e.terminated = false
	e.cleanups = make([dynamic]Cleanup_Scope)
	e.prologue = nil
	u.replaying = true

	fmt.sbprintf(&e.b, "define private void %s(ptr %%ctx)", u.thunk)
	fmt.sbprintln(&e.b, " {")
	fmt.sbprintln(&e.b, "entry:")
	live := load(e, "ptr", "%ctx")
	env_slot, env := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = getelementptr ptr, ptr %%ctx, i64 1", env_slot)
	fmt.sbprintfln(&e.b, "  %s = load ptr, ptr %s", env, env_slot)

	// The parent's allocas are unreachable from here, so every local a replayed
	// action names is rebound to its address in the env.
	saved_names := make([dynamic]string, 0, len(u.env_bindings))
	for binding in u.env_bindings {
		append(&saved_names, e.names[binding.symbol])
		address, value := temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = getelementptr ptr, ptr %s, i64 %d", address, env, binding.index)
		fmt.sbprintfln(&e.b, "  %s = load ptr, ptr %s", value, address)
		e.names[binding.symbol] = value
	}

	for index := len(u.actions) - 1; index >= 0; index -= 1 {
		entry := u.actions[index]
		flag, address := temp(e), temp(e)
		fmt.sbprintfln(&e.b, "  %s = getelementptr i8, ptr %s, i64 %d", address, live, index)
		fmt.sbprintfln(&e.b, "  %s = load i1, ptr %s", flag, address)
		run, skip := new_label(e, "unwind.run"), new_label(e, "unwind.skip")
		branch_if(e, flag, run, skip)
		place_label(e, run)
		fmt.sbprintfln(&e.b, "  store i1 false, ptr %s", address)
		if entry.array_cleanup {
			load_env := proc(e: ^Emitter, env: string, index: int) -> string {
				slot, value := temp(e), temp(e)
				fmt.sbprintfln(&e.b, "  %s = getelementptr ptr, ptr %s, i64 %d", slot, env, index)
				fmt.sbprintfln(&e.b, "  %s = load ptr, ptr %s", value, slot)
				return value
			}
			buffer := load_env(e, env, entry.array_buffer_env)
			flags := load_env(e, env, entry.array_flags_env)
			count := load_env(e, env, entry.array_count_env)
			emit_drop_flagged_array(e, entry.type, buffer, flags, count)
		} else if entry.stmt != nil {
			emit_stmt(e, entry.stmt)
		} else if entry.temporary_place {
			slot, place := temp(e), temp(e)
			fmt.sbprintfln(&e.b, "  %s = getelementptr ptr, ptr %s, i64 %d", slot, env, entry.place_env)
			fmt.sbprintfln(&e.b, "  %s = load ptr, ptr %s", place, slot)
			emit_drop_place(e, entry.type, place)
		} else if place, bound := e.names[entry.place_symbol]; bound {
			emit_drop_place(e, entry.type, place)
		}
		branch(e, skip)
		place_label(e, skip)
	}
	fmt.sbprintln(&e.b, "  ret void")
	fmt.sbprintln(&e.b, "}")
	fmt.sbprintln(&e.b, "")

	for binding, index in u.env_bindings {
		e.names[binding.symbol] = saved_names[index]
	}
	append(&e.pending, splice_prologue(strings.to_string(e.b), e.prologue[:]))
	u.replaying = false
	e.b, e.terminated, e.cleanups = saved_body, saved_terminated, saved_cleanups
	e.prologue = saved_prologue
}

// Registers a partially constructed compiler-owned value for panic replay. It
// never enters the lexical cleanup stack: the builder clears it once complete,
// at which point ordinary destination ownership takes over.
@(private)
begin_temporary_drop :: proc(e: ^Emitter, type: Type_Id, place: string) -> Deferred {
	entry := Deferred{type = type, place = place, temporary_place = true, slot = -1, place_env = -1}
	if unwind_enabled(e) {
		entry.place_env = unwind_reserve_env(e)
	}
	unwind_reserve(e, &entry)
	unwind_publish_env(e, entry.place_env, place)
	unwind_register(e, entry)
	return entry
}

@(private)
finish_temporary_drop :: proc(e: ^Emitter, entry: Deferred) {
	unwind_clear(e, entry.slot)
}

// A completed owned value can be borrowed by an operation without transferring
// its cleanup responsibility. Register it before evaluating later arguments.
@(private)
hold_temporary_value :: proc(e: ^Emitter, type: Type_Id, value: string) -> Deferred {
	if !emit_lifecycle(e, type).managed { return Deferred{slot = -1} }
	place := alloca(e, llvm_type(e, type))
	store(e, type, value, place)
	return begin_temporary_drop(e, type, place)
}

// A variant switch owns its subject: every case binding only borrows the
// payload, so the drop belongs to the switch's own scope, where falling out,
// `break`, `return` and a panic each replay it exactly once.
@(private)
register_scope_place :: proc(e: ^Emitter, type: Type_Id, place: string) {
	if !emit_lifecycle(e, type).managed || len(e.cleanups) == 0 {
		return
	}
	entry := Deferred{type = type, place = place, temporary_place = true, slot = -1, place_env = -1}
	if unwind_enabled(e) {
		entry.place_env = unwind_reserve_env(e)
	}
	unwind_reserve(e, &entry)
	unwind_publish_env(e, entry.place_env, place)
	unwind_register(e, entry)
	append(&e.cleanups[len(e.cleanups) - 1].entries, entry)
}

@(private)
drop_temporary_value :: proc(e: ^Emitter, entry: Deferred) {
	if entry.place == "" { return }
	// Clear before invoking a user drop hook, which can itself panic.
	finish_temporary_drop(e, entry)
	emit_drop_place(e, entry.type, entry.place)
}

// -------------------------------------------------------------- cleanups --

@(private)
push_scope :: proc(e: ^Emitter, b: ^Block) {
	push_scope_stmts(e, b == nil ? nil : b.stmts)
}

@(private)
push_scope_stmts :: proc(e: ^Emitter, stmts: []Stmt) {
	append(&e.cleanups, Cleanup_Scope{entries = make([dynamic]Deferred)})
	// Reset the flag of every defer written directly in this scope: the storage
	// is reused across loop iterations, so a stale `true` would run a
	// registration that never happened this time round.
	reset_defer_flags(e, stmts)
}

// A `defer` written inside a selected `when` belongs to the surrounding scope,
// so its flag is reset with that scope's own.
@(private = "file")
reset_defer_flags :: proc(e: ^Emitter, stmts: []Stmt) {
	for stmt in stmts {
		#partial switch s in stmt {
		case ^Stmt_Defer:
			if s.slot < len(e.defer_flags) {
				fmt.sbprintfln(&e.b, "  store i1 false, ptr %s", e.defer_flags[s.slot])
			}
			if slot, registered := e.unwind.slot_by_defer[s.slot]; registered {
				unwind_clear(e, slot)
			}
		case ^Decl:
			// A managed local's hidden flag reuses the same storage across loop
			// iterations, so it needs the same reset a written `defer` gets.
			for symbol_id in s.symbols {
				if flag := drop_flag_of(e, symbol_id); flag != "" {
					fmt.sbprintfln(&e.b, "  store i1 false, ptr %s", flag)
				}
				if slot, registered := e.unwind.slot_by_symbol[symbol_id]; registered {
					unwind_clear(e, slot)
				}
			}
		case ^Stmt_When:
			if selected := when_selected_block(s); selected != nil {
				reset_defer_flags(e, selected.stmts)
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
}

// Runs the deferred statements of every scope above `down_to`, innermost first
// and in reverse registration order within each.
@(private)
run_cleanups :: proc(e: ^Emitter, down_to: int) {
	for depth := len(e.cleanups) - 1; depth >= down_to; depth -= 1 {
		entries := e.cleanups[depth].entries
		for index := len(entries) - 1; index >= 0; index -= 1 {
			entry := entries[index]
			if entry.flag == "" {
				run_one_cleanup(e, entry)
				continue
			}
			flag := load(e, "i1", entry.flag)
			run := new_label(e, "defer.run")
			skip := new_label(e, "defer.skip")
			branch_if(e, flag, run, skip)
			place_label(e, run)
			run_one_cleanup(e, entry)
			branch(e, skip)
			place_label(e, skip)
		}
	}
}

@(private = "file")
run_one_cleanup :: proc(e: ^Emitter, entry: Deferred) {
	// design.md "Panic during unwinding": clearing the registration first is what
	// keeps a panic raised *by* this cleanup from asking for the same cleanup
	// again on the way down.
	unwind_clear(e, entry.slot)
	if entry.stmt != nil {
		emit_stmt(e, entry.stmt)
		return
	}
	emit_drop_place(e, entry.type, entry.place)
}

// A managed local declaration places an implicit conditional
// `defer drop(value)` at the declaration point (design.md). Registration is
// what fixes its position in the one reverse order every exit replays.
@(private)
register_implicit_drop :: proc(e: ^Emitter, symbol_id: Symbol_Id) {
	sym := symbol_of(e.c, symbol_id)
	if sym == nil {
		return
	}
	// The flag says "this place holds a value", which an assignment's drop reads
	// as well as cleanup, so it is set whenever one exists.
	flag := drop_flag_of(e, symbol_id)
	if flag != "" {
		fmt.sbprintfln(&e.b, "  store i1 true, ptr %s", flag)
	}
	if !sym.drop_at_exit || len(e.cleanups) == 0 {
		return
	}
	entry := Deferred{flag = flag, place = e.names[symbol_id], place_symbol = symbol_id, type = sym.type}
	unwind_reserve(e, &entry)
	e.unwind.slot_by_symbol[symbol_id] = entry.slot
	unwind_register(e, entry)
	append(&e.cleanups[len(e.cleanups) - 1].entries, entry)
}

// The hidden `i1` of a conditionally live local, or "" when the CFG left its
// state definite at every cleanup point.
@(private)
drop_flag_of :: proc(e: ^Emitter, symbol_id: Symbol_Id) -> string {
	sym := symbol_of(e.c, symbol_id)
	if sym == nil || !sym.drop_conditional || sym.cleanup_slot >= len(e.defer_flags) {
		return ""
	}
	return e.defer_flags[sym.cleanup_slot]
}

// `move(x)` and `drop(x)` both leave the source dead: the inert zero
// representation is written, and a conditional slot records that its cleanup
// must not run again.
@(private)
kill_place :: proc(e: ^Emitter, symbol_id: Symbol_Id) {
	sym := symbol_of(e.c, symbol_id)
	if sym == nil {
		return
	}
	if zero, ok := zero_const(e.c, sym.type); ok {
		store(e, sym.type, llvm_const(e, zero, sym.type), e.names[symbol_id])
	}
	if flag := drop_flag_of(e, symbol_id); flag != "" {
		fmt.sbprintfln(&e.b, "  store i1 false, ptr %s", flag)
	}
	// The same fact the drop flag records, made visible to a panic: this place no
	// longer holds a value, so its registered cleanup must not be replayed.
	if slot, registered := e.unwind.slot_by_symbol[symbol_id]; registered {
		unwind_clear(e, slot)
	}
}

// `drop(value)` runs the cleanup operation, writes the inert zero
// representation, and marks the variable dead (design.md "Storage modifiers").
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
	emit_drop_place(e, sym.type, e.names[ident.symbol])
	kill_place(e, ident.symbol)
}

// design.md: an owning temporary nothing binds is still a completed
// initialization, so it is cleaned up exactly once.
//
// ponytail: dropped at its full-expression boundary rather than registered in
// the surrounding scope's reverse order. Nothing can name it, so the only
// observable difference is ordering against other cleanups — and registering it
// would drop one value per emitted statement rather than one per loop iteration.
@(private)
emit_discarded_temporary :: proc(e: ^Emitter, expr: Expr, value: string) {
	base := expr_base(expr)
	if base == nil || !emit_lifecycle(e, base.type).managed {
		return
	}
	// A place names storage someone else owns; only an owned temporary is ours
	// to clean up.
	if expression_is_borrowed_place(e.c, expr) {
		return
	}
	slot := alloca(e, llvm_type(e, base.type))
	store(e, base.type, value, slot)
	emit_drop_place(e, base.type, slot)
}

// design.md: an implicit copy — a binding, an assignment, or the return of a
// borrowed managed owner — goes through `clone`, the policy-following entry
// point. It calls `try_clone` once and applies the allocator's failure policy,
// so a failure never reaches a half-written destination.
//
// `allocator` is the destination's selected provider: its written `via`, or the
// default when the declaration has no policy.
// An empty `allocator` means the build-selected default, which is a call
// rather than a symbol and so cannot be a parameter default.
@(private)
emit_clone_value :: proc(e: ^Emitter, type: Type_Id, value: string, allocator := "") -> string {
	entry := emit_lifecycle(e, type)
	// Resolved once here rather than per branch: every path below that allocates
	// needs it, and the paths that do not are `return`s above the first use.
	provider := allocator
	if provider == "" && (entry.container || entry.clone != INVALID_SYMBOL ||
	   underlying_kind(e.c, type) == .Array) {
		provider = emit_default_allocator(e)
	}
	// design.md "Dynamic arrays"/"Maps": a container's copy is a deep clone, so
	// an implicit copy duplicates the storage through the C helper and applies
	// the allocator's failure policy — there is nowhere here to return an error.
	if entry.container {
		source := alloca(e, CONTAINER_TYPE)
		destination := alloca(e, CONTAINER_TYPE)
		fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", CONTAINER_TYPE, value, source)
		ok := emit_try_clone_into(e, type, destination, source, provider)
		fail_label, done_label := new_label(e, "cclone.fail"), new_label(e, "cclone.done")
		branch_if(e, ok, done_label, fail_label)
		place_label(e, fail_label)
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_alloc_failed(ptr %s)", provider)
		branch(e, done_label)
		place_label(e, done_label)
		e.terminated = false
		out := load(e, CONTAINER_TYPE, destination)
		return out
	}
	// A string copy is cheap and its immutable backing storage may be shared
	// (design.md "string type"). An implicit copy of a string retains a handle;
	// only `.copy()` allocates, and that is a written call, not this path.
	if entry.intrinsic {
		owner := extract(e, STRING_TYPE, value, STRING_OWNER)
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_string_retain(i64 %s)", owner)
		return value
	}
	// Fixed arrays have a generated `try_clone`, but no public `clone` member.
	// Use its field-wise copy and the same policy as a record's clone wrapper.
	// In particular, an empty array copies successfully without visiting an
	// element, regardless of the element type's lifecycle.
	if info := underlying_info(e.c, type); info != nil && info.kind == .Array {
		return emit_clone_with_policy(e, type, value, provider)
	}
	hook := entry.clone
	if hook == INVALID_SYMBOL {
		backend_fail(e, fmt.aprintf("an implicit copy of `%s` has no `clone` member", type_name(e.c, type)))
		return "0"
	}
	out := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = call %s %s(%s %s, ptr %s)",
		out, llvm_type(e, type), e.names[hook], llvm_type(e, type), value, provider,
	)
	return out
}

@(private)
register_variadic_cleanup :: proc(
	e: ^Emitter, element: Type_Id, buffer, flags, count: string,
) -> Deferred {
	entry := Deferred {
		type             = element,
		array_cleanup    = true,
		array_buffer     = buffer,
		array_flags      = flags,
		array_count      = count,
		array_buffer_env = -1,
		array_flags_env  = -1,
		array_count_env  = -1,
		slot             = -1,
	}
	if unwind_enabled(e) {
		entry.array_buffer_env = unwind_reserve_env(e)
		entry.array_flags_env = unwind_reserve_env(e)
		entry.array_count_env = unwind_reserve_env(e)
	}
	unwind_reserve(e, &entry)
	unwind_publish_env(e, entry.array_buffer_env, buffer)
	unwind_publish_env(e, entry.array_flags_env, flags)
	unwind_publish_env(e, entry.array_count_env, count)
	unwind_register(e, entry)
	return entry
}

// ------------------------------------------------------- lifecycle bodies --

// design.md "Typed fallibility": `try_clone` returns `Result(T, Allocator_Error)`.
// The clone machinery keeps working in `(value, failed)` pairs internally and
// converts only at the two boundaries - the call and the return.
@(private)
clone_result_of :: proc(e: ^Emitter, hook: Symbol_Id) -> Type_Id {
	sym := symbol_of(e.c, hook)
	if sym == nil || sym.result == INVALID_TYPE {
		backend_fail(e, "a `try_clone` member has no result type")
		return INVALID_TYPE
	}
	return sym.result
}

// Calls one `try_clone` and unpacks its result into the internal pair. The
// cloned value is only meaningful where `failed` is false.
@(private)
emit_clone_call :: proc(
	e: ^Emitter, hook: Symbol_Id, subject: Type_Id, value, allocator: string,
) -> (cloned: string, failed: string) {
	result := clone_result_of(e, hook)
	returned := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = call %s %s(%s %s, ptr %s)",
		returned, llvm_type(e, result), e.names[hook], llvm_type(e, subject), value, allocator,
	)
	slot := emit_union_spill(e, result, returned)
	failed = emit_union_failed(e, result, returned)
	cloned = emit_union_payload(e, result, subject, slot)
	return
}

// Compiler-generated field-wise cloning calls `try_clone` recursively for every
// owning field, destroys a partially completed temporary on failure, and
// returns zero plus the error (design.md).
//
// A type no part of which reaches a custom hook cannot fail, so its generated
// body is the copy the representation already is. The branchy shape below exists
// only where a real hook can return an error.
@(private)
emit_synth_try_clone :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	subject := symbol.params[0]
	operations := emit_lifecycle(e, subject)
	value_type := llvm_type(e, subject)
	result := symbol.result
	pair := llvm_type(e, result)
	fmt.sbprintf(&e.b, "define %s %s(%s %%arg0, ptr %%arg1)", pair, name, value_type)
	fmt.sbprintln(&e.b, " {")
	fmt.sbprintln(&e.b, "entry:")
	e.terminated = false

	// A user `hook(copy)` is the fallible primitive. The public generated
	// `try_clone` member is a stable wrapper around it.
	if hook := operations.custom_try_clone; hook != INVALID_SYMBOL {
		fmt.sbprintfln(&e.b, "  %%custom = call %s %s(%s %%arg0, ptr %%arg1)", pair, e.names[hook], value_type)
		fmt.sbprintfln(&e.b, "  ret %s %%custom", pair)
		fmt.sbprintln(&e.b, "}")
		return
	}

	// A trivial value is its own clone. Copy fallibility is the wrong
	// question here: a `string` part clones infallibly but still has to retain its
	// handle, so asking about failure alone would hand back a second owner of one
	// allocation with the count still at 1.
	if !operations.managed {
		fmt.sbprintfln(&e.b, "  ret %s %s", pair, emit_alloc_result(e, result, "false", "%arg0"))
		fmt.sbprintln(&e.b, "}")
		return
	}

	if info := underlying_info(e.c, subject); info != nil && info.kind == .Union {
		emit_union_try_clone_body(e, subject, info, result, pair, value_type)
		return
	}

	// design.md "standard interface catalogue": the copyable owning built-ins
	// satisfy `Cloneable`, so `string`, `[dynamic]T` and `map[K]V` carry the same
	// `try_clone` member a record does. Its body is the one intrinsic copy the
	// implicit paths already use — a retain, or the versioned container helper.
	if operations.intrinsic {
		self, built := alloca(e, value_type), alloca(e, value_type)
		fmt.sbprintfln(&e.b, "  store %s %%arg0, ptr %s", value_type, self)
		// A failed container clone leaves the destination untouched, so the zero
		// value is what travels back beside the error.
		fmt.sbprintfln(&e.b, "  store %s zeroinitializer, ptr %s", value_type, built)
		ok := emit_try_clone_into(e, subject, built, self, "%arg1")
		value := load(e, value_type, built)
		broke := temp(e)
		fmt.sbprintfln(&e.b, "  %s = xor i1 %s, true", broke, ok)
		fmt.sbprintfln(&e.b, "  ret %s %s", pair, emit_alloc_result(e, result, broke, value))
		fmt.sbprintln(&e.b, "}")
		return
	}

	// Both sides are addressed rather than kept in registers: a failure path has
	// to drop what the destination already holds, and a drop hook takes a place.
	self := alloca(e, value_type)
	out := temp(e)
	fmt.sbprintfln(&e.b, "  store %s %%arg0, ptr %s", value_type, self)
	alloca_named(e, out, value_type)
	// Every hook must handle the inert zero value (design.md), and a cleanup that
	// runs before a part is written must see that zero rather than garbage.
	fmt.sbprintfln(&e.b, "  store %s zeroinitializer, ptr %s", value_type, out)

	for index in 0 ..< clone_part_count(e.c, subject) {
		part := clone_part(e.c, subject, index)
		part_operations := emit_lifecycle(e, part)
		source := element_address(e, subject, self, index)
		destination := element_address(e, subject, out, index)
		if !part_operations.managed {
			loaded := load(e, llvm_type(e, part), source)
			store(e, part, loaded, destination)
			continue
		}
		// Managed but infallible — a `string` handle, or a record of them. There is
		// no error to branch on, but there is real copy work to do.
		if !part_operations.clone_fallible {
			loaded := load(e, llvm_type(e, part), source)
			store(e, part, emit_clone_value(e, part, loaded, "%arg1"), destination)
			continue
		}
		cloned, failed := emit_part_clone(e, part, source)
		unwind, ok := new_label(e, "clone.unwind"), new_label(e, "clone.ok")
		branch_if(e, failed, unwind, ok)

		// The partially built temporary, cleaned in reverse part order. Everything
		// past `index` is still the inert zero this block never wrote.
		place_label(e, unwind)
		for done := index - 1; done >= 0; done -= 1 {
			emit_drop_place(e, clone_part(e.c, subject, done), element_address(e, subject, out, done))
		}
		fmt.sbprintfln(&e.b, "  ret %s %s", pair, emit_alloc_result(e, result, "true"))
		e.terminated = true
		// Only a successful part is published, so a hook that breaks its contract
		// and hands back a live value beside an error cannot leave one in the
		// temporary that cleanup would never reach.
		place_label(e, ok)
		store(e, part, cloned, destination)
	}

	built := load(e, value_type, out)
	fmt.sbprintfln(&e.b, "  ret %s %s", pair, emit_alloc_result(e, result, "false", built))
	fmt.sbprintln(&e.b, "}")
}

// The address of part `index`, which is a struct field or an array element.
@(private = "file")
element_address :: proc(e: ^Emitter, owner: Type_Id, base: string, index: int) -> string {
	info := underlying_info(e.c, owner)
	out := temp(e)
	if info != nil && info.kind == .Array {
		fmt.sbprintfln(
			&e.b, "  %s = getelementptr inbounds %s, ptr %s, i64 0, i64 %d",
			out, llvm_type(e, owner), base, index,
		)
		return out
	}
	fmt.sbprintfln(
		&e.b, "  %s = getelementptr inbounds %s, ptr %s, i32 0, i32 %d",
		out, llvm_type(e, owner), base, index,
	)
	return out
}

// Clones one part through its own `try_clone` — custom or generated, both real
// members. Returns the cloned value and the error word; the caller publishes the
// value only on the success path.
@(private = "file")
emit_part_clone :: proc(e: ^Emitter, part: Type_Id, source: string) -> (string, string) {
	operations := emit_lifecycle(e, part)
	// A container part uses the versioned C helper directly, driven by this
	// type's generated operation table.
	if operations.container {
		destination := alloca(e, CONTAINER_TYPE)
		ok := emit_try_clone_into(e, part, destination, source, "%arg1")
		cloned := load(e, CONTAINER_TYPE, destination)
		failed := temp(e)
		fmt.sbprintfln(&e.b, "  %s = xor i1 %s, true", failed, ok)
		return cloned, failed
	}
	hook := operations.try_clone
	if hook == INVALID_SYMBOL {
		// The checked facts say this part reaches a custom hook, so the
		// contribution pass owed it one.
		backend_fail(e, "a fallible clone part has no `try_clone` member")
		return "0", "true"
	}
	loaded := load(e, llvm_type(e, part), source)
	return emit_clone_call(e, hook, part, loaded, "%arg1")
}

// Drops every initialized element of a compiler-owned variadic buffer in
// reverse order. A flag is cleared before its hook runs, so a panic raised by
// that hook cannot replay the same element; remaining flags stay visible to the
// frame's unwind action.
@(private)
emit_drop_flagged_array :: proc(e: ^Emitter, element: Type_Id, buffer, flags, count_address: string) {
	count := load(e, "i64", count_address)
	cursor := alloca(e, "i64")
	fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", count, cursor)
	head, inspect, done := new_label(e, "vararg.drop.head"), new_label(e, "vararg.drop.inspect"), new_label(e, "vararg.drop.done")
	branch(e, head)
	place_label(e, head)
	remaining := load(e, "i64", cursor)
	has_more := temp(e)
	fmt.sbprintfln(&e.b, "  %s = icmp ugt i64 %s, 0", has_more, remaining)
	branch_if(e, has_more, inspect, done)
	place_label(e, inspect)
	index := temp(e)
	fmt.sbprintfln(&e.b, "  %s = sub i64 %s, 1", index, remaining)
	fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", index, cursor)
	flag_address, live := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = getelementptr i1, ptr %s, i64 %s", flag_address, flags, index)
	fmt.sbprintfln(&e.b, "  %s = load i1, ptr %s", live, flag_address)
	run, next := new_label(e, "vararg.drop.run"), new_label(e, "vararg.drop.next")
	branch_if(e, live, run, next)
	place_label(e, run)
	fmt.sbprintfln(&e.b, "  store i1 false, ptr %s", flag_address)
	slot := gep_at(e, llvm_type(e, element), buffer, index)
	emit_drop_place(e, element, slot)
	branch(e, next)
	place_label(e, next)
	branch(e, head)
	place_label(e, done)
}

// `clone` calls `try_clone` once and, on failure, invokes the supplied
// allocator's failure policy (design.md).
@(private)
emit_synth_clone :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	subject := symbol.params[0]
	value_type := llvm_type(e, subject)
	fmt.sbprintf(&e.b, "define %s %s(%s %%arg0, ptr %%arg1)", value_type, name, value_type)
	fmt.sbprintln(&e.b, " {")
	fmt.sbprintln(&e.b, "entry:")
	e.terminated = false

	cloned := emit_clone_with_policy(e, subject, "%arg0", "%arg1")
	fmt.sbprintfln(&e.b, "  ret %s %s", value_type, cloned)
	fmt.sbprintln(&e.b, "}")
}

// Shared by public record wrappers and implicit array copies. The fallible
// operation owns partial-copy cleanup; only a complete result is published.
@(private = "file")
emit_clone_with_policy :: proc(e: ^Emitter, subject: Type_Id, value, allocator: string) -> string {
	hook := emit_lifecycle(e, subject).try_clone
	if hook == INVALID_SYMBOL {
		backend_fail(e, "a policy-following copy has no `try_clone` operation")
		return "0"
	}
	cloned, failed := emit_clone_call(e, hook, subject, value, allocator)
	// design.md "Allocation failure": an implicit copy has nowhere to return an
	// error, so the *allocator's* policy decides — `.Panic` follows the program
	// strategy and `.Trap` terminates immediately under either. The runtime reads
	// that policy off the handle the clone was given.
	fail, ok := new_label(e, "clone.failed"), new_label(e, "ok")
	branch_if(e, failed, fail, ok)
	place_label(e, fail)
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_alloc_failed(ptr %s)", allocator)
	fmt.sbprintln(&e.b, "  unreachable")
	e.terminated = true
	place_label(e, ok)
	return cloned
}

// All lifecycle decisions come from the completed semantic snapshot. Returning
// an inert value after failure lets lowering unwind without repairing the cache.
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

// `drop(value)` invokes the user hook when present, and fields are dropped in
// reverse declaration order after the containing type's drop hook returns
// (design.md). Used by partial-clone cleanup now; step 4's scope-exit cleanup is
// the same walk from a different caller.
emit_drop_place :: proc(e: ^Emitter, type: Type_Id, address: string) {
	operations := emit_lifecycle(e, type)
	if !operations.managed {
		return
	}
	// design.md "Dynamic arrays"/"Maps": container drop destroys every live
	// element exactly once, releases the raw storage through the bound provider,
	// and writes the inert all-zero representation. The all-zero value has no
	// storage and no provider, so dropping one is already a no-op in the helper.
	if operations.container {
		helper := type_is_map(e.c, type) ? "loke_rt_v1_map_drop" : "loke_rt_v1_dyn_drop"
		fmt.sbprintfln(&e.b, "  call void @%s(ptr %s, ptr %s)", helper, address, container_ops_global(e, type))
		return
	}
	// design.md "Allocators": ending a local region releases every block it
	// handed out. The zero (or moved-from) control pointer drops to nothing,
	// which is what makes a moved-out provider safe to leave behind.
	if operations.provider {
		control := load(e, "ptr", address)
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_arena_drop(ptr %s)", control)
		fmt.sbprintfln(&e.b, "  store ptr null, ptr %s", address)
		return
	}
	// design.md "string type": the drop releases one handle, and the last one
	// deallocates through the allocator the string was created with. A static
	// literal and the empty value are both no-ops the runtime recognises.
	if operations.intrinsic {
		value := load(e, STRING_TYPE, address)
		owner := extract(e, STRING_TYPE, value, STRING_OWNER)
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_string_release(i64 %s)", owner)
		return
	}
	if hook := operations.custom_drop; hook != INVALID_SYMBOL {
		fmt.sbprintfln(&e.b, "  call void %s(ptr %s)", e.names[hook], address)
	}
	// design.md "Unions": a union owns exactly one payload, so its drop reads the
	// tag and destroys that variant alone. No inactive payload is loaded.
	if info := underlying_info(e.c, type); info != nil && info.kind == .Union {
		emit_union_drop(e, type, info, address)
		return
	}
	for index := clone_part_count(e.c, type) - 1; index >= 0; index -= 1 {
		part := clone_part(e.c, type, index)
		if !emit_lifecycle(e, part).managed {
			continue
		}
		emit_drop_place(e, part, element_address(e, type, address, index))
	}
}

// The tag-aware half of `emit_drop_place`. Only a variant whose payload is
// managed gets a block; every other tag falls straight through to `done`.
@(private = "file")
emit_union_drop :: proc(e: ^Emitter, type: Type_Id, info: ^Type_Info, address: string) {
	shape := union_layout(e.c, type)
	value := load(e, llvm_type(e, type), address)
	tag := emit_union_tag(e, type, value)
	done := new_label(e, "uniondrop.done")
	for variant, index in info.variants {
		if variant == TYPE_VOID || !type_is_managed(e.c, variant) {
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
	// A dropped union is left inert, so a second drop on an unwind path is a
	// no-op rather than a second release of the same payload.
	fmt.sbprintfln(&e.b, "  store %s zeroinitializer, ptr %s", llvm_type(e, type), address)
}

// The tag-aware half of `emit_synth_try_clone`. Each managed variant clones its
// own payload and rebuilds the union at that variant; a partial failure has
// nothing to unwind, because a union holds one payload and it is either cloned
// whole or not at all.
@(private = "file")
emit_union_try_clone_body :: proc(
	e: ^Emitter, subject: Type_Id, info: ^Type_Info, result: Type_Id, pair, value_type: string,
) {
	shape := union_layout(e.c, subject)
	self := alloca(e, value_type)
	fmt.sbprintfln(&e.b, "  store %s %%arg0, ptr %s", value_type, self)
	tag := emit_union_tag(e, subject, "%arg0")

	for variant, index in info.variants {
		if variant == TYPE_VOID || !type_is_managed(e.c, variant) {
			continue
		}
		matched := temp(e)
		fmt.sbprintfln(&e.b, "  %s = icmp eq i%d %s, %d", matched, shape.tag_bytes * 8, tag, index)
		hit, next := new_label(e, "unionclone.hit"), new_label(e, "unionclone.next")
		branch_if(e, matched, hit, next)

		place_label(e, hit)
		source := gep_field(e, value_type, self, 0)
		if !type_clone_is_fallible(e.c, variant) {
			loaded := load(e, llvm_type(e, variant), source)
			cloned := emit_clone_value(e, variant, loaded, "%arg1")
			built := emit_union_value(e, subject, index, cloned)
			fmt.sbprintfln(&e.b, "  ret %s %s", pair, emit_alloc_result(e, result, "false", built))
			e.terminated = true
			place_label(e, next)
			continue
		}
		cloned, failed := emit_part_clone(e, variant, source)
		broke, ok := new_label(e, "unionclone.failed"), new_label(e, "unionclone.ok")
		branch_if(e, failed, broke, ok)
		place_label(e, broke)
		fmt.sbprintfln(&e.b, "  ret %s %s", pair, emit_alloc_result(e, result, "true"))
		e.terminated = true
		place_label(e, ok)
		built := emit_union_value(e, subject, index, cloned)
		fmt.sbprintfln(&e.b, "  ret %s %s", pair, emit_alloc_result(e, result, "false", built))
		e.terminated = true
		place_label(e, next)
	}

	// Every remaining tag holds a payload the representation already copies.
	fmt.sbprintfln(&e.b, "  ret %s %s", pair, emit_alloc_result(e, result, "false", "%arg0"))
	fmt.sbprintln(&e.b, "}")
}

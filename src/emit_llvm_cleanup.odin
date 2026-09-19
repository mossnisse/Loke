// Cleanup registration, panic replay, and lifecycle clone/drop emission.
//
// Part of the textual LLVM backend; see compiler-architecture.md.
package lokec

import "core:fmt"
import "core:strings"

@(private)
// One registered cleanup action: a written `defer`, or a managed local's
// implicit drop. Both share one reverse registration order (design.md).
// `flag` is empty when the CFG proved the slot reached unconditionally.
Deferred :: struct {
	flag: string,
	// A written `defer`, or nil for an implicit drop of `place`.
	stmt:  Stmt,
	place: string,
	// A compiler-owned temporary has no symbol; its address is published at
	// `place_env` so panic replay can reach it.
	temporary_place: bool,
	place_env:       int,
	place_symbol:    Symbol_Id,
	type:  Type_Id,
	// A compiler-owned variadic buffer with per-element flags. The env indices
	// serve the unwind thunk; the direct names serve normal cleanup.
	array_cleanup:  bool,
	array_buffer:   string,
	array_flags:    string,
	array_count:    string,
	array_buffer_env: int,
	array_flags_env:  int,
	array_count_env:  int,
	// Index in the procedure's registration state, or -1 under `-panic=abort`.
	slot: int,
}

Unwind_Env_Binding :: struct {
	symbol: Symbol_Id,
	index:  int,
}

// One procedure's runtime-visible cleanup registration. A panic never unwinds
// the native stack: the runtime calls each live frame's generated thunk, which
// reads which actions are registered (`live`) and where their storage is (`env`).
Unwind_State :: struct {
	live:  string, // `[n x i1]`: action `i` is registered right now
	env:   string, // `[n x ptr]`: the storage each replayed action addresses
	frame: string, // the `{previous, cleanup, context}` record this frame pushes
	ctx:   string, // `[2 x ptr]` = {live, env}, the thunk's one argument
	thunk: string,
	// Every action in source order, so descending-index replay is reverse
	// registration order.
	actions:      [dynamic]Deferred,
	env_index:    map[Symbol_Id]int,
	env_bindings: [dynamic]Unwind_Env_Binding,
	env_count:    int,
	// Registration slots, so `move`/`drop` and a re-entered scope can clear them.
	slot_by_symbol: map[Symbol_Id]int,
	slot_by_defer:  map[int]int,
	// True while the thunk is emitted, so replayed code registers nothing.
	replaying: bool,
}

@(private)
Cleanup_Scope :: struct {
	entries: [dynamic]Deferred,
}

// Deep-copies `src` into `out`, answering an `i1` that is true on success. On
// failure `out` is left untouched, so the caller can destroy exactly the prefix
// it did build.
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
		if emit_dead_move_only_copy(e, type) {
			return "false"
		}
		backend_fail(e, "a fallible container element has no `try_clone` member")
		return "false"
	}
	cloned, broke := emit_clone_call(e, hook, type, value, allocator)
	ok := temp(e)
	fmt.sbprintfln(&e.b, "  %s = xor i1 %s, true", ok, broke)
	// A failed clone returns an inert zero the caller must not count as
	// initialised, so the value is stored only on success.
	store_label, done_label := new_label(e, "clone.store"), new_label(e, "clone.done")
	branch_if(e, ok, store_label, done_label)
	place_label(e, store_label)
	store(e, type, cloned, out)
	branch(e, done_label)
	place_label(e, done_label)
	return ok
}

// ---------------------------------------------------------- panic unwind --

// Under `-panic=abort` nothing is registered and no thunk is generated.
@(private = "file")
unwind_enabled :: proc(e: ^Emitter) -> bool {
	return e.c.panic_unwind && !e.unwind.replaying
}

// Fresh registration state for one procedure. The names are chosen up front
// because the array sizes are only known once the body is emitted.
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

@(private)
unwind_reserve :: proc(e: ^Emitter, entry: ^Deferred) {
	entry.slot = -1
	if !unwind_enabled(e) {
		return
	}
	entry.slot = len(e.unwind.actions)
	append(&e.unwind.actions, entry^)
}

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

// Names a local and publishes its address into the env for the thunk.
//
// ponytail: every local is published, not just the ones a cleanup names;
// narrowing it needs a free-variable walk over every deferred statement.
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

@(private = "file")
unwind_env_load :: proc(e: ^Emitter, env: string, index: int) -> string {
	address, value := temp(e), temp(e)
	fmt.sbprintfln(&e.b, "  %s = getelementptr ptr, ptr %s, i64 %d", address, env, index)
	fmt.sbprintfln(&e.b, "  %s = load ptr, ptr %s", value, address)
	return value
}

// Marks an action registered, only once it is *fully* registered (design.md).
@(private)
unwind_register :: proc(e: ^Emitter, entry: Deferred) {
	if entry.slot < 0 || !unwind_enabled(e) {
		return
	}
	fmt.sbprintfln(&e.b, "  store i1 true, ptr %s", unwind_live_address(e, entry.slot))
}

// Clears a registration before the action's own code runs, so a panic raised
// by a cleanup cannot ask for it again. It also runs inside the thunk, where
// `e.unwind.live` names the thunk's own view of the array, so a replayed
// `drop(x)` stops x's implicit drop from replaying too.
@(private)
unwind_clear :: proc(e: ^Emitter, slot: int) {
	if slot < 0 || !e.c.panic_unwind {
		return
	}
	fmt.sbprintfln(&e.b, "  store i1 false, ptr %s", unwind_live_address(e, slot))
}

// The frame prologue, written once the body is emitted and the array lengths
// are known.
@(private)
emit_unwind_prologue :: proc(e: ^Emitter) {
	u := &e.unwind
	if u.frame == "" {
		return
	}
	// `{` is a directive to core:fmt, so the record type is written literally.
	FRAME :: "{ ptr, ptr, ptr }"
	alloca_named(e, u.frame, FRAME)
	fmt.sbprint(&e.b, "  store ")
	fmt.sbprint(&e.b, FRAME)
	fmt.sbprint(&e.b, " zeroinitializer, ptr ")
	fmt.sbprintln(&e.b, u.frame)
	if len(u.actions) == 0 && u.env_count == 0 {
		// Nothing is pushed; the zeroed record makes the epilogue's pop a no-op.
		return
	}
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
	// Unlike `begin_function_emission`, this keeps the parent's unwind state and
	// result slot: it replays the parent's own actions.
	saved_body, saved_terminated := e.b, e.terminated
	saved_cleanups, saved_prologue := e.cleanups, e.prologue
	saved_live := u.live
	e.b = strings.builder_make()
	e.terminated = false
	e.cleanups = make([dynamic]Cleanup_Scope)
	e.prologue = nil
	u.replaying = true

	open_function(e, "define private void %s(ptr %%ctx)", u.thunk)
	u.live = load(e, "ptr", "%ctx")
	env := unwind_env_load(e, "%ctx", 1)

	// Rebind every published local to its address in the env. An empty saved
	// name means "had none", and is deleted rather than restored.
	saved_names := make([dynamic]string, 0, len(u.env_bindings))
	for binding in u.env_bindings {
		append(&saved_names, e.names[binding.symbol])
		e.names[binding.symbol] = unwind_env_load(e, env, binding.index)
	}

	// The `%deferN` flags are parent allocas the thunk cannot reach. Each gets a
	// local stand-in seeded `true`: an action only runs where its live byte
	// already says so.
	saved_flags := e.defer_flags
	e.defer_flags = make([]string, len(saved_flags))
	for index in 0 ..< len(saved_flags) {
		flag := fmt.aprintf("%%udefer%d.%d", index, next_id(e))
		alloca_named(e, flag, "i1")
		fmt.sbprintfln(&e.b, "  store i1 true, ptr %s", flag)
		e.defer_flags[index] = flag
	}

	for index := len(u.actions) - 1; index >= 0; index -= 1 {
		entry := u.actions[index]
		address := unwind_live_address(e, index)
		flag := load(e, "i1", address)
		run, skip := new_label(e, "unwind.run"), new_label(e, "unwind.skip")
		branch_if(e, flag, run, skip)
		place_label(e, run)
		fmt.sbprintfln(&e.b, "  store i1 false, ptr %s", address)
		if entry.array_cleanup {
			buffer := unwind_env_load(e, env, entry.array_buffer_env)
			flags := unwind_env_load(e, env, entry.array_flags_env)
			count := unwind_env_load(e, env, entry.array_count_env)
			emit_drop_flagged_array(e, entry.type, buffer, flags, count)
		} else if entry.stmt != nil {
			emit_stmt(e, entry.stmt)
		} else if entry.temporary_place {
			emit_drop_place(e, entry.type, unwind_env_load(e, env, entry.place_env))
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
		if saved_names[index] == "" {
			delete_key(&e.names, binding.symbol)
			continue
		}
		e.names[binding.symbol] = saved_names[index]
	}
	append(&e.pending, splice_prologue(e, strings.to_string(e.b), e.prologue[:]))
	u.replaying = false
	u.live = saved_live
	e.b, e.terminated, e.cleanups = saved_body, saved_terminated, saved_cleanups
	e.prologue, e.defer_flags = saved_prologue, saved_flags
}

// Registers a partially constructed compiler-owned value for panic replay only;
// the builder clears it once complete.
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

// A completed owned value borrowed by an operation. Register it before
// evaluating later arguments.
@(private)
hold_temporary_value :: proc(e: ^Emitter, type: Type_Id, value: string) -> Deferred {
	if !emit_lifecycle(e, type).managed { return Deferred{slot = -1} }
	place := alloca(e, llvm_type(e, type))
	store(e, type, value, place)
	return begin_temporary_drop(e, type, place)
}

// A place whose drop belongs to the innermost lexical scope, such as a variant
// switch's subject, which its case bindings only borrow.
@(private)
register_scope_place :: proc(e: ^Emitter, type: Type_Id, place: string) {
	if !emit_lifecycle(e, type).managed || len(e.cleanups) == 0 {
		return
	}
	append(&e.cleanups[len(e.cleanups) - 1].entries, begin_temporary_drop(e, type, place))
}

@(private)
drop_temporary_value :: proc(e: ^Emitter, entry: Deferred) {
	if entry.place == "" { return }
	// Clear before invoking a user drop hook, which can itself panic.
	finish_temporary_drop(e, entry)
	emit_drop_place(e, entry.type, entry.place)
}

// ------------------------------------------------ full-expression frames --

// design.md "Borrows and lifetimes": a borrowed owned temporary lives until the
// end of its complete expression. The storage is a hoisted alloca, so a
// scope-registered drop inside a loop would leak every earlier iteration;
// every construct that evaluates an expression declares its own frame instead.
@(private)
push_temporaries :: proc(e: ^Emitter) {
	append(&e.temporaries, make([dynamic]Deferred))
}

@(private)
pop_temporaries :: proc(e: ^Emitter) {
	if len(e.temporaries) == 0 {
		return
	}
	if !e.terminated {
		drain_temporaries(e, len(e.temporaries) - 1)
	}
	entries := e.temporaries[len(e.temporaries) - 1]
	delete(entries)
	pop(&e.temporaries)
}

// Drops the frames above `down_to`, innermost first, without closing them: an
// exit that branches away owes their drops, while the fall-through path pops.
@(private)
drain_temporaries :: proc(e: ^Emitter, down_to: int) {
	for depth := len(e.temporaries) - 1; depth >= down_to; depth -= 1 {
		entries := e.temporaries[depth]
		for index := len(entries) - 1; index >= 0; index -= 1 {
			drop_temporary_value(e, entries[index])
		}
	}
}

// With no frame open the enclosing scope is the boundary, which is the extended
// lifetime design.md gives a `foreach` iterable, a `switch` subject, and an
// initial statement.
@(private)
register_temporary_place :: proc(e: ^Emitter, type: Type_Id, place: string) {
	if !emit_lifecycle(e, type).managed {
		return
	}
	if len(e.temporaries) == 0 {
		register_scope_place(e, type, place)
		return
	}
	entry := begin_temporary_drop(e, type, place)
	append(&e.temporaries[len(e.temporaries) - 1], entry)
}

// -------------------------------------------------------------- cleanups --

@(private)
push_scope :: proc(e: ^Emitter, b: ^Block) {
	push_scope_stmts(e, b == nil ? nil : b.stmts)
}

@(private)
push_scope_stmts :: proc(e: ^Emitter, stmts: []Stmt) {
	append(&e.cleanups, Cleanup_Scope{entries = make([dynamic]Deferred)})
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
			if slot, registered := e.unwind.slot_by_defer[s.slot]; registered {
				unwind_clear(e, slot)
			}
		case ^Decl:
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

// Runs every scope above `down_to`, innermost first and in reverse registration
// order within each.
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
	unwind_clear(e, entry.slot)
	if entry.stmt != nil {
		emit_stmt(e, entry.stmt)
		return
	}
	emit_drop_place(e, entry.type, entry.place)
}

// A managed local's implicit conditional `defer drop(value)` (design.md).
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
	if !sym.drop_at_exit || len(e.cleanups) == 0 {
		return
	}
	entry := Deferred{flag = flag, place = symbol_name(e, symbol_id), place_symbol = symbol_id, type = sym.type}
	unwind_reserve(e, &entry)
	e.unwind.slot_by_symbol[symbol_id] = entry.slot
	if live {
		unwind_register(e, entry)
	}
	append(&e.cleanups[len(e.cleanups) - 1].entries, entry)
}

// A whole-local assignment makes the place hold a value again, so its implicit
// drop is registered for panic replay once more.
@(private)
revive_place :: proc(e: ^Emitter, target: Expr) {
	ident, is_ident := target.(^Expr_Ident)
	if !is_ident {
		return
	}
	if slot, registered := e.unwind.slot_by_symbol[ident.symbol]; registered {
		unwind_register(e, Deferred{slot = slot})
	}
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
	if zero, ok := zero_const(e.c, sym.type); ok {
		store(e, sym.type, llvm_const(e, zero, sym.type), symbol_name(e, symbol_id))
	}
	if flag := drop_flag_of(e, symbol_id); flag != "" {
		fmt.sbprintfln(&e.b, "  store i1 false, ptr %s", flag)
	}
	if slot, registered := e.unwind.slot_by_symbol[symbol_id]; registered {
		unwind_clear(e, slot)
	}
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
	slot := alloca(e, llvm_type(e, base.type))
	store(e, base.type, value, slot)
	emit_drop_place(e, base.type, slot)
}

// An implicit copy goes through `clone`, which calls `try_clone` once and
// applies the allocator's failure policy (design.md). An empty `allocator`
// means the build-selected default.
@(private)
emit_clone_value :: proc(e: ^Emitter, type: Type_Id, value: string, allocator := "") -> string {
	entry := emit_lifecycle(e, type)
	provider := allocator
	if provider == "" && (entry.container || entry.clone != INVALID_SYMBOL ||
	   underlying_kind(e.c, type) == .Array) {
		provider = emit_default_allocator(e)
	}
	if entry.container {
		source := alloca(e, CONTAINER_TYPE)
		destination := alloca(e, CONTAINER_TYPE)
		fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", CONTAINER_TYPE, value, source)
		ok := emit_try_clone_into(e, type, destination, source, provider)
		fail_label, done_label := new_label(e, "cclone.fail"), new_label(e, "cclone.done")
		branch_if(e, ok, done_label, fail_label)
		place_label(e, fail_label)
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_alloc_failed(ptr %s)", provider)
		fmt.sbprintln(&e.b, "  unreachable")
		e.terminated = true
		place_label(e, done_label)
		return load(e, CONTAINER_TYPE, destination)
	}
	// A string copy retains a shared handle; only `.copy()` allocates.
	if entry.intrinsic {
		owner := extract(e, STRING_TYPE, value, STRING_OWNER)
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_string_retain(i64 %s)", owner)
		return value
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
	out := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = call %s %s(%s %s, ptr %s)",
		out, llvm_type(e, type), symbol_name(e, hook), receiver_type, receiver, provider,
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

// `try_clone` returns `Result(T, Allocator_Error)`; internally the clone
// machinery works in `(value, failed)` pairs.
@(private)
clone_result_of :: proc(e: ^Emitter, hook: Symbol_Id) -> Type_Id {
	sym := symbol_of(e.c, hook)
	if sym == nil || sym.result == INVALID_TYPE {
		backend_fail(e, "a `try_clone` member has no result type")
		return INVALID_TYPE
	}
	return sym.result
}

// Calls one `try_clone`. `cloned` is only meaningful where `failed` is false.
@(private)
emit_clone_call :: proc(
	e: ^Emitter, hook: Symbol_Id, subject: Type_Id, value, allocator: string,
) -> (cloned: string, failed: string) {
	result := clone_result_of(e, hook)
	receiver_type, receiver := call_receiver_operand(e, hook, subject, value)
	returned := temp(e)
	fmt.sbprintfln(
		&e.b, "  %s = call %s %s(%s %s, ptr %s)",
		returned, llvm_type(e, result), symbol_name(e, hook), receiver_type, receiver, allocator,
	)
	slot := emit_union_spill(e, result, returned)
	failed = emit_union_failed(e, result, returned)
	cloned = emit_union_payload(e, result, subject, slot)
	return
}

// Generated field-wise `try_clone`: clones every owning part, destroys the
// partial result on failure, and returns zero plus the error (design.md).
@(private)
emit_synth_try_clone :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	subject := symbol.params[0]
	operations := emit_lifecycle(e, subject)
	value_type := llvm_type(e, subject)
	result := symbol.result
	pair := llvm_type(e, result)
	open_function(
		e, "define %s%s %s(%s %%arg0, ptr %%arg1)",
		llvm_linkage(name), pair, name, synth_param_llvm(e, symbol, 0),
	)
	e.terminated = false
	subject_value := synth_receiver_value(e, symbol)

	// A user `hook(copy)` is the primitive; forward the receiver in its own mode.
	if hook := operations.custom_try_clone; hook != INVALID_SYMBOL {
		hook_type, hook_receiver := value_type, subject_value
		if hook_sym := symbol_of(e.c, hook);
		   hook_sym != nil && param_mode_is_pointer(symbol_param_mode(e.c, hook_sym, 0)) {
			hook_type, hook_receiver = "ptr", "%arg0"
		}
		fmt.sbprintfln(&e.b, "  %%custom = call %s %s(%s %s, ptr %%arg1)", pair, symbol_name(e, hook), hook_type, hook_receiver)
		fmt.sbprintfln(&e.b, "  ret %s %%custom", pair)
		fmt.sbprintln(&e.b, "}")
		return
	}

	// An unmanaged value is its own clone. (A `string` part is infallible but
	// managed: it still needs a retain.)
	if !operations.managed {
		fmt.sbprintfln(&e.b, "  ret %s %s", pair, emit_alloc_result(e, result, "false", subject_value))
		fmt.sbprintln(&e.b, "}")
		return
	}

	if info := underlying_info(e.c, subject); info != nil && info.kind == .Union {
		emit_union_try_clone_body(e, subject, info, result, pair, value_type, subject_value)
		return
	}

	// `string`, `[dynamic]T` and `map[K]V` carry a `try_clone` whose body is the
	// same intrinsic copy the implicit paths use.
	if operations.intrinsic {
		self, built := alloca(e, value_type), alloca(e, value_type)
		fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", value_type, subject_value, self)
		fmt.sbprintfln(&e.b, "  store %s zeroinitializer, ptr %s", value_type, built)
		ok := emit_try_clone_into(e, subject, built, self, "%arg1")
		value := load(e, value_type, built)
		broke := temp(e)
		fmt.sbprintfln(&e.b, "  %s = xor i1 %s, true", broke, ok)
		fmt.sbprintfln(&e.b, "  ret %s %s", pair, emit_alloc_result(e, result, broke, value))
		fmt.sbprintln(&e.b, "}")
		return
	}

	// Both sides live in memory: a failure path drops what the destination holds,
	// and it starts zeroed so every hook sees the inert value, never garbage.
	self := alloca(e, value_type)
	out := temp(e)
	fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", value_type, subject_value, self)
	alloca_named(e, out, value_type)
	fmt.sbprintfln(&e.b, "  store %s zeroinitializer, ptr %s", value_type, out)

	for index in 0 ..< clone_part_count(e.c, subject) {
		part := clone_part(e.c, subject, index)
		part_operations := emit_lifecycle(e, part)
		source := element_address(e, subject, self, index)
		destination := element_address(e, subject, out, index)
		// An unmanaged `@(initialized)` field is copied whole as bytes below.
		if field, counter, prefixed := record_prefix_part(e, subject, index); prefixed &&
		   part_operations.managed {
			emit_clone_prefix(e, subject, self, out, field, counter, index, result, pair)
			continue
		}
		if !part_operations.managed {
			loaded := load(e, llvm_type(e, part), source)
			store(e, part, loaded, destination)
			continue
		}
		if !part_operations.clone_fallible {
			loaded := load(e, llvm_type(e, part), source)
			store(e, part, emit_clone_value(e, part, loaded, "%arg1"), destination)
			continue
		}
		cloned, failed := emit_part_clone(e, part, source)
		unwind, ok := new_label(e, "clone.unwind"), new_label(e, "clone.ok")
		branch_if(e, failed, unwind, ok)

		// Drop the parts already built, in reverse; later ones are still zero.
		place_label(e, unwind)
		for done := index - 1; done >= 0; done -= 1 {
			emit_drop_record_part(e, subject, out, done)
		}
		fmt.sbprintfln(&e.b, "  ret %s %s", pair, emit_alloc_result(e, result, "true"))
		e.terminated = true
		// Only a successful part is published, so a hook that returns a live value
		// beside an error cannot leak it into the temporary.
		place_label(e, ok)
		store(e, part, cloned, destination)
	}

	built := load(e, value_type, out)
	fmt.sbprintfln(&e.b, "  ret %s %s", pair, emit_alloc_result(e, result, "false", built))
	fmt.sbprintln(&e.b, "}")
}

// design.md "Uninitialized capacity": `@(initialized = count)` makes only the
// first `count` elements of a fixed array field values; the capacity behind
// them is never read as one.
@(private = "file")
record_prefix_part :: proc(
	e: ^Emitter, record: Type_Id, index: int,
) -> (field: ^Symbol, counter: ^Symbol, prefixed: bool) {
	info := underlying_info(e.c, record)
	if info == nil || info.kind != .Struct || index < 0 || index >= len(info.fields) {
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
emit_prefix_count :: proc(e: ^Emitter, record: Type_Id, base: string, counter: ^Symbol) -> string {
	address := element_address(e, record, base, int(counter.index))
	return widen_to_i64(e, load(e, llvm_type(e, counter.type), address), counter.type)
}

// Drops the live prefix, last element first.
@(private = "file")
emit_drop_prefix_elements :: proc(e: ^Emitter, element: Type_Id, items, count: string) {
	cursor := alloca(e, "i64")
	fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", count, cursor)
	head := new_label(e, "prefix.drop.head")
	body, done := new_label(e, "prefix.drop.body"), new_label(e, "prefix.drop.done")
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
	emit_drop_place(e, element, gep_at(e, llvm_type(e, element), items, index))
	branch(e, head)
	place_label(e, done)
}

@(private = "file")
emit_drop_prefix :: proc(e: ^Emitter, record: Type_Id, base: string, field, counter: ^Symbol) {
	element := underlying_info(e.c, field.type).element
	if !emit_lifecycle(e, element).managed {
		return
	}
	items := element_address(e, record, base, int(field.index))
	count := emit_prefix_count(e, record, base, counter)
	emit_drop_prefix_elements(e, element, items, count)
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
// full destination count is published first, so a later failure can clean
// every completed prefix sharing it; a failure inside this field drops exactly
// the progress the cursor holds.
@(private = "file")
emit_clone_prefix :: proc(
	e: ^Emitter,
	record: Type_Id,
	self, out: string,
	field, counter: ^Symbol,
	index: int,
	result: Type_Id,
	pair: string,
) {
	element := underlying_info(e.c, field.type).element
	element_llvm := llvm_type(e, element)
	source := element_address(e, record, self, int(field.index))
	destination := element_address(e, record, out, int(field.index))
	built := element_address(e, record, out, int(counter.index))
	total := emit_prefix_count(e, record, self, counter)
	fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", llvm_type(e, counter.type), total, built)

	cursor := alloca(e, "i64")
	fmt.sbprintfln(&e.b, "  store i64 0, ptr %s", cursor)
	head := new_label(e, "prefix.clone.head")
	body, done := new_label(e, "prefix.clone.body"), new_label(e, "prefix.clone.done")
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
		cloned = emit_clone_value(e, element, load(e, element_llvm, from), "%arg1")
	} else {
		value, failed := emit_part_clone(e, element, from)
		fail, ok := new_label(e, "prefix.clone.fail"), new_label(e, "prefix.clone.ok")
		branch_if(e, failed, fail, ok)
		place_label(e, fail)
		emit_drop_prefix_elements(e, element, destination, at)
		for earlier := index - 1; earlier >= 0; earlier -= 1 {
			emit_drop_record_part(e, record, out, earlier)
		}
		fmt.sbprintfln(&e.b, "  ret %s %s", pair, emit_alloc_result(e, result, "true"))
		e.terminated = true
		place_label(e, ok)
		cloned = value
	}
	store(e, element, cloned, into)
	next := temp(e)
	fmt.sbprintfln(&e.b, "  %s = add i64 %s, 1", next, at)
	fmt.sbprintfln(&e.b, "  store i64 %s, ptr %s", next, cursor)
	branch(e, head)
	place_label(e, done)
}

// The address of part `index`: a struct field or an array element.
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

// Clones one part through its own `try_clone`. Returns the value and the error
// flag; the caller publishes the value only on success.
@(private = "file")
emit_part_clone :: proc(e: ^Emitter, part: Type_Id, source: string) -> (string, string) {
	operations := emit_lifecycle(e, part)
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
		backend_fail(e, "a fallible clone part has no `try_clone` member")
		return "0", "true"
	}
	loaded := load(e, llvm_type(e, part), source)
	return emit_clone_call(e, hook, part, loaded, "%arg1")
}

// Drops every initialized element of a compiler-owned variadic buffer in
// reverse. Each flag is cleared before its hook runs, so a panic from that hook
// cannot replay the same element.
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

// `clone` calls `try_clone` once and applies the allocator's failure policy.
@(private)
emit_synth_clone :: proc(e: ^Emitter, symbol: ^Symbol, name: string) {
	function := begin_function_emission(e)
	defer finish_function_emission(e, function)
	subject := symbol.params[0]
	value_type := llvm_type(e, subject)
	open_function(
		e, "define %s%s %s(%s %%arg0, ptr %%arg1)",
		llvm_linkage(name), value_type, name, synth_param_llvm(e, symbol, 0),
	)
	e.terminated = false

	cloned := emit_clone_with_policy(e, subject, synth_receiver_value(e, symbol), "%arg1")
	fmt.sbprintfln(&e.b, "  ret %s %s", value_type, cloned)
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
	cloned, failed := emit_clone_call(e, hook, subject, value, allocator)
	fail, ok := new_label(e, "clone.failed"), new_label(e, "ok")
	branch_if(e, failed, fail, ok)
	place_label(e, fail)
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_alloc_failed(ptr %s)", allocator)
	fmt.sbprintln(&e.b, "  unreachable")
	e.terminated = true
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
// order (design.md).
emit_drop_place :: proc(e: ^Emitter, type: Type_Id, address: string) {
	operations := emit_lifecycle(e, type)
	if !operations.managed {
		return
	}
	// The container helper leaves the inert zero, and dropping zero is a no-op.
	if operations.container {
		helper := type_is_map(e.c, type) ? "loke_rt_v1_map_drop" : "loke_rt_v1_dyn_drop"
		fmt.sbprintfln(&e.b, "  call void @%s(ptr %s, ptr %s)", helper, address, container_ops_global(e, type))
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
		value := load(e, STRING_TYPE, address)
		owner := extract(e, STRING_TYPE, value, STRING_OWNER)
		fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_string_release(i64 %s)", owner)
		return
	}
	if hook := operations.custom_drop; hook != INVALID_SYMBOL {
		fmt.sbprintfln(&e.b, "  call void %s(ptr %s)", symbol_name(e, hook), address)
	}
	if info := underlying_info(e.c, type); info != nil && info.kind == .Union {
		emit_union_drop(e, type, info, address)
		return
	}
	for index := clone_part_count(e.c, type) - 1; index >= 0; index -= 1 {
		emit_drop_record_part(e, type, address, index)
	}
}

// Drops the active variant's payload only, then leaves the union inert so a
// second drop is a no-op.
@(private = "file")
emit_union_drop :: proc(e: ^Emitter, type: Type_Id, info: ^Type_Info, address: string) {
	shape := union_layout(e.c, type)
	value := load(e, llvm_type(e, type), address)
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
	fmt.sbprintfln(&e.b, "  store %s zeroinitializer, ptr %s", llvm_type(e, type), address)
}

// Each managed variant clones its one payload and rebuilds the union; there is
// no partial result to unwind.
@(private = "file")
emit_union_try_clone_body :: proc(
	e: ^Emitter, subject: Type_Id, info: ^Type_Info, result: Type_Id, pair, value_type: string,
	subject_value: string,
) {
	shape := union_layout(e.c, subject)
	self := alloca(e, value_type)
	fmt.sbprintfln(&e.b, "  store %s %s, ptr %s", value_type, subject_value, self)
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
		if !emit_lifecycle(e, variant).clone_fallible {
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
	fmt.sbprintfln(&e.b, "  ret %s %s", pair, emit_alloc_result(e, result, "false", subject_value))
	fmt.sbprintln(&e.b, "}")
}

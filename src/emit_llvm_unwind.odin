// Panic replay: a procedure's runtime-visible registration, and the generated
// thunk that runs what is still registered.
//
// Part of the textual LLVM backend; see compiler-architecture.md.
package lokec

import "core:fmt"
import "core:strings"

@(private)
Unwind_Env_Binding :: struct {
	symbol: Symbol_Id,
	index:  int,
	// Whether the thunk reads it. One it does not is never stored.
	read: bool,
}

// A line of a procedure's body that may turn out unneeded: the env store of the
// binding at index `binding` in `env_bindings`, or a frame pop when `binding` is
// negative. Offsets are into the body's builder, which only grows.
@(private)
Unwind_Body_Line :: struct {
	start, end, binding: int,
}

// One procedure's runtime-visible cleanup registration. A panic never unwinds
// the native stack: the runtime calls each live frame's generated thunk, which
// reads which actions are registered (`live`) and where their storage is (`env`).
@(private)
Unwind_State :: struct {
	live:  string, // `[n x i1]`: action `i` is registered right now
	env:   string, // `[n x ptr]`: the storage each replayed action addresses
	frame: string, // the `{previous, cleanup, context}` record this frame pushes
	ctx:   string, // `[2 x ptr]` = {live, env}, the thunk's one argument
	thunk: string,
	// Every action in source order, so descending-index replay is reverse
	// registration order.
	actions:      [dynamic]Deferred,
	// Each published local's index in `env_bindings`.
	binding_of:   map[Symbol_Id]int,
	env_bindings: [dynamic]Unwind_Env_Binding,
	env_count:    int,
	// In the order they were written.
	body_lines:   [dynamic]Unwind_Body_Line,
	// Registration slots (`Deferred.slot`), so `move`/`drop` and a re-entered
	// scope can clear them.
	slot_by_symbol: map[Symbol_Id]int,
	slot_by_defer:  map[int]int,
	// True while the thunk is emitted, so replayed code registers nothing.
	replaying: bool,
}

// Under `-panic=abort` nothing is registered and no thunk is generated.
@(private)
unwind_enabled :: proc(e: ^Emitter) -> bool {
	return e.c.panic_unwind && !e.unwind.replaying && e.unwind.frame != ""
}

// Fresh registration state for one procedure. The names are chosen up front
// because the array sizes are only known once the body is emitted.
@(private)
begin_unwind_frame :: proc(e: ^Emitter, llvm_name: string) {
	e.unwind = Unwind_State {
		actions        = make([dynamic]Deferred),
		binding_of     = make(map[Symbol_Id]int),
		env_bindings   = make([dynamic]Unwind_Env_Binding),
		body_lines     = make([dynamic]Unwind_Body_Line),
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
	if !unwind_enabled(e) {
		return
	}
	entry.slot = len(e.unwind.actions) + 1
	append(&e.unwind.actions, entry^)
}

@(private)
unwind_reserve_env :: proc(e: ^Emitter) -> int {
	index := e.unwind.env_count
	e.unwind.env_count += 1
	return index
}

@(private)
unwind_publish_env :: proc(e: ^Emitter, index: int, address: string) {
	fmt.sbprintfln(&e.b, "  store ptr %s, ptr %s", address, unwind_env_address(e, index))
}

// Records the line written to the body since `start` as one the thunk may turn
// out not to need.
@(private = "file")
unwind_note_body_line :: proc(e: ^Emitter, start, binding: int) {
	append(&e.unwind.body_lines, Unwind_Body_Line{start, len(e.b.buf), binding})
}

// Names a local and publishes its address into the env for the thunk. Which
// locals the thunk reads is known only once it is written, after the body, so
// every one is stored here through its slot's name, and `unwind_finished_body`
// then removes the stores of those it does not read, which are all of them when
// nothing is registered. The prologue defines the names of those it does.
@(private)
bind_local :: proc(e: ^Emitter, symbol_id: Symbol_Id, name: string) {
	e.names[symbol_id] = name
	debug_mark_variable(e, symbol_id, name)
	if symbol_id == INVALID_SYMBOL || !unwind_enabled(e) {
		return
	}
	u := &e.unwind
	binding, found := u.binding_of[symbol_id]
	if !found {
		binding = len(u.env_bindings)
		u.binding_of[symbol_id] = binding
		append(&u.env_bindings, Unwind_Env_Binding{symbol = symbol_id, index = unwind_reserve_env(e)})
	}
	start := len(e.b.buf)
	fmt.sbprintfln(&e.b, "  store ptr %s, ptr %s.%d", name, u.env, u.env_bindings[binding].index)
	unwind_note_body_line(e, start, binding)
}

// The body, without the lines noted by `unwind_note_body_line` that the finished
// thunk left unneeded.
@(private)
unwind_finished_body :: proc(e: ^Emitter) -> string {
	u := &e.unwind
	body := strings.to_string(e.b)
	if len(u.body_lines) == 0 {
		return body
	}
	stripped := strings.builder_make(0, len(body))
	kept := 0
	for line in u.body_lines {
		if line.binding < 0 ? len(u.actions) != 0 : u.env_bindings[line.binding].read {
			continue
		}
		strings.write_string(&stripped, body[kept:line.start])
		kept = line.end
	}
	strings.write_string(&stripped, body[kept:])
	return strings.to_string(stripped)
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

// Marks an action registered, only once it is *fully* registered
// (design.md "What the unwind runs, and what it does not").
@(private)
unwind_register :: proc(e: ^Emitter, entry: Deferred) {
	if entry.slot == 0 || !unwind_enabled(e) {
		return
	}
	fmt.sbprintfln(&e.b, "  store i1 true, ptr %s", unwind_live_address(e, entry.slot - 1))
}

// Clears a registration before the action's own code runs, so a panic raised
// by a cleanup cannot ask for it again. It also runs inside the thunk, where
// `e.unwind.live` names the thunk's own view of the array, so a replayed
// `drop(x)` stops x's implicit drop from replaying too.
@(private)
unwind_clear :: proc(e: ^Emitter, slot: int) {
	if slot == 0 {
		return
	}
	fmt.sbprintfln(&e.b, "  store i1 false, ptr %s", unwind_live_address(e, slot - 1))
}

// The frame prologue, written once the body and the thunk are emitted and the
// array lengths and the locals the thunk reads are known.
@(private)
emit_unwind_prologue :: proc(e: ^Emitter) {
	u := &e.unwind
	if len(u.actions) == 0 {
		return
	}
	// `{` is a directive to core:fmt, so the record type is written literally;
	// the push fills in all of it.
	alloca_named(e, u.frame, "{ ptr, ptr, ptr }")
	alloca_named(e, u.live, fmt.aprintf("[%d x i1]", len(u.actions)))
	fmt.sbprintfln(
		&e.b, "  call void @llvm.memset.p0.i64(ptr %s, i8 0, i64 %d, i1 false)",
		u.live, len(u.actions),
	)
	alloca_named(e, u.env, fmt.aprintf("[%d x ptr]", max(u.env_count, 1)))
	for binding in u.env_bindings {
		if binding.read {
			fmt.sbprintfln(
				&e.b, "  %s.%d = getelementptr ptr, ptr %s, i64 %d", u.env, binding.index, u.env, binding.index,
			)
		}
	}
	alloca_named(e, u.ctx, "[2 x ptr]")
	fmt.sbprintfln(&e.b, "  store ptr %s, ptr %s", u.live, u.ctx)
	slot := temp(e)
	fmt.sbprintfln(&e.b, "  %s = getelementptr ptr, ptr %s, i64 1", slot, u.ctx)
	fmt.sbprintfln(&e.b, "  store ptr %s, ptr %s", u.env, slot)
	fmt.sbprintfln(
		&e.b, "  call void @loke_rt_v1_frame_push(ptr %s, ptr %s, ptr %s)",
		u.frame, u.thunk, u.ctx,
	)
}

// A procedure that registers nothing pushes nothing, so `unwind_finished_body`
// removes this pop: a call into the runtime is one the optimizer cannot remove,
// and every return would pay for it.
@(private)
emit_unwind_pop :: proc(e: ^Emitter) {
	if !unwind_enabled(e) {
		return
	}
	start := len(e.b.buf)
	fmt.sbprintfln(&e.b, "  call void @loke_rt_v1_frame_pop(ptr %s)", e.unwind.frame)
	unwind_note_body_line(e, start, -1)
}

// design.md "What the unwind runs, and what it does not": a generated body that
// holds owners registers them as a procedure does, and a procedure's starts here
// too. It starts the frame while still in its entry block; what it emits next is
// written aside, since the prologue depends on all of it. `emit_ret` pops the
// frame.
@(private)
begin_generated_frame :: proc(e: ^Emitter, name: string) -> strings.Builder {
	begin_unwind_frame(e, name)
	header := e.b
	e.b = strings.builder_make()
	return header
}

// Called once the body's closing brace is written.
@(private)
end_generated_frame :: proc(e: ^Emitter, header: strings.Builder) {
	// The thunk first: the locals it reads are the ones the body publishes.
	emit_unwind_thunk(e)
	body := unwind_finished_body(e)
	e.b = header
	emit_unwind_prologue(e)
	strings.write_string(&e.b, body)
}

// The generated thunk: replay every still-registered action of one frame,
// newest first. LLVM functions do not nest, so it waits for the end of the module.
@(private)
emit_unwind_thunk :: proc(e: ^Emitter) {
	u := &e.unwind
	if len(u.actions) == 0 {
		return
	}
	// Keeps the parent's function state, whose actions it replays, but starts its
	// output empty. Runs after the parent's body and before its prologue.
	parent, parent_body := e.fn, e.b
	e.b = strings.builder_make()
	e.terminated = false
	e.cleanups = make([dynamic][dynamic]Deferred)
	e.temporaries = make([dynamic][dynamic]Deferred)
	e.prologue = nil
	e.large_taken, e.large_marks, e.large_free = nil, nil, nil
	e.stack_saves = nil
	u.replaying = true

	open_function(e, "define private void %s(ptr %%ctx)%s", u.thunk, copy_attributes(e))
	u.live = load(e, "ptr", "%ctx")
	env := unwind_env_load(e, "%ctx", 1)

	// Rebind every published local to the value its address will be loaded into
	// from the env. The loads are written once the replay is, and only for the
	// locals it names.
	loads_at := len(e.b.buf)
	values := make([dynamic]string, 0, len(u.env_bindings), context.temp_allocator)
	for binding in u.env_bindings {
		value := temp(e)
		append(&values, value)
		e.names[binding.symbol] = value
	}

	// The `%deferN` flags are parent allocas the thunk cannot reach. Each gets a
	// local stand-in seeded `true`: an action only runs where its live byte
	// already says so.
	e.defer_flags = make([]string, len(parent.defer_flags))
	for index in 0 ..< len(parent.defer_flags) {
		flag := fmt.aprintf("%%udefer%d.%d", index, next_id(e))
		alloca_named(e, flag, "i1")
		fmt.sbprintfln(&e.b, "  store i1 true, ptr %s", flag)
		e.defer_flags[index] = flag
	}

	for index := len(u.actions) - 1; index >= 0; index -= 1 {
		address := unwind_live_address(e, index)
		flag := load(e, "i1", address)
		run, skip := new_label(e, "unwind.run"), new_label(e, "unwind.skip")
		branch_if(e, flag, run, skip)
		place_label(e, run)
		fmt.sbprintfln(&e.b, "  store i1 false, ptr %s", address)
		emit_replay_action(e, u.actions[index], env)
		branch(e, skip)
		place_label(e, skip)
	}
	fmt.sbprintln(&e.b, "  ret void")
	fmt.sbprintln(&e.b, "}")
	fmt.sbprintln(&e.b, "")

	replay := strings.to_string(e.b)
	mark_replay_reads(u, replay[loads_at:], values[:])
	loads := strings.builder_make()
	// A local the replay binds again, as one declared in a deferred block, has
	// a name of the replay's own by now, so the values are the ones chosen above.
	for binding, index in u.env_bindings {
		if binding.read {
			address := temp(e)
			fmt.sbprintfln(&loads, "  %s = getelementptr ptr, ptr %s, i64 %d", address, env, binding.index)
			fmt.sbprintfln(&loads, "  %s = load ptr, ptr %s", values[index], address)
		}
	}
	text := strings.concatenate({replay[:loads_at], strings.to_string(loads), replay[loads_at:]})

	append(&e.pending_thunks, splice_prologue(e, text, e.prologue[:]))
	e.fn, e.b = parent, parent_body
}

// What the thunk runs for one registered action. `env` is its view of the env.
@(private = "file")
emit_replay_action :: proc(e: ^Emitter, entry: Deferred, env: string) {
	switch entry.kind {
	case .Array:
		buffer := unwind_env_load(e, env, entry.array_buffer_env)
		count := load(e, "i64", unwind_env_load(e, env, entry.array_count_env))
		if entry.array_counted != INVALID_TYPE {
			emit_prefix_count_check(e, count, entry.array_counted)
		}
		flags := entry.array_flags == "" ? "" : unwind_env_load(e, env, entry.array_flags_env)
		emit_drop_elements_reversed(e, entry.type, buffer, count, flags)
	case .Written:
		push_temporaries(e)
		emit_stmt(e, entry.stmt)
		pop_temporaries(e)
	case .Box_Release:
		emit_box_release(e, entry.type, unwind_env_load(e, env, entry.place_env))
	case .Frame_Release:
		emit_frame_release(e, entry.type, unwind_env_load(e, env, entry.place_env))
	case .Temporary:
		emit_drop_place(e, entry.type, unwind_env_load(e, env, entry.place_env))
	case .Local:
		if place, bound := e.names[entry.place_symbol]; bound {
			emit_drop_place(e, entry.type, place)
		}
	}
}

// Mark the locals the replay's text names.
@(private = "file")
mark_replay_reads :: proc(u: ^Unwind_State, replay: string, values: []string) {
	reads := make(map[string]int, len(values), context.temp_allocator)
	for value, index in values {
		reads[value] = index
	}
	for at := 0; at < len(replay); {
		found := strings.index_byte(replay[at:], '%')
		if found < 0 {
			break
		}
		start := at + found
		end := start + 1
		for end < len(replay) && llvm_name_char(replay[end]) {
			end += 1
		}
		if index, bound := reads[replay[start:end]]; bound {
			u.env_bindings[index].read = true
		}
		at = end
	}
}

// A character that continues an LLVM local name after its `%`.
@(private = "file")
llvm_name_char :: proc(c: u8) -> bool {
	switch c {
	case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '.', '_', '-', '$':
		return true
	}
	return false
}

// `parallel` blocks and `spawn` statements (design.md "Structured
// concurrency").
//
// Checked as ordinary code: a block gains a hidden `Task_Scope` local, and a
// spawn a frame record and `run` procedure (compiler-architecture.md "Lowering
// parallel blocks").
package lokec

import "core:fmt"

// How one argument reaches the task, which decides its frame field.
Spawn_Field_Kind :: enum u8 {
	// Copied into the task: a `value: T` argument whose type copies without a
	// hook or an allocation, or a widened place's widened form, whose payload
	// stays lent. Only what the value borrows lasts to the join.
	Copy,
	// A temporary or moved value the task owns, or its copy of a place in a
	// temporary; the worker drops what its call does not consume.
	Owned,
	// The address of the parent's place, which stays lent to the task until the
	// join: an `inout` or `self: ^` argument, or a managed `value: T` one.
	Address,
}

// What checking a spawn records for later phases.
Spawn_Task :: struct {
	// The frame: a leading `rawptr` slot `Task_Scope.start` fills with `run`,
	// one field per bound argument in parameter order, then the result's
	// address when there is one, then the procedure value a call through one
	// calls.
	frame:  Type_Id,
	run:    Symbol_Id,
	// The callee is a value the frame holds, not a procedure `run` names.
	through_value: bool,
	// The enclosing block's hidden `Task_Scope` local, and its `start`.
	scope:  Symbol_Id,
	start:  Symbol_Id,
	kinds:  []Spawn_Field_Kind,
	result: Symbol_Id, // INVALID_SYMBOL for a bare spawn
	// A call with a variadic pack: its slot's field is a record holding each
	// element and spread in `variadic_order`, with how each reaches the task.
	pack:   []Spawn_Field_Kind,
	// The block runs on a pool, so a worker of it joining the block may run
	// the task on the joining thread (design.md "Parallel blocks").
	pooled: bool,
	// The spawned call and the procedure it is in, where the effects resolve
	// what `run`'s own call of it passes (`Compiler.spawn_calls`).
	call:   ^Expr_Call,
	parent: Symbol_Id,
}

// The frame field holding bound argument `index`, and the result's address.
spawn_argument_field :: proc(index: int) -> int {
	return index + 1
}

spawn_result_field :: proc(task: ^Spawn_Task) -> int {
	return len(task.kinds) + 1
}

spawn_callee_field :: proc(task: ^Spawn_Task) -> int {
	return len(task.kinds) + (task.result != INVALID_SYMBOL ? 2 : 1)
}

// compiler-architecture.md "Lowering parallel blocks".
spawn_frame_field_count :: proc(task: ^Spawn_Task) -> int {
	return spawn_callee_field(task) + (task.through_value ? 1 : 0)
}

// How diagnostics name what a spawn starts: the procedure or method, the
// procedure value or `dyn` call as written, or a literal called in place by
// its signature.
spawn_callee_name :: proc(c: ^Compiler, call: ^Expr_Call) -> string {
	if sym := symbol_of(c, call.resolution.symbol); sym != nil && sym.kind == .Proc && sym.synth == .None {
		return identifier_text(c, sym.name)
	}
	span := expr_span(call.callee)
	if literal, is_literal := call.callee.(^Expr_Proc); is_literal && literal.signature != nil {
		span = literal.signature.span
	}
	return span_text(c, span)
}

// The names the synthesized code binds in scopes of its own. None can be
// written, so none collides with the source.
@(private = "file")
PARALLEL_SCOPE :: "parallel$scope"
@(private = "file")
PARALLEL_POOL :: "parallel$pool"
@(private = "file")
SPAWN_FRAME :: "spawn$frame"

check_parallel :: proc(k: ^Checker, s: ^Stmt_Parallel) -> Flow_Info {
	outer_block := k.parallel_block
	defer k.parallel_block = outer_block
	// The window checks read the thread summaries (design.md "Globals while
	// tasks run").
	k.c.thread_summaries_wanted = true
	scope_type := thread_type(k, s.keyword, "Task_Scope")
	pool_type := INVALID_TYPE
	if s.executor != nil && scope_type != INVALID_TYPE {
		pool_type = thread_type(k, s.keyword, "Pool")
	}
	if scope_type == INVALID_TYPE || (s.executor != nil && pool_type == INVALID_TYPE) {
		if s.executor != nil {
			check_expr(k, s.executor)
		}
		k.parallel_block = s
		return check_scoped_block(k, s.body)
	}

	outer := k.scope
	k.scope = new_scope(k.c, outer, .Local)
	defer k.scope = outer
	hidden := make([dynamic]Stmt, 0, 3, k.c.semantic_allocator)
	// design.md "Parallel blocks": the executor is evaluated once, on entry,
	// and the scope borrows it until the join.
	pool: ^Decl
	if s.executor != nil {
		pool = hidden_pool_declaration(k, s, pool_type)
		errors := k.c.error_count
		check_local_declaration(k, pool)
		if k.c.error_count != errors {
			add_notef(k.c, expr_span(s.executor), "a `parallel` block's executor is a `^thread.Pool`, such as `&pool`")
		}
		append(&hidden, pool)
	}
	scope := hidden_scope_declaration(k, s, scope_type, pool)
	check_local_declaration(k, scope)
	append(&hidden, scope)
	if len(scope.symbols) == 1 {
		s.scope = scope.symbols[0]
	}
	k.parallel_block = s
	if committing(k.c) {
		s.spawns = make([dynamic]^Stmt_Spawn, 0, 2, k.c.semantic_allocator)
	}
	flow := check_scoped_block(k, s.body)

	lowered := new(Block, k.c.semantic_allocator)
	lowered.span = s.span
	append(&hidden, s.body)
	lowered.stmts = hidden[:]
	s.lowered = lowered
	return flow
}

// `parallel$pool: ^Pool = executor;`, so an executor of another type is
// reported as the initializer it is.
@(private = "file")
hidden_pool_declaration :: proc(k: ^Checker, s: ^Stmt_Parallel, pool_type: Type_Id) -> ^Decl {
	span := expr_span(s.executor)
	alias := intern_identifier(k.c, "parallel$pool$type")
	k.scope.names[alias] = new_associated_type(k.c, "Pool", pool_type, INVALID_TYPE)
	pointer := new(Type_Pointer, k.c.semantic_allocator)
	pointer.span = span
	pointer.elem = synth_ident_as(k.c, "Pool", alias, span)
	return synth_decl(k.c, .Var, PARALLEL_POOL, s.executor, span, pointer)
}

// `parallel$scope: Task_Scope = {};`, or `Task_Scope.pooled(parallel$pool)`
// after an executor, its type bound to a name only the block's own scope has.
@(private = "file")
hidden_scope_declaration :: proc(k: ^Checker, s: ^Stmt_Parallel, scope_type: Type_Id, pool: ^Decl) -> ^Decl {
	span := s.keyword
	alias := intern_identifier(k.c, "parallel$scope$type")
	k.scope.names[alias] = new_associated_type(k.c, "Task_Scope", scope_type, INVALID_TYPE)
	type := synth_ident_as(k.c, "Task_Scope", alias, span)
	value: Expr
	if pool != nil {
		pooled := synth_selector(k.c, synth_ident_as(k.c, "Task_Scope", alias, span), "pooled", span)
		executor := synth_ident(k.c, PARALLEL_POOL, span)
		value = synth_call(k.c, pooled, {executor}, span)
	} else {
		composite := new(Expr_Composite, k.c.semantic_allocator)
		composite.span = span
		value = composite
	}
	return synth_decl(k.c, .Var, PARALLEL_SCOPE, value, span, type)
}

// A type `core:thread` declares for `parallel` blocks: `Task_Scope`, or
// `Pool` for an executor. Import discovery loaded the package for a program
// with a block where a collection provides it.
@(private = "file")
thread_type :: proc(k: ^Checker, keyword: Span, name: string) -> Type_Id {
	pkg := standard_package(k.c, STD_THREAD)
	if pkg == nil {
		errorf(k.c, keyword, "L0329", "a `parallel` block needs `%s`, which no collection provides", STD_THREAD)
		return INVALID_TYPE
	}
	sym := symbol_of(k.c, package_symbol_named(k.c, pkg, name))
	if sym == nil || sym.kind != .Type || sym.type == INVALID_TYPE {
		errorf(k.c, keyword, "L0727", "`%s` declares no `%s`, which a `parallel` block needs", STD_THREAD, name)
		return INVALID_TYPE
	}
	return sym.type
}

check_spawn :: proc(k: ^Checker, s: ^Stmt_Spawn) -> Flow_Info {
	block := k.parallel_block
	if block == nil {
		errorf(k.c, s.keyword, "L0727", "`spawn` belongs inside a `parallel` block of the same procedure")
	} else if k.in_defer {
		// design.md "Spawn statements": a deferred spawn would start a task
		// during cleanup, possibly while unwinding.
		errorf(k.c, s.keyword, "L0727", "a deferred statement cannot `spawn`")
	}
	call, is_call := s.call.(^Expr_Call)
	if !is_call {
		return FLOWS
	}
	result_type := INVALID_TYPE
	if s.result != nil {
		if capture_place_of(k, s.result) != nil {
			errorf(
				k.c, s.result.span, "L0728",
				"a task's result goes to a local variable declared before the `parallel` block, and `%s` is a capture",
				s.result.name,
			)
		} else {
			result_type = check_expr(k, s.result, position = .Place)
		}
	}
	type := check_expr(k, call)
	if s.result == nil {
		report_discarded_required_results(k, call)
	}
	if block == nil || k.in_defer || block.scope == INVALID_SYMBOL ||
	   type == INVALID_TYPE || (s.result != nil && result_type == INVALID_TYPE) {
		return FLOWS
	}
	proc_type, callee_ok := spawned_callee(k, call)
	result, result_ok := spawn_result_symbol(k, s.result, call, block, type)
	if !callee_ok || !result_ok {
		return FLOWS
	}
	lower_spawn(k, s, block, proc_type, result)
	return FLOWS
}

// design.md "Spawn statements": the spawned call is a procedure or method
// declared in Loke, including a generic instance, a procedure value, or a
// `dyn` method or callable view, whose view is the receiver argument. Answers
// the procedure type the call goes through.
@(private = "file")
spawned_callee :: proc(k: ^Checker, call: ^Expr_Call) -> (Type_Id, bool) {
	c := k.c
	_, slot := call.operation.(Call_Dyn_Slot)
	if !call_through_value(c, call) && !slot {
		_, procedure := call.operation.(Call_Procedure)
		sym := symbol_of(c, call.resolution.symbol)
		if !procedure || call.dispatch != nil || sym == nil || sym.kind != .Proc ||
		   (sym.synth != .None && sym.synth != .Dyn_Forward) || sym.delegated {
			errorf(
				c, expr_span(call.callee), "L0728",
				"`spawn` starts a procedure, a method, a procedure value, or a call through a `dyn` view; a built-in or a conversion cannot be spawned yet",
			)
			return INVALID_TYPE, false
		}
	}
	proc_type := call_proc_type(c, call)
	info := underlying_info(c, proc_type)
	if info == nil {
		return INVALID_TYPE, false
	}
	if convention_is_foreign(info.convention) {
		errorf(c, expr_span(call.callee), "L0728", "`spawn` starts a Loke procedure; call a foreign one from a Loke procedure the task runs")
		return INVALID_TYPE, false
	}
	if info.result_inout {
		errorf(c, call.span, "L0728", "a task cannot hand back an `inout` result, which is a place of the worker's call")
		return INVALID_TYPE, false
	}
	return proc_type, true
}

// design.md "Spawn statements": `result` names a lexical local declared
// outside the block, of exactly the call's one result type.
@(private = "file")
spawn_result_symbol :: proc(k: ^Checker, result: ^Expr_Ident, call: ^Expr_Call, block: ^Stmt_Parallel, type: Type_Id) -> (Symbol_Id, bool) {
	c := k.c
	if result == nil {
		return INVALID_SYMBOL, true
	}
	id := result.symbol
	sym := symbol_of(c, id)
	if sym == nil {
		return INVALID_SYMBOL, false
	}
	inside := sym.span.file == block.span.file && sym.span.lo >= block.span.lo && sym.span.hi <= block.span.hi
	if sym.kind != .Var || symbol_outlives_bodies(sym) || sym.borrowed_binding != .None || inside {
		errorf(
			c, result.span, "L0728",
			"a task's result goes to a local variable declared before the `parallel` block, and `%s` is not one",
			result.name,
		)
		if inside {
			add_notef(c, sym.span, "declared inside the block, so it ends before the join")
		}
		return INVALID_SYMBOL, false
	}
	if type == TYPE_VOID {
		errorf(c, call.span, "L0728", "this call has no result to assign to `%s`", result.name)
		return INVALID_SYMBOL, false
	}
	if info := type_of(c, type); info != nil && info.anonymous_record {
		errorf(
			c, call.span, "L0728",
			"this call has several results, so a task has nowhere to put them; return one record from the procedure the task runs",
		)
		return INVALID_SYMBOL, false
	}
	if type != sym.type {
		errorf(
			c, call.span, "L0728",
			"this call returns `%s`, and `%s` is a `%s`; the worker assigns the result without converting it",
			type_name(c, type), result.name, type_name(c, sym.type),
		)
		return INVALID_SYMBOL, false
	}
	return id, true
}

// The frame record and `run` procedure for one spawn, declared in a scope of
// their own: `run` takes every argument out of the frame and makes the call.
//
//     spawn$type$frame :: struct { run: rawptr, arg0: ..., arg1: ..., result: ^mut R, callee: ... }
//     spawn$run :: proc(spawn$frame: ^mut spawn$type$frame) {
//         spawn$owned$1 := unsafe.take(spawn$frame.arg1);
//         unsafe.write(spawn$frame.result^, callee(spawn$frame.arg0^, move(spawn$owned$1)));
//         unsafe.free(spawn$frame);
//     }
//
// design.md "Spawn statements": a variadic pack's slot holds a record of its
// operands, `spawn$pack :: struct { p0: T, p1: []T }`, and `run` packs them
// again: `callee(..., move(spawn$pack$owned$0), ..spawn$frame.arg2.p1)`.
@(private = "file")
lower_spawn :: proc(k: ^Checker, s: ^Stmt_Spawn, block: ^Stmt_Parallel, proc_type: Type_Id, result: Symbol_Id) {
	c := k.c
	call := s.call.(^Expr_Call)
	span := call.span

	scope_info := type_of(c, symbol_of(c, block.scope).type)
	start := scope_info != nil ? member_named(c, scope_info.members, intern_identifier(c, "start")) : INVALID_SYMBOL
	if start == INVALID_SYMBOL {
		errorf(c, span, "L0727", "`%s` declares no `Task_Scope.start`, which a `spawn` needs", STD_THREAD)
		return
	}

	outer := k.scope
	k.scope = new_scope(c, outer, .Local)
	defer k.scope = outer
	if !bind_unsafe_builtins(k, span) {
		return
	}

	task := new(Spawn_Task, c.semantic_allocator)
	task.scope = block.scope
	task.start = start
	task.pooled = block.executor != nil
	task.result = result
	task.through_value = call_through_value(c, call)
	task.call = call
	if k.proc_literal != nil {
		task.parent = k.proc_literal.symbol
	}

	layout: Spawn_Layout
	if !spawn_lay_out_arguments(k, task, proc_type, &layout) {
		return
	}
	if result != INVALID_SYMBOL {
		spawn_add_field(&layout, "result", pointer_to(c, symbol_of(c, result).type, true))
	}
	// design.md "Spawn statements": the task's own copy of a procedure value.
	if task.through_value {
		spawn_add_field(&layout, "callee", proc_type)
	}
	task.frame = synth_record(k, "spawn$type$frame", "spawn$type", layout.field_names[:], layout.field_types[:], span)
	if task.frame == INVALID_TYPE {
		return
	}

	inner := spawn_make_call(k, task, &layout)
	run_decl := synth_decl(c, .Const, "spawn$run", spawn_run_literal(k, task, layout.stmts[:]), span)
	errors := c.error_count
	check_local_declaration(k, run_decl)
	if c.error_count != errors || len(run_decl.symbols) != 1 {
		return
	}
	task.run = run_decl.symbols[0]
	if committing(c) {
		s.task = task
		append(&c.spawn_tasks, task)
		append(&block.spawns, s)
		c.spawn_calls[inner] = task
	}
}

// What the one walk over a spawn's arguments builds: the frame's fields in
// layout order, and `run`'s statements and the arguments of the call it makes.
@(private = "file")
Spawn_Layout :: struct {
	field_names: [dynamic]string,
	field_types: [dynamic]Type_Id,
	stmts:       [dynamic]Stmt,
	args:        [dynamic]Argument,
}

@(private = "file")
spawn_add_field :: proc(layout: ^Spawn_Layout, name: string, type: Type_Id) {
	append(&layout.field_names, name)
	append(&layout.field_types, type)
}

// The leading `run` slot and each bound argument's field, with what `run` does
// to pass that argument on.
@(private = "file")
spawn_lay_out_arguments :: proc(k: ^Checker, task: ^Spawn_Task, proc_type: Type_Id, layout: ^Spawn_Layout) -> bool {
	c := k.c
	call := task.call
	span := call.span
	parameters := underlying_info(c, proc_type).parameters
	task.kinds = make([]Spawn_Field_Kind, len(call.bound), c.semantic_allocator)
	layout.field_names = make([dynamic]string, 0, len(call.bound) + 3, c.semantic_allocator)
	layout.field_types = make([dynamic]Type_Id, 0, len(call.bound) + 3, c.semantic_allocator)
	layout.stmts = make([dynamic]Stmt, 0, len(call.bound) + 2, c.semantic_allocator)
	layout.args = make([dynamic]Argument, 0, len(call.bound) + len(call.variadic_order), c.semantic_allocator)
	spawn_add_field(layout, "run", TYPE_RAWPTR)
	for argument, index in call.bound {
		type := parameters[index]
		mode := proc_parameter_mode(c, proc_type, index)
		name := fmt.aprintf("arg%d", index, allocator = c.semantic_allocator)
		field := frame_select(c, name, span)
		kind := spawn_field_kind(k, argument, type, mode)
		field_type := kind == .Address ? pointer_to(c, type, mode == .Inout) : type
		switch {
		case call_packs(call, index):
			kind = .Owned
			field_type = spawn_pack_record(k, task, call, type, span)
			if field_type == INVALID_TYPE {
				return false
			}
			spawn_repack(k, task, call, field, layout, span)
		case mode == .Variadic:
			// A lone spread forwards the slice it views, as at any call.
			append(&layout.args, Argument{span = span, mode = .Spread, value = field})
		case kind == .Copy:
			append(&layout.args, Argument{span = span, value = field})
		case kind == .Address:
			append(&layout.args, Argument{span = span, mode = mode == .Inout ? .Inout : .Value, value = synth_deref(c, field, span)})
		case:
			local := fmt.aprintf("spawn$owned$%d", index, allocator = c.semantic_allocator)
			value := spawn_take_local(c, &layout.stmts, local, field, span)
			append(&layout.args, Argument{span = span, value = mode == .Move ? synth_move(c, value, span) : value})
		}
		task.kinds[index] = kind
		spawn_add_field(layout, name, field_type)
	}
	return true
}

// Ends `run`'s statements: the call, its result written through the frame, and
// the frame freed. Answers the call, which the effects resolve through
// `Compiler.spawn_calls`.
@(private = "file")
spawn_make_call :: proc(k: ^Checker, task: ^Spawn_Task, layout: ^Spawn_Layout) -> ^Expr_Call {
	c := k.c
	call := task.call
	span := call.span
	inner := new(Expr_Call, c.semantic_allocator)
	inner.span = span
	inner.args = layout.args[:]
	if task.through_value {
		inner.callee = frame_select(c, "callee", span)
	} else if _, slot := call.operation.(Call_Dyn_Slot); slot {
		// The view is the receiver argument, which the slot is selected on.
		inner.callee = synth_selector(c, layout.args[0].value, call.callee.(^Expr_Selector).name.text, span)
		inner.args = layout.args[1:]
	} else {
		callee_alias := intern_identifier(c, "spawn$callee")
		k.scope.names[callee_alias] = call.resolution.symbol
		inner.callee = synth_ident_as(c, "spawn$callee", callee_alias, span)
	}
	made: Expr = inner
	if task.result != INVALID_SYMBOL {
		made = spawn_builtin_call(c, "spawn$write", {synth_deref(c, frame_select(c, "result", span), span), inner}, span)
	}
	append(&layout.stmts, synth_expr_stmt(c, made, span))
	freed := spawn_builtin_call(c, "spawn$free", {synth_ident(c, SPAWN_FRAME, span)}, span)
	append(&layout.stmts, synth_expr_stmt(c, freed, span))
	return inner
}

// `proc(spawn$frame: ^mut <frame>) { stmts }`, its type spelled as one more alias.
@(private = "file")
spawn_run_literal :: proc(k: ^Checker, task: ^Spawn_Task, stmts: []Stmt) -> ^Expr_Proc {
	c := k.c
	span := task.call.span
	frame_pointer := intern_identifier(c, "spawn$frame$pointer")
	k.scope.names[frame_pointer] = new_associated_type(c, SPAWN_FRAME, pointer_to(c, task.frame, true), INVALID_TYPE)
	param_names := make([]Param_Name, 1, c.semantic_allocator)
	param_names[0] = Param_Name{name = synth_name(c, SPAWN_FRAME, span)}
	params := make([]Parameter, 1, c.semantic_allocator)
	params[0] = Parameter{span = span, names = param_names, mode = .Value, type = synth_ident_as(c, SPAWN_FRAME, frame_pointer, span)}
	signature := new(Type_Proc, c.semantic_allocator)
	signature.span = span
	signature.params = params
	body := new(Block, c.semantic_allocator)
	body.span = span
	body.stmts = stmts
	literal := new(Expr_Proc, c.semantic_allocator)
	literal.span = span
	literal.signature = signature
	literal.body = body
	return literal
}

// design.md "Spawn statements": the record holding a pack's operands until the
// worker packs them again.
@(private = "file")
spawn_pack_record :: proc(k: ^Checker, task: ^Spawn_Task, call: ^Expr_Call, pack: Type_Id, span: Span) -> Type_Id {
	c := k.c
	element := slice_element(c, pack)
	task.pack = make([]Spawn_Field_Kind, len(call.variadic_order), c.semantic_allocator)
	types := make([]Type_Id, len(call.variadic_order), c.semantic_allocator)
	names := make([]string, len(call.variadic_order), c.semantic_allocator)
	cursor: Call_Pack_Cursor
	for operand, is_spread in call_pack_next(call, &cursor) {
		index := cursor.taken - 1
		names[index] = spawn_pack_field_name(c, index)
		types[index] = is_spread ? spawn_spread_type(c, operand, pack) : element
		task.pack[index] = !is_spread && type_is_managed(c, element) ? .Owned : .Copy
	}
	return synth_record(k, "spawn$pack", "spawn$pack$type", names, types, span)
}

// A spread is held as the slice it views, the `[]T` a `..^T` pack lends the
// elements of included, which the worker spreads again (design.md "Variadic
// parameters").
spawn_spread_type :: proc(c: ^Compiler, spread: Expr, pack: Type_Id) -> Type_Id {
	held, _ := variadic_spread_type(c, expr_base(spread).type, pack)
	return held
}

@(private = "file")
spawn_pack_field_name :: proc(c: ^Compiler, index: int) -> string {
	return fmt.aprintf("p%d", index, allocator = c.semantic_allocator)
}

// The worker's arguments for a held pack, in written order.
@(private = "file")
spawn_repack :: proc(k: ^Checker, task: ^Spawn_Task, call: ^Expr_Call, field: Expr, layout: ^Spawn_Layout, span: Span) {
	c := k.c
	for is_spread, index in call.variadic_order {
		operand := synth_selector(c, field, spawn_pack_field_name(c, index), span)
		if is_spread {
			append(&layout.args, Argument{span = span, mode = .Spread, value = operand})
			continue
		}
		if task.pack[index] == .Copy {
			append(&layout.args, Argument{span = span, value = operand})
			continue
		}
		local := fmt.aprintf("spawn$pack$owned$%d", index, allocator = c.semantic_allocator)
		value := spawn_take_local(c, &layout.stmts, local, operand, span)
		append(&layout.args, Argument{span = span, value = synth_move(c, value, span)})
	}
}

// `name := unsafe.take(field);` in `run`, and the name.
@(private = "file")
spawn_take_local :: proc(c: ^Compiler, stmts: ^[dynamic]Stmt, name: string, field: Expr, span: Span) -> Expr {
	append(stmts, synth_decl(c, .Var, name, spawn_builtin_call(c, "spawn$take", {field}, span), span))
	return synth_ident(c, name, span)
}

// A call of the `unsafe` builtin `bind_unsafe_builtins` bound to `name`.
@(private = "file")
spawn_builtin_call :: proc(c: ^Compiler, name: string, values: []Expr, span: Span) -> Expr {
	return synth_call(c, synth_ident(c, name, span), values, span)
}

// A field of the frame `run` takes.
@(private = "file")
frame_select :: proc(c: ^Compiler, field: string, span: Span) -> Expr {
	return synth_selector(c, synth_ident(c, SPAWN_FRAME, span), field, span)
}

// design.md "Spawn statements": which arguments are copied, lent, or owned.
@(private = "file")
spawn_field_kind :: proc(k: ^Checker, argument: Expr, type: Type_Id, mode: Param_Mode) -> Spawn_Field_Kind {
	switch mode {
	case .Inout:
		return .Address
	case .Move:
		return .Owned
	case .Variadic:
		return .Copy
	case .Borrow:
	case .Value:
		if !type_is_managed(k.c, type) {
			return .Copy
		}
	}
	if !place_in_temporary(k.c, argument) {
		// comments.md "Widening by label": a widened place is lent as any
		// argument is, and only its widened form is the task's.
		return expression_converts_storage(argument) ? .Copy : .Address
	}
	if expression_is_borrowed_place(argument) {
		spawn_copy_from_temporary(k, argument, type)
	}
	return .Owned
}

// Whether a value or place is in a temporary's own storage, which ends with its
// statement: a path of fields and elements that follows no pointer or slice. A
// call's `inout` result has a mutable place behind it, which no temporary is.
@(private = "file")
place_in_temporary :: proc(c: ^Compiler, place: Expr) -> bool {
	if !expression_is_borrowed_place(place) {
		return true
	}
	#partial switch v in place {
	case ^Expr_Selector:
		return v.resolution.kind == .Field && !type_is_pointer(c, expr_base(v.operand).type) && place_in_temporary(c, v.operand)
	case ^Expr_Postfix:
		return v.boxed && place_in_temporary(c, v.operand)
	case ^Expr_Index:
		#partial switch underlying_kind(c, expr_base(v.operand).type) {
		case .Slice, .C_Pointer, .Pointer:
			return false
		}
		return len(v.bound) == 0 && place_in_temporary(c, v.operand)
	}
	return false
}

// design.md "Spawn statements": a field or element of a temporary is copied into
// the task, as a binding would copy it.
@(private = "file")
spawn_copy_from_temporary :: proc(k: ^Checker, argument: Expr, type: Type_Id) {
	copied := copied_type(argument, type)
	if type_clone_disabled(k.c, copied) {
		errorf(
			k.c, expr_span(argument), "L0728",
			"`%s` is move-only, so a task cannot have a copy of this part of a temporary, which ends with this statement; bind the temporary to a local declared before the `parallel` block",
			type_name(k.c, copied),
		)
		return
	}
	record_copy(k, .Argument, expr_span(argument), argument, copied)
	classify_copy(k, argument, type, .Argument)
}

// `unsafe.take`, `unsafe.write`, and `unsafe.free` under the names `run` calls
// them by. `core:thread` imports the package, so its `parallel` dependency
// loaded it.
@(private = "file")
bind_unsafe_builtins :: proc(k: ^Checker, span: Span) -> bool {
	pkg := standard_package(k.c, STD_UNSAFE)
	for name in ([]string{"take", "write", "free"}) {
		builtin := package_symbol_named(k.c, pkg, name)
		if builtin == INVALID_SYMBOL {
			errorf(k.c, span, "L0727", "a `spawn` needs `%s` from `%s`, which `%s` has not loaded", name, STD_UNSAFE, STD_THREAD)
			return false
		}
		k.scope.names[intern_identifier(k.c, fmt.tprintf("spawn$%s", name))] = builtin
	}
	return true
}

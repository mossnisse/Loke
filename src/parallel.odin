// `parallel` blocks and `spawn` statements (design.md "Structured
// concurrency").
//
// A block is checked as the block a programmer would write with a hidden local
// declared first: a `core:thread` `Task_Scope`, whose drop joins every task
// (design.md "Parallel blocks"). `parallel (pool)` declares the executor
// first, as a `^thread.Pool` local, and its scope borrows it until the join. Later phases run that block,
// `Stmt_Parallel.lowered`, instead of the statement. A spawn is checked as the
// call it starts. Its arguments are prepared on the parent into a frame record,
// and a synthesized `run` procedure, checked as ordinary code, makes the call
// on the worker from that frame (compiler-architecture.md "Lowering parallel
// blocks").
package lokec

import "core:fmt"

// How one argument reaches the task, which decides its frame field.
Spawn_Field_Kind :: enum u8 {
	// Copied into the task: a `value: T` argument whose type copies without a
	// hook or an allocation. Only what the value borrows lasts to the join.
	Copy,
	// A temporary or moved value the task owns; the worker drops what its call
	// does not consume.
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

// How diagnostics name what a spawn starts: the procedure, the procedure
// value as written, or a literal called in place by its signature.
spawn_callee_name :: proc(c: ^Compiler, call: ^Expr_Call) -> string {
	if !call_through_value(c, call) {
		if sym := symbol_of(c, call.resolution.symbol); sym != nil {
			return identifier_text(c, sym.name)
		}
	}
	span := expr_span(call.callee)
	if literal, is_literal := call.callee.(^Expr_Proc); is_literal && literal.signature != nil {
		span = literal.signature.span
	}
	return c.sources[span.file].text[span.lo:span.hi]
}

// The names the synthesized code binds in scopes of its own. None can be
// written, so none collides with the source.
@(private = "file")
PARALLEL_SCOPE :: "parallel$scope"
@(private = "file")
PARALLEL_POOL :: "parallel$pool"

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
		errors := len(k.c.diagnostics)
		check_local_declaration(k, pool)
		if len(k.c.diagnostics) > errors {
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
	pointer.elem = synth_ident(k, "Pool", alias, span)
	return hidden_declaration(k, PARALLEL_POOL, pointer, s.executor, span)
}

// `parallel$scope: Task_Scope = {};`, or `Task_Scope.pooled(parallel$pool)`
// after an executor, its type bound to a name only the block's own scope has.
@(private = "file")
hidden_scope_declaration :: proc(k: ^Checker, s: ^Stmt_Parallel, scope_type: Type_Id, pool: ^Decl) -> ^Decl {
	span := s.keyword
	alias := intern_identifier(k.c, "parallel$scope$type")
	k.scope.names[alias] = new_associated_type(k.c, "Task_Scope", scope_type, INVALID_TYPE)
	type := synth_ident(k, "Task_Scope", alias, span)
	value: Expr
	if pool != nil {
		pooled := synth_selector(k.c, synth_ident(k, "Task_Scope", alias, span), "pooled", span)
		executor := synth_ident(k, PARALLEL_POOL, intern_identifier(k.c, PARALLEL_POOL), span)
		value = synth_call(k.c, pooled, {executor}, span)
	} else {
		composite := new(Expr_Composite, k.c.semantic_allocator)
		composite.span = span
		value = composite
	}
	return hidden_declaration(k, PARALLEL_SCOPE, type, value, span)
}

@(private = "file")
hidden_declaration :: proc(k: ^Checker, name: string, type: Expr, value: Expr, span: Span) -> ^Decl {
	d := new(Decl, k.c.semantic_allocator)
	d.span = span
	d.kind = .Var
	d.names = make([]Name, 1, k.c.semantic_allocator)
	d.names[0] = Name{text = name, span = span, id = intern_identifier(k.c, name)}
	d.declared_type = type
	d.values = make([]Expr, 1, k.c.semantic_allocator)
	d.values[0] = value
	return d
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
	if pkg.scope == nil {
		return INVALID_TYPE
	}
	sym := symbol_of(k.c, pkg.scope.names[intern_identifier(k.c, name)] or_else INVALID_SYMBOL)
	if sym == nil || sym.kind != .Type || sym.type == INVALID_TYPE {
		errorf(k.c, no_span(), "L0727", "`%s` declares no `%s`, which a `parallel` block needs", STD_THREAD, name)
		return INVALID_TYPE
	}
	return sym.type
}

task_scope_start :: proc(c: ^Compiler, scope_type: Type_Id) -> Symbol_Id {
	info := type_of(c, scope_type)
	if info == nil {
		return INVALID_SYMBOL
	}
	return member_named(c, info.members, intern_identifier(c, "start"))
}

@(private = "file")
standard_package :: proc(c: ^Compiler, key: string) -> ^Package {
	for &pkg in c.packages {
		if pkg.key == key {
			return &pkg
		}
	}
	return nil
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
		result_type = check_expr(k, s.result, position = .Place)
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
	result, result_ok := spawn_result_symbol(k, s, block, type)
	if !callee_ok || !result_ok {
		return FLOWS
	}
	lower_spawn(k, s, block, proc_type, result)
	return FLOWS
}

// design.md "Spawn statements": the spawned call is a procedure or method
// declared in Loke, including a generic instance, or a procedure value.
// Answers the procedure type the call goes through.
@(private = "file")
spawned_callee :: proc(k: ^Checker, call: ^Expr_Call) -> (Type_Id, bool) {
	c := k.c
	proc_type := INVALID_TYPE
	if call_through_value(c, call) {
		proc_type = expr_base(call.callee).type
	} else {
		_, procedure := call.operation.(Call_Procedure)
		sym := symbol_of(c, call.resolution.symbol)
		if !procedure || call.dispatch != nil || sym == nil || sym.kind != .Proc || sym.synth != .None ||
		   sym.delegated {
			errorf(
				c, expr_span(call.callee), "L0728",
				"`spawn` starts a procedure, a method, or a procedure value; a `dyn` view, a built-in, or a conversion cannot be spawned yet",
			)
			return INVALID_TYPE, false
		}
		proc_type = sym.proc_type
	}
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
spawn_result_symbol :: proc(k: ^Checker, s: ^Stmt_Spawn, block: ^Stmt_Parallel, type: Type_Id) -> (Symbol_Id, bool) {
	c := k.c
	if s.result == nil {
		return INVALID_SYMBOL, true
	}
	id := s.result.symbol
	sym := symbol_of(c, id)
	if sym == nil {
		return INVALID_SYMBOL, false
	}
	inside := sym.span.file == block.span.file && sym.span.lo >= block.span.lo && sym.span.hi <= block.span.hi
	if sym.kind != .Var || symbol_outlives_bodies(sym) || sym.borrowed_binding != .None || inside {
		errorf(
			c, s.result.span, "L0728",
			"a task's result goes to a local variable declared before the `parallel` block, and `%s` is not one",
			s.result.name,
		)
		if inside {
			add_notef(c, sym.span, "declared inside the block, so it ends before the join")
		}
		return INVALID_SYMBOL, false
	}
	if type == TYPE_VOID {
		errorf(c, s.call.(^Expr_Call).span, "L0728", "this call has no result to assign to `%s`", s.result.name)
		return INVALID_SYMBOL, false
	}
	if info := type_of(c, type); info != nil && info.anonymous_record {
		errorf(
			c, s.call.(^Expr_Call).span, "L0728",
			"this call has several results, so a task has nowhere to put them; return one record from the procedure the task runs",
		)
		return INVALID_SYMBOL, false
	}
	if type != sym.type {
		errorf(
			c, s.call.(^Expr_Call).span, "L0728",
			"this call returns `%s`, and `%s` is a `%s`; the worker assigns the result without converting it",
			type_name(c, type), s.result.name, type_name(c, sym.type),
		)
		return INVALID_SYMBOL, false
	}
	return id, true
}

// The frame record and `run` procedure for one spawn, declared in a scope of
// their own: `run` takes every argument out of the frame and makes the call.
//
//     frame :: struct { run: rawptr, arg$0: ..., result: ^mut R }
//     run :: proc(frame: ^mut frame) {
//         owned$1 := unsafe.take(frame.arg$1);
//         unsafe.write(frame.result^, callee(frame.arg$0^, inout ..., move(owned$1)));
//         unsafe.free(frame);
//     }
//
// design.md "Spawn statements": a variadic pack's slot holds a record of its
// operands, `pack :: struct { p0: T, p1: []T }`, and `run` packs them again:
// `callee(..., move(pack$owned$0), ..frame.arg$2.p1)`.
@(private = "file")
lower_spawn :: proc(k: ^Checker, s: ^Stmt_Spawn, block: ^Stmt_Parallel, proc_type: Type_Id, result: Symbol_Id) {
	c := k.c
	call := s.call.(^Expr_Call)
	info := underlying_info(c, proc_type)
	builtins, found := unsafe_builtins(k)
	if !found {
		return
	}
	span := call.span

	task := new(Spawn_Task, c.semantic_allocator)
	task.scope = block.scope
	task.pooled = block.executor != nil
	if scope := symbol_of(c, block.scope); scope != nil {
		task.start = task_scope_start(c, scope.type)
	}
	if task.start == INVALID_SYMBOL {
		return
	}
	task.result = result
	task.through_value = call_through_value(c, call)

	outer := k.scope
	k.scope = new_scope(c, outer, .Local)
	defer k.scope = outer

	task.kinds = make([]Spawn_Field_Kind, len(call.bound), c.semantic_allocator)
	field_types := make([]Type_Id, len(call.bound) + 3, c.semantic_allocator)
	field_types[0] = TYPE_RAWPTR
	for argument, index in call.bound {
		type := index < len(info.parameters) ? info.parameters[index] : INVALID_TYPE
		mode := index < len(info.param_modes) ? info.param_modes[index] : Param_Mode.Value
		kind := spawn_field_kind(c, argument, type, mode)
		if call_packs(call, index) {
			pack := spawn_pack_record(k, task, call, type, span)
			if pack == INVALID_TYPE {
				return
			}
			kind, type = .Owned, pack
		} else if call.is_variadic && index == call.variadic_slot {
			// A lone spread forwards the slice it views, as at any call.
			kind = .Copy
		}
		task.kinds[index] = kind
		field_types[spawn_argument_field(index)] = kind == .Address ? pointer_to(c, type, mode == .Inout) : type
	}
	if result != INVALID_SYMBOL {
		field_types[spawn_result_field(task)] = pointer_to(c, symbol_of(c, result).type, true)
	}
	// design.md "Spawn statements": a procedure value is evaluated on the
	// parent, and copied into the task as a value argument would be.
	if task.through_value {
		field_types[spawn_callee_field(task)] = proc_type
	}
	fields := field_types[:spawn_callee_field(task) + (task.through_value ? 1 : 0)]

	field_names := make([]string, len(fields), c.semantic_allocator)
	for &name, index in field_names {
		name = frame_field_name(c, task, index)
	}
	frame_name := fmt.aprintf("spawn$frame$%d", span.lo, allocator = c.semantic_allocator)
	task.frame = synth_record(k, frame_name, "spawn$type", field_names, fields, span)
	if task.frame == INVALID_TYPE {
		return
	}

	callee_alias := intern_identifier(c, "spawn$callee")
	if !task.through_value {
		k.scope.names[callee_alias] = call.resolution.symbol
	}
	for name, index in ([]string{"spawn$take", "spawn$write", "spawn$free"}) {
		k.scope.names[intern_identifier(c, name)] = builtins[index]
	}

	frame_param := intern_identifier(c, "spawn$frame")
	frame_of :: proc(k: ^Checker, id: Identifier_Id, span: Span) -> Expr {
		return synth_ident(k, "spawn$frame", id, span)
	}
	stmts := make([dynamic]Stmt, 0, len(call.bound) + 2, c.semantic_allocator)
	args := make([dynamic]Argument, 0, len(call.bound) + len(task.pack), c.semantic_allocator)
	for kind, index in task.kinds {
		mode := index < len(info.param_modes) ? info.param_modes[index] : Param_Mode.Value
		field := synth_selector(c, frame_of(k, frame_param, span), frame_field_name(c, task, spawn_argument_field(index)), span)
		if call_packs(call, index) {
			spawn_repack(k, task, call, field, &stmts, &args, span)
			continue
		}
		if call.is_variadic && index == call.variadic_slot {
			append(&args, Argument{span = span, mode = .Spread, value = field})
			continue
		}
		value: Expr
		argument_mode := Argument_Mode.Value
		switch kind {
		case .Copy:
			value = field
		case .Address:
			value = synth_deref(c, field, span)
			if mode == .Inout {
				argument_mode = .Inout
			}
		case .Owned:
			local := fmt.aprintf("spawn$owned$%d", index, allocator = c.semantic_allocator)
			local_id := intern_identifier(c, local)
			taken := synth_call(c, synth_ident(k, "spawn$take", intern_identifier(c, "spawn$take"), span), {field}, span)
			append(&stmts, synth_var(c, local, local_id, taken, span))
			value = synth_ident(k, local, local_id, span)
			if mode == .Move {
				moved := new(Expr_Move, c.semantic_allocator)
				moved.span = span
				moved.value = value
				value = moved
			}
		}
		append(&args, Argument{span = span, mode = argument_mode, value = value})
	}
	inner := new(Expr_Call, c.semantic_allocator)
	inner.span = span
	if task.through_value {
		inner.callee = synth_selector(c, frame_of(k, frame_param, span), frame_field_name(c, task, spawn_callee_field(task)), span)
	} else {
		inner.callee = synth_ident(k, "spawn$callee", callee_alias, span)
	}
	inner.args = args[:]
	made: Expr = inner
	if result != INVALID_SYMBOL {
		destination := synth_deref(c, synth_selector(c, frame_of(k, frame_param, span), frame_field_name(c, task, spawn_result_field(task)), span), span)
		made = synth_call(c, synth_ident(k, "spawn$write", intern_identifier(c, "spawn$write"), span), {destination, inner}, span)
	}
	append(&stmts, synth_expr_stmt(c, made, span))
	freed := synth_call(c, synth_ident(k, "spawn$free", intern_identifier(c, "spawn$free"), span), {frame_of(k, frame_param, span)}, span)
	append(&stmts, synth_expr_stmt(c, freed, span))

	// `proc(spawn$frame: ^mut <frame>)`, its type spelled as one more alias.
	frame_pointer := intern_identifier(c, "spawn$frame$pointer")
	k.scope.names[frame_pointer] = new_associated_type(c, "spawn$frame", pointer_to(c, task.frame, true), INVALID_TYPE)
	param_names := make([]Param_Name, 1, c.semantic_allocator)
	param_names[0] = Param_Name{name = Name{text = "spawn$frame", span = span, id = frame_param}}
	params := make([]Parameter, 1, c.semantic_allocator)
	params[0] = Parameter{span = span, names = param_names, mode = .Value, type = synth_ident(k, "spawn$frame", frame_pointer, span)}
	signature := new(Type_Proc, c.semantic_allocator)
	signature.span = span
	signature.params = params
	body := new(Block, c.semantic_allocator)
	body.span = span
	body.stmts = stmts[:]
	literal := new(Expr_Proc, c.semantic_allocator)
	literal.span = span
	literal.signature = signature
	literal.body = body
	run_name := fmt.aprintf("spawn$run$%d", span.lo, allocator = c.semantic_allocator)
	run_decl := synth_const(k, run_name, intern_identifier(c, run_name), literal, span)
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
	}
}

// design.md "Spawn statements": the record a variadic pack's operands are
// held in until the worker packs them again. An element is copied into the
// task, or owned by it when its type is managed, as the pack would own it; a
// spread is the `[]T` it views, which the task borrows until the join.
@(private = "file")
spawn_pack_record :: proc(k: ^Checker, task: ^Spawn_Task, call: ^Expr_Call, pack: Type_Id, span: Span) -> Type_Id {
	c := k.c
	element := slice_element(c, pack)
	task.pack = make([]Spawn_Field_Kind, len(call.variadic_order), c.semantic_allocator)
	types := make([]Type_Id, len(call.variadic_order), c.semantic_allocator)
	names := make([]string, len(call.variadic_order), c.semantic_allocator)
	for is_spread, index in call.variadic_order {
		names[index] = spawn_pack_field_name(c, index)
		types[index] = is_spread ? pack : element
		task.pack[index] = !is_spread && type_is_managed(c, element) ? .Owned : .Copy
	}
	name := fmt.aprintf("spawn$pack$%d", span.lo, allocator = c.semantic_allocator)
	return synth_record(k, name, "spawn$pack$type", names, types, span)
}

spawn_pack_field_name :: proc(c: ^Compiler, index: int) -> string {
	return fmt.aprintf("p%d", index, allocator = c.semantic_allocator)
}

// The worker's arguments for a held pack, in its written order: an owned
// element moved out of the frame, a copied one read, and a spread forwarded.
@(private = "file")
spawn_repack :: proc(
	k: ^Checker, task: ^Spawn_Task, call: ^Expr_Call, field: Expr,
	stmts: ^[dynamic]Stmt, args: ^[dynamic]Argument, span: Span,
) {
	c := k.c
	for is_spread, index in call.variadic_order {
		operand := synth_selector(c, field, spawn_pack_field_name(c, index), span)
		if is_spread {
			append(args, Argument{span = span, mode = .Spread, value = operand})
			continue
		}
		if task.pack[index] == .Copy {
			append(args, Argument{span = span, value = operand})
			continue
		}
		local := fmt.aprintf("spawn$pack$owned$%d", index, allocator = c.semantic_allocator)
		local_id := intern_identifier(c, local)
		taken := synth_call(c, synth_ident(k, "spawn$take", intern_identifier(c, "spawn$take"), span), {operand}, span)
		append(stmts, synth_var(c, local, local_id, taken, span))
		moved := new(Expr_Move, c.semantic_allocator)
		moved.span = span
		moved.value = synth_ident(k, local, local_id, span)
		append(args, Argument{span = span, value = moved})
	}
}

// design.md "Spawn statements": a `value: T` argument is copied into the
// task when `T` copies without a hook and without allocating; a managed one
// stays borrowed, as an ordinary call borrows it, unless it is a temporary,
// which belongs to the task.
@(private = "file")
spawn_field_kind :: proc(c: ^Compiler, argument: Expr, type: Type_Id, mode: Param_Mode) -> Spawn_Field_Kind {
	switch mode {
	case .Inout:
		return .Address
	case .Move, .Variadic:
		return .Owned
	case .Borrow:
		return expression_is_borrowed_place(argument) ? .Address : .Owned
	case .Value:
	}
	if !type_is_managed(c, type) {
		return .Copy
	}
	return expression_is_borrowed_place(argument) ? .Address : .Owned
}

@(private = "file")
frame_field_name :: proc(c: ^Compiler, task: ^Spawn_Task, field: int) -> string {
	if field == 0 {
		return "run"
	}
	if task.result != INVALID_SYMBOL && field == spawn_result_field(task) {
		return "result"
	}
	if task.through_value && field == spawn_callee_field(task) {
		return "callee"
	}
	return fmt.aprintf("arg%d", field - 1, allocator = c.semantic_allocator)
}

// `unsafe.take`, `unsafe.write`, and `unsafe.free`, which `core:thread`
// imports, so its `parallel` dependency loaded them.
@(private = "file")
unsafe_builtins :: proc(k: ^Checker) -> ([3]Symbol_Id, bool) {
	out: [3]Symbol_Id
	pkg := standard_package(k.c, STD_UNSAFE)
	if pkg == nil || pkg.scope == nil {
		return out, false
	}
	for name, index in ([]string{"take", "write", "free"}) {
		out[index] = pkg.scope.names[intern_identifier(k.c, name)] or_else INVALID_SYMBOL
		if out[index] == INVALID_SYMBOL {
			return out, false
		}
	}
	return out, true
}

// ------------------------------------------------------- synthesized syntax --

@(private = "file")
synth_name :: proc(c: ^Compiler, text: string, span: Span) -> Name {
	return Name{text = text, span = span, id = intern_identifier(c, text)}
}

@(private = "file")
synth_ident :: proc(k: ^Checker, text: string, id: Identifier_Id, span: Span) -> ^Expr_Ident {
	ident := new(Expr_Ident, k.c.semantic_allocator)
	ident.span = span
	ident.name, ident.name_id = text, id
	return ident
}

@(private = "file")
synth_selector :: proc(c: ^Compiler, operand: Expr, field: string, span: Span) -> Expr {
	selector := new(Expr_Selector, c.semantic_allocator)
	selector.span = span
	selector.operand = operand
	selector.name = synth_name(c, field, span)
	return selector
}

@(private = "file")
synth_deref :: proc(c: ^Compiler, operand: Expr, span: Span) -> Expr {
	deref := new(Expr_Postfix, c.semantic_allocator)
	deref.span = span
	deref.op, deref.op_span = .Caret, span
	deref.operand = operand
	return deref
}

@(private = "file")
synth_call :: proc(c: ^Compiler, callee: Expr, values: []Expr, span: Span) -> Expr {
	call := new(Expr_Call, c.semantic_allocator)
	call.span = span
	call.callee = callee
	call.args = make([]Argument, len(values), c.semantic_allocator)
	for value, index in values {
		call.args[index] = Argument{span = span, value = value}
	}
	return call
}

@(private = "file")
synth_expr_stmt :: proc(c: ^Compiler, value: Expr, span: Span) -> Stmt {
	s := new(Stmt_Expr, c.semantic_allocator)
	s.span = span
	s.exprs = make([]Expr, 1, c.semantic_allocator)
	s.exprs[0] = value
	return s
}

// A struct declared in the current scope, each field's type bound to a name
// only this scope has.
@(private = "file")
synth_record :: proc(k: ^Checker, name, alias_prefix: string, field_names: []string, types: []Type_Id, span: Span) -> Type_Id {
	c := k.c
	record := new(Type_Record, c.semantic_allocator)
	record.span = span
	record.kind = .Struct
	record.fields = make([]Field, len(types), c.semantic_allocator)
	for type, index in types {
		alias := intern_identifier(c, fmt.aprintf("%s$%d", alias_prefix, index, allocator = c.semantic_allocator))
		k.scope.names[alias] = new_associated_type(c, alias_prefix, type, INVALID_TYPE)
		names := make([]Name, 1, c.semantic_allocator)
		names[0] = synth_name(c, field_names[index], span)
		record.fields[index] = Field{span = span, names = names, type = synth_ident(k, alias_prefix, alias, span)}
	}
	decl := synth_const(k, name, intern_identifier(c, name), record, span)
	check_local_declaration(k, decl)
	if len(decl.symbols) != 1 {
		return INVALID_TYPE
	}
	sym := symbol_of(c, decl.symbols[0])
	return sym == nil ? INVALID_TYPE : sym.type
}

@(private = "file")
synth_var :: proc(c: ^Compiler, text: string, id: Identifier_Id, value: Expr, span: Span) -> ^Decl {
	d := new(Decl, c.semantic_allocator)
	d.span = span
	d.kind = .Var
	d.names = make([]Name, 1, c.semantic_allocator)
	d.names[0] = Name{text = text, span = span, id = id}
	d.values = make([]Expr, 1, c.semantic_allocator)
	d.values[0] = value
	return d
}

@(private = "file")
synth_const :: proc(k: ^Checker, text: string, id: Identifier_Id, value: Expr, span: Span) -> ^Decl {
	d := new(Decl, k.c.semantic_allocator)
	d.span = span
	d.kind = .Const
	d.names = make([]Name, 1, k.c.semantic_allocator)
	d.names[0] = Name{text = text, span = span, id = id}
	d.values = make([]Expr, 1, k.c.semantic_allocator)
	d.values[0] = value
	return d
}

// A disposable per-procedure control-flow view (m5a-plan decision "Analysis
// placement").
//
// Blocks reference the typed AST rather than replacing it: this is a lightweight
// analysis view, not MIR, and the backend still receives annotated AST until M6.
// It is rebuilt for each concrete body instance, so a generic specialization
// never shares liveness state with another one.
//
// The events are deliberately few. A managed local becomes live at a completed
// initialization, dies at a `move` or an explicit `drop`, must be live at a use,
// and is cleaned up at every point control leaves its declaring scope. Every
// exit — fallthrough, `return`, `break`, `continue` — emits the cleanup events of
// the scopes it passes through, innermost first, so the analysis reads one state
// per cleanup point instead of reconstructing which scopes an abrupt jump left.
package lokec

Block_Id :: distinct int

Flow_Event_Kind :: enum {
	Init,
	Kill,
	Use,
	Cleanup,
}

Flow_Event :: struct {
	kind: Flow_Event_Kind,
	slot: int,
	span: Span,
	name: string,
}

Flow_Block :: struct {
	events: [dynamic]Flow_Event,
	preds:  [dynamic]Block_Id,
	// Filled by `src/lifecycle.odin`'s solver.
	entry_state: []Liveness,
	exit_state:  []Liveness,
	visited:     bool,
}

// One local the analysis follows. Only a managed lexical local is tracked: an
// unmanaged one has no cleanup obligation and no operation that can kill it.
Tracked_Local :: struct {
	symbol: Symbol_Id,
	scope:  int,
	// A `move` parameter arrives owned, so it is live before the first statement
	// rather than at a declaration inside the body.
	live_on_entry: bool,
	// Filled while reporting: whether this local ever reaches a cleanup point,
	// and in which states.
	seen_cleanup: bool,
	live_exit:    bool,
	dead_exit:    bool,
}

Flow_Graph :: struct {
	blocks:  [dynamic]^Flow_Block,
	tracked: [dynamic]Tracked_Local,
	by_symbol: map[Symbol_Id]int,

	k:       ^Checker,
	current: Block_Id,
	// A slot in `tracked` is permanent: it names one declaration's state for the
	// whole analysis. What comes and goes is scope membership, so that is a
	// separate stack of slots in declaration order, with `scopes` holding one
	// marker into it per open lexical scope. Leaving a scope cleans up exactly
	// the slots above its marker and then forgets them.
	in_scope: [dynamic]int,
	scopes:   [dynamic]int,
	// Where an abrupt exit lands, and how far down `in_scope` it unwinds.
	break_block:    Block_Id,
	continue_block: Block_Id,
	break_depth:    int,
	continue_depth: int,
}

NO_BLOCK :: Block_Id(-1)

// nil when the body has nothing to track, which is the ordinary case and saves
// every unmanaged procedure a graph.
build_flow_graph :: proc(k: ^Checker, literal: ^Expr_Proc) -> ^Flow_Graph {
	if literal == nil || literal.body == nil {
		return nil
	}
	graph := new(Flow_Graph, k.c.semantic_allocator)
	graph.k = k
	graph.blocks = make([dynamic]^Flow_Block, k.c.semantic_allocator)
	graph.tracked = make([dynamic]Tracked_Local, k.c.semantic_allocator)
	graph.by_symbol = make(map[Symbol_Id]int, 8, k.c.semantic_allocator)
	graph.scopes = make([dynamic]int, k.c.semantic_allocator)
	graph.in_scope = make([dynamic]int, k.c.semantic_allocator)
	graph.break_block, graph.continue_block = NO_BLOCK, NO_BLOCK
	graph.current = new_flow_block(graph)

	// design.md: a `move` parameter transfers ownership from caller to callee, so
	// the callee drops it like any owned local. It lives in a scope outside the
	// body's, which is what makes its cleanup the outermost one.
	enter_flow_scope(graph)
	track_move_parameters(graph, literal)
	walk_flow_block(graph, literal.body)
	leave_flow_scope(graph)

	return len(graph.tracked) == 0 ? nil : graph
}

@(private = "file")
new_flow_block :: proc(graph: ^Flow_Graph) -> Block_Id {
	block := new(Flow_Block, graph.k.c.semantic_allocator)
	block.events = make([dynamic]Flow_Event, graph.k.c.semantic_allocator)
	block.preds = make([dynamic]Block_Id, graph.k.c.semantic_allocator)
	append(&graph.blocks, block)
	return Block_Id(len(graph.blocks) - 1)
}

@(private = "file")
link :: proc(graph: ^Flow_Graph, from, to: Block_Id) {
	if from == NO_BLOCK || to == NO_BLOCK {
		return
	}
	append(&graph.blocks[to].preds, from)
}

@(private = "file")
emit :: proc(graph: ^Flow_Graph, event: Flow_Event) {
	if graph.current == NO_BLOCK {
		return // unreachable code carries no obligation
	}
	append(&graph.blocks[graph.current].events, event)
}

@(private = "file")
slot_of :: proc(graph: ^Flow_Graph, symbol: Symbol_Id) -> (int, bool) {
	index, found := graph.by_symbol[symbol]
	return index, found
}

// ------------------------------------------------------------- the walk --

@(private = "file")
walk_flow_block :: proc(graph: ^Flow_Graph, b: ^Block) {
	if b == nil {
		return
	}
	enter_flow_scope(graph)
	walk_flow_stmts(graph, b.stmts)
	leave_flow_scope(graph)
}

@(private = "file")
track_move_parameters :: proc(graph: ^Flow_Graph, literal: ^Expr_Proc) {
	if literal.signature == nil {
		return
	}
	for parameter in literal.signature.params {
		if parameter.mode != .Move {
			continue
		}
		for id in parameter.symbols {
			sym := symbol_of(graph.k.c, id)
			if sym == nil || !type_is_managed(graph.k.c, sym.type) {
				continue
			}
			append(&graph.tracked, Tracked_Local{symbol = id, live_on_entry = true})
			graph.by_symbol[id] = len(graph.tracked) - 1
			append(&graph.in_scope, len(graph.tracked) - 1)
		}
	}
}

@(private = "file")
enter_flow_scope :: proc(graph: ^Flow_Graph) {
	append(&graph.scopes, len(graph.in_scope))
}

@(private = "file")
leave_flow_scope :: proc(graph: ^Flow_Graph) {
	marker := pop(&graph.scopes)
	emit_cleanups(graph, marker)
	// A local leaving its scope is gone: nothing after this may name it, and the
	// enclosing scope must not clean it up a second time.
	resize(&graph.in_scope, marker)
}

@(private = "file")
walk_flow_stmts :: proc(graph: ^Flow_Graph, stmts: []Stmt) {
	for stmt in stmts {
		walk_flow_stmt(graph, stmt)
	}
}

// Cleanup events for every scope above `down_to`, innermost first, which is the
// reverse registration order design.md requires.
@(private = "file")
emit_cleanups :: proc(graph: ^Flow_Graph, down_to: int) {
	for index := len(graph.in_scope) - 1; index >= down_to; index -= 1 {
		slot := graph.in_scope[index]
		sym := symbol_of(graph.k.c, graph.tracked[slot].symbol)
		emit(graph, Flow_Event {
			kind = .Cleanup,
			slot = slot,
			span = sym == nil ? no_span() : sym.span,
			name = sym == nil ? "" : identifier_text(graph.k.c, sym.name),
		})
	}
}

@(private = "file")
walk_flow_stmt :: proc(graph: ^Flow_Graph, stmt: Stmt) {
	switch s in stmt {
	case ^Stmt_Error:

	case ^Decl:
		walk_flow_decl(graph, s)

	case ^Stmt_Expr:
		for expr in s.exprs {
			walk_flow_expr(graph, expr)
		}

	case ^Stmt_Assign:
		walk_flow_assign(graph, s)

	case ^Stmt_If:
		walk_flow_if(graph, s)

	case ^Stmt_For:
		walk_flow_for(graph, s)

	case ^Stmt_Foreach:
		walk_flow_foreach(graph, s)

	case ^Stmt_Switch:
		walk_flow_switch(graph, s)

	case ^Stmt_Defer:
		// The deferred statement runs at scope exit, after the analysis has
		// already decided what is live there. M5b owns the "a deferred statement
		// may read a managed local the compiler has not dropped yet" proof; M5a
		// records the registration and does not walk the body as if it ran here.

	case ^Stmt_Return:
		for value in s.values {
			// design.md: returning a managed local, named result, temporary, or
			// `move` parameter "transfers that owned value into result storage
			// without cloning", so the source is dead afterwards and scope exit
			// must not drop it.
			if ident, is_ident := value.expr.(^Expr_Ident); is_ident && !value.clone_on_return {
				if slot, tracked := slot_of(graph, ident.symbol); tracked {
					emit(graph, Flow_Event{kind = .Kill, slot = slot, span = ident.span, name = ident.name})
					continue
				}
			}
			walk_flow_expr(graph, value.expr)
		}
		emit_cleanups(graph, 0)
		graph.current = NO_BLOCK

	case ^Stmt_Branch:
		if s.kind == .Break {
			emit_cleanups(graph, graph.break_depth)
			link(graph, graph.current, graph.break_block)
		} else {
			emit_cleanups(graph, graph.continue_depth)
			link(graph, graph.current, graph.continue_block)
		}
		graph.current = NO_BLOCK

	case ^Block:
		walk_flow_block(graph, s)

	case ^Stmt_When:
		// The branch the checker selected is the only one that exists.
		if selected := when_selected_block(s); selected != nil {
			walk_flow_stmts(graph, selected.stmts)
		}
	}
}

@(private = "file")
walk_flow_decl :: proc(graph: ^Flow_Graph, d: ^Decl) {
	if d.kind == .Const || d.top_level {
		return
	}
	for value in d.values {
		walk_flow_expr(graph, value)
	}
	for id in d.symbols {
		sym := symbol_of(graph.k.c, id)
		if sym == nil || sym.kind != .Var || !type_is_managed(graph.k.c, sym.type) {
			continue
		}
		// ponytail: `manual` disables automatic cleanup, but it is still gated at
		// the declaration, so there is nothing here to exempt yet.
		append(&graph.tracked, Tracked_Local{symbol = id, scope = len(graph.scopes)})
		graph.by_symbol[id] = len(graph.tracked) - 1
		append(&graph.in_scope, len(graph.tracked) - 1)
		// design.md: the implicit action is placed "at the declaration point",
		// which is where initialization completes. `---` leaves storage
		// uninitialised and so registers nothing.
		if len(d.values) == 1 && d.values[0] == nil {
			continue
		}
		emit(graph, Flow_Event {
			kind = .Init,
			slot = len(graph.tracked) - 1,
			span = sym.span,
			name = identifier_text(graph.k.c, sym.name),
		})
	}
}

@(private = "file")
walk_flow_assign :: proc(graph: ^Flow_Graph, s: ^Stmt_Assign) {
	for value in s.rhs {
		walk_flow_expr(graph, value)
	}
	for target in s.lhs {
		// A full assignment to the variable itself revives it; a write through a
		// field or element needs the root live, which is an ordinary use.
		if ident, is_ident := target.(^Expr_Ident); is_ident && s.op == .Assign {
			if slot, tracked := slot_of(graph, ident.symbol); tracked {
				emit(graph, Flow_Event{kind = .Init, slot = slot, span = expr_span(target), name = ident.name})
				continue
			}
		}
		walk_flow_expr(graph, target)
	}
}

@(private = "file")
walk_flow_if :: proc(graph: ^Flow_Graph, s: ^Stmt_If) {
	if s.init != nil {
		walk_flow_stmt(graph, s.init)
	}
	walk_flow_expr(graph, s.cond)
	entry := graph.current
	merge := new_flow_block(graph)

	graph.current = new_flow_block(graph)
	link(graph, entry, graph.current)
	walk_flow_block(graph, s.then)
	link(graph, graph.current, merge)

	graph.current = new_flow_block(graph)
	link(graph, entry, graph.current)
	if s.otherwise != nil {
		walk_flow_stmt(graph, s.otherwise)
	}
	link(graph, graph.current, merge)

	graph.current = merge
}

@(private = "file")
walk_flow_for :: proc(graph: ^Flow_Graph, s: ^Stmt_For) {
	if s.init != nil {
		walk_flow_stmt(graph, s.init)
	}
	head := new_flow_block(graph)
	link(graph, graph.current, head)
	graph.current = head
	if s.cond != nil {
		walk_flow_expr(graph, s.cond)
	}
	done := new_flow_block(graph)
	link(graph, head, done)

	body := new_flow_block(graph)
	link(graph, head, body)
	graph.current = body
	walk_flow_loop_body(graph, s.body, head, done)
	if s.post != nil && graph.current != NO_BLOCK {
		walk_flow_stmt(graph, s.post)
	}
	link(graph, graph.current, head)
	graph.current = done
}

@(private = "file")
walk_flow_foreach :: proc(graph: ^Flow_Graph, s: ^Stmt_Foreach) {
	walk_flow_expr(graph, s.iterable)
	head := new_flow_block(graph)
	link(graph, graph.current, head)
	done := new_flow_block(graph)
	link(graph, head, done)

	body := new_flow_block(graph)
	link(graph, head, body)
	graph.current = body
	walk_flow_loop_body(graph, s.body, head, done)
	link(graph, graph.current, head)
	graph.current = done
}

@(private = "file")
walk_flow_loop_body :: proc(graph: ^Flow_Graph, body: ^Block, head, done: Block_Id) {
	outer_break, outer_continue := graph.break_block, graph.continue_block
	outer_break_depth, outer_continue_depth := graph.break_depth, graph.continue_depth
	graph.break_block, graph.continue_block = done, head
	graph.break_depth, graph.continue_depth = len(graph.in_scope), len(graph.in_scope)
	walk_flow_block(graph, body)
	graph.break_block, graph.continue_block = outer_break, outer_continue
	graph.break_depth, graph.continue_depth = outer_break_depth, outer_continue_depth
}

@(private = "file")
walk_flow_switch :: proc(graph: ^Flow_Graph, s: ^Stmt_Switch) {
	if s.init != nil {
		walk_flow_stmt(graph, s.init)
	}
	if s.subject != nil {
		walk_flow_expr(graph, s.subject)
	}
	entry := graph.current
	merge := new_flow_block(graph)
	// A `switch` without a default can fall past every case, so the entry
	// reaches the merge directly.
	has_default := false
	for c in s.cases {
		if len(c.values) == 0 {
			has_default = true
		}
		graph.current = new_flow_block(graph)
		link(graph, entry, graph.current)
		outer_break, outer_break_depth := graph.break_block, graph.break_depth
		graph.break_block, graph.break_depth = merge, len(graph.in_scope)
		enter_flow_scope(graph)
		walk_flow_stmts(graph, c.stmts)
		leave_flow_scope(graph)
		graph.break_block, graph.break_depth = outer_break, outer_break_depth
		link(graph, graph.current, merge)
	}
	if !has_default {
		link(graph, entry, merge)
	}
	graph.current = merge
}

// ------------------------------------------------------------ expressions --

// Only the shapes that carry an ownership event need their own arm; everything
// else is walked for the uses inside it.
@(private = "file")
walk_flow_expr :: proc(graph: ^Flow_Graph, e: Expr) {
	switch v in e {
	case ^Expr_Ident:
		if slot, tracked := slot_of(graph, v.symbol); tracked {
			emit(graph, Flow_Event{kind = .Use, slot = slot, span = v.span, name = v.name})
		}

	case ^Expr_Move:
		// One event, not a use followed by a kill: `Kill` already requires the
		// source to be live, and two events would report one mistake twice.
		if ident, is_ident := v.value.(^Expr_Ident); is_ident {
			if slot, tracked := slot_of(graph, ident.symbol); tracked {
				emit(graph, Flow_Event{kind = .Kill, slot = slot, span = v.span, name = ident.name})
				return
			}
		}
		walk_flow_expr(graph, v.value)

	case ^Expr_Call:
		walk_flow_call(graph, v)

	case ^Expr_Binary:
		walk_flow_expr(graph, v.lhs)
		walk_flow_expr(graph, v.rhs)

	case ^Expr_Unary:
		walk_flow_expr(graph, v.operand)

	case ^Expr_Postfix:
		walk_flow_expr(graph, v.operand)

	case ^Expr_Selector:
		walk_flow_expr(graph, v.operand)

	case ^Expr_Index:
		walk_flow_expr(graph, v.operand)
		for index in v.indices {
			walk_flow_expr(graph, index)
		}

	case ^Expr_Slice:
		walk_flow_expr(graph, v.operand)
		if v.lo != nil {
			walk_flow_expr(graph, v.lo)
		}
		if v.hi != nil {
			walk_flow_expr(graph, v.hi)
		}

	case ^Expr_Composite:
		for element in v.elements {
			if element.value != nil {
				walk_flow_expr(graph, element.value)
			}
		}

	case ^Expr_Cond:
		walk_flow_expr(graph, v.cond)
		walk_flow_expr(graph, v.then)
		walk_flow_expr(graph, v.otherwise)

	case ^Expr_Or_Else:
		walk_flow_expr(graph, v.value)
		walk_flow_expr(graph, v.fallback)

	case ^Expr_Type_Assert:
		walk_flow_expr(graph, v.operand)

	case ^Expr_Range:
		walk_flow_expr(graph, v.lo)
		walk_flow_expr(graph, v.hi)

	case ^Expr_Literal, ^Expr_Hash, ^Expr_Proc, ^Expr_Proc_Group, ^Expr_Operator,
	     ^Expr_Error,
	     ^Type_Pointer, ^Type_Multi_Pointer, ^Type_Slice, ^Type_Dynamic_Array,
	     ^Type_Array, ^Type_Map, ^Type_Distinct, ^Type_Dyn, ^Type_Type,
	     ^Type_Poly, ^Type_Proc, ^Type_Record, ^Type_Enum, ^Type_Interface:
	}
}

@(private = "file")
walk_flow_call :: proc(graph: ^Flow_Graph, v: ^Expr_Call) {
	// `drop(x)` reads the value, runs its hook, and kills the binding. Its
	// operand is in `bound` rather than `args` by the time this runs.
	if sym := symbol_of(graph.k.c, v.resolution.symbol); sym != nil && sym.kind == .Builtin && sym.builtin == .Drop {
		if len(v.bound) == 1 {
			if ident, is_ident := v.bound[0].(^Expr_Ident); is_ident {
				if slot, tracked := slot_of(graph, ident.symbol); tracked {
					emit(graph, Flow_Event{kind = .Kill, slot = slot, span = v.span, name = ident.name})
					return
				}
			}
		}
		return
	}
	walk_flow_expr(graph, v.callee)
	// design.md: "Method-call syntax supplies an `inout` or `move` marker
	// implicitly for its receiver", so a `move self` call kills the caller's
	// source with no written marker.
	consumed := -1
	if sym := symbol_of(graph.k.c, v.resolution.chosen_overload); sym != nil && sym.receiver == .Move && len(v.bound) > 0 {
		if ident, is_ident := v.bound[0].(^Expr_Ident); is_ident {
			if slot, tracked := slot_of(graph, ident.symbol); tracked {
				emit(graph, Flow_Event{kind = .Kill, slot = slot, span = v.span, name = ident.name})
				consumed = 0
			}
		}
	}
	for argument, index in v.bound {
		if argument != nil && index != consumed {
			walk_flow_expr(graph, argument)
		}
	}
	if len(v.bound) == 0 {
		for argument in v.args {
			walk_flow_expr(graph, argument.value)
		}
	}
}

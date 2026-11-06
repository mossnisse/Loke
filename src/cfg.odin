// A disposable per-procedure control-flow view over the annotated AST, rebuilt
// per concrete body instance. A local goes live at a completed initialization,
// dies at `move`/`drop`, and must be live at a use; a managed one is also
// cleaned up, innermost first, wherever control leaves its scope. Provenance
// events are built in cfg_provenance.odin.
package lokec

import "core:mem"
import "core:slice"

Block_Id :: distinct int

// One walk, three jobs. Only Lifecycle reports; the provenance modes rebuild the
// same topology without repeating its diagnostics or annotations.
Flow_Mode :: enum u8 {
	Lifecycle,
	Prov_Summary,
	Prov_Diagnose,
}

Flow_Event_Kind :: enum {
	Init,
	// Like `Init`, but the state before it decides whether the old value drops.
	Assign,
	Kill,
	Use,
	Cleanup,
	// A region reset, where the provenance pass later asks which owners were
	// dead (design.md "Allocators": a dropped owner no longer blocks a reset).
	Reset_Point,
	// Like `Init`, from a task's result: the local must hold no value yet
	// (design.md "Spawn statements").
	Spawn_Result,
	// A declaration without a value: the local starts dead, also on a loop's
	// next iteration, which reaches it holding the last one's value.
	Declare,
	// A statement that may panic starts: the unwind drops what is live here, so
	// a local no normal exit drops may still need its cleanup (design.md "What
	// the unwind runs, and what it does not").
	Panic_Point,
}

Flow_Event :: struct {
	kind:          Flow_Event_Kind,
	slot:          int,
	span:          Span,
	name:          string,
	assign:        ^Stmt_Assign,
	target:        int,
	// `Reset_Point`: where it is, and the resetting call, if it is one.
	reset:         Reset_Key,
	call:          ^Expr_Call,
	// The attempted operation, for diagnostics.
	verb:          string,
	// `Cleanup`: run by a panic's unwind, not by the end of the local's own scope.
	unwinding:     bool,
}

// A point where a region may end, named alike by the lifecycle walk, which
// records who is dead there, and the provenance walk, which reads it. `node` is
// the resetting call, the `drop`, `move`, `exchange`, or assignment, or the
// jump whose cleanups end `symbol`'s region; nil where its scope ends. A
// deferred statement is walked once per exit, so `expansion` names the walk,
// and a `return`'s unwind apart from the return itself.
Reset_Key :: struct {
	body:      ^Expr_Proc,
	node:      rawptr,
	symbol:    Symbol_Id,
	expansion: Defer_Expansion,
}

@(private)
reset_key :: proc(graph: ^Flow_Graph, node: rawptr, symbol := INVALID_SYMBOL) -> Reset_Key {
	return Reset_Key{graph.literal, node, symbol, graph.expansion}
}

// One walk of a `defer` body: the deferred statement and the exit running it,
// nil at its scope's end. `unwinding` is set from the start of a panic's unwind
// path, whose cleanups may name the same exit, with no `defer` being walked yet.
Defer_Expansion :: struct {
	deferred:  ^Stmt_Defer,
	exit:      rawptr,
	unwinding: bool,
}

// Whether the key's symbol is dead, and where a region ends, the owners live at
// one reset point. Lifecycle registers every point it walks and solves the
// reachable ones, so the provenance walk tells an unreachable point from one the
// walks keyed differently, a compiler bug.
Reset_Liveness :: struct {
	dead:    bool,
	owners:  []Symbol_Id,
	reached: bool,
}

Flow_Block :: struct {
	events: [dynamic]Flow_Event,
	preds:  [dynamic]Block_Id,
	succs:  [dynamic]Block_Id,
	// Filled by `src/lifecycle.odin`'s solver.
	entry_state: []Liveness,
	exit_state:  []Liveness,
	visited:     bool,
	// On a panic's unwind path: the lifecycle pass records liveness there but
	// checks only what deferred statements read, and counts only the cleanups of
	// what those statements declare themselves (`Flow_Event.unwinding`).
	unwind:      bool,
	unwind_at:   Span,

	// Provenance modes, solved by `src/borrow.odin`. Each table is the solver's flat
	// one at this block's entry or exit, kept in pages shared with its neighbors
	// (`src/borrow_tables.odin`). Reaching loans are per slot a handle of a row of
	// `Prov_Solve.reach_rows`.
	prov:            [dynamic]Prov_Event,
	reach_entry:     [][]u32,
	reach_exit:      [][]u32,
	precision_entry: [][]Precision_Loss,
	precision_exit:  [][]Precision_Loss,
	ended_entry:     [][]bool,
	ended_exit:      [][]bool,
	// Per slot, a handle of what it holds of the reborrows (`solve_links_held`).
	links_entry:     [][]u32,
	links_exit:      [][]u32,
	// Per slot, a handle of what carriers it was loaded below (`Loaded_Below`).
	below_entry:     [][]u32,
	below_exit:      [][]u32,
	live_entry:      [][]Slot_Use,
	live_exit:       [][]Slot_Use,
	use_entry:       [][]Span,
	use_exit:        [][]Span,
	prov_visited:    bool,
	// A walk took what reaches this block's end, or what its last definition
	// left, so a new predecessor or definition invalidates that
	// (`prov_reach_invalidate`).
	reach_known:     bool,
}

Flow_Cleanup_Kind :: enum {
	Local,
	Defer,
	// A provenance root whose storage ends with its scope.
	Prov_Root,
}

// Locals and defers share one cleanup order: a deferred read is valid only if
// every local it names is still live where it runs.
Flow_Cleanup :: struct {
	kind:     Flow_Cleanup_Kind,
	slot:     int,
	deferred: ^Stmt_Defer,
	root:     Root_Id,
	span:     Span,
}

Tracked_Local :: struct {
	symbol:        Symbol_Id,
	// A `move` parameter arrives owned.
	live_on_entry: bool,
	// `x: T = ---`: followed, but a not-live use isn't reported (design.md
	// "Built-in values").
	unchecked:     bool,
	// Whether any path initializes it, which picks the not-live wording.
	ever_written:  bool,
	// Filled while reporting: which states reach a cleanup, and whether an
	// assignment sees it live on one path and dead on another.
	live_exit:          bool,
	dead_exit:          bool,
	conditional_assign: bool,
	// Whether a statement that may panic finds it live, or an unwind leaves it so.
	live_at_panic:      bool,
}

Flow_Graph :: struct {
	blocks:    [dynamic]^Flow_Block,
	tracked:   [dynamic]Tracked_Local,
	by_symbol: map[Symbol_Id]int,
	alloc:     mem.Allocator,
	mode:      Flow_Mode,
	effect_program: ^Prov_Effect_Program,
	effect_depth: int,
	replaying_facts: bool,

	// Nil in lifecycle mode, so a lifecycle walk cannot read what only the
	// provenance walks build.
	using prov: ^Prov_State,
	// Walk state both modes keep.
	// Temporaries ending with the current statement (design.md "Temporaries and
	// procedure boundaries"); alternative branches keep theirs apart.
	temp_roots:     [dynamic]Root_Id,
	// Owned operands held while later operands are evaluated. A moved argument
	// leaves the set on entry to the callee, and `emit_return_cleanups` leaves
	// out discarded temporaries and staged operands while keeping what the
	// returned value depends on.
	held_owners:    [dynamic]Expr,
	// Lifecycle counts temporary providers until their statement boundary;
	// provenance keeps their region tokens in `temp_providers` instead.
	temp_provider_count: int,
	extended_content: map[^Expr_Base][]int,
	// The statement a panic's unwind path leaves from, while
	// `expansion.unwinding` says one is walked; its blocks are marked.
	unwind_at:      Span,
	// The `move`s and `exchange`s whose value becomes a new local or a result,
	// which takes the provider's region with it rather than ending it.
	aliased_moves:    map[rawptr]bool,
	// The content of the error each `or_return` mapper is called with.
	propagated_errors: map[^Expr_Postfix][]int,

	// The statements with statements inside them classified so far
	// (`stmt_cannot_panic`).
	panic_free:     map[^Node_Base]bool,

	k:       ^Checker,
	literal: ^Expr_Proc,
	current: Block_Id,
	// The cleanups of every open scope, in registration order; `scopes` marks
	// where each scope starts. Only `leave_flow_scope` pops them, so an abrupt
	// exit can run a scope's cleanups without ending it.
	in_scope:       [dynamic]Flow_Cleanup,
	scopes:         [dynamic]int,
	// The `defer` body being walked, if any.
	expansion:      Defer_Expansion,
	// Where an abrupt exit lands, and how far down `in_scope` it unwinds.
	break_block:    Block_Id,
	continue_block: Block_Id,
	break_depth:    int,
	continue_depth: int,

	// Lifecycle only, for design.md "Last-use transfer": the locals read while
	// `reads` is set, those an enclosing `foreach` or `switch` holds a borrow
	// of, those ever bound into a borrow-carrying value, and the clones of a
	// whole local that may turn out to be its last use.
	reads:     ^[dynamic]int,
	held:      [dynamic]int,
	lent:      map[int]bool,
	last_uses: [dynamic]Last_Use,
	// design.md "@(require_results)": the writes of a required result, each
	// checked for a read before the next write or the scope's end.
	required:  [dynamic]Required_Write,
}

Required_Write :: struct {
	block:  Block_Id,
	event:  int,
	// The declaration requiring it, or "" when the result type does.
	source: string,
}

// A clone of a local that may allocate, and the `Use` event that reads it: the
// operand and the flag that make it a move instead.
Last_Use :: struct {
	block: Block_Id,
	event: int,
	site:  ^Expr,
	clone: ^bool,
}

NO_BLOCK :: Block_Id(-1)

// Built in the analysis arena, which the caller frees. Lifecycle mode returns
// nil for a body with nothing to track; a provenance mode always builds one.
build_flow_graph :: proc(k: ^Checker, literal: ^Expr_Proc, mode := Flow_Mode.Lifecycle) -> ^Flow_Graph {
	if mode == .Lifecycle || literal == nil || literal.body == nil {
		return build_flow_pass(k, literal, k.c.analysis_allocator, mode)
	}
	graph, _ := build_provenance_replay(k, literal, mode)
	return graph
}

@(private)
new_flow_graph :: proc(k: ^Checker, literal: ^Expr_Proc, allocator: mem.Allocator, mode: Flow_Mode, normalized_input: ^Prov_Input = nil) -> ^Flow_Graph {
	if literal == nil || literal.body == nil {
		return nil
	}
	graph := new(Flow_Graph, allocator)
	graph.k = k
	graph.literal = literal
	graph.alloc = allocator
	graph.mode = mode
	graph.blocks = make([dynamic]^Flow_Block, allocator)
	graph.tracked = make([dynamic]Tracked_Local, allocator)
	graph.by_symbol = make(map[Symbol_Id]int, allocator)
	graph.scopes = make([dynamic]int, allocator)
	graph.in_scope = make([dynamic]Flow_Cleanup, allocator)
	graph.held = make([dynamic]int, allocator)
	graph.lent = make(map[int]bool, allocator)
	graph.last_uses = make([dynamic]Last_Use, allocator)
	graph.required = make([dynamic]Required_Write, allocator)
	graph.temp_roots = make([dynamic]Root_Id, allocator)
	graph.held_owners = make([dynamic]Expr, allocator)
	graph.panic_free = make(map[^Node_Base]bool, allocator)
	graph.extended_content = make(map[^Expr_Base][]int, allocator)
	graph.aliased_moves = make(map[rawptr]bool, allocator)
	graph.propagated_errors = make(map[^Expr_Postfix][]int, allocator)
	if mode != .Lifecycle {
		graph.prov = new_prov_state(allocator, normalized_input != nil ? normalized_input : new_prov_input(allocator))
		if literal.signature != nil {
			params := make([dynamic]Symbol_Id, 0, len(literal.signature.params), allocator)
			for parameter in literal.signature.params {
				append(&params, ..parameter.symbols)
			}
			graph.param_symbols = params[:]
		}
	}
	graph.break_block, graph.continue_block = NO_BLOCK, NO_BLOCK
	graph.current = new_flow_block(graph)

	return graph
}

@(private)
build_flow_pass :: proc(
	k: ^Checker,
	literal: ^Expr_Proc,
	allocator: mem.Allocator,
	mode: Flow_Mode,
	program: ^Prov_Effect_Program = nil,
) -> ^Flow_Graph {
	graph := new_flow_graph(k, literal, allocator, mode)
	if graph == nil { return nil }
	graph.effect_program = program

	// Parameters live in a scope outside the body's, so a `move` parameter's
	// cleanup is the outermost.
	enter_flow_scope(graph)
	if mode == .Lifecycle {
		track_move_parameters(graph, literal)
	} else {
		prov_bind_parameters(graph, literal)
	}
	walk_flow_block(graph, literal.body)
	leave_flow_scope(graph)

	if mode != .Lifecycle {
		return graph
	}
	return len(graph.tracked) == 0 ? nil : graph
}

@(private)
new_flow_block :: proc(graph: ^Flow_Graph) -> Block_Id {
	block := new(Flow_Block, graph.alloc)
	block.events = make([dynamic]Flow_Event, graph.alloc)
	block.preds = make([dynamic]Block_Id, graph.alloc)
	block.succs = make([dynamic]Block_Id, graph.alloc)
	block.prov = make([dynamic]Prov_Event, graph.alloc)
	block.unwind = graph.expansion.unwinding
	block.unwind_at = graph.unwind_at
	append(&graph.blocks, block)
	return Block_Id(len(graph.blocks) - 1)
}

@(private = "file")
link :: proc(graph: ^Flow_Graph, from, to: Block_Id) {
	if from == NO_BLOCK || to == NO_BLOCK {
		return
	}
	append(&graph.blocks[to].preds, from)
	if graph.blocks[to].reach_known {
		// As a loop's head is linked to its back edge (`prov_reaching_offsets`).
		prov_reach_invalidate(graph, to)
	}
	append(&graph.blocks[from].succs, to)
}

// The blocks a fixed point has yet to visit, in the order they were woken, each
// listed once.
@(private)
Block_Queue :: struct {
	queued:  []bool,
	pending: [dynamic]Block_Id,
	head:    int,
}

@(private = "file")
block_queue_make :: proc(graph: ^Flow_Graph) -> Block_Queue {
	return Block_Queue {
		queued = make([]bool, len(graph.blocks), graph.alloc),
		pending = make([dynamic]Block_Id, 0, len(graph.blocks), graph.alloc),
	}
}

// A forward problem starts where the procedure does.
@(private)
block_queue_from_entry :: proc(graph: ^Flow_Graph) -> Block_Queue {
	queue := block_queue_make(graph)
	block_queue_wake(&queue, {Block_Id(0)})
	return queue
}

// A backward problem starts from every block, since any may hold a use.
@(private)
block_queue_last_first :: proc(graph: ^Flow_Graph) -> Block_Queue {
	queue := block_queue_make(graph)
	for index := len(graph.blocks) - 1; index >= 0; index -= 1 {
		block_queue_wake(&queue, {Block_Id(index)})
	}
	return queue
}

@(private)
block_queue_pop :: proc(queue: ^Block_Queue) -> (index: int, ok: bool) {
	if queue.head >= len(queue.pending) {
		return 0, false
	}
	index = int(queue.pending[queue.head])
	queue.head += 1
	queue.queued[index] = false
	return index, true
}

@(private)
block_queue_wake :: proc(queue: ^Block_Queue, blocks: []Block_Id) {
	for block in blocks {
		if !queue.queued[int(block)] {
			queue.queued[int(block)] = true
			append(&queue.pending, block)
		}
	}
}

@(private)
flow_emit :: proc(graph: ^Flow_Graph, event: Flow_Event) {
	if graph.current == NO_BLOCK {
		return // unreachable code carries no obligation
	}
	if graph.reads != nil && event.kind == .Use {
		append(graph.reads, event.slot)
	}
	append(&graph.blocks[graph.current].events, event)
}

// Lifecycle mode: walks `e` and returns the tracked locals it reads.
@(private = "file")
walk_flow_reads :: proc(graph: ^Flow_Graph, e: Expr) -> []int {
	outer := graph.reads
	reads := make([dynamic]int, 0, 4, graph.alloc)
	graph.reads = &reads
	walk_flow_expr(graph, e)
	graph.reads = outer
	if outer != nil {
		append(outer, ..reads[:])
	}
	return reads[:]
}

// Lifecycle mode: walks a value that is stored. One that carries a borrow may
// keep one of any local it reads, so those locals never move at a last use; a
// bare local is copied, not borrowed.
@(private = "file")
walk_flow_stored :: proc(graph: ^Flow_Graph, value: Expr) {
	reads := walk_flow_reads(graph, value)
	if _, is_ident := value.(^Expr_Ident); is_ident {
		return
	}
	if base := expr_base(value); base != nil && type_carries_borrow(graph.k.c, base.type).any {
		for slot in reads {
			graph.lent[slot] = true
		}
	}
}

// Whether a call has somewhere to keep an argument: an `inout` argument or
// receiver, such as the container of an `append`.
@(private = "file")
call_may_store :: proc(c: ^Compiler, v: ^Expr_Call) -> bool {
	info := underlying_info(c, call_proc_type(c, v))
	return info != nil && slice.contains(info.param_modes, Param_Mode.Inout)
}

// Lifecycle mode: walks a value bound into a destination, which is stored, and
// which is a candidate last use when it is a bare local.
@(private = "file")
walk_flow_bound_value :: proc(graph: ^Flow_Graph, value: Expr, decl: ^Decl, assign: ^Stmt_Assign, index: int) {
	walk_flow_stored(graph, value)
	ident, is_ident := value.(^Expr_Ident)
	if !is_ident {
		return
	}
	slot, tracked := graph.by_symbol[ident.symbol]
	if !tracked || graph.current == NO_BLOCK || slice.contains(graph.held[:], slot) {
		return
	}
	events := graph.blocks[graph.current].events
	if len(events) == 0 || events[len(events) - 1].kind != .Use || events[len(events) - 1].slot != slot {
		return
	}
	site, clone := last_use_site(graph, decl, assign, index)
	if clone != nil && clone^ && clone_may_allocate(graph.k.c, copied_type(ident, prov_type(graph, ident))) {
		append(&graph.last_uses, Last_Use{graph.current, len(events) - 1, site, clone})
	}
}

// The operand and clone flag of one bound value, or nil when it cannot become a
// move: a destination with a `via` allocates from it, which a move would not, and
// `x = x` would move the value out of the place it is stored back into.
@(private = "file")
last_use_site :: proc(graph: ^Flow_Graph, decl: ^Decl, assign: ^Stmt_Assign, index: int) -> (site: ^Expr, clone: ^bool) {
	if decl != nil {
		if index < len(decl.value_clones) && decl.via == nil {
			return &decl.values[index], &decl.value_clones[index]
		}
		return nil, nil
	}
	if index >= len(assign.rhs_clones) || index >= len(assign.lhs) {
		return nil, nil
	}
	target := place_root_symbol(assign.lhs[index])
	ident, is_ident := assign.rhs[index].(^Expr_Ident)
	if is_ident && ident.symbol == target || symbol_via_allocator(graph.k.c, target) != nil {
		return nil, nil
	}
	return &assign.rhs[index], &assign.rhs_clones[index]
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

// Every local is followed, since `move` and `drop` kill it; only a managed one is
// cleaned up (design.md "Variable declarations"). A deferred declaration keeps
// one slot across its expansions but registers a cleanup in each.
@(private = "file")
track_local :: proc(graph: ^Flow_Graph, id: Symbol_Id, sym: ^Symbol) -> int {
	slot, tracked := graph.by_symbol[id]
	if !tracked {
		append(&graph.tracked, Tracked_Local{symbol = id})
		slot = len(graph.tracked) - 1
		graph.by_symbol[id] = slot
	}
	if type_is_managed(graph.k.c, sym.type) {
		append(&graph.in_scope, Flow_Cleanup{kind = .Local, slot = slot})
	}
	return slot
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
			if sym := symbol_of(graph.k.c, id); sym != nil {
				slot := track_local(graph, id, sym)
				graph.tracked[slot].live_on_entry, graph.tracked[slot].ever_written = true, true
			}
		}
	}
}

// What is live here drops if a panic comes next. A panic while unwinding aborts.
@(private = "file")
emit_panic_point :: proc(graph: ^Flow_Graph) {
	if graph.mode == .Lifecycle && !graph.expansion.unwinding {
		flow_emit(graph, Flow_Event{kind = .Panic_Point})
	}
}

// Splits off a path that may be skipped: control stays in the branch, and the
// block returned is where the paths rejoin.
@(private = "file")
fork_flow_branch :: proc(graph: ^Flow_Graph) -> Block_Id {
	entry := graph.current
	join := new_flow_block(graph)
	link(graph, entry, join)
	graph.current = new_flow_block(graph)
	link(graph, entry, graph.current)
	return join
}

@(private = "file")
enter_flow_scope :: proc(graph: ^Flow_Graph) {
	append(&graph.scopes, len(graph.in_scope))
}

@(private = "file")
leave_flow_scope :: proc(graph: ^Flow_Graph) {
	cleanups := pop(&graph.scopes)
	emit_cleanups(graph, cleanups, nil)
	resize(&graph.in_scope, cleanups)
}

@(private = "file")
walk_flow_stmts :: proc(graph: ^Flow_Graph, stmts: []Stmt) {
	for stmt in stmts {
		emit_unwind_branch(graph, stmt)
		walk_flow_stmt(graph, stmt, lends = true)
	}
}

// design.md "Panics and unwinding": a panic in a statement runs the cleanups
// registered so far, newest first, as an exit from the procedure does. Only a
// registered `defer` can observe them afterwards, so the path is modeled where
// one is in scope, from the statement's start, which no later state in it can
// make less live; without one, the owners live there need only their drops. A
// statement that cannot panic has no such path.
@(private = "file")
emit_unwind_branch :: proc(graph: ^Flow_Graph, stmt: Stmt) {
	if graph.current == NO_BLOCK || graph.expansion.unwinding {
		return
	}
	// Checked before classifying the statement, which visits all of it.
	deferred, owner := false, false
	for action in graph.in_scope {
		deferred ||= action.kind == .Defer
		owner ||= action.kind == .Local
	}
	if !deferred && !owner || stmt_cannot_panic(graph.k.c, stmt, &graph.panic_free) {
		return
	}
	if owner {
		emit_panic_point(graph)
	}
	if !deferred {
		return
	}
	// The block ends here, so the unwind sees the state before the statement.
	from := graph.current
	outer := graph.expansion
	graph.expansion.unwinding = true
	graph.unwind_at = stmt_span(stmt)
	graph.current = new_flow_block(graph)
	link(graph, from, graph.current)
	emit_cleanups(graph, 0, stmt_base(stmt), unwinding = true)
	graph.expansion = outer
	resume := new_flow_block(graph)
	link(graph, from, resume)
	graph.current = resume
}

// The cleanup walk already popped this registration and everything after it,
// as at runtime, so a diagnosed `return` cannot expand this defer again.
@(private = "file")
emit_deferred :: proc(graph: ^Flow_Graph, action: Flow_Cleanup, exit: rawptr) {
	outer := graph.expansion
	graph.expansion = {action.deferred, exit, outer.unwinding}
	walk_flow_stmt(graph, action.deferred.stmt)
	graph.expansion = outer
}

// How a `return` meets a pending `errdefer` (design.md "defer statement"): one
// that constructs the result's success variant discards it, one that constructs
// the failure variant runs it, and otherwise the tag decides at run time.
@(private = "file")
returned_variant :: proc(graph: ^Flow_Graph, s: ^Stmt_Return) -> (returning, failing: bool) {
	sym := symbol_of(graph.k.c, graph.literal.symbol)
	if s.value == nil || s.value.is_inout || sym == nil {
		return true, false
	}
	selector, is_selector := s.value.expr.(^Expr_Selector)
	if call, is_call := s.value.expr.(^Expr_Call); is_call {
		selector, is_selector = call.callee.(^Expr_Selector)
	}
	if !is_selector || selector.variant_union == INVALID_TYPE || selector.variant_union != sym.result {
		return true, false
	}
	shape, fallible := fallible_of(graph.k.c, sym.result)
	switch {
	case !fallible:
		return true, false
	case selector.variant_index == shape.success:
		return false, false
	case selector.variant_index == shape.failure:
		return false, true
	}
	return true, false
}

// design.md "Temporaries and procedure boundaries" and "or_return operator":
// discarded expression owners end before local cleanup on every return path.
// The result's own dependencies remain in `graph.returning` and its held loans.
@(private = "file")
emit_return_cleanups :: proc(graph: ^Flow_Graph, exit: rawptr, returning := false, failing := false) {
	temporaries, owners := graph.temp_roots, graph.held_owners
	graph.temp_roots = make([dynamic]Root_Id, graph.alloc)
	graph.held_owners = make([dynamic]Expr, graph.alloc)
	defer graph.temp_roots, graph.held_owners = temporaries, owners
	emit_cleanups(graph, 0, exit, returning = returning, failing = failing)
}

// Cleanup events for every registration above `down_to`, innermost first
// (design.md "Managed values and storage"). `exit` is the jump that runs them,
// nil at a scope's end; an `unwinding` exit drops each local only where the
// lifecycle pass found it live.
// An `errdefer` runs on an unwinding or `failing` exit, may run on another
// `returning` one, and is discarded otherwise (design.md "defer statement").
@(private = "file")
emit_cleanups :: proc(
	graph: ^Flow_Graph, down_to: int, exit: rawptr, unwinding := false, returning := false, failing := false,
) {
	// An already-diagnosed exit inside a defer can name a scope deeper than
	// its currently popped stack. It has no registrations left to run.
	if down_to >= len(graph.in_scope) { return }
	// Pop registrations as they run. A reset in an earlier cleanup must not
	// see a temporary owner already dropped by a later registration. Restore
	// the stack afterwards so another control-flow exit can replay it.
	tail := slice.clone(graph.in_scope[down_to:], graph.alloc)
	defer {
		resize(&graph.in_scope, down_to)
		append(&graph.in_scope, ..tail)
	}
	for index := len(tail) - 1; index >= 0; index -= 1 {
		resize(&graph.in_scope, down_to + index)
		action := tail[index]
		switch action.kind {
		case .Defer:
			if action.deferred.on_failure && !unwinding && !failing {
				if !returning {
					continue
				}
				// The result's tag decides at run time, so both paths join.
				merge := fork_flow_branch(graph)
				emit_deferred(graph, action, exit)
				link(graph, graph.current, merge)
				graph.current = merge
				continue
			}
			emit_deferred(graph, action, exit)
		case .Prov_Root:
			root := graph.roots[int(action.root)]
			if root.extended && root.dropped != INVALID_TYPE {
				prov_extended_drop(graph, root, unwinding ? graph.unwind_at : action.span, action.span)
			}
			provider_region_end(graph, root.symbol, action.span, exit)
			if unwinding {
				unwind_drop_effects(graph, root.symbol, graph.unwind_at, exit)
			} else {
				prov_scope_drop_effects(graph, root.symbol, action.span)
			}
			prov_drop_use(graph, root.symbol, action.span, at_scope_exit = true)
			prov_emit(graph, Prov_Event{kind = .Root_End, root = action.root, span = action.span})
		case .Local:
			id := graph.tracked[action.slot].symbol
			sym := symbol_of(graph.k.c, id)
			provider_region_end(graph, id, sym.span, exit)
			if unwinding {
				unwind_drop_effects(graph, id, graph.unwind_at, exit)
			}
			flow_emit(graph, Flow_Event {
				kind = .Cleanup,
				slot = action.slot,
				span = sym.span,
				name = identifier_text(graph.k.c, sym.name),
				unwinding = unwinding,
			})
		}
	}
}

// An unwind drops a local only if it is still live where the panic happens,
// which the lifecycle pass records one pass ahead of provenance. `span` is the
// statement the panic would unwind from.
@(private = "file")
unwind_drop_effects :: proc(graph: ^Flow_Graph, id: Symbol_Id, span: Span, exit: rawptr) {
	sym := symbol_of(graph.k.c, id)
	if sym == nil || sym.kind != .Var || !type_drop_runs_hook(graph.k.c, sym.type) {
		return
	}
	// A view such as a `&` loop element owns nothing, so an unwind drops nothing.
	if sym.borrowed_binding != .None {
		return
	}
	live, provenance := cleanup_reset_point(graph, exit, id, span)
	if !provenance || !live.reached || live.dead {
		return
	}
	prov_drop_effects(graph, sym.type, span, identifier_text(graph.k.c, sym.name), region = prov_symbol_drop_region(graph, id))
}

// A cleanup that may end a region, as one reset point of both walks. The lifecycle
// walk registers it; the provenance walk gets what lifecycle found there.
@(private)
cleanup_reset_point :: proc(
	graph: ^Flow_Graph, node: rawptr, symbol: Symbol_Id, span: Span, location := #caller_location,
) -> (live: Reset_Liveness, provenance: bool) {
	key := reset_key(graph, node, symbol)
	if graph.mode == .Lifecycle {
		graph.k.c.cleanup_reset_dead[key] = {}
		flow_emit(graph, Flow_Event{kind = .Reset_Point, reset = key, span = span})
		return {}, false
	}
	found: bool
	live, found = graph.k.c.cleanup_reset_dead[key]
	assert(found, "the provenance walk reached a cleanup the lifecycle walk did not", location)
	return live, true
}

// The temporaries a statement made end with it: providers first, so an owner
// backed by one is reported, then the temporary roots.
@(private = "file")
end_statement_temporaries :: proc(graph: ^Flow_Graph, mark, providers: int, stmt: Stmt) {
	// These owners finish with the expression, before its providers end. A
	// temporary extended to the block remains in the cleanup stack instead.
	roots := graph.temp_roots[mark:]
	resize(&graph.temp_roots, mark)
	// A temporary provider can end after a declaration has installed its
	// owner. Record that boundary in lifecycle too, after the statement's writes.
	key := reset_key(graph, stmt_base(stmt))
	if graph.mode == .Lifecycle && graph.temp_provider_count > providers {
		graph.k.c.cleanup_reset_dead[key] = {}
		if len(graph.tracked) > 0 {
			flow_emit(graph, Flow_Event{kind = .Reset_Point, span = stmt_span(stmt), reset = key})
		}
		graph.temp_provider_count = providers
	}
	if graph.mode != .Lifecycle && len(graph.temp_providers) > providers {
		live, found := graph.k.c.cleanup_reset_dead[key]
		assert(found, "the provenance walk ended a temporary provider the lifecycle walk did not")
		for index := len(graph.temp_providers) - 1; index >= providers; index -= 1 {
			prov_temp_provider_end(graph, graph.temp_providers[index], live)
		}
		resize(&graph.temp_providers, providers)
	}
	#reverse for root in roots {
		prov_emit(graph, Prov_Event{kind = .Root_End, root = root})
	}
}

// Temporaries end with their statement, but a header's initial statement
// `extend`s them to the whole enclosing statement (design.md "Temporaries and
// procedure boundaries"). A statement that `lends` is one of its block's own, so a local it stores a borrow of a
// temporary into keeps that temporary until the block ends; a `for` update and
// a deferred statement rerun in one scope and lend nothing.
@(private = "file")
walk_flow_stmt :: proc(graph: ^Flow_Graph, stmt: Stmt, extend := false, lends := false) {
	if lends && graph.mode == .Lifecycle {
		mark_extended_temporaries(graph.k.c, stmt)
	}
	mark := len(graph.temp_roots)
	providers := graph.mode == .Lifecycle ? graph.temp_provider_count : len(graph.temp_providers)
	defer if !extend {
		end_statement_temporaries(graph, mark, providers, stmt)
	}
	switch s in stmt {
	case ^Stmt_Error, ^Item_Impl:

	case ^Decl:
		walk_flow_decl(graph, s)

	case ^Stmt_Expr:
		for expr in s.exprs {
			walk_flow_expr(graph, expr)
			prov_discarded_drop_effects(graph, expr)
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
		append(&graph.in_scope, Flow_Cleanup{kind = .Defer, deferred = s})

	case ^Stmt_Return:
		walk_flow_return(graph, s)

	case ^Stmt_Branch:
		if s.kind == .Break {
			emit_cleanups(graph, graph.break_depth, s)
			link(graph, graph.current, graph.break_block)
		} else {
			emit_cleanups(graph, graph.continue_depth, s)
			link(graph, graph.current, graph.continue_block)
		}
		graph.current = NO_BLOCK

	case ^Block:
		walk_flow_block(graph, s)

	case ^Stmt_When:
		if s.selected != nil {
			walk_flow_stmts(graph, s.selected.stmts)
		}

	case ^Stmt_Parallel:
		// The provenance modes check what runs while the block's tasks may.
		if graph.mode != .Lifecycle {
			graph.parallel_depth += 1
			prov_enter_parallel(graph, s)
		}
		walk_flow_block(graph, s.lowered != nil ? s.lowered : s.body)
		if graph.mode != .Lifecycle {
			graph.parallel_depth -= 1
		}

	case ^Stmt_Spawn:
		walk_flow_spawn(graph, s)
	}
}

@(private = "file")
walk_flow_return :: proc(graph: ^Flow_Graph, s: ^Stmt_Return) {
	value := s.value
	if value != nil && !value.is_inout {
		mark_aliased_moves(graph, value.expr)
	}
	returning, failing := returned_variant(graph, s)
	if graph.mode == .Lifecycle {
		if value != nil {
			walk_returned_value(graph, value)
		}
		emit_return_cleanups(graph, s, returning = returning, failing = failing)
		graph.current = NO_BLOCK
		return
	}
	outer := graph.returning
	held: []int
	if value != nil {
		held = prov_return_value(graph, value)
	}
	emit_return_cleanups(graph, s, returning = returning, failing = failing)
	graph.returning = outer
	prov_entry_report_effects(graph, s.span)
	if len(held) > 0 {
		prov_emit(graph, Prov_Event{kind = .Live, sources = held, span = expr_span(value.expr)})
	}
	graph.current = NO_BLOCK
}

// Returning an owned local moves it into the result (design.md "Parameter
// semantics and ABI lowering"). Only a managed local transfers; a scalar is
// copied, so a deferred read still sees it (design.md "defer statement").
@(private = "file")
walk_returned_value :: proc(graph: ^Flow_Graph, value: ^Return_Value) {
	if ident, is_ident := value.expr.(^Expr_Ident); is_ident && !value.clone_on_return &&
	   type_is_managed(graph.k.c, copied_type(ident, prov_type(graph, ident))) {
		if slot, tracked := graph.by_symbol[ident.symbol]; tracked {
			flow_emit(graph, Flow_Event{kind = .Kill, slot = slot, span = ident.span, name = ident.name})
			return
		}
	}
	walk_flow_expr(graph, value.expr)
}

// design.md "Spawn statements": a spawn's arguments are prepared as its
// call's are, and its result local holds a value from the spawn on, which the
// enclosing scope's cleanup drops after the join.
@(private = "file")
walk_flow_spawn :: proc(graph: ^Flow_Graph, s: ^Stmt_Spawn) {
	if graph.mode != .Lifecycle {
		prov_spawn(graph, s)
		return
	}
	walk_flow_expr(graph, s.call)
	if s.result == nil {
		return
	}
	if slot, tracked := graph.by_symbol[s.result.symbol]; tracked {
		flow_emit(graph, Flow_Event{kind = .Spawn_Result, slot = slot, span = s.result.span, name = s.result.name})
	}
}

// The symbol one declared value initializes alone, or `INVALID_SYMBOL` when it
// is destructured or spread over several.
@(private = "file")
decl_value_symbol :: proc(d: ^Decl, index: int) -> Symbol_Id {
	if d.destructure.active || len(d.values) != len(d.symbols) {
		return INVALID_SYMBOL
	}
	return d.symbols[index]
}

// One assigned value, read as a declaration's initializer is: stored into a
// read-only carrier, it is only read.
@(private = "file")
walk_flow_assigned :: proc(graph: ^Flow_Graph, s: ^Stmt_Assign, value: Expr, index: int) -> []int {
	if s.op != .Assign || s.destructure.active || len(s.lhs) != len(s.rhs) || is_discard(s.lhs[index]) {
		return walk_flow_expr(graph, value)
	}
	if target := expr_base(s.lhs[index]); target != nil {
		return prov_walk_stored(graph, value, target.type)
	}
	return walk_flow_expr(graph, value)
}

@(private = "file")
walk_flow_decl :: proc(graph: ^Flow_Graph, d: ^Decl) {
	if d.kind == .Const || d.top_level {
		return
	}
	// A destructured value is split between bindings, so its region cannot follow.
	if !d.destructure.active {
		for value in d.values {
			mark_aliased_moves(graph, value)
		}
	}
	if graph.mode == .Lifecycle {
		walk_flow_decl_lifecycle(graph, d)
	} else {
		walk_flow_decl_provenance(graph, d)
	}
}

@(private = "file")
walk_declared_vias :: proc(graph: ^Flow_Graph, d: ^Decl) {
	for _, index in d.symbols {
		if declaration_evaluates_via(graph.k.c, d, index) {
			walk_flow_expr(graph, d.via)
		}
	}
}

@(private = "file")
walk_flow_decl_provenance :: proc(graph: ^Flow_Graph, d: ^Decl) {
	held := len(graph.held_owners)
	defer resize(&graph.held_owners, held)
	value_loans := make([][]int, len(d.values), graph.alloc)
	for value, index in d.values {
		if sym := symbol_of(graph.k.c, decl_value_symbol(d, index)); sym != nil {
			value_loans[index] = prov_walk_stored(graph, value, sym.type)
		} else {
			value_loans[index] = walk_flow_expr(graph, value)
		}
		prov_hold_owner(graph, value)
	}
	walk_declared_vias(graph, d)
	prov_note_declared_procs(graph, d)
	if d.destructure.active {
		prov_destructure_copy_effects(graph, &d.destructure, d.values[0])
	}
	prov_declare(graph, d, value_loans)
}

@(private = "file")
walk_flow_decl_lifecycle :: proc(graph: ^Flow_Graph, d: ^Decl) {
	for value, index in d.values {
		walk_flow_bound_value(graph, value, d, nil, index)
	}
	walk_declared_vias(graph, d)
	for id, symbol_index in d.symbols {
		sym := symbol_of(graph.k.c, id)
		// Static storage is never dropped automatically (design.md "Values that
		// outlive every scope").
		if sym == nil || sym.kind != .Var || sym.duration != .None {
			continue
		}
		slot := track_local(graph, id, sym)
		// Without an initializer, or with `---`, the local starts dead.
		initializer, written := declared_initializer(d, symbol_index)
		if written && initializer == nil {
			graph.tracked[slot].unchecked = true
		}
		if initializer == nil {
			flow_emit(graph, Flow_Event{kind = .Declare, slot = slot, span = sym.span})
			continue
		}
		flow_emit(graph, Flow_Event {
			kind = .Init,
			slot = slot,
			span = sym.span,
			name = identifier_text(graph.k.c, sym.name),
		})
		note_required_write(graph, id, symbol_index < len(d.values) ? initializer : nil)
	}
}

// design.md "@(require_results)": the write just emitted stores the required
// result of a call. A local never named again is the name check's to report.
@(private = "file")
note_required_write :: proc(graph: ^Flow_Graph, id: Symbol_Id, value: Expr) {
	sym := symbol_of(graph.k.c, id)
	call, is_call := value.(^Expr_Call)
	if sym == nil || !sym.named || graph.current == NO_BLOCK || !is_call || prov_type(graph, call) == INVALID_TYPE {
		return
	}
	if _, built := call.operation.(Call_Union_Construct); built {
		return // `.err(code)` builds a value; no call produced it
	}
	if source, required := required_result_of_call(graph.k, call); required {
		event := len(graph.blocks[graph.current].events) - 1
		append(&graph.required, Required_Write{graph.current, event, source})
	}
}

// Whether the declaration itself evaluates its `via` for one binding, mirroring
// `emit_local_decl`: an eager binding or a clone into the destination. A
// non-empty literal evaluates it as part of the literal.
@(private = "file")
declaration_evaluates_via :: proc(c: ^Compiler, d: ^Decl, index: int) -> bool {
	if d.via == nil || d.destructure.active {
		return false
	}
	sym := symbol_of(c, d.symbols[index])
	if sym == nil || sym.kind != .Var || sym.duration != .None {
		return false
	}
	if index >= len(d.values) || d.values[index] == nil {
		return type_is_container(c, sym.type)
	}
	if index < len(d.value_clones) && d.value_clones[index] {
		return true
	}
	literal, is_literal := d.values[index].(^Expr_Composite)
	return is_literal && len(literal.elements) == 0 && type_is_container(c, sym.type)
}

// One binding's initializer, and whether one was written; a written nil is
// `---`. One value spread over several bindings initializes each.
declared_initializer :: proc(d: ^Decl, symbol_index: int) -> (initializer: Expr, written: bool) {
	if len(d.values) == 0 {
		return nil, false
	}
	if len(d.values) == 1 && len(d.symbols) > 1 {
		return d.values[0], true
	}
	if symbol_index < len(d.values) {
		return d.values[symbol_index], true
	}
	return nil, false
}

@(private = "file")
walk_flow_assign :: proc(graph: ^Flow_Graph, s: ^Stmt_Assign) {
	held := len(graph.held_owners)
	defer resize(&graph.held_owners, held)
	if s.lowered != nil {
		walk_flow_block(graph, s.lowered)
		return
	}
	// A provider moved into a local's storage goes on backing its owners there.
	if s.op == .Assign && !s.destructure.active {
		for target, index in s.lhs {
			if index < len(s.rhs) && provider_place_root(graph, target) != INVALID_SYMBOL {
				mark_aliased_moves(graph, s.rhs[index])
			}
		}
	}
	if graph.mode != .Lifecycle {
		prov_note_assigned_procs(graph, s)
		// design.md "Operator declarations": `operator([]=)` and a direct compound
		// overload are the whole statement, a call like any other.
		if s.place_setter != INVALID_SYMBOL {
			prov_call(graph, prov_synthetic_call(graph, s.place_setter, s.setter_bound, TYPE_VOID, s.op_span, indexes = true))
			return
		}
		if s.operator != INVALID_SYMBOL {
			operands := make([]Expr, 2, graph.alloc)
			operands[0], operands[1] = s.lhs[0], s.rhs[0]
			if s.operator_direct {
				prov_call(graph, prov_synthetic_call(graph, s.operator, operands, TYPE_VOID, s.op_span))
				return
			}
			// The binary operator, then a write of its result.
			result := symbol_of(graph.k.c, s.operator).result
			value_loans := make([][]int, 1, graph.alloc)
			value_loans[0] = prov_call(graph, prov_synthetic_call(graph, s.operator, operands, result, s.op_span))
			prov_assign(graph, s, value_loans)
			return
		}
	}
	value_loans: [][]int
	if graph.mode != .Lifecycle {
		value_loans = make([][]int, len(s.rhs), graph.alloc)
	}
	for value, index in s.rhs {
		if graph.mode == .Lifecycle {
			walk_flow_bound_value(graph, value, nil, s, index)
		} else {
			value_loans[index] = walk_flow_assigned(graph, s, value, index)
			prov_hold_owner(graph, value)
		}
		// A clone allocates through the destination's `via`, evaluated here.
		if index < len(s.rhs_clones) && s.rhs_clones[index] && index < len(s.lhs) {
			walk_flow_expr(graph, symbol_via_allocator(graph.k.c, place_root_symbol(s.lhs[index])))
		}
	}
	if graph.mode != .Lifecycle {
		if s.destructure.active {
			prov_destructure_copy_effects(graph, &s.destructure, s.rhs[0])
		}
		prov_assign(graph, s, value_loans)
		if !s.destructure.active {
			for target, index in s.lhs {
				if is_discard(target) && index < len(s.rhs) {
					prov_discarded_drop_effects(graph, s.rhs[index])
				}
			}
		}
		return
	}
	// design.md "Evaluation order": every destination is prepared before any
	// write. A write through a field or element is a use of its root.
	revived := make([]bool, len(s.lhs), graph.alloc)
	for target, index in s.lhs {
		if s.op == .Assign {
			if ident, is_ident := target.(^Expr_Ident); is_ident {
				if _, tracked := graph.by_symbol[ident.symbol]; tracked {
					revived[index] = true
					continue
				}
			}
			provider_assign_end(graph, target)
		}
		walk_flow_expr(graph, target)
	}
	// Then the writes, in order: a full assignment revives the variable.
	for target, index in s.lhs {
		if !revived[index] {
			continue
		}
		ident := target.(^Expr_Ident)
		provider_assign_end(graph, ident)
		flow_emit(graph, Flow_Event {
			kind   = .Assign,
			slot   = graph.by_symbol[ident.symbol],
			span   = expr_span(target),
			name   = ident.name,
			assign = s,
			target = index,
		})
		note_required_write(graph, ident.symbol, index < len(s.rhs) && len(s.rhs) == len(s.lhs) ? s.rhs[index] : nil)
	}
}

// A header declaration is scoped to the whole statement (design.md "Control-flow
// headers"), as in `emit_if`/`emit_for`/`emit_switch`. The caller closes it with
// `defer leave_flow_scope(graph)`.
@(private = "file")
enter_flow_header_scope :: proc(graph: ^Flow_Graph, init: Stmt) {
	enter_flow_scope(graph)
	if init != nil {
		walk_flow_stmt(graph, init, extend = true, lends = true)
		emit_panic_point(graph) // what the header goes on to evaluate may panic
	}
}

@(private = "file")
walk_flow_if :: proc(graph: ^Flow_Graph, s: ^Stmt_If) {
	enter_flow_header_scope(graph, s.init)
	defer leave_flow_scope(graph)
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
	enter_flow_header_scope(graph, s.init)
	defer leave_flow_scope(graph)
	head := new_flow_block(graph)
	link(graph, graph.current, head)
	graph.current = head
	walk_flow_expr(graph, s.cond)
	// A condition can split into blocks of its own; both edges leave the last.
	tested := graph.current
	done := new_flow_block(graph)
	if s.cond != nil {
		link(graph, tested, done)
	}
	post := new_flow_block(graph)

	body := new_flow_block(graph)
	link(graph, tested, body)
	graph.current = body
	walk_flow_loop_body(graph, s.body, post, done)
	link(graph, graph.current, post)
	graph.current = post
	if s.post != nil {
		walk_flow_stmt(graph, s.post)
	}
	link(graph, graph.current, head)
	graph.current = done
}

@(private = "file")
walk_flow_foreach :: proc(graph: ^Flow_Graph, s: ^Stmt_Foreach) {
	if s.kind == .Static {
		// An expansion is not a loop: its checked copies run in iterable order, and
		// the written body is never checked, so only the copies carry types.
		for copy_block in s.expansion {
			walk_flow_block(graph, copy_block)
		}
		return
	}
	place_loop := foreach_is_place_loop(s)
	iterable := s.iterable
	// The iteration borrows what it reads until the loop ends.
	held := len(graph.held)
	defer resize(&graph.held, held)
	iterated: []int
	if graph.mode == .Lifecycle {
		append(&graph.held, ..walk_flow_reads(graph, iterable))
	} else if ident, plain := prov_plain_slice_local(graph, iterable); plain && !place_loop {
		iterated = prov_read_ident(graph, ident, reads_only = true) // traversed by value
	} else {
		iterated = walk_flow_expr(graph, iterable)
	}
	if graph.mode != .Lifecycle {
		first_read := len(graph.reborrows)
		iterated = prov_reborrow_traversal(graph, iterated, expr_span(s.iterable), place_loop)
		for &reborrow in graph.reborrows[first_read:] {
			reborrow.names_element = place_loop
		}
	}
	// A copied element keeps its own borrows without borrowing the container.
	elements := iterated
	// A diagnostic about what a step reads names what the loop traverses.
	for slot in elements {
		if entry := &graph.prov_slots[slot]; entry.name == "" {
			span := expr_span(iterable)
			entry.name = span_text(graph.k.c, span)
		}
	}
	through: []int
	if graph.mode != .Lifecycle {
		iterated = prov_iterate(graph, s, iterated)
		through = foreach_reborrow_through_carrier(graph, s, place_loop)
		if s.kind == .Protocol {
			prov_iteration_call_effects(graph, s.iter_symbol, expr_span(s.iterable), prov_drop_region(graph, s.iterable))
		}
	}
	// The loop owns a protocol's iterator, dropped however the loop ends.
	drops_iterator := graph.mode != .Lifecycle && s.kind == .Protocol && len(type_drop_hooks(graph.k.c, s.iterator_type)) > 0
	if drops_iterator {
		enter_flow_scope(graph)
		prov_note_iterator_drop(graph, s)
	}
	head := new_flow_block(graph)
	link(graph, graph.current, head)
	done := new_flow_block(graph)
	link(graph, head, done)
	// The iteration reads its source every step, so the loan stays live through
	// the body (design.md "Borrowing iteration"). A by-value step reads its
	// element only when it runs, so the element's own borrows are read on entering the body, not on the way
	// out: a copy of the last element may outlive the loop.
	head_reads, step_reads: []int = iterated, nil
	if !place_loop && len(elements) > 0 {
		outer := make([dynamic]int, 0, len(iterated), graph.alloc)
		for slot in iterated {
			if !slice.contains(elements, slot) {
				append(&outer, slot)
			}
		}
		head_reads, step_reads = outer[:], elements
	}
	graph.current = head
	if len(head_reads) > 0 {
		prov_emit(graph, Prov_Event{
			kind = .Live, sources = head_reads, span = expr_span(s.iterable), revives = true,
		})
	}
	// Each step reads the source through the traversal's reborrow, which a
	// read-only one kept from an earlier step's element does not conflict with.
	if len(through) > 0 {
		prov_emit(graph, Prov_Event{
			kind = .Live, sources = through, span = expr_span(s.iterable), revives = true, reads_only = !place_loop,
		})
	}
	// design.md "Iteration protocol": each step of a protocol loop calls `next`.
	if graph.mode != .Lifecycle && s.kind == .Protocol {
		prov_iteration_call_effects(graph, s.next_symbol, expr_span(s.iterable), prov_drop_region(graph, s.iterable))
	}

	body := new_flow_block(graph)
	link(graph, head, body)
	graph.current = body
	if len(step_reads) > 0 {
		prov_emit(graph, Prov_Event{
			kind = .Live, sources = step_reads, span = expr_span(s.iterable), revives = true,
		})
	}
	if graph.mode != .Lifecycle {
		// A step of a built-in traversal that does not lend its element clones it
		// out of the source. A protocol's `next` hands back what it hands back.
		if s.kind != .Protocol && !s.borrows && !place_loop && s.element_type != INVALID_TYPE {
			prov_copy_effects(graph, s.element_type, expr_span(s.iterable))
		}
		prov_bind_foreach(graph, s, iterated, elements, through)
	}
	// design.md "By-reference iteration": a `&mut` binding's loan ends with its
	// step, and a copied element is a local of its step.
	walk_flow_loop_body(graph, s.body, head, done, s.bindings, place_loop || !s.borrows)
	link(graph, graph.current, head)
	graph.current = done
	if drops_iterator {
		leave_flow_scope(graph)
	}
}

// design.md "Borrowing iteration": the source cannot change while the
// traversal is live. A source reached through a pointer, as `items^`, has no
// root for the iterator loan, so the traversal takes a place loan of it
// instead (`prov_place_loan`), mutable for a place loop: changing the source
// through any pointer naming it, as `items.append(x)` or `p^.append(x)` for
// `p^^`, conflicts until the loop ends.
@(private = "file")
foreach_reborrow_through_carrier :: proc(graph: ^Flow_Graph, s: ^Stmt_Foreach, place_loop: bool) -> []int {
	if s.kind == .Protocol {
		return nil
	}
	source := s.iterable
	// A slice of the source taken in the header, as `p^^[:]`, is a view of
	// the same storage, which the loop keeps reading at each step.
	if view, is_slice := source.(^Expr_Slice); is_slice && view.resolution.kind != .User_Operator {
		source = view.operand
	}
	if type_is_carrier(graph.k.c, prov_type(graph, source)) {
		return nil
	}
	// Only the source is traversed, so another field beside it stays usable.
	carriers, below, through := prov_read_through_carrier(graph, source, reads_only = !place_loop)
	if !through {
		return nil
	}
	if place_loop {
		prov_write_through(graph, carriers, below, expr_span(source), "mutable traversal", source)
	}
	return prov_place_loan(graph, carriers, below, place_loop, "element", source, borrows = true)
}

@(private = "file")
walk_flow_loop_body :: proc(
	graph: ^Flow_Graph, body: ^Block, next, done: Block_Id,
	bindings: []Foreach_Binding = nil, all_step_locals := false,
) {
	outer_break, outer_continue := graph.break_block, graph.continue_block
	outer_break_depth, outer_continue_depth := graph.break_depth, graph.continue_depth
	graph.break_block, graph.continue_block = done, next
	graph.break_depth, graph.continue_depth = len(graph.in_scope), len(graph.in_scope)
	enter_flow_scope(graph)
	if graph.mode != .Lifecycle {
		add_foreach_ref_cleanups(graph, bindings, all_step_locals)
	} else {
		track_owned_foreach_leaves(graph, bindings)
	}
	walk_flow_block(graph, body)
	leave_flow_scope(graph)
	graph.break_block, graph.continue_block = outer_break, outer_continue
	graph.break_depth, graph.continue_depth = outer_break_depth, outer_continue_depth
}

// design.md "Element bindings": an owned leaf is a local of its step, so
// `move` and `drop` end it as they end any local.
@(private = "file")
track_owned_foreach_leaves :: proc(graph: ^Flow_Graph, bindings: []Foreach_Binding) {
	for binding in bindings {
		if len(binding.group) > 0 {
			track_owned_foreach_leaves(graph, binding.group)
			continue
		}
		sym := symbol_of(graph.k.c, binding.symbol)
		if sym != nil && sym.borrowed_binding == .None {
			track_owned_binding(graph, binding.symbol, sym)
		}
	}
}

// An owned binding starts live (design.md "Variable declarations"; see
// `track_local`).
@(private = "file")
track_owned_binding :: proc(graph: ^Flow_Graph, symbol: Symbol_Id, sym: ^Symbol) {
	slot := track_local(graph, symbol, sym)
	flow_emit(graph, Flow_Event {
		kind = .Init,
		slot = slot,
		span = sym.span,
		name = identifier_text(graph.k.c, sym.name),
	})
}

@(private = "file")
add_foreach_ref_cleanups :: proc(graph: ^Flow_Graph, bindings: []Foreach_Binding, all: bool) {
	for binding in bindings {
		if len(binding.group) > 0 {
			add_foreach_ref_cleanups(graph, binding.group, all)
			continue
		}
		// An owned leaf is a local of its step, even beside lent siblings.
		sym := symbol_of(graph.k.c, binding.symbol)
		if sym != nil && (all || binding.is_ref || sym.borrowed_binding == .None) {
			root := prov_root_for_symbol(graph, binding.symbol)
			append(&graph.in_scope, Flow_Cleanup{kind = .Prov_Root, root = root, span = binding.name.span})
		}
	}
}

// A union argument expansion's switch is walked here too: each case's `arm` is
// its value, and the loans the call carries are every arm's (design.md "Union
// argument expansion").
@(private = "file")
walk_flow_switch :: proc(graph: ^Flow_Graph, s: ^Stmt_Switch) -> (carried: []int) {
	enter_flow_header_scope(graph, s.init)
	defer leave_flow_scope(graph)
	// A switch over a temporary consumes it into the case binding; one over a
	// place borrows it, for the whole switch.
	consumes := s.kind != .Value && s.subject != nil &&
		!expression_is_borrowed_place(s.subject)
	held := len(graph.held)
	defer resize(&graph.held, held)
	subject: []int
	if graph.mode == .Lifecycle && s.kind != .Value && !consumes {
		append(&graph.held, ..walk_flow_reads(graph, s.subject))
	} else {
		subject = walk_flow_expr(graph, s.subject)
	}
	merge := new_flow_block(graph)
	bodies := make([]Block_Id, len(s.cases), graph.alloc)
	for _, index in s.cases {
		bodies[index] = new_flow_block(graph)
	}
	if s.kind == .Value {
		// design.md "switch statement": values are tested in order, stopping at the
		// first match, and the default runs only once every test has failed.
		fallback := s.exhaustive ? NO_BLOCK : merge
		for c, index in s.cases {
			if len(c.values) == 0 {
				fallback = bodies[index]
				continue
			}
			for value in c.values {
				walk_flow_expr(graph, value)
				if graph.mode != .Lifecycle && s.subject != nil {
					prov_equality_effects(graph, expr_base(s.subject).type, expr_span(value))
				}
				link(graph, graph.current, bodies[index])
				next := new_flow_block(graph)
				link(graph, graph.current, next)
				graph.current = next
			}
		}
		link(graph, graph.current, fallback)
	} else {
		for _, index in s.cases {
			link(graph, graph.current, bodies[index])
		}
		if !s.exhaustive {
			link(graph, graph.current, merge)
		}
	}
	roots := len(graph.temp_roots)
	arm_roots := make([dynamic]Root_Id, graph.alloc)
	shared_view: Prov_Case_View
	for c, index in s.cases {
		graph.current = bodies[index]
		enter_flow_scope(graph)
		if graph.mode != .Lifecycle {
			// A case that names nothing takes no view of the subject, which was
			// read above: a loan per case is a loan per block, and the solver's
			// tables grow with both.
			if len(c.fields) == 0 && c.binding_symbol != INVALID_SYMBOL {
				prov_bind_case_name(graph, s, c.binding_symbol, c.binding_ref, prov_case_payload(graph, s, c, subject), c.span, consumes, c.variant_indices, &shared_view)
			}
			// design.md "Inspecting a union": each field binding is that field of
			// the payload, borrowed apart from its siblings.
			for field in c.fields {
				if field.symbol == INVALID_SYMBOL {
					continue
				}
				sources := prov_case_field(graph, s, field, subject, c.span)
				prov_bind_case_name(graph, s, field.symbol, field.is_ref, sources, c.span, consumes, c.variant_indices, &shared_view, field.slot)
			}
		} else {
			track_case_binding(graph, c.binding_symbol, consumes)
			for field in c.fields {
				track_case_binding(graph, field.symbol, consumes)
			}
		}
		walk_flow_stmts(graph, c.stmts)
		if c.arm != nil {
			emit_panic_point(graph)
			carried = prov_join(graph, carried, walk_flow_expr(graph, c.arm))
		}
		leave_flow_scope(graph)
		if graph.current != NO_BLOCK { append(&arm_roots, ..graph.temp_roots[roots:]) }
		resize(&graph.temp_roots, roots)
		link(graph, graph.current, merge)
	}
	append(&graph.temp_roots, ..arm_roots[:])
	graph.current = merge
	return
}

// A consuming switch's binding is an ordinary local of its case.
@(private = "file")
track_case_binding :: proc(graph: ^Flow_Graph, symbol: Symbol_Id, consumes: bool) {
	if !consumes || symbol == INVALID_SYMBOL {
		return
	}
	if sym := symbol_of(graph.k.c, symbol); sym != nil {
		track_owned_binding(graph, symbol, sym)
	}
}

// ------------------------------------------------------------ expressions --

// Walks an expression (nil is a no-op) in evaluation order and returns the
// carrier slots holding the loans its value carries.
@(private)
walk_flow_expr :: proc(graph: ^Flow_Graph, e: Expr) -> (carried: []int) {
	assert(!graph.replaying_facts, "fact replay evaluated source syntax")
	prov := graph.mode != .Lifecycle
	if prov {
		prov_note_proc_value(graph, e)
	}
	// An extended temporary keeps what it carries live until its drop, though
	// the borrow extending it may name only a field of it.
	defer if prov {
		if base := expr_base(e); base != nil {
			if base.extended {
				graph.extended_content[base] = carried
			}
			if base.copied_as != INVALID_TYPE {
				prov_copy_of_held_effects(graph, base.copied_as, carried, base.span)
			}
		}
	}
	// design.md "Variadic parameters", "Borrowed callable views": an implicit view
	// borrows the place it came from.
	if prov {
		if expr_base(e) != nil && prov_repr(graph, e).erased_from != INVALID_TYPE {
			return prov_erase(graph, e)
		}
		if expr_base(e) != nil && prov_repr(graph, e).view_from != INVALID_TYPE {
			return prov_owner_view(graph, e)
		}
	}
	switch v in e {
	case ^Expr_Ident:
		if !prov {
			if slot, tracked := graph.by_symbol[v.symbol]; tracked {
				flow_emit(graph, Flow_Event{kind = .Use, slot = slot, span = v.span, name = v.name})
			}
			return nil
		}
		return prov_read_ident(graph, v)

	case ^Expr_Move:
		provider_move_end(graph, v)
		if prov {
			consumed := prov_consume(graph, v.value, v.span, v.implicit ? LAST_USE_VERB : "moved")
			// design.md "Global write effects": a copy last-use transfer made a move
			// still counts, as the program cannot tell which it gets.
			if copied := expr_base(v.value).copied_as; v.implicit && copied != INVALID_TYPE {
				prov_copy_of_held_effects(graph, copied, consumed, v.span)
			}
			return consumed
		}
		// `Kill` alone: it already requires the source live.
		walk_flow_operand(graph, v.value, .Kill, v.span, "moved")

	case ^Expr_Call:
		if v.dispatch != nil {
			return walk_flow_switch(graph, v.dispatch)
		}
		loans := walk_flow_call(graph, v)
		// design.md "Diverging procedures": once its operands are evaluated, a
		// diverging call ends the path, so nothing after it is reached.
		if call_diverges(graph.k.c, v) {
			graph.current = NO_BLOCK
		}
		return loans

	case ^Expr_Binary:
		if prov && v.resolution.kind == .User_Operator {
			return prov_call(graph, prov_operator_call(graph, v))
		}
		walk_flow_expr(graph, v.lhs)
		if v.op == .And_And || v.op == .Or_Or {
			merge := fork_flow_branch(graph)
			walk_flow_expr(graph, v.rhs)
			link(graph, graph.current, merge)
			graph.current = merge
		} else {
			walk_flow_expr(graph, v.rhs)
			if prov {
				prov_operator_effects(graph, v)
				prov_note_fresh_owner(graph, v)
			}
		}

	case ^Expr_Unary:
		if prov && v.op == .Amp {
			return prov_borrow_place(graph, v.operand, v.mutable, v.span, "pointer")
		}
		if prov && v.resolution.kind == .User_Operator {
			return prov_call(graph, prov_operator_call(graph, v))
		}
		walk_flow_expr(graph, v.operand)

	case ^Expr_Postfix:
		if prov && v.op == .Caret {
			return prov_read_deref(graph, v)
		}
		operand_loans := walk_flow_expr(graph, v.operand)
		if v.op == .Or_Return {
			return walk_flow_or_return(graph, v, operand_loans)
		}

	case ^Expr_Selector:
		if prov {
			return prov_read_selector(graph, v)
		}
		walk_flow_expr(graph, v.operand)

	case ^Expr_Index:
		if prov {
			return prov_read_index(graph, v)
		}
		walk_flow_expr(graph, v.operand)
		for index in v.indices {
			walk_flow_expr(graph, index)
		}

	case ^Expr_Slice:
		if prov {
			return prov_slice(graph, v)
		}
		walk_flow_expr(graph, v.operand)
		walk_flow_expr(graph, v.lo)
		walk_flow_expr(graph, v.hi)

	case ^Expr_Composite:
		held := len(graph.held_owners)
		defer resize(&graph.held_owners, held)
		// A non-empty container literal evaluates its destination's `via` first.
		if len(v.elements) > 0 {
			walk_flow_expr(graph, v.via)
			if prov && type_is_container(graph.k.c, prov_type(graph, v)) {
				prov_note_fresh_owner(graph, v, v.via)
			}
		}
		if prov {
			if prov_repr(graph, v).backing != INVALID_TYPE {
				return prov_slice_literal(graph, v, carrier_is_mutable(graph.k.c, prov_type(graph, v)))
			}
			if content := prov_temp_content(graph, prov_type(graph, v)); len(content) > 0 {
				return prov_composite_content(graph, v, content, prov_type(graph, v))
			}
		}
		is_map := underlying_kind(graph.k.c, prov_type(graph, v)) == .Map
		for element, index in v.elements {
			if is_map {
				walk_flow_expr(graph, element.key)
				if prov { prov_hold_owner(graph, element.key) }
			}
			loans := walk_flow_expr(graph, element.value)
			if prov {
				prov_hold_owner(graph, element.value)
				prov_repeated_element_effects(graph, v, prov_type(graph, v), index, loans)
			}
		}
		if prov && is_map && len(v.elements) > 0 {
			prov_key_effects(graph, prov_type(graph, v), v.span)
		}

	case ^Expr_Cond:
		walk_flow_expr(graph, v.cond)
		roots, cleanups := len(graph.temp_roots), len(graph.in_scope)
		entry := graph.current
		merge := new_flow_block(graph)
		graph.current = new_flow_block(graph)
		link(graph, entry, graph.current)
		then_loans := walk_flow_expr(graph, v.then)
		then_reaches := graph.current != NO_BLOCK
		then_roots: []Root_Id
		then_cleanups: []Flow_Cleanup
		if then_reaches {
			then_roots = slice.clone(graph.temp_roots[roots:], graph.alloc)
			then_cleanups = slice.clone(graph.in_scope[cleanups:], graph.alloc)
		}
		resize(&graph.temp_roots, roots)
		resize(&graph.in_scope, cleanups)
		link(graph, graph.current, merge)
		graph.current = new_flow_block(graph)
		link(graph, entry, graph.current)
		else_loans := walk_flow_expr(graph, v.otherwise)
		else_reaches := graph.current != NO_BLOCK
		if !else_reaches {
			resize(&graph.temp_roots, roots)
			resize(&graph.in_scope, cleanups)
		}
		append(&graph.temp_roots, ..then_roots)
		append(&graph.in_scope, ..then_cleanups)
		link(graph, graph.current, merge)
		graph.current = then_reaches || else_reaches ? merge : NO_BLOCK
		return prov_join(graph, then_loans, else_loans)

	case ^Expr_Propagated_Error:
		// A fresh value: moved out of a temporary, or copied out of a place.
		return graph.propagated_errors[v.owner]

	case ^Expr_Or_Else:
		value_loans := walk_flow_expr(graph, v.value)
		// design.md "or_else expression": the failure leaves through its exit,
		// which runs the cleanups the statement would, and only success resumes.
		if v.exit != nil {
			resume := fork_flow_branch(graph)
			walk_flow_stmt(graph, v.exit)
			graph.current = resume
			return prov_payload_content(graph, value_loans, prov_type(graph, v.value), prov_type(graph, v), v.span)
		}
		merge := fork_flow_branch(graph)
		fallback_loans := walk_flow_expr(graph, v.fallback)
		link(graph, graph.current, merge)
		graph.current = merge
		payload := prov_payload_content(graph, value_loans, prov_type(graph, v.value), prov_type(graph, v), v.span)
		return prov_join(graph, payload, fallback_loans)

	case ^Expr_Range:
		walk_flow_expr(graph, v.lo)
		walk_flow_expr(graph, v.hi)

	case ^Expr_Literal, ^Expr_Proc, ^Expr_Proc_Group, ^Expr_Operator,
	     ^Expr_Error,
	     ^Type_Pointer, ^Type_C_Pointer, ^Type_Slice, ^Type_Dynamic_Array,
	     ^Type_Array, ^Type_Map, ^Type_Distinct, ^Type_Dyn, ^Type_Type,
	     ^Type_Poly, ^Type_Proc, ^Type_Record, ^Type_Anon_Record, ^Type_Anon_Union, ^Type_Enum, ^Type_Interface:
	}
	return nil
}

// design.md "or_return operator": a failure operand leaves through its `return`,
// as an `or_else` exit does; a mapper's error carries the operand's failure
// content. The success payload carries the operand's loans and regions.
@(private = "file")
walk_flow_or_return :: proc(graph: ^Flow_Graph, v: ^Expr_Postfix, operand_loans: []int) -> []int {
	prov := graph.mode != .Lifecycle
	resume := fork_flow_branch(graph)
	if v.failure_exit != nil {
		shape, _ := fallible_of(graph.k.c, prov_type(graph, v.operand))
		if prov && v.failure_maps {
			graph.propagated_errors[v] = prov_payload_content(
				graph, operand_loans, prov_type(graph, v.operand), shape.failure_type, v.span,
			)
		} else if prov && !v.borrows {
			// A replacement drops a temporary's error before it runs.
			prov_drop_effects(graph, shape.failure_type, v.op_span, "the replaced error", unnamed = true)
		}
		walk_flow_stmt(graph, v.failure_exit)
	} else if prov {
		outer := graph.returning
		held := prov_or_return_escape(graph, v, operand_loans)
		emit_return_cleanups(graph, v, failing = true)
		graph.returning = outer
		prov_entry_report_effects(graph, v.span)
		if len(held) > 0 {
			prov_emit(graph, Prov_Event{kind = .Live, sources = held, span = v.span})
		}
	} else {
		emit_return_cleanups(graph, v, failing = true)
	}
	graph.current = resume
	return prov_payload_content(graph, operand_loans, prov_type(graph, v.operand), prov_type(graph, v), v.span)
}

@(private = "file")
walk_flow_operand :: proc(graph: ^Flow_Graph, operand: Expr, kind: Flow_Event_Kind, span: Span, verb: string) {
	if ident, is_ident := operand.(^Expr_Ident); is_ident {
		if slot, tracked := graph.by_symbol[ident.symbol]; tracked {
			flow_emit(graph, Flow_Event{kind = kind, slot = slot, span = span, name = ident.name, verb = verb})
			return
		}
	}
	walk_flow_expr(graph, operand)
}

// design.md "Evaluation order": a method or `dyn` slot receiver is evaluated
// once, as `bound[0]`, though it is also the callee's operand. A walk takes it
// as the argument alone, so `move(value).method()` kills its source once.
call_receiver_is_bound :: proc(c: ^Compiler, v: ^Expr_Call) -> bool {
	if len(v.bound) == 0 {
		return false
	}
	if _, slot := v.operation.(Call_Dyn_Slot); slot {
		return true
	}
	sym := symbol_of(c, v.resolution.chosen_overload)
	return sym != nil && sym.has_receiver
}

@(private = "file")
walk_flow_call :: proc(graph: ^Flow_Graph, v: ^Expr_Call) -> []int {
	#partial switch operation in v.operation {
	case Call_Enum_From_Int:
		walk_flow_expr(graph, v.bound[0])
		return nil
	case Call_Box_Unbox:
		// The payload carries what the consumed box carried below its one step.
		loans := walk_flow_expr(graph, v.bound[0])
		if graph.mode == .Lifecycle {
			return nil
		}
		return prov_project_content(graph, loans, prov_type(graph, v.bound[0]), {proj_wild()}, prov_type(graph, v), v.span)
	case Call_Union_As:
		// Both unions keep their payloads below one wildcard.
		loans := walk_flow_expr(graph, v.bound[0])
		if graph.mode == .Lifecycle {
			return nil
		}
		// It clones the payload out.
		prov_copy_effects(graph, union_variant_payload(graph.k.c, prov_type(graph, v.bound[0]), operation.index), v.span)
		return prov_project_content(graph, loans, prov_type(graph, v.bound[0]), nil, prov_type(graph, v), v.span)
	case Call_Union_Construct:
		loans: []int
		if len(v.bound) == 1 {
			loans = walk_flow_expr(graph, v.bound[0])
		}
		return graph.mode == .Lifecycle ? nil : prov_variant_content(graph, v, loans)
	case Call_Reflect:
		// `field.get(value)` reads the place `field.pointer(value)^`.
		if operation.op == .Field_Get {
			carriers := walk_flow_expr(graph, v.bound[0])
			return graph.mode == .Lifecycle ? nil : prov_load_content(graph, carriers, nil, prov_type(graph, v), v.span)
		}
	}
	builtin := Builtin_Kind.None
	if sym := symbol_of(graph.k.c, v.resolution.symbol); sym != nil && sym.kind == .Builtin {
		builtin = sym.builtin
	}
	#partial switch builtin {
	// Unevaluated operands read nothing (design.md "Variable declarations").
	case .Size_Of, .Align_Of, .Offset_Of, .Is_Copyable, .Is_Union, .Type_Of, .Source_Location:
		return nil
	}
	provider_container_moves(graph, v)
	if graph.mode == .Lifecycle && call_provider_op(graph.k.c, v) == .Handle &&
	   len(v.bound) > 0 && prov_expr_is_temporary(v.bound[0]) {
		graph.temp_provider_count += 1
	}
	if graph.mode != .Lifecycle {
		out := prov_call(graph, v)
		provider_container_end(graph, v)
		prov_container_drop_effects(graph, v)
		return out
	}
	#partial switch builtin {
	case .Exchange:
		// The destination must be live and stays live (design.md "Exchange").
		if len(v.bound) == 2 {
			provider_exchange_end(graph, v)
			walk_flow_operand(graph, v.bound[0], .Use, v.span, "exchanged")
			walk_flow_expr(graph, v.bound[1])
		}
		return nil
	case .Unsafe_Take, .Unsafe_Write:
		for bound in v.bound {
			walk_flow_expr(graph, bound)
		}
		return nil
	case .Drop:
		if len(v.bound) == 1 {
			provider_drop_end(graph, v)
			walk_flow_operand(graph, v.bound[0], .Kill, v.span, "dropped")
		}
		return nil
	}
	if !call_receiver_is_bound(graph.k.c, v) {
		walk_flow_expr(graph, v.callee)
	}
	stores := call_may_store(graph.k.c, v)
	for step in 0 ..< len(v.bound) {
		index := call_slot_at(v, step)
		if v.is_variadic && index == v.variadic_slot && !v.variadic_forwards {
			walk_variadic_pack(graph, v, stores)
		} else if stores {
			walk_flow_stored(graph, v.bound[index])
		} else {
			walk_flow_expr(graph, v.bound[index])
		}
	}
	if len(v.bound) == 0 {
		for argument in v.args {
			walk_flow_expr(graph, argument.value)
		}
	}
	provider_container_end(graph, v)
	note_reset_point(graph, v)
	return nil
}

// An unforwarded variadic pack's operands in written order.
@(private = "file")
walk_variadic_pack :: proc(graph: ^Flow_Graph, v: ^Expr_Call, stores: bool) {
	cursor: Call_Pack_Cursor
	for operand in call_pack_next(v, &cursor) {
		if stores {
			walk_flow_stored(graph, operand)
		} else {
			walk_flow_expr(graph, operand)
		}
	}
}

// The next argument a call passes to an `@(allocator_reset)` parameter. A walk
// that acts on these needs the reset point `call_is_reset` has it note.
@(private)
call_reset_arguments :: proc(c: ^Compiler, v: ^Expr_Call, cursor: ^int) -> (argument: Expr, more: bool) {
	proc_type := call_proc_type(c, v)
	for cursor^ < len(v.bound) {
		index := cursor^
		cursor^ += 1
		if v.bound[index] != nil && proc_param_resets(c, proc_type, index) {
			return v.bound[index], true
		}
	}
	return nil, false
}

// `free_all`, or an argument to an `@(allocator_reset)` parameter.
@(private = "file")
call_is_reset :: proc(c: ^Compiler, v: ^Expr_Call) -> bool {
	if sym := symbol_of(c, v.resolution.symbol); sym != nil && sym.builtin == .Free_All {
		return true
	}
	cursor := 0
	_, resets := call_reset_arguments(c, v, &cursor)
	return resets
}

// After the arguments, which may themselves move an owner out.
@(private = "file")
note_reset_point :: proc(graph: ^Flow_Graph, v: ^Expr_Call) {
	if !call_is_reset(graph.k.c, v) {
		return
	}
	key := reset_key(graph, v)
	graph.k.c.reset_dead[key] = {}
	if len(graph.tracked) > 0 {
		flow_emit(graph, Flow_Event{kind = .Reset_Point, span = v.span, reset = key, call = v})
	}
}

// ------------------------------------------------------------ last uses --

// The verb a borrow diagnostic uses for a move the program did not write.
LAST_USE_VERB :: "moved by its last use"

// design.md "Last-use transfer": a clone of a whole local that no path reads
// again becomes a move of it, unless something may still borrow it. A read is
// a use, a move, or a drop; a new value ends the old one's reads. The events
// stay in place, with the move's `Kill` where its `Use` was, so the forward
// solve that follows sees the local end there.
settle_last_uses :: proc(graph: ^Flow_Graph) {
	if !committing(graph.k.c) {
		return
	}
	if len(graph.required) > 0 {
		report_unread_required(graph)
	}
	if len(graph.last_uses) > 0 {
		transfer_last_uses(graph)
	}
}

// design.md "@(require_results)": a required result no path reads before it
// is overwritten or leaves scope was dropped unseen. One lent elsewhere may
// be read through the borrow. What an unwind's deferred statements read keeps
// no result from going unread, and unreachable code has no obligation.
@(private = "file")
report_unread_required :: proc(graph: ^Flow_Graph) {
	rows := solve_reads(graph, through_unwind = false)
	reached := flow_reachable(graph)
	reads := make([]u64, rows.words, graph.alloc)
	for write in graph.required {
		if !reached[write.block] {
			continue
		}
		event := graph.blocks[write.block].events[write.event]
		reads_at_exit(graph, rows, write.block, reads)
		reads_before(graph.blocks[write.block].events[:], write.event + 1, reads)
		if reads_get(reads, event.slot) || graph.lent[event.slot] {
			continue
		}
		what := write.source != "" ? concat(graph.k.c, "the result of `", write.source, "`") : "the result of this call"
		errorf(
			graph.k.c, event.span, "L0698",
			"%s stored in `%s` is never read before it is overwritten or goes out of scope: inspect it, or discard it with `_ = ...`",
			what, event.name,
		)
	}
}

// A deferred copy is one node at every exit it expands at, so it becomes a
// move only when no expansion's source is read again, on an unwind or otherwise.
@(private = "file")
transfer_last_uses :: proc(graph: ^Flow_Graph) {
	rows := solve_reads(graph, through_unwind = true)
	reads := make([]u64, rows.words, graph.alloc)
	kept := make(map[^bool]bool, allocator = graph.alloc)
	for use in graph.last_uses {
		event := graph.blocks[use.block].events[use.event]
		reads_at_exit(graph, rows, use.block, reads)
		reads_before(graph.blocks[use.block].events[:], use.event + 1, reads)
		if graph.lent[event.slot] || reads_get(reads, event.slot) {
			kept[use.clone] = true
		}
	}
	for use in graph.last_uses {
		if use.clone in kept {
			continue
		}
		// The verb stays the copy's, so a liveness error reads as the use written.
		graph.blocks[use.block].events[use.event].kind = .Kill
		// An earlier expansion may already have made it a move.
		if use.clone^ {
			use.clone^ = false
			ident := use.site^.(^Expr_Ident)
			moved := new(Expr_Move, graph.k.c.semantic_allocator)
			moved.span, moved.type, moved.value_category = ident.span, ident.type, .Value
			moved.value = ident
			moved.implicit = true
			use.site^ = moved
		}
	}
}

// Per block, the locals its code and successors may read, packed one row of
// `words` per block.
@(private = "file")
Read_Rows :: struct {
	bits:           []u64,
	words:          int,
	through_unwind: bool,
}

@(private = "file")
read_row :: proc(rows: Read_Rows, block: Block_Id) -> []u64 {
	return rows.bits[int(block) * rows.words:][:rows.words]
}

@(private = "file")
reads_get :: proc(row: []u64, slot: int) -> bool {
	return row[slot / 64] & (u64(1) << uint(slot % 64)) != 0
}

// Backward to a fixed point: reads only grow, so this stops.
@(private = "file")
solve_reads :: proc(graph: ^Flow_Graph, through_unwind: bool) -> Read_Rows {
	rows := Read_Rows{words = (len(graph.tracked) + 63) / 64, through_unwind = through_unwind}
	rows.bits = make([]u64, rows.words * len(graph.blocks), graph.alloc)
	reads := make([]u64, rows.words, graph.alloc)
	for changed := true; changed; {
		changed = false
		for index := len(graph.blocks) - 1; index >= 0; index -= 1 {
			reads_at_exit(graph, rows, Block_Id(index), reads)
			reads_before(graph.blocks[index].events[:], 0, reads)
			if row := read_row(rows, Block_Id(index)); !slice.equal(reads, row) {
				copy(row, reads)
				changed = true
			}
		}
	}
	return rows
}

// Which locals a block's successors may read.
@(private = "file")
reads_at_exit :: proc(graph: ^Flow_Graph, rows: Read_Rows, block: Block_Id, reads: []u64) {
	slice.zero(reads)
	for successor in graph.blocks[int(block)].succs {
		if !rows.through_unwind && graph.blocks[int(successor)].unwind && !graph.blocks[int(block)].unwind {
			continue
		}
		for word, at in read_row(rows, successor) {
			reads[at] |= word
		}
	}
}

@(private = "file")
reads_before :: proc(events: []Flow_Event, from: int, reads: []u64) {
	for index := len(events) - 1; index >= from; index -= 1 {
		event := events[index]
		bit := u64(1) << uint(event.slot % 64)
		#partial switch event.kind {
		case .Use, .Kill:
			reads[event.slot / 64] |= bit
		case .Init, .Assign, .Spawn_Result, .Declare:
			reads[event.slot / 64] &~= bit
		}
	}
}

// The blocks some path from the procedure's entry reaches.
@(private)
flow_reachable :: proc(graph: ^Flow_Graph) -> []bool {
	reached := make([]bool, len(graph.blocks), graph.alloc)
	pending := make([dynamic]Block_Id, 0, len(graph.blocks), graph.alloc)
	reached[0] = true
	append(&pending, Block_Id(0))
	for len(pending) > 0 {
		for successor in graph.blocks[int(pop(&pending))].succs {
			if !reached[successor] {
				reached[successor] = true
				append(&pending, successor)
			}
		}
	}
	return reached
}

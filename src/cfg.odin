// A disposable per-procedure control-flow view.
//
// Blocks reference the typed AST rather than replacing it: this is a lightweight
// analysis view, not MIR: the backend receives annotated AST, and a real MIR is
// deferred past v1.
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

import "core:fmt"
import "core:mem"
import "core:slice"

Block_Id :: distinct int

// One walk, three jobs. Only the lifecycle mode is allowed to do semantic work:
// the provenance modes rebuild the same block topology read-only, so replaying
// copy classification, copy-cost reports, lifecycle-member contribution, cleanup
// slots or annotation writes cannot duplicate a diagnostic or disturb a settled
// annotation.
Flow_Mode :: enum u8 {
	Lifecycle,
	Prov_Summary,
	Prov_Diagnose,
}

Flow_Event_Kind :: enum {
	Init,
	// A full assignment: like `Init`, but the destination's state *before* it is
	// what decides whether the previous value has to be dropped, so the event
	// carries the node that answer is written back to.
	Assign,
	Kill,
	Use,
	Cleanup,
	// An allocator-region reset, noted only so the *later* provenance pass can
	// ask which owners were definitely dead at it. An explicitly dropped manual
	// owner no longer blocks a reset (design.md). The two passes run over
	// separate graphs, so the answer is recorded against the call node both of
	// them walk.
	Reset_Point,
}

Flow_Event :: struct {
	kind:   Flow_Event_Kind,
	slot:   int,
	span:   Span,
	name:   string,
	assign: ^Stmt_Assign,
	target: int,
	// `Reset_Point`: the call whose liveness answer is being recorded.
	call:   ^Expr_Call,
	// The operation being attempted at this event, so a diagnostic can name what
	// the reader wrote. Which earlier operation consumed the binding is not
	// tracked: the states are a lattice, not a history.
	verb:   string,
}

Flow_Block :: struct {
	events: [dynamic]Flow_Event,
	preds:  [dynamic]Block_Id,
	succs:  [dynamic]Block_Id,
	// Filled by `src/lifecycle.odin`'s solver.
	entry_state: []Liveness,
	exit_state:  []Liveness,
	visited:     bool,

	// Provenance modes. `src/borrow.odin` solves reaching loans forwards and
	// carrier liveness backwards over these same blocks. The reaching component
	// is `slots * loans` bits and is the one that multiplies, so it is packed:
	// one row of `ceil(loans / 8)` bytes per slot.
	prov:          [dynamic]Prov_Event,
	reach_entry:   []u8,
	reach_exit:    []u8,
	invalid_entry: []bool,
	invalid_exit:  []bool,
	live_entry:    []bool,
	live_exit:     []bool,
	use_entry:     []Span,
	use_exit:      []Span,
	prov_visited:  bool,
}

// ------------------------------------------------------ provenance events --

// The event vocabulary the root and region lattices read. It is deliberately
// separate from the lifecycle events above: the two analyses share the block
// topology and the source order, not the facts they record.
Prov_Kind :: enum u8 {
	// A carrier slot receives a value: the union of its source slots plus one
	// freshly created loan.
	Def,
	// A carrier slot is read. This is what makes a loan live to its last use.
	Live,
	// Storage is reached through a name that is not a live borrow of it.
	Access,
	// A root's storage ends, so every loan of it does too.
	Root_End,
	// A value leaves the body through `return`.
	Escape,
	// `free`, which needs an allocation base and ends that allocation root.
	Free,
	// A borrow is stored where it outlives the statement that stored it: in
	// process or thread storage, or in storage the caller owns
	// (consolidation-provenance-plan.md step 8). `retain` says which.
	Retain,
	// An allocator region reset: `free_all`, or a call through a parameter marked
	// `@(allocator_reset)`.
	Reset,
	// An owner backed by a received allocator region is stored somewhere that
	// outlives that region.
	Region_Escape,
	// A value is written into whatever a carrier points at: `p^.view = values`,
	// or an argument the callee may keep. Which storage that is depends on the
	// carrier's own loans, so unlike `Def` the destination slots are resolved
	// while solving. It joins rather than replaces, because the carrier may name
	// more than one root and the write reaches only one of them.
	Publish,
}

// design.md "Capabilities and the one rule". A read is compatible with a
// read-only borrow; a write is not; an invalidation ends the borrowed value
// outright.
Access_Kind :: enum u8 {
	Read,
	Write,
	Invalidate,
}

Prov_Event :: struct {
	kind:    Prov_Kind,
	span:    Span,
	slot:    int,
	loan:    Loan_Id,
	sources: []int,
	root:    Root_Id,
	path:    []Proj_Step,
	access:  Access_Kind,
	verb:    string,
	name:    string,
	// `Retain`: what kind of storage the destination is. `name` is how a
	// diagnostic spells it and `verb` names the destination.
	retain: Retain_Kind,
	// `Retain`: the carrier the destination was written through, when the place
	// left lexical storage — `p^.view`, `d[0].view`, a `^mut` argument. Its
	// reaching loans name the destination roots, which only the solver knows, so
	// `retain` and `root` are answered there instead of here.
	into: []int,
	// `Escape`: which result of the enclosing procedure this value becomes, and
	// the allocator region an owning result carries with it.
	result:  int,
	region:  Region_Set,
	// `Reset`: whether the promise this reset needs is already written. `access`
	// selects the form -- `Invalidate` for a direct `free_all`, `Write` for a
	// call that hands one of this body's allocator parameters onward.
	reset_covered: bool,
	owner_span:    Span,
	// `Live`: this use re-establishes the loans it names rather than merely
	// keeping them alive. A loop head re-reads its iterable once per iteration,
	// so an invalidation recorded in the body must not travel the back edge and
	// make the next iteration's iterator look already dead.
	revives:       bool,
}

// A borrowed parameter arrives holding the caller's storage, which the entry
// block installs before the first statement.
Prov_Entry_Def :: struct {
	slot: int,
	loan: Loan_Id,
}

// One result position of a call. Expression walking still returns the first
// result for ordinary single-value contexts, while declarations, assignments,
// and returns that explicitly expand a multi-result call select their matching
// entry here.
Prov_Call_Result :: struct {
	loans:  []int,
	region: Region_Set,
}

Flow_Cleanup_Kind :: enum {
	Local,
	Defer,
	// A provenance root whose storage ends when its scope does.
	Prov_Root,
	// A region-backed owner leaving scope, so a later reset no longer has to
	// treat it as a surviving dependant.
	Prov_Owner,
}

// One registration in the unified cleanup order. Locals and written defers
// must be kept in one list: a deferred read is valid only when every local it
// names is still live at the exact point that registration executes.
Flow_Cleanup :: struct {
	kind: Flow_Cleanup_Kind,
	slot: int,
	stmt: Stmt,
	root: Root_Id,
	span: Span,
}

// One managed local the lifecycle analysis follows. An allocation root is not
// one of them: design.md makes the pointer `new` returns manual, and root
// provenance in `src/borrow.odin` is what decides whether `free` may have it.
Tracked_Local :: struct {
	symbol: Symbol_Id,
	scope:  int,
	// Whether scope exit is responsible for this slot. False for an allocation
	// root: it is released explicitly or not at all.
	owns_cleanup: bool,
	// A `move` parameter arrives owned, so it is live before the first statement
	// rather than at a declaration inside the body.
	live_on_entry: bool,
	// Filled while reporting: whether this local ever reaches a cleanup point,
	// and in which states. `conditional_assign` records the other place a hidden
	// flag can be needed — an assignment whose destination is live on one path
	// and dead on another.
	seen_cleanup:       bool,
	live_exit:          bool,
	dead_exit:          bool,
	conditional_assign: bool,
}

Flow_Graph :: struct {
	blocks:  [dynamic]^Flow_Block,
	tracked: [dynamic]Tracked_Local,
	by_symbol: map[Symbol_Id]int,
	alloc:   mem.Allocator,
	mode:    Flow_Mode,

	// Provenance modes only.
	roots:          [dynamic]Prov_Root,
	loans:          [dynamic]Prov_Loan,
	prov_slots:     [dynamic]Prov_Slot,
	reborrows:      [dynamic]Prov_Reborrow,
	entry_defs:     [dynamic]Prov_Entry_Def,
	root_by_symbol: map[Symbol_Id]Root_Id,
	slot_by_symbol: map[Symbol_Id]int,
	// One slot per `carrier_shape` path, for a local whose type is not itself a
	// carrier but can hold one inside it (consolidation-provenance-plan.md
	// step 5). Ordered by the shape, so two values of one type pair by index.
	content_by_symbol: map[Symbol_Id][]int,
	call_results:   map[^Expr_Call][]Prov_Call_Result,
	// Direct callees whose result summaries this graph reads. Populated only in
	// summary mode and copied into compilation metadata before the graph dies.
	summary_callees: [dynamic]Symbol_Id,
	// A value temporary lives until the end of its complete expression
	// (design.md), extended to the complete statement inside a `foreach`
	// iterable, a `switch` subject, or an `if`/`for`/`switch` initial statement.
	// One list per statement is exactly that boundary.
	temp_roots:     [dynamic]Root_Id,
	// design.md "Allocator regions and region provenance". One entry per
	// allocator binding and per region-backed owner; `owners_in_scope` is what a
	// reset has to answer "would this owner survive it" against.
	region_of:       map[Symbol_Id]Region_Set,
	// A provider owns its own region, but provider-backed construction also makes
	// it depend on the parent allocator until the child is dropped. Keeping that
	// edge separate avoids confusing `child.allocator()` with the parent region.
	provider_parents: map[Symbol_Id]Region_Set,
	owners_in_scope: [dynamic]Symbol_Id,
	param_count:     int,
	// One bit per local `mem.Arena`/`mem.Scratch` in this body. The list is what
	// a diagnostic names the region by.
	provider_bits:    map[Symbol_Id]u64,
	provider_symbols: [dynamic]Symbol_Id,
	// A body may borrow nothing at all and still reset a region or let an owner
	// escape one, so the region half has its own reason to run the solver.
	has_region_event: bool,

	k:       ^Checker,
	literal: ^Expr_Proc,
	current: Block_Id,
	// A slot in `tracked` is permanent: it names one declaration's state for the
	// whole analysis. What comes and goes is scope membership, so that is a
	// separate stack of slots in declaration order, with `scopes` holding one
	// marker into it per open lexical scope. Leaving a scope cleans up exactly
	// the slots above its marker and then forgets them.
	in_scope: [dynamic]Flow_Cleanup,
	scopes:   [dynamic]int,
	// How many loops enclose the statement being walked, so the copy-cost report
	// can say that a copy runs on every iteration.
	loop_depth: int,
	// Where an abrupt exit lands, and how far down `in_scope` it unwinds.
	break_block:    Block_Id,
	continue_block: Block_Id,
	break_depth:    int,
	continue_depth: int,
}

NO_BLOCK :: Block_Id(-1)

// In lifecycle mode, nil when the body has nothing to track, which is the
// ordinary case and saves every unmanaged procedure a graph. A provenance mode
// always builds one: design.md's one rule applies to a body whose every local is
// trivial just as much as to a managed one.
build_flow_graph :: proc(
	k: ^Checker,
	literal: ^Expr_Proc,
	allocator: mem.Allocator,
	mode := Flow_Mode.Lifecycle,
) -> ^Flow_Graph {
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
	graph.by_symbol = make(map[Symbol_Id]int, 8, allocator)
	graph.scopes = make([dynamic]int, allocator)
	graph.in_scope = make([dynamic]Flow_Cleanup, allocator)
	graph.roots = make([dynamic]Prov_Root, allocator)
	graph.loans = make([dynamic]Prov_Loan, allocator)
	graph.prov_slots = make([dynamic]Prov_Slot, allocator)
	graph.entry_defs = make([dynamic]Prov_Entry_Def, allocator)
	graph.root_by_symbol = make(map[Symbol_Id]Root_Id, 8, allocator)
	graph.slot_by_symbol = make(map[Symbol_Id]int, 8, allocator)
	graph.content_by_symbol = make(map[Symbol_Id][]int, 8, allocator)
	graph.call_results = make(map[^Expr_Call][]Prov_Call_Result, 8, allocator)
	graph.summary_callees = make([dynamic]Symbol_Id, allocator)
	graph.temp_roots = make([dynamic]Root_Id, allocator)
	graph.region_of = make(map[Symbol_Id]Region_Set, 8, allocator)
	graph.provider_parents = make(map[Symbol_Id]Region_Set, 4, allocator)
	graph.owners_in_scope = make([dynamic]Symbol_Id, allocator)
	graph.provider_bits = make(map[Symbol_Id]u64, 4, allocator)
	graph.provider_symbols = make([dynamic]Symbol_Id, allocator)
	graph.break_block, graph.continue_block = NO_BLOCK, NO_BLOCK
	graph.current = new_flow_block(graph)

	// design.md: a `move` parameter transfers ownership from caller to callee, so
	// the callee drops it like any owned local. It lives in a scope outside the
	// body's, which is what makes its cleanup the outermost one.
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

@(private = "file")
new_flow_block :: proc(graph: ^Flow_Graph) -> Block_Id {
	block := new(Flow_Block, graph.alloc)
	block.events = make([dynamic]Flow_Event, graph.alloc)
	block.preds = make([dynamic]Block_Id, graph.alloc)
	block.succs = make([dynamic]Block_Id, graph.alloc)
	block.prov = make([dynamic]Prov_Event, graph.alloc)
	append(&graph.blocks, block)
	return Block_Id(len(graph.blocks) - 1)
}

@(private = "file")
link :: proc(graph: ^Flow_Graph, from, to: Block_Id) {
	if from == NO_BLOCK || to == NO_BLOCK {
		return
	}
	append(&graph.blocks[to].preds, from)
	append(&graph.blocks[from].succs, to)
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
			append(&graph.tracked, Tracked_Local{symbol = id, live_on_entry = true, owns_cleanup = true})
			graph.by_symbol[id] = len(graph.tracked) - 1
			append(&graph.in_scope, Flow_Cleanup{kind = .Local, slot = len(graph.tracked) - 1})
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
		action := graph.in_scope[index]
		if action.kind == .Defer {
			// Execute the deferred syntax at scope exit, not at registration. This
			// gives reads, moves, drops, branches, and nested lexical cleanup their
			// real position in the ownership dataflow.
			// Remove this action and the already-run later registrations while it
			// executes. Besides matching runtime stack popping, this prevents an
			// already-diagnosed illegal `return` inside a defer from recursively
			// invoking the same defer during error recovery.
			// The walk appends into this same backing storage, so the entries
			// have to be saved, not the dynamic-array header.
			tail := slice.clone(graph.in_scope[index:], graph.alloc)
			resize(&graph.in_scope, index)
			walk_flow_stmt(graph, action.stmt)
			resize(&graph.in_scope, index)
			append(&graph.in_scope, ..tail)
			continue
		}
		if action.kind == .Prov_Owner {
			resize(&graph.owners_in_scope, action.slot)
			continue
		}
		if action.kind == .Prov_Root {
			// A borrow may be used only while its root is live (design.md). The
			// storage ends here, so every loan of it does too.
			prov_emit(graph, Prov_Event{kind = .Root_End, root = action.root, span = action.span})
			continue
		}
		slot := action.slot
		sym := symbol_of(graph.k.c, graph.tracked[slot].symbol)
		emit(graph, Flow_Event {
			kind = .Cleanup,
			slot = slot,
			span = sym == nil ? no_span() : sym.span,
			name = sym == nil ? "" : identifier_text(graph.k.c, sym.name),
		})
	}
}

// An ordinary temporary root lives until the end of its complete expression,
// and one in a control-flow header until that complete statement ends
// (design.md). A header's initial statement therefore does not release its
// own temporaries: `extend` keeps them on the enclosing statement's list.
@(private = "file")
walk_flow_stmt :: proc(graph: ^Flow_Graph, stmt: Stmt, extend := false) {
	mark := len(graph.temp_roots)
	defer if !extend {
		for index := len(graph.temp_roots) - 1; index >= mark; index -= 1 {
			prov_emit(graph, Prov_Event{kind = .Root_End, root = graph.temp_roots[index]})
		}
		resize(&graph.temp_roots, mark)
	}
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
		append(&graph.in_scope, Flow_Cleanup{kind = .Defer, stmt = s.stmt})

	case ^Stmt_Return:
		if graph.mode != .Lifecycle {
			for value, value_index in s.values {
				first := walk_flow_expr(graph, value.expr)
				if len(s.values) == 1 {
					if call, ok := value.expr.(^Expr_Call); ok {
						if results, found := graph.call_results[call]; found && len(results) > 1 {
							for result, result_index in results {
								prov_emit(graph, Prov_Event {
									kind    = .Escape,
									sources = result.loans,
									span    = expr_span(value.expr),
									result  = result_index,
									region  = result.region,
								})
							}
							continue
						}
					}
				}
				escaping := prov_escape_region(graph, value.expr, 0)
				prov_emit(graph, Prov_Event {
					kind    = .Escape,
					sources = first,
					span    = expr_span(value.expr),
					result  = value_index,
					region  = escaping,
					// design.md's `bad_owner`: "ERROR: owner outlives allocator region
					// `arena`". The region ends with the frame, so no result can carry
					// it -- and the diagnostic has to name which region that is.
					name    = prov_region_name(graph, escaping),
				})
			}
			emit_cleanups(graph, 0)
			graph.current = NO_BLOCK
			return
		}
		for value in s.values {
			// Returning a managed local, named result, temporary, or `move`
			// parameter transfers that owned value into result storage without
			// cloning (design.md), so the source is dead afterwards and scope exit
			// must not drop it.
			if value.clone_on_return {
				report_copy_cost(
					graph.k, .Return, expr_span(value.expr), value.expr,
					expr_base(value.expr).type, graph.loop_depth > 0,
				)
			}
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
	value_loans: [][]int
	if graph.mode != .Lifecycle && len(d.values) > 0 {
		value_loans = make([][]int, len(d.values), graph.alloc)
	}
	for value, index in d.values {
		if value != nil {
			result := walk_flow_expr(graph, value)
			if value_loans != nil {
				value_loans[index] = result
			}
		}
	}
	if graph.mode != .Lifecycle {
		prov_declare(graph, d, value_loans)
		return
	}
	classify_declaration_copies(graph.k, d, graph.loop_depth > 0)
	for id, symbol_index in d.symbols {
		sym := symbol_of(graph.k.c, id)
		if sym == nil || sym.kind != .Var {
			continue
		}
		if !type_is_managed(graph.k.c, sym.type) {
			continue
		}
		// Static-duration storage is always live after initialization and the
		// compiler never drops it automatically (design.md), so there is no state
		// to follow and no scope-exit obligation.
		if sym.duration != .None {
			continue
		}
		// ponytail: `manual` disables automatic cleanup, but it is still gated at
		// the declaration, so there is nothing here to exempt yet.
		// Scope exit automatically drops a live managed lexical owner but not a
		// manual one (design.md). A `manual` owner is still followed, so `drop(x)`
		// and use-after-drop both work on it.
		slot, already_tracked := slot_of(graph, id)
		if !already_tracked {
			append(&graph.tracked, Tracked_Local {
				symbol       = id,
				scope        = len(graph.scopes),
				owns_cleanup = type_is_managed(graph.k.c, sym.type) && !sym.manual,
			})
			slot = len(graph.tracked) - 1
			graph.by_symbol[id] = slot
		}
		// A deferred statement's AST is expanded at each distinct exit. Reuse its
		// declaration's state slot, but register the runtime activation in each
		// expanded cleanup path.
		append(&graph.in_scope, Flow_Cleanup{kind = .Local, slot = slot})
		// The implicit action is placed at the declaration point, where
		// initialization completes (design.md). `---` leaves storage
		// uninitialised and so registers nothing.
		if len(d.values) == 1 && d.values[0] == nil {
			continue
		}
		event := Flow_Event {
			kind = .Init,
			slot = slot,
			span = sym.span,
			name = identifier_text(graph.k.c, sym.name),
		}
		initializer: Expr
		if len(d.values) == 1 && len(d.symbols) > 1 {
			if symbol_index == 0 {
				initializer = d.values[0]
			}
		} else if symbol_index < len(d.values) {
			initializer = d.values[symbol_index]
		}
		_ = initializer
		emit(graph, event)
	}
}

@(private = "file")
walk_flow_assign :: proc(graph: ^Flow_Graph, s: ^Stmt_Assign) {
	value_loans: [][]int
	if graph.mode != .Lifecycle && len(s.rhs) > 0 {
		value_loans = make([][]int, len(s.rhs), graph.alloc)
	}
	for value, index in s.rhs {
		result := walk_flow_expr(graph, value)
		if value_loans != nil {
			value_loans[index] = result
		}
	}
	if graph.mode != .Lifecycle {
		prov_assign(graph, s, value_loans)
		return
	}
	classify_assignment_copies(graph.k, s, graph.loop_depth > 0)
	for target, index in s.lhs {
		// A full assignment to the variable itself revives it; a write through a
		// field or element needs the root live, which is an ordinary use.
		if ident, is_ident := target.(^Expr_Ident); is_ident && s.op == .Assign {
			if slot, tracked := slot_of(graph, ident.symbol); tracked {
				event := Flow_Event {
					kind   = .Assign,
					slot   = slot,
					span   = expr_span(target),
					name   = ident.name,
					assign = s,
					target = index,
				}
				emit(graph, event)
				continue
			}
		}
		walk_flow_expr(graph, target)
	}
}

@(private = "file")
walk_flow_if :: proc(graph: ^Flow_Graph, s: ^Stmt_If) {
	if s.init != nil {
		walk_flow_stmt(graph, s.init, extend = true)
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
		walk_flow_stmt(graph, s.init, extend = true)
	}
	head := new_flow_block(graph)
	link(graph, graph.current, head)
	graph.current = head
	if s.cond != nil {
		walk_flow_expr(graph, s.cond)
	}
	done := new_flow_block(graph)
	if s.cond != nil {
		link(graph, head, done)
	}
	post := new_flow_block(graph)

	body := new_flow_block(graph)
	link(graph, head, body)
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
	iterated := walk_flow_expr(graph, s.iterable)
	if graph.mode != .Lifecycle {
		iterated = prov_iterate(graph, s, iterated)
	}
	head := new_flow_block(graph)
	link(graph, graph.current, head)
	done := new_flow_block(graph)
	link(graph, head, done)
	// design.md lists compiler-known iterators among the borrow carriers: both
	// conversion to a built-in view and compiler-known iteration preserve the
	// source root. The read happens once per iteration, so the loan has to be
	// live through the body, not only where the iterable was written.
	if len(iterated) > 0 {
		graph.current = head
		prov_emit(graph, Prov_Event{
			kind = .Live, sources = iterated, span = expr_span(s.iterable), revives = true,
		})
	}

	body := new_flow_block(graph)
	link(graph, head, body)
	graph.current = body
	// Each iteration binds the element to what the iteration holds, so a borrow
	// stored inside an element travels into the binding instead of vanishing.
	if graph.mode != .Lifecycle {
		for binding in s.bindings {
			prov_bind_value(graph, binding.symbol, iterated, expr_span(s.iterable))
		}
	}
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
	graph.loop_depth += 1
	walk_flow_block(graph, body)
	graph.loop_depth -= 1
	graph.break_block, graph.continue_block = outer_break, outer_continue
	graph.break_depth, graph.continue_depth = outer_break_depth, outer_continue_depth
}

@(private = "file")
walk_flow_switch :: proc(graph: ^Flow_Graph, s: ^Stmt_Switch) {
	if s.init != nil {
		walk_flow_stmt(graph, s.init, extend = true)
	}
	subject: []int
	if s.subject != nil {
		subject = walk_flow_expr(graph, s.subject)
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
		// A type switch binds one name per case to the subject's value, so what
		// the union alternative holds is what the binding holds.
		if graph.mode != .Lifecycle {
			prov_bind_value(graph, c.binding_symbol, subject, c.span)
		}
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

// Only the shapes that carry an ownership or provenance event need their own
// arm; everything else is walked for the uses inside it. The result is the
// carrier slots holding the loans this expression's value carries, which is
// empty for every value that borrows nothing.
@(private = "file")
walk_flow_expr :: proc(graph: ^Flow_Graph, e: Expr) -> []int {
	prov := graph.mode != .Lifecycle
	if prov {
		// design.md "any_view type": the erased view holds the address of the
		// concrete value, so it borrows the place it was erased from. M4b settled
		// the representation; what it could not do without provenance is stop the
		// subject from being invalidated while the view is still read.
		if base := expr_base(e); base != nil && base.erased_from != INVALID_TYPE {
			return prov_erase(graph, e)
		}
	}
	switch v in e {
	case ^Expr_Ident:
		if !prov {
			if slot, tracked := slot_of(graph, v.symbol); tracked {
				emit(graph, Flow_Event{kind = .Use, slot = slot, span = v.span, name = v.name})
			}
			return nil
		}
		return prov_read_ident(graph, v, .Read)

	case ^Expr_Move:
		if prov {
			return prov_consume(graph, v.value, v.span, "moved")
		}
		// One event, not a use followed by a kill: `Kill` already requires the
		// source to be live, and two events would report one mistake twice.
		if ident, is_ident := v.value.(^Expr_Ident); is_ident {
			if slot, tracked := slot_of(graph, ident.symbol); tracked {
				emit(graph, Flow_Event{kind = .Kill, slot = slot, span = v.span, name = ident.name, verb = "moved"})
				return nil
			}
		}
		walk_flow_expr(graph, v.value)

	case ^Expr_Call:
		return walk_flow_call(graph, v)

	case ^Expr_Binary:
		walk_flow_expr(graph, v.lhs)
		if v.op == .And_And || v.op == .Or_Or {
			entry := graph.current
			merge := new_flow_block(graph)
			// One result of the left operand skips the right operand.
			link(graph, entry, merge)
			graph.current = new_flow_block(graph)
			link(graph, entry, graph.current)
			walk_flow_expr(graph, v.rhs)
			link(graph, graph.current, merge)
			graph.current = merge
		} else {
			walk_flow_expr(graph, v.rhs)
		}

	case ^Expr_Unary:
		// `&place` creates a checked read-only `^T` borrow of the root containing
		// `place`, and `&mut place` a mutable `^mut T` one (design.md).
		if prov && v.op == .Amp {
			return prov_address_of(graph, v)
		}
		walk_flow_expr(graph, v.operand)

	case ^Expr_Postfix:
		operand_loans := walk_flow_expr(graph, v.operand)
		if v.op == .Or_Return {
			entry := graph.current
			resume := new_flow_block(graph)
			link(graph, entry, resume)
			failure := new_flow_block(graph)
			link(graph, entry, failure)
			graph.current = failure
			emit_cleanups(graph, 0)
			graph.current = resume
			// design.md "or_return operator": on success the expression yields the
			// operand's values with the status removed, so whatever those values
			// borrow or allocate travels out with them. Dropping the loans here
			// would leave `p := new(T) or_return` with unknown provenance.
			return operand_loans
		}

	case ^Expr_Selector:
		if prov {
			if root, path, ok := prov_place_of(graph, v); ok {
				prov_access(graph, root, path, .Read, v.span)
				// Reading a field yields what that field holds, and only that.
				// Checking the access must not add a lasting borrow of the
				// wrapper on top of it.
				if content := prov_content_at(graph, root, path); len(content) > 0 {
					prov_emit(graph, Prov_Event{kind = .Live, sources = content, span = v.span})
					return content
				}
				return nil
			}
		}
		walk_flow_expr(graph, v.operand)

	case ^Expr_Index:
		if prov {
			if root, path, ok := prov_place_of(graph, v); ok {
				prov_access(graph, root, path, .Read, v.span)
				for index in v.indices {
					walk_flow_expr(graph, index)
				}
				if underlying_kind(graph.k.c, expr_base(v.operand).type) == .Map && type_is_carrier(graph.k.c, v.type) {
					return prov_borrow(graph, root, path, carrier_is_mutable(graph.k.c, v.type), v.span, "map value")
				}
				// Reading an element yields what that element holds. The path
				// already ends in the wildcard that stands for every element, so
				// this is the same selection a field read does.
				if content := prov_content_at(graph, root, path); len(content) > 0 {
					prov_emit(graph, Prov_Event{kind = .Live, sources = content, span = v.span})
					return content
				}
				return nil
			}
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
		if v.lo != nil {
			walk_flow_expr(graph, v.lo)
		}
		if v.hi != nil {
			walk_flow_expr(graph, v.hi)
		}

	case ^Expr_Composite:
		if prov {
			if content := prov_temp_content(graph, v.type); len(content) > 0 {
				return prov_composite_content(graph, v, content)
			}
		}
		for element in v.elements {
			if element.value != nil {
				walk_flow_expr(graph, element.value)
			}
		}

	case ^Expr_Cond:
		walk_flow_expr(graph, v.cond)
		entry := graph.current
		merge := new_flow_block(graph)
		graph.current = new_flow_block(graph)
		link(graph, entry, graph.current)
		then_loans := walk_flow_expr(graph, v.then)
		link(graph, graph.current, merge)
		graph.current = new_flow_block(graph)
		link(graph, entry, graph.current)
		else_loans := walk_flow_expr(graph, v.otherwise)
		link(graph, graph.current, merge)
		graph.current = merge
		return prov_join(graph, then_loans, else_loans)

	case ^Expr_Or_Else:
		value_loans := walk_flow_expr(graph, v.value)
		entry := graph.current
		merge := new_flow_block(graph)
		// Success skips the fallback; failure evaluates it.
		link(graph, entry, merge)
		graph.current = new_flow_block(graph)
		link(graph, entry, graph.current)
		fallback_loans := walk_flow_expr(graph, v.fallback)
		link(graph, graph.current, merge)
		graph.current = merge
		return prov_join(graph, value_loans, fallback_loans)

	case ^Expr_Checked_Extract:
		// Carrier results retain the source root. An owning extraction clones
		// into independent storage instead of retaining the erased borrow.
		loans := walk_flow_expr(graph, v.operand)
		if type_is_carrier(graph.k.c, v.type) {
			return loans
		}
		return nil

	case ^Expr_Range:
		walk_flow_expr(graph, v.lo)
		walk_flow_expr(graph, v.hi)

	case ^Expr_Literal, ^Expr_Proc, ^Expr_Proc_Group, ^Expr_Operator,
	     ^Expr_Error,
	     ^Type_Pointer, ^Type_Multi_Pointer, ^Type_Slice, ^Type_Dynamic_Array,
	     ^Type_Array, ^Type_Map, ^Type_Distinct, ^Type_Dyn, ^Type_Type,
	     ^Type_Poly, ^Type_Proc, ^Type_Record, ^Type_Enum, ^Type_Interface:
	}
	return nil
}

// A trivial aggregate copied into a `value: T` parameter is a copy site, while
// an ordinary `value: T` parameter that borrows a managed owner is not
// (design.md). Passing a temporary hands over a value nothing else holds, so
// only a place duplicates anything.
@(private = "file")
report_argument_copies :: proc(graph: ^Flow_Graph, v: ^Expr_Call, consumed: int) {
	sym := symbol_of(graph.k.c, v.resolution.chosen_overload)
	if sym == nil {
		return
	}
	info := type_of(graph.k.c, sym.proc_type)
	if info == nil {
		return
	}
	for argument, index in v.bound {
		if argument == nil || index == consumed || index >= len(info.parameters) {
			continue
		}
		mode := index < len(info.param_modes) ? info.param_modes[index] : Param_Mode.Value
		if mode != .Value {
			continue
		}
		type := info.parameters[index]
		// A managed parameter is a borrow for the duration of the call.
		if type_is_managed(graph.k.c, type) || !type_is_aggregate(graph.k.c, type) {
			continue
		}
		if !expression_is_borrowed_place(graph.k.c, argument) {
			continue
		}
		report_copy_cost(graph.k, .Argument, expr_span(argument), argument, type, graph.loop_depth > 0)
	}
}

@(private = "file")
walk_flow_call :: proc(graph: ^Flow_Graph, v: ^Expr_Call) -> []int {
	// `value.as(T)` is an extraction wearing call syntax. Walking the node it
	// resolved to is what preserves the source root, exactly as `value.(T)` does.
	if v.union_op == .Extract && v.extract != nil {
		return walk_flow_expr(graph, v.extract)
	}
	// A union's active type query reads its receiver once and returns a scalar;
	// it neither consumes the union nor carries provenance into the result.
	if v.union_op != .None {
		if len(v.bound) == 1 {
			walk_flow_expr(graph, v.bound[0])
		}
		return nil
	}
	if graph.mode != .Lifecycle {
		return prov_call(graph, v)
	}
	// `drop(x)` reads the value, runs its hook, and kills the binding. Its
	// operand is in `bound` rather than `args` by the time this runs.
	// `free` ends the allocation root designated by a checked base pointer and
	// consumes the operand binding (design.md). Step 3 checked the operand's
	// form; requiring it definitely live is the half that needed this graph.
	if sym := symbol_of(graph.k.c, v.resolution.symbol); sym != nil && sym.kind == .Builtin {
		#partial switch sym.builtin {
		case .Exchange:
			// `exchange` replaces a definitely live value (design.md). It leaves a
			// completed live replacement, so the destination survives the operation
			// and this is a use rather than a kill.
			if len(v.bound) == 2 {
				if ident, is_ident := v.bound[0].(^Expr_Ident); is_ident {
					if slot, tracked := slot_of(graph, ident.symbol); tracked {
						emit(graph, Flow_Event {
							kind = .Use,
							slot = slot,
							span = v.span,
							name = ident.name,
							verb = "exchanged",
						})
					}
				}
				walk_flow_expr(graph, v.bound[1])
			}
			return nil
		case .Drop, .Free:
			if len(v.bound) == 1 {
				if ident, is_ident := v.bound[0].(^Expr_Ident); is_ident {
					if slot, tracked := slot_of(graph, ident.symbol); tracked {
						emit(graph, Flow_Event {
							kind = .Kill,
							slot = slot,
							span = v.span,
							name = ident.name,
							verb = sym.builtin == .Free ? "released" : "dropped",
						})
						return nil
					}
				}
			}
			return nil
		}
	}
	// A method call's receiver is `bound[0]` *and* the callee selector's operand:
	// one expression reached two ways. Walk it once, as an argument, so that a
	// consuming receiver written `move(value).method()` kills its source exactly
	// once. It needs no exemption from `report_argument_copies` either: a `move`
	// parameter is not a `.Value` one, and a `move` expression is not a place.
	if sym := symbol_of(graph.k.c, v.resolution.chosen_overload); sym == nil || !sym.has_receiver {
		walk_flow_expr(graph, v.callee)
	}
	report_argument_copies(graph, v, -1)
	for argument in v.bound {
		if argument != nil {
			walk_flow_expr(graph, argument)
		}
	}
	// A packed variadic parameter leaves `bound[variadic_slot]` nil and keeps the
	// arguments themselves in the two lists, so the loop above walked past them.
	// Each one is still an ordinary use of whatever it names.
	for element in v.variadic_elements {
		walk_flow_expr(graph, element)
	}
	for spread in v.variadic_spreads {
		walk_flow_expr(graph, spread)
	}
	if len(v.bound) == 0 {
		for argument in v.args {
			walk_flow_expr(graph, argument.value)
		}
	}
	note_reset_point(graph, v)
	return nil
}

// Whether this call resets an allocator region: `free_all`, or a call handing an
// argument to an `@(allocator_reset)` parameter. One predicate, so the liveness
// pass and the provenance pass cannot disagree about which calls are resets.
call_is_reset :: proc(c: ^Compiler, v: ^Expr_Call) -> bool {
	if sym := symbol_of(c, v.resolution.symbol); sym != nil && sym.builtin == .Free_All {
		return true
	}
	proc_type := INVALID_TYPE
	if sym := symbol_of(c, v.resolution.chosen_overload); sym != nil {
		proc_type = sym.proc_type
	} else if v.callee != nil {
		proc_type = expr_base(v.callee).type
	}
	if proc_type == INVALID_TYPE {
		return false
	}
	for argument, index in v.bound {
		if argument != nil && proc_param_resets(c, proc_type, index) {
			return true
		}
	}
	return false
}

// Emitted after the arguments, because that is where the reset happens: an
// argument may itself move an owner out, and the state that matters is the one
// the reset sees.
@(private = "file")
note_reset_point :: proc(graph: ^Flow_Graph, v: ^Expr_Call) {
	if len(graph.tracked) == 0 || !call_is_reset(graph.k.c, v) {
		return
	}
	emit(graph, Flow_Event{kind = .Reset_Point, span = v.span, call = v})
}

// ------------------------------------------------- provenance construction --

// The provenance modes record what the two lattices in `src/borrow.odin` read.
// Everything below is pure graph construction: it may allocate in the graph's
// own arena and may read the typed AST, but never writes to it and never
// reports.

@(private = "file")
prov_emit :: proc(graph: ^Flow_Graph, event: Prov_Event) {
	if graph.current == NO_BLOCK {
		return // unreachable code borrows nothing observable
	}
	if event.kind == .Reset || event.kind == .Region_Escape {
		graph.has_region_event = true
	}
	// A body that borrows nothing can still return an owner backed by one of its
	// own regions, which is the only thing that would make the solver run.
	if event.kind == .Escape && region_has_local(event.region) {
		graph.has_region_event = true
	}
	append(&graph.blocks[graph.current].prov, event)
}

@(private = "file")
prov_one :: proc(graph: ^Flow_Graph, slot: int) -> []int {
	out := make([]int, 1, graph.alloc)
	out[0] = slot
	return out
}

@(private = "file")
prov_join :: proc(graph: ^Flow_Graph, a, b: []int) -> []int {
	if len(a) == 0 {
		return b
	}
	if len(b) == 0 {
		return a
	}
	out := make([]int, len(a) + len(b), graph.alloc)
	copy(out, a)
	copy(out[len(a):], b)
	return out
}

// design.md "or_return operator": the operator removes the *final* status, so
// every earlier result keeps its index and the per-result provenance of the
// operand applies unchanged to the expression's own results.
@(private = "file")
prov_through_or_return :: proc(value: Expr) -> Expr {
	if postfix, ok := value.(^Expr_Postfix); ok && postfix.op == .Or_Return {
		return postfix.operand
	}
	return value
}

@(private = "file")
prov_result_loans :: proc(graph: ^Flow_Graph, value: Expr, result: int, first: []int = nil) -> []int {
	if call, ok := prov_through_or_return(value).(^Expr_Call); ok {
		if results, found := graph.call_results[call]; found && result < len(results) {
			return results[result].loans
		}
	}
	return result == 0 ? first : nil
}

@(private = "file")
prov_result_region :: proc(graph: ^Flow_Graph, value: Expr, result: int) -> Region_Set {
	if call, ok := prov_through_or_return(value).(^Expr_Call); ok {
		if results, found := graph.call_results[call]; found && result < len(results) {
			return results[result].region
		}
	}
	return result == 0 ? prov_region_of(graph, value) : Region_Set{}
}

// Returning a region provider transfers the provider's dependency, not the
// callee-local token that identifies allocations made *by* that provider. The
// caller creates a fresh token for the returned owner and retains the parent
// edge represented here.
@(private = "file")
prov_escape_region :: proc(graph: ^Flow_Graph, value: Expr, result: int) -> Region_Set {
	if result == 0 && expr_base(value) != nil && type_is_region_provider(graph.k.c, expr_base(value).type) {
		#partial switch v in value {
		case ^Expr_Ident:
			if parent, found := graph.provider_parents[v.symbol]; found {
				return parent
			}
			return Region_Set{}
		case ^Expr_Move:
			return prov_escape_region(graph, v.value, 0)
		}
	}
	return prov_result_region(graph, value, result)
}

@(private = "file")
prov_new_root :: proc(graph: ^Flow_Graph, kind: Root_Kind, span: Span, name: string) -> Root_Id {
	append(&graph.roots, Prov_Root{kind = kind, span = span, name = name, param_index = -1})
	return Root_Id(len(graph.roots) - 1)
}

// design.md "Storage roots and borrow carriers": every ordinary variable owns
// its inline storage and is a root for borrows of it. Static-duration storage is
// a root that outlives every body, and an `inout` parameter names the caller's.
@(private = "file")
prov_root_for_symbol :: proc(graph: ^Flow_Graph, id: Symbol_Id) -> Root_Id {
	if id == INVALID_SYMBOL {
		return NO_ROOT
	}
	if existing, found := graph.root_by_symbol[id]; found {
		return existing
	}
	sym := symbol_of(graph.k.c, id)
	if sym == nil {
		return NO_ROOT
	}
	kind := Root_Kind.Local
	#partial switch sym.kind {
	case .Var:
		// `thread_local` storage lives as long as its thread, not as long as the
		// process, so it is a root kind of its own even though both survive a
		// return (design.md "Storage duration").
		switch {
		case sym.duration == .Thread_Local:
			kind = .Thread_Local
		case sym.duration != .None || (sym.decl != nil && sym.decl.top_level):
			kind = .Static
		}
	case .Parameter:
		// An `inout` parameter aliases the caller's root, while the default
		// parameter binding is a callee-local read-only value (design.md).
		if sym.mode == .Inout {
			kind = .Param
		}
	case .Result:
	case .Const:
		// design.md "Materialization": a constant reached by a runtime index,
		// slice, or `&` gets one read-only object for the whole program.
		kind = .Materialized
	case:
		return NO_ROOT
	}
	root := prov_new_root(graph, kind, sym.span, identifier_text(graph.k.c, sym.name))
	graph.roots[int(root)].symbol = id
	if kind == .Param {
		graph.roots[int(root)].param_index = int(sym.index)
	}
	graph.root_by_symbol[id] = root
	return root
}

// A carrier variable gets one slot; its reaching loans are what the forward
// lattice follows. A static-duration carrier deliberately gets none: design.md
// lists storing a view in a global as one of the cases that are not checked.
@(private = "file")
prov_slot_for_symbol :: proc(graph: ^Flow_Graph, id: Symbol_Id) -> (int, bool) {
	if id == INVALID_SYMBOL {
		return 0, false
	}
	if existing, found := graph.slot_by_symbol[id]; found {
		return existing, true
	}
	sym := symbol_of(graph.k.c, id)
	if sym == nil {
		return 0, false
	}
	if !type_is_carrier(graph.k.c, sym.type) {
		// It may still carry a borrow inside it. That is step 5's slot to
		// allocate; step 4 only measures what it will cost.
		prov_stats_note_aggregate(graph.k.c, id, sym.type)
		return 0, false
	}
	if sym.kind != .Var && sym.kind != .Parameter && sym.kind != .Result {
		return 0, false
	}
	if sym.duration != .None || (sym.decl != nil && sym.decl.top_level) {
		return 0, false
	}
	entry := empty_prov_slot(id)
	entry.name = identifier_text(graph.k.c, sym.name)
	entry.span = sym.span
	append(&graph.prov_slots, entry)
	slot := len(graph.prov_slots) - 1
	graph.slot_by_symbol[id] = slot
	return slot, true
}

// Constructing an aggregate puts each element's borrows at that element's own
// place. A positional element goes to its field, or to its index in an array; a
// keyed one is not resolved here, so a keyed literal joins every element into
// every path rather than guessing. An array whose shape kept a single wildcard
// element path joins into it through the same overlap test.
@(private = "file")
prov_composite_content :: proc(graph: ^Flow_Graph, v: ^Expr_Composite, content: []int) -> []int {
	is_array := underlying_kind(graph.k.c, expr_base(v).type) == .Array
	keyed := false
	for element in v.elements {
		if element.key != nil {
			keyed = true
			break
		}
	}
	per_element := make([][]int, len(v.elements), graph.alloc)
	joined: []int
	for element, index in v.elements {
		if element.value == nil {
			continue
		}
		loans := walk_flow_expr(graph, element.value)
		per_element[index] = loans
		joined = prov_join(graph, joined, loans)
	}
	for slot in content {
		sources := joined
		if !keyed {
			sources = nil
			for loans, index in per_element {
				if len(loans) == 0 {
					continue
				}
				// An element is selected by index, a field by its own step, and
				// the two kinds must not be compared: `steps_overlap` treats a
				// mismatch as "nothing proven", which would join everything.
				element_step := proj_field(index)
				if is_array {
					element_step = proj_range(i64(index), i64(index) + 1)
				}
				if paths_overlap(graph.prov_slots[slot].path, {element_step}) {
					sources = prov_join(graph, sources, loans)
				}
			}
		}
		prov_define_one_content(graph, slot, sources, v.span)
	}
	return content
}

// consolidation-provenance-plan.md step 5: a value that is not itself a borrow
// can still hold one. Every place `carrier_shape` names gets its own slot, so a
// read of one field does not inherit what a sibling borrows, and a wrapped
// borrow keeps the obligations the bare one has.
@(private = "file")
prov_content_slots :: proc(graph: ^Flow_Graph, id: Symbol_Id) -> []int {
	if id == INVALID_SYMBOL {
		return nil
	}
	if existing, found := graph.content_by_symbol[id]; found {
		return existing
	}
	sym := symbol_of(graph.k.c, id)
	if sym == nil || type_is_carrier(graph.k.c, sym.type) {
		return nil // a bare carrier already has its own slot
	}
	if sym.kind != .Var && sym.kind != .Parameter && sym.kind != .Result {
		return nil
	}
	// Static-duration storage gets no slot, for the same reason a bare carrier
	// in a global does not: design.md lists storing a view there as unchecked,
	// and step 8 is where that changes.
	if sym.duration != .None || (sym.decl != nil && sym.decl.top_level) {
		return nil
	}
	shape := carrier_shape(graph.k.c, sym.type)
	if len(shape) == 0 {
		return nil // an all-scalar value initializes no payload facts
	}
	slots := make([]int, len(shape), graph.alloc)
	for path, index in shape {
		entry := empty_prov_slot(id)
		entry.name = identifier_text(graph.k.c, sym.name)
		entry.span = sym.span
		entry.path = path.steps
		entry.content_type = path.truncated ? INVALID_TYPE : path.type
		append(&graph.prov_slots, entry)
		slots[index] = len(graph.prov_slots) - 1
	}
	graph.content_by_symbol[id] = slots
	return slots
}

// The content slots of one place: those whose shape path overlaps the
// projection the place names. `paths_overlap` already treats a prefix as
// covering everything below it, so a truncated path still answers for a deeper
// read, and two distinct fields still answer separately.
@(private = "file")
prov_content_at :: proc(graph: ^Flow_Graph, root: Root_Id, path: []Proj_Step) -> []int {
	if root == NO_ROOT {
		return nil
	}
	slots := prov_content_slots(graph, graph.roots[int(root)].symbol)
	if len(slots) == 0 {
		return nil
	}
	if len(path) == 0 {
		return slots
	}
	out := make([dynamic]int, 0, len(slots), graph.alloc)
	for slot in slots {
		if paths_overlap(graph.prov_slots[slot].path, path) {
			append(&out, slot)
		}
	}
	return out[:]
}

// Slots for the content of a value with no name of its own: a literal, a call
// result, a temporary. Ordered by the same shape, so they pair by index with a
// destination of the same type.
@(private = "file")
prov_temp_content :: proc(graph: ^Flow_Graph, type: Type_Id) -> []int {
	shape := carrier_shape(graph.k.c, type)
	if len(shape) == 0 {
		return nil
	}
	slots := make([]int, len(shape), graph.alloc)
	for path, index in shape {
		entry := empty_prov_slot(INVALID_SYMBOL)
		entry.path = path.steps
		entry.content_type = path.truncated ? INVALID_TYPE : path.type
		append(&graph.prov_slots, entry)
		slots[index] = len(graph.prov_slots) - 1
	}
	return slots
}

// Consuming a value: what it held travels to wherever it went, so read that
// before the source is invalidated. The borrows inside it are of other roots and
// survive; what ends is the source binding's own storage, which is exactly what
// the invalidation covers (design.md). An explicit `move` around the place is
// transparent here — it is the same consumption written twice.
@(private = "file")
prov_consume :: proc(graph: ^Flow_Graph, place: Expr, span: Span, verb: string) -> []int {
	source := place
	if moved, is_move := place.(^Expr_Move); is_move {
		source = moved.value
	}
	consumed: []int
	if root, path, ok := prov_place_of(graph, source); ok {
		consumed = prov_content_at(graph, root, path)
	}
	prov_invalidate(graph, source, span, verb)
	return consumed
}

// Publishes a value into whatever slots a binding has: its own slot when it is
// a bare carrier, its content slots when it holds borrows inside it. Used where
// a name is bound to a value the walk already has loans for but no declaration
// runs — a `foreach` element and a type switch's per-case binding.
@(private = "file")
prov_bind_value :: proc(graph: ^Flow_Graph, id: Symbol_Id, sources: []int, span: Span) {
	if id == INVALID_SYMBOL {
		return
	}
	if slot, is_carrier := prov_slot_for_symbol(graph, id); is_carrier {
		sym := symbol_of(graph.k.c, id)
		if sym != nil {
			prov_weaken(graph, sources, sym.type, slot, span)
		}
		prov_emit(graph, Prov_Event{kind = .Def, slot = slot, loan = NO_LOAN, sources = sources, span = span})
		return
	}
	if content := prov_content_slots(graph, id); len(content) > 0 {
		prov_define_content(graph, content, sources, span)
	}
}

// Publishes one value's content into another's. Two values of one type have
// slot vectors built from the same shape, so they pair by index; anything else
// takes the whole source conservatively into every destination path.
@(private = "file")
prov_define_content :: proc(
	graph: ^Flow_Graph,
	into: []int,
	from: []int,
	span: Span,
	written: []Proj_Step = nil,
) {
	// A write whose own path is indistinct — an unknown index, a union subject —
	// reaches one of the places it selected without saying which, so it may not
	// erase the others.
	indistinct := path_is_indistinct(written)
	for slot, index in into {
		sources := from
		if len(from) == len(into) {
			sources = prov_one(graph, from[index])
		}
		// One content path can stand for many places — every element of a
		// container, every alternative of a union — and a write reaches only one
		// of them. Replacing the path would erase what the others hold, so an
		// indistinguishable destination joins instead. A known field replaces.
		if indistinct || path_is_indistinct(graph.prov_slots[slot].path) {
			sources = prov_join(graph, prov_one(graph, slot), sources)
		}
		prov_define_one_content(graph, slot, sources, span)
	}
}

// Whether a path stands for more than one place, which is exactly when a
// wildcard step appears in it.
@(private = "file")
path_is_indistinct :: proc(path: []Proj_Step) -> bool {
	for step in path {
		if step.kind == .Wild {
			return true
		}
	}
	return false
}

// One content path takes its own capability from the leaf that lives there: a
// mutable borrow published into a read-only field weakens exactly as it would
// at a read-only local.
@(private = "file")
prov_define_one_content :: proc(graph: ^Flow_Graph, slot: int, sources: []int, span: Span) {
	prov_weaken(graph, sources, graph.prov_slots[slot].content_type, slot, span)
	prov_emit(graph, Prov_Event{kind = .Def, slot = slot, loan = NO_LOAN, sources = sources, span = span})
}

@(private = "file")
prov_temp_slot :: proc(graph: ^Flow_Graph) -> int {
	append(&graph.prov_slots, empty_prov_slot(INVALID_SYMBOL))
	return len(graph.prov_slots) - 1
}

// A mutable carrier implicitly weakens to a read-only one (design.md). The
// conversion is written at the destination, so a borrow created by an
// expression takes its final capability from what receives it — both the loan
// and the access the borrow registered on its root.
// `into` is the slot receiving the weakened value, or -1 where the destination
// has no slot of its own — a call argument, whose reborrow cannot outlive the
// call and so can suspend nothing.
@(private = "file")
prov_weaken :: proc(graph: ^Flow_Graph, slots: []int, destination: Type_Id, into := -1, span := Span{}) {
	if !type_is_carrier(graph.k.c, destination) || carrier_is_mutable(graph.k.c, destination) {
		return
	}
	for slot in slots {
		entry := graph.prov_slots[slot]
		if entry.fresh_loan != NO_LOAN {
			graph.loans[int(entry.fresh_loan)].mutable = false
			if entry.fresh_access_index >= 0 {
				graph.blocks[entry.fresh_access_block].prov[entry.fresh_access_index].access = .Read
			}
			continue
		}
		// No fresh loan: this slot already held its loans, so the weakening is a
		// reborrow of a carrier rather than the settling of a new one.
		if into < 0 || !prov_slot_is_mutable_carrier(graph, slot) {
			continue
		}
		append(&graph.reborrows, Prov_Reborrow{source = slot, derived = into, span = span})
	}
}

// Whether a slot names a mutable carrier. Only a slot bound to a declared name
// has a type to ask; an expression temporary that reached here without a fresh
// loan is left alone rather than guessed at.
@(private = "file")
prov_slot_is_mutable_carrier :: proc(graph: ^Flow_Graph, slot: int) -> bool {
	sym := symbol_of(graph.k.c, graph.prov_slots[slot].symbol)
	return sym != nil && carrier_is_mutable(graph.k.c, sym.type)
}

@(private = "file")
prov_new_loan :: proc(
	graph: ^Flow_Graph,
	root: Root_Id,
	path: []Proj_Step,
	mutable: bool,
	span: Span,
	what: string,
) -> Loan_Id {
	append(&graph.loans, Prov_Loan{root = root, path = path, mutable = mutable, span = span, what = what})
	return Loan_Id(len(graph.loans) - 1)
}

// A fresh borrow, parked in an expression temporary so that its consumer -- a
// declaration, an assignment, a call, or nothing at all -- decides how long it
// stays live.
@(private = "file")
prov_borrow :: proc(
	graph: ^Flow_Graph,
	root: Root_Id,
	path: []Proj_Step,
	mutable: bool,
	span: Span,
	what: string,
	access_block := NO_BLOCK,
	access_index := -1,
) -> []int {
	loan := prov_new_loan(graph, root, path, mutable, span, what)
	slot := prov_temp_slot(graph)
	graph.prov_slots[slot].fresh_loan = loan
	graph.prov_slots[slot].fresh_access_block = access_block
	graph.prov_slots[slot].fresh_access_index = access_index
	prov_emit(graph, Prov_Event{kind = .Def, slot = slot, loan = loan, span = span})
	return prov_one(graph, slot)
}

@(private = "file")
// Returns where the event landed, so a caller that may have to revise it — a
// fresh borrow whose capability the destination settles — can find it again.
// `index` is -1 when nothing was emitted.
prov_access :: proc(
	graph: ^Flow_Graph,
	root: Root_Id,
	path: []Proj_Step,
	kind: Access_Kind,
	span: Span,
	verb := "",
) -> (block: Block_Id, index: int) {
	if root == NO_ROOT {
		return NO_BLOCK, -1
	}
	prov_emit(graph, Prov_Event {
		kind   = .Access,
		root   = root,
		path   = path,
		access = kind,
		span   = span,
		verb   = verb,
	})
	if graph.current == NO_BLOCK {
		return NO_BLOCK, -1
	}
	return graph.current, len(graph.blocks[graph.current].prov) - 1
}

@(private = "file")
prov_extend :: proc(graph: ^Flow_Graph, path: []Proj_Step, step: Proj_Step) -> []Proj_Step {
	out := make([]Proj_Step, len(path) + 1, graph.alloc)
	copy(out, path)
	out[len(path)] = step
	return out
}

// design.md: a borrowed parameter's storage belongs to the caller, so the body
// starts with one loan of a root it cannot see but can name in a summary.
@(private = "file")
prov_bind_parameters :: proc(graph: ^Flow_Graph, literal: ^Expr_Proc) {
	if literal.signature == nil {
		return
	}
	position := 0
	for parameter in literal.signature.params {
		position += len(parameter.symbols)
	}
	graph.param_count = position
	position = 0
	for parameter in literal.signature.params {
		for id in parameter.symbols {
			index := position
			position += 1
			sym := symbol_of(graph.k.c, id)
			if sym == nil {
				continue
			}
			// An allocator value's region identity is what lets the compiler
			// recognise two values as the same region, and what an
			// `@(allocator_reset)` promise is written about (design.md).
			if type_underlying(graph.k.c, sym.type) == TYPE_ALLOCATOR {
				set := prov_empty_region(graph)
				set.params[index] = true
				graph.region_of[id] = set
			}
			slot, is_carrier := prov_slot_for_symbol(graph, id)
			// An aggregate parameter arrives holding one borrow per place its
			// shape names, seeded independently of the parameter binding itself.
			content := prov_content_slots(graph, id)
			if !is_carrier && len(content) == 0 {
				continue
			}
			name := identifier_text(graph.k.c, sym.name)
			root := prov_new_root(graph, .Param, sym.span, name)
			graph.roots[int(root)].symbol = id
			graph.roots[int(root)].param_index = index
			if !is_carrier {
				shape := carrier_shape(graph.k.c, sym.type)
				for path, path_index in shape {
					loan := prov_new_loan(
						graph,
						root,
						path.steps,
						path.mutable,
						sym.span,
						path.truncated ? "borrow" : carrier_noun(graph.k.c, path.type),
					)
					append(&graph.entry_defs, Prov_Entry_Def{slot = content[path_index], loan = loan})
				}
				continue
			}
			loan := prov_new_loan(
				graph,
				root,
				nil,
				carrier_is_mutable(graph.k.c, sym.type),
				sym.span,
				carrier_noun(graph.k.c, sym.type),
			)
			append(&graph.entry_defs, Prov_Entry_Def{slot = slot, loan = loan})
		}
	}
}



// Conversion to a built-in view and compiler-known iteration preserve the
// source root (design.md). An `any_view` reads its subject and never writes
// it, so the loan is a read-only one and other reads stay legal.
@(private = "file")
prov_erase :: proc(graph: ^Flow_Graph, e: Expr) -> []int {
	span := expr_span(e)
	// Erasing a carrier borrows both its representation and the storage it
	// already refers to. Otherwise erasure (including a formatting argument)
	// hides a use of a previously invalidated view.
	loans := walk_flow_expr_erased(graph, e)
	if root, path, ok := prov_place_of(graph, e); ok {
		return prov_join(graph, loans, prov_borrow(graph, root, path, false, span, "view"))
	}
	// A carrier erased into a view keeps the loans it already held; anything else
	// is a temporary whose hidden storage ends with its statement.
	if len(loans) > 0 {
		return loans
	}
	// The storage the compiler creates to erase a value is a frame slot, not a
	// value temporary: like the hidden array behind a slice literal, it follows
	// the surrounding lexical scope.
	return prov_borrow(graph, prov_hidden_root(graph, span, "this erased value"), nil, false, span, "view")
}

// A root the compiler created rather than the reader, ending with the scope it
// was created in.
@(private = "file")
prov_hidden_root :: proc(graph: ^Flow_Graph, span: Span, name: string) -> Root_Id {
	root := prov_new_root(graph, .Temporary, span, name)
	append(&graph.in_scope, Flow_Cleanup{kind = .Prov_Root, root = root, span = span})
	return root
}

// The same walk with the erasure hook suppressed, so `prov_erase` can fall back
// to the node's ordinary meaning without recursing into itself.
@(private = "file")
walk_flow_expr_erased :: proc(graph: ^Flow_Graph, e: Expr) -> []int {
	base := expr_base(e)
	saved, saved_type := base.erased_from, base.type
	base.erased_from, base.type = INVALID_TYPE, saved
	defer { base.erased_from, base.type = saved, saved_type }
	return walk_flow_expr(graph, e)
}

// ------------------------------------------------------------- regions --

@(private = "file")
prov_empty_region :: proc(graph: ^Flow_Graph) -> Region_Set {
	return Region_Set{params = make([]bool, max(graph.param_count, 1), graph.alloc)}
}

// The token for one local provider, made on first ask. Past 64 providers in one
// body the set degrades to `crowded`, which means "may be any of them" and only
// ever makes the answer more conservative.
@(private = "file")
prov_provider_region :: proc(graph: ^Flow_Graph, id: Symbol_Id) -> Region_Set {
	out := prov_empty_region(graph)
	if existing, found := graph.provider_bits[id]; found {
		out.locals = existing
		return out
	}
	index := len(graph.provider_symbols)
	if index >= 64 {
		out.crowded = true
		return out
	}
	append(&graph.provider_symbols, id)
	bit := u64(1) << u64(index)
	graph.provider_bits[id] = bit
	out.locals = bit
	return out
}

// The name a diagnostic gives one local region, or "" when the set names more
// than one -- in which case the sentence has to talk about the owner instead.
prov_region_name :: proc(graph: ^Flow_Graph, set: Region_Set) -> string {
	if set.crowded {
		return ""
	}
	found := ""
	for id, index in graph.provider_symbols {
		if set.locals & (u64(1) << u64(index)) == 0 {
			continue
		}
		if found != "" {
			return ""
		}
		if sym := symbol_of(graph.k.c, id); sym != nil {
			found = identifier_text(graph.k.c, sym.name)
		}
	}
	return found
}

// The allocator region an expression denotes, or an empty set when it denotes
// nothing region-shaped.
@(private = "file")
prov_region_of :: proc(graph: ^Flow_Graph, e: Expr) -> Region_Set {
	c := graph.k.c
	#partial switch v in e {
	case ^Expr_Ident:
		if set, found := graph.region_of[v.symbol]; found {
			return set
		}
	case ^Expr_Move:
		// Moving an owner transfers, rather than erases, the region that backs it.
		return prov_region_of(graph, v.value)
	case ^Expr_Cond:
		out := prov_empty_region(graph)
		region_merge(&out, prov_region_of(graph, v.then))
		region_merge(&out, prov_region_of(graph, v.otherwise))
		return out
	case ^Expr_Or_Else:
		out := prov_empty_region(graph)
		region_merge(&out, prov_region_of(graph, v.value))
		region_merge(&out, prov_region_of(graph, v.fallback))
		return out
	case ^Expr_Postfix:
		// Propagating a status does not change which region backs the value that
		// travels through it.
		if v.op == .Or_Return {
			return prov_region_of(graph, v.operand)
		}
	case ^Expr_Composite:
		// An owning aggregate keeps every region dependency of its owning fields.
		out := prov_empty_region(graph)
		for element in v.elements {
			if element.value != nil {
				region_merge(&out, prov_region_of(graph, element.value))
			}
		}
		return out
	case ^Expr_Call:
		if sym := symbol_of(c, v.resolution.symbol); sym != nil && sym.builtin == .Default_Allocator {
			set := prov_empty_region(graph)
			set.default = true
			return set
		}
		// `arena.allocator()`: the handle names the provider's own region, and
		// copying an allocator value preserves that identity (design.md), so it
		// carries through every copy of the handle for free.
		if set, ok := prov_handle_region(graph, v); ok {
			return set
		}
		if results, found := graph.call_results[v]; found && len(results) > 0 {
			return results[0].region
		}
		return prov_call_region(graph, v, 0, v.type)
	}
	if type_underlying(c, expr_base(e) == nil ? INVALID_TYPE : expr_base(e).type) == TYPE_ALLOCATOR {
		set := prov_empty_region(graph)
		set.unknown = true
		return set
	}
	return Region_Set{}
}

// The region an `arena.allocator()` names. The receiver has to be a lexical
// provider: a handle taken from a temporary provider would name a region that
// ended at the end of the statement, and there is nothing sensible to say about
// it beyond the conservative "unknown".
@(private = "file")
prov_handle_region :: proc(graph: ^Flow_Graph, v: ^Expr_Call) -> (Region_Set, bool) {
	if call_provider_op(graph.k.c, v) != .Handle || len(v.bound) == 0 {
		return Region_Set{}, false
	}
	ident, is_ident := v.bound[0].(^Expr_Ident)
	if !is_ident {
		set := prov_empty_region(graph)
		set.unknown = true
		return set, true
	}
	if set, found := graph.region_of[ident.symbol]; found {
		return set, true
	}
	set := prov_empty_region(graph)
	set.unknown = true
	return set, true
}

// The region component of one call result. Direct summaries are substituted by
// position. A procedure value has no declaration summary, so an owning result
// conservatively retains every moved-owner and allocator argument region.
@(private = "file")
prov_call_region :: proc(graph: ^Flow_Graph, v: ^Expr_Call, result: int, result_type: Type_Id) -> Region_Set {
	c := graph.k.c
	out := prov_empty_region(graph)
	allocator_result := type_underlying(c, result_type) == TYPE_ALLOCATOR
	if !type_is_managed(c, result_type) && !allocator_result {
		return out
	}
	if v.union_op == .Extract && type_is_managed(c, result_type) {
		out.default = true
		return out
	}
	if sym := symbol_of(c, v.resolution.symbol); sym != nil && sym.builtin == .Default_Allocator {
		out.default = true
		return out
	}
	// `arena.allocator()`. Recorded here as well as in `prov_region_of`, because
	// a call's stored result summary is consulted before the expression walk.
	if set, ok := prov_handle_region(graph, v); ok {
		return set
	}
	// A fixed arena borrows its buffer but has no allocator-region parent. The
	// ordinary loan analysis carries that buffer lifetime; inventing an unknown
	// allocator dependency here would make unrelated resets spuriously overlap.
	if call_provider_op(c, v) == .Open_Fixed {
		return out
	}
	callee := v.resolution.chosen_overload
	if callee == INVALID_SYMBOL {
		callee = v.resolution.symbol
	}
	direct := prov_has_direct_body(c, callee)
	prov_note_summary_dependency(graph, callee, direct)
	if summary, found := result_summary(c, callee, result); found {
		for wanted, index in summary.region.params {
			if wanted && index < len(v.bound) && v.bound[index] != nil {
				region_merge(&out, prov_region_of(graph, v.bound[index]))
			}
		}
		out.default ||= summary.region.default
		out.unknown ||= summary.region.unknown
	}
	proc_type := INVALID_TYPE
	if sym := symbol_of(c, v.resolution.chosen_overload); sym != nil {
		proc_type = sym.proc_type
	} else if v.callee != nil {
		proc_type = expr_base(v.callee).type
	}
	info := underlying_info(c, proc_type)
	for argument, index in v.bound {
		if argument == nil {
			continue
		}
		if type_underlying(c, expr_base(argument).type) == TYPE_ALLOCATOR {
			// An owning result constructed with an allocator argument derives that
			// allocator's region at the call site.
			region_merge(&out, prov_region_of(graph, argument))
			continue
		}
		if !direct && info != nil && index < len(info.param_modes) && info.param_modes[index] == .Move {
			region_merge(&out, prov_region_of(graph, argument))
		}
	}
	if !direct && region_is_empty(out) {
		out.unknown = true
	}
	return out
}

// Which of this body's own allocator parameters an expression may name, and
// whether every one of them already carries the reset promise.
@(private = "file")
prov_reset_promise :: proc(graph: ^Flow_Graph, set: Region_Set) -> (covered: bool, name: string) {
	covered, name = false, ""
	for wanted, index in set.params {
		if !wanted {
			continue
		}
		sym := prov_parameter_symbol(graph, index)
		if sym == nil {
			continue
		}
		if !sym.allocator_reset {
			return false, identifier_text(graph.k.c, sym.name)
		}
		covered = true
	}
	return covered, ""
}

@(private = "file")
prov_parameter_symbol :: proc(graph: ^Flow_Graph, index: int) -> ^Symbol {
	literal := graph.literal
	if literal == nil || literal.signature == nil {
		return nil
	}
	position := 0
	for parameter in literal.signature.params {
		for id in parameter.symbols {
			if position == index {
				return symbol_of(graph.k.c, id)
			}
			position += 1
		}
	}
	return nil
}

// A reset may end every allocation root in that allocator region (design.md),
// so it is checked both for the promise it needs and for what would survive it.
@(private = "file")
prov_reset :: proc(graph: ^Flow_Graph, set: Region_Set, span: Span, direct: bool, at: ^Expr_Call) {
	covered, unmarked := prov_reset_promise(graph, set)
	if !direct && unmarked == "" && region_is_empty(set) {
		// Default and unknown regions are pre-existing and must not be hidden
		// merely because they are not this body's parameters.
		covered = true
	}
	// A procedure may reset a region it created locally, because no caller-owned
	// value can belong to it (design.md). No promise is needed, and none could
	// be written -- the region does not exist outside this body.
	if region_is_local_only(set) {
		covered, unmarked = true, ""
	}
	event := Prov_Event {
		kind          = .Reset,
		span          = span,
		access        = direct ? .Invalidate : .Write,
		name          = unmarked,
		region        = set,
		reset_covered = unmarked == "" && covered,
	}
	// A tracked owner whose backing region this may end is a blocker whatever its
	// carriers do, because its cleanup still has to run. Only owners of a region
	// this reset can actually reach: a second arena's containers are none of its
	// business, which is the whole point of giving each local provider a token.
	//
	//
	// An owner is live when it may be used later or still requires cleanup on an
	// outgoing path; an explicitly dropped manual owner is dead and no longer
	// blocks reset (design.md). Scope presence cannot answer that, so the answer
	// is M5a's, recorded at this same call node one pass earlier.
	dead := graph.k.c.reset_dead[at]
	for id in graph.owners_in_scope {
		owner := symbol_of(graph.k.c, id)
		if owner == nil {
			continue
		}
		if slice.contains(dead, id) {
			continue
		}
		if type_is_region_provider(graph.k.c, owner.type) {
			// The provider being reset is not its own dependant, but a live child
			// provider is: releasing the parent would invalidate the child's blocks
			// and later cleanup.
			parent, found := graph.provider_parents[id]
			if found && regions_may_overlap(parent, set) {
				event.verb = identifier_text(graph.k.c, owner.name)
				event.owner_span = owner.span
				break
			}
			continue
		}
		owner_region, found := graph.region_of[id]
		if !found || region_is_empty(owner_region) {
			continue
		}
		if !regions_may_overlap(owner_region, set) {
			continue
		}
		event.verb = identifier_text(graph.k.c, owner.name)
		event.owner_span = owner.span
		break
	}
	prov_emit(graph, event)
}

// consolidation-provenance-plan.md step 8: a borrow stored where it outlives the
// statement that stored it. The destination is resolved as a place, so a field,
// a nested container element, and a write through a tracked alias are all seen,
// not only a bare identifier. Only a destination that actually receives a borrow
// is reported, so ordinary global data costs nothing.
@(private = "file")
prov_retain_escape :: proc(graph: ^Flow_Graph, target: Expr, sources: []int, span: Span) {
	if len(sources) == 0 {
		return
	}
	root, _, ok := prov_place_of(graph, target)
	if !ok {
		// The place left lexical storage through a carrier, so which root it
		// names is a solved question rather than a syntactic one.
		if through := prov_retain_through_carrier(graph, target); len(through) > 0 {
			prov_emit(graph, Prov_Event {
				kind    = .Retain,
				span    = span,
				sources = sources,
				root    = NO_ROOT,
				into    = through,
			})
		}
		return
	}
	descriptor := graph.roots[int(root)]
	into := retain_kind_for_root(descriptor.kind)
	if into == .None {
		return
	}
	prov_emit(graph, Prov_Event {
		kind    = .Retain,
		span    = span,
		sources = sources,
		root    = root,
		retain  = into,
		verb    = descriptor.name,
	})
}

// The carrier a destination place was written through, as the slots holding it.
// `p^.view` and `d[0].view` are writes into whatever `p` and `d` point at, which
// is what the carrier's loans say; a chain that never leaves lexical storage has
// no carrier and is answered by `prov_place_of` instead.
@(private = "file")
prov_retain_through_carrier :: proc(graph: ^Flow_Graph, place: Expr) -> []int {
	c := graph.k.c
	#partial switch v in place {
	case ^Expr_Postfix:
		if v.op == .Caret {
			return prov_carrier_slots(graph, v.operand)
		}
	case ^Expr_Selector:
		if v.resolution.kind != .Field || v.operand == nil {
			return nil
		}
		if type_is_pointer(c, expr_base(v.operand).type) {
			return prov_carrier_slots(graph, v.operand) // an auto-deref
		}
		return prov_retain_through_carrier(graph, v.operand)
	case ^Expr_Index:
		if len(v.bound) > 0 || v.operand == nil {
			return nil // user-defined addressing
		}
		#partial switch underlying_kind(c, expr_base(v.operand).type) {
		case .Array, .Dynamic_Array, .Map:
			// An owner's element is a place in the owner, so the chain has not
			// left lexical storage yet.
			return prov_retain_through_carrier(graph, v.operand)
		}
		return prov_carrier_slots(graph, v.operand)
	}
	return nil
}

// The slots holding a carrier value, without reading it: a bare carrier has its
// own slot, and one inside a value has the content slot for its path.
@(private = "file")
prov_carrier_slots :: proc(graph: ^Flow_Graph, e: Expr) -> []int {
	if ident, is_ident := e.(^Expr_Ident); is_ident {
		if slot, is_carrier := prov_slot_for_symbol(graph, ident.symbol); is_carrier {
			return prov_one(graph, slot)
		}
	}
	if root, path, ok := prov_place_of(graph, e); ok {
		return prov_content_at(graph, root, path)
	}
	return prov_retain_through_carrier(graph, e)
}

// An owner backed by a region the procedure received may not be returned,
// assigned to `static`, `thread_local`, or file-scope storage (design.md).
@(private = "file")
prov_region_escape :: proc(graph: ^Flow_Graph, target: Expr, value: Expr, result := 0) {
	// The destination is a *place*, not only a bare name: wrapping an owner in a
	// global's field must not lose the region obligation the bare form has,
	// which is the same rule aggregate provenance applies to borrows.
	if !type_is_managed(graph.k.c, expr_base(target).type) {
		return
	}
	root, _, ok := prov_place_of(graph, target)
	if !ok {
		return
	}
	sym := symbol_of(graph.k.c, graph.roots[int(root)].symbol)
	if sym == nil {
		return
	}
	storage := ""
	switch {
	case sym.duration == .Thread_Local: storage = "`thread_local` storage"
	case sym.duration == .Static:       storage = "`static` storage"
	case sym.decl != nil && sym.decl.top_level: storage = "file-scope storage"
	}
	if storage == "" {
		return
	}
	// An allocating clone receives the destination allocator's region provenance
	// (design.md). Assigning a place *copies* it, so the destination is built
	// with its own allocator and inherits nothing; only a `move`, a call result,
	// or a constructed aggregate carries a region into the destination.
	if type_is_managed(graph.k.c, expr_base(value).type) && expression_is_borrowed_place(graph.k.c, value) {
		return
	}
	set := prov_result_region(graph, value, result)
	if !region_is_parameter_backed(set) && !region_has_local(set) {
		return
	}
	prov_emit(graph, Prov_Event {
		kind   = .Region_Escape,
		span   = expr_span(target),
		verb   = identifier_text(graph.k.c, sym.name),
		name   = storage,
		region = set,
	})
}

// ------------------------------------------------------------- places --

// The root and normalized projection path a place expression names, or no root
// when the chain leaves lexical storage through a carrier. Reaching a pointee or
// a slice element is a *use of the carrier*, not a competing access to the root,
// which is what lets access through a live borrow stay legal.
@(private = "file")
prov_place_of :: proc(graph: ^Flow_Graph, e: Expr) -> (Root_Id, []Proj_Step, bool) {
	c := graph.k.c
	#partial switch v in e {
	case ^Expr_Ident:
		root := prov_root_for_symbol(graph, v.symbol)
		return root, nil, root != NO_ROOT

	case ^Expr_Selector:
		// A bare `.Member` has no operand at all, and a non-field selection names
		// a package, an enum member, or a method rather than storage.
		if v.resolution.kind != .Field || v.operand == nil {
			return NO_ROOT, nil, false
		}
		operand_type := expr_base(v.operand).type
		if type_is_pointer(c, operand_type) {
			return NO_ROOT, nil, false // an auto-deref reaches another root
		}
		root, path, ok := prov_place_of(graph, v.operand)
		if !ok {
			return NO_ROOT, nil, false
		}
		step := proj_wild()
		if !type_is_union(c, operand_type) {
			if field := symbol_of(c, v.resolution.symbol); field != nil {
				step = proj_field(int(field.index))
			}
		}
		return root, prov_extend(graph, path, step), true

	case ^Expr_Index:
		if len(v.bound) > 0 || v.operand == nil {
			return NO_ROOT, nil, false // user-defined addressing
		}
		// A container element is a place in its owner's *current allocation*, so
		// the container is the root and every relocating operation on it ends the
		// pointer. Which slot is unknowable once the storage can move, so the
		// projection is the whole container.
		#partial switch underlying_kind(c, expr_base(v.operand).type) {
		case .Array:
			root, path, ok := prov_place_of(graph, v.operand)
			if !ok {
				return NO_ROOT, nil, false
			}
			return root, prov_extend(graph, path, prov_index_step(graph, v.indices)), true
		case .Dynamic_Array:
			root, path, ok := prov_place_of(graph, v.operand)
			if !ok {
				return NO_ROOT, nil, false
			}
			return root, prov_extend(graph, path, proj_wild()), true
		case .Map:
			// design.md "Maps": insertion may reallocate the map, so the index is a
			// mutable borrow of `m` for the duration of the statement. Rehashing
			// moves every slot, so no narrower projection would be true.
			//
			// The second step says this is the value half of an entry, matching
			// what `carrier_shape` names: a key is never a place, so it can only
			// be reached through the shape, and a value read must not inherit
			// what a key borrows.
			root, path, ok := prov_place_of(graph, v.operand)
			if !ok {
				return NO_ROOT, nil, false
			}
			entry := prov_extend(graph, path, proj_wild())
			return root, prov_extend(graph, entry, proj_field(PROJ_MAP_VALUE)), true
		}
		return NO_ROOT, nil, false
	}
	return NO_ROOT, nil, false
}

// Index expressions inside a place chain are ordinary values and still have to
// be walked; the place itself contributes one access, not one per link.
@(private = "file")
prov_walk_subscripts :: proc(graph: ^Flow_Graph, e: Expr) {
	#partial switch v in e {
	case ^Expr_Selector:
		prov_walk_subscripts(graph, v.operand)
	case ^Expr_Index:
		prov_walk_subscripts(graph, v.operand)
		for index in v.indices {
			walk_flow_expr(graph, index)
		}
	}
}

@(private = "file")
prov_const_int :: proc(graph: ^Flow_Graph, e: Expr) -> (i64, bool) {
	base := expr_base(e)
	if base == nil || !base.is_const || base.const_value.kind != .Integer {
		return 0, false
	}
	return bi_to_i64(graph.k.c, base.const_value.integer)
}

@(private = "file")
prov_index_step :: proc(graph: ^Flow_Graph, indices: []Expr) -> Proj_Step {
	if len(indices) != 1 {
		return proj_wild()
	}
	value, ok := prov_const_int(graph, indices[0])
	if !ok {
		return proj_wild()
	}
	return proj_range(value, value + 1)
}

@(private = "file")
prov_range_step :: proc(graph: ^Flow_Graph, v: ^Expr_Slice) -> Proj_Step {
	low, low_ok := i64(0), true
	if v.lo != nil {
		low, low_ok = prov_const_int(graph, v.lo)
	}
	high, high_ok := i64(0), false
	if v.hi != nil {
		high, high_ok = prov_const_int(graph, v.hi)
	} else if info := v.operand == nil ? nil : underlying_info(graph.k.c, expr_base(v.operand).type);
	   info != nil && info.kind == .Array {
		high, high_ok = i64(info.count), true
	}
	if !low_ok || !high_ok || high <= low {
		return proj_wild()
	}
	return proj_range(low, high)
}

// ------------------------------------------------------- statement hooks --

@(private = "file")
prov_read_ident :: proc(graph: ^Flow_Graph, v: ^Expr_Ident, kind: Access_Kind) -> []int {
	if root := prov_root_for_symbol(graph, v.symbol); root != NO_ROOT {
		prov_access(graph, root, nil, kind, v.span)
	}
	if slot, is_carrier := prov_slot_for_symbol(graph, v.symbol); is_carrier {
		sources := prov_one(graph, slot)
		prov_emit(graph, Prov_Event{kind = .Live, sources = sources, span = v.span})
		return sources
	}
	// Reading a carrier that lives in static or thread storage yields a borrow of
	// that storage, which is what lets a later store ask whether it outlives its
	// destination — a `thread_local` view does not outlive the process
	// (consolidation-provenance-plan.md step 8).
	if sym := symbol_of(graph.k.c, v.symbol); sym != nil && sym.duration != .None {
		if type_is_carrier(graph.k.c, sym.type) {
			if root := prov_root_for_symbol(graph, v.symbol); root != NO_ROOT {
				return prov_borrow(
					graph, root, nil,
					carrier_is_mutable(graph.k.c, sym.type),
					v.span,
					carrier_noun(graph.k.c, sym.type),
				)
			}
		}
	}
	// Reading a whole aggregate reads everything it holds.
	if content := prov_content_slots(graph, v.symbol); len(content) > 0 {
		prov_emit(graph, Prov_Event{kind = .Live, sources = content, span = v.span})
		return content
	}
	return nil
}

@(private = "file")
prov_invalidate :: proc(graph: ^Flow_Graph, place: Expr, span: Span, verb: string) {
	if root, path, ok := prov_place_of(graph, place); ok {
		prov_walk_subscripts(graph, place)
		prov_access(graph, root, path, .Invalidate, span, verb)
		return
	}
	walk_flow_expr(graph, place)
}

@(private = "file")
prov_address_of :: proc(graph: ^Flow_Graph, v: ^Expr_Unary) -> []int {
	// `&place` is an immutable loan and `&mut place` an exclusive one: several
	// `&` borrows of one place may be live together, while a `&mut` excludes
	// every competing name (design.md "Capabilities and the one rule").
	root, path, ok := prov_place_of(graph, v.operand)
	if !ok {
		loans := walk_flow_expr(graph, v.operand)
		if len(loans) > 0 || !prov_expr_is_temporary(v.operand) {
			return loans
		}
		// A borrow of a value temporary may be used during that expression,
		// including by a called procedure, but cannot escape it (design.md).
		return prov_borrow(graph, prov_temp_root(graph, expr_span(v.operand)), nil, v.mutable, v.span, "pointer")
	}
	prov_walk_subscripts(graph, v.operand)
	access_block, access_index := prov_access(graph, root, path, v.mutable ? .Write : .Read, v.span)
	return prov_borrow(graph, root, path, v.mutable, v.span, "pointer", access_block, access_index)
}

@(private = "file")
prov_slice :: proc(graph: ^Flow_Graph, v: ^Expr_Slice) -> []int {
	if len(v.bound) > 0 {
		// A selected `operator([:])` result is a borrow of the receiver unless
		// its result type is owning (design.md). M4a deliberately postponed this
		// relationship because it needed provenance.
		receiver_loans := walk_flow_expr(graph, v.bound[0])
		for index in 1 ..< len(v.bound) {
			if v.bound[index] != nil {
				walk_flow_expr(graph, v.bound[index])
			}
		}
		if !type_is_carrier(graph.k.c, v.type) {
			return nil // an owning result carries no borrow edge at all
		}
		if len(receiver_loans) > 0 {
			return receiver_loans
		}
		if root, path, ok := prov_place_of(graph, v.bound[0]); ok {
			return prov_borrow(graph, root, path, slice_is_mutable(graph.k.c, v.type), v.span, "slice")
		}
		return nil
	}
	mutable := slice_is_mutable(graph.k.c, v.type)
	// Only a fixed array is sliced out of a root's own inline storage. Slicing a
	// slice, a pointer or a string view reslices the carrier, so the loans it
	// already holds are what the result borrows.
	// `st[low:high]` borrows a subrange view of the string's own storage,
	// exactly as slicing a fixed array borrows the array's (design.md).
	// design.md "Dynamic arrays": indexing and slicing produce views into the
	// current allocation, so a container lends from its own root too — that
	// borrow is what every relocating operation on it then invalidates.
	operand_kind := underlying_kind(graph.k.c, expr_base(v.operand).type)
	array := operand_kind == .Array || operand_kind == .String || operand_kind == .Dynamic_Array
	if root, path, ok := prov_place_of(graph, v.operand); ok && array {
		prov_walk_subscripts(graph, v.operand)
		if v.lo != nil {
			walk_flow_expr(graph, v.lo)
		}
		if v.hi != nil {
			walk_flow_expr(graph, v.hi)
		}
		full := prov_extend(graph, path, prov_range_step(graph, v))
		access_block, access_index := prov_access(graph, root, full, mutable ? .Write : .Read, v.span)
		return prov_borrow(
			graph, root, full, mutable, v.span, carrier_noun(graph.k.c, v.type),
			access_block, access_index,
		)
	}
	// Reslicing a carrier keeps the loans it already holds. Composing the two
	// ranges could only narrow the result, so the source loans are both the
	// conservative and the correct answer.
	source := walk_flow_expr(graph, v.operand)
	if v.lo != nil {
		walk_flow_expr(graph, v.lo)
	}
	if v.hi != nil {
		walk_flow_expr(graph, v.hi)
	}
	if len(source) > 0 {
		return source
	}
	// A slice literal borrows a hidden array, which follows the surrounding
	// lexical scope (design.md); any other temporary ends with its statement.
	if _, is_literal := v.operand.(^Expr_Composite); is_literal {
		root := prov_new_root(graph, .Slice_Literal, expr_span(v.operand), "this slice literal")
		append(&graph.in_scope, Flow_Cleanup{kind = .Prov_Root, root = root, span = expr_span(v.operand)})
		return prov_borrow(graph, root, nil, mutable, v.span, "slice")
	}
	if prov_expr_is_temporary(v.operand) {
		return prov_borrow(graph, prov_temp_root(graph, expr_span(v.operand)), nil, mutable, v.span, "slice")
	}
	return nil
}

// The borrow a `foreach` holds on its iterable. Iterating a carrier reuses the
// loans it already holds; iterating a place borrows that place, mutably when the
// binding is written `ref` over a mutable sequence.
@(private = "file")
prov_iterate :: proc(graph: ^Flow_Graph, s: ^Stmt_Foreach, iterated: []int) -> []int {
	if len(iterated) > 0 {
		return iterated
	}
	root, path, ok := prov_place_of(graph, s.iterable)
	if !ok {
		return nil
	}
	mutable := false
	for binding in s.bindings {
		mutable ||= binding.is_ref
	}
	span := expr_span(s.iterable)
	prov_access(graph, root, path, mutable ? .Write : .Read, span)
	return prov_borrow(graph, root, path, mutable, span, "iterator")
}

// A root that ends with the statement that created it.
@(private = "file")
prov_temp_root :: proc(graph: ^Flow_Graph, span: Span) -> Root_Id {
	root := prov_new_root(graph, .Temporary, span, "this temporary")
	append(&graph.temp_roots, root)
	return root
}

@(private = "file")
prov_expr_is_temporary :: proc(e: Expr) -> bool {
	#partial switch _ in e {
	case ^Expr_Composite, ^Expr_Call:
		return true
	}
	return false
}

@(private = "file")
prov_declare :: proc(graph: ^Flow_Graph, d: ^Decl, value_loans: [][]int) {
	for id, symbol_index in d.symbols {
		sym := symbol_of(graph.k.c, id)
		if sym == nil || sym.kind != .Var {
			continue
		}
		root := prov_root_for_symbol(graph, id)
		if root != NO_ROOT && graph.roots[int(root)].kind == .Local {
			append(&graph.in_scope, Flow_Cleanup{kind = .Prov_Root, root = root, span = sym.span})
		}
		initializer: Expr
		if len(d.values) == 1 && len(d.symbols) > 1 {
			// One multi-result call initializes every declaration on the left.
			// `result_index` below selects the matching root and region component.
			initializer = d.values[0]
		} else if symbol_index < len(d.values) {
			initializer = d.values[symbol_index]
		}
		result_index := len(d.values) == 1 && len(d.symbols) > 1 ? symbol_index : 0
		prov_declare_region(graph, id, sym, initializer, result_index)
		slot, is_carrier := prov_slot_for_symbol(graph, id)
		content := prov_content_slots(graph, id)
		if !is_carrier && len(content) == 0 {
			continue
		}
		sources: []int
		if value_loans != nil {
			if len(d.values) == 1 && len(d.symbols) > 1 {
				sources = prov_result_loans(graph, d.values[0], symbol_index, value_loans[0])
			} else if symbol_index < len(value_loans) {
				sources = value_loans[symbol_index]
			}
		}
		if !is_carrier {
			prov_define_content(graph, content, sources, sym.span)
			continue
		}
		prov_weaken(graph, sources, sym.type, slot, sym.span)
		prov_emit(graph, Prov_Event {
			kind    = .Def,
			slot    = slot,
			loan    = NO_LOAN,
			sources = sources,
			span    = sym.span,
		})
	}
}


// An allocator binding inherits the identity it was initialised from; a managed
// owner inherits the region its constructing call named.
@(private = "file")
prov_declare_region :: proc(graph: ^Flow_Graph, id: Symbol_Id, sym: ^Symbol, initializer: Expr, result := 0) {
	// design.md: a local `mem.Arena`/`mem.Scratch` *is* a region this body
	// created, so it gets its own token rather than merging into anything.
	if type_is_region_provider(graph.k.c, sym.type) && sym.duration == .None {
		graph.region_of[id] = prov_provider_region(graph, id)
		if initializer != nil {
			parent := prov_result_region(graph, initializer, result)
			if !region_is_empty(parent) {
				graph.provider_parents[id] = parent
			}
		}
		append(&graph.owners_in_scope, id)
		append(&graph.in_scope, Flow_Cleanup{kind = .Prov_Owner, slot = len(graph.owners_in_scope) - 1})
		return
	}
	if type_underlying(graph.k.c, sym.type) == TYPE_ALLOCATOR {
		if initializer != nil {
			graph.region_of[id] = prov_result_region(graph, initializer, result)
		}
		return
	}
	if !type_is_managed(graph.k.c, sym.type) {
		return
	}
	set := prov_empty_region(graph)
	// An explicit `via` allocator is bound at the declaration (design.md). That
	// binding, not the initialiser, is what decides an owner's region -- a literal
	// `{}` names no region at all, and `via arena.allocator()` names one exactly.
	if written := symbol_via_allocator(graph.k.c, id); written != nil {
		region_merge(&set, prov_region_of(graph, written))
	}
	if initializer != nil {
		region_merge(&set, prov_result_region(graph, initializer, result))
	}
	if !region_is_empty(set) {
		graph.region_of[id] = set
		if sym.duration != .None && (region_is_parameter_backed(set) || region_has_local(set)) {
			storage := sym.duration == .Thread_Local ? "`thread_local` storage" : "`static` storage"
			prov_emit(graph, Prov_Event {
				kind   = .Region_Escape,
				span   = sym.span,
				verb   = identifier_text(graph.k.c, sym.name),
				name   = storage,
				region = set,
			})
		}
	}
	// Resetting a region is rejected while a live owning value, managed or
	// manual, still refers to storage from that allocator (design.md). All
	// lexical owners register once; the flow-insensitive region map may learn a
	// dependency from a later assignment.
	if sym.duration == .None {
		append(&graph.owners_in_scope, id)
		append(&graph.in_scope, Flow_Cleanup{kind = .Prov_Owner, slot = len(graph.owners_in_scope) - 1})
	}
}

@(private = "file")
prov_assign :: proc(graph: ^Flow_Graph, s: ^Stmt_Assign, value_loans: [][]int) {
	for target, index in s.lhs {
		sources: []int
		value: Expr
		result_index := 0
		if len(s.rhs) == 1 && len(s.lhs) > 1 {
			value = s.rhs[0]
			result_index = index
			if value_loans != nil && len(value_loans) > 0 {
				sources = prov_result_loans(graph, value, result_index, value_loans[0])
			}
		} else if index < len(s.rhs) {
			value = s.rhs[index]
			if value_loans != nil && index < len(value_loans) {
				sources = value_loans[index]
			}
		}
		if value != nil && s.op == .Assign {
			prov_region_escape(graph, target, value, result_index)
		}
		if ident, is_ident := target.(^Expr_Ident); is_ident && s.op == .Assign {
			if value != nil {
				if type_underlying(graph.k.c, expr_base(target).type) == TYPE_ALLOCATOR {
					existing, found := graph.region_of[ident.symbol]
					if !found {
						existing = prov_empty_region(graph)
					}
					region_merge(&existing, prov_result_region(graph, value, result_index))
					graph.region_of[ident.symbol] = existing
				} else if type_is_managed(graph.k.c, expr_base(target).type) {
					existing, found := graph.region_of[ident.symbol]
					if !found {
						existing = prov_empty_region(graph)
					}
					region_merge(&existing, prov_result_region(graph, value, result_index))
					graph.region_of[ident.symbol] = existing
				}
			}
			prov_retain_escape(graph, target, sources, expr_span(target))
			// Moving, dropping, freeing, fully assigning, or exchanging a root
			// invalidates borrows of its previous value (design.md).
			prov_invalidate(graph, target, expr_span(target), "assigned")
			if slot, is_carrier := prov_slot_for_symbol(graph, ident.symbol); is_carrier {
				prov_weaken(graph, sources, expr_base(target).type, slot, expr_span(target))
				prov_emit(graph, Prov_Event {
					kind    = .Def,
					slot    = slot,
					loan    = NO_LOAN,
					sources = sources,
					span    = expr_span(target),
				})
			} else if content := prov_content_slots(graph, ident.symbol); len(content) > 0 {
				// Replacing the whole value replaces everything it held.
				prov_define_content(graph, content, sources, expr_span(target))
			}
			continue
		}
		// A write through a field or an element touches only that path.
		prov_retain_escape(graph, target, sources, expr_span(target))
		if _, _, ok := prov_place_of(graph, target); !ok && s.op == .Assign && len(sources) > 0 {
			// The destination is reached through a carrier, so what it names is
			// solved rather than written out.
			if through := prov_retain_through_carrier(graph, target); len(through) > 0 {
				// The destination's own type still decides the capability, exactly
				// as it would if the place had been written out: a fresh mutable
				// borrow written into a read-only field is simply created
				// read-only (design.md "Weakening and read-only reborrows").
				prov_weaken(graph, sources, expr_base(target).type)
				prov_emit(graph, Prov_Event {
					kind    = .Publish,
					span    = expr_span(target),
					sources = sources,
					into    = through,
				})
			}
		}
		if root, path, ok := prov_place_of(graph, target); ok {
			prov_walk_subscripts(graph, target)
			prov_access(graph, root, path, .Write, expr_span(target))
			// Only the written path is replaced; the surviving fields keep what
			// they held.
			if written := prov_content_at(graph, root, path); len(written) > 0 && s.op == .Assign {
				prov_define_content(graph, written, sources, expr_span(target), path)
			}
			continue
		}
		walk_flow_expr(graph, target)
	}
}

// The procedure type a call goes through: the chosen overload's when the callee
// is a declaration, and the callee expression's own when it is a value. The
// second is the one that matters for `@(escape=...)`, because an indirect call
// is exactly where there is no body to infer from.
@(private = "file")
prov_call_proc_type :: proc(graph: ^Flow_Graph, v: ^Expr_Call) -> Type_Id {
	if sym := symbol_of(graph.k.c, v.resolution.chosen_overload); sym != nil {
		return sym.proc_type
	}
	if base := expr_base(v.callee); base != nil {
		return base.type
	}
	return INVALID_TYPE
}

// The loans of every argument whose parameter may still be named after the call.
// A parameter written `@(escape=none)` promises nothing survives, which is what
// keeps a scratch argument out of an indirect call's conservative result.
@(private = "file")
prov_escaping_actuals :: proc(graph: ^Flow_Graph, v: ^Expr_Call, actuals: [][]int) -> []int {
	proc_type := prov_call_proc_type(graph, v)
	out: []int
	for slots, index in actuals {
		if proc_param_escape(graph.k.c, proc_type, index) == .None {
			continue
		}
		out = prov_join(graph, out, slots)
	}
	return out
}

prov_parameter_type :: proc(graph: ^Flow_Graph, v: ^Expr_Call, index: int) -> Type_Id {
	sym := symbol_of(graph.k.c, v.resolution.chosen_overload)
	if sym == nil {
		return INVALID_TYPE
	}
	info := type_of(graph.k.c, sym.proc_type)
	if info == nil || index >= len(info.parameters) {
		return INVALID_TYPE
	}
	return info.parameters[index]
}

@(private = "file")
prov_has_direct_body :: proc(c: ^Compiler, id: Symbol_Id) -> bool {
	sym := symbol_of(c, id)
	if sym == nil || sym.kind != .Proc {
		return false
	}
	if sym.proc_literal != nil {
		return sym.proc_literal.body != nil
	}
	if sym.decl != nil {
		literal := decl_proc(sym.decl)
		return literal != nil && literal.body != nil
	}
	return false
}

@(private = "file")
prov_result_is_inout :: proc(graph: ^Flow_Graph, v: ^Expr_Call, result: int) -> bool {
	sym := symbol_of(graph.k.c, v.resolution.chosen_overload)
	if sym == nil {
		return false
	}
	info := type_of(graph.k.c, sym.proc_type)
	return info != nil && result < len(info.result_inout) && info.result_inout[result]
}

@(private = "file")
prov_argument_is_inout :: proc(graph: ^Flow_Graph, v: ^Expr_Call, index: int) -> bool {
	// The declaration's type when there is one, the callee value's otherwise: a
	// parameter mode is part of procedure-type compatibility, so an indirect call
	// answers this question as well as a direct one does.
	info := type_of(graph.k.c, prov_call_proc_type(graph, v))
	if info == nil || index >= len(info.param_modes) {
		return false
	}
	return info.param_modes[index] == .Inout
}

@(private = "file")
prov_call :: proc(graph: ^Flow_Graph, v: ^Expr_Call) -> []int {
	c := graph.k.c
	if v.text != .None || v.text_conversion != .None {
		return prov_text_call(graph, v)
	}
	if sym := symbol_of(c, v.resolution.symbol); sym != nil && sym.kind == .Builtin {
		#partial switch sym.builtin {
		case .New, .New_Clone:
			for argument in v.bound {
				if argument != nil {
					walk_flow_expr(graph, argument)
				}
			}
			// `new` creates a new allocation root and returns a checked pointer to
			// its first value (design.md).
			root := prov_new_root(graph, .Allocation, v.span, "this allocation")
			graph.roots[int(root)].symbol = INVALID_SYMBOL
			return prov_borrow(graph, root, nil, true, v.span, "pointer")
		case .Free:
			if len(v.bound) >= 1 {
				sources := walk_flow_expr(graph, v.bound[0])
				prov_emit(graph, Prov_Event{kind = .Free, sources = sources, span = v.span})
			}
			return nil
		case .Free_All:
			if len(v.bound) >= 1 {
				region := prov_region_of(graph, v.bound[0])
				walk_flow_expr(graph, v.bound[0])
				prov_reset(graph, region, v.span, true, v)
			}
			return nil
		case .Drop:
			if len(v.bound) == 1 {
				prov_invalidate(graph, v.bound[0], v.span, "dropped")
			}
			return nil
		case .Exchange:
			if len(v.bound) == 2 {
				prov_invalidate(graph, v.bound[0], v.span, "exchanged")
				walk_flow_expr(graph, v.bound[1])
			}
			return nil
		}
	}
	receiver := Param_Mode.Value
	has_receiver := false
	map_value_borrow := false
	container_op := Container_Op.None
	if sym := symbol_of(c, v.resolution.chosen_overload); sym != nil && sym.has_receiver {
		receiver, has_receiver = sym.receiver, true
		if sym.synth == .Container_Op {
			container_op = sym.container_op
		}
		map_value_borrow = container_op == .Map_Lookup_Value && type_is_carrier(c, sym.results[0])
	}
	// Method-call syntax puts the receiver in `bound[0]`; walking the callee
	// selector as well would count one access twice.
	if !(has_receiver && len(v.bound) > 0) {
		walk_flow_expr(graph, v.callee)
	}
	if len(v.bound) == 0 {
		actuals := make([][]int, max(len(v.args), 1), graph.alloc)
		borrowed: []int
		for argument, index in v.args {
			actuals[index] = walk_flow_expr(graph, argument.value)
			borrowed = prov_join(graph, borrowed, actuals[index])
		}
		// A reset happens during the call, after argument evaluation, while every
		// borrow handed to the callee is still live. Put the reset before the call
		// boundary use so backward liveness sees those actuals at the reset.
		prov_call_resets(graph, v)
		if len(borrowed) > 0 {
			prov_emit(graph, Prov_Event{kind = .Live, sources = borrowed, span = v.span})
		}
			return prov_store_call_results(graph, v, actuals, borrowed)
	}
	// The loans each actual argument carried, so a direct call can substitute
	// them into the callee's result summary.
	actuals := make([][]int, len(v.bound), graph.alloc)
	borrowed: []int
	for argument, index in v.bound {
		// design.md "Variadic parameters": the pack slot holds no single written
		// expression unless a sole spread is forwarded. Its operands are walked
		// here so each one's borrows still reach the call boundary.
		if v.is_variadic && index == v.variadic_slot && !v.variadic_forwards {
			actuals[index] = prov_variadic_pack(graph, v)
			borrowed = prov_join(graph, borrowed, actuals[index])
			continue
		}
		if argument == nil {
			continue
		}
		if index == 0 && receiver == .Move {
			// A consumed receiver hands its contents to the callee, so a result
			// derived from it depends on what the receiver held.
			// The move expression's own span, not the whole call's: what conflicts
			// is the consumption of the receiver.
			actuals[index] = prov_consume(graph, argument, expr_span(argument), "moved")
			borrowed = prov_join(graph, borrowed, actuals[index])
			continue
		}
		// Any user operation whose `self` parameter is `inout` also invalidates
		// element and view borrows of the receiver (design.md).
		if index == 0 && receiver == .Inout {
			prov_invalidate(graph, argument, v.span, "modified")
			if root, path, ok := prov_place_of(graph, argument); ok {
				actuals[index] = prov_borrow(graph, root, path, true, expr_span(argument), "borrow")
				borrowed = prov_join(graph, borrowed, actuals[index])
			}
			continue
		}
		if prov_argument_is_inout(graph, v, index) {
			if root, path, ok := prov_place_of(graph, argument); ok {
				prov_walk_subscripts(graph, argument)
				prov_access(graph, root, path, .Write, expr_span(argument))
				// An `inout` parameter aliases the caller's root, so a borrow returned
				// from it is derived from that root (design.md).
				actuals[index] = prov_borrow(graph, root, path, true, expr_span(argument), "borrow")
				borrowed = prov_join(graph, borrowed, actuals[index])
				continue
			}
		}
		actuals[index] = walk_flow_expr(graph, argument)
		if index == 0 && map_value_borrow {
			// A map is an owner, so reading its identifier carries no loans.
			// A borrowed payload nevertheless depends on its current contents.
			if root, path, ok := prov_place_of(graph, argument); ok {
				actuals[index] = prov_borrow(graph, root, prov_extend(graph, path, proj_wild()), carrier_is_mutable(c, v.type), v.span, "map value")
			} else if prov_expr_is_temporary(argument) {
				root := prov_temp_root(graph, expr_span(argument))
				actuals[index] = prov_borrow(graph, root, nil, carrier_is_mutable(c, v.type), v.span, "map value")
			}
		}
		prov_weaken(graph, actuals[index], prov_parameter_type(graph, v, index))
		borrowed = prov_join(graph, borrowed, actuals[index])
	}
	prov_call_resets(graph, v)
	prov_call_retention(graph, v, actuals)
	prov_container_content(graph, v, container_op, actuals)
	if len(borrowed) > 0 {
		prov_emit(graph, Prov_Event{kind = .Live, sources = borrowed, span = v.span})
	}
	return prov_store_call_results(graph, v, actuals, borrowed)
}

// The caller's half of `@(escape=...)`, which the callee's body check cannot
// answer: only the caller knows how long the storage behind an argument lives.
//
// `static` is direct — the argument has to still be there when the process ends.
// `stored` says the callee may write the argument into a destination this call
// hands it, so the call is modelled as exactly that assignment: the same
// duration check an assignment gets, and the same flow, so the destination
// carries what the argument borrowed and the existing scope rules answer the
// rest. Modelling the flow is what makes a caller-local destination work without
// proving one local outlives another — the loan simply travels, and using it
// after its root has ended is already an error.
@(private = "file")
prov_call_retention :: proc(graph: ^Flow_Graph, v: ^Expr_Call, actuals: [][]int) {
	proc_type := prov_call_proc_type(graph, v)
	if type_of(graph.k.c, proc_type) == nil {
		return
	}
	destinations: []int
	for slots, index in actuals {
		if len(slots) == 0 {
			continue
		}
		level := proc_param_escape(graph.k.c, proc_type, index)
		if level == .Static {
			prov_emit(graph, Prov_Event {
				kind    = .Retain,
				span    = v.span,
				sources = slots,
				root    = NO_ROOT,
				retain  = .Process,
				verb    = prov_parameter_label(graph, v, index),
			})
		}
		if level < .Stored {
			continue
		}
		if destinations == nil {
			destinations = prov_writable_arguments(graph, v, proc_type)
		}
		for target in destinations {
			if target != index {
				prov_retain_into_argument(graph, v, target, actuals[target], slots)
			}
		}
	}
}

// The arguments a call can write through, which is where a `stored` parameter
// may end up: an `inout` parameter or receiver, and a mutable carrier whose
// pointee or element could hold the borrow. These are the destinations the body
// check recognises, so caller and callee agree on the set.
//
// A destination that cannot hold a borrow at all is not one: `inout int` names
// caller storage, but nothing a call retains can land in it.
@(private = "file")
prov_writable_arguments :: proc(graph: ^Flow_Graph, v: ^Expr_Call, proc_type: Type_Id) -> []int {
	c := graph.k.c
	out := make([dynamic]int, 0, len(v.bound), graph.alloc)
	sym := symbol_of(c, v.resolution.chosen_overload)
	// A receiver is `bound[0]` and answers with its own mode; an ordinary
	// parameter answers with the procedure type's.
	start := 0
	if sym != nil && sym.has_receiver {
		start = 1
		if sym.receiver == .Inout && len(v.bound) > 0 && v.bound[0] != nil {
			if type_carries_borrow(c, expr_base(v.bound[0]).type).any {
				append(&out, 0)
			}
		}
	}
	info := type_of(c, proc_type)
	for index in start ..< len(v.bound) {
		if info == nil || index >= len(info.parameters) {
			break
		}
		if prov_argument_is_inout(graph, v, index) {
			if type_carries_borrow(c, info.parameters[index]).any {
				append(&out, index)
			}
			continue
		}
		// Writing through the parameter itself: `p^.view = values`. What can be
		// retained is what the pointee or element holds, not the pointer.
		if !carrier_is_mutable(c, info.parameters[index]) {
			continue
		}
		element := underlying_info(c, info.parameters[index])
		if element != nil && type_carries_borrow(c, element.element).any {
			append(&out, index)
		}
	}
	return out[:]
}

// One argument receiving what another may leave in it. The duration question is
// the assignment's — a destination in static, thread, or the caller's own
// storage needs a source that outlives it — and the flow is the assignment's
// too, joined rather than replaced because the callee may also leave it alone.
//
// Which storage the argument names depends on how it was passed. An `inout`
// argument *is* the destination place. A `^mut`/`[]mut` argument is a carrier
// pointing at the destination, so both halves go through its loans instead:
// `carrier` is what it borrows, and the solver reads the roots off it.
@(private = "file")
prov_retain_into_argument :: proc(
	graph: ^Flow_Graph,
	v: ^Expr_Call,
	index: int,
	carrier: []int,
	sources: []int,
) {
	argument := v.bound[index]
	if argument == nil {
		return
	}
	if !prov_argument_is_place(graph, v, index) {
		if len(carrier) == 0 {
			return
		}
		prov_emit(graph, Prov_Event {
			kind    = .Retain,
			span    = v.span,
			sources = sources,
			root    = NO_ROOT,
			into    = carrier,
		})
		prov_emit(graph, Prov_Event {
			kind    = .Publish,
			span    = v.span,
			sources = sources,
			into    = carrier,
		})
		return
	}
	root, path, ok := prov_place_of(graph, argument)
	if !ok {
		return
	}
	prov_retain_escape(graph, argument, sources, v.span)
	slots := prov_content_at(graph, root, path)
	if len(slots) == 0 {
		ident, is_ident := argument.(^Expr_Ident)
		if !is_ident {
			return
		}
		slot, is_carrier := prov_slot_for_symbol(graph, ident.symbol)
		if !is_carrier {
			return
		}
		slots = prov_one(graph, slot)
	}
	for slot in slots {
		prov_define_one_content(graph, slot, prov_join(graph, prov_one(graph, slot), sources), v.span)
	}
}

// Whether this argument names the destination itself rather than pointing at it.
@(private = "file")
prov_argument_is_place :: proc(graph: ^Flow_Graph, v: ^Expr_Call, index: int) -> bool {
	if index == 0 {
		if sym := symbol_of(graph.k.c, v.resolution.chosen_overload); sym != nil && sym.has_receiver {
			return sym.receiver == .Inout
		}
	}
	return prov_argument_is_inout(graph, v, index)
}

@(private = "file")
prov_parameter_label :: proc(graph: ^Flow_Graph, v: ^Expr_Call, index: int) -> string {
	sym := symbol_of(graph.k.c, v.resolution.chosen_overload)
	if sym == nil || index >= len(sym.param_symbols) {
		return "a parameter this call may keep"
	}
	bound := symbol_of(graph.k.c, sym.param_symbols[index])
	if bound == nil {
		return "a parameter this call may keep"
	}
	return fmt.aprintf(
		"`%s`, which `%s` may keep",
		identifier_text(graph.k.c, bound.name),
		identifier_text(graph.k.c, sym.name),
		allocator = graph.k.c.semantic_allocator,
	)
}

// consolidation-provenance-plan.md step 6. A container operation is resolved
// before this point, so the solver asks `Container_Op` rather than recognising a
// member name. A stored element's borrows become the container's, at the element
// content path — which is indistinct, so they join what is already there rather
// than replacing it. An unknown index cannot erase the other elements' loans.
@(private = "file")
prov_container_content :: proc(graph: ^Flow_Graph, v: ^Expr_Call, op: Container_Op, actuals: [][]int) {
	#partial switch op {
	case .Append, .Try_Append, .Insert, .Try_Insert, .Map_Try_Insert:
	case:
		return
	}
	if len(v.bound) == 0 || v.bound[0] == nil {
		return
	}
	root, path, ok := prov_place_of(graph, v.bound[0])
	if !ok {
		return
	}
	stored: []int
	for index in 1 ..< len(actuals) {
		stored = prov_join(graph, stored, actuals[index])
	}
	if len(stored) == 0 {
		return
	}
	// Every element path of the receiver, keys included: which argument is the
	// key and which the value is not worth a second rule while an unknown index
	// already joins them.
	if content := prov_content_at(graph, root, path); len(content) > 0 {
		prov_define_content(graph, content, stored, v.span)
	}
}

// Every operand of an unforwarded variadic pack, in written order. The pack
// itself is compiler-owned stack storage, so its loans are exactly the union of
// what its elements and spreads carry.
@(private = "file")
prov_variadic_pack :: proc(graph: ^Flow_Graph, v: ^Expr_Call) -> []int {
	joined: []int
	next_element, next_spread := 0, 0
	for is_spread in v.variadic_order {
		operand: Expr
		if is_spread {
			operand = v.variadic_spreads[next_spread]
			next_spread += 1
		} else {
			operand = v.variadic_elements[next_element]
			next_element += 1
		}
		joined = prov_join(graph, joined, walk_flow_expr(graph, operand))
	}
	return joined
}

// design.md "string type conversions": every text operation is either a borrow
// of its operand or a fresh owner, and which it is follows from the result type
// alone. A borrow carries the operand's loans; an owner carries none, so the
// analysis stops there rather than pretending the result outlives its source.
@(private = "file")
prov_text_call :: proc(graph: ^Flow_Graph, v: ^Expr_Call) -> []int {
	source: []int
	for argument, index in v.bound {
		if argument == nil {
			continue
		}
		loans := walk_flow_expr(graph, argument)
		if index == 0 {
			source = loans
			// `text.bytes()`, `text[lo:hi]`, and `to_c_view()` all borrow the
			// receiver's own storage, so a receiver that is itself a root — an owning
			// `string` local — lends it here.
			if len(source) == 0 && text_result_borrows(graph.k.c, v) {
				if root, path, ok := prov_place_of(graph, argument); ok {
					source = prov_borrow(graph, root, path, false, v.span, "view")
				}
			}
		}
	}
	if !text_result_borrows(graph.k.c, v) {
		return nil
	}
	return source
}

// Whether this text operation's result is a borrow of its operand rather than a
// fresh owner. `clone`, `+`, and every validating conversion that copies produce
// owners; the views do not.
@(private = "file")
text_result_borrows :: proc(c: ^Compiler, v: ^Expr_Call) -> bool {
	if v.text == .Copy || v.text == .From_Runes {
		return false
	}
	#partial switch v.text_conversion {
	case .String_From_Bytes, .String_From_C_View:
		return false
	}
	result := len(v.result_types) > 0 ? v.result_types[0] : v.type
	return type_is_carrier(c, result)
}

@(private = "file")
prov_store_call_results :: proc(graph: ^Flow_Graph, v: ^Expr_Call, actuals: [][]int, borrowed: []int) -> []int {
	types := v.result_types
	count := len(types)
	if count == 0 && v.type != TYPE_VOID && v.type != INVALID_TYPE {
		count = 1
	}
	if count == 0 {
		return nil
	}
	results := make([]Prov_Call_Result, count, graph.alloc)
	for index in 0 ..< count {
		type := len(types) > 0 ? types[index] : v.type
		results[index].loans = prov_call_result(graph, v, actuals, borrowed, index, type)
		results[index].region = prov_call_region(graph, v, index, type)
	}
	graph.call_results[v] = results
	return results[0].loans
}

// design.md "Temporaries and procedure boundaries". At a direct call the actual
// argument roots are substituted into the callee's result summary. At a call
// through a procedure value there is no summary, so a returned carrier is
// conservatively derived from every borrowed argument, and fresh-allocation
// provenance is erased -- which is what keeps an indirect result away from
// checked `free`.

// Allocator-wide invalidation is the one effect propagated through arbitrary
// ordinary procedure wrappers (design.md), and it survives an indirect call
// because the attribute is part of the procedure type.
@(private = "file")
prov_call_resets :: proc(graph: ^Flow_Graph, v: ^Expr_Call) {
	proc_type := INVALID_TYPE
	if sym := symbol_of(graph.k.c, v.resolution.chosen_overload); sym != nil {
		proc_type = sym.proc_type
	} else if v.callee != nil {
		proc_type = expr_base(v.callee).type
	}
	if proc_type == INVALID_TYPE {
		return
	}
	arguments := v.bound
	if len(arguments) == 0 {
		return
	}
	for argument, index in arguments {
		if argument == nil || !proc_param_resets(graph.k.c, proc_type, index) {
			continue
		}
		prov_reset(graph, prov_region_of(graph, argument), v.span, false, v)
	}
}

@(private = "file")
prov_call_result :: proc(
	graph: ^Flow_Graph,
	v: ^Expr_Call,
	actuals: [][]int,
	borrowed: []int,
	result: int,
	result_type: Type_Id,
) -> []int {
	c := graph.k.c
	// design.md "Named results": an `inout` result is the caller's storage, so
	// the call is a place aliasing whatever the `inout` arguments named. It is not
	// a carrier type, which is why it is answered before the carrier test.
	if prov_result_is_inout(graph, v, result) {
		out: []int
		for slots, index in actuals {
			if prov_argument_is_inout(graph, v, index) {
				out = prov_join(graph, out, slots)
			}
		}
		return out
	}
	// A result that is not itself a borrow can still hold one, and its summary is
	// about the same dependency either way (step 6: reading a container value out
	// yields what that value borrows).
	if !type_is_carrier(c, result_type) && !type_carries_borrow(c, result_type).any {
		return nil
	}
	callee := v.resolution.chosen_overload
	if callee == INVALID_SYMBOL {
		callee = v.resolution.symbol
	}
	direct := prov_has_direct_body(c, callee)
	prov_note_summary_dependency(graph, callee, direct)
	if summary, found := result_summary(c, callee, result); found {
		out: []int
		for wanted, index in summary.params {
			if !wanted || index >= len(actuals) {
				continue
			}
			// Substitute the caller's matching content, not everything the
			// argument holds: the callee's summary records which of the
			// parameter's content paths reach this result, in the same order the
			// caller's content slots are in.
			paths := index < len(summary.param_paths) ? summary.param_paths[index] : nil
			if len(paths) != len(actuals[index]) {
				out = prov_join(graph, out, actuals[index])
				continue
			}
			for named, position in paths {
				if named {
					out = prov_join(graph, out, prov_one(graph, actuals[index][position]))
				}
			}
		}
		if summary.static {
			out = prov_join(graph, out, prov_synthetic_borrow(graph, v, .Static, result_type))
		}
		if summary.thread {
			out = prov_join(graph, out, prov_synthetic_borrow(graph, v, .Thread_Local, result_type))
		}
		if summary.fresh {
			out = prov_join(graph, out, prov_synthetic_borrow(graph, v, .Allocation, result_type))
		}
		if summary.unknown || summary.local {
			out = prov_join(graph, out, prov_synthetic_borrow(graph, v, .Unknown, result_type))
		}
		return out
	}
	// A named body without a summary yet is a forward fixed-point edge, not an
	// indirect call with erased metadata. Contribute nothing this round; its
	// monotone summary will be substituted once that body has been visited.
	if direct {
		return nil
	}
	// No summary to consult, so every argument that may still be named after the
	// call is a possible source of the result.
	if escaping := prov_escaping_actuals(graph, v, actuals); len(escaping) > 0 {
		return escaping
	}
	if len(borrowed) > 0 {
		return nil // every borrowed argument promised it does not escape
	}
	return prov_synthetic_borrow(graph, v, .Unknown, result_type)
}

@(private = "file")
prov_note_summary_dependency :: proc(graph: ^Flow_Graph, callee: Symbol_Id, direct: bool) {
	if graph.mode != .Prov_Summary || !direct || callee == INVALID_SYMBOL {
		return
	}
	for existing in graph.summary_callees {
		if existing == callee {
			return
		}
	}
	append(&graph.summary_callees, callee)
}

@(private = "file")
prov_synthetic_borrow :: proc(graph: ^Flow_Graph, v: ^Expr_Call, kind: Root_Kind, type: Type_Id) -> []int {
	name: string
	#partial switch kind {
	case .Allocation:   name = "this allocation"
	case .Static:       name = "static storage"
	case .Thread_Local: name = "`thread_local` storage"
	case:               name = "unknown storage"
	}
	root := prov_new_root(graph, kind, v.span, name)
	return prov_borrow(
		graph,
		root,
		nil,
		carrier_is_mutable(graph.k.c, type),
		v.span,
		carrier_noun(graph.k.c, type),
	)
}

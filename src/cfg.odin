// A disposable per-procedure control-flow view: annotated AST, not MIR (a real
// MIR is deferred past v1). Rebuilt per concrete body instance, so generic
// specializations never share liveness state.
//
// Events are deliberately few. A managed local goes live at a completed
// initialization, dies at `move`/`drop`, must be live at a use, and is cleaned
// up wherever control leaves its declaring scope. Every exit emits the cleanup
// events of the scopes it passes through, innermost first.
package lokec

import "core:fmt"
import "core:mem"
import "core:slice"

Block_Id :: distinct int

// One walk, three jobs. Only Lifecycle does semantic work; the provenance modes
// rebuild the same topology read-only, so they can't duplicate diagnostics or
// disturb settled annotations.
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
	// An allocator-region reset, recorded so the later provenance pass can ask
	// which owners were definitely dead at it (a dropped owner no longer blocks
	// a reset — design.md). Keyed on the call node since the two passes use
	// separate graphs.
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
	// Names the operation attempted, for diagnostics. Not a history: states are
	// a lattice, so which earlier op consumed the binding isn't tracked.
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

	// Provenance modes. `src/borrow.odin` solves reaching loans forward and
	// carrier liveness backward over these blocks. Reaching is `slots * loans`
	// bits, the part that multiplies, so it's packed: one `ceil(loans/8)`-byte
	// row per slot.
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

// Event vocabulary the root and region lattices read. Kept separate from the
// lifecycle events above: the two analyses share block topology and source
// order, not the facts they record.
Prov_Kind :: enum u8 {
	// A carrier slot receives a value: union of its source slots plus one fresh
	// loan.
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
	// A borrow stored somewhere that outlives the statement: process/thread
	// storage, or caller-owned storage. `retain` says which.
	Retain,
	// An allocator region reset: `free_all`, or a call through a parameter marked
	// `@(allocator_reset)`.
	Reset,
	// An owner backed by a received allocator region is stored somewhere that
	// outlives that region.
	Region_Escape,
	// A value written through a carrier: `p^.view = values`, or an argument the
	// callee may keep. Unlike `Def`, the destination depends on the carrier's
	// own loans, so it resolves while solving — and joins rather than replaces,
	// since the carrier may name more than one root.
	Publish,
	// A value read through a carrier; like a Publish target, its content slots
	// are only known after reaching loans are solved.
	Load,
}

// design.md "Capabilities and the one rule": a read is compatible with a
// read-only borrow, a write is not, an invalidation ends the value outright.
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
	// `Retain`: the carrier the place was written through when it left lexical
	// storage (`p^.view`, `d[0].view`, a `^mut` argument). Its reaching loans
	// name the destination roots, so `retain`/`root` are resolved by the
	// solver, not here.
	// `Load`: `into` holds the addressing carriers, `path` the projection below
	// their pointees, `slot` the content. `sources` fills with resolved content
	// reads before solving liveness.
	into: []int,
	// `Escape`: the allocator region an owning result carries with it.
	region:         Region_Set,
	region_content: []Prov_Region_Content,
	// `Reset`: whether the promise this reset needs is already written. `access`
	// selects the form: `Invalidate` for a direct `free_all`, `Write` for
	// handing an allocator parameter onward.
	reset_covered: bool,
	owner_span:    Span,
	// `Live`: re-establishes the loans it names rather than just keeping them
	// alive. A loop head re-reads its iterable each iteration, so a body
	// invalidation must not travel the back edge and kill the next one's
	// iterator.
	revives:       bool,
}

// A borrowed parameter arrives holding the caller's storage, which the entry
// block installs before the first statement.
Prov_Entry_Def :: struct {
	slot: int,
	loan: Loan_Id,
}

// The one result of a call: what it borrows and the allocator region it
// carries.
Prov_Call_Result :: struct {
	loans:          []int,
	region:         Region_Set,
	region_content: []Prov_Region_Content,
}

// Allocator backing is independent of contained borrow loans. Aggregate field
// writes therefore keep a parallel path-indexed region fact even when the field
// type has no carrier shape (for example `[dynamic]int`).
Prov_Region_Content :: struct {
	path:   []Proj_Step,
	region: Region_Set,
}

Flow_Cleanup_Kind :: enum {
	Local,
	Defer,
	// A provenance root whose storage ends when its scope does.
	Prov_Root,
}

// One open lexical scope: where its cleanups start in `in_scope`, and how many
// region-backed owners were in scope when it opened. Only `leave_flow_scope`
// restores these, so an abrupt exit can emit a scope's cleanups without ending
// it.
Flow_Scope :: struct {
	cleanups: int,
	owners:   int,
}

// One registration in the unified cleanup order. Locals and defers share one
// list because a deferred read is valid only when every local it names is
// still live at the exact point it executes.
Flow_Cleanup :: struct {
	kind: Flow_Cleanup_Kind,
	slot: int,
	stmt: Stmt,
	root: Root_Id,
	span: Span,
}

// One managed local the lifecycle analysis follows. An allocation root is not
// one: design.md releases `new` storage via `free`/region reset, and root
// provenance (`src/borrow.odin`) decides whether `free` may have it.
Tracked_Local :: struct {
	symbol: Symbol_Id,
	scope:  int,
	// A `move` parameter arrives owned, so it is live before the first statement
	// rather than at a declaration inside the body.
	live_on_entry: bool,
	// Filled while reporting: whether this local ever reaches a cleanup point,
	// and in which states. `conditional_assign` marks the other place a hidden
	// flag is needed: an assignment live on one path, dead on another.
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
	// One slot per `carrier_shape` path, for a local whose type can hold a
	// carrier without being one. Ordered by the shape, so values of one type
	// pair by index.
	content_by_symbol: map[Symbol_Id][]int,
	// Which entry of a keyed map shape each constant key uses. A map's key set
	// isn't part of its type, so the type provides the entries and the body
	// assigns them first-written-first. Numbering is shared across the body's
	// maps harmlessly: two maps are two roots whose paths are never compared.
	map_key_entries: map[string]int,
	call_results:   map[^Expr_Call]Prov_Call_Result,
	// Direct callees whose result summaries this graph reads. Populated only in
	// summary mode and copied into compilation metadata before the graph dies.
	summary_callees: [dynamic]Symbol_Id,
	// A value temporary lives until the end of its complete expression
	// (design.md), extended to the complete statement for a `foreach` iterable,
	// `switch` subject, or header initial statement. One list per statement.
	temp_roots:     [dynamic]Root_Id,
	// design.md "Allocator regions and region provenance". One entry per
	// allocator binding and per region-backed owner; `owners_in_scope` is what
	// a reset checks survival against.
	region_of:       map[Symbol_Id]Region_Set,
	region_content:  map[Symbol_Id][]Prov_Region_Content,
	// A provider owns its own region but also depends on the parent allocator
	// until the child is dropped. Kept separate to avoid confusing
	// `child.allocator()` with the parent region.
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
	has_content_load: bool,

	k:       ^Checker,
	literal: ^Expr_Proc,
	current: Block_Id,
	// A slot in `tracked` is permanent, naming one declaration's state for the
	// whole analysis. Scope membership comes and goes separately: a stack of
	// slots in declaration order, with `scopes` holding one marker per open
	// scope. Leaving a scope cleans up the slots above its marker, then forgets
	// them.
	in_scope: [dynamic]Flow_Cleanup,
	scopes:   [dynamic]Flow_Scope,
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

// In lifecycle mode, nil when the body has nothing to track (the ordinary
// case, saving unmanaged procedures a graph). A provenance mode always builds
// one: design.md's one rule applies even to a body with only trivial locals.
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
	graph.scopes = make([dynamic]Flow_Scope, allocator)
	graph.in_scope = make([dynamic]Flow_Cleanup, allocator)
	graph.roots = make([dynamic]Prov_Root, allocator)
	graph.loans = make([dynamic]Prov_Loan, allocator)
	graph.prov_slots = make([dynamic]Prov_Slot, allocator)
	graph.entry_defs = make([dynamic]Prov_Entry_Def, allocator)
	graph.root_by_symbol = make(map[Symbol_Id]Root_Id, 8, allocator)
	graph.slot_by_symbol = make(map[Symbol_Id]int, 8, allocator)
	graph.content_by_symbol = make(map[Symbol_Id][]int, 8, allocator)
	graph.call_results = make(map[^Expr_Call]Prov_Call_Result, 8, allocator)
	graph.summary_callees = make([dynamic]Symbol_Id, allocator)
	graph.temp_roots = make([dynamic]Root_Id, allocator)
	graph.region_of = make(map[Symbol_Id]Region_Set, 8, allocator)
	graph.region_content = make(map[Symbol_Id][]Prov_Region_Content, 8, allocator)
	graph.provider_parents = make(map[Symbol_Id]Region_Set, 4, allocator)
	graph.owners_in_scope = make([dynamic]Symbol_Id, allocator)
	graph.provider_bits = make(map[Symbol_Id]u64, 4, allocator)
	graph.provider_symbols = make([dynamic]Symbol_Id, allocator)
	graph.break_block, graph.continue_block = NO_BLOCK, NO_BLOCK
	graph.current = new_flow_block(graph)

	// design.md: a `move` parameter transfers ownership to the callee, which
	// drops it like any owned local. It lives in a scope outside the body's,
	// making its cleanup the outermost one.
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
			append(&graph.tracked, Tracked_Local{symbol = id, live_on_entry = true})
			graph.by_symbol[id] = len(graph.tracked) - 1
			append(&graph.in_scope, Flow_Cleanup{kind = .Local, slot = len(graph.tracked) - 1})
		}
	}
}

@(private = "file")
enter_flow_scope :: proc(graph: ^Flow_Graph) {
	append(
		&graph.scopes,
		Flow_Scope{cleanups = len(graph.in_scope), owners = len(graph.owners_in_scope)},
	)
}

@(private = "file")
leave_flow_scope :: proc(graph: ^Flow_Graph) {
	scope := pop(&graph.scopes)
	emit_cleanups(graph, scope.cleanups)
	// A local leaving its scope is gone: nothing after may name it, and the
	// enclosing scope must not clean it up twice. Leaving the scope is the only
	// thing that ends it — an abrupt exit runs the same cleanups on the way out,
	// but statements after it stay in this scope, seeing everything it declared.
	resize(&graph.in_scope, scope.cleanups)
	resize(&graph.owners_in_scope, scope.owners)
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
			// Executed at scope exit, not at registration, so reads, moves, drops,
			// branches, and nested cleanup land at their real dataflow position.
			// Removed, along with the already-run later registrations, while it
			// executes: matches runtime stack popping, and stops an already-diagnosed
			// illegal `return` inside a defer from recursively invoking itself during
			// error recovery.
			// The walk appends into this same backing storage, so the entries have to
			// be saved, not the dynamic-array header.
			tail := slice.clone(graph.in_scope[index:], graph.alloc)
			owners := len(graph.owners_in_scope)
			resize(&graph.in_scope, index)
			walk_flow_stmt(graph, action.stmt)
			resize(&graph.in_scope, index)
			append(&graph.in_scope, ..tail)
			// A declaration inside the deferred syntax is not in scope after it,
			// any more than its cleanup registration above is.
			resize(&graph.owners_in_scope, owners)
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

// An ordinary temporary root lives until the end of its complete expression;
// one in a control-flow header, until that whole statement ends (design.md).
// So a header's initial statement doesn't release its own temporaries —
// `extend` keeps them on the enclosing statement's list.
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
			if value := s.value; value != nil {
				first := walk_flow_expr(graph, value.expr)
				escaping := prov_escape_region(graph, value.expr)
				result_type := expr_base(value.expr).type
				if sym := symbol_of(graph.k.c, graph.literal.symbol); sym != nil {
					result_type = sym.result
				}
				prov_emit(graph, Prov_Event {
					kind           = .Escape,
					sources        = first,
					span           = expr_span(value.expr),
					region         = escaping,
					region_content = prov_result_region_fields(graph, value.expr, result_type),
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
		if value := s.value; value != nil {
			// Returning a managed local, temporary, or `move` parameter transfers
			// that owned value into result storage without cloning (design.md), so
			// the source is dead afterwards and scope exit must not drop it.
			if value.clone_on_return {
				report_copy_cost(
					graph.k, .Return, expr_span(value.expr), value.expr,
					expr_base(value.expr).type, graph.loop_depth > 0,
				)
			}
			killed := false
			if ident, is_ident := value.expr.(^Expr_Ident); is_ident && !value.clone_on_return {
				if slot, tracked := slot_of(graph, ident.symbol); tracked {
					emit(graph, Flow_Event{kind = .Kill, slot = slot, span = ident.span, name = ident.name})
					killed = true
				}
			}
			if !killed {
				walk_flow_expr(graph, value.expr)
			}
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
		// Scope exit automatically drops every live managed lexical owner
		// (design.md). Suppressing that is a property of the value, never of the
		// declaration — an `unsafe.forget` consumes it, and a consumed local is
		// dead here like any other.
		slot, already_tracked := slot_of(graph, id)
		if !already_tracked {
			append(&graph.tracked, Tracked_Local {
				symbol = id,
				scope  = len(graph.scopes),
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

// design.md: a declaration in an `if`/`for`/`switch` header is scoped to that
// whole statement — condition, body, and post all see it, nothing after does.
// `emit_if`/`emit_for`/`emit_switch` already push a scope here, matching where
// the emitter drops the local.
//
// The caller pairs this with `defer leave_flow_scope(graph)`, in the caller's
// own scope so it closes over the whole statement.
@(private = "file")
enter_flow_header_scope :: proc(graph: ^Flow_Graph, init: Stmt) {
	enter_flow_scope(graph)
	if init != nil {
		walk_flow_stmt(graph, init, extend = true)
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
	// source root. The read happens once per iteration, so the loan must stay
	// live through the body, not just at the iterable's write site.
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
	enter_flow_header_scope(graph, s.init)
	defer leave_flow_scope(graph)
	subject: []int
	if s.subject != nil {
		subject = walk_flow_expr(graph, s.subject)
	}
	// A switch over a place borrows it; one over a temporary consumes it, and
	// the active payload transfers into the case's own owning binding.
	consumes := s.kind == .Type && s.subject != nil &&
		expr_base(s.subject).type != TYPE_ANY_VIEW &&
		!expression_is_borrowed_place(graph.k.c, s.subject)
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
			prov_bind_value(graph, c.binding_symbol, prov_case_payload(graph, s, c, subject), c.span)
			prov_bind_case_region(graph, c.binding_symbol, s.subject)
		} else {
			track_case_binding(graph, c, consumes)
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

// The payload read out from under a union's wildcard alternative. Unwrapping a
// borrow-carrying value — a case binding, `or_else`, `or_return` — keeps every
// borrow the wrapper carried. An `any_view` reads through its data pointer
// instead, which is the read the extraction itself performs.
@(private = "file")
prov_payload_content :: proc(
	graph: ^Flow_Graph, loans: []int, subject_type, payload_type: Type_Id, span: Span,
) -> []int {
	if len(loans) == 0 || payload_type == INVALID_TYPE || payload_type == subject_type {
		return loans
	}
	if subject_type == TYPE_ANY_VIEW {
		return prov_load_content(graph, loans, nil, payload_type, span)
	}
	if !type_is_union(graph.k.c, subject_type) {
		return loans
	}
	return prov_project_content(graph, loans, subject_type, {proj_wild()}, payload_type, span)
}

// What a case binding holds: the subject's own content when the case binds the
// union type, and the active variant's payload when it binds one variant.
@(private = "file")
prov_case_payload :: proc(
	graph: ^Flow_Graph, s: ^Stmt_Switch, entry: Switch_Case, subject: []int,
) -> []int {
	if entry.binding_symbol == INVALID_SYMBOL || s.subject == nil {
		return subject
	}
	return prov_payload_content(
		graph, subject, expr_base(s.subject).type, entry.binding_type, entry.span,
	)
}

// A case binding names the payload its subject held, so it inherits that
// subject's region: unwrapping a handle does not lose which region it names.
@(private = "file")
prov_bind_case_region :: proc(graph: ^Flow_Graph, id: Symbol_Id, subject: Expr) {
	if id == INVALID_SYMBOL || subject == nil {
		return
	}
	sym := symbol_of(graph.k.c, id)
	if sym == nil {
		return
	}
	if type_underlying(graph.k.c, sym.type) != TYPE_ALLOCATOR &&
	   !type_is_managed(graph.k.c, sym.type) {
		return
	}
	if set := prov_region_of(graph, subject); !region_is_empty(set) {
		graph.region_of[id] = set
	}
}

// A consuming switch hands the active payload to the case's binding, which is
// an ordinary managed local from there on: tracked, movable, droppable, and
// dropped exactly once on every exit of its case.
@(private = "file")
track_case_binding :: proc(graph: ^Flow_Graph, entry: Switch_Case, consumes: bool) {
	if !consumes || entry.binding_symbol == INVALID_SYMBOL {
		return
	}
	sym := symbol_of(graph.k.c, entry.binding_symbol)
	if sym == nil || !type_is_managed(graph.k.c, sym.type) {
		return
	}
	slot, already := slot_of(graph, entry.binding_symbol)
	if !already {
		append(&graph.tracked, Tracked_Local {
			symbol = entry.binding_symbol,
			scope  = len(graph.scopes),
		})
		slot = len(graph.tracked) - 1
		graph.by_symbol[entry.binding_symbol] = slot
	}
	append(&graph.in_scope, Flow_Cleanup{kind = .Local, slot = slot})
	emit(graph, Flow_Event {
		kind = .Init,
		slot = slot,
		span = sym.span,
		name = identifier_text(graph.k.c, sym.name),
	})
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
		if prov && v.op == .Caret {
			return prov_load_content(graph, operand_loans, nil, v.type, v.span)
		}
		if v.op == .Or_Return {
			entry := graph.current
			resume := new_flow_block(graph)
			link(graph, entry, resume)
			failure := new_flow_block(graph)
			link(graph, entry, failure)
			graph.current = failure
			proc_symbol := symbol_of(graph.k.c, graph.literal.symbol)
			if graph.mode != .Lifecycle && proc_symbol != nil && proc_symbol.result != INVALID_TYPE {
				shape, operand_fallible := fallible_of(graph.k, expr_base(v.operand).type)
				target, target_fallible := fallible_of(graph.k, proc_symbol.result)
				if operand_fallible && target_fallible {
					from := shape.info.variants[shape.failure]
					into := target.info.variants[target.failure]
					escaping := prov_payload_content(
						graph, operand_loans, expr_base(v.operand).type, from, v.span,
					)
					if failure_assignment_borrows(graph.k.c, from, into) {
						if root, path, is_place := prov_place_of(graph, v.operand); is_place {
							block, index := prov_access(graph, root, path, .Read, v.span)
							escaping = prov_join(
								graph, escaping,
								prov_borrow(graph, root, path, false, v.span, "view", block, index),
							)
						} else {
							escaping = prov_join(
								graph, escaping,
								prov_borrow(graph, prov_temp_root(graph, v.span), nil, false, v.span, "view"),
							)
						}
					}
					prov_emit(graph, Prov_Event {
						kind = .Escape, sources = escaping, span = v.span,
					})
				}
			}
			emit_cleanups(graph, 0)
			graph.current = resume
			// design.md "or_return operator": on success the expression yields the
			// operand's value with the failure removed, so whatever that value
			// borrows or allocates travels out with it. Dropping the loans here
			// would leave `p := new(T) or_return` with unknown provenance.
			return prov_payload_content(
				graph, operand_loans, expr_base(v.operand).type, v.type, v.span,
			)
		}

	case ^Expr_Selector:
		if prov {
			if root, path, ok := prov_place_of(graph, v); ok {
				prov_walk_subscripts(graph, v)
				prov_access(graph, root, path, .Read, v.span)
				// Reading a field yields what that field holds, and only that.
				// Checking the access must not add a lasting borrow of the
				// wrapper on top of it.
				return prov_read_content(graph, root, path, v.type, v.span)
			}
			if carriers, path, ok := prov_read_through_carrier(graph, v); ok {
				return prov_load_content(graph, carriers, path, v.type, v.span)
			}
			loans := walk_flow_expr(graph, v.operand)
			if v.resolution.kind == .Field && v.operand != nil {
				return prov_project_content(
					graph, loans, expr_base(v.operand).type, {prov_field_step(graph, v)}, v.type, v.span,
				)
			}
			return nil
		}
		walk_flow_expr(graph, v.operand)

	case ^Expr_Index:
		if prov {
		if root, path, ok := prov_place_of(graph, v); ok {
			prov_access(graph, root, path, .Read, v.span)
			prov_walk_subscripts(graph, v)
			// Reading an element yields what that element holds. The path
			// already ends in the wildcard that stands for every element, so
			// this is the same selection a field read does.
				return prov_read_content(graph, root, path, v.type, v.span)
			}
			if carriers, path, ok := prov_read_through_carrier(graph, v); ok {
				return prov_load_content(graph, carriers, path, v.type, v.span)
			}
			loans := walk_flow_expr(graph, v.operand)
			for index in v.indices {
				loans = prov_join(graph, loans, walk_flow_expr(graph, index))
			}
			if len(v.bound) > 0 {
				return prov_value_content(graph, loans, v.type, v.span)
			}
			return prov_project_content(
				graph, loans, expr_base(v.operand).type, prov_index_path(graph, v), v.type, v.span,
			)
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
		payload := prov_payload_content(graph, value_loans, expr_base(v.value).type, v.type, v.span)
		return prov_join(graph, payload, fallback_loans)

	case ^Expr_Checked_Extract:
		loans := walk_flow_expr(graph, v.operand)
		if prov {
			// A union stores its alternatives below a wildcard. An erased view
			// instead points at the value. Copying either payload preserves its
			// content, while an all-owning extraction has no carrier shape.
			operand_type := expr_base(v.operand).type
			if type_is_union(graph.k.c, operand_type) {
				return prov_project_content(graph, loans, operand_type, {proj_wild()}, v.type, v.span)
			}
			return prov_load_content(graph, loans, nil, v.type, v.span)
		}
		return nil

	case ^Expr_Range:
		walk_flow_expr(graph, v.lo)
		walk_flow_expr(graph, v.hi)

	case ^Expr_Literal, ^Expr_Proc, ^Expr_Proc_Group, ^Expr_Operator,
	     ^Expr_Error,
	     ^Type_Pointer, ^Type_C_Pointer, ^Type_Slice, ^Type_Dynamic_Array,
	     ^Type_Array, ^Type_Map, ^Type_Distinct, ^Type_Dyn, ^Type_Type,
	     ^Type_Poly, ^Type_Proc, ^Type_Record, ^Type_Anon_Record, ^Type_Enum, ^Type_Interface:
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
	info := underlying_info(graph.k.c, sym.proc_type)
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
	// `.name(payload)` is aggregate construction: the payload's borrows travel
	// into the union under its wildcard alternative, exactly as wrapping the
	// same value in a struct field puts them at that field.
	if v.union_op != .None {
		loans: []int
		if len(v.bound) == 1 {
			loans = walk_flow_expr(graph, v.bound[0])
		}
		if graph.mode == .Lifecycle || v.union_op != .Construct {
			return nil
		}
		return prov_variant_content(graph, v, loans)
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
	// A body that borrows nothing can still return an owner backed by an
	// allocator parameter or local region. Its result summary (including field
	// projections) therefore needs the solver even with no root-provenance loan.
	if event.kind == .Escape {
		graph.has_region_event ||= !region_is_empty(event.region)
		for content in event.region_content {
			graph.has_region_event ||= !region_is_empty(content.region)
		}
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
prov_result_region :: proc(graph: ^Flow_Graph, value: Expr) -> Region_Set {
	if call, ok := prov_through_or_return(value).(^Expr_Call); ok {
		if result, found := graph.call_results[call]; found {
			return result.region
		}
	}
	return prov_region_of(graph, value)
}

// The allocator region carried by one projected result field. Calls keep a
// path-indexed companion to their conservative whole-result union; literals and
// places can be projected directly without first joining sibling fields.
@(private = "file")
prov_result_region_at :: proc(graph: ^Flow_Graph, value: Expr, path: []Proj_Step) -> Region_Set {
	if len(path) == 0 {
		return prov_result_region(graph, value)
	}
	#partial switch v in prov_through_or_return(value) {
	case ^Expr_Move:
		return prov_result_region_at(graph, v.value, path)
	case ^Expr_Cond:
		out := prov_empty_region(graph)
		region_merge(&out, prov_result_region_at(graph, v.then, path))
		region_merge(&out, prov_result_region_at(graph, v.otherwise, path))
		return out
	case ^Expr_Or_Else:
		out := prov_empty_region(graph)
		region_merge(&out, prov_result_region_at(graph, v.value, path))
		region_merge(&out, prov_result_region_at(graph, v.fallback, path))
		return out
	case ^Expr_Call:
		if result, found := graph.call_results[v]; found && len(result.region_content) > 0 {
			out := prov_empty_region(graph)
			matched := false
			for content in result.region_content {
				if paths_overlap(content.path, path) {
					matched = true
					region_merge(&out, content.region)
				}
			}
			if matched { return out }
		}
	case ^Expr_Composite:
		value_type := v.type
		is_array := underlying_kind(graph.k.c, value_type) == .Array
		out := prov_empty_region(graph)
		for _, index in v.elements {
			step, known := prov_element_step(graph, v, value_type, is_array, index)
			if known && paths_overlap({step}, path[:1]) && v.elements[index].value != nil {
				region_merge(&out, prov_result_region_at(graph, v.elements[index].value, path[1:]))
			}
		}
		return out
	}
	if root, base, ok := prov_place_of(graph, value); ok {
		projected := make([]Proj_Step, len(base) + len(path), graph.alloc)
		copy(projected, base)
		copy(projected[len(base):], path)
		return prov_region_content_at(graph, root, projected)
	}
	return prov_result_region(graph, value)
}

@(private = "file")
prov_result_region_fields :: proc(graph: ^Flow_Graph, value: Expr, type: Type_Id) -> []Prov_Region_Content {
	info := underlying_info(graph.k.c, type)
	if info == nil || info.kind != .Struct {
		return nil
	}
	out := make([]Prov_Region_Content, len(info.fields), graph.alloc)
	for _, index in info.fields {
		path := make([]Proj_Step, 1, graph.alloc)
		path[0] = proj_field(index)
		out[index] = Prov_Region_Content {
			path = path,
			region = prov_result_region_at(graph, value, path),
		}
	}
	return out
}

// Returning a region provider transfers the provider's dependency, not the
// callee-local token that identifies allocations made *by* that provider. The
// caller creates a fresh token for the returned owner and retains the parent
// edge represented here.
@(private = "file")
prov_escape_region :: proc(graph: ^Flow_Graph, value: Expr) -> Region_Set {
	if expr_base(value) != nil && type_is_region_provider(graph.k.c, expr_base(value).type) {
		#partial switch v in value {
		case ^Expr_Ident:
			if parent, found := graph.provider_parents[v.symbol]; found {
				return parent
			}
			return Region_Set{}
		case ^Expr_Move:
			return prov_escape_region(graph, v.value)
		}
	}
	return prov_result_region(graph, value)
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
		// It may still carry a borrow inside it; that is a content slot, not one
		// of these.
		return 0, false
	}
	if sym.kind != .Var && sym.kind != .Parameter {
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

// Constructing an aggregate puts each element's borrows at its own place: a
// positional element at its field or array index, a named field element at
// the field it names, and a keyed element whose slot can't be resolved here
// joins into every path rather than guessing. An array with a single wildcard
// element path joins into it via the same overlap test.
@(private = "file")
prov_composite_content :: proc(graph: ^Flow_Graph, v: ^Expr_Composite, content: []int) -> []int {
	value_type := v.type
	is_array := underlying_kind(graph.k.c, value_type) == .Array
	per_element := make([][]int, len(v.elements), graph.alloc)
	// The slot each written element fills, and whether it is known at all. A
	// named field element resolves to the field's own index — the checker already
	// proved the name — so `Point{y = view}` is as precise as `Point{v, view}`.
	steps := make([]Proj_Step, len(v.elements), graph.alloc)
	known := make([]bool, len(v.elements), graph.alloc)
	joined: []int
	for element, index in v.elements {
		if element.value == nil {
			continue
		}
		loans := walk_flow_expr(graph, element.value)
		per_element[index] = loans
		joined = prov_join(graph, joined, loans)
		steps[index], known[index] = prov_element_step(graph, v, value_type, is_array, index)
	}
	for slot in content {
		sources: []int
		for loans, index in per_element {
			if len(loans) == 0 {
				continue
			}
			if !known[index] {
				// An unresolved slot could be any of them, so it contributes to all.
				sources = prov_join(graph, sources, loans)
				continue
			}
			prefix := prov_extend(graph, nil, steps[index])
			if paths_overlap(graph.prov_slots[slot].path, prefix) {
				path := graph.prov_slots[slot].path
				suffix := path[min(len(prefix), len(path)):]
				child_type := expr_base(v.elements[index].value).type
				sources = prov_join(graph, sources, prov_select_content(graph, loans, child_type, suffix))
			}
		}
		prov_define_one_content(graph, slot, sources, v.span)
	}
	return content
}

// Which slot one written literal element fills. An element is selected by index,
// a field by its own step, and the two kinds must not be compared:
// `steps_overlap` treats a mismatch as "nothing proven", which would join
// everything.
@(private = "file")
prov_element_step :: proc(
	graph: ^Flow_Graph,
	v: ^Expr_Composite,
	value_type: Type_Id,
	is_array: bool,
	index: int,
) -> (Proj_Step, bool) {
	key := v.elements[index].key
	if key == nil {
		if is_array {
			return proj_range(i64(index), i64(index) + 1), true
		}
		return proj_field(index), true
	}
	if is_array {
		if constant, ok := prov_const_int(graph, key); ok {
			return proj_range(constant, constant + 1), true
		}
		return proj_wild(), false
	}
	name, is_ident := key.(^Expr_Ident)
	if !is_ident {
		return proj_wild(), false
	}
	field := struct_field(graph.k.c, value_type, intern_identifier(graph.k.c, name.name))
	sym := symbol_of(graph.k.c, field)
	if sym == nil {
		return proj_wild(), false
	}
	return proj_field(int(sym.index)), true
}

// design.md "Unions": one variant's payload sits under the union's wildcard
// alternative, so constructing a variant puts the payload's borrows there.
@(private = "file")
prov_variant_content :: proc(graph: ^Flow_Graph, v: ^Expr_Call, loans: []int) -> []int {
	content := prov_temp_content(graph, v.type)
	if len(content) == 0 {
		return nil
	}
	prefix := prov_extend(graph, nil, proj_wild())
	payload_type := INVALID_TYPE
	if len(v.bound) == 1 && v.bound[0] != nil {
		payload_type = expr_base(v.bound[0]).type
	}
	for slot in content {
		sources: []int
		if len(loans) > 0 && paths_overlap(graph.prov_slots[slot].path, prefix) {
			path := graph.prov_slots[slot].path
			suffix := path[min(len(prefix), len(path)):]
			sources = prov_select_content(graph, loans, payload_type, suffix)
		}
		prov_define_one_content(graph, slot, sources, v.span)
	}
	return content
}

// A value that is not itself a borrow
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
	if sym.kind != .Var && sym.kind != .Parameter {
		return nil
	}
	shape := carrier_shape(graph.k.c, sym.type)
	if len(shape) == 0 {
		return nil // an all-scalar value initializes no payload facts
	}
	external_duration := sym.duration != .None || (sym.decl != nil && sym.decl.top_level)
	unknown_root := NO_ROOT
	if external_duration {
		// Another body may have populated this storage. Starting empty would turn
		// missing cross-body content metadata into a proof that it borrows nothing;
		// a definite write in this body replaces these entry facts normally.
		unknown_root = prov_new_root(
			graph, .Unknown, sym.span,
			fmt.aprintf(
				"existing content of `%s`", identifier_text(graph.k.c, sym.name), allocator = graph.alloc,
			),
		)
	}
	slots := make([]int, len(shape), graph.alloc)
	for path, index in shape {
		entry := empty_prov_slot(id)
		entry.name = identifier_text(graph.k.c, sym.name)
		entry.span = sym.span
		entry.path = path.steps
		entry.content_type = path.truncated ? INVALID_TYPE : path.type
		entry.content_shape = sym.type
		entry.content_truncated = path.truncated
		append(&graph.prov_slots, entry)
		slots[index] = len(graph.prov_slots) - 1
		if unknown_root != NO_ROOT {
			loan := prov_new_loan(
				graph, unknown_root, nil, path.mutable, sym.span,
				path.truncated ? "borrow" : carrier_noun(graph.k.c, path.type),
			)
			append(&graph.entry_defs, Prov_Entry_Def{slot = slots[index], loan = loan})
		}
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
		entry.content_shape = type
		entry.content_truncated = path.truncated
		append(&graph.prov_slots, entry)
		slots[index] = len(graph.prov_slots) - 1
	}
	return slots
}

// A path can select from slots only when they describe this value's shape.
// Unstructured dependencies contribute to every path, regardless of count.
@(private = "file")
prov_select_content :: proc(graph: ^Flow_Graph, sources: []int, type: Type_Id, path: []Proj_Step) -> []int {
	selected: []int
	for source in sources {
		entry := graph.prov_slots[source]
		if type == INVALID_TYPE || entry.content_shape != type || paths_overlap(entry.path, path) {
			selected = prov_join(graph, selected, prov_one(graph, source))
		}
	}
	return selected
}

// A read produces slots relative to the value being read, not the enclosing
// root. This lets a later projection of that value select its own fields.
@(private = "file")
prov_project_content :: proc(
	graph: ^Flow_Graph,
	sources: []int,
	source_type: Type_Id,
	path: []Proj_Step,
	result_type: Type_Id,
	span: Span,
) -> []int {
	if len(sources) == 0 {
		return nil
	}
	content := prov_temp_content(graph, result_type)
	for slot in content {
		full := prov_concat_path(graph, path, graph.prov_slots[slot].path)
		selected := prov_select_content(graph, sources, source_type, full)
		prov_emit(graph, Prov_Event{kind = .Live, sources = selected, span = span})
		prov_define_one_content(graph, slot, selected, span)
	}
	return content
}

@(private = "file")
prov_read_content :: proc(graph: ^Flow_Graph, root: Root_Id, path: []Proj_Step, type: Type_Id, span: Span) -> []int {
	sym := symbol_of(graph.k.c, graph.roots[int(root)].symbol)
	if sym == nil {
		return nil
	}
	return prov_project_content(graph, prov_content_at(graph, root, path), sym.type, path, type, span)
}

// Without a result-field mapping, give every result path the whole dependency
// set so projecting a call temporary cannot silently drop a source.
@(private = "file")
prov_value_content :: proc(graph: ^Flow_Graph, sources: []int, type: Type_Id, span: Span) -> []int {
	return prov_project_content(graph, sources, INVALID_TYPE, nil, type, span)
}

@(private = "file")
prov_load_content :: proc(graph: ^Flow_Graph, carriers: []int, path: []Proj_Step, type: Type_Id, span: Span) -> []int {
	if len(carriers) == 0 {
		return nil
	}
	content := prov_temp_content(graph, type)
	graph.has_content_load ||= len(content) > 0
	for slot in content {
		prov_emit(graph, Prov_Event {
			kind = .Load,
			slot = slot,
			into = carriers,
			path = prov_concat_path(graph, path, graph.prov_slots[slot].path),
			span = span,
		})
	}
	prov_emit(graph, Prov_Event{kind = .Live, sources = content, span = span})
	return content
}

// Consuming a value: what it held travels to wherever it went, so read that
// before invalidating the source. The borrows inside it are of other roots and
// survive; only the source binding's own storage ends, which is exactly what
// the invalidation covers (design.md). An explicit `move` around the place is
// transparent here — the same consumption, just written twice.
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

// Publishes one value's content into another's by matching paths of the same
// value type. Equal slot counts alone never establish a correspondence.
@(private = "file")
prov_define_content :: proc(
	graph: ^Flow_Graph,
	into: []int,
	from: []int,
	span: Span,
	written: []Proj_Step = nil,
	value_type: Type_Id = INVALID_TYPE,
	preserve_previous := false,
) {
	// A write whose own path is indistinct — an unknown index, a union subject —
	// reaches one of the places it selected without saying which, so it may not
	// erase the others.
	indistinct := path_is_indistinct(written)
	for slot in into {
		entry := graph.prov_slots[slot]
		type := value_type
		if type == INVALID_TYPE && len(written) == 0 {
			type = entry.content_shape
		}
		path := entry.path[min(len(written), len(entry.path)):]
		sources := prov_select_content(graph, from, type, path)
		// One content path can stand for many places — every element of a
		// container, every alternative of a union — and a write reaches only one
		// of them. Replacing the path would erase what the others hold, so an
		// indistinguishable destination joins instead. A fallible synthesized
		// write also keeps the old value from its failure edge. A known field in a
		// write that must commit replaces.
		partial_truncated_write := entry.content_truncated && len(written) > len(entry.path)
		whole_replacement := !indistinct && path_has_exact_prefix(entry.path, written)
		if preserve_previous || (!whole_replacement &&
		   (indistinct || path_is_indistinct(entry.path) || partial_truncated_write)) {
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

// A whole-value or whole-field write replaces every represented place below
// its path, including a wildcard container slot. A known element write into a
// wildcard slot is not a prefix match and therefore remains a partial join.
@(private = "file")
path_has_exact_prefix :: proc(path, prefix: []Proj_Step) -> bool {
	if len(prefix) > len(path) {
		return false
	}
	for step, index in prefix {
		other := path[index]
		if step.kind != other.kind || step.lo != other.lo || step.hi != other.hi {
			return false
		}
	}
	return true
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

@(private = "file")
prov_concat_path :: proc(graph: ^Flow_Graph, prefix, path: []Proj_Step) -> []Proj_Step {
	out := make([]Proj_Step, len(prefix) + len(path), graph.alloc)
	copy(out, prefix)
	copy(out[len(prefix):], path)
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

// Every region dependency of one symbol, including managed values moved into
// aggregate fields after the symbol's declaration.
@(private = "file")
prov_region_for_symbol :: proc(graph: ^Flow_Graph, id: Symbol_Id) -> Region_Set {
	out := prov_empty_region(graph)
	if direct, found := graph.region_of[id]; found {
		region_merge(&out, direct)
	}
	for content in graph.region_content[id] {
		region_merge(&out, content.region)
	}
	return out
}

// The region dependencies stored at one aggregate path. A whole-value fact has
// an empty path and therefore contributes to every projection conservatively.
@(private = "file")
prov_region_content_at :: proc(graph: ^Flow_Graph, root: Root_Id, path: []Proj_Step) -> Region_Set {
	out := prov_empty_region(graph)
	if root == NO_ROOT {
		return out
	}
	id := graph.roots[int(root)].symbol
	if direct, found := graph.region_of[id]; found {
		region_merge(&out, direct)
	}
	for content in graph.region_content[id] {
		if len(path) == 0 || len(content.path) == 0 || paths_overlap(content.path, path) {
			region_merge(&out, content.region)
		}
	}
	return out
}

// Record a managed value stored into a field or element. The region analysis is
// deliberately flow-insensitive, so repeated writes merge rather than erase a
// possibility; the path split still prevents an unrelated sibling read from
// inheriting the dependency.
@(private = "file")
prov_define_region_content :: proc(
	graph: ^Flow_Graph,
	root: Root_Id,
	path: []Proj_Step,
	region: Region_Set,
) {
	if root == NO_ROOT || region_is_empty(region) {
		return
	}
	id := graph.roots[int(root)].symbol
	if id == INVALID_SYMBOL {
		return
	}
	content := graph.region_content[id]
	for &entry in content {
		if len(entry.path) == len(path) && path_has_exact_prefix(entry.path, path) {
			region_merge(&entry.region, region)
			graph.region_content[id] = content
			return
		}
	}
	stored_path := make([]Proj_Step, len(path), graph.alloc)
	copy(stored_path, path)
	grown := make([dynamic]Prov_Region_Content, len(content), len(content) + 1, graph.alloc)
	copy(grown[:], content)
	append(&grown, Prov_Region_Content{path = stored_path, region = region})
	graph.region_content[id] = grown[:]
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

// design.md "Allocators": a handle carries its region through every copy of it.
// An `Option` or `Result` around one is still that handle in transit, so the
// wrapper carries whatever its payload carries.
@(private = "file")
prov_carries_allocator :: proc(c: ^Compiler, type: Type_Id, depth := 0) -> bool {
	if type == INVALID_TYPE || depth > 8 {
		return false
	}
	if type_underlying(c, type) == TYPE_ALLOCATOR {
		return true
	}
	info := underlying_info(c, type)
	if info == nil || info.kind != .Union {
		return false
	}
	for payload in info.variants {
		if payload != TYPE_VOID && prov_carries_allocator(c, payload, depth + 1) {
			return true
		}
	}
	return false
}

// The allocator region an expression denotes, or an empty set when it denotes
// nothing region-shaped.
@(private = "file")
prov_region_of :: proc(graph: ^Flow_Graph, e: Expr) -> Region_Set {
	c := graph.k.c
	#partial switch v in e {
	case ^Expr_Ident:
		return prov_region_for_symbol(graph, v.symbol)
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
	case ^Expr_Selector, ^Expr_Index:
		if root, path, ok := prov_place_of(graph, e); ok {
			return prov_region_content_at(graph, root, path)
		}
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
		if result, found := graph.call_results[v]; found {
			return result.region
		}
		return prov_call_region(graph, v, v.type)
	}
	if prov_carries_allocator(c, expr_base(e) == nil ? INVALID_TYPE : expr_base(e).type) {
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
prov_call_region :: proc(graph: ^Flow_Graph, v: ^Expr_Call, result_type: Type_Id) -> Region_Set {
	c := graph.k.c
	out := prov_empty_region(graph)
	allocator_result := prov_carries_allocator(c, result_type)
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
	if summary, found := result_summary(c, callee); found {
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

@(private = "file")
prov_substitute_region :: proc(graph: ^Flow_Graph, v: ^Expr_Call, summary: Region_Set) -> Region_Set {
	out := prov_empty_region(graph)
	for wanted, index in summary.params {
		if wanted && index < len(v.bound) && v.bound[index] != nil {
			region_merge(&out, prov_region_of(graph, v.bound[index]))
		}
	}
	out.default = summary.default
	out.unknown = summary.unknown
	// Summary-local identities cannot escape their body. The ordinary escape
	// diagnostic reports them there, so they are deliberately not substituted.
	return out
}

// Substitute each independently summarized result field at the call site.
// Missing content means the callee had no path mapping, and callers continue to
// use the conservative whole-result region in that case.
@(private = "file")
prov_call_region_content :: proc(graph: ^Flow_Graph, v: ^Expr_Call) -> []Prov_Region_Content {
	callee := v.resolution.chosen_overload
	if callee == INVALID_SYMBOL {
		callee = v.resolution.symbol
	}
	summary, found := result_summary(graph.k.c, callee)
	if !found || len(summary.region_content) == 0 {
		return nil
	}
	out := make([]Prov_Region_Content, len(summary.region_content), graph.alloc)
	for content, index in summary.region_content {
		path := make([]Proj_Step, len(content.path), graph.alloc)
		copy(path, content.path)
		out[index] = Prov_Region_Content {
			path = path,
			region = prov_substitute_region(graph, v, content.region),
		}
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
	// carriers do, because its cleanup still has to run — but only an owner of a
	// region this reset can actually reach: a second arena's containers are none
	// of its business, the whole point of giving each local provider a token.
	//
	// An owner is live when it may be used later or still needs cleanup on some
	// outgoing path; an explicitly dropped owner is dead and no longer blocks a
	// reset (design.md). Scope presence can't answer that, so the answer is
	// M5a's, recorded at this same call node one pass earlier.
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
		owner_region := prov_region_for_symbol(graph, id)
		if region_is_empty(owner_region) {
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

// A borrow stored where it outlives the statement that stored it. The
// destination is resolved as a place, so a field, a nested container element,
// and a write through a tracked alias are all seen, not only a bare
// identifier. Only a destination that actually receives a borrow is reported,
// so ordinary global data costs nothing.
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
prov_region_escape :: proc(graph: ^Flow_Graph, target: Expr, value: Expr) {
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
	set := prov_result_region(graph, value)
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

@(private = "file")
prov_field_step :: proc(graph: ^Flow_Graph, v: ^Expr_Selector) -> Proj_Step {
	if !type_is_union(graph.k.c, expr_base(v.operand).type) {
		if field := symbol_of(graph.k.c, v.resolution.symbol); field != nil {
			return proj_field(int(field.index))
		}
	}
	return proj_wild()
}

@(private = "file")
prov_index_path :: proc(graph: ^Flow_Graph, v: ^Expr_Index) -> []Proj_Step {
	type := expr_base(v.operand).type
	#partial switch underlying_kind(graph.k.c, type) {
	case .Array:
		return prov_extend(graph, nil, prov_index_step(graph, v.indices))
	case .Map:
		key: Expr
		if len(v.indices) == 1 {
			key = v.indices[0]
		}
		entry := prov_extend(graph, nil, prov_map_entry_step(graph, type, key))
		return prov_extend(graph, entry, proj_field(PROJ_MAP_VALUE))
	}
	return prov_extend(graph, nil, proj_wild())
}

// Find the carrier at which a place leaves lexical storage, evaluating it and
// each subscript once. Keep the rest of the projection together: `p^.left`
// reads left's content without making the contents of right live as well.
@(private = "file")
prov_read_through_carrier :: proc(graph: ^Flow_Graph, place: Expr) -> ([]int, []Proj_Step, bool) {
	#partial switch v in place {
	case ^Expr_Postfix:
		if v.op == .Caret {
			return walk_flow_expr(graph, v.operand), nil, true
		}
	case ^Expr_Selector:
		if v.resolution.kind != .Field || v.operand == nil {
			return nil, nil, false
		}
		step := prov_field_step(graph, v)
		if type_is_pointer(graph.k.c, expr_base(v.operand).type) {
			return walk_flow_expr(graph, v.operand), prov_extend(graph, nil, step), true
		}
		if carriers, path, ok := prov_read_through_carrier(graph, v.operand); ok {
			return carriers, prov_extend(graph, path, step), true
		}
	case ^Expr_Index:
		if len(v.bound) > 0 || v.operand == nil {
			return nil, nil, false
		}
		kind := underlying_kind(graph.k.c, expr_base(v.operand).type)
		if kind == .Slice || kind == .Pointer || kind == .C_Pointer {
			carriers := walk_flow_expr(graph, v.operand)
			for index in v.indices {
				walk_flow_expr(graph, index)
			}
			// The carrier's loan already names its element range. Keeping that
			// range is conservative even after reslicing or an unknown index.
			return carriers, nil, true
		}
		if carriers, path, ok := prov_read_through_carrier(graph, v.operand); ok {
			for index in v.indices {
				walk_flow_expr(graph, index)
			}
			return carriers, prov_concat_path(graph, path, prov_index_path(graph, v)), true
		}
	}
	return nil, nil, false
}

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
		return root, prov_extend(graph, path, prov_field_step(graph, v)), true

	case ^Expr_Index:
		if len(v.bound) > 0 || v.operand == nil {
			return NO_ROOT, nil, false // user-defined addressing
		}
		// A container element is a place in its owner's *current allocation*, so
		// the container is the root and every relocating operation on it ends the
		// pointer. Which slot is unknowable once the storage can move, so the
		// projection is the whole container.
		#partial switch underlying_kind(c, expr_base(v.operand).type) {
		case .Array, .Dynamic_Array, .Map:
			root, path, ok := prov_place_of(graph, v.operand)
			if !ok {
				return NO_ROOT, nil, false
			}
			return root, prov_concat_path(graph, path, prov_index_path(graph, v)), true
		}
		return NO_ROOT, nil, false
	}
	return NO_ROOT, nil, false
}

// Index expressions inside a place chain are ordinary values and still have to
// be walked; the place itself contributes one access, not one per link.
@(private = "file")
prov_walk_subscripts :: proc(graph: ^Flow_Graph, e: Expr, publish_map_keys := false) {
	#partial switch v in e {
	case ^Expr_Selector:
		prov_walk_subscripts(graph, v.operand, publish_map_keys)
	case ^Expr_Index:
		prov_walk_subscripts(graph, v.operand, publish_map_keys)
		key_sources: []int
		for index, position in v.indices {
			loans := walk_flow_expr(graph, index)
			if position == 0 {
				key_sources = loans
			}
		}
		if !publish_map_keys || len(v.bound) > 0 || len(v.indices) != 1 || len(key_sources) == 0 ||
		   underlying_kind(graph.k.c, expr_base(v.operand).type) != .Map {
			return
		}
		info := underlying_info(graph.k.c, expr_base(v.operand).type)
		if info == nil {
			return
		}
		// An assignment through a map place inserts the key when absent. When an
		// equal key already exists its original representation remains, so even a
		// known key joins rather than replacing the previous key dependency.
		prov_retain_escape(graph, v.operand, key_sources, v.span)
		root, path, ok := prov_place_of(graph, v.operand)
		if !ok {
			// The map itself was reached through a carrier. Its precise entry path
			// is solver-owned, so publish conservatively to every content slot of
			// each root that carrier may name.
			if through := prov_retain_through_carrier(graph, v.operand); len(through) > 0 {
				prov_weaken(graph, key_sources, info.key)
				prov_emit(graph, Prov_Event {
					kind = .Publish, span = v.span, sources = key_sources, into = through,
				})
			}
			return
		}
		entry := prov_extend(graph, path, prov_map_entry_step(graph, expr_base(v.operand).type, v.indices[0]))
		written := prov_extend(graph, entry, proj_field(PROJ_MAP_KEY))
		if content := prov_content_at(graph, root, written); len(content) > 0 {
			prov_define_content(graph, content, key_sources, v.span, written, info.key, true)
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

// The entry step a map access uses: the key's own entry when the key is a
// constant this body has room for, and the wildcard otherwise. The wildcard
// overlaps every keyed entry, so an unknown key still reads all of them and
// still joins when it writes.
@(private = "file")
prov_map_entry_step :: proc(graph: ^Flow_Graph, map_type: Type_Id, key: Expr) -> Proj_Step {
	if key == nil || !map_shape_is_keyed(graph.k.c, map_type) {
		return proj_wild()
	}
	base := expr_base(key)
	if base == nil || !base.is_const {
		return proj_wild()
	}
	name: string
	#partial switch base.const_value.kind {
	case .String:
		name = fmt.aprintf("s:%s", base.const_value.text, allocator = graph.alloc)
	case .Integer:
		value, ok := bi_to_i64(graph.k.c, base.const_value.integer)
		if !ok {
			return proj_wild()
		}
		name = fmt.aprintf("i:%d", value, allocator = graph.alloc)
	case .Rune:
		value, ok := bi_to_i64(graph.k.c, base.const_value.integer)
		if !ok {
			return proj_wild()
		}
		name = fmt.aprintf("r:%d", value, allocator = graph.alloc)
	case .Boolean:
		name = fmt.aprintf("b:%v", base.const_value.boolean, allocator = graph.alloc)
	case:
		return proj_wild()
	}
	if entry, found := graph.map_key_entries[name]; found {
		return proj_range(i64(entry), i64(entry) + 1)
	}
	entry := len(graph.map_key_entries)
	if entry >= MAP_KEY_SLOTS {
		return proj_wild() // out of entries; the wildcard answers for the rest
	}
	graph.map_key_entries[name] = entry
	return proj_range(i64(entry), i64(entry) + 1)
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
	// destination — a `thread_local` view does not outlive the process.
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
	// A fixed array, string, or dynamic array is sliced out of its own root's
	// storage: `st[low:high]` borrows a subrange view exactly as slicing a fixed
	// array does, and a dynamic array's range is a borrow of its own root too,
	// which every relocating operation on it then invalidates (design.md
	// "Dynamic arrays"). Reslicing a slice or pointer instead keeps the loans
	// the carrier already holds.
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
	// An unmanaged composite — a slice literal's hidden `[N]T`, or an array
	// literal sliced in place — is frame storage and lives for that scope. A
	// *managed* one such as `[dynamic]int{1, 2}[:]` owns an allocation instead,
	// and nothing keeps that alive past the statement that built it.
	_, is_literal := v.operand.(^Expr_Composite)
	if is_literal && !type_is_managed(graph.k.c, expr_base(v.operand).type) {
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
		if d.destructure.active {
			// One record initializes every binding on the left, so its region
			// component is that one value's.
			initializer = d.values[0]
		} else if symbol_index < len(d.values) {
			initializer = d.values[symbol_index]
		}
		projected := d.destructure.active ? symbol_index : -1
		prov_declare_region(graph, id, sym, initializer, projected)
		slot, is_carrier := prov_slot_for_symbol(graph, id)
		content := prov_content_slots(graph, id)
		if !is_carrier && len(content) == 0 {
			continue
		}
		sources: []int
		if value_loans != nil {
			if d.destructure.active {
				// design.md "Destructuring": each binding takes its own field's root,
				// not the record's joined set.
				sources = prov_destructure_field(
					graph, value_loans[0], &d.destructure, symbol_index, sym.type, sym.span,
				)
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
prov_declare_region :: proc(
	graph: ^Flow_Graph,
	id: Symbol_Id,
	sym: ^Symbol,
	initializer: Expr,
	projected: int = -1,
) {
	initializer_region := Region_Set{}
	if initializer != nil {
		if projected >= 0 {
			initializer_region = prov_result_region_at(graph, initializer, {proj_field(projected)})
		} else {
			initializer_region = prov_result_region(graph, initializer)
		}
	}
	// design.md: a local `mem.Arena`/`mem.Scratch` *is* a region this body
	// created, so it gets its own token rather than merging into anything.
	if type_is_region_provider(graph.k.c, sym.type) && sym.duration == .None {
		graph.region_of[id] = prov_provider_region(graph, id)
		if initializer != nil {
			parent := initializer_region
			if !region_is_empty(parent) {
				graph.provider_parents[id] = parent
			}
		}
		append(&graph.owners_in_scope, id)
		return
	}
	if type_underlying(graph.k.c, sym.type) == TYPE_ALLOCATOR {
		if initializer != nil {
			graph.region_of[id] = initializer_region
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
		region_merge(&set, initializer_region)
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
	// Resetting a region is rejected while a live owning value, or a borrow,
	// still refers to storage from that allocator (design.md). All
	// lexical owners register once; the flow-insensitive region map may learn a
	// dependency from a later assignment.
	if sym.duration == .None {
		append(&graph.owners_in_scope, id)
	}
}

// One destructured binding's provenance: the record's own sources projected
// through that field, so a borrow reaching one field does not become a borrow
// reaching its siblings.
@(private = "file")
prov_destructure_field :: proc(
	graph: ^Flow_Graph,
	sources: []int,
	plan: ^Destructure,
	index: int,
	field_type: Type_Id,
	span: Span,
) -> []int {
	if len(sources) == 0 {
		return nil
	}
	return prov_project_content(graph, sources, plan.record, {proj_field(index)}, field_type, span)
}

@(private = "file")
prov_assign :: proc(graph: ^Flow_Graph, s: ^Stmt_Assign, value_loans: [][]int) {
	for target, index in s.lhs {
		sources: []int
		value: Expr
		if s.destructure.active {
			value = s.rhs[0]
			if value_loans != nil && len(value_loans) > 0 {
				sources = prov_destructure_field(
					graph, value_loans[0], &s.destructure, index, expr_base(target).type, expr_span(target),
				)
			}
		} else if index < len(s.rhs) {
			value = s.rhs[index]
			if value_loans != nil && index < len(value_loans) {
				sources = value_loans[index]
			}
		}
		if value != nil && s.op == .Assign {
			prov_region_escape(graph, target, value)
		}
		value_region := Region_Set{}
		if value != nil {
			if s.destructure.active {
				value_region = prov_result_region_at(graph, value, {proj_field(index)})
			} else {
				value_region = prov_result_region(graph, value)
			}
		}
		if ident, is_ident := target.(^Expr_Ident); is_ident && s.op == .Assign {
			if value != nil {
				if type_underlying(graph.k.c, expr_base(target).type) == TYPE_ALLOCATOR {
					existing, found := graph.region_of[ident.symbol]
					if !found {
						existing = prov_empty_region(graph)
					}
					region_merge(&existing, value_region)
					graph.region_of[ident.symbol] = existing
				} else if type_is_managed(graph.k.c, expr_base(target).type) {
					existing, found := graph.region_of[ident.symbol]
					if !found {
						existing = prov_empty_region(graph)
					}
					region_merge(&existing, value_region)
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
		root, path, place_ok := prov_place_of(graph, target)
		if !place_ok && s.op == .Assign {
			// The destination is reached through a carrier, so what it names is
			// solved rather than written out.
			if through := prov_retain_through_carrier(graph, target); len(through) > 0 {
				prov_walk_subscripts(graph, target, true)
				// The destination's own type still decides the capability, exactly
				// as it would if the place had been written out: a fresh mutable
				// borrow written into a read-only field is simply created
				// read-only (design.md "Weakening and read-only reborrows").
				if len(sources) > 0 {
					prov_weaken(graph, sources, expr_base(target).type)
					prov_emit(graph, Prov_Event {
						kind    = .Publish,
						span    = expr_span(target),
						sources = sources,
						into    = through,
					})
				}
				prov_emit(graph, Prov_Event{kind = .Live, sources = through, span = expr_span(target)})
				continue
			}
		}
		if place_ok {
			if value != nil && s.op == .Assign &&
			   (type_is_managed(graph.k.c, expr_base(target).type) ||
			    type_underlying(graph.k.c, expr_base(target).type) == TYPE_ALLOCATOR) {
				prov_define_region_content(
					graph, root, path, value_region,
				)
			}
			prov_walk_subscripts(graph, target, s.op == .Assign)
			prov_access(graph, root, path, .Write, expr_span(target))
			// Only the written path is replaced; the surviving fields keep what
			// they held.
			if written := prov_content_at(graph, root, path); len(written) > 0 && s.op == .Assign {
				prov_define_content(graph, written, sources, expr_span(target), path, expr_base(target).type)
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
	info := underlying_info(graph.k.c, prov_call_proc_type(graph, v))
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
prov_result_is_inout :: proc(graph: ^Flow_Graph, v: ^Expr_Call) -> bool {
	info := underlying_info(graph.k.c, prov_call_proc_type(graph, v))
	return info != nil && info.result_inout
}

@(private = "file")
prov_argument_is_inout :: proc(graph: ^Flow_Graph, v: ^Expr_Call, index: int) -> bool {
	// The declaration's type when there is one, the callee value's otherwise: a
	// parameter mode is part of procedure-type compatibility, so an indirect call
	// answers this question as well as a direct one does.
	info := underlying_info(graph.k.c, prov_call_proc_type(graph, v))
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
		case .Unsafe_Free:
			// The unchecked release: no allocation root to end, and nothing to
			// invalidate, because the pointer's provenance is exactly what the
			// caller is promising instead of proving (design.md "What is not
			// checked"). The operands are still read.
			for bound in v.bound {
				walk_flow_expr(graph, bound)
			}
			return nil
		case .Free:
			if len(v.bound) >= 1 {
				sources := walk_flow_expr(graph, v.bound[0])
				// A written allocator is read like any other operand; only the
				// pointer names what the release ends.
				for bound in v.bound[1:] {
					walk_flow_expr(graph, bound)
				}
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
		case .Atomic_Load, .Atomic_Store, .Atomic_Exchange, .Atomic_Compare_Exchange,
		     .Atomic_Add, .Atomic_Sub, .Atomic_And, .Atomic_Or, .Atomic_Xor, .Atomic_Fence:
			// An atomic reads and writes *through* its address operand; what it hands
			// back is the value in that storage, not a borrow of it. Without this, an
			// `Atomic(^T)` could never load, because the coarse rule would derive the
			// loaded pointer from the address of the atomic itself and then reject it
			// for outliving the receiver.
			for argument in v.bound {
				if argument != nil {
					walk_flow_expr(graph, argument)
				}
			}
			return nil
		case .Unsafe_Forget:
			if len(v.bound) == 1 {
				// The carriers the operand held go nowhere: nothing binds the
				// forgotten value, so every loan inside it ends here. Invalidating
				// the source root is what keeps `forget` from reading as a lifetime
				// extension — a borrow of it dies here exactly as at a `drop`.
				prov_consume(graph, v.bound[0], v.span, "forgotten")
			}
			return nil
		}
	}
	receiver := Param_Mode.Value
	has_receiver := false
	container_op := Container_Op.None
	if sym := symbol_of(c, v.resolution.chosen_overload); sym != nil && sym.has_receiver {
		receiver, has_receiver = sym.receiver, true
		if sym.synth == .Container_Op {
			container_op = sym.container_op
		}
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
				if prov_op_removes_element(container_op) {
					// What a removal hands back is what that element held, not a
					// borrow of the container it came out of. The invalidation
					// above is still what ends the borrows the container's own
					// storage was carrying.
					actuals[index] = prov_content_at(
						graph, root, prov_element_path(graph, v, path, container_op),
					)
				} else {
					actuals[index] = prov_borrow(graph, root, path, true, expr_span(argument), "borrow")
				}
				borrowed = prov_join(graph, borrowed, actuals[index])
			}
			continue
		}
		if index == 0 && prov_op_returns_view(container_op) {
			// design.md "Iteration adapters": a view holds the map's table, so it
			// borrows the map for as long as it lives -- exactly as the `[]T` a
			// dynamic array hands out borrows that container. The borrow is
			// read-only: a view yields copies, and a live one is what stops the map
			// being mutated under it.
			//
			// The two components are separate. What the *stored elements* borrow
			// travels with the view as well: a `map[K]string_view` yields views of
			// someone else's bytes, and an owned copy of one still obeys that
			// source's lifetime, not the map's.
			held := walk_flow_expr(graph, argument)
			if root, path, ok := prov_place_of(graph, argument); ok {
				prov_access(graph, root, path, .Read, expr_span(argument))
				held = prov_join(
					graph, held, prov_borrow(graph, root, path, false, expr_span(argument), "view"),
				)
			} else if prov_expr_is_temporary(argument) {
				// A view of a temporary map borrows storage that ends with the
				// statement that built it, exactly as slicing one does.
				held = prov_join(
					graph, held,
					prov_borrow(graph, prov_temp_root(graph, expr_span(argument)), nil, false, v.span, "view"),
				)
			}
			actuals[index] = held
			borrowed = prov_join(graph, borrowed, held)
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
		if index == 0 && container_op == .Map_Lookup_Value {
			// `lookup_value` copies the selected payload. Its result carries the
			// payload's stored dependencies, including when the payload is itself
			// a bare carrier; only entry addresses borrow the map's storage.
			result_type := v.type
			entry_step := prov_map_call_step(graph, v)
			if root, path, ok := prov_place_of(graph, argument); ok {
				prov_walk_subscripts(graph, argument)
				prov_access(graph, root, path, .Read, expr_span(argument))
				entry := prov_extend(graph, path, entry_step)
				value := prov_extend(graph, entry, proj_field(PROJ_MAP_VALUE))
				actuals[index] = prov_read_content(graph, root, value, result_type, v.span)
			} else {
				receiver := walk_flow_expr(graph, argument)
				entry := prov_extend(graph, nil, entry_step)
				value := prov_extend(graph, entry, proj_field(PROJ_MAP_VALUE))
				actuals[index] = prov_project_content(
					graph, receiver, expr_base(argument).type, value, result_type, v.span,
				)
			}
		} else {
			actuals[index] = walk_flow_expr(graph, argument)
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
// `static` is direct — the argument must still exist when the process ends.
// `stored` means the callee may write the argument into a destination this
// call hands it, so the call is modelled as that assignment: same duration
// check, same flow — the destination carries what the argument borrowed, and
// existing scope rules handle the rest. Modelling the flow lets a caller-local
// destination work without proving one local outlives another: the loan just
// travels, and using it after its root ends is already an error.
@(private = "file")
prov_call_retention :: proc(graph: ^Flow_Graph, v: ^Expr_Call, actuals: [][]int) {
	proc_type := prov_call_proc_type(graph, v)
	if underlying_info(graph.k.c, proc_type) == nil {
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
	info := underlying_info(c, proc_type)
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

// Which operations hand back a borrowed view of the container rather than a
// value out of it.
@(private = "file")
prov_op_returns_view :: proc(op: Container_Op) -> bool {
	#partial switch op {
	case .Map_Entries, .Map_Keys, .Map_Values:
		return true
	}
	return false
}

// Which operations hand an element back out. Their result is the element, so it
// carries what the element held rather than a borrow of the container.
@(private = "file")
prov_op_removes_element :: proc(op: Container_Op) -> bool {
	#partial switch op {
	case .Pop, .Remove, .Remove_Unordered, .Map_Remove:
		return true
	}
	return false
}

// The content path a removal reads from. A map entry's key and value are
// separate storage, so removing a value does not hand back what a key borrows.
@(private = "file")
prov_element_path :: proc(
	graph: ^Flow_Graph,
	v: ^Expr_Call,
	path: []Proj_Step,
	op: Container_Op,
) -> []Proj_Step {
	if op != .Map_Remove {
		return prov_extend(graph, path, proj_wild())
	}
	entry := prov_extend(graph, path, prov_map_call_step(graph, v))
	return prov_extend(graph, entry, proj_field(PROJ_MAP_VALUE))
}

// The entry step for a map operation that takes its key as an argument.
@(private = "file")
prov_map_call_step :: proc(graph: ^Flow_Graph, v: ^Expr_Call) -> Proj_Step {
	if len(v.bound) < 2 || v.bound[0] == nil {
		return proj_wild()
	}
	return prov_map_entry_step(graph, expr_base(v.bound[0]).type, v.bound[1])
}

// A container operation is resolved before this point, so the solver asks
// `Container_Op` rather than recognising a member name. Stored key/value
// borrows become the receiver's and must satisfy its duration just like an
// indexed assignment. A fallible write joins the matching previous content
// because its failure edge changes nothing.
@(private = "file")
prov_container_content :: proc(graph: ^Flow_Graph, v: ^Expr_Call, op: Container_Op, actuals: [][]int) {
	#partial switch op {
	case .Append, .Insert, .Map_Try_Insert, .Clear, .Map_Clear:
	case:
		return
	}
	if len(v.bound) == 0 || v.bound[0] == nil {
		return
	}
	info := underlying_info(graph.k.c, expr_base(v.bound[0]).type)
	if info == nil {
		return
	}
	if op == .Clear || op == .Map_Clear {
		// A successful clear is a known whole-content replacement. Existing
		// copies have their own slots and keep their dependencies; only the
		// receiver's removed contents become empty.
		if root, path, ok := prov_place_of(graph, v.bound[0]); ok {
			if content := prov_content_at(graph, root, path); len(content) > 0 {
				prov_define_content(
					graph, content, nil, v.span, path, expr_base(v.bound[0]).type,
				)
			}
		}
		return
	}
	stored: []int
	#partial switch op {
	case .Append:
		if type_carries_borrow(graph.k.c, info.element).any && len(actuals) > 1 {
			stored = actuals[1]
		}
	case .Insert:
		if type_carries_borrow(graph.k.c, info.element).any && len(actuals) > 2 {
			stored = actuals[2]
		}
	case .Map_Try_Insert:
		if type_carries_borrow(graph.k.c, info.key).any && len(actuals) > 1 {
			stored = actuals[1]
		}
		if type_carries_borrow(graph.k.c, info.element).any && len(actuals) > 2 {
			stored = prov_join(graph, stored, actuals[2])
		}
	}
	if len(stored) == 0 {
		return
	}
	// This also resolves a receiver reached through a pointer or slice carrier,
	// so synthesized mutation cannot bypass caller/static retention through an
	// alias even when no lexical root is available for the content update below.
	prov_retain_escape(graph, v.bound[0], stored, v.span)
	root, path, ok := prov_place_of(graph, v.bound[0])
	if !ok {
		return
	}
	if op == .Map_Try_Insert {
		entry := prov_extend(graph, path, prov_map_call_step(graph, v))
		if len(actuals) > 1 && len(actuals[1]) > 0 {
			written := prov_extend(graph, entry, proj_field(PROJ_MAP_KEY))
			if content := prov_content_at(graph, root, written); len(content) > 0 {
				prov_define_content(graph, content, actuals[1], v.span, written, info.key, true)
			}
		}
		if len(actuals) > 2 && len(actuals[2]) > 0 {
			written := prov_extend(graph, entry, proj_field(PROJ_MAP_VALUE))
			if content := prov_content_at(graph, root, written); len(content) > 0 {
				prov_define_content(graph, content, actuals[2], v.span, written, info.element, true)
			}
		}
		return
	}
	// A dynamic array's wildcard element path represents every existing element
	// plus the inserted one, so the write naturally joins instead of replacing.
	written := prov_extend(graph, path, proj_wild())
	if content := prov_content_at(graph, root, written); len(content) > 0 {
		prov_define_content(graph, content, stored, v.span, written, info.element)
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
	return prov_carries_borrow(c, v.type)
}

// A carrier, or an `Option`/`Result` around one: the wrapper travels with the
// borrow its payload holds, and unwrapping it hands that borrow on.
@(private = "file")
prov_carries_borrow :: proc(c: ^Compiler, type: Type_Id, depth := 0) -> bool {
	if type == INVALID_TYPE || depth > 8 {
		return false
	}
	if type_is_carrier(c, type) {
		return true
	}
	info := underlying_info(c, type)
	if info == nil || info.kind != .Union {
		return false
	}
	for payload in info.variants {
		if payload != TYPE_VOID && prov_carries_borrow(c, payload, depth + 1) {
			return true
		}
	}
	return false
}

@(private = "file")
prov_store_call_results :: proc(graph: ^Flow_Graph, v: ^Expr_Call, actuals: [][]int, borrowed: []int) -> []int {
	if v.type == TYPE_VOID || v.type == INVALID_TYPE {
		return nil
	}
	result := Prov_Call_Result {
		loans          = prov_call_result(graph, v, actuals, borrowed, v.type),
		region         = prov_call_region(graph, v, v.type),
		region_content = prov_call_region_content(graph, v),
	}
	graph.call_results[v] = result
	return result.loans
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
	result_type: Type_Id,
) -> []int {
	c := graph.k.c
	// design.md "`inout` results": an `inout` result is the caller's storage, so
	// the call is a place aliasing whatever the `inout` arguments named. It is not
	// a carrier type, which is why it is answered before the carrier test.
	if prov_result_is_inout(graph, v) {
		out: []int
		for slots, index in actuals {
			if prov_argument_is_inout(graph, v, index) {
				out = prov_join(graph, out, slots)
			}
		}
		return type_is_carrier(c, result_type) ? out : prov_value_content(graph, out, result_type, v.span)
	}
	// design.md "Shared ownership": "`handle.get()` returns a non-owning `^T`
	// whose root provenance derives from that handle", and "the borrow may not
	// outlive the handle used to obtain it". The body cannot show that — the
	// payload address comes out of a `rawptr` control block — so the language
	// asserts it here instead of inferring it.
	if len(actuals) > 0 && prov_receiver_is_shared_handle(graph, v) {
		if type_is_carrier(c, result_type) {
			return actuals[0]
		}
		return prov_value_content(graph, actuals[0], result_type, v.span)
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
	out: []int
	if summary, found := result_summary(c, callee); found {
		// Sibling fields may alias the same synthesized root. Keep that root
		// shared even though each path has its own dependencies and capability.
		synthetic := make(map[Root_Kind]Root_Id, graph.alloc)
		if summary.content_type == result_type && len(summary.content) > 0 {
			content := prov_temp_content(graph, result_type)
			for slot in content {
				sources: []int
				for path in summary.content {
					if paths_overlap(graph.prov_slots[slot].path, path.path.steps) {
						leaf_type := path.path.truncated ? result_type : path.path.type
						sources = prov_join(graph, sources, prov_substitute_result(graph, v, actuals, path.dependencies, leaf_type, &synthetic))
					}
				}
				prov_define_one_content(graph, slot, sources, v.span)
			}
			return content
		}
		out = prov_substitute_result(graph, v, actuals, summary.dependencies, result_type, &synthetic)
	} else if direct {
		// No summary yet is a forward fixed-point edge, not erased metadata.
		return nil
	} else {
		// Without a mapping every escaping argument can reach every result path.
		out = prov_escaping_actuals(graph, v, actuals)
		if len(out) == 0 && len(borrowed) == 0 {
			out = prov_synthetic_borrow(graph, v, .Unknown, result_type)
		}
	}
	return type_is_carrier(c, result_type) ? out : prov_value_content(graph, out, result_type, v.span)
}


// Whether this call's receiver is a `shared(T)` or `weak(T)` handle. Only the
// receiver is asked about: what the language promises is about the handle a
// borrow was taken from, not about the method that took it.
@(private = "file")
prov_receiver_is_shared_handle :: proc(graph: ^Flow_Graph, v: ^Expr_Call) -> bool {
	sym := symbol_of(graph.k.c, v.resolution.chosen_overload)
	if sym == nil || !sym.has_receiver {
		return false
	}
	return type_is_shared_handle(graph.k.c, sym.owner_type)
}

// Substitute one result path's parameter dependencies. Parameter paths are
// matched against the actual value's shape, never against its slot count.
@(private = "file")
prov_substitute_result :: proc(
	graph: ^Flow_Graph,
	v: ^Expr_Call,
	actuals: [][]int,
	dependencies: Result_Dependencies,
	type: Type_Id,
	synthetic: ^map[Root_Kind]Root_Id,
) -> []int {
	out: []int
	for wanted, index in dependencies.params {
		if !wanted || index >= len(actuals) {
			continue
		}
		paths := index < len(dependencies.param_paths) ? dependencies.param_paths[index] : nil
		param_type := prov_parameter_type(graph, v, index)
		shape := carrier_shape(graph.k.c, param_type)
		if len(paths) == 0 || len(paths) != len(shape) {
			out = prov_join(graph, out, actuals[index])
			continue
		}
		for named, position in paths {
			if named {
				out = prov_join(graph, out, prov_select_content(graph, actuals[index], param_type, shape[position].steps))
			}
		}
	}
	kinds := [4]Root_Kind{.Static, .Thread_Local, .Allocation, .Unknown}
	wanted := [4]bool{dependencies.static, dependencies.thread, dependencies.fresh, dependencies.unknown || dependencies.local}
	for needed, index in wanted {
		if !needed {
			continue
		}
		kind := kinds[index]
		root, found := synthetic^[kind]
		if !found {
			root = prov_synthetic_root(graph, v, kind)
			synthetic^[kind] = root
		}
		out = prov_join(graph, out, prov_borrow(
			graph, root, nil, type_carries_borrow(graph.k.c, type).mutable,
			v.span, carrier_noun(graph.k.c, type),
		))
	}
	return out
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
prov_synthetic_root :: proc(graph: ^Flow_Graph, v: ^Expr_Call, kind: Root_Kind) -> Root_Id {
	name: string
	#partial switch kind {
	case .Allocation:   name = "this allocation"
	case .Static:       name = "static storage"
	case .Thread_Local: name = "`thread_local` storage"
	case:               name = "unknown storage"
	}
	return prov_new_root(graph, kind, v.span, name)
}

@(private = "file")
prov_synthetic_borrow :: proc(graph: ^Flow_Graph, v: ^Expr_Call, kind: Root_Kind, type: Type_Id) -> []int {
	root := prov_synthetic_root(graph, v, kind)
	return prov_borrow(
		graph,
		root,
		nil,
		carrier_is_mutable(graph.k.c, type),
		v.span,
		carrier_noun(graph.k.c, type),
	)
}

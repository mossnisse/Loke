// A disposable per-procedure control-flow view: annotated AST, not MIR (a real
// MIR is deferred past v1). Rebuilt per concrete body instance, so generic
// specializations never share liveness state.
//
// Events are deliberately few. A managed local goes live at a completed
// initialization, dies at `move`/`drop`, must be live at a use, and is cleaned
// up wherever control leaves its declaring scope. Every exit emits the cleanup
// events of the scopes it passes through, innermost first.
// Provenance event construction lives in cfg_provenance.odin.
package lokec

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
	// a reset — design.md). Calls use their AST node; provider cleanups use a
	// body-local ordinal since the two passes use separate graphs.
	Reset_Point,
}

Flow_Event :: struct {
	cleanup_reset: Cleanup_Reset_Key,
	kind:   Flow_Event_Kind,
	slot:   int,
	span:   Span,
	name:   string,
	assign: ^Stmt_Assign,
	target: int,
	// `Reset_Point`: a call, or `cleanup_reset` for a lexical provider exit.
	call:   ^Expr_Call,
	// Names the operation attempted, for diagnostics. Not a history: states are
	// a lattice, so which earlier op consumed the binding isn't tracked.
	verb:   string,
}

// Cleanup syntax can be expanded at several exits (including inside defers).
// Number provider cleanups in walk order, shared by all three graph modes.
Cleanup_Reset_Key :: struct {
	body: ^Expr_Proc,
	ordinal: int,
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
	precision_entry: []Precision_Loss,
	precision_exit: []Precision_Loss,
	reach_exit:    []u8,
	invalid_entry: []bool,
	invalid_exit:  []bool,
	live_entry:    []bool,
	live_exit:     []bool,
	use_entry:     []Span,
	use_exit:      []Span,
	prov_visited:  bool,
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
	// `x: T = ---` declares storage whose uses go unchecked (design.md "Built-in
	// values"). The state is still followed, so nothing is dropped for storage a
	// foreign write filled; only the not-live diagnostic is suppressed.
	unchecked:     bool,
	// Whether any path completes an initialization of this local. A local no
	// path ever writes is dead because it was never initialized, not because
	// something consumed it, and the diagnostic says so.
	ever_written:  bool,
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
	// The loan a non-owning binding views: a `&` loop element or a switch
	// payload over a place. `&binding` names the source's storage, so it
	// borrows the source rather than the binding's own frame slot.
	view_loans:     map[Symbol_Id][]int,
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
	allocation_region_sources: [dynamic]Prov_Allocation_Region_Source,
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
	cleanup_reset_count: int,
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
	graph.view_loans = make(map[Symbol_Id][]int, 8, allocator)
	graph.content_by_symbol = make(map[Symbol_Id][]int, 8, allocator)
	graph.call_results = make(map[^Expr_Call]Prov_Call_Result, 8, allocator)
	graph.allocation_region_sources = make([dynamic]Prov_Allocation_Region_Source, allocator)
	graph.summary_callees = make([dynamic]Symbol_Id, allocator)
	graph.temp_roots = make([dynamic]Root_Id, allocator)
	graph.region_of = make(map[Symbol_Id]Region_Set, 8, allocator)
	graph.region_content = make(map[Symbol_Id][]Prov_Region_Content, 8, allocator)
	graph.provider_parents = make(map[Symbol_Id]Region_Set, 4, allocator)
	graph.owners_in_scope = make([dynamic]Symbol_Id, allocator)
	graph.provider_bits = make(map[Symbol_Id]u64, 4, allocator)
	graph.map_key_entries = make(map[string]int, 4, allocator)
	graph.reborrows = make([dynamic]Prov_Reborrow, allocator)
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
		prov_finalize_allocation_regions(graph)
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
			id := graph.roots[int(action.root)].symbol
			provider_cleanup_reset(graph, id, action.span)
			// A borrow may be used only while its root is live (design.md). The
			// storage ends here, so every loan of it does too.
			prov_emit(graph, Prov_Event{kind = .Root_End, root = action.root, span = action.span})
			continue
		}
		slot := action.slot
		sym := symbol_of(graph.k.c, graph.tracked[slot].symbol)
		provider_cleanup_reset(graph, graph.tracked[slot].symbol, sym == nil ? no_span() : sym.span)
		emit(graph, Flow_Event {
			kind = .Cleanup,
			slot = slot,
			span = sym == nil ? no_span() : sym.span,
			name = sym == nil ? "" : identifier_text(graph.k.c, sym.name),
		})
	}
}

@(private = "file")
provider_cleanup_reset :: proc(graph: ^Flow_Graph, id: Symbol_Id, span: Span) {
	sym := symbol_of(graph.k.c, id)
	if sym == nil || !type_is_region_provider(graph.k.c, sym.type) || sym.duration != .None {
		return
	}
	graph.cleanup_reset_count += 1
	key := Cleanup_Reset_Key{graph.literal, graph.cleanup_reset_count}
	if graph.mode == .Lifecycle {
		emit(graph, Flow_Event{kind = .Reset_Point, cleanup_reset = key, span = span})
	} else {
		dead, found := graph.k.c.cleanup_reset_dead[key]
		// Unreachable exits have no solved checkpoint. A consumed provider has
		// no cleanup to execute, so neither case ends a region here.
		if !found || slice.contains(dead, id) {
			return
		}
		prov_reset(graph, prov_region_for_symbol(graph, id), span, true, nil, dead)
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

	// An `impl` declares members; it runs nothing and holds nothing live.
	case ^Item_Impl:

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
		// Static-duration storage is always live after initialization and the
		// compiler never drops it automatically (design.md), so there is no state
		// to follow and no scope-exit obligation.
		if sym.duration != .None {
			continue
		}
		// Every local is followed, because design.md "Variable declarations" makes
		// definite initialization a property of all of them. Only a managed one
		// carries a scope-exit obligation.
		managed := type_is_managed(graph.k.c, sym.type)
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
		if managed {
			append(&graph.in_scope, Flow_Cleanup{kind = .Local, slot = slot})
		}
		// The implicit action is placed at the declaration point, where
		// initialization completes (design.md). A declaration with no initializer
		// completes none: the local starts dead and a later full assignment
		// initializes it. `x: T = ---` starts dead as well, and only stops the
		// diagnostic.
		initializer, written := declared_initializer(d, symbol_index)
		if written && initializer == nil {
			graph.tracked[slot].unchecked = true
		}
		if !written || initializer == nil {
			continue
		}
		event := Flow_Event {
			kind = .Init,
			slot = slot,
			span = sym.span,
			name = identifier_text(graph.k.c, sym.name),
		}
		emit(graph, event)
	}
}

// The initializer belonging to one binding of a declaration, and whether the
// declaration wrote one at all. One value spread over several bindings
// initializes each of them; `written` with a nil expression is the `---`
// marker (src/ast.odin).
@(private = "file")
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
	iterable := s.iterable
	if foreach_is_place_loop(s) { iterable = mutable_foreach_root(graph.k.c, s) }
	iterated := walk_flow_expr(graph, iterable)
	// The traversal also borrows container storage, but copying an element
	// preserves its existing borrows without borrowing the container itself.
	elements := iterated
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
		walk_foreach_binding_provenance(graph, s, s.bindings, iterated, elements)
	}
	// design.md "By-reference iteration": the loan a `&` binding names ends when
	// the step does, whatever lowering produced the element -- a pointer taken
	// from it may not outlive the iteration that yielded it.
	walk_flow_loop_body(graph, s.body, head, done, s.bindings, foreach_is_place_loop(s))
	link(graph, graph.current, head)
	graph.current = done
}

@(private = "file")
walk_foreach_binding_provenance :: proc(
	graph: ^Flow_Graph, s: ^Stmt_Foreach, bindings: []Foreach_Binding, iterated, elements: []int,
) {
	for binding in bindings {
		if len(binding.group) > 0 {
			walk_foreach_binding_provenance(graph, s, binding.group, iterated, elements)
			continue
		}
		loans := iterated
		if !binding.is_ref && s.kind != .Protocol && len(elements) > 0 { loans = elements }
		prov_bind_value(graph, binding.symbol, loans, expr_span(s.iterable))
		if s.borrows { prov_bind_view(graph, binding.symbol, iterated) }
	}
}

@(private = "file")
walk_flow_loop_body :: proc(
	graph: ^Flow_Graph, body: ^Block, head, done: Block_Id,
	bindings: []Foreach_Binding = nil, all_step_borrows := false,
) {
	outer_break, outer_continue := graph.break_block, graph.continue_block
	outer_break_depth, outer_continue_depth := graph.break_depth, graph.continue_depth
	graph.break_block, graph.continue_block = done, head
	graph.break_depth, graph.continue_depth = len(graph.in_scope), len(graph.in_scope)
	graph.loop_depth += 1
	enter_flow_scope(graph)
	if graph.mode != .Lifecycle {
		add_foreach_ref_cleanups(graph, bindings, all_step_borrows)
	}
	walk_flow_block(graph, body)
	leave_flow_scope(graph)
	graph.loop_depth -= 1
	graph.break_block, graph.continue_block = outer_break, outer_continue
	graph.break_depth, graph.continue_depth = outer_break_depth, outer_continue_depth
}

@(private = "file")
add_foreach_ref_cleanups :: proc(graph: ^Flow_Graph, bindings: []Foreach_Binding, all: bool) {
	for binding in bindings {
		if len(binding.group) > 0 {
			add_foreach_ref_cleanups(graph, binding.group, all)
		} else if (all || binding.is_ref) && binding.symbol != INVALID_SYMBOL {
			root := prov_root_for_symbol(graph, binding.symbol)
			append(&graph.in_scope, Flow_Cleanup{kind = .Prov_Root, root = root, span = binding.name.span})
		}
	}
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
	consumes := s.kind != .Value && s.subject != nil &&
		expr_base(s.subject).type != TYPE_ANY_VIEW &&
		!expression_is_borrowed_place(graph.k.c, s.subject)
	entry := graph.current
	merge := new_flow_block(graph)
	// A switch that is not exhaustive can fall past every case, so the entry
	// reaches the merge directly.
	for c in s.cases {
		graph.current = new_flow_block(graph)
		link(graph, entry, graph.current)
		enter_flow_scope(graph)
		// A type switch binds one name per case to the subject's value, so what
		// the union alternative holds is what the binding holds.
		if graph.mode != .Lifecycle {
			prov_bind_value(graph, c.binding_symbol, prov_case_payload(graph, s, c, subject), c.span)
			prov_bind_case_region(graph, c.binding_symbol, s.subject)
			// A place subject keeps owning its payload, so the binding views the
			// subject's storage and a pointer taken from it borrows the subject.
			if !consumes {
				prov_bind_view(graph, c.binding_symbol, prov_subject_view(graph, s.subject))
			}
		} else {
			track_case_binding(graph, c, consumes)
		}
		walk_flow_stmts(graph, c.stmts)
		leave_flow_scope(graph)
		link(graph, graph.current, merge)
	}
	if !s.exhaustive {
		link(graph, entry, merge)
	}
	graph.current = merge
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
@(private)
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
			// Either payload may be the one copied out of a place, so the report
			// names the fallible union rather than guessing a path.
			if graph.mode == .Lifecycle && v.borrows {
				report_copy_cost(
					graph.k, .Or_Return, expr_span(v.operand), v.operand,
					expr_base(v.operand).type, graph.loop_depth > 0,
				)
			}
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
		// design.md "Operator ownership": a place operand leaves the source live
		// and copies the success payload out of it, so the same refactor that
		// names a temporary turns a transfer into a clone. Only the payload is
		// reported — `or_else` leaves a place's failure alone. The `Prov_` modes
		// rebuild this topology read-only and must not repeat the warning.
		if graph.mode == .Lifecycle && v.borrows {
			report_copy_cost(graph.k, .Or_Else, expr_span(v.value), v.value, v.type, graph.loop_depth > 0)
		}
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
	#partial switch operation in v.operation {
	case Call_Enum_From_Int:
		walk_flow_expr(graph, v.bound[0])
		return nil // integer input and enum payload carry no borrows
	case Call_Extract:
		// The same extraction node as the postfix spelling.
		return walk_flow_expr(graph, operation.node)
	case Call_Union_Construct:
		loans: []int
		if len(v.bound) == 1 { loans = walk_flow_expr(graph, v.bound[0]) }
		if graph.mode == .Lifecycle { return nil }
		return prov_variant_content(graph, v, loans)
	}
	// design.md "Variable declarations": an unevaluated operand inspects a
	// declaration or a static type. It reads no storage, creates no borrow, and
	// does not require a named local to be live, so neither pass walks into it.
	if sym := symbol_of(graph.k.c, v.resolution.symbol); sym != nil && sym.kind == .Builtin {
		#partial switch sym.builtin {
		case .Size_Of, .Align_Of, .Offset_Of, .Type_Of, .Source_Location:
			return nil
		}
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
		case .Unsafe_Take, .Unsafe_Write:
			// Neither names a variable (the checker refuses one), so the operands are
			// ordinary reads of whatever aggregate holds the place.
			for bound in v.bound {
				walk_flow_expr(graph, bound)
			}
			return nil
		case .Drop, .Free:
			// `drop` consumes the binding. `free` ends an allocation root rather
			// than a value, and provenance (`src/borrow.odin`) already reports a
			// second release and a surviving alias in the allocation's own terms,
			// so here it is only a use: the pointer must hold a value to release.
			if len(v.bound) == 1 {
				if ident, is_ident := v.bound[0].(^Expr_Ident); is_ident {
					if slot, tracked := slot_of(graph, ident.symbol); tracked {
						emit(graph, Flow_Event {
							kind = sym.builtin == .Free ? .Use : .Kill,
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
	// Arguments in evaluation order, so a use after an earlier-evaluated move is seen.
	for step in 0 ..< len(v.bound) {
		index := call_slot_at(v, step)
		if v.is_variadic && index == v.variadic_slot && !v.variadic_forwards {
			walk_variadic_pack(graph, v)
		} else if v.bound[index] != nil {
			walk_flow_expr(graph, v.bound[index])
		}
	}
	if len(v.bound) == 0 {
		for argument in v.args {
			walk_flow_expr(graph, argument.value)
		}
	}
	note_reset_point(graph, v)
	return nil
}

// Every operand of an unforwarded variadic pack, in written order. The pack is
// compiler-owned stack storage, so its loans are the union of its operands'.
@(private)
walk_variadic_pack :: proc(graph: ^Flow_Graph, v: ^Expr_Call) -> []int {
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

// Whether this call resets an allocator region: `free_all`, or a call handing an
// argument to an `@(allocator_reset)` parameter. One predicate, so the liveness
// pass and the provenance pass cannot disagree about which calls are resets.
call_is_reset :: proc(c: ^Compiler, v: ^Expr_Call) -> bool {
	if sym := symbol_of(c, v.resolution.symbol); sym != nil && sym.builtin == .Free_All {
		return true
	}
	proc_type := call_proc_type(c, v)
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

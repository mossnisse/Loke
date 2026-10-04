// A disposable per-procedure control-flow view over the annotated AST, rebuilt
// per concrete body instance. A local goes live at a completed initialization,
// dies at `move`/`drop`, and must be live at a use; a managed one is also
// cleaned up, innermost first, wherever control leaves its scope. Provenance
// events are built in cfg_provenance.odin.
package lokec

import "core:fmt"
import "core:mem"
import "core:mem/virtual"
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
	// dead (design.md: a dropped owner no longer blocks a reset).
	Reset_Point,
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
}

// A point where a region may end, named alike by the lifecycle walk, which
// records who is dead there, and the provenance walk, which reads it. `node` is
// the resetting call, the `drop`, `move`, `exchange`, or assignment, or the
// jump whose cleanups end `symbol`'s region; nil where its scope ends. A
// deferred statement is walked once per exit, so `expansion` names the walk.
Reset_Key :: struct {
	body:      ^Expr_Proc,
	node:      rawptr,
	symbol:    Symbol_Id,
	expansion: Defer_Expansion,
}

// One walk of a `defer` body: the deferred statement and the exit running it,
// nil at its scope's end.
Defer_Expansion :: struct {
	deferred: ^Stmt_Defer,
	exit:     rawptr,
}

// The owners dead at one reset point. Lifecycle registers every point it walks
// and solves the reachable ones, so the provenance walk tells an unreachable
// point from one the two walks keyed differently, which is a compiler bug.
Reset_Liveness :: struct {
	dead:    []Symbol_Id,
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

	// Provenance modes, solved by `src/borrow.odin`. Reaching loans are packed
	// one `ceil(2*loans/8)`-byte row per slot: which loans the slot may hold,
	// then which of those it may hold after their release.
	prov:            [dynamic]Prov_Event,
	reach_entry:     []u8,
	reach_exit:      []u8,
	precision_entry: []Precision_Loss,
	precision_exit:  []Precision_Loss,
	ended_entry:     []bool,
	ended_exit:      []bool,
	live_entry:      []bool,
	live_exit:       []bool,
	use_entry:       []Span,
	use_exit:        []Span,
	prov_visited:    bool,
}

Flow_Cleanup_Kind :: enum {
	Local,
	Defer,
	// A provenance root whose storage ends with its scope.
	Prov_Root,
}

// Where an open scope's cleanups and region-backed owners start. Only
// `leave_flow_scope` pops them, so an abrupt exit can run a scope's cleanups
// without ending it.
Flow_Scope :: struct {
	cleanups: int,
	owners:   int,
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
	seen_cleanup:       bool,
	live_exit:          bool,
	dead_exit:          bool,
	conditional_assign: bool,
}

Flow_Graph :: struct {
	blocks:    [dynamic]^Flow_Block,
	tracked:   [dynamic]Tracked_Local,
	by_symbol: map[Symbol_Id]int,
	alloc:     mem.Allocator,
	mode:      Flow_Mode,

	// Nil in lifecycle mode, so a lifecycle walk cannot read what only the
	// provenance walks build.
	using prov: ^Prov_State,
	// Walk state both modes keep.
	// Temporaries ending with the current statement (design.md).
	temp_roots:     [dynamic]Root_Id,
	// The `move`s and `exchange`s whose value becomes a new local or a result,
	// which takes the provider's region with it rather than ending it.
	aliased_moves:    map[rawptr]bool,
	owners_in_scope: [dynamic]Symbol_Id,

	k:       ^Checker,
	literal: ^Expr_Proc,
	current: Block_Id,
	// The cleanups of every open scope, in registration order; `scopes` marks
	// where each scope starts.
	in_scope:       [dynamic]Flow_Cleanup,
	scopes:         [dynamic]Flow_Scope,
	// The `defer` body being walked, if any.
	expansion:      Defer_Expansion,
	loop_depth:     int,
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

// A clone of a local, and the `Use` event that reads it. Whether it clones at
// all is decided after the walk, by the statement's own flags.
Last_Use :: struct {
	block:  Block_Id,
	event:  int,
	decl:   ^Decl,
	assign: ^Stmt_Assign,
	index:  int,
}

// The state only the provenance modes build.
Prov_State :: struct {
	roots:          [dynamic]Prov_Root,
	loans:          [dynamic]Prov_Loan,
	prov_slots:     [dynamic]Prov_Slot,
	reborrows:      [dynamic]Prov_Reborrow,
	entry_defs:     [dynamic]Prov_Entry_Def,
	root_by_symbol: map[Symbol_Id]Root_Id,
	slot_by_symbol: map[Symbol_Id]int,
	// What a non-owning binding (a loop element, a switch payload over a place)
	// views: every access and borrow through it also uses the source.
	view_loans:     map[Symbol_Id][]int,
	// The view bindings whose own loans end with their step (design.md
	// "By-reference iteration"), so `&binding` borrows the binding too.
	step_views:     map[Symbol_Id]bool,
	// One slot per `carrier_shape` path of a local that holds carriers.
	content_by_symbol: map[Symbol_Id][]int,
	// The keyed map-shape entry each constant key uses, first written first.
	map_key_entries: map[string]int,
	call_results:   map[^Expr_Call]Prov_Call_Result,
	// The call each user operator stands for, keyed by its node.
	operator_calls: map[rawptr]^Expr_Call,
	// Summary mode: the direct callees whose result summaries this body reads.
	summary_callees: [dynamic]Symbol_Id,
	// Calls through a procedure type with no result contract, for notes.
	plain_calls: [dynamic]^Expr_Call,
	// design.md "Global write effects": this body's own writes of globals, and
	// its calls while the effects are still settling.
	effect_writes: [dynamic]Symbol_Id,
	effect_calls:  [dynamic]Effect_Call,
	// Procedures this body uses as values, and the callee being walked, which is
	// a call rather than a use.
	effect_values: [dynamic]Symbol_Id,
	// `thread.spawn` calls, kept on the graph so a repeated pass notes each once.
	thread_spawns: [dynamic]Thread_Spawn,
	callee_expr:   Expr,
	// design.md "Allocator regions and region provenance".
	region_of:       map[Symbol_Id]Region_Set,
	region_content:  map[Symbol_Id][]Prov_Region_Content,
	// The parent allocator a provider depends on until it is dropped.
	provider_parents: map[Symbol_Id]Region_Set,
	param_count:     int,
	// One bit per local `mem.Arena`/`mem.Scratch`.
	provider_bits:    map[Symbol_Id]u64,
	provider_symbols: [dynamic]Symbol_Id,
	// Per local, one token per provider position its type fixes, and the tokens
	// of providers moved in, which may sit at any position.
	provider_paths: map[Symbol_Id][]Provider_Path,
	provider_moved: map[Symbol_Id]u64,
	// Locals a mutable loan was ever taken of: only these can be reached through
	// a pointer or slice. Flow-insensitive, like the region facts.
	lent_locals: map[Symbol_Id]bool,
	has_region_event: bool,
	// The uses that are a local's `drop` at scope exit, for the note naming them.
	scope_drops:      map[Span]bool,
	has_content_load: bool,
}

NO_BLOCK :: Block_Id(-1)

// Built in the analysis arena, which the caller frees. Lifecycle mode returns
// nil for a body with nothing to track; a provenance mode always builds one.
build_flow_graph :: proc(k: ^Checker, literal: ^Expr_Proc, mode := Flow_Mode.Lifecycle) -> ^Flow_Graph {
	allocator := k.c.analysis_allocator
	if mode == .Lifecycle || literal == nil || literal.body == nil {
		return build_flow_pass(k, literal, allocator, mode, nil)
	}
	// design.md "Allocator regions and region provenance": region facts are
	// flow-insensitive, but a pass reads them while it walks, so a fact written
	// later in a loop body reaches an earlier read only on the next pass. Facts
	// only grow, so the passes stop. A pass that added facts is reclaimed once
	// they are copied out, so scratch holds one graph, not one per pass.
	carry_arena: virtual.Arena
	defer virtual.arena_destroy(&carry_arena)
	carry: ^Flow_Graph
	seeded := 0
	for {
		temp := virtual.arena_temp_begin(&k.c.analysis_arena)
		graph := build_flow_pass(k, literal, allocator, mode, carry)
		weight := prov_region_weight(graph)
		if weight == seeded {
			virtual.arena_temp_ignore(temp)
			return graph
		}
		free_all(virtual.arena_allocator(&carry_arena))
		carry = prov_carry_regions(graph, virtual.arena_allocator(&carry_arena))
		virtual.arena_temp_end(temp)
		seeded = weight
	}
}

@(private = "file")
build_flow_pass :: proc(
	k: ^Checker,
	literal: ^Expr_Proc,
	allocator: mem.Allocator,
	mode: Flow_Mode,
	seed: ^Flow_Graph,
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
	graph.held = make([dynamic]int, allocator)
	graph.lent = make(map[int]bool, 4, allocator)
	graph.last_uses = make([dynamic]Last_Use, allocator)
	graph.owners_in_scope = make([dynamic]Symbol_Id, allocator)
	graph.temp_roots = make([dynamic]Root_Id, allocator)
	graph.aliased_moves = make(map[rawptr]bool, 4, allocator)
	if mode != .Lifecycle {
		graph.prov = new(Prov_State, allocator)
		graph.roots = make([dynamic]Prov_Root, allocator)
		graph.loans = make([dynamic]Prov_Loan, allocator)
		graph.prov_slots = make([dynamic]Prov_Slot, allocator)
		graph.entry_defs = make([dynamic]Prov_Entry_Def, allocator)
		graph.root_by_symbol = make(map[Symbol_Id]Root_Id, 8, allocator)
		graph.slot_by_symbol = make(map[Symbol_Id]int, 8, allocator)
		graph.view_loans = make(map[Symbol_Id][]int, 8, allocator)
		graph.step_views = make(map[Symbol_Id]bool, 8, allocator)
		graph.content_by_symbol = make(map[Symbol_Id][]int, 8, allocator)
		graph.call_results = make(map[^Expr_Call]Prov_Call_Result, 8, allocator)
		graph.operator_calls = make(map[rawptr]^Expr_Call, 4, allocator)
		graph.summary_callees = make([dynamic]Symbol_Id, allocator)
		graph.plain_calls = make([dynamic]^Expr_Call, allocator)
		graph.effect_writes = make([dynamic]Symbol_Id, allocator)
		graph.effect_calls = make([dynamic]Effect_Call, allocator)
		graph.effect_values = make([dynamic]Symbol_Id, allocator)
		graph.thread_spawns = make([dynamic]Thread_Spawn, allocator)
		graph.region_of = make(map[Symbol_Id]Region_Set, 8, allocator)
		graph.region_content = make(map[Symbol_Id][]Prov_Region_Content, 8, allocator)
		graph.provider_parents = make(map[Symbol_Id]Region_Set, 4, allocator)
		graph.provider_bits = make(map[Symbol_Id]u64, 4, allocator)
		graph.map_key_entries = make(map[string]int, 4, allocator)
		graph.reborrows = make([dynamic]Prov_Reborrow, allocator)
		graph.provider_symbols = make([dynamic]Symbol_Id, allocator)
		graph.provider_paths = make(map[Symbol_Id][]Provider_Path, 4, allocator)
		graph.provider_moved = make(map[Symbol_Id]u64, 4, allocator)
		graph.lent_locals = make(map[Symbol_Id]bool, 4, allocator)
	}
	graph.break_block, graph.continue_block = NO_BLOCK, NO_BLOCK
	graph.current = new_flow_block(graph)

	// Parameters live in a scope outside the body's, so a `move` parameter's
	// cleanup is the outermost.
	enter_flow_scope(graph)
	if mode == .Lifecycle {
		track_move_parameters(graph, literal)
	} else {
		prov_bind_parameters(graph, literal)
		if seed != nil {
			prov_seed_regions(graph, seed)
		}
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

// An argument, stored when the call has somewhere to keep it: an `inout`
// argument or receiver, such as the container of an `append`.
@(private = "file")
walk_flow_argument :: proc(graph: ^Flow_Graph, argument: Expr, stores: bool) -> []int {
	if stores && graph.mode == .Lifecycle {
		walk_flow_stored(graph, argument)
		return nil
	}
	return walk_flow_expr(graph, argument)
}

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
	append(&graph.last_uses, Last_Use{graph.current, len(events) - 1, decl, assign, index})
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
		// Every `move` parameter is followed, since `move` and `drop` kill it;
		// only a managed one is cleaned up (design.md "Variable declarations").
		for id in parameter.symbols {
			sym := symbol_of(graph.k.c, id)
			if sym == nil {
				continue
			}
			append(&graph.tracked, Tracked_Local{symbol = id, live_on_entry = true, ever_written = true})
			graph.by_symbol[id] = len(graph.tracked) - 1
			if type_is_managed(graph.k.c, sym.type) {
				append(&graph.in_scope, Flow_Cleanup{kind = .Local, slot = len(graph.tracked) - 1})
			}
		}
	}
}

// The locals a panic's unwind drops where a path ends in a diverging call. The
// unwind replays registered `defer` statements by their runtime registration,
// so they are not walked here.
@(private = "file")
emit_unwind_cleanups :: proc(graph: ^Flow_Graph) {
	if graph.mode != .Lifecycle {
		return
	}
	for index := len(graph.in_scope) - 1; index >= 0; index -= 1 {
		action := graph.in_scope[index]
		if action.kind != .Local {
			continue
		}
		sym := symbol_of(graph.k.c, graph.tracked[action.slot].symbol)
		emit(graph, Flow_Event {
			kind = .Cleanup,
			slot = action.slot,
			span = sym == nil ? no_span() : sym.span,
			name = sym == nil ? "" : identifier_text(graph.k.c, sym.name),
		})
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
	emit_cleanups(graph, scope.cleanups, nil)
	resize(&graph.in_scope, scope.cleanups)
	resize(&graph.owners_in_scope, scope.owners)
}

@(private = "file")
walk_flow_stmts :: proc(graph: ^Flow_Graph, stmts: []Stmt) {
	for stmt in stmts {
		walk_flow_stmt(graph, stmt)
	}
}

// Cleanup events for every registration above `down_to`, innermost first
// (design.md). `exit` is the jump that runs them, nil at a scope's end.
@(private = "file")
emit_cleanups :: proc(graph: ^Flow_Graph, down_to: int, exit: rawptr) {
	for index := len(graph.in_scope) - 1; index >= down_to; index -= 1 {
		action := graph.in_scope[index]
		switch action.kind {
		case .Defer:
			// Walked where it runs, with itself and the later registrations
			// popped, as at runtime; that also stops a diagnosed `return` inside it
			// from expanding itself again. The walk reuses the backing storage, so
			// the entries are saved, not the header.
			tail := slice.clone(graph.in_scope[index:], graph.alloc)
			owners := len(graph.owners_in_scope)
			outer := graph.expansion
			graph.expansion = {action.deferred, exit}
			resize(&graph.in_scope, index)
			walk_flow_stmt(graph, action.deferred.stmt)
			graph.expansion = outer
			resize(&graph.in_scope, index)
			append(&graph.in_scope, ..tail)
			resize(&graph.owners_in_scope, owners)
		case .Prov_Root:
			provider_region_end(graph, graph.roots[int(action.root)].symbol, action.span, exit)
			prov_scope_drop_effects(graph, graph.roots[int(action.root)].symbol, action.span)
			prov_drop_use(graph, graph.roots[int(action.root)].symbol, action.span, at_scope_exit = true)
			prov_emit(graph, Prov_Event{kind = .Root_End, root = action.root, span = action.span})
		case .Local:
			id := graph.tracked[action.slot].symbol
			sym := symbol_of(graph.k.c, id)
			span := sym == nil ? no_span() : sym.span
			provider_region_end(graph, id, span, exit)
			if graph.mode != .Lifecycle {
				prov_scope_drop_effects(graph, id, span)
				prov_drop_use(graph, id, span, at_scope_exit = true)
			}
			emit(graph, Flow_Event {
				kind = .Cleanup,
				slot = action.slot,
				span = span,
				name = sym == nil ? "" : identifier_text(graph.k.c, sym.name),
			})
		}
	}
}

// A local holding a provider ends its region when it is cleaned up, dropped,
// moved anywhere but a new local or a result, or assigned over; every owner the
// region backs must be dead by then (design.md "Allocators"). `node` is the
// written end, or for a cleanup, the jump running it or nil; `ends` names a
// written end for the diagnostic.
@(private)
provider_region_end :: proc(graph: ^Flow_Graph, id: Symbol_Id, span: Span, node: rawptr, ends := "", path: []Proj_Step = nil) {
	sym := symbol_of(graph.k.c, id)
	if sym == nil || sym.kind != .Var || sym.duration != .None || !type_carries_provider(graph.k.c, sym.type) {
		return
	}
	// A view such as a `&` loop element owns nothing, so it ends no region.
	if sym.borrowed_binding != .None {
		return
	}
	key := Reset_Key{graph.literal, node, id, graph.expansion}
	if graph.mode == .Lifecycle {
		graph.k.c.cleanup_reset_dead[key] = {}
		emit(graph, Flow_Event{kind = .Reset_Point, reset = key, span = span})
		return
	}
	live, found := graph.k.c.cleanup_reset_dead[key]
	assert(found, "the provenance walk reached a provider end the lifecycle walk did not")
	// An unreachable exit ends nothing, and a consumed value has no region left.
	if !live.reached || slice.contains(live.dead, id) {
		return
	}
	prov_provider_use(graph, id, span)
	// A parameter's region is the caller's, and its owners are the caller's too.
	if root, rooted := graph.root_by_symbol[id]; !rooted || graph.roots[int(root)].kind != .Local {
		return
	}
	region := path == nil ? prov_provider_region(graph, id) : prov_provider_region_at(graph, id, path)
	prov_reset(graph, region, span, true, nil, live.dead, ends, id, provider_end = true)
}

// A `move` out of a local ends what it holds, unless the move is into a new
// local or a result, which carries the region along.
@(private)
provider_move_end :: proc(graph: ^Flow_Graph, v: ^Expr_Move) {
	if graph.aliased_moves[v] {
		return
	}
	if ident, is_ident := v.value.(^Expr_Ident); is_ident {
		provider_region_end(graph, ident.symbol, v.span, v, provider_end_phrase(graph, "moving", ident.name))
	}
}

@(private)
provider_drop_end :: proc(graph: ^Flow_Graph, v: ^Expr_Call) {
	if ident, is_ident := v.bound[0].(^Expr_Ident); is_ident {
		provider_region_end(graph, ident.symbol, v.span, v, provider_end_phrase(graph, "dropping", ident.name))
	}
}

// `exchange` hands back the old value, which ends its region wherever it goes
// but a new local.
@(private)
provider_exchange_end :: proc(graph: ^Flow_Graph, v: ^Expr_Call) {
	if graph.aliased_moves[v] {
		return
	}
	provider_place_end(graph, v.bound[0], v, v.span, "exchanging")
}

// Assignment drops the destination's previous value (design.md).
@(private)
provider_assign_end :: proc(graph: ^Flow_Graph, target: ^Expr_Ident) {
	provider_region_end(
		graph, target.symbol, target.span, target, provider_end_phrase(graph, "assigning over", target.name),
	)
}

// The local whose own storage a place is in, when that local holds providers by
// value; INVALID_SYMBOL for anything reached through a pointer or slice.
@(private)
provider_place_root :: proc(graph: ^Flow_Graph, place: Expr) -> Symbol_Id {
	if !place_is_direct(graph.k.c, place) {
		return INVALID_SYMBOL
	}
	root := place_root_symbol(place)
	sym := symbol_of(graph.k.c, root)
	if sym == nil || sym.kind != .Var || sym.duration != .None || !type_carries_provider(graph.k.c, sym.type) {
		return INVALID_SYMBOL
	}
	return root
}

// Whether a place is in its root variable's own storage: a field or element
// path that never follows a pointer or a slice.
@(private = "file")
place_is_direct :: proc(c: ^Compiler, place: Expr) -> bool {
	#partial switch v in place {
	case ^Expr_Ident:
		return true
	case ^Expr_Selector:
		return v.operand != nil && !type_is_pointer(c, expr_base(v.operand).type) && place_is_direct(c, v.operand)
	case ^Expr_Postfix:
		// A box's payload is part of the box (design.md "Owned values").
		return v.boxed && place_is_direct(c, v.operand)
	case ^Expr_Index:
		#partial switch underlying_kind(c, expr_base(v.operand).type) {
		case .Array, .Dynamic_Array, .Map:
			return len(v.bound) == 0 && place_is_direct(c, v.operand)
		}
	}
	return false
}

// Replacing or removing the providers at a place ends their regions: in a
// local's own storage, that local's; through a pointer or slice, any local's.
// Static storage is not followed.
@(private)
provider_place_end :: proc(graph: ^Flow_Graph, place: Expr, node: rawptr, span: Span, verb: string, preposition := "") {
	if !type_carries_provider(graph.k.c, expr_base(place).type) {
		return
	}
	if root := provider_place_root(graph, place); root != INVALID_SYMBOL {
		name := identifier_text(graph.k.c, symbol_of(graph.k.c, root).name)
		direct := preposition == "" ? verb : fmt.aprintf("%s %s", verb, preposition, allocator = graph.alloc)
		// Only the providers at or under this place end.
		path: []Proj_Step
		if graph.mode != .Lifecycle {
			if _, place_path, ok := prov_place_of(graph, place); ok {
				path = place_path
			}
		}
		provider_region_end(graph, root, span, node, provider_end_phrase(graph, direct, name), path)
		return
	}
	if !place_is_direct(graph.k.c, place) {
		provider_indirect_end(graph, node, span, verb)
	}
}

// A place behind a pointer or slice may be in any local holding providers that
// was ever lent mutably, so the regions of all of those in scope end here.
@(private = "file")
provider_indirect_end :: proc(graph: ^Flow_Graph, node: rawptr, span: Span, verb: string) {
	key := Reset_Key{graph.literal, node, INVALID_SYMBOL, graph.expansion}
	if graph.mode == .Lifecycle {
		graph.k.c.cleanup_reset_dead[key] = {}
		emit(graph, Flow_Event{kind = .Reset_Point, reset = key, span = span})
		return
	}
	live, found := graph.k.c.cleanup_reset_dead[key]
	assert(found, "the provenance walk reached a provider end the lifecycle walk did not")
	if !live.reached {
		return
	}
	set := prov_empty_region(graph)
	for id in graph.owners_in_scope {
		sym := symbol_of(graph.k.c, id)
		if sym == nil || !type_carries_provider(graph.k.c, sym.type) || !graph.lent_locals[id] {
			continue
		}
		if root, rooted := graph.root_by_symbol[id]; rooted && graph.roots[int(root)].kind == .Local {
			region_merge(&set, prov_provider_region(graph, id))
		}
	}
	if region_is_empty(set) {
		return
	}
	ends := fmt.aprintf("%s through a pointer or slice", verb, allocator = graph.alloc)
	prov_reset(graph, set, span, true, nil, live.dead, ends, provider_end = true)
}

// Assigning into a provider inside a local drops the provider there before.
@(private)
provider_field_assign_end :: proc(graph: ^Flow_Graph, target: Expr) {
	if _, is_ident := target.(^Expr_Ident); !is_ident {
		provider_place_end(graph, target, expr_base(target), expr_span(target), "assigning", "into")
	}
}

// Container operations on a local that store a moved provider, and those that
// may drop one.
STORING_CONTAINER_OPS :: bit_set[Container_Op]{.Append, .Insert, .Map_Try_Insert}
DROPPING_CONTAINER_OPS :: bit_set[Container_Op]{
	.Pop, .Remove, .Remove_Unordered, .Clear, .Resize, .Map_Remove, .Map_Clear,
}

// A provider appended or inserted into a local container is stored there, so it
// carries its region along.
@(private)
provider_container_moves :: proc(graph: ^Flow_Graph, v: ^Expr_Call) {
	sym := symbol_of(graph.k.c, v.resolution.chosen_overload)
	if sym == nil || sym.synth != .Container_Op || len(v.bound) == 0 ||
	   sym.container_op not_in STORING_CONTAINER_OPS ||
	   provider_place_root(graph, v.bound[0]) == INVALID_SYMBOL {
		return
	}
	for argument in v.bound[1:] {
		if argument != nil {
			mark_aliased_moves(graph, argument)
		}
	}
	for argument in v.variadic_elements {
		mark_aliased_moves(graph, argument)
	}
}

@(private)
provider_container_end :: proc(graph: ^Flow_Graph, v: ^Expr_Call) {
	sym := symbol_of(graph.k.c, v.resolution.chosen_overload)
	if sym == nil || sym.synth != .Container_Op || len(v.bound) == 0 {
		return
	}
	if sym.container_op in DROPPING_CONTAINER_OPS {
		provider_place_end(graph, v.bound[0], v, v.span, "removing", "from")
		return
	}
	root := provider_place_root(graph, v.bound[0])
	if root != INVALID_SYMBOL && sym.container_op in STORING_CONTAINER_OPS && graph.mode != .Lifecycle {
		for argument in v.bound[1:] {
			if argument != nil {
				prov_merge_moved_bits(graph, root, argument)
			}
		}
		for argument in v.variadic_elements {
			prov_merge_moved_bits(graph, root, argument)
		}
	}
}

@(private = "file")
provider_end_phrase :: proc(graph: ^Flow_Graph, verb, name: string) -> string {
	return graph.mode == .Lifecycle ? "" : fmt.aprintf("%s `%s`", verb, name, allocator = graph.alloc)
}

// The moves an initializer or a result takes whole, through composite literals.
@(private = "file")
mark_aliased_moves :: proc(graph: ^Flow_Graph, e: Expr) {
	#partial switch v in e {
	case ^Expr_Move:
		graph.aliased_moves[v] = true
	case ^Expr_Call:
		if sym := symbol_of(graph.k.c, v.resolution.symbol); sym != nil && sym.builtin == .Exchange {
			graph.aliased_moves[v] = true
		}
	case ^Expr_Composite:
		for element in v.elements {
			if element.value != nil {
				mark_aliased_moves(graph, element.value)
			}
		}
	}
}

// Temporaries end with their statement, but a header's initial statement
// `extend`s them to the whole enclosing statement (design.md).
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
	case ^Stmt_Error, ^Item_Impl:

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
		append(&graph.in_scope, Flow_Cleanup{kind = .Defer, deferred = s})

	case ^Stmt_Return:
		if s.value != nil && !s.value.is_inout {
			mark_aliased_moves(graph, s.value.expr)
		}
		if graph.mode != .Lifecycle {
			held: []int
			if value := s.value; value != nil {
				// design.md "`inout` results": `return inout place` hands back a
				// borrow of the place, which must outlive the frame.
				sources: []int
				if value.is_inout {
					sources = prov_borrow_place(graph, value.expr, true, expr_span(value.expr), "`inout` result")
				} else {
					sources = walk_flow_expr(graph, value.expr)
				}
				escaping := prov_escape_region(graph, value.expr)
				result_type := expr_base(value.expr).type
				if sym := symbol_of(graph.k.c, graph.literal.symbol); sym != nil {
					result_type = sym.result
				}
				contents := prov_load_deep(graph, sources, expr_span(value.expr))
				prov_emit(graph, Prov_Event {
					kind           = .Escape,
					sources        = sources,
					into           = contents,
					span           = expr_span(value.expr),
					region         = escaping,
					region_content = prov_result_region_fields(graph, value.expr, result_type),
					// The frame's regions end here, so the diagnostic names them.
					name           = prov_region_name(graph, escaping),
				})
				held = prov_hold_result(graph, prov_join(graph, sources, contents), result_type, expr_span(value.expr))
			}
			emit_cleanups(graph, 0, s)
			if len(held) > 0 {
				prov_emit(graph, Prov_Event{kind = .Live, sources = held, span = expr_span(s.value.expr)})
			}
			graph.current = NO_BLOCK
			return
		}
		if value := s.value; value != nil {
			// Returning an owned local moves it into the result (design.md).
			if value.clone_on_return {
				report_copy_cost(
					graph.k, .Return, expr_span(value.expr), value.expr,
					expr_base(value.expr).type, graph.loop_depth > 0,
				)
			}
			// Only a managed local transfers; a scalar is copied, so a deferred read
			// still sees it (design.md "defer statement").
			killed := false
			if ident, is_ident := value.expr.(^Expr_Ident); is_ident && !value.clone_on_return &&
			   type_is_managed(graph.k.c, expr_base(value.expr).type) {
				if slot, tracked := graph.by_symbol[ident.symbol]; tracked {
					emit(graph, Flow_Event{kind = .Kill, slot = slot, span = ident.span, name = ident.name})
					killed = true
				}
			}
			if !killed {
				walk_flow_expr(graph, value.expr)
			}
		}
		emit_cleanups(graph, 0, s)
		graph.current = NO_BLOCK

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
	// A destructured value is split between bindings, so its region cannot follow.
	if !d.destructure.active {
		for value in d.values {
			mark_aliased_moves(graph, value)
		}
	}
	for value, index in d.values {
		if graph.mode == .Lifecycle {
			walk_flow_bound_value(graph, value, d, nil, index)
			continue
		}
		result := walk_flow_expr(graph, value)
		if value_loans != nil {
			value_loans[index] = result
		}
	}
	for _, index in d.symbols {
		if declaration_evaluates_via(graph.k.c, d, index) {
			walk_flow_expr(graph, d.via)
		}
	}
	if graph.mode != .Lifecycle {
		prov_declare(graph, d, value_loans)
		return
	}
	classify_declaration_copies(graph.k, d, graph.loop_depth > 0)
	for id, symbol_index in d.symbols {
		sym := symbol_of(graph.k.c, id)
		// Static storage is never dropped automatically (design.md).
		if sym == nil || sym.kind != .Var || sym.duration != .None {
			continue
		}
		// Every local is followed for definite initialization; only a managed
		// one is cleaned up. A deferred declaration keeps one slot across its
		// expansions but registers a cleanup in each.
		slot, already_tracked := graph.by_symbol[id]
		if !already_tracked {
			append(&graph.tracked, Tracked_Local{symbol = id})
			slot = len(graph.tracked) - 1
			graph.by_symbol[id] = slot
		}
		if type_is_managed(graph.k.c, sym.type) {
			append(&graph.in_scope, Flow_Cleanup{kind = .Local, slot = slot})
		}
		// Without an initializer, or with `---`, the local starts dead.
		initializer, written := declared_initializer(d, symbol_index)
		if written && initializer == nil {
			graph.tracked[slot].unchecked = true
		}
		if initializer == nil {
			continue
		}
		emit(graph, Flow_Event {
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
	if sym == nil || !sym.named || graph.current == NO_BLOCK || !is_call || call.type == INVALID_TYPE {
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
	if graph.mode != .Lifecycle && len(s.rhs) > 0 {
		value_loans = make([][]int, len(s.rhs), graph.alloc)
	}
	for value, index in s.rhs {
		if graph.mode == .Lifecycle {
			walk_flow_bound_value(graph, value, nil, s, index)
		} else if result := walk_flow_expr(graph, value); value_loans != nil {
			value_loans[index] = result
		}
		// A clone allocates through the destination's `via`, evaluated here.
		if index < len(s.rhs_clones) && s.rhs_clones[index] && index < len(s.lhs) {
			walk_flow_expr(graph, symbol_via_allocator(graph.k.c, place_root_symbol(s.lhs[index])))
		}
	}
	if graph.mode != .Lifecycle {
		prov_assign(graph, s, value_loans)
		return
	}
	classify_assignment_copies(graph.k, s, graph.loop_depth > 0)
	// design.md "Evaluation order": every destination is prepared before any
	// write. A write through a field or element is a use of its root.
	revived := make([]bool, len(s.lhs), graph.alloc)
	for target, index in s.lhs {
		if ident, is_ident := target.(^Expr_Ident); is_ident && s.op == .Assign {
			if _, tracked := graph.by_symbol[ident.symbol]; tracked {
				revived[index] = true
				continue
			}
		}
		if ident, is_ident := target.(^Expr_Ident); is_ident && s.op == .Assign {
			provider_assign_end(graph, ident)
		}
		if s.op == .Assign {
			provider_field_assign_end(graph, target)
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
		emit(graph, Flow_Event {
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

// A header declaration is scoped to the whole statement (design.md), as in
// `emit_if`/`emit_for`/`emit_switch`. The caller closes it with
// `defer leave_flow_scope(graph)`.
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
		iterated = prov_read_ident(graph, ident, .Read, reads_only = true) // traversed by value
	} else {
		iterated = walk_flow_expr(graph, iterable)
	}
	if graph.mode != .Lifecycle {
		iterated = prov_reborrow_traversal(graph, iterated, expr_span(s.iterable), place_loop)
	}
	// A copied element keeps its own borrows without borrowing the container.
	elements := iterated
	if graph.mode != .Lifecycle {
		iterated = prov_iterate(graph, s, iterated)
	}
	head := new_flow_block(graph)
	link(graph, graph.current, head)
	done := new_flow_block(graph)
	link(graph, head, done)
	// The iteration reads its source every step, so the loan stays live through
	// the body (design.md).
	graph.current = head
	if len(iterated) > 0 {
		prov_emit(graph, Prov_Event{
			kind = .Live, sources = iterated, span = expr_span(s.iterable), revives = true,
		})
	}

	body := new_flow_block(graph)
	link(graph, head, body)
	graph.current = body
	if graph.mode != .Lifecycle {
		walk_foreach_binding_provenance(graph, s, s.bindings, iterated, elements)
	}
	// design.md "By-reference iteration": a `&` binding's loan ends with its
	// step, and a copied element is a local of its step.
	walk_flow_loop_body(graph, s.body, head, done, s.bindings, place_loop || !s.borrows)
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
		if !binding.is_ref && s.kind != .Protocol && len(elements) > 0 {
			loans = elements
		}
		prov_bind_value(graph, binding.symbol, loans, expr_span(s.iterable))
		prov_bind_element_region(graph, binding.symbol, s.iterable)
		// A lent or mutable element is the source's storage, not a copy.
		if sym := symbol_of(graph.k.c, binding.symbol); sym != nil && sym.borrowed_binding != .None {
			prov_bind_view(graph, binding.symbol, iterated, lends = !foreach_is_place_loop(s))
		}
	}
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
	graph.loop_depth += 1
	enter_flow_scope(graph)
	if graph.mode != .Lifecycle {
		add_foreach_ref_cleanups(graph, bindings, all_step_locals)
	} else {
		track_owned_foreach_leaves(graph, bindings)
	}
	walk_flow_block(graph, body)
	leave_flow_scope(graph)
	graph.loop_depth -= 1
	graph.break_block, graph.continue_block = outer_break, outer_continue
	graph.break_depth, graph.continue_depth = outer_break_depth, outer_continue_depth
}

// design.md "Element bindings": an owned leaf is a managed local of its step,
// so `move` and `drop` end it as they end any local.
@(private = "file")
track_owned_foreach_leaves :: proc(graph: ^Flow_Graph, bindings: []Foreach_Binding) {
	for binding in bindings {
		if len(binding.group) > 0 {
			track_owned_foreach_leaves(graph, binding.group)
			continue
		}
		sym := symbol_of(graph.k.c, binding.symbol)
		if sym == nil || sym.borrowed_binding != .None || !type_is_managed(graph.k.c, sym.type) {
			continue
		}
		slot, already := graph.by_symbol[binding.symbol]
		if !already {
			append(&graph.tracked, Tracked_Local{symbol = binding.symbol})
			slot = len(graph.tracked) - 1
			graph.by_symbol[binding.symbol] = slot
		}
		append(&graph.in_scope, Flow_Cleanup{kind = .Local, slot = slot})
		emit(graph, Flow_Event {
			kind = .Init,
			slot = slot,
			span = sym.span,
			name = identifier_text(graph.k.c, sym.name),
		})
	}
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
	// A switch over a temporary consumes it into the case binding; one over a
	// place borrows it, for the whole switch.
	consumes := s.kind != .Value && s.subject != nil &&
		expr_base(s.subject).type != TYPE_ANY_VIEW &&
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
		// design.md: value cases are tested in order, each testing all its
		// values, and the default runs only once every test has failed.
		fallback := s.exhaustive ? NO_BLOCK : merge
		for c, index in s.cases {
			if len(c.values) == 0 {
				fallback = bodies[index]
				continue
			}
			for value in c.values {
				walk_flow_expr(graph, value)
			}
			link(graph, graph.current, bodies[index])
			next := new_flow_block(graph)
			link(graph, graph.current, next)
			graph.current = next
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
	for c, index in s.cases {
		graph.current = bodies[index]
		enter_flow_scope(graph)
		if graph.mode != .Lifecycle {
			prov_bind_value(graph, c.binding_symbol, prov_case_payload(graph, s, c, subject), c.span)
			prov_bind_case_region(graph, c.binding_symbol, s.subject)
			// A place subject keeps its payload, so the binding views its storage;
			// a consumed one is the binding's own, which ends with its case
			// (design.md "Switch ownership").
			if !consumes {
				prov_bind_view(graph, c.binding_symbol, prov_subject_view(graph, s.subject))
			} else if c.binding_symbol != INVALID_SYMBOL {
				root := prov_root_for_symbol(graph, c.binding_symbol)
				append(&graph.in_scope, Flow_Cleanup{kind = .Prov_Root, root = root, span = c.span})
			}
		} else {
			track_case_binding(graph, c, consumes)
		}
		walk_flow_stmts(graph, c.stmts)
		leave_flow_scope(graph)
		link(graph, graph.current, merge)
	}
	graph.current = merge
}

// A consuming switch's binding is an ordinary managed local of its case.
@(private = "file")
track_case_binding :: proc(graph: ^Flow_Graph, entry: Switch_Case, consumes: bool) {
	if !consumes || entry.binding_symbol == INVALID_SYMBOL {
		return
	}
	sym := symbol_of(graph.k.c, entry.binding_symbol)
	if sym == nil || !type_is_managed(graph.k.c, sym.type) {
		return
	}
	slot, already := graph.by_symbol[entry.binding_symbol]
	if !already {
		append(&graph.tracked, Tracked_Local{symbol = entry.binding_symbol})
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

// Walks an expression (nil is a no-op) in evaluation order and returns the
// carrier slots holding the loans its value carries.
@(private)
walk_flow_expr :: proc(graph: ^Flow_Graph, e: Expr) -> []int {
	prov := graph.mode != .Lifecycle
	if prov {
		prov_note_proc_value(graph, e)
	}
	// design.md "any_view type": an erased view borrows the place it came from.
	if prov {
		if base := expr_base(e); base != nil && base.erased_from != INVALID_TYPE {
			return prov_erase(graph, e)
		}
		if base := expr_base(e); base != nil && base.view_from != INVALID_TYPE {
			return prov_owner_view(graph, e)
		}
	}
	switch v in e {
	case ^Expr_Ident:
		if !prov {
			if slot, tracked := graph.by_symbol[v.symbol]; tracked {
				emit(graph, Flow_Event{kind = .Use, slot = slot, span = v.span, name = v.name})
			}
			return nil
		}
		return prov_read_ident(graph, v, .Read)

	case ^Expr_Move:
		provider_move_end(graph, v)
		if prov {
			return prov_consume(graph, v.value, v.span, v.implicit ? LAST_USE_VERB : "moved")
		}
		// `Kill` alone: it already requires the source live.
		if ident, is_ident := v.value.(^Expr_Ident); is_ident {
			if slot, tracked := graph.by_symbol[ident.symbol]; tracked {
				emit(graph, Flow_Event{kind = .Kill, slot = slot, span = v.span, name = ident.name, verb = "moved"})
				return nil
			}
		}
		walk_flow_expr(graph, v.value)

	case ^Expr_Call:
		loans := walk_flow_call(graph, v)
		// design.md "Diverging procedures": once its operands are evaluated, a
		// diverging call ends the path, so nothing after it is reached. A panic's
		// unwind still drops each live local, so the end is their cleanup point.
		if call_diverges(graph.k.c, v) {
			emit_unwind_cleanups(graph)
			graph.current = NO_BLOCK
		}
		return loans

	case ^Expr_Binary:
		if prov && v.resolution.kind == .User_Operator {
			return prov_call(graph, prov_operator_call(graph, v))
		}
		walk_flow_expr(graph, v.lhs)
		if v.op == .And_And || v.op == .Or_Or {
			entry := graph.current
			merge := new_flow_block(graph)
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
		if prov && v.op == .Amp {
			return prov_address_of(graph, v)
		}
		if prov && v.resolution.kind == .User_Operator {
			return prov_call(graph, prov_operator_call(graph, v))
		}
		walk_flow_expr(graph, v.operand)

	case ^Expr_Postfix:
		// design.md "Owned values": reading `b^` reads the box, as reading `xs[i]`
		// reads a dynamic array.
		if prov && v.op == .Caret && type_is_box(graph.k.c, expr_base(v.operand).type) {
			if root, path, ok := prov_place_of(graph, v); ok {
				prov_walk_subscripts(graph, v)
				prov_access(graph, root, path, .Read, v.span)
				return prov_read_content(graph, root, path, v.type, v.span)
			}
			if carriers, path, ok := prov_read_through_carrier(graph, v); ok {
				return prov_load_content(graph, carriers, path, v.type, v.span)
			}
			loans := walk_flow_expr(graph, v.operand)
			return prov_project_content(graph, loans, expr_base(v.operand).type, {proj_wild()}, v.type, v.span)
		}
		operand_loans := walk_flow_expr(graph, v.operand)
		if prov && v.op == .Caret {
			return prov_load_content(graph, operand_loans, nil, v.type, v.span)
		}
		if v.op == .Or_Return {
			// Either payload may be copied out of a place, so the report names
			// the whole fallible union.
			if !prov && v.borrows {
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
			held: []int
			if prov && proc_symbol != nil && proc_symbol.result != INVALID_TYPE {
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
					contents := prov_load_deep(graph, escaping, v.span)
					prov_emit(graph, Prov_Event {
						kind = .Escape, sources = escaping, into = contents, span = v.span,
					})
					held = prov_hold_result(graph, prov_join(graph, escaping, contents), proc_symbol.result, v.span)
				}
			}
			emit_cleanups(graph, 0, v)
			if len(held) > 0 {
				prov_emit(graph, Prov_Event{kind = .Live, sources = held, span = v.span})
			}
			graph.current = resume
			// The success payload carries the operand's loans and regions.
			return prov_payload_content(
				graph, operand_loans, expr_base(v.operand).type, v.type, v.span,
			)
		}

	case ^Expr_Selector:
		if prov {
			if root, path, ok := prov_place_of(graph, v); ok {
				prov_walk_subscripts(graph, v)
				prov_access(graph, root, path, .Read, v.span)
				// The read yields the field's content, with no lasting borrow.
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
			if v.resolution.kind == .User_Operator {
				return prov_call(graph, prov_operator_call(graph, v))
			}
			if root, path, ok := prov_place_of(graph, v); ok {
				prov_walk_subscripts(graph, v)
				prov_access(graph, root, path, .Read, v.span)
				return prov_read_content(graph, root, path, v.type, v.span)
			}
			// An element of plain data read out of a slice local only reads the
			// carrier (design.md "Weakening and reborrows").
			if ident, plain := prov_plain_slice_local(graph, v.operand); plain && len(v.bound) == 0 &&
			   !prov_indices_may_write(v.indices) {
				carriers := prov_read_ident(graph, ident, .Read, reads_only = true)
				for index in v.indices {
					walk_flow_expr(graph, index)
				}
				return prov_load_content(graph, carriers, nil, v.type, v.span)
			}
			if carriers, path, ok := prov_read_through_carrier(graph, v); ok {
				return prov_load_content(graph, carriers, path, v.type, v.span)
			}
			loans := walk_flow_expr(graph, v.operand)
			for index in v.indices {
				loans = prov_join(graph, loans, walk_flow_expr(graph, index))
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
		walk_flow_expr(graph, v.lo)
		walk_flow_expr(graph, v.hi)

	case ^Expr_Composite:
		// A non-empty container literal evaluates its destination's `via` first.
		if len(v.elements) > 0 {
			walk_flow_expr(graph, v.via)
		}
		if prov {
			if content := prov_temp_content(graph, v.type); len(content) > 0 {
				content = prov_composite_content(graph, v, content)
				if v.backing != INVALID_TYPE {
					return prov_slice_literal(graph, v.span, carrier_is_mutable(graph.k.c, v.type), content)
				}
				return content
			}
		}
		is_map := underlying_kind(graph.k.c, v.type) == .Map
		for element in v.elements {
			if is_map {
				walk_flow_expr(graph, element.key)
			}
			walk_flow_expr(graph, element.value)
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
		// design.md "Operator ownership": a place operand's success payload is
		// copied out, and only that copy is reported.
		if !prov && v.borrows {
			report_copy_cost(graph.k, .Or_Else, expr_span(v.value), v.value, v.type, graph.loop_depth > 0)
		}
		entry := graph.current
		merge := new_flow_block(graph)
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
			// A union keeps its alternatives below a wildcard; an erased view
			// points at the value.
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

// A place copied into a trivial aggregate `value: T` parameter is a copy site; a
// managed one is borrowed for the call (design.md).
@(private = "file")
report_argument_copies :: proc(graph: ^Flow_Graph, v: ^Expr_Call) {
	info := underlying_info(graph.k.c, call_proc_type(graph.k.c, v))
	if info == nil {
		return
	}
	// A container insertion reports its element as the insertion it is.
	if callee := symbol_of(graph.k.c, v.resolution.symbol); callee != nil && callee.container_op != .None {
		return
	}
	for argument, index in v.bound {
		if argument == nil || index >= len(info.parameters) {
			continue
		}
		mode := index < len(info.param_modes) ? info.param_modes[index] : Param_Mode.Value
		type := info.parameters[index]
		if mode != .Value || type_is_managed(graph.k.c, type) || !type_is_aggregate(graph.k.c, type) {
			continue
		}
		if expression_is_borrowed_place(argument) {
			report_copy_cost(graph.k, .Argument, expr_span(argument), argument, type, graph.loop_depth > 0)
		}
	}
}

// A lifecycle event on a tracked variable operand, or else an ordinary walk of it.
@(private = "file")
walk_flow_operand :: proc(graph: ^Flow_Graph, operand: Expr, kind: Flow_Event_Kind, span: Span, verb: string) {
	if ident, is_ident := operand.(^Expr_Ident); is_ident {
		if slot, tracked := graph.by_symbol[ident.symbol]; tracked {
			emit(graph, Flow_Event{kind = kind, slot = slot, span = span, name = ident.name, verb = verb})
			return
		}
	}
	walk_flow_expr(graph, operand)
}

@(private = "file")
walk_flow_call :: proc(graph: ^Flow_Graph, v: ^Expr_Call) -> []int {
	#partial switch operation in v.operation {
	case Call_Enum_From_Int:
		walk_flow_expr(graph, v.bound[0])
		return nil
	case Call_Extract:
		return walk_flow_expr(graph, operation.node)
	case Call_Box_Unbox:
		// The payload carries what the consumed box carried below its one step.
		loans := walk_flow_expr(graph, v.bound[0])
		if graph.mode == .Lifecycle {
			return nil
		}
		return prov_project_content(graph, loans, expr_base(v.bound[0]).type, {proj_wild()}, v.type, v.span)
	case Call_Union_As:
		// Both unions keep their payloads below one wildcard.
		loans := walk_flow_expr(graph, v.bound[0])
		if graph.mode == .Lifecycle {
			return nil
		}
		return prov_project_content(graph, loans, expr_base(v.bound[0]).type, nil, v.type, v.span)
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
			return graph.mode == .Lifecycle ? nil : prov_load_content(graph, carriers, nil, v.type, v.span)
		}
	}
	builtin := Builtin_Kind.None
	if sym := symbol_of(graph.k.c, v.resolution.symbol); sym != nil && sym.kind == .Builtin {
		builtin = sym.builtin
	}
	#partial switch builtin {
	// Unevaluated operands read nothing (design.md "Variable declarations").
	case .Size_Of, .Align_Of, .Offset_Of, .Type_Of, .Source_Location:
		return nil
	}
	provider_container_moves(graph, v)
	if graph.mode != .Lifecycle {
		out := prov_call(graph, v)
		provider_container_end(graph, v)
		prov_container_drop_effects(graph, v)
		return out
	}
	#partial switch builtin {
	case .Exchange:
		// The destination must be live and stays live (design.md).
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
	// A method receiver is both `bound[0]` and the callee's operand; walk it once,
	// as an argument, so `move(value).method()` kills its source once.
	if sym := symbol_of(graph.k.c, v.resolution.chosen_overload); sym == nil || !sym.has_receiver {
		walk_flow_expr(graph, v.callee)
	}
	report_argument_copies(graph, v)
	stores := call_may_store(graph.k.c, v)
	for step in 0 ..< len(v.bound) {
		index := call_slot_at(v, step)
		if v.is_variadic && index == v.variadic_slot && !v.variadic_forwards {
			walk_variadic_pack(graph, v, stores)
		} else {
			walk_flow_argument(graph, v.bound[index], stores)
		}
	}
	if len(v.bound) == 0 {
		for argument in v.args {
			walk_flow_expr(graph, argument.value)
		}
	}
	provider_container_end(graph, v)
	prov_container_drop_effects(graph, v)
	note_reset_point(graph, v)
	return nil
}

// An unforwarded variadic pack's operands in written order; the pack holds the
// union of their loans.
@(private)
walk_variadic_pack :: proc(graph: ^Flow_Graph, v: ^Expr_Call, stores := false) -> []int {
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
		joined = prov_join(graph, joined, walk_flow_argument(graph, operand, stores))
	}
	return joined
}

// `free_all`, or an argument to an `@(allocator_reset)` parameter; shared by both
// passes so they agree on which calls reset.
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

// After the arguments, which may themselves move an owner out.
@(private = "file")
note_reset_point :: proc(graph: ^Flow_Graph, v: ^Expr_Call) {
	if graph.mode != .Lifecycle || !call_is_reset(graph.k.c, v) {
		return
	}
	key := Reset_Key{graph.literal, v, INVALID_SYMBOL, graph.expansion}
	graph.k.c.reset_dead[key] = {}
	if len(graph.tracked) > 0 {
		emit(graph, Flow_Event{kind = .Reset_Point, span = v.span, reset = key, call = v})
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
	if (len(graph.last_uses) == 0 && len(graph.required) == 0) || !committing(graph.k.c) {
		return
	}
	tracked := len(graph.tracked)
	read_in := make([][]bool, len(graph.blocks), graph.alloc)
	for &row in read_in {
		row = make([]bool, tracked, graph.alloc)
	}
	reads := make([]bool, tracked, graph.alloc)
	// Backward to a fixed point: reads only grow, so this stops.
	for changed := true; changed; {
		changed = false
		for index := len(graph.blocks) - 1; index >= 0; index -= 1 {
			reads_at_exit(graph, read_in, Block_Id(index), reads)
			events := graph.blocks[index].events[:]
			reads_before(events, 0, reads)
			if !slice.equal(reads, read_in[index]) {
				copy(read_in[index], reads)
				changed = true
			}
		}
	}
	// design.md "@(require_results)": a required result no path reads before it
	// is overwritten or leaves scope was dropped unseen. One lent elsewhere may
	// be read through the borrow.
	for write in graph.required {
		event := graph.blocks[write.block].events[write.event]
		reads_at_exit(graph, read_in, write.block, reads)
		reads_before(graph.blocks[write.block].events[:], write.event + 1, reads)
		if reads[event.slot] || graph.lent[event.slot] {
			continue
		}
		what := write.source != "" ? concat(graph.k.c, "the result of `", concat(graph.k.c, write.source, "`")) : "the result of this call"
		errorf(
			graph.k.c, event.span, "L0698",
			"%s stored in `%s` is never read before it is overwritten or goes out of scope: inspect it, or discard it with `_ = ...`",
			what, event.name,
		)
	}
	// A deferred copy is one node at every exit it expands at, so it becomes a
	// move only when no expansion's source is read again.
	kept := make(map[^bool]bool, allocator = graph.alloc)
	for use in graph.last_uses {
		site, clone, via := last_use_site(graph, use)
		if site == nil || !clone^ || via {
			continue
		}
		event := graph.blocks[use.block].events[use.event]
		reads_at_exit(graph, read_in, use.block, reads)
		reads_before(graph.blocks[use.block].events[:], use.event + 1, reads)
		if graph.lent[event.slot] || reads[event.slot] {
			kept[clone] = true
		}
	}
	for use in graph.last_uses {
		site, clone, via := last_use_site(graph, use)
		if site == nil || via || clone in kept {
			continue
		}
		event := &graph.blocks[use.block].events[use.event]
		// The verb stays the copy's, so a liveness error reads as the use written.
		if !clone^ {
			if moved, is_move := site^.(^Expr_Move); is_move && moved.implicit {
				event.kind = .Kill // an earlier expansion already made it a move
			}
			continue
		}
		ident := site^.(^Expr_Ident)
		if !clone_may_allocate(graph.k.c, ident.type) {
			continue
		}
		event.kind = .Kill
		clone^ = false
		moved := new(Expr_Move, graph.k.c.semantic_allocator)
		moved.span, moved.type, moved.value_category = ident.span, ident.type, .Value
		moved.value = ident
		moved.implicit = true
		site^ = moved
	}
}

// Which locals a block's successors may read.
@(private = "file")
reads_at_exit :: proc(graph: ^Flow_Graph, read_in: [][]bool, block: Block_Id, reads: []bool) {
	slice.fill(reads, false)
	for successor in graph.blocks[int(block)].succs {
		for value, slot in read_in[int(successor)] {
			reads[slot] ||= value
		}
	}
}

// Steps `reads` backward over `events[from:]`.
@(private = "file")
reads_before :: proc(events: []Flow_Event, from: int, reads: []bool) {
	for index := len(events) - 1; index >= from; index -= 1 {
		event := events[index]
		#partial switch event.kind {
		case .Use, .Kill:
			reads[event.slot] = true
		case .Init, .Assign:
			reads[event.slot] = false
		}
	}
}

// The operand and clone flag a candidate names, and whether its destination
// has a `via`, which a clone allocates from and a move would not.
@(private = "file")
last_use_site :: proc(graph: ^Flow_Graph, use: Last_Use) -> (site: ^Expr, clone: ^bool, via: bool) {
	c := graph.k.c
	if d := use.decl; d != nil {
		if use.index >= len(d.value_clones) {
			return
		}
		return &d.values[use.index], &d.value_clones[use.index], d.via != nil
	}
	s := use.assign
	if s == nil || use.index >= len(s.rhs_clones) || use.index >= len(s.lhs) {
		return
	}
	target := place_root_symbol(s.lhs[use.index])
	// `x = x` would move the value out of the place it is stored back into.
	if ident, is_ident := s.rhs[use.index].(^Expr_Ident); is_ident && ident.symbol == target {
		return
	}
	return &s.rhs[use.index], &s.rhs_clones[use.index], symbol_via_allocator(c, target) != nil
}

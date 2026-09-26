// A disposable per-procedure control-flow view over the annotated AST, rebuilt
// per concrete body instance. A local goes live at a completed initialization,
// dies at `move`/`drop`, and must be live at a use; a managed one is also
// cleaned up, innermost first, wherever control leaves its scope. Provenance
// events are built in cfg_provenance.odin.
package lokec

import "core:fmt"
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
	// `Reset_Point`: the resetting call, or the provider end's key.
	call:          ^Expr_Call,
	cleanup_reset: Cleanup_Reset_Key,
	// The attempted operation, for diagnostics.
	verb:          string,
}

// Where a local holding a provider ends. A `drop`, `move`, or assignment is
// keyed by its node. A cleanup can be expanded at several exits, so each is
// numbered per symbol in walk order instead: both passes number the same
// symbols' cleanups the same way, whatever other roots only one of them
// registers.
Cleanup_Reset_Key :: struct {
	body:    ^Expr_Proc,
	symbol:  Symbol_Id,
	ordinal: int,
	node:    rawptr,
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
	// one `ceil(loans/8)`-byte row per slot.
	prov:            [dynamic]Prov_Event,
	reach_entry:     []u8,
	reach_exit:      []u8,
	precision_entry: []Precision_Loss,
	precision_exit:  []Precision_Loss,
	invalid_entry:   []bool,
	invalid_exit:    []bool,
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
	kind: Flow_Cleanup_Kind,
	slot: int,
	stmt: Stmt,
	root: Root_Id,
	span: Span,
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

	// Provenance modes only.
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
	allocation_region_sources: [dynamic]Prov_Allocation_Region_Source,
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
	callee_expr:   Expr,
	// Temporaries ending with the current statement (design.md).
	temp_roots:     [dynamic]Root_Id,
	// design.md "Allocator regions and region provenance".
	region_of:       map[Symbol_Id]Region_Set,
	region_content:  map[Symbol_Id][]Prov_Region_Content,
	// The parent allocator a provider depends on until it is dropped.
	provider_parents: map[Symbol_Id]Region_Set,
	owners_in_scope: [dynamic]Symbol_Id,
	param_count:     int,
	// One bit per local `mem.Arena`/`mem.Scratch`.
	provider_bits:    map[Symbol_Id]u64,
	provider_symbols: [dynamic]Symbol_Id,
	// The `move`s and `exchange`s whose value becomes a new local or a result,
	// which takes the provider's region with it rather than ending it.
	aliased_moves:    map[rawptr]bool,
	has_region_event: bool,
	// The uses that are a local's `drop` at scope exit, for the note naming them.
	scope_drops:      map[Span]bool,
	has_content_load: bool,

	k:       ^Checker,
	literal: ^Expr_Proc,
	current: Block_Id,
	// The cleanups of every open scope, in registration order; `scopes` marks
	// where each scope starts.
	in_scope:       [dynamic]Flow_Cleanup,
	scopes:         [dynamic]Flow_Scope,
	cleanup_resets: map[Symbol_Id]int,
	loop_depth:     int,
	// Where an abrupt exit lands, and how far down `in_scope` it unwinds.
	break_block:    Block_Id,
	continue_block: Block_Id,
	break_depth:    int,
	continue_depth: int,
}

NO_BLOCK :: Block_Id(-1)

// Lifecycle mode returns nil for a body with nothing to track; a provenance mode
// always builds one.
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
	graph.step_views = make(map[Symbol_Id]bool, 8, allocator)
	graph.content_by_symbol = make(map[Symbol_Id][]int, 8, allocator)
	graph.call_results = make(map[^Expr_Call]Prov_Call_Result, 8, allocator)
	graph.allocation_region_sources = make([dynamic]Prov_Allocation_Region_Source, allocator)
	graph.summary_callees = make([dynamic]Symbol_Id, allocator)
	graph.plain_calls = make([dynamic]^Expr_Call, allocator)
	graph.effect_writes = make([dynamic]Symbol_Id, allocator)
	graph.effect_calls = make([dynamic]Effect_Call, allocator)
	graph.effect_values = make([dynamic]Symbol_Id, allocator)
	graph.temp_roots = make([dynamic]Root_Id, allocator)
	graph.region_of = make(map[Symbol_Id]Region_Set, 8, allocator)
	graph.region_content = make(map[Symbol_Id][]Prov_Region_Content, 8, allocator)
	graph.provider_parents = make(map[Symbol_Id]Region_Set, 4, allocator)
	graph.owners_in_scope = make([dynamic]Symbol_Id, allocator)
	graph.provider_bits = make(map[Symbol_Id]u64, 4, allocator)
	graph.map_key_entries = make(map[string]int, 4, allocator)
	graph.reborrows = make([dynamic]Prov_Reborrow, allocator)
	graph.provider_symbols = make([dynamic]Symbol_Id, allocator)
	graph.cleanup_resets = make(map[Symbol_Id]int, 4, allocator)
	graph.aliased_moves = make(map[rawptr]bool, 4, allocator)
	graph.break_block, graph.continue_block = NO_BLOCK, NO_BLOCK
	graph.current = new_flow_block(graph)

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
// (design.md).
@(private = "file")
emit_cleanups :: proc(graph: ^Flow_Graph, down_to: int) {
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
			resize(&graph.in_scope, index)
			walk_flow_stmt(graph, action.stmt)
			resize(&graph.in_scope, index)
			append(&graph.in_scope, ..tail)
			resize(&graph.owners_in_scope, owners)
		case .Prov_Root:
			provider_region_end(graph, graph.roots[int(action.root)].symbol, action.span)
			prov_drop_use(graph, graph.roots[int(action.root)].symbol, action.span, at_scope_exit = true)
			prov_emit(graph, Prov_Event{kind = .Root_End, root = action.root, span = action.span})
		case .Local:
			id := graph.tracked[action.slot].symbol
			sym := symbol_of(graph.k.c, id)
			span := sym == nil ? no_span() : sym.span
			provider_region_end(graph, id, span)
			if graph.mode != .Lifecycle {
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
// region backs must be dead by then (design.md "Allocators"). `node` keys a
// written end; a cleanup passes nil. `ends` names a written end for the
// diagnostic.
@(private)
provider_region_end :: proc(graph: ^Flow_Graph, id: Symbol_Id, span: Span, node: rawptr = nil, ends := "") {
	sym := symbol_of(graph.k.c, id)
	if sym == nil || sym.kind != .Var || sym.duration != .None || !type_carries_provider(graph.k.c, sym.type) {
		return
	}
	key := Cleanup_Reset_Key{graph.literal, id, 0, node}
	if node == nil {
		graph.cleanup_resets[id] += 1
		key.ordinal = graph.cleanup_resets[id]
	}
	if graph.mode == .Lifecycle {
		emit(graph, Flow_Event{kind = .Reset_Point, cleanup_reset = key, span = span})
		return
	}
	dead, found := graph.k.c.cleanup_reset_dead[key]
	// No key: an unreachable exit, or a view such as a `&` loop element that
	// owns nothing. A consumed value has no region left to end either.
	if !found || slice.contains(dead, id) {
		return
	}
	prov_provider_use(graph, id, span)
	// A parameter's region is the caller's, and its owners are the caller's too.
	if root, rooted := graph.root_by_symbol[id]; !rooted || graph.roots[int(root)].kind != .Local {
		return
	}
	prov_reset(graph, prov_provider_region(graph, id), span, true, nil, dead, ends, id)
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
		provider_region_end(graph, root, span, node, provider_end_phrase(graph, direct, name))
		return
	}
	if !place_is_direct(graph.k.c, place) {
		provider_indirect_end(graph, node, span, verb)
	}
}

// A place behind a pointer or slice may be in any local holding providers, so
// the regions of all of them in scope end here.
@(private = "file")
provider_indirect_end :: proc(graph: ^Flow_Graph, node: rawptr, span: Span, verb: string) {
	key := Cleanup_Reset_Key{graph.literal, INVALID_SYMBOL, 0, node}
	if graph.mode == .Lifecycle {
		emit(graph, Flow_Event{kind = .Reset_Point, cleanup_reset = key, span = span})
		return
	}
	dead, found := graph.k.c.cleanup_reset_dead[key]
	if !found {
		return
	}
	set := prov_empty_region(graph)
	for id in graph.owners_in_scope {
		sym := symbol_of(graph.k.c, id)
		if sym == nil || !type_carries_provider(graph.k.c, sym.type) {
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
	prov_reset(graph, set, span, true, nil, dead, ends)
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
		append(&graph.in_scope, Flow_Cleanup{kind = .Defer, stmt = s.stmt})

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
				prov_emit(graph, Prov_Event {
					kind           = .Escape,
					sources        = sources,
					span           = expr_span(value.expr),
					region         = escaping,
					region_content = prov_result_region_fields(graph, value.expr, result_type),
					// The frame's regions end here, so the diagnostic names them.
					name           = prov_region_name(graph, escaping),
				})
				held = prov_hold_result(graph, sources, result_type, expr_span(value.expr))
			}
			emit_cleanups(graph, 0)
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
			killed := false
			if ident, is_ident := value.expr.(^Expr_Ident); is_ident && !value.clone_on_return {
				if slot, tracked := graph.by_symbol[ident.symbol]; tracked {
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
	// A provider moved into a local's storage goes on backing its owners there.
	if s.op == .Assign && !s.destructure.active {
		for target, index in s.lhs {
			if index < len(s.rhs) && provider_place_root(graph, target) != INVALID_SYMBOL {
				mark_aliased_moves(graph, s.rhs[index])
			}
		}
	}
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
		borrowed: []int
		for loans in value_loans {
			borrowed = prov_join(graph, borrowed, loans)
		}
		prov_direct_effects(graph, s.operator, s.op_span, borrowed)
		prov_direct_effects(graph, s.place_setter, s.op_span, borrowed)
		return
	}
	classify_assignment_copies(graph.k, s, graph.loop_depth > 0)
	for target, index in s.lhs {
		// A full assignment revives the variable; a write through a field or
		// element is a use of its root.
		if ident, is_ident := target.(^Expr_Ident); is_ident && s.op == .Assign {
			provider_assign_end(graph, ident)
			if slot, tracked := graph.by_symbol[ident.symbol]; tracked {
				emit(graph, Flow_Event {
					kind   = .Assign,
					slot   = slot,
					span   = expr_span(target),
					name   = ident.name,
					assign = s,
					target = index,
				})
				continue
			}
		}
		if s.op == .Assign {
			provider_field_assign_end(graph, target)
		}
		walk_flow_expr(graph, target)
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
	iterated := walk_flow_expr(graph, iterable)
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
	// design.md "By-reference iteration": a `&` binding's loan ends with its step.
	walk_flow_loop_body(graph, s.body, head, done, s.bindings, place_loop)
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
		// A lent or mutable element is the source's storage, not a copy.
		if s.borrows || foreach_is_place_loop(s) {
			prov_bind_view(graph, binding.symbol, iterated, lends = !foreach_is_place_loop(s))
		}
	}
}

@(private = "file")
walk_flow_loop_body :: proc(
	graph: ^Flow_Graph, body: ^Block, next, done: Block_Id,
	bindings: []Foreach_Binding = nil, all_step_borrows := false,
) {
	outer_break, outer_continue := graph.break_block, graph.continue_block
	outer_break_depth, outer_continue_depth := graph.break_depth, graph.continue_depth
	graph.break_block, graph.continue_block = done, next
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
	subject := walk_flow_expr(graph, s.subject)
	// A switch over a temporary consumes it into the case binding; one over a
	// place borrows it.
	consumes := s.kind != .Value && s.subject != nil &&
		expr_base(s.subject).type != TYPE_ANY_VIEW &&
		!expression_is_borrowed_place(s.subject)
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
			// A place subject keeps its payload, so the binding views its storage.
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
			return prov_consume(graph, v.value, v.span, "moved")
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
		return walk_flow_call(graph, v)

	case ^Expr_Binary:
		borrowed := walk_flow_expr(graph, v.lhs)
		if v.op == .And_And || v.op == .Or_Or {
			entry := graph.current
			merge := new_flow_block(graph)
			link(graph, entry, merge)
			graph.current = new_flow_block(graph)
			link(graph, entry, graph.current)
			right := walk_flow_expr(graph, v.rhs)
			if prov { borrowed = prov_join(graph, borrowed, right) }
			link(graph, graph.current, merge)
			graph.current = merge
		} else {
			right := walk_flow_expr(graph, v.rhs)
			if prov { borrowed = prov_join(graph, borrowed, right) }
		}
		if prov { prov_operator_effects(graph, v.resolution, v.span, borrowed) }

	case ^Expr_Unary:
		if prov && v.op == .Amp {
			return prov_address_of(graph, v)
		}
		borrowed := walk_flow_expr(graph, v.operand)
		if prov { prov_operator_effects(graph, v.resolution, v.span, borrowed) }

	case ^Expr_Postfix:
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
					prov_emit(graph, Prov_Event {
						kind = .Escape, sources = escaping, span = v.span,
					})
					held = prov_hold_result(graph, escaping, proc_symbol.result, v.span)
				}
			}
			emit_cleanups(graph, 0)
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
			if root, path, ok := prov_place_of(graph, v); ok {
				prov_walk_subscripts(graph, v)
				prov_access(graph, root, path, .Read, v.span)
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
				prov_operator_effects(graph, v.resolution, v.span, loans)
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
	case .Free:
		// Only a use: provenance reports a double release in the allocation's terms.
		if len(v.bound) == 1 {
			walk_flow_operand(graph, v.bound[0], .Use, v.span, "released")
		}
		return nil
	}
	// A method receiver is both `bound[0]` and the callee's operand; walk it once,
	// as an argument, so `move(value).method()` kills its source once.
	if sym := symbol_of(graph.k.c, v.resolution.chosen_overload); sym == nil || !sym.has_receiver {
		walk_flow_expr(graph, v.callee)
	}
	report_argument_copies(graph, v)
	for step in 0 ..< len(v.bound) {
		index := call_slot_at(v, step)
		if v.is_variadic && index == v.variadic_slot && !v.variadic_forwards {
			walk_variadic_pack(graph, v)
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

// An unforwarded variadic pack's operands in written order; the pack holds the
// union of their loans.
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
	if len(graph.tracked) == 0 || !call_is_reset(graph.k.c, v) {
		return
	}
	emit(graph, Flow_Event{kind = .Reset_Point, span = v.span, call = v})
}

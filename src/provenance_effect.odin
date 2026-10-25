// Ordered semantic fact operations. The flow walk selects checked inputs;
// saturation replays these operations without evaluating source operands.
package lokec

import "core:mem"
import "core:mem/virtual"
import "core:slice"
import "core:time"

Prov_Replay_Statistics :: struct {
	body_builds, replay_passes: int,
	normalization_time, replay_time, materialization_time: time.Duration,
	peak_build_bytes: uint,
}

Prov_Effect_Declare :: struct { symbol: Symbol_Id, value: Value_Id, projected: int, copies: bool }
Prov_Effect_Element :: struct { symbol: Symbol_Id, value: Value_Id }
Prov_Effect_Case :: struct { symbol: Symbol_Id, value: Value_Id, variants: []int, slot: int }
Prov_Effect_Targets :: struct { storage: Storage_Id, value: Value_Id, path: []Proj_Step }
Prov_Effect_Call :: struct { value: Value_Id, kind: enum { Result, Write, Invalidate } }
Prov_Effect_Store :: struct { destination, value: Value_Id, element: bool }
Prov_Effect_Spread :: struct { destination, value: Value_Id }
Prov_Effect_Map_Key :: struct { destination, value: Value_Id }
Prov_Effect_Define :: struct { storage: Storage_Id, path: []Proj_Step, value: Value_Id, source: []Proj_Step, copies: bool, allocated_by: Symbol_Id }
Prov_Effect_Parent :: struct { symbol: Symbol_Id, value: Value_Id, source: []Proj_Step, storage: bool }
Prov_Effect_Assign :: struct { symbol: Symbol_Id, value: Value_Id, source: []Proj_Step, storage: bool }
Prov_Effect_Move_Provider :: struct { symbol: Symbol_Id, value: Value_Id }
Prov_Effect_Forget_Binding :: struct { symbol: Symbol_Id }
Prov_Effect_Borrow_Owner :: struct { value: Value_Id }
Prov_Fact_Operation :: union {
	Prov_Effect_Declare, Prov_Effect_Element, Prov_Effect_Case,
	Prov_Effect_Targets, Prov_Effect_Call, Prov_Effect_Store,
	Prov_Effect_Spread, Prov_Effect_Map_Key, Prov_Effect_Define,
	Prov_Effect_Parent, Prov_Effect_Assign, Prov_Effect_Move_Provider,
	Prov_Effect_Forget_Binding, Prov_Effect_Borrow_Owner,
}

// `first` and `count` are the construction events emitted while the operation
// ran; `sequence` orders it among the recorded events.
Prov_Effect_Site :: struct {
	operation: Prov_Fact_Operation,
	block: Block_Id,
	expansion: Defer_Expansion,
	first, count: int,
	sequence: int,
	// The walk state its replay reads.
	parallel_depth: int,
	task: int,
}

Prov_Effect_Program :: struct {
	alloc: mem.Allocator,
	operations: [dynamic]Prov_Effect_Site,
	events: [dynamic]Prov_Event_Site,
	root_regions: [dynamic]Prov_Root_Region,
	sequence: int,
	// Materialized owner views already recorded by a query.
	borrowed_owners: map[Value_Id]bool,
	input: ^Prov_Input,
	param_count: int,
	// Storage metadata and topology do not depend on the carried facts.
	roots: []Prov_Root,
	root_by_symbol: map[Symbol_Id]Root_Id,
	root_by_storage: map[Storage_Id]Root_Id,
	provider_bits: map[Symbol_Id]u64,
	provider_symbols: []Symbol_Id,
	provider_paths: map[Symbol_Id][]Provider_Path,
	temp_provider_bits: map[^Expr_Call]u64,
	operator_calls: map[rawptr]^Expr_Call,
	lent_locals: map[Symbol_Id]bool,
	blocks: int,
	replays: int,
	normalization_time, replay_time, materialization_time: time.Duration,
	peak_used_bytes: uint,
}

// design.md "Allocator regions and region provenance": saturate flow-insensitive
// facts before producing the graph consumed by the borrow and region solvers.
build_provenance_replay :: proc(k: ^Checker, literal: ^Expr_Proc, mode: Flow_Mode) -> ^Flow_Graph {
	allocator := k.c.analysis_allocator
	started := time.tick_now()
	initial_bytes := k.c.analysis_arena.total_used
	program := new(Prov_Effect_Program, allocator)
	program.alloc = allocator
	program.operations = make([dynamic]Prov_Effect_Site, allocator)
	program.events = make([dynamic]Prov_Event_Site, allocator)
	program.root_regions = make([dynamic]Prov_Root_Region, allocator)
	program.borrowed_owners = make(map[Value_Id]bool, 4, allocator)
	initial := build_flow_pass(k, literal, allocator, mode, program)
	initial.effect_program = nil
	program.param_count = initial.param_count
	weight := prov_region_weight(initial)
	if weight == 0 {
		// No carried fact changed: the construction graph is already final, as
		// in the former fixed point. Keep its events and avoid another walk.
		program.input = initial.input
		program.normalization_time = time.tick_since(started)
		program.peak_used_bytes = k.c.analysis_arena.total_used - initial_bytes
		initial.normalized_effects = program
		prov_note_replay_statistics(k.c, program)
		return initial
	}
	prov_finish_effect_program(program, initial)
	// What a recorded event reported from unsettled facts is reported again
	// once they settle; the rest of the construction diagnostics stand.
	prov_drop_event_diagnostics(k.c, program)
	program.normalization_time = time.tick_since(started)
	replay_started := time.tick_now()
	carry_arena, replay_arena: virtual.Arena
	defer virtual.arena_destroy(&carry_arena)
	defer virtual.arena_destroy(&replay_arena)
	carry := prov_carry_regions(initial, virtual.arena_allocator(&carry_arena))
	seeded := weight
	for {
		graph := prov_fact_graph(k, literal, mode, program, virtual.arena_allocator(&replay_arena))
		prov_seed_regions(graph, carry)
		replayed_diagnostics := len(k.c.diagnostics)
		prov_replay_fact_operations(graph, program)
		truncate_diagnostics(k.c, replayed_diagnostics)
		current_weight := prov_region_weight(graph)
		settled := current_weight == seeded
		if !settled {
			free_all(virtual.arena_allocator(&carry_arena))
			carry = prov_carry_regions(graph, virtual.arena_allocator(&carry_arena))
		}
		program.peak_used_bytes = max(program.peak_used_bytes,
		                             k.c.analysis_arena.total_used - initial_bytes + carry_arena.total_used + replay_arena.total_used)
		free_all(virtual.arena_allocator(&replay_arena))
		if settled { break }
		seeded = current_weight
	}
	program.replay_time = time.tick_since(replay_started)
	// The construction graph's loans, roots, and control flow do not depend on
	// the carried facts. Its fact-dependent events are materialized again from
	// the settled facts, interleaved with one more replay of the fact operations.
	materialization_started := time.tick_now()
	final := prov_fact_graph(k, literal, mode, program, allocator)
	prov_seed_regions(final, carry)
	prov_materialize_events(initial, final, program)
	prov_seed_regions(initial, carry)
	program.materialization_time = time.tick_since(materialization_started)
	program.peak_used_bytes = max(program.peak_used_bytes, k.c.analysis_arena.total_used - initial_bytes + carry_arena.total_used)
	initial.normalized_effects = program
	prov_note_replay_statistics(k.c, program)
	return initial
}

@(private = "file")
prov_note_replay_statistics :: proc(c: ^Compiler, program: ^Prov_Effect_Program) {
	stats := &c.provenance_stats
	stats.body_builds += 1
	stats.replay_passes += program.replays
	stats.normalization_time += program.normalization_time
	stats.replay_time += program.replay_time
	stats.materialization_time += program.materialization_time
	stats.peak_build_bytes = max(stats.peak_build_bytes, program.peak_used_bytes)
}

@(private = "file")
prov_finish_effect_program :: proc(program: ^Prov_Effect_Program, graph: ^Flow_Graph) {
	// Describe every value before reclaiming construction scratch. No later fact
	// round may add values, storage, or checked call descriptions. A later round
	// can follow another branch of a query, so every operand beneath a value is
	// interned at its checked representation too.
	expansion := graph.expansion
	defer graph.expansion = expansion
	operands := make([dynamic]Expr, context.temp_allocator)
	for index := 1; index < len(graph.input.values); index += 1 {
		id := Value_Id(index)
		graph.expansion = graph.input.values[index].expansion
		_ = prov_value_transfer(graph, id)
		_ = prov_input_read(graph, id)
		clear(&operands)
		prov_query_operands(graph, graph.input.values[index].origin, &operands)
		for operand in operands { _ = prov_input_value(graph, operand) }
	}
	// The construction graph and its metadata share the body's analysis arena.
	// Reuse that metadata instead of retaining a second copy of every table.
	program.input = graph.input
	program.input.frozen = true
	program.roots = graph.roots[:]
	program.root_by_symbol = graph.root_by_symbol
	program.root_by_storage = graph.root_by_storage
	program.provider_bits = graph.provider_bits
	program.provider_symbols = graph.provider_symbols[:]
	program.provider_paths = graph.provider_paths
	program.temp_provider_bits = graph.temp_provider_bits
	program.operator_calls = graph.operator_calls
	program.lent_locals = graph.lent_locals
	program.blocks = len(graph.blocks)
}

// The expressions a leaf query can follow from a value of `e`, including the
// call a user operator stands for.
@(private = "file")
prov_query_operands :: proc(graph: ^Flow_Graph, e: Expr, out: ^[dynamic]Expr) {
	add :: proc(out: ^[dynamic]Expr, operands: ..Expr) {
		for operand in operands { if operand != nil { append(out, operand) } }
	}
	if base := expr_base(e); base != nil {
		if call, found := graph.operator_calls[rawptr(base)]; found { add(out, call) }
	}
	#partial switch v in e {
	case ^Expr_Selector:        add(out, v.operand)
	case ^Expr_Checked_Extract: add(out, v.operand)
	case ^Expr_Index:           add(out, v.operand); add(out, ..v.indices); add(out, ..v.bound)
	case ^Expr_Slice:           add(out, v.operand, v.lo, v.hi); add(out, ..v.bound)
	case ^Expr_Postfix:         add(out, v.operand)
	case ^Expr_Propagated_Error:
		if v.owner != nil { add(out, v.owner.operand) }
	case ^Expr_Unary:           add(out, v.operand)
	case ^Expr_Binary:          add(out, v.lhs, v.rhs)
	case ^Expr_Or_Else:         add(out, v.value, v.fallback)
	case ^Expr_Cond:            add(out, v.then, v.otherwise)
	case ^Expr_Move:            add(out, v.value)
	case ^Expr_Composite:
		for element in v.elements { add(out, element.key, element.value) }
		add(out, v.via)
	case ^Expr_Call:
		if v.dispatch != nil { return }
		add(out, ..v.bound)
		add(out, ..v.variadic_elements)
		add(out, ..v.variadic_spreads)
		for argument in v.args { add(out, argument.value) }
	}
}

// A replay round starts from the ordinary constructor, so every fact map exists;
// its loan, lifecycle, and event buffers stay empty.
@(private)
prov_fact_graph :: proc(k: ^Checker, literal: ^Expr_Proc, mode: Flow_Mode, program: ^Prov_Effect_Program, allocator: mem.Allocator) -> ^Flow_Graph {
	graph := new_flow_graph(k, literal, allocator, mode, normalized_input = program.input)
	graph.replaying_facts = true
	graph.param_count = program.param_count
	append(&graph.roots, ..program.roots)
	for key, value in program.root_by_symbol { graph.root_by_symbol[key] = value }
	for key, value in program.root_by_storage { graph.root_by_storage[key] = value }
	for key, value in program.provider_bits { graph.provider_bits[key] = value }
	append(&graph.provider_symbols, ..program.provider_symbols)
	for key, value in program.provider_paths { graph.provider_paths[key] = value }
	for key, value in program.temp_provider_bits { graph.temp_provider_bits[key] = value }
	for key, value in program.operator_calls { graph.operator_calls[key] = value }
	for key, value in program.lent_locals { graph.lent_locals[key] = value }
	for len(graph.blocks) < program.blocks { _ = new_flow_block(graph) }
	return graph
}

// One high-level operation owns the nested fact writes it performs. Recording
// both would freeze intermediate results and replay the same write twice.
prov_effect_active :: #force_inline proc(graph: ^Flow_Graph) -> bool {
	return graph.effect_program != nil && graph.effect_depth == 0
}

prov_effect_symbol_relevant :: proc(graph: ^Flow_Graph, id: Symbol_Id) -> bool {
	sym := symbol_of(graph.k.c, id)
	return sym != nil && prov_type_has_region(graph.k.c, sym.type)
}

// The record helpers below run only while prov_effect_active holds.
prov_effect_begin :: proc(graph: ^Flow_Graph, operation: Prov_Fact_Operation) {
	program := graph.effect_program
	program.sequence += 1
	first := graph.current == NO_BLOCK ? 0 : len(graph.blocks[graph.current].prov)
	append(&program.operations, Prov_Effect_Site{operation, graph.current, graph.expansion, first, 0, program.sequence, graph.parallel_depth, prov_task_index(graph)})
	graph.effect_depth += 1
}

prov_effect_end :: proc(graph: ^Flow_Graph, recorded: bool) {
	if !recorded { return }
	graph.effect_depth -= 1
	site := &graph.effect_program.operations[len(graph.effect_program.operations) - 1]
	assert(site.block == graph.current, "a fact operation changed blocks")
	if site.block != NO_BLOCK { site.count = len(graph.blocks[site.block].prov) - site.first }
}

prov_effect_value :: proc(graph: ^Flow_Graph, id: Value_Id) -> Value_Id {
	_ = prov_value_transfer(graph, id)
	return id
}

prov_effect_path :: proc(graph: ^Flow_Graph, path: []Proj_Step) -> []Proj_Step {
	return slice.clone(path, graph.effect_program.alloc)
}

// Borrowed bindings are rebound independently for each case/defer expansion.
prov_forget_region_binding :: proc(graph: ^Flow_Graph, symbol: Symbol_Id) {
	recorded := prov_effect_active(graph)
	if recorded { prov_effect_begin(graph, Prov_Effect_Forget_Binding{symbol}) }
	defer prov_effect_end(graph, recorded)
	delete_key(&graph.region_aliases, symbol)
}

prov_merge_provider_parent :: proc(graph: ^Flow_Graph, symbol: Symbol_Id, value: Value_Id, source: []Proj_Step = nil, storage := false) {
	recorded := prov_effect_active(graph)
	if recorded { prov_effect_begin(graph, Prov_Effect_Parent{symbol, prov_effect_value(graph, value), prov_effect_path(graph, source), storage}) }
	defer prov_effect_end(graph, recorded)
	if value == 0 { return }
	region := storage ? prov_storage_region(graph, value) : prov_result_region_at(graph, value, source)
	parent := graph.provider_parents[symbol] or_else prov_empty_region(graph)
	region_merge(&parent, region)
	graph.provider_parents[symbol] = parent
}

prov_assign_value_region :: proc(graph: ^Flow_Graph, symbol: Symbol_Id, value: Value_Id, source: []Proj_Step, storage: bool) {
	recorded := prov_effect_active(graph)
	if recorded { prov_effect_begin(graph, Prov_Effect_Assign{symbol, prov_effect_value(graph, value), prov_effect_path(graph, source), storage}) }
	defer prov_effect_end(graph, recorded)
	if value == 0 { return }
	region := storage ? prov_storage_region(graph, value) : prov_result_region_at(graph, value, source)
	prov_merge_region_of(graph, symbol, region)
}

prov_store_spread_region :: proc(graph: ^Flow_Graph, destination, value: Value_Id) {
	recorded := prov_effect_active(graph)
	if recorded { prov_effect_begin(graph, Prov_Effect_Spread{prov_effect_value(graph, destination), prov_effect_value(graph, value)}) }
	defer prov_effect_end(graph, recorded)
	region := prov_storage_region(graph, value)
	prov_store_region_set(graph, destination, region, region, prov_owner_name(graph, prov_value(graph, value).origin), element = true)
}

prov_store_map_key_region :: proc(graph: ^Flow_Graph, destination, value: Value_Id) {
	recorded := prov_effect_active(graph)
	if recorded { prov_effect_begin(graph, Prov_Effect_Map_Key{prov_effect_value(graph, destination), prov_effect_value(graph, value)}) }
	defer prov_effect_end(graph, recorded)
	region := prov_result_region(graph, value)
	owned := prov_result_region_at(graph, value, nil, .Owners)
	prov_store_region_through(graph, destination, region, owned, prov_owner_name(graph, prov_value(graph, value).origin), {proj_wild(), proj_field(PROJ_MAP_KEY)})
}

prov_replay_fact_operations :: proc(graph: ^Flow_Graph, program: ^Prov_Effect_Program) {
	for site in program.operations {
		graph.current, graph.expansion = site.block, site.expansion
		prov_replay_fact_operation(graph, site.operation)
	}
	program.replays += 1
}

// Every operation reads its values' recorded representations; the checked
// nodes are only their origins. This never walks an operand or builds control
// flow.
@(private)
prov_replay_fact_operation :: proc(graph: ^Flow_Graph, op: Prov_Fact_Operation) {
	switch operation in op {
	case Prov_Effect_Declare:
		prov_declare_region(graph, operation.symbol, symbol_of(graph.k.c, operation.symbol), operation.value, operation.projected, operation.copies)
	case Prov_Effect_Element:
		prov_bind_element_region(graph, operation.symbol, operation.value)
	case Prov_Effect_Case:
		prov_bind_case_region(graph, operation.symbol, operation.value, operation.variants, operation.slot)
	case Prov_Effect_Targets:
		prov_note_alias_source(graph, operation.storage, operation.value, operation.path)
	case Prov_Effect_Call:
		call := prov_value(graph, operation.value).form.(Prov_Form_Call).call
		switch operation.kind {
		case .Result:
			graph.call_results[call] = Prov_Call_Result{region = prov_call_region(graph, operation.value, prov_value(graph, operation.value).type),
			                                            region_content = prov_call_region_content(graph, operation.value)}
		case .Write: prov_call_written_regions(graph, call, prov_input_call(graph, call).signature)
		case .Invalidate: prov_call_written_aliases(graph, call)
		}
	case Prov_Effect_Store:
		prov_store_region(graph, operation.destination, operation.value, operation.element)
	case Prov_Effect_Spread:
		prov_store_spread_region(graph, operation.destination, operation.value)
	case Prov_Effect_Map_Key:
		prov_store_map_key_region(graph, operation.destination, operation.value)
	case Prov_Effect_Define:
		root := prov_root_for_storage(graph, operation.storage)
		prov_define_value_regions(graph, root, operation.path, operation.value, operation.source, operation.copies, operation.allocated_by)
	case Prov_Effect_Parent:
		prov_merge_provider_parent(graph, operation.symbol, operation.value, operation.source, operation.storage)
	case Prov_Effect_Move_Provider:
		prov_merge_moved_bits(graph, operation.symbol, operation.value)
	case Prov_Effect_Assign:
		prov_assign_value_region(graph, operation.symbol, operation.value, operation.source, operation.storage)
	case Prov_Effect_Forget_Binding:
		prov_forget_region_binding(graph, operation.symbol)
	case Prov_Effect_Borrow_Owner:
		prov_note_borrowed_owner(graph, operation.value)
	case:
		unreachable()
	}
}

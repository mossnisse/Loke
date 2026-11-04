// Ordered semantic fact operations. The flow walk selects checked inputs;
// saturation replays these operations without evaluating source operands.
package lokec

import "core:mem"
import "core:slice"
import "core:time"

Prov_Replay_Statistics :: struct {
	body_builds, replay_passes: int,
	normalization_time, replay_time, materialization_time: time.Duration,
	peak_build_bytes: uint,
}

Prov_Effect_Declare :: struct { symbol: Symbol_Id, value: Value_Id, projected: int, copies: bool }
Prov_Effect_Element :: struct { symbol: Symbol_Id, value: Value_Id, element: []Proj_Step, traversed: bool }
Prov_Effect_Case :: struct { symbol: Symbol_Id, value: Value_Id, variants: []int, slot: int }
Prov_Effect_Targets :: struct { storage: Storage_Id, value: Value_Id, path, source: []Proj_Step }
Prov_Effect_Call :: struct { value: Value_Id, kind: enum { Result, Write, Invalidate } }
Prov_Effect_Store :: struct { destination, value: Value_Id, element: bool }
Prov_Effect_Spread :: struct { destination, value: Value_Id }
Prov_Effect_Permute :: struct { receiver: Value_Id }
Prov_Effect_Map_Key :: struct { destination, value: Value_Id }
Prov_Effect_Define :: struct { storage: Storage_Id, path: []Proj_Step, value: Value_Id, source: []Proj_Step, copies: bool, allocated_by: Symbol_Id }
Prov_Effect_Merge_Value :: struct { symbol: Symbol_Id, value: Value_Id, source: []Proj_Step, storage, provider: bool }
Prov_Effect_Move_Provider :: struct { symbol: Symbol_Id, value: Value_Id }
Prov_Effect_Forget_Binding :: struct { symbol: Symbol_Id }
Prov_Effect_Borrow_Owner :: struct { value: Value_Id }
Prov_Fact_Operation :: union {
	Prov_Effect_Declare, Prov_Effect_Element, Prov_Effect_Case,
	Prov_Effect_Targets, Prov_Effect_Call, Prov_Effect_Store,
	Prov_Effect_Spread, Prov_Effect_Permute, Prov_Effect_Map_Key, Prov_Effect_Define,
	Prov_Effect_Merge_Value, Prov_Effect_Move_Provider,
	Prov_Effect_Forget_Binding, Prov_Effect_Borrow_Owner,
}

Prov_Effect_Site :: struct {
	operation: Prov_Fact_Operation,
	using at: Prov_Site,
}

Prov_Effect_Program :: struct {
	operations: [dynamic]Prov_Effect_Site,
	events: [dynamic]Prov_Event_Site,
	root_regions: [dynamic]Prov_Root_Region,
	sequence: int,
	// Materialized owner views already recorded by a query.
	borrowed_owners: map[Value_Id]bool,
	input: ^Prov_Input,
	// The walk's graph, whose topology every round takes (`prov_fact_graph`).
	construction: ^Flow_Graph,
	replays: int,
}

// design.md "Allocator regions and region provenance": saturate flow-insensitive
// facts before producing the graph consumed by the borrow and region solvers.
build_provenance_replay :: proc(k: ^Checker, literal: ^Expr_Proc, mode: Flow_Mode) -> (^Flow_Graph, ^Prov_Effect_Program) {
	stats := &k.c.provenance_stats
	stats.body_builds += 1
	allocator := k.c.analysis_allocator
	started := time.tick_now()
	initial_bytes := scratch_arena_used(&k.c.analysis_arena)
	program := new(Prov_Effect_Program, allocator)
	program.operations = make([dynamic]Prov_Effect_Site, allocator)
	program.events = make([dynamic]Prov_Event_Site, allocator)
	program.root_regions = make([dynamic]Prov_Root_Region, allocator)
	program.borrowed_owners = make(map[Value_Id]bool, allocator)
	initial := build_flow_pass(k, literal, allocator, mode, program)
	initial.effect_program = nil
	program.input, program.construction = initial.input, initial
	weight := prov_fact_weight(&initial.facts)
	if weight == 0 {
		// The walk recorded no carried fact, so replay could change nothing: this
		// graph is final.
		stats.normalization_time += time.tick_since(started)
		stats.peak_build_bytes = max(stats.peak_build_bytes, scratch_arena_used(&k.c.analysis_arena) - initial_bytes)
		return initial, program
	}
	prov_freeze_input(initial)
	// What a recorded event reported from unsettled facts is reported again
	// once they settle; the rest of the construction diagnostics stand.
	prov_drop_event_diagnostics(k.c, program)
	stats.normalization_time += time.tick_since(started)
	replay_started := time.tick_now()
	// Bodies are not replayed within one another, so one pair of arenas serves
	// every body.
	carry_arena, replay_arena := &k.c.replay_carry_arena, &k.c.replay_round_arena
	defer scratch_arena_reset(carry_arena)
	carry := prov_carry_facts(initial, scratch_allocator(carry_arena))
	seeded := weight
	for {
		graph := prov_fact_graph(k, literal, mode, program, scratch_allocator(replay_arena))
		prov_seed_regions(graph, carry)
		replayed_diagnostics := len(k.c.diagnostics)
		prov_replay_fact_operations(graph, program)
		assert(len(k.c.diagnostics) == replayed_diagnostics, "fact replay reported a diagnostic")
		current_weight := prov_fact_weight(&graph.facts)
		settled := current_weight == seeded
		if !settled {
			scratch_arena_reset(carry_arena)
			carry = prov_carry_facts(graph, scratch_allocator(carry_arena))
		}
		stats.peak_build_bytes = max(stats.peak_build_bytes,
		                             scratch_arena_used(&k.c.analysis_arena) - initial_bytes + scratch_arena_used(carry_arena) + scratch_arena_used(replay_arena))
		scratch_arena_reset(replay_arena)
		if settled { break }
		seeded = current_weight
	}
	stats.replay_passes += program.replays
	stats.replay_time += time.tick_since(replay_started)
	// Only fact-dependent events change once the facts settle; they are
	// materialized again, interleaved with one more replay.
	materialization_started := time.tick_now()
	final := prov_fact_graph(k, literal, mode, program, allocator)
	prov_seed_regions(final, carry)
	prov_materialize_events(initial, final, program)
	prov_seed_regions(initial, carry)
	stats.materialization_time += time.tick_since(materialization_started)
	stats.peak_build_bytes = max(stats.peak_build_bytes, scratch_arena_used(&k.c.analysis_arena) - initial_bytes + scratch_arena_used(carry_arena))
	return initial, program
}

// Describe every value: no later fact round may add values, storage, or checked
// call descriptions. A later round can follow another branch of a query; the
// operands it reaches are in the values' forms and transfers, interned with them.
@(private = "file")
prov_freeze_input :: proc(graph: ^Flow_Graph) {
	expansion := graph.expansion
	defer graph.expansion = expansion
	for index := 1; index < len(graph.input.values); index += 1 {
		graph.expansion = graph.input.values[index].expansion
		_ = prov_value_transfer(graph, Value_Id(index))
	}
	graph.input.frozen = true
}

@(private = "file")
prov_copy_map :: proc(into: ^$M/map[$K]$V, from: M) {
	reserve(into, len(from))
	for key, value in from { into[key] = value }
}

// A replay round starts from the ordinary constructor, so every map exists, and
// takes the body's topology: its storage roots, provider tokens, user-operator
// calls, and block count. A query there may still number a temporary provider the
// walk never named, so the round has its own copy of all but the operator calls,
// which it only reads (`prov_operator_call`). The caller seeds its facts; its loan
// and lifecycle buffers stay empty.
@(private)
prov_fact_graph :: proc(k: ^Checker, literal: ^Expr_Proc, mode: Flow_Mode, program: ^Prov_Effect_Program, allocator: mem.Allocator) -> ^Flow_Graph {
	graph := new_flow_graph(k, literal, allocator, mode, normalized_input = program.input)
	graph.replaying_facts = true
	construction := program.construction
	append(&graph.roots, ..construction.roots[:])
	prov_copy_map(&graph.root_by_symbol, construction.root_by_symbol)
	prov_copy_map(&graph.root_by_storage, construction.root_by_storage)
	prov_copy_map(&graph.provider_bits, construction.provider_bits)
	append(&graph.provider_symbols, ..construction.provider_symbols[:])
	prov_copy_map(&graph.provider_paths, construction.provider_paths)
	prov_copy_map(&graph.temp_provider_bits, construction.temp_provider_bits)
	graph.operator_calls = construction.operator_calls
	for len(graph.blocks) < len(construction.blocks) { _ = new_flow_block(graph) }
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
	at := prov_site_here(graph)
	program.sequence += 1
	at.sequence = program.sequence
	append(&program.operations, Prov_Effect_Site{operation, at})
	graph.effect_depth += 1
}

prov_effect_end :: proc(graph: ^Flow_Graph, recorded: bool) {
	if !recorded { return }
	graph.effect_depth -= 1
	site := &graph.effect_program.operations[len(graph.effect_program.operations) - 1]
	assert(site.block == graph.current, "a fact operation changed blocks")
	site.count = prov_next_event(graph) - site.first
}

prov_effect_value :: proc(graph: ^Flow_Graph, id: Value_Id) -> Value_Id {
	_ = prov_value_transfer(graph, id)
	return id
}

prov_effect_path :: proc(graph: ^Flow_Graph, path: []Proj_Step) -> []Proj_Step {
	return slice.clone(path, graph.alloc)
}

prov_replay_fact_operations :: proc(graph: ^Flow_Graph, program: ^Prov_Effect_Program) {
	for site in program.operations {
		graph.current, graph.expansion = site.block, site.expansion
		prov_replay_fact_operation(graph, site.operation)
	}
	program.replays += 1
}

// compiler-architecture.md "Normalized provenance input": replay reads recorded values.
@(private)
prov_replay_fact_operation :: proc(graph: ^Flow_Graph, op: Prov_Fact_Operation) {
	switch operation in op {
	case Prov_Effect_Declare:
		prov_declare_region(graph, operation.symbol, symbol_of(graph.k.c, operation.symbol), operation.value, operation.projected, operation.copies)
	case Prov_Effect_Element:
		prov_bind_element_region(graph, operation.symbol, operation.value, operation.element, operation.traversed)
	case Prov_Effect_Case:
		prov_bind_case_region(graph, operation.symbol, operation.value, operation.variants, operation.slot)
	case Prov_Effect_Targets:
		prov_note_alias_source(graph, operation.storage, operation.value, operation.path, operation.source)
	case Prov_Effect_Call:
		call := prov_value(graph, operation.value).form.(Prov_Form_Call).call
		switch operation.kind {
		case .Result:
			graph.call_results[call] = Prov_Call_Result{region = prov_call_region(graph, operation.value, prov_value(graph, operation.value).type),
			                                            region_content = prov_call_region_content(graph, operation.value)}
		case .Write: prov_call_written_regions(graph, operation.value)
		case .Invalidate: prov_call_written_aliases(graph, operation.value)
		}
	case Prov_Effect_Store:
		prov_store_region(graph, operation.destination, operation.value, operation.element)
	case Prov_Effect_Spread:
		prov_store_spread_region(graph, operation.destination, operation.value)
	case Prov_Effect_Permute:
		prov_store_permuted_region(graph, operation.receiver)
	case Prov_Effect_Map_Key:
		prov_store_map_key_region(graph, operation.destination, operation.value)
	case Prov_Effect_Define:
		root := prov_root_for_storage(graph, operation.storage)
		prov_define_value_regions(graph, root, operation.path, operation.value, operation.source, operation.copies, operation.allocated_by)
	case Prov_Effect_Merge_Value:
		prov_merge_value_region(graph, operation.symbol, operation.value, operation.source, operation.storage, operation.provider)
	case Prov_Effect_Move_Provider:
		prov_merge_moved_bits(graph, operation.symbol, operation.value)
	case Prov_Effect_Forget_Binding:
		prov_forget_region_binding(graph, operation.symbol)
	case Prov_Effect_Borrow_Owner:
		prov_note_borrowed_owner(graph, operation.value)
	case:
		unreachable()
	}
}

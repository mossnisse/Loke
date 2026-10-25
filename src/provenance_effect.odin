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
	Prov_Effect_Define, Prov_Effect_Parent, Prov_Effect_Move_Provider,
	Prov_Effect_Forget_Binding,
	Prov_Effect_Assign,
	Prov_Effect_Spread, Prov_Effect_Map_Key,
	Prov_Effect_Borrow_Owner,
}

Prov_Effect_Site :: struct {
	operation: Prov_Fact_Operation,
	block: Block_Id,
	expansion: Defer_Expansion,
}

Prov_Effect_Program :: struct {
	alloc: mem.Allocator,
	operations: [dynamic]Prov_Effect_Site,
	// Materialized owner views already recorded by a query.
	borrowed_owners: map[Value_Id]bool,
	input: ^Prov_Input,
	entry: ^Flow_Graph,
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
	program.borrowed_owners = make(map[Value_Id]bool, 4, allocator)
	reported := len(k.c.diagnostics)
	initial := build_flow_pass(k, literal, allocator, mode, nil, program)
	initial.effect_program = nil
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
	truncate_diagnostics(k.c, reported)
	program.normalization_time = time.tick_since(started)
	replay_started := time.tick_now()
	carry_arena, replay_arena: virtual.Arena
	defer virtual.arena_destroy(&carry_arena)
	defer virtual.arena_destroy(&replay_arena)
	carry := prov_carry_regions(initial, virtual.arena_allocator(&carry_arena), copy_input = false)
	seeded := weight
	for {
		graph := prov_fact_graph(k, literal, mode, program, virtual.arena_allocator(&replay_arena))
		prov_seed_regions(graph, carry)
		replayed_diagnostics := len(k.c.diagnostics)
		prov_replay_fact_operations(graph, program)
		truncate_diagnostics(k.c, replayed_diagnostics)
		current_weight := prov_region_weight(graph)
		if current_weight == seeded {
			program.peak_used_bytes = max(program.peak_used_bytes,
			                             k.c.analysis_arena.total_used - initial_bytes + carry_arena.total_used + replay_arena.total_used)
			free_all(virtual.arena_allocator(&replay_arena))
			break
		}
		free_all(virtual.arena_allocator(&carry_arena))
		carry = prov_carry_regions(graph, virtual.arena_allocator(&carry_arena), copy_input = false)
		program.peak_used_bytes = max(program.peak_used_bytes,
		                             k.c.analysis_arena.total_used - initial_bytes + carry_arena.total_used + replay_arena.total_used)
		free_all(virtual.arena_allocator(&replay_arena))
		seeded = current_weight
	}
	program.replay_time = time.tick_since(replay_started)
	// The remaining loan/event bridge runs once with settled facts. In particular,
	// borrowed payload publication must see every possible destination. Stage 5
	// removes this final bridge after those operations share the replay vocabulary.
	materialization_started := time.tick_now()
	result := build_flow_pass(k, literal, allocator, mode, carry, normalized = program)
	program.materialization_time = time.tick_since(materialization_started)
	program.peak_used_bytes = max(program.peak_used_bytes, k.c.analysis_arena.total_used - initial_bytes + carry_arena.total_used)
	result.normalized_effects = program
	prov_note_replay_statistics(k.c, program)
	return result
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
	// Prepare all captured representations before reclaiming construction scratch.
	// No later fact round may add values, storage, or checked call descriptions.
	graph.effect_program = nil
	for index := 1; index < len(graph.input.values); index += 1 {
		id := Value_Id(index)
		graph.expansion = graph.input.values[index].expansion
		saved := prov_open_value(graph, id)
		_ = prov_input_transfer(graph, graph.input.values[index].origin)
		_ = prov_input_read(graph, id)
		prov_close_value(saved)
	}
	// The construction graph and its metadata share the body's analysis arena.
	// Reuse that metadata instead of retaining a second copy of every table.
	program.input = graph.input
	program.input.frozen = true
	program.entry.input = program.input
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

@(private)
prov_fact_graph :: proc(k: ^Checker, literal: ^Expr_Proc, mode: Flow_Mode, program: ^Prov_Effect_Program, allocator: mem.Allocator) -> ^Flow_Graph {
	graph := new(Flow_Graph, allocator)
	graph.k, graph.literal, graph.mode, graph.alloc = k, literal, mode, allocator
	graph.prov = new(Prov_State, allocator)
	graph.replaying_facts = true
	graph.input, graph.param_count = program.input, program.entry.param_count
	graph.blocks = make([dynamic]^Flow_Block, allocator)
	graph.roots = make([dynamic]Prov_Root, len(program.roots), allocator)
	graph.root_by_symbol = make(map[Symbol_Id]Root_Id, len(program.root_by_symbol), allocator)
	graph.root_by_storage = make(map[Storage_Id]Root_Id, len(program.root_by_storage), allocator)
	graph.region_of = make(map[Symbol_Id]Region_Set, 8, allocator)
	graph.region_content = make(map[Storage_Id][]Prov_Region_Content, 8, allocator)
	graph.region_aliases = make(map[Symbol_Id][]Prov_Region_Alias, 4, allocator)
	graph.provider_parents = make(map[Symbol_Id]Region_Set, 4, allocator)
	graph.provider_bits = make(map[Symbol_Id]u64, len(program.provider_bits), allocator)
	graph.provider_symbols = make([dynamic]Symbol_Id, allocator)
	graph.provider_paths = make(map[Symbol_Id][]Provider_Path, len(program.provider_paths), allocator)
	graph.provider_moved = make(map[Symbol_Id]u64, 4, allocator)
	graph.temp_provider_bits = make(map[^Expr_Call]u64, len(program.temp_provider_bits), allocator)
	graph.operator_calls = make(map[rawptr]^Expr_Call, len(program.operator_calls), allocator)
	graph.lent_locals = make(map[Symbol_Id]bool, len(program.lent_locals), allocator)
	graph.written_aliases = make(map[Storage_Id][]Written_Alias, 4, allocator)
	graph.call_results = make(map[^Expr_Call]Prov_Call_Result, 8, allocator)
	graph.summary_callees = make([dynamic]Symbol_Id, allocator)
	copy(graph.roots[:], program.roots)
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

prov_effect_begin :: proc(graph: ^Flow_Graph, operation: Prov_Fact_Operation) -> bool {
	if graph.effect_program == nil || graph.effect_depth != 0 { return false }
	append(&graph.effect_program.operations, Prov_Effect_Site{operation, graph.current, graph.expansion})
	graph.effect_depth += 1
	return true
}

prov_effect_end :: proc(graph: ^Flow_Graph, recorded: bool) {
	if recorded { graph.effect_depth -= 1 }
}

prov_effect_value :: proc(graph: ^Flow_Graph, value: Expr) -> Value_Id {
	if graph.effect_program == nil || graph.effect_depth != 0 || value == nil { return 0 }
	id := prov_input_value(graph, value)
	_ = prov_input_transfer(graph, value)
	return id
}

prov_effect_path :: proc(graph: ^Flow_Graph, path: []Proj_Step) -> []Proj_Step {
	if graph.effect_program == nil || graph.effect_depth != 0 { return nil }
	return slice.clone(path, graph.effect_program.alloc)
}

// Borrowed bindings are rebound independently for each case/defer expansion.
prov_forget_region_binding :: proc(graph: ^Flow_Graph, symbol: Symbol_Id) {
	recorded := false
	if prov_effect_active(graph) {
		recorded = prov_effect_begin(graph, Prov_Effect_Forget_Binding{symbol})
	}
	defer prov_effect_end(graph, recorded)
	delete_key(&graph.region_aliases, symbol)
}

prov_merge_provider_parent :: proc(graph: ^Flow_Graph, symbol: Symbol_Id, value: Expr, source: []Proj_Step = nil, storage := false) {
	recorded := false
	if prov_effect_active(graph) {
		recorded = prov_effect_begin(graph, Prov_Effect_Parent{symbol, prov_effect_value(graph, value), prov_effect_path(graph, source), storage})
	}
	defer prov_effect_end(graph, recorded)
	if value == nil { return }
	region := storage ? prov_storage_region(graph, value) : prov_result_region_at(graph, value, source)
	parent := graph.provider_parents[symbol] or_else prov_empty_region(graph)
	region_merge(&parent, region)
	graph.provider_parents[symbol] = parent
}

prov_assign_value_region :: proc(graph: ^Flow_Graph, symbol: Symbol_Id, value: Expr, source: []Proj_Step, storage: bool) {
	recorded := false
	if prov_effect_active(graph) {
		recorded = prov_effect_begin(graph, Prov_Effect_Assign{symbol, prov_effect_value(graph, value), prov_effect_path(graph, source), storage})
	}
	defer prov_effect_end(graph, recorded)
	if value == nil { return }
	region := storage ? prov_storage_region(graph, value) : prov_result_region_at(graph, value, source)
	prov_merge_region_of(graph, symbol, region)
}

prov_store_spread_region :: proc(graph: ^Flow_Graph, destination, value: Expr) {
	recorded := false
	if prov_effect_active(graph) {
		recorded = prov_effect_begin(graph, Prov_Effect_Spread{prov_effect_value(graph, destination), prov_effect_value(graph, value)})
	}
	defer prov_effect_end(graph, recorded)
	region := prov_storage_region(graph, value)
	prov_store_region_set(graph, destination, region, region, prov_owner_name(graph, value), element = true)
}

prov_store_map_key_region :: proc(graph: ^Flow_Graph, destination, value: Expr) {
	recorded := false
	if prov_effect_active(graph) {
		recorded = prov_effect_begin(graph, Prov_Effect_Map_Key{prov_effect_value(graph, destination), prov_effect_value(graph, value)})
	}
	defer prov_effect_end(graph, recorded)
	region := prov_result_region(graph, value)
	owned := prov_result_region_at(graph, value, nil, .Owners)
	prov_store_region_through(graph, destination, region, owned, prov_owner_name(graph, value), {proj_wild(), proj_field(PROJ_MAP_KEY)})
}

prov_replay_fact_operations :: proc(graph: ^Flow_Graph, program: ^Prov_Effect_Program) {
	for site in program.operations {
		graph.current, graph.expansion = site.block, site.expansion
		prov_replay_fact_operation(graph, site.operation)
	}
	program.replays += 1
}

@(private = "file")
prov_replay_fact_operation :: proc(graph: ^Flow_Graph, op: Prov_Fact_Operation) {
	// Each source keeps the checked representation at its operation point,
	// including the raw owner beneath a temporary view.
	first, second: Value_Id
	switch input in op {
	case Prov_Effect_Declare: first = input.value
	case Prov_Effect_Element: first = input.value
	case Prov_Effect_Case: first = input.value
	case Prov_Effect_Targets: first = input.value
	case Prov_Effect_Call: first = input.value
	case Prov_Effect_Store: first, second = input.destination, input.value
	case Prov_Effect_Spread: first, second = input.destination, input.value
	case Prov_Effect_Map_Key: first, second = input.destination, input.value
	case Prov_Effect_Define: first = input.value
	case Prov_Effect_Parent: first = input.value
	case Prov_Effect_Move_Provider: first = input.value
	case Prov_Effect_Assign: first = input.value
	case Prov_Effect_Forget_Binding, Prov_Effect_Borrow_Owner:
	case: unreachable()
	}
	saved_first, saved_second: Prov_Value_Origin
	if first != 0 { saved_first = prov_open_value(graph, first) }
	defer if first != 0 { prov_close_value(saved_first) }
	if second != 0 { saved_second = prov_open_value(graph, second) }
	defer if second != 0 { prov_close_value(saved_second) }
	// The original expression is only the bridge to the remaining checked
	// metadata queries. This never walks an operand or builds control flow.
	switch operation in op {
	case Prov_Effect_Declare:
		value := graph.input.values[int(operation.value)]
		prov_declare_region(graph, operation.symbol, symbol_of(graph.k.c, operation.symbol), value.origin, operation.projected, operation.copies)
	case Prov_Effect_Element:
		prov_bind_element_region(graph, operation.symbol, graph.input.values[int(operation.value)].origin)
	case Prov_Effect_Case:
		prov_bind_case_region(graph, operation.symbol, graph.input.values[int(operation.value)].origin, operation.variants, operation.slot)
	case Prov_Effect_Targets:
		prov_note_alias_source(graph, operation.storage, graph.input.values[int(operation.value)].origin, operation.path)
	case Prov_Effect_Call:
		call := graph.input.values[int(operation.value)].origin.(^Expr_Call)
		switch operation.kind {
		case .Result:
			graph.call_results[call] = Prov_Call_Result{region = prov_call_region(graph, call, call.type), region_content = prov_call_region_content(graph, call)}
		case .Write: prov_call_written_regions(graph, call, prov_input_call(graph, call).signature)
		case .Invalidate: prov_call_written_aliases(graph, call)
		}
	case Prov_Effect_Store:
		prov_store_region(graph, graph.input.values[int(operation.destination)].origin, graph.input.values[int(operation.value)].origin, operation.element)
	case Prov_Effect_Spread:
		prov_store_spread_region(graph, graph.input.values[int(operation.destination)].origin, graph.input.values[int(operation.value)].origin)
	case Prov_Effect_Map_Key:
		prov_store_map_key_region(graph, graph.input.values[int(operation.destination)].origin, graph.input.values[int(operation.value)].origin)
	case Prov_Effect_Define:
		root := prov_root_for_storage(graph, operation.storage)
		prov_define_value_regions(graph, root, operation.path, graph.input.values[int(operation.value)].origin, operation.source, operation.copies, operation.allocated_by)
	case Prov_Effect_Parent:
		prov_merge_provider_parent(graph, operation.symbol, graph.input.values[int(operation.value)].origin, operation.source, operation.storage)
	case Prov_Effect_Move_Provider:
		prov_merge_moved_bits(graph, operation.symbol, graph.input.values[int(operation.value)].origin)
	case Prov_Effect_Assign:
		prov_assign_value_region(graph, operation.symbol, graph.input.values[int(operation.value)].origin, operation.source, operation.storage)
	case Prov_Effect_Forget_Binding:
		prov_forget_region_binding(graph, operation.symbol)
	case Prov_Effect_Borrow_Owner:
		prov_note_borrowed_owner(graph, operation.value)
	case:
		unreachable()
	}
}

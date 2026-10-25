package lokec

import "core:mem/virtual"

normalization_legacy_graph :: proc(k: ^Checker, literal: ^Expr_Proc, mode := Flow_Mode.Lifecycle) -> ^Flow_Graph {
	allocator := k.c.analysis_allocator
	if mode == .Lifecycle || literal == nil || literal.body == nil {
		return build_flow_pass(k, literal, allocator, mode, nil)
	}
	// design.md "Allocator regions and region provenance": region facts are
	// flow-insensitive, but a pass reads them while it walks, so a fact written
	// later in a loop body reaches an earlier read only on the next pass. Facts
	// only grow, so the passes stop. A pass that added facts is reclaimed once
	// they are copied out, so scratch holds one graph, not one per pass, and
	// what it reported while walking is dropped, since the next pass reports it
	// again.
	carry_arena: virtual.Arena
	defer virtual.arena_destroy(&carry_arena)
	carry: ^Flow_Graph
	seeded := 0
	for {
		temp := virtual.arena_temp_begin(&k.c.analysis_arena)
		reported := len(k.c.diagnostics)
		graph := build_flow_pass(k, literal, allocator, mode, carry)
		weight := prov_region_weight(graph)
		if weight == seeded {
			virtual.arena_temp_ignore(temp)
			return graph
		}
		truncate_diagnostics(k.c, reported)
		free_all(virtual.arena_allocator(&carry_arena))
		carry = prov_carry_regions(graph, virtual.arena_allocator(&carry_arena))
		virtual.arena_temp_end(temp)
		seeded = weight
	}
}

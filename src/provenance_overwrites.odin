// design.md "@(allocator_reset)": what a parameter received is gone from a place the
// body wrote on every path to a read, so the read is in what those writes stored and
// not in an allocator the caller supplied there. Region facts merge without regard to
// control flow. The incoming value is added at each read (`prov_add_received_allocator`),
// or seeded into a parameter's own entry (`prov_received_region`), so a read records the
// places written on every path to it, from the construction walk's control flow, which no
// fact changes, and leaves the incoming value out there.
package lokec

import "core:slice"

// A place in a parameter's storage that a direct assignment wrote: a whole parameter
// or a path of struct fields in it.
@(private)
Prov_Overwrite :: struct {
	storage: Storage_Id,
	path:    []Proj_Step,
}

@(private)
Prov_Overwrites :: struct {
	// Each distinct place written, numbered by its position here.
	places:   [dynamic]Prov_Overwrite,
	// Per block, the places its assignments wrote, in order.
	by_block: [dynamic][dynamic]int,
	// Set once the walk is done: a value interned later was not read where the walk
	// stood, so it records nothing.
	walked:   bool,
	// Scratch rows of the solve, per block and one more.
	exit, row: [dynamic]u8,
}

// A finished assignment's direct writes. They take effect once all of its
// destinations are written, so a value the statement read is still the old one.
@(private)
prov_note_overwrites :: proc(graph: ^Flow_Graph, s: ^Stmt_Assign) {
	if graph.current == NO_BLOCK || graph.replaying_facts {
		return
	}
	for target in s.lhs {
		if is_discard(target) {
			continue
		}
		place := prov_input_place(graph, target)
		storage, direct := place.base.(Storage_Id)
		if !direct || storage == 0 || !prov_storage_is_parameter(graph, storage) || !prov_path_is_fields(graph, storage, place.path) {
			continue
		}
		prov_add_overwrite(graph, Prov_Overwrite{storage, place.path})
	}
}

// Whether `storage` is one of this body's parameters, whose contents the caller
// supplied.
@(private = "file")
prov_storage_is_parameter :: proc(graph: ^Flow_Graph, storage: Storage_Id) -> bool {
	sym := symbol_of(graph.k.c, prov_storage(graph, storage).key.symbol)
	return sym != nil && sym.kind == .Parameter
}

// Whether every step of `path` selects a struct field, so a write there replaces
// all that a read at or below it finds. A variant or element step may name a place
// the write did not reach.
@(private = "file")
prov_path_is_fields :: proc(graph: ^Flow_Graph, storage: Storage_Id, path: []Proj_Step) -> bool {
	c := graph.k.c
	type := prov_storage(graph, storage).type
	for step, at in path {
		if step.kind != .Field || step.precision != {} || underlying_kind(c, prov_type_at(c, type, path[:at])) != .Struct {
			return false
		}
	}
	return true
}

@(private = "file")
prov_add_overwrite :: proc(graph: ^Flow_Graph, overwrite: Prov_Overwrite) {
	written := &graph.overwrites
	if written.places == nil {
		written.places = make([dynamic]Prov_Overwrite, graph.alloc)
		written.by_block = make([dynamic][dynamic]int, graph.alloc)
	}
	index := -1
	for place, at in written.places {
		if place.storage == overwrite.storage && slice.equal(place.path, overwrite.path) {
			index = at
			break
		}
	}
	if index < 0 {
		index = len(written.places)
		append(&written.places, Prov_Overwrite{overwrite.storage, slice.clone(overwrite.path, graph.alloc)})
	}
	block := int(graph.current)
	for len(written.by_block) <= block {
		append(&written.by_block, make([dynamic]int, graph.alloc))
	}
	// A block ends where it is linked onward, so what its successors see is all it
	// wrote.
	assert(len(graph.blocks[block].succs) == 0, "an assignment wrote into a block already linked onward")
	append(&written.by_block[block], index)
}

// The paths of `storage` written on every path to the walk's current point, for a
// value interned there, which is where it is read. A loop's back edge only adds
// writes to what its head already had, so the blocks not walked yet change nothing.
@(private)
prov_overwritten_here :: proc(graph: ^Flow_Graph, place: Prov_Place) -> [][]Proj_Step {
	written := &graph.overwrites
	storage, direct := place.base.(Storage_Id)
	if written.walked || !direct || graph.current == NO_BLOCK || graph.replaying_facts {
		return nil
	}
	named := false
	for at in written.places {
		named ||= at.storage == storage
	}
	if !named {
		return nil
	}
	here := prov_overwritten_at(graph, graph.current)
	out := make([dynamic][]Proj_Step, 0, 1, graph.alloc)
	for at, index in written.places {
		if at.storage == storage && bit_get(here, index) {
			append(&out, at.path)
		}
	}
	return out[:]
}

// A must-fact over the blocks walked so far, solved down from everything written: a
// block with no predecessor yet is entered with nothing written, and every other one
// with what each predecessor's exit wrote. The bits of `graph.overwrites.places`
// written at `block`'s end.
@(private = "file")
prov_overwritten_at :: proc(graph: ^Flow_Graph, block: Block_Id) -> []u8 {
	written := &graph.overwrites
	bytes := (len(written.places) + 7) / 8
	blocks := len(graph.blocks)
	if written.exit == nil {
		written.exit = make([dynamic]u8, graph.alloc)
		written.row = make([dynamic]u8, graph.alloc)
	}
	resize(&written.exit, blocks * bytes)
	resize(&written.row, bytes)
	exit, row := written.exit[:], written.row[:]
	// A write of a place writes every place below it, so one branch writing `h` and
	// the other `h.allocator` both wrote `h.allocator`.
	gen :: proc(written: ^Prov_Overwrites, row: []u8, block: int) {
		if block >= len(written.by_block) {
			return
		}
		for index in written.by_block[block] {
			at := written.places[index]
			for below, other in written.places {
				if below.storage == at.storage && path_has_exact_prefix(below.path, at.path) {
					bit_mark(row, other)
				}
			}
		}
	}
	for at in 0 ..< blocks {
		out := exit[at * bytes:][:bytes]
		if len(graph.blocks[at].preds) > 0 {
			slice.fill(out, 0xff)
		} else {
			slice.fill(out, 0)
			gen(written, out, at)
		}
	}
	for changed := true; changed; {
		changed = false
		for at in 0 ..< blocks {
			preds := graph.blocks[at].preds
			if len(preds) == 0 {
				continue
			}
			slice.fill(row, 0xff)
			for pred in preds {
				from := exit[int(pred) * bytes:][:bytes]
				for &byte, offset in row {
					byte &= from[offset]
				}
			}
			gen(written, row, at)
			out := exit[at * bytes:][:bytes]
			if !slice.equal(row, out) {
				copy(out, row)
				changed = true
			}
		}
	}
	return exit[int(block) * bytes:][:bytes]
}

// Whether a read of `value` at `path` of its root, a path below the value's own
// place, finds only what a write in this body put there.
@(private)
prov_received_replaced :: proc(graph: ^Flow_Graph, value: Value_Id, path: []Proj_Step) -> bool {
	if value == 0 {
		return false
	}
	for written in prov_value(graph, value).replaced {
		if path_has_exact_prefix(path, written) {
			return true
		}
	}
	return false
}

// A parameter that keeps its argument's region has it in `region_of` from the start
// (`prov_seed_parameter_region`), where its whole-value writes merge too. `direct`, that
// entry, read by `value` at `path`, leaves the seed out where every path to the read
// assigned the place, unless a write may have put the parameter's own region back.
@(private)
prov_received_region :: proc(graph: ^Flow_Graph, id: Symbol_Id, direct: Region_Set, value: Value_Id, path: []Proj_Step) -> Region_Set {
	out := direct
	if index, replaced := prov_seed_replaced(graph, id, value, path); replaced {
		region_remove_param(&out, index)
	}
	return out
}

// Whether the read of parameter `id` by `value` at `path` finds none of what it received,
// and the region index that names that. Only a read that may find it hands it on, so a
// write can put it back only from a read this is false for (`prov_parameter_restored`).
@(private)
prov_seed_replaced :: proc(graph: ^Flow_Graph, id: Symbol_Id, value: Value_Id, path: []Proj_Step) -> (index: int, replaced: bool) {
	if !prov_received_replaced(graph, value, path) {
		return
	}
	sym := symbol_of(graph.k.c, id)
	if sym == nil || sym.kind != .Parameter || type_is_region_provider(graph.k.c, sym.type) {
		return
	}
	own: bool
	index, own = slice.linear_search(graph.param_symbols, id)
	if !own || index >= REGION_PARAM_LIMIT || prov_parameter_restored(graph, id, index) {
		return
	}
	return index, true
}

// A write that may hold what parameter `id` received: one merged into its own entry
// with its region, which a copy of it read before an assignment carries.
@(private)
prov_note_restored :: proc(graph: ^Flow_Graph, id: Symbol_Id, set: Region_Set) {
	if set.params == 0 || graph.restored[id] {
		return
	}
	if sym := symbol_of(graph.k.c, id); sym == nil || sym.kind != .Parameter {
		return
	}
	if index, own := slice.linear_search(graph.param_symbols, id); own && region_has_param(set, index) {
		graph.restored[id] = true
	}
}

// Whether a write may have put back what parameter `id`, at region `index`, received:
// one merged into its own entry (`Prov_Facts.restored`), or one into a place of it
// with its region, or copied from another place of it (`Prov_Region_Content.from`).
@(private = "file")
prov_parameter_restored :: proc(graph: ^Flow_Graph, id: Symbol_Id, index: int) -> bool {
	if graph.restored[id] {
		return true
	}
	storage := graph.input.storage_ids[Written_Storage{symbol = id}]
	for content in graph.region_content[storage] {
		if _, copied := content.from.?; copied || region_has_param(content.region, index) {
			return true
		}
	}
	return false
}

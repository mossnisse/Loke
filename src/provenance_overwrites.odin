// design.md "@(allocator_reset)": what a parameter received is gone from a place the
// body wrote on every path to a read, so the read is in what those writes stored and
// not in an allocator the caller supplied there. Region facts merge without regard to
// control flow. The incoming value is added at each read (`prov_add_received_allocator`),
// or seeded into a parameter's own entry (`prov_seed_parameter_region`), so a read records
// the places written on every path to it, from the construction walk's control flow, which
// no fact changes, and leaves the incoming value out there (`prov_received_replaced`,
// `prov_received_region`).
package lokec

import "core:mem"
import "core:slice"

// A place in a parameter's storage that a direct assignment wrote: a whole parameter
// or a path of struct fields in it.
@(private)
Prov_Overwrite :: struct {
	storage: Storage_Id,
	path:    []Proj_Step,
}

// Where a value is read: a block of the walk, and how many of the writes its
// assignments made come first. A value read after the walk has no block.
@(private)
Prov_Read_Point :: struct {
	block:  Block_Id,
	writes: int,
}

@(private)
Prov_Overwrites :: struct {
	// Each distinct place written, numbered by its position here.
	places:  [dynamic]Prov_Overwrite,
	// Per block, the places written on every path into it (`prov_link_overwrites`),
	// and the places its own assignments wrote, in order.
	entry:   map[Block_Id][]int,
	wrote:   map[Block_Id][dynamic]int,
	// Where the value whose transfer is being described was read, so what describing
	// it interns is read there too (`prov_value_transfer`).
	reading: Maybe(Prov_Read_Point),
	// Set once the walk is done (`prov_end_overwrites`).
	walked:  bool,
}

@(private)
new_prov_overwrites :: proc(allocator: mem.Allocator) -> Prov_Overwrites {
	return Prov_Overwrites {
		places = make([dynamic]Prov_Overwrite, allocator),
		entry = make(map[Block_Id][]int, allocator),
		wrote = make(map[Block_Id][dynamic]int, allocator),
	}
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

// The walk is done: a value interned from here on, outside the description of one
// read during it, was not read where the walk stood, so it records nothing.
@(private)
prov_end_overwrites :: proc(graph: ^Flow_Graph) {
	graph.overwrites.walked = true
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
	// A block ends where it is linked onward, so what its successors see is all it
	// wrote.
	assert(len(graph.blocks[int(graph.current)].succs) == 0, "an assignment wrote into a block already linked onward")
	wrote := written.wrote[graph.current]
	if wrote == nil {
		wrote = make([dynamic]int, graph.alloc)
	}
	append(&wrote, index)
	written.wrote[graph.current] = wrote
}

// The edge the walk links from `from` to `to` carries what `from` wrote on every path
// through it. Every predecessor of a block but a loop's back edge is linked before
// the walk enters the block, and a back edge comes from a block the head reaches,
// which wrote all the head was entered with, so a block's entry is final once the
// walk reads in it or links it onward.
@(private)
prov_link_overwrites :: proc(graph: ^Flow_Graph, from, to: Block_Id) {
	written := &graph.overwrites
	if len(written.places) == 0 {
		// Every entry is empty so far, and a meet with an empty one stays so.
		return
	}
	block := graph.blocks[int(to)]
	exit := prov_exit_overwrites(graph, from)
	if len(block.preds) == 1 {
		written.entry[to] = exit
		return
	}
	entry := written.entry[to]
	if len(block.succs) > 0 {
		assert(prov_overwrites_cover(written, exit, entry), "a back edge left out a place its loop head was entered with")
		return
	}
	// A place written on every path is one each side wrote, itself or a place above
	// it: one branch writing `h` and the other `h.allocator` both wrote `h.allocator`.
	met := make([dynamic]int, 0, min(len(entry), len(exit)), graph.alloc)
	for index in entry {
		if prov_overwrite_covered(written, exit, index) {
			append(&met, index)
		}
	}
	for index in exit {
		if !slice.contains(met[:], index) && prov_overwrite_covered(written, entry, index) {
			append(&met, index)
		}
	}
	written.entry[to] = met[:]
}

// The places written on every path to `block`'s end. An entry is never changed in
// place, so a block with no writes of its own shares its entry.
@(private = "file")
prov_exit_overwrites :: proc(graph: ^Flow_Graph, block: Block_Id) -> []int {
	written := &graph.overwrites
	entry, wrote := written.entry[block], written.wrote[block]
	if len(wrote) == 0 {
		return entry
	}
	out := make([dynamic]int, 0, len(entry) + len(wrote), graph.alloc)
	append(&out, ..entry)
	for index in wrote {
		if !slice.contains(out[:], index) {
			append(&out, index)
		}
	}
	return out[:]
}

// Whether `set` wrote place `index`, or a place above it.
@(private = "file")
prov_overwrite_covered :: proc(written: ^Prov_Overwrites, set: []int, index: int) -> bool {
	place := written.places[index]
	for other in set {
		above := written.places[other]
		if above.storage == place.storage && path_has_exact_prefix(place.path, above.path) {
			return true
		}
	}
	return false
}

@(private = "file")
prov_overwrites_cover :: proc(written: ^Prov_Overwrites, set, places: []int) -> bool {
	for index in places {
		if !prov_overwrite_covered(written, set, index) {
			return false
		}
	}
	return true
}

// Where the walk stands, for a value interned now, which is where it is read; or,
// while a transfer is described, where the described value was read.
@(private)
prov_read_point :: proc(graph: ^Flow_Graph) -> Prov_Read_Point {
	written := &graph.overwrites
	if point, describing := written.reading.?; describing {
		return point
	}
	if written.walked || graph.current == NO_BLOCK || graph.replaying_facts {
		return {block = NO_BLOCK}
	}
	return {graph.current, len(written.wrote[graph.current])}
}

// The paths of `place`'s parameter storage written on every path to `point`.
@(private)
prov_overwritten_at :: proc(graph: ^Flow_Graph, place: Prov_Place, point: Prov_Read_Point) -> [][]Proj_Step {
	storage, direct := place.base.(Storage_Id)
	if !direct || point.block == NO_BLOCK {
		return nil
	}
	written := &graph.overwrites
	out: [dynamic][]Proj_Step
	add :: proc(graph: ^Flow_Graph, out: ^[dynamic][]Proj_Step, storage: Storage_Id, index: int) {
		at := graph.overwrites.places[index]
		if at.storage != storage {
			return
		}
		if out^ == nil {
			out^ = make([dynamic][]Proj_Step, 0, 1, graph.alloc)
		}
		append(out, at.path)
	}
	for index in written.entry[point.block] {
		add(graph, &out, storage, index)
	}
	for index in written.wrote[point.block][:point.writes] {
		add(graph, &out, storage, index)
	}
	return out[:]
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
	own: bool
	index, own = prov_param_index(graph, id)
	if !own || index >= REGION_PARAM_LIMIT || type_is_region_provider(graph.k.c, symbol_of(graph.k.c, id).type) ||
	   prov_parameter_restored(graph, id, index, path) {
		return
	}
	return index, true
}

// The region index of `id` among this body's parameters, if it is one; only a
// parameter is among them.
@(private)
prov_param_index :: proc(graph: ^Flow_Graph, id: Symbol_Id) -> (index: int, found: bool) {
	return slice.linear_search(graph.param_symbols, id)
}

// A write that may hold what parameter `id` received: one merged into its own entry
// with its region, which a copy of it read before an assignment carries.
@(private)
prov_note_restored :: proc(graph: ^Flow_Graph, id: Symbol_Id, set: Region_Set) {
	if set.params == 0 || graph.restored[id] {
		return
	}
	if index, own := prov_param_index(graph, id); own && region_has_param(set, index) {
		graph.restored[id] = true
	}
}

// Whether a write may have put back what parameter `id`, at region `index`, received
// at `path`: one merged into its own entry (`Prov_Facts.restored`), or one into a
// place of it that the read reaches, with its region or copied from another place of
// it (`Prov_Region_Content.from`). A place the read does not reach is not part of
// what it finds (`prov_region_content_at`).
@(private = "file")
prov_parameter_restored :: proc(graph: ^Flow_Graph, id: Symbol_Id, index: int, path: []Proj_Step) -> bool {
	if graph.restored[id] {
		return true
	}
	storage := graph.input.storage_ids[Written_Storage{symbol = id}]
	for content in graph.region_content[storage][:] {
		if !paths_overlap(content.path, path) {
			continue
		}
		if _, copied := content.from.?; copied || region_has_param(content.region, index) {
			return true
		}
	}
	return false
}

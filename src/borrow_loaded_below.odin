// design.md "Weakening and reborrows": which carriers each slot's value was loaded at or
// below, on every path to here, as of those carriers' current values. One slot stands for a
// field of every node a pointer chain reaches, as a list's `next`, so a cursor stepped by
// `cur = cur^.next` holds a copy out of that slot, and so does whatever is loaded further
// down through it. This tells such a load, which is below the cursor's own value and so
// never the place the cursor was copied from, from a read of that place, which competes
// with the cursor (`loads_below`). A carrier's new value ends what was below its old one,
// and a store of a carrier may relink what any of them reach, so it ends all of it, unless
// nothing it stores could be one of the carriers a load reads (`store_may_relink`).
package lokec

import "core:mem"
import "core:slice"

@(private)
Loaded_Below :: struct {
	// Per slot, a handle of `rows`, whose bits are anchors.
	held:      []u32,
	rows:      Interned_Rows,
	row_bytes: int,
	// Each slot's anchor bit, or -1. Only a slot holding a reborrow is asked about, as the
	// cursor a load may be below.
	anchor:  []int,
	// The anchors a row may hold, one bit each, so a new value of a carrier nothing was
	// loaded below ends nothing.
	used:    []u8,
	// Scratch rows.
	value, edit: []u8,
	// An interned row without one anchor, by `u64(row) << 32 | u64(anchor)`.
	cleared: map[u64]u32,
	// The carrier types of the values the body's loads read, each once: only a store
	// that may land in a carrier of one of these relinks what a load reaches.
	links: [dynamic]Type_Id,
}

@(private)
loaded_below_make :: proc(state: ^Prov_Solve) {
	graph := state.graph
	below := &state.below
	below.anchor = make([]int, state.slots, graph.alloc)
	for &bit in below.anchor {
		bit = -1
	}
	anchors := 0
	for link in graph.reborrows {
		if below.anchor[link.derived] < 0 && holds_one_value(graph.prov_slots[link.derived]) {
			below.anchor[link.derived] = anchors
			anchors += 1
		}
	}
	below.row_bytes = (anchors + 7) / 8
	below.held = make([]u32, state.slots, graph.alloc)
	below.rows = interned_rows_make(below.row_bytes, graph.alloc)
	below.used = make([]u8, below.row_bytes, graph.alloc)
	below.value = make([]u8, below.row_bytes, graph.alloc)
	below.edit = make([]u8, below.row_bytes, graph.alloc)
	below.cleared = make(map[u64]u32, 16, graph.alloc)
	below.links = make([dynamic]Type_Id, graph.alloc)
	if anchors == 0 {
		return // no event reads the fact (`run_loaded_below_event`)
	}
	explored := make([dynamic]Type_Id, graph.alloc)
	for block in graph.blocks {
		for event in block.prov {
			if event.kind != .Load {
				continue
			}
			if event.load != .Deep {
				append_unique(&below.links, slot_carrier_type(graph, event.slot))
				continue
			}
			// A deep load reads every carrier below the ones it goes through, at any depth.
			for carrier in event.into {
				add_links_below(graph.k.c, &below.links, &explored, slot_carrier_type(graph, carrier))
			}
		}
	}
}

// Every carrier type in what a carrier of `type` points at, and below those, each
// carrier type `explored` once.
@(private = "file")
add_links_below :: proc(c: ^Compiler, links, explored: ^[dynamic]Type_Id, type: Type_Id) {
	if slice.contains(explored[:], type) {
		return
	}
	append(explored, type)
	kind := underlying_kind(c, type)
	if type == INVALID_TYPE || (kind != .Pointer && kind != .Slice) {
		append_unique(links, INVALID_TYPE) // what it reads is not known
		return
	}
	for path in carrier_pointee_shape(c, type) {
		if path.truncated {
			append_unique(links, INVALID_TYPE)
			continue
		}
		append_unique(links, path.type)
		if below := underlying_kind(c, path.type); below == .Pointer || below == .Slice {
			add_links_below(c, links, explored, path.type)
		}
	}
}

// Whether a store of `carried` may change one of the carriers a load reads, and so
// relink what was loaded below a cursor. Each carrier it holds lands only in a slot that
// could hold that type (`carrier_may_land_in`), so storing a `^int` beside a list of
// `^mut Node` relinks nothing. An unknown type may relink anything.
@(private = "file")
store_may_relink :: proc(state: ^Prov_Solve, carried: Type_Id) -> bool {
	c := state.graph.k.c
	if carried == INVALID_TYPE {
		return true
	}
	// A carrier's own shape is itself, at no path.
	for path in carrier_shape(c, carried) {
		if path.truncated { return true }
		for link in state.below.links {
			if carrier_may_land_in(c, link, path.type) { return true }
		}
	}
	return false
}

// A slot standing for many places, as one for every node's `next`, has no one value to be
// below: what is below one of them may be where another was copied from.
@(private = "file")
holds_one_value :: proc(slot: Prov_Slot) -> bool {
	return slot.kind != .Caller && slot.kind != .Literal && !slot.content_truncated && !path_is_indistinct(slot.path)
}

// Whether `slot`'s value was loaded at or below `anchor`'s current value on every path.
@(private)
loaded_below :: proc(state: ^Prov_Solve, slot, anchor: int) -> bool {
	below := &state.below
	bit := below.anchor[anchor]
	return bit >= 0 && bit_get(below.rows.rows[below.held[slot]], bit)
}

// A must-fact: a block's entry holds what every predecessor's exit does. `first` takes
// the first visited predecessor's as it is.
@(private)
join_loaded_below :: proc(state: ^Prov_Solve, from: [][]u32, first: bool) {
	below := &state.below
	if first {
		block_table_put(from, below.held)
		return
	}
	if from == nil {
		mem.zero_slice(below.held)
		return
	}
	interned_join(&below.rows, below.held, from, below.edit, every = true)
}

@(private)
run_loaded_below_event :: proc(state: ^Prov_Solve, event: Prov_Event) {
	below := &state.below
	if below.row_bytes == 0 {
		return
	}
	#partial switch event.kind {
	case .Def, .Load:
		// Loaded through `into`, or copied from `sources`: below each of them, and below
		// what each is below.
		carriers := event.kind == .Load ? event.into : event.sources
		value := below.value
		mem.zero_slice(value)
		for carrier, index in carriers {
			row := index == 0 ? value : below.edit
			copy(row, below.rows.rows[below.held[carrier]])
			if bit := below.anchor[carrier]; bit >= 0 {
				bit_mark(row, bit)
			}
			if index > 0 {
				for &byte, at in value {
					byte &= below.edit[at]
				}
			}
		}
		end_loaded_below(state, event.slot)
		if bit := below.anchor[event.slot]; bit >= 0 {
			bit_clear(value, bit)
		}
		below.held[event.slot] = intern_row(&below.rows, value)
		bytes_or(below.used, value)
	case .Publish, .Rearrange:
		if event.kind == .Publish && len(event.sources) == 0 {
			for slot in event.replaces {
				end_loaded_below(state, slot)
				below.held[slot] = 0
			}
			return
		}
		if event.kind == .Rearrange || store_may_relink(state, event.carried) {
			mem.zero_slice(below.held)
			return
		}
		// The slots it replaces still take new values.
		for slot in event.replaces {
			end_loaded_below(state, slot)
			below.held[slot] = 0
		}
	}
}

// `slot` takes a new value, so nothing is below its old one any more.
@(private = "file")
end_loaded_below :: proc(state: ^Prov_Solve, slot: int) {
	below := &state.below
	bit := below.anchor[slot]
	if bit < 0 || !bit_get(below.used, bit) {
		return
	}
	for &row in below.held {
		if row == 0 || !bit_get(below.rows.rows[row], bit) {
			continue
		}
		key := u64(row) << 32 | u64(bit)
		if cleared, found := below.cleared[key]; found {
			row = cleared
			continue
		}
		copy(below.edit, below.rows.rows[row])
		bit_clear(below.edit, bit)
		cleared := intern_row(&below.rows, below.edit)
		below.cleared[key] = cleared
		row = cleared
	}
}

// design.md "Weakening and reborrows": which carriers each slot's value was loaded at or
// below, on every path to here, as of those carriers' current values. One slot stands for a
// field of every node a pointer chain reaches, as a list's `next`, so a cursor stepped by
// `cur = cur^.next` holds a copy out of that slot, and so does whatever is loaded further
// down through it. This tells such a load, which is below the cursor's own value and so
// never the place the cursor was copied from, from a read of that place, which competes
// with the cursor (`loads_below`). A carrier's new value ends what was below its old one,
// and a store of a carrier may relink what any of them reach, so it ends all of it.
package lokec

import "core:mem"

@(private)
Loaded_Below :: struct {
	// Per slot, a handle of `rows`, whose bits are anchors.
	held:      []u32,
	rows:      Interned_Rows,
	row_bytes: int,
	// Each slot's anchor bit, or -1. Only a slot holding a reborrow is asked about, as the
	// cursor a load may be below.
	anchor:  []int,
	// Whether a row may hold each anchor, so a new value of a carrier nothing was loaded
	// below ends nothing.
	used:    []bool,
	// Scratch rows.
	value, edit: []u8,
	// An interned row without one anchor, by `u64(row) << 32 | u64(anchor)`.
	cleared: map[u64]u32,
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
	below.used = make([]bool, anchors, graph.alloc)
	below.value = make([]u8, below.row_bytes, graph.alloc)
	below.edit = make([]u8, below.row_bytes, graph.alloc)
	below.cleared = make(map[u64]u32, 16, graph.alloc)
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
	for page, at in from {
		for row, index in page {
			slot := at * BLOCK_TABLE_PAGE + index
			held := below.held[slot]
			if row == held || held == 0 {
				continue
			}
			if row == 0 {
				below.held[slot] = 0
				continue
			}
			copy(below.edit, below.rows.rows[held])
			for &byte, offset in below.edit {
				byte &= below.rows.rows[row][offset]
			}
			below.held[slot] = intern_row(&below.rows, below.edit)
		}
	}
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
		for byte, at in value {
			if byte == 0 {
				continue
			}
			for bit in 0 ..< 8 {
				if byte & (1 << uint(bit)) != 0 {
					below.used[at * 8 + bit] = true
				}
			}
		}
	case .Publish, .Rearrange:
		if event.kind == .Publish && len(event.sources) == 0 {
			for slot in event.replaces {
				end_loaded_below(state, slot)
				below.held[slot] = 0
			}
			return
		}
		mem.zero_slice(below.held)
	}
}

// `slot` takes a new value, so nothing is below its old one any more.
@(private = "file")
end_loaded_below :: proc(state: ^Prov_Solve, slot: int) {
	below := &state.below
	bit := below.anchor[slot]
	if bit < 0 || !below.used[bit] {
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

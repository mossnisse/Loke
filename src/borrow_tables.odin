// What the provenance solver keeps at each block's boundaries. A walk works on one flat
// table per fact, and a block keeps what that table held on entering it and on leaving
// it. Most of a body's slots are the same at the two ends of a block and at the two ends
// of an edge, so a block shares pages of its tables with its neighbors, and a row of
// reaching loans, wider than everything else in the body, is kept once however many slots
// and blocks hold it. A body's tables then grow with what changes between blocks, not with
// blocks times slots times loans.
package lokec

import "base:runtime"
import "core:mem"
import "core:slice"

// Elements per page. A byte table's page is the size of a cache line, and a table of
// handles or spans is small enough that one changed slot copies little.
@(private)
BLOCK_TABLE_PAGE :: 64

// The bytes of the element at `index` are the page's, in order: comparing them is what
// `slice.equal` would do, and a page compared with itself costs nothing.
@(private = "file")
same_page :: #force_inline proc(a, b: []$T) -> bool {
	if raw_data(a) == raw_data(b) {
		return true
	}
	return runtime.memory_compare(raw_data(a), raw_data(b), len(a) * size_of(T)) == 0
}

// The page of `flat` holding table page `index`.
@(private = "file")
flat_page :: #force_inline proc(flat: []$T, index: int) -> []T {
	low := index * BLOCK_TABLE_PAGE
	return flat[low:min(low + BLOCK_TABLE_PAGE, len(flat))]
}

// Keeps `flat` in `table`: a page it already holds stays, one the same as `like`'s, a
// neighboring block's, is shared with that, and only a page neither has is copied.
@(private)
block_table_take :: proc(table: ^[][]$T, flat: []T, like: [][]T, allocator: mem.Allocator) {
	if table^ == nil {
		table^ = make([][]T, (len(flat) + BLOCK_TABLE_PAGE - 1) / BLOCK_TABLE_PAGE, allocator)
	}
	for &page, index in table^ {
		value := flat_page(flat, index)
		if page != nil && same_page(page, value) {
			continue
		}
		if like != nil && same_page(like[index], value) {
			page = like[index]
			continue
		}
		page = slice.clone(value, allocator)
	}
}

// A table nothing has been kept in holds zeros.
@(private)
block_table_put :: proc(table: [][]$T, flat: []T) {
	if table == nil {
		mem.zero_slice(flat)
		return
	}
	for page, index in table {
		copy(flat[index * BLOCK_TABLE_PAGE:], page)
	}
}

@(private)
block_table_equal :: proc(table: [][]$T, flat: []T) -> bool {
	if table == nil {
		for byte in slice.reinterpret([]u8, flat) {
			if byte != 0 {
				return false
			}
		}
		return true
	}
	for page, index in table {
		if !same_page(page, flat_page(flat, index)) {
			return false
		}
	}
	return true
}

@(private)
block_table_at :: #force_inline proc(table: [][]$T, index: int) -> T {
	return table[index / BLOCK_TABLE_PAGE][index % BLOCK_TABLE_PAGE]
}

// Distinct rows of bits, each kept once, whatever number of slots and blocks holds it.
// Handle 0 is the row of no bits.
@(private)
Interned_Rows :: struct {
	rows: [dynamic][]u8,
	ids:  map[string]u32,
}

@(private)
interned_rows_make :: proc(row_bytes: int, allocator: mem.Allocator) -> Interned_Rows {
	interned := Interned_Rows{
		rows = make([dynamic][]u8, 0, 16, allocator),
		ids  = make(map[string]u32, allocator),
	}
	intern_row(&interned, make([]u8, row_bytes, allocator))
	return interned
}

@(private)
intern_row :: proc(interned: ^Interned_Rows, row: []u8) -> u32 {
	if id, found := interned.ids[string(row)]; found {
		return id
	}
	allocator := interned.rows.allocator
	kept := slice.clone(row, allocator)
	id := u32(len(interned.rows))
	append(&interned.rows, kept)
	interned.ids[string(kept)] = id
	return id
}

// `reach_handles[slot]` of a row written since it was last interned.
@(private = "file")
ROW_WRITTEN :: max(u32)

// `reach_row` for a row about to change.
@(private)
reach_row_written :: proc(state: ^Prov_Solve, reach: []u8, slot: int) -> []u8 {
	if state.reach_handles[slot] != ROW_WRITTEN {
		state.reach_handles[slot] = ROW_WRITTEN
		append(&state.reach_written, slot)
	}
	return reach_row(state, reach, slot)
}

// Gives every row written since the last call its handle again, so `reach_handles` says
// what `reach` holds.
@(private)
reach_settle :: proc(state: ^Prov_Solve) {
	for slot in state.reach_written {
		state.reach_handles[slot] = intern_row(&state.reach_rows, reach_row(state, state.reach, slot))
	}
	clear(&state.reach_written)
}

// Makes `reach` hold `table`, touching only the rows that differ. A row written since it
// was last interned differs from every handle, so a walk's changes are undone here too.
@(private)
reach_load :: proc(state: ^Prov_Solve, table: [][]u32) {
	clear(&state.reach_written)
	if table == nil {
		for &handle, slot in state.reach_handles {
			if handle != 0 {
				mem.zero_slice(reach_row(state, state.reach, slot))
				handle = 0
			}
		}
		return
	}
	for page, index in table {
		held := flat_page(state.reach_handles, index)
		if same_page(page, held) {
			continue
		}
		for handle, at in page {
			if held[at] != handle {
				copy(reach_row(state, state.reach, index * BLOCK_TABLE_PAGE + at), state.reach_rows.rows[handle])
				held[at] = handle
			}
		}
	}
}

// Joins `table` into `reach`, writing only the rows that differ.
@(private)
reach_join :: proc(state: ^Prov_Solve, table: [][]u32) {
	for page, index in table {
		held := flat_page(state.reach_handles, index)
		if same_page(page, held) {
			continue
		}
		for handle, at in page {
			if handle != 0 && held[at] != handle {
				bytes_or(reach_row_written(state, state.reach, index * BLOCK_TABLE_PAGE + at), state.reach_rows.rows[handle])
			}
		}
	}
}

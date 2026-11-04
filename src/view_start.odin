// Where a local view starts in the range a loan lends, and which definitions of it
// reach each use (design.md "Values that contain borrows"). It takes only a
// `Flow_Graph`.
package lokec

import "core:mem"
import "core:slice"

// Where the element `at` names is among those `loan` lends, counted from the
// first, when that is known: for a view parameter, relative to its own loan,
// at its index; for a local view, relative to a loan of a range, at its
// index past where the view starts in that range (`view_start_of`). Only
// the start must be known, not how many elements the view holds: an index
// past the end of a shorter view panics, so wherever the access goes on, the
// index names the same element. One past every length the view may have
// names none.
@(private)
view_element_in :: proc(graph: ^Flow_Graph, at: Prov_View_At, loan: int) -> (i64, bool) {
	if at.slot == 0 {
		return 0, false
	}
	if at.loan > 0 {
		return at.index, at.loan - 1 == loan
	}
	lent := graph.loans[loan]
	if len(lent.path) == 0 || !path_is_exact(lent.path[:len(lent.path) - 1]) {
		return 0, false
	}
	// A constant range lends that many elements; a wildcard, as an open
	// borrow's (`Prov_View_Def.open`), any number from the first.
	last := lent.path[len(lent.path) - 1]
	range: i64
	switch {
	case last.precision != {}:
		return 0, false
	case last.kind == .Range && last.hi > last.lo:
		range = last.hi - last.lo
	case last.kind == .Wild:
		range = VIEW_OPEN_RANGE
	case:
		return 0, false
	}
	offset, length, present, known := view_start_of(graph, at.slot - 1, at.reaching, loan, range)
	if !present || !known || at.index >= length {
		return 0, false
	}
	return offset + at.index, true
}

// The `range` of a loan whose last step is a wildcard (`view_element_in`):
// where the view starts is all that is known of it, and no constant index
// lies past its end.
@(private = "file")
VIEW_OPEN_RANGE :: max(i64)

// The loan `one`, narrowed to the one element of the range it lends that
// `at` names when that is known (`view_element_in`), as a store into or a
// load out of `s[k]` names, with `s` a local view.
@(private)
view_element_loan :: proc(graph: ^Flow_Graph, at: Prov_View_At, one: int) -> (Prov_Loan, bool) {
	loan := graph.loans[one]
	element, known := view_element_in(graph, at, one)
	if !known {
		return loan, false
	}
	at_element := loan.path[len(loan.path) - 1].lo + element
	path := make([]Proj_Step, len(loan.path), graph.alloc)
	copy(path, loan.path)
	path[len(path) - 1] = proj_range(at_element, at_element + 1)
	loan.path = path
	return loan, true
}

// Where the definitions of a view slot start in the range a loan lends, and at
// most how many elements they view, as `view_start_of` has it: not `present`
// when none takes the loan, and `present` but not `known` when they do not
// agree on one start.
Prov_View_Start :: struct {
	offset, length: i64,
	present, known: bool,
}

// What `view_start_of` is asked.
Prov_View_Query :: struct {
	slot, loan: int,
	range:      i64,
	reaching:   rawptr,
	count:      int,
}

// A definition `view_start_order` found: `key` names it among `view_defs`,
// and `readable` says, for a reslice, that its source may be worked out
// (`view_start_readable`).
@(private = "file")
Prov_View_Node :: struct {
	key:      [2]int,
	readable: bool,
}

// A view `view_start_order` is walking: the definitions `reaching` of
// `slot`, of which `next` is the first not yet taken, on behalf of the
// reslice definition `node`, or none for the view the store names.
@(private = "file")
Prov_View_Walk :: struct {
	node:     Prov_View_Node,
	slot:     int,
	reaching: []int,
	next:     int,
}

// design.md "Values that contain borrows": where in the `range` elements
// `loan` lends the view held in `slot` starts, and at most how many it views,
// whenever `slot` holds that loan where the definitions `reaching` of it
// reach (`solve_view_defs`). All that take the loan must agree where it starts,
// though not on its length; nothing may borrow the slot, which would let a store
// through a pointer change it unseen. `present` is false when no definition takes
// the loan, and `known` false when it is not known where the view starts.
//
// A reslice is worked out from the view it reads, and around a loop that may be
// what it made itself, so the answer is the least fixed point: a known answer
// holds of every execution by induction over its definitions. So `s = &mut s[:2]`
// in a loop keeps the start, and `s = &mut s[1:]` does not, as what it makes
// disagrees with what it read on the next round.
@(private = "file")
view_start_of :: proc(graph: ^Flow_Graph, slot: int, reaching: []int, loan: int, range: i64) -> (offset, length: i64, present, known: bool) {
	// Every walk asks again, and the answer is settled once `solve_view_defs` ran.
	query := Prov_View_Query{slot, loan, range, raw_data(reaching), len(reaching)}
	if answer, found := graph.view_answers[query]; found {
		return answer.offset, answer.length, answer.present, answer.known
	}
	if !view_start_readable(graph, slot, reaching) {
		graph.view_answers[query] = Prov_View_Start{present = true}
		return 0, 0, true, false
	}
	order, cyclic := view_start_order(graph, slot, reaching)
	lengths := view_start_lengths(graph, order, cyclic, loan, range)
	starts := make(map[[2]int]Prov_View_Start, len(order), graph.alloc)
	for changed := true; changed; changed = cyclic && changed {
		changed = false
		for node in order {
			def := graph.view_defs[node.key[0]][node.key[1]]
			source: Prov_View_Start
			longest: i64
			if !def.unknown && def.from > 0 {
				source = node.readable ? view_start_join(graph, &starts, def.from - 1, def.reaching) : Prov_View_Start{present = true}
				longest = view_start_longest(graph, lengths, def.from - 1, def.reaching)
			}
			old := starts[node.key]
			start := view_start_agree(old, view_start_def(def, source, longest, loan, range))
			if start != old {
				starts[node.key] = start
				changed = true
			}
		}
	}
	view := view_start_join(graph, &starts, slot, reaching)
	graph.view_answers[query] = view
	return view.offset, view.length, view.present, view.known
}

// The most elements each of the definitions `order` holds may view of what
// `loan` lends, for those that may take it. The least fixed point, as
// `view_start_of`'s is, of a value that only grows: what a reslice may view
// grows with what its source may, and what it may not view from it, past a
// constant end, it panics on. Going round a cycle only shortens a view, so the
// longest comes by a path without one and the rounds are bounded.
@(private = "file")
view_start_lengths :: proc(graph: ^Flow_Graph, order: []Prov_View_Node, cyclic: bool, loan: int, range: i64) -> map[[2]int]i64 {
	lengths := make(map[[2]int]i64, len(order), graph.alloc)
	for changed := true; changed; changed = cyclic && changed {
		changed = false
		for node in order {
			def := graph.view_defs[node.key[0]][node.key[1]]
			length := i64(-1)
			if !def.unknown && def.from > 0 {
				source := node.readable ? view_start_longest(graph, lengths, def.from - 1, def.reaching) : -1
				hi := def.hi < 0 ? source : min(def.hi, source)
				if source >= 0 && def.lo >= 0 && def.lo <= hi {
					length = hi - def.lo
				}
			} else if start := view_start_def(def, {}, 0, loan, range); start.known {
				length = start.length
			}
			if old, seen := lengths[node.key]; length >= 0 && (!seen || old < length) {
				lengths[node.key] = length
				changed = true
			}
		}
	}
	return lengths
}

// The longest of the definitions `reaching` of `slot` (`view_start_lengths`),
// or -1 when none may take the loan.
@(private = "file")
view_start_longest :: proc(graph: ^Flow_Graph, lengths: map[[2]int]i64, slot: int, reaching: []int) -> i64 {
	longest := i64(-1)
	for index in reaching {
		if length, seen := lengths[[2]int{slot, index}]; seen {
			longest = max(longest, length)
		}
	}
	return longest
}

// False for an unrecorded slot, or one a loan borrows, as a store through that loan
// changes it unseen.
@(private = "file")
view_start_readable :: proc(graph: ^Flow_Graph, slot: int, reaching: []int) -> bool {
	return slot in graph.view_defs && len(reaching) > 0 && !graph.view_borrowed[graph.prov_slots[slot].symbol]
}

// The definitions the view the definitions `reaching` of `slot` make depends
// on, sources before what reslices them where no cycle prevents that, and
// whether any does. A reslice chain may be as long as the procedure, so the
// walk keeps a stack of views rather than recursing.
@(private = "file")
view_start_order :: proc(graph: ^Flow_Graph, slot: int, reaching: []int) -> (order: []Prov_View_Node, cyclic: bool) {
	nodes := make([dynamic]Prov_View_Node, 0, 8, graph.alloc)
	walks := make([dynamic]Prov_View_Walk, 0, 8, graph.alloc)
	// Each definition met, and whether it is done rather than being walked.
	met := make(map[[2]int]bool, graph.alloc)
	append(&walks, Prov_View_Walk{slot = slot, reaching = reaching})
	for len(walks) > 0 {
		walk := &walks[len(walks) - 1]
		if walk.next == len(walk.reaching) {
			if len(walks) > 1 {
				met[walk.node.key] = true
				append(&nodes, walk.node)
			}
			pop(&walks)
			continue
		}
		defs := graph.view_defs[walk.slot]
		index := walk.reaching[walk.next]
		walk.next += 1
		if index < 0 || index >= len(defs) {
			continue
		}
		key := [2]int{walk.slot, index}
		if done, seen := met[key]; seen {
			cyclic ||= !done
			continue
		}
		def := defs[index]
		node := Prov_View_Node{key = key}
		if !def.unknown && def.from > 0 && view_start_readable(graph, def.from - 1, def.reaching) {
			node.readable = true
			met[key] = false
			append(&walks, Prov_View_Walk{node = node, slot = def.from - 1, reaching = def.reaching})
			continue
		}
		met[key] = true
		append(&nodes, node)
	}
	return nodes[:], cyclic
}

// What the definitions `reaching` of `slot` have come to agree on
// (`view_start_of`). One not recorded (`Prov_View_Def.reaching`) may have
// made anything.
@(private = "file")
view_start_join :: proc(graph: ^Flow_Graph, starts: ^map[[2]int]Prov_View_Start, slot: int, reaching: []int) -> (view: Prov_View_Start) {
	defs := graph.view_defs[slot]
	for index in reaching {
		if index < 0 || index >= len(defs) {
			return Prov_View_Start{present = true}
		}
		view = view_start_agree(view, starts^[[2]int{slot, index}])
	}
	return
}

// What holds of a view either of `a` and `b` may have made: where they agree
// it starts, and at most as many elements as the longer views.
@(private = "file")
view_start_agree :: proc(a, b: Prov_View_Start) -> Prov_View_Start {
	if !a.present {
		return b
	}
	if !b.present {
		return a
	}
	if !a.known || !b.known || a.offset != b.offset {
		return Prov_View_Start{present = true}
	}
	return Prov_View_Start{offset = a.offset, length = max(a.length, b.length), present = true, known = true}
}

// Where `def` starts, `source` being the view a reslice reads and `longest` the
// most elements that may view (`view_start_lengths`). A reslice past them always
// panics, and is taken as not known; one within them starts where its constant
// start says whatever length the source has, as it panics where the source is
// shorter. An open borrow starts where it says (`Prov_View_Def.open`), and only a
// loan whose range the analysis cannot name, as `VIEW_OPEN_RANGE`, may be one.
@(private = "file")
view_start_def :: proc(def: Prov_View_Def, source: Prov_View_Start, longest: i64, loan: int, range: i64) -> Prov_View_Start {
	start: Prov_View_Start
	switch {
	case def.unknown:
		start.present = true
	case def.from > 0:
		hi := def.hi < 0 ? longest : def.hi
		if source.present {
			start.present = true
			if source.known && def.lo >= 0 && def.lo <= hi && hi <= longest {
				start.offset, start.length, start.known = source.offset + def.lo, hi - def.lo, true
			}
		}
	case int(def.loan) == loan:
		start.present = true
		if def.open == (range == VIEW_OPEN_RANGE) && def.lo >= 0 && def.lo <= range {
			first := def.open ? def.lo : 0
			start.offset, start.length, start.known = first, range - first, true
		}
	}
	return start
}

// design.md "Values that contain borrows", "Weakening and reborrows": which
// definitions of each followed local view reach each element store, place loan and
// reslice, so `view_start_of` takes only those. A slot has a bit per recorded
// definition and one for any other.
@(private)
solve_view_defs :: proc(graph: ^Flow_Graph) {
	first := make(map[int]int, graph.alloc)
	followed := make([dynamic]int, 0, 4, graph.alloc)
	bits := 0
	follow :: proc(graph: ^Flow_Graph, first: ^map[int]int, followed: ^[dynamic]int, bits: ^int, slot: int) {
		if slot not_in first {
			first[slot] = bits^
			bits^ += len(graph.view_defs[slot]) + 1
			append(followed, slot)
		}
	}
	for block in graph.blocks {
		for event in block.prov {
			if at := event.element; at.slot > 0 && at.loan == 0 {
				follow(graph, &first, &followed, &bits, at.slot - 1)
			}
		}
	}
	if len(followed) == 0 {
		return
	}
	for index := 0; index < len(followed); index += 1 {
		defs := graph.view_defs[followed[index]]
		for def in defs {
			if def.from > 0 {
				follow(graph, &first, &followed, &bits, def.from - 1)
			}
		}
	}
	graph.view_answers = make(map[Prov_View_Query]Prov_View_Start, graph.alloc)
	graph.view_borrowed = make(map[Symbol_Id]bool, graph.alloc)
	for loan in graph.loans {
		graph.view_borrowed[graph.roots[int(loan.root)].symbol] = true
	}
	width := (bits + 7) / 8
	entry := make([][]u8, len(graph.blocks), graph.alloc)
	exit := make([][]u8, len(graph.blocks), graph.alloc)
	for id in 0 ..< len(graph.blocks) {
		entry[id] = make([]u8, width, graph.alloc)
		exit[id] = make([]u8, width, graph.alloc)
	}
	visited := make([]bool, len(graph.blocks), graph.alloc)
	queue := block_queue_from_entry(graph)
	row := make([]u8, width, graph.alloc)
	for id in block_queue_pop(&queue) {
		block := graph.blocks[id]
		mem.zero_slice(row)
		for predecessor in block.preds {
			if visited[int(predecessor)] {
				bytes_or(row, exit[int(predecessor)])
			}
		}
		if id == 0 {
			for def in graph.entry_defs {
				if base, found := first[def.slot]; found {
					bit_mark(row, base + len(graph.view_defs[def.slot]))
				}
			}
		}
		copy(entry[id], row)
		for event in block.prov {
			view_def_step(graph, first, event, row)
		}
		if visited[id] && slice.equal(exit[id], row) {
			continue
		}
		copy(exit[id], row)
		visited[id] = true
		block_queue_wake(&queue, block.succs[:])
	}
	for block, id in graph.blocks {
		if !visited[id] {
			continue
		}
		copy(row, entry[id])
		for &event in block.prov {
			if at := &event.element; at.slot > 0 && at.loan == 0 {
				at.reaching = view_defs_reaching(graph, first, at.slot - 1, row, nil)
				if event.kind == .Def && event.place_loan > 0 {
					graph.place_loans[event.place_loan - 1].element.reaching = at.reaching
				}
			}
			if event.kind == .Def && event.view_def > 0 && event.slot in first {
				defs := graph.view_defs[event.slot]
				if def := &defs[event.view_def - 1]; def.from > 0 {
					def.reaching = view_defs_reaching(graph, first, def.from - 1, row, def.reaching)
				}
			}
			view_def_step(graph, first, event, row)
		}
	}
}

// What `event` leaves of the definitions reaching (`solve_view_defs`): a
// definition of a followed slot replaces its others, and so does anything
// else that writes it, standing for a definition not recorded.
@(private = "file")
view_def_step :: proc(graph: ^Flow_Graph, first: map[int]int, event: Prov_Event, row: []u8) {
	if event.kind != .Def && event.kind != .Load {
		return
	}
	base, followed := first[event.slot]
	if !followed {
		return
	}
	count := len(graph.view_defs[event.slot])
	for bit in base ..= base + count {
		bit_clear(row, bit)
	}
	bit_mark(row, base + (event.kind == .Def && event.view_def > 0 ? event.view_def - 1 : count))
}

// The definitions of `slot` in `row`, added to those in `into`.
@(private = "file")
view_defs_reaching :: proc(graph: ^Flow_Graph, first: map[int]int, slot: int, row: []u8, into: []int) -> []int {
	base := first[slot]
	out := make([dynamic]int, 0, len(into) + 1, graph.alloc)
	append(&out, ..into)
	for index in 0 ..= len(graph.view_defs[slot]) {
		if bit_get(row, base + index) && !slice.contains(out[:], index) {
			append(&out, index)
		}
	}
	return out[:]
}

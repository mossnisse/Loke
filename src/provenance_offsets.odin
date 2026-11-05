// Where a carrier may point below the storage it names: places, merging past the
// limits, and the definitions reaching a block (design.md "Minimum provenance
// precision").
package lokec

// Which places a named slot's definitions may have left it pointing at where,
// for `prov_reaching_offsets`. Bit `i` of a mask stands for place `i` of the
// slot's `places`, and `PROV_REACH_UNKNOWN` for a definition that names no storage
// or for the procedure's entry. `defined` is what the last definition in a block
// left, and `exits` what reaches a walked block's end, for as long as its `epoch`
// is the block's. The rest is the walk's scratch.
Prov_Reach :: struct {
	places:  map[int][dynamic]Prov_Offset,
	defined: map[Prov_Reach_Key]u128,
	exits:   map[Prov_Reach_Key]Prov_Reach_Exit,
	frames:  [dynamic]Prov_Reach_Frame,
	blocks:  [dynamic]Prov_Reach_Block,
	scc:     [dynamic]Block_Id,
	stale:   [dynamic]Block_Id,
	walk:    int,
	visit:   int,
}

Prov_Reach_Key :: struct {
	slot:  int,
	block: Block_Id,
}

Prov_Reach_Exit :: struct {
	mask:  u128,
	epoch: int,
}

// A block the walk is in: the next of its predecessors to take, the places
// found so far, and its order of discovery and the lowest one it reaches back
// to.
Prov_Reach_Frame :: struct {
	block:        Block_Id,
	next:         int,
	mask:         u128,
	index, low:   int,
}

// A block as the walks know it. `epoch` counts what may have changed what
// reaches its end. In the walk numbered `walk` it was taken: `mask` reaches its
// end, it was discovered `index`th, and `waiting` when it waits on a block
// still being walked, which closes a cycle. `visit` numbers the last
// invalidation to reach it (`prov_reach_invalidate`).
Prov_Reach_Block :: struct {
	mask:    u128,
	index:   int,
	walk:    int,
	visit:   int,
	epoch:   int,
	waiting: bool,
}

// The paths below the storage `slots` name that a value made of them may
// point at (`Prov_Slot.offsets`): any of theirs, as a borrow's place loan
// snapshot points at the place it is of. A slot standing for a borrow's
// access, which names no storage, takes no part. False when no slot names
// storage. `merged` when places past the limits were taken as a prefix they
// share, here or in a slot's own offsets.
@(private)
prov_value_offset :: proc(graph: ^Flow_Graph, slots: []int) -> (out: []Prov_Offset, found: bool, merged: bool) {
	for slot in slots {
		if prov_slot_is_through(graph, slot) {
			continue
		}
		offsets, slot_merged := prov_carrier_offsets(graph, slot)
		merged ||= slot_merged
		if found {
			joined: bool
			out, joined = prov_union_offsets(graph, out, offsets)
			merged ||= joined
		} else {
			out = offsets
		}
		found = true
	}
	return
}

// Records what a definition of `slot` from `sources` may point at, besides
// what the slot's earlier definitions may, and, for a named slot, what this
// one does (`prov_reaching_offsets`).
@(private)
prov_note_offset :: proc(graph: ^Flow_Graph, slot: int, sources: []int) {
	at, found, merged := prov_value_offset(graph, sources)
	entry := &graph.prov_slots[slot]
	reach := &graph.offset_reach
	if entry.symbol != INVALID_SYMBOL && (found || slot in reach.places) {
		reach.defined[Prov_Reach_Key{slot, graph.current}] = prov_reach_mask(graph, slot, at if found else nil)
		if graph.blocks[graph.current].reach_known {
			prov_reach_invalidate(graph, graph.current)
		}
	}
	if !found {
		return
	}
	if entry.offsets != nil {
		joined: bool
		entry.offsets, joined = prov_union_offsets(graph, entry.offsets, at)
		merged ||= joined
	} else {
		entry.offsets = at
	}
	entry.offsets_merged ||= merged
}

// The most places of one storage a value is told apart at, and the most in
// all; past either, places are merged into a prefix they share
// (`prov_union_offsets`). They are the specification's minimums for chosen
// places, so a rejection the merge may cause names them (design.md "Minimum
// provenance precision", `Precision_Limit.Places`).
@(private)
PROV_OFFSET_LIMIT :: 8

@(private)
PROV_OFFSET_TOTAL :: 64

// The most places of a slot's definitions `prov_reaching_offsets` tells apart,
// each a bit of a mask beside `PROV_REACH_UNKNOWN`; past them, the borrow takes
// what every definition of the slot may point at. That is above
// `PROV_OFFSET_TOTAL`, past which the slot's gathered offsets have merged and
// say so.
@(private = "file")
PROV_REACHING_PLACES :: 127

@(private = "file")
PROV_REACH_UNKNOWN :: u128(1) << 127

// The bits of the places of `offsets` among those of `slot` (`Prov_Reach`), or
// `PROV_REACH_UNKNOWN` when it names no storage.
@(private = "file")
prov_reach_mask :: proc(graph: ^Flow_Graph, slot: int, offsets: []Prov_Offset) -> (mask: u128) {
	reach := &graph.offset_reach
	if slot not_in reach.places {
		reach.places[slot] = make([dynamic]Prov_Offset, 0, 2, graph.alloc)
	}
	if len(offsets) == 0 {
		return PROV_REACH_UNKNOWN
	}
	places := &reach.places[slot]
	each: for at in offsets {
		for place, index in places {
			if place.storage == at.storage && prov_same_path(place.path, at.path) {
				if index < PROV_REACHING_PLACES {
					mask |= u128(1) << uint(index)
				}
				continue each
			}
		}
		// Past the bound the slot keeps one more, which marks it untracked.
		if len(places) <= PROV_REACHING_PLACES {
			if len(places) < PROV_REACHING_PLACES {
				mask |= u128(1) << uint(len(places))
			}
			append(places, at)
		}
	}
	return
}

// What `slot` may point at where the event about to be emitted is, and
// whether a limit merged places on the way.
@(private)
prov_carrier_offsets :: proc(graph: ^Flow_Graph, slot: int) -> (offsets: []Prov_Offset, merged: bool) {
	offsets, merged = prov_slot_offsets(graph, slot), graph.prov_slots[slot].offsets_merged
	if reaching, reaching_merged, found := prov_reaching_offsets(graph, slot, offsets); found {
		return reaching, merged || reaching_merged
	}
	return
}

// design.md "Minimum provenance precision": a named slot whose definitions
// point into several storages, as `p` for `p := s; ...; p = t`, is taken to
// point where the event about to be emitted is at what the definitions
// reaching there do (`prov_reaching_mask`), so a place taken through it
// counts against only the storage it names there. Each place of `all`, what
// the slot's definitions recorded so far may point at, that none of theirs
// covers is kept too, so `all` still bounds the paths taken. Not found for a
// slot of one storage, past `PROV_REACHING_PLACES`, or where a definition that
// names no storage, or the procedure's entry, may reach.
@(private)
prov_reaching_offsets :: proc(graph: ^Flow_Graph, slot: int, all: []Prov_Offset) -> (out: []Prov_Offset, merged: bool, found: bool) {
	several := false
	for at in all {
		several ||= at.storage != all[0].storage
	}
	if !several || graph.current == NO_BLOCK {
		return
	}
	places, recorded := graph.offset_reach.places[slot]
	if !recorded || len(places) > PROV_REACHING_PLACES {
		return
	}
	mask := prov_reaching_mask(graph, slot)
	if mask == 0 || mask & PROV_REACH_UNKNOWN != 0 {
		return
	}
	reaching := make([dynamic]Prov_Offset, 0, len(places), graph.alloc)
	for place, index in places {
		if mask & (u128(1) << uint(index)) != 0 {
			prov_add_offset(&reaching, place)
		}
	}
	merged = prov_merge_past_limits(&reaching)
	out, found = reaching[:], true
	extra: [dynamic]Prov_Offset
	for at in all {
		if !prov_offset_covered_in(out, at.path, -1) {
			if extra == nil {
				extra = make([dynamic]Prov_Offset, 0, len(all), graph.alloc)
			}
			append(&extra, at)
		}
	}
	if extra != nil {
		joined: bool
		out, joined = prov_union_offsets(graph, out, extra[:])
		merged ||= joined
	}
	return
}

// The places `slot` may point at, by its definitions that reach the end of the
// current block so far, as a mask of `Prov_Reach`: a block's last definition,
// or else what reaches the end of each of its predecessors, the procedure's
// entry reaching as `PROV_REACH_UNKNOWN`. A depth-first walk over predecessors
// that keeps finished strongly connected components in `exits` until
// `prov_reach_invalidate`.
@(private = "file")
prov_reaching_mask :: proc(graph: ^Flow_Graph, slot: int) -> u128 {
	reach := &graph.offset_reach
	start := graph.current
	if defined, own := reach.defined[Prov_Reach_Key{slot, start}]; own {
		return defined
	}
	prov_reach_track_blocks(graph)
	clear(&reach.frames)
	clear(&reach.scc)
	reach.walk += 1
	discovered := 0
	prov_reach_enter(graph, start, discovered)
	for {
		top := &reach.frames[len(reach.frames) - 1]
		preds := graph.blocks[int(top.block)].preds
		if top.next < len(preds) {
			pred := preds[top.next]
			top.next += 1
			taken := reach.blocks[int(pred)]
			key := Prov_Reach_Key{slot, pred}
			if taken.walk == reach.walk {
				top.mask |= taken.mask
				if taken.waiting {
					top.low = min(top.low, taken.index)
				}
			} else if exit, memo := reach.exits[key]; memo && exit.epoch == taken.epoch {
				top.mask |= exit.mask
			} else if defined, own := reach.defined[key]; own {
				top.mask |= defined
				graph.blocks[int(pred)].reach_known = true
			} else {
				discovered += 1
				prov_reach_enter(graph, pred, discovered)
			}
			continue
		}
		frame := pop(&reach.frames)
		if frame.low == frame.index {
			// The first block of a cycle, done with all of it.
			for {
				member := pop(&reach.scc)
				at := &reach.blocks[int(member)]
				at.mask, at.waiting = frame.mask, false
				if frame.block != start {
					reach.exits[Prov_Reach_Key{slot, member}] = Prov_Reach_Exit{frame.mask, at.epoch}
					graph.blocks[int(member)].reach_known = true
				}
				if member == frame.block {
					break
				}
			}
		} else {
			at := &reach.blocks[int(frame.block)]
			at.mask, at.waiting = frame.mask, true
		}
		if len(reach.frames) == 0 {
			return frame.mask
		}
		parent := &reach.frames[len(reach.frames) - 1]
		parent.mask |= frame.mask
		parent.low = min(parent.low, frame.low)
	}
}

@(private = "file")
prov_reach_enter :: proc(graph: ^Flow_Graph, block: Block_Id, index: int) {
	reach := &graph.offset_reach
	mask := PROV_REACH_UNKNOWN if len(graph.blocks[int(block)].preds) == 0 else 0
	append(&reach.frames, Prov_Reach_Frame{block = block, mask = mask, index = index, low = index})
	append(&reach.scc, block)
	at := &reach.blocks[int(block)]
	at.index, at.walk, at.mask, at.waiting = index, reach.walk, 0, true
}

// Gives every block so far its entry in `Prov_Reach.blocks`, which only a
// procedure with a carrier of several storages pays for.
@(private = "file")
prov_reach_track_blocks :: proc(graph: ^Flow_Graph) {
	reach := &graph.offset_reach
	if cap(reach.blocks) < len(graph.blocks) {
		reserve(&reach.blocks, 2 * len(graph.blocks))
	}
	if len(reach.blocks) < len(graph.blocks) {
		resize(&reach.blocks, len(graph.blocks))
	}
}

// `block` gained a predecessor or a definition, which may change what reaches
// its end and the end of every block after it, and nothing else: drops what
// the walks kept for those alone, so the blocks before a loop stay known when
// its head gains its back edge, and each loop is walked anew only once.
@(private)
prov_reach_invalidate :: proc(graph: ^Flow_Graph, block: Block_Id) {
	reach := &graph.offset_reach
	prov_reach_track_blocks(graph)
	reach.visit += 1
	clear(&reach.stale)
	reach.blocks[int(block)].visit = reach.visit
	append(&reach.stale, block)
	for len(reach.stale) > 0 {
		next := pop(&reach.stale)
		reach.blocks[int(next)].epoch += 1
		graph.blocks[int(next)].reach_known = false
		for successor in graph.blocks[int(next)].succs {
			if reach.blocks[int(successor)].visit != reach.visit {
				reach.blocks[int(successor)].visit = reach.visit
				append(&reach.stale, successor)
			}
		}
	}
}

// A slot whose definitions name no storage points at the whole of what it
// names, which counts as storage of its own.
@(private = "file")
prov_slot_offsets :: proc(graph: ^Flow_Graph, slot: int) -> []Prov_Offset {
	if offsets := graph.prov_slots[slot].offsets; offsets != nil {
		return offsets
	}
	whole := make([]Prov_Offset, 1, graph.alloc)
	whole[0].storage = slot
	return whole
}

// design.md "Places and overlap": a load's `path` is below what its carriers point
// at, and the storage their loans name is what a load reads. So `h^.to` after
// `h := &mut r^.b` reads `r^.b.to`, and no other field's. Nil when they point at the
// whole of that storage. A prefix places were merged into may be above where `path`
// starts, so it is read whole.
@(private)
prov_load_places :: proc(graph: ^Flow_Graph, carriers: []int, path: []Proj_Step) -> [][]Proj_Step {
	pointing := false
	for carrier in carriers {
		pointing ||= graph.prov_slots[carrier].offsets != nil
	}
	if !pointing {
		return nil
	}
	offsets, found, merged := prov_value_offset(graph, carriers)
	if !found {
		return nil
	}
	places := prov_offset_paths(graph, offsets)
	if len(places) == 1 && len(places[0]) == 0 {
		return nil
	}
	if !merged {
		for &place in places {
			place = prov_concat_path(graph, place, path)
		}
	}
	return places
}

// The places of `offsets`, apart from which storage each was reached in, as a
// place loan and an access through carriers take them.
@(private)
prov_offset_paths :: proc(graph: ^Flow_Graph, offsets: []Prov_Offset) -> [][]Proj_Step {
	places := make([dynamic]Prov_Offset, 0, len(offsets), graph.alloc)
	for at in offsets {
		prov_add_offset(&places, Prov_Offset{path = at.path})
	}
	out := make([][]Proj_Step, len(places), graph.alloc)
	for at, index in places {
		out[index] = at.path
	}
	return out
}

// What a value pointing at `offsets` may wrongly be taken to point at: places
// merged past the limits, and, holding places of several storages, those of
// one storage in another (`Prov_Offset`).
@(private)
prov_offset_precision :: proc(offsets: []Prov_Offset, merged: bool) -> (loss: Precision_Loss) {
	if merged {
		loss |= {.Places}
	}
	for at in offsets {
		for other in offsets {
			if other.storage != at.storage && !prov_offset_covered_in(offsets, other.path, at.storage) {
				return loss | {.Storages}
			}
		}
	}
	return
}

// The places of `a` and those of `b`, a place inside another of the same
// storage taken as that one. Past the limit for one storage, two of its places
// sharing the longest prefix, the first such pair among equals, are taken as
// that prefix until few enough are left, so `[inner, a]` and `[inner, b]`
// become `[inner]` while a place outside `inner` stays apart; past the limit
// in all, two of any storage are. Each place of `a` and `b` stays inside one
// of the result. `merged` when a limit took any.
@(private)
prov_union_offsets :: proc(graph: ^Flow_Graph, a, b: []Prov_Offset) -> (union_of: []Prov_Offset, merged: bool) {
	if prov_offsets_cover(a, b) {
		return a, false
	}
	if prov_offsets_cover(b, a) {
		return b, false
	}
	out := make([dynamic]Prov_Offset, 0, len(a) + len(b), graph.alloc)
	for at in a {
		prov_add_offset(&out, at)
	}
	for at in b {
		prov_add_offset(&out, at)
	}
	merged = prov_merge_past_limits(&out)
	return out[:], merged
}

// Takes places past the limits in `out` as prefixes they share
// (`prov_union_offsets`), and whether it took any.
@(private = "file")
prov_merge_past_limits :: proc(out: ^[dynamic]Prov_Offset) -> (merged: bool) {
	for {
		first, second := prov_offsets_past_limit(out[:])
		if first < 0 {
			return
		}
		shared := Prov_Offset{prov_common_prefix(out[first].path, out[second].path), out[first].storage}
		ordered_remove(out, second)
		ordered_remove(out, first)
		prov_add_offset(out, shared)
		merged = true
	}
}

// The two places `prov_union_offsets` merges next, the first before the
// second, or -1 when `offsets` are within the limits.
@(private = "file")
prov_offsets_past_limit :: proc(offsets: []Prov_Offset) -> (first, second: int) {
	if len(offsets) <= PROV_OFFSET_LIMIT {
		return -1, -1
	}
	storage, past := -1, len(offsets) > PROV_OFFSET_TOTAL
	if !past {
		for at in offsets {
			count := 0
			for other in offsets {
				count += 1 if other.storage == at.storage else 0
			}
			if count > PROV_OFFSET_LIMIT {
				storage, past = at.storage, true
				break
			}
		}
	}
	if !past {
		return -1, -1
	}
	first, second = -1, -1
	longest := -1
	for i in 0 ..< len(offsets) {
		for j in i + 1 ..< len(offsets) {
			if storage >= 0 && (offsets[i].storage != storage || offsets[j].storage != storage) {
				continue
			}
			if shared := len(prov_common_prefix(offsets[i].path, offsets[j].path)); shared > longest {
				first, second, longest = i, j, shared
			}
		}
	}
	return
}

@(private = "file")
prov_add_offset :: proc(out: ^[dynamic]Prov_Offset, offset: Prov_Offset) {
	if prov_offset_covered_in(out[:], offset.path, offset.storage) {
		return
	}
	kept := 0
	for at in out {
		if at.storage != offset.storage || !path_has_exact_prefix(at.path, offset.path) {
			out[kept] = at
			kept += 1
		}
	}
	resize(out, kept)
	append(out, offset)
}

// Whether every place of `inner` is inside one of `outer` of the same storage,
// or of any with `any_storage`.
@(private)
prov_offsets_cover :: proc(outer, inner: []Prov_Offset, any_storage := false) -> bool {
	for at in inner {
		if !prov_offset_covered_in(outer, at.path, -1 if any_storage else at.storage) {
			return false
		}
	}
	return true
}

// Whether `path` is inside one of the places of `offsets` of `storage`, or of
// any when `storage` is -1.
@(private = "file")
prov_offset_covered_in :: proc(offsets: []Prov_Offset, path: []Proj_Step, storage: int) -> bool {
	for at in offsets {
		if (storage < 0 || at.storage == storage) && path_has_exact_prefix(path, at.path) {
			return true
		}
	}
	return false
}

@(private = "file")
prov_common_prefix :: proc(a, b: []Proj_Step) -> []Proj_Step {
	length := 0
	for length < min(len(a), len(b)) && same_step(a[length], b[length]) {
		length += 1
	}
	return a[:length]
}

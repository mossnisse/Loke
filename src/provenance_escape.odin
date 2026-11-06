// What a store or a call lets escape: a borrow stored where it outlives the
// statement, an owner stored beyond the region backing it, and the regions a call
// writes or a moved owner leaves (design.md "Allocator regions and region
// provenance").
package lokec

import "core:fmt"
import "core:mem"
import "core:slice"

// A borrow stored where it outlives the statement, resolved as a place so fields,
// elements, and writes through an alias are all seen.
@(private)
prov_retain_escape :: proc(graph: ^Flow_Graph, target: Expr, sources: []int, span: Span) {
	if len(sources) == 0 {
		return
	}
	root, _, ok := prov_place_of(graph, target)
	// A view binding or a destination carrier retains in the storage it names.
	through := ok ? prov_root_view(graph, root) : prov_retain_through_carrier(graph, target)
	if len(through) > 0 {
		prov_emit(graph, Prov_Event {
			kind    = .Retain,
			span    = span,
			sources = sources,
			root    = NO_ROOT,
			into    = through,
		})
		return
	}
	if !ok { return }
	descriptor := graph.roots[int(root)]
	into := retain_kind_for_root(descriptor.kind)
	if into == .None {
		return
	}
	prov_emit(graph, Prov_Event {
		kind    = .Retain,
		span    = span,
		sources = sources,
		root    = root,
		retain  = into,
		verb    = descriptor.name,
	})
}

// The slots of the carrier a destination is written through (`p^.view`,
// `d[0].view`), or nil when the chain stays in lexical storage.
@(private)
prov_retain_through_carrier :: proc(graph: ^Flow_Graph, place: Expr) -> []int {
	if carrier := prov_place_carrier(graph, prov_input_value(graph, place)); carrier != 0 {
		return prov_carrier_slots(graph, prov_value(graph, carrier).origin)
	}
	return nil
}

// The last carrier crossed on the way to this place. Loading a carrier from
// that storage is a separate step from finding the storage itself.
@(private)
prov_place_carrier :: proc(graph: ^Flow_Graph, place: Value_Id) -> Value_Id {
	carrier, _ := prov_value(graph, place).place.base.(Value_Id)
	return carrier
}

// The slots holding a carrier value, without reading it.
@(private)
prov_carrier_slots :: proc(graph: ^Flow_Graph, e: Expr) -> []int {
	if ident, is_ident := e.(^Expr_Ident); is_ident {
		if slot, is_carrier := prov_slot_for_symbol(graph, ident.symbol); is_carrier {
			return prov_one(graph, slot)
		}
	}
	if root, path, ok := prov_place_of(graph, e); ok {
		return prov_content_at(graph, root, path)
	}
	return prov_retain_through_carrier(graph, e)
}

// An owner backed by a region the procedure received may not be returned,
// assigned to `static`, `thread_local`, or file-scope storage (design.md).
@(private)
prov_region_escape :: proc(graph: ^Flow_Graph, target: Expr, value: Value_Id, source: []Proj_Step, copies: bool) {
	prov_event(graph, Prov_Event_Region_Escape{prov_input_value(graph, target), value, slice.clone(source, graph.alloc), copies, place_root_symbol(target)})
}

// Escape checks use the same copied fields as a store, without including facts
// from later assignments to the destination (design.md "Allocator regions and region provenance").
@(private)
prov_copied_owner_region :: proc(graph: ^Flow_Graph, value: Value_Id, source: []Proj_Step, copies: bool, allocator: Region_Set) -> Region_Set {
	owned := Region_Set{}
	if value == 0 { return owned }
	for field in prov_result_region_fields(graph, value, prov_value(graph, value).type, source, copies, allocator) {
		if !field.handle { region_merge(&owned, field.region) }
	}
	return owned
}

@(private)
prov_region_escape_set :: proc(graph: ^Flow_Graph, target: Value_Id, region: Region_Set, owner: string) {
	if !type_is_managed(graph.k.c, prov_value(graph, target).type) {
		return
	}
	root, _, ok := prov_value_place_of(graph, target)
	if !ok {
		return
	}
	prov_region_escape_into(graph, expr_span(prov_value(graph, target).origin), graph.roots[int(root)].symbol, region, owner)
}

// The type of the value at `path` in a value of `type`, or of the innermost
// value the path is known to stay in.
@(private)
prov_type_at :: proc(c: ^Compiler, type: Type_Id, path: []Proj_Step) -> Type_Id {
	current, _ := prov_type_along(c, type, path)
	return current
}

// `prov_type_at`, and how many steps of `path` the value has. Only a step that a
// record, union, map, or array it reaches has not, as an element of a record,
// leaves some out; below a type the walk does not look into, as a pointer
// parameter's pointee, every step counts.
@(private)
prov_type_along :: proc(c: ^Compiler, type: Type_Id, path: []Proj_Step) -> (current: Type_Id, named: int) {
	current = type
	for step in path {
		if payload := shared_payload_type(c, current); payload != INVALID_TYPE && step.kind == .Wild {
			current = payload
			named += 1
			continue
		}
		info := underlying_info(c, current)
		if info == nil {
			return current, len(path)
		}
		#partial switch info.kind {
		case .Struct:
			if step.kind != .Field || step.lo < 0 || int(step.lo) >= len(info.fields) {
				return
			}
			field := symbol_of(c, info.fields[int(step.lo)])
			if field == nil {
				return current, len(path)
			}
			current = field.type
		case .Union:
			if step.kind != .Field || step.lo < 0 || int(step.lo) >= len(info.variants) { return }
			current = info.variants[int(step.lo)]
		case .Map:
			if step.kind == .Field {
				current = step.lo == PROJ_MAP_KEY ? info.key : info.element
			} else if step.kind != .Range && step.kind != .Wild { return }
		case .Array, .Dynamic_Array, .Slice, .Box:
			if step.kind != .Range && step.kind != .Wild {
				return
			}
			current = info.element
		case:
			return current, len(path)
		}
		named += 1
	}
	return
}

// Whether storing an owner of `region` into the variable `id`, at `span`, lets
// it outlive that region; reports it if so.
@(private)
prov_region_escape_into :: proc(graph: ^Flow_Graph, span: Span, id: Symbol_Id, region: Region_Set, owner: string) -> bool {
	for alias in graph.region_aliases[id] {
		if alias.root == NO_ROOT {
			if prov_region_escape_through(graph, span, region, owner) { return true }
		} else if prov_region_escape_into(graph, span, graph.roots[int(alias.root)].symbol, region, owner) {
			return true
		}
	}
	sym := symbol_of(graph.k.c, id)
	if sym == nil {
		return false
	}
	storage := ""
	param := sym.kind == .Parameter
	switch {
	case symbol_outlives_bodies(sym): storage = storage_phrase(sym.duration)
	case param:                       storage = "storage the caller owns"
	}
	if storage == "" {
		return false
	}
	// A received region may back what the caller owns; only a local one ends
	// first. An owner moved in is kept only as far as its parameter allows.
	moved, set := prov_moved_parameter(graph, region, param ? .Stored : .Static)
	if moved == "" && !region_has_local(set) && (param || !region_is_parameter_backed(set)) {
		return false
	}
	// design.md "Required diagnostics" names the escaping owner; the
	// destination follows its kind of storage.
	prov_emit(graph, Prov_Event {
		kind   = .Region_Escape,
		span   = span,
		verb   = owner,
		name   = fmt.aprintf("`%s` (%s)", identifier_text(graph.k.c, sym.name), storage, allocator = graph.alloc),
		region = set,
		moved  = moved,
	})
	return true
}

// A value's loans written into a place, as assignment writes them.
@(private)
prov_store_loans :: proc(graph: ^Flow_Graph, target: Expr, sources: []int, span: Span) {
	root, path, ok := prov_place_of(graph, target)
	if !ok {
		return
	}
	prov_retain_escape(graph, target, sources, span)
	type := prov_type(graph, target)
	if ident, is_ident := target.(^Expr_Ident); is_ident {
		if slot, is_carrier := prov_slot_for_symbol(graph, ident.symbol); is_carrier {
			prov_define_one_content(graph, slot, sources, span)
			return
		}
	}
	if written := prov_content_at(graph, root, path); len(written) > 0 {
		prov_define_content(graph, written, sources, span, path, type)
	}
}

// design.md "Allocator regions and region provenance": a stored owner keeps its
// region. A place records it as content, so resetting the region while the
// place is live is caught, and storage outliving the region rejects it. A
// carrier's target is not known here, so an owner of a local region may not be
// written through one. `element` stores into a container's elements.
@(private)
prov_store_region :: proc(graph: ^Flow_Graph, destination: Value_Id, value: Value_Id, element := false) {
	recorded := prov_effect_active(graph)
	if recorded { prov_effect_begin(graph, Prov_Effect_Store{destination, value, element}) }
	defer prov_effect_end(graph, recorded)
	if value == 0 {
		return
	}
	// An owner, an allocator handle, or a record holding either.
	c := graph.k.c
	type := prov_value(graph, value).type
	if !type_is_managed(c, type) && type_underlying(c, type) != TYPE_ALLOCATOR &&
	   (type_is_carrier(c, type) || !prov_type_has_region(c, type)) {
		return
	}
	// design.md "Allocator regions and region provenance": an allocator handle
	// is not an owner, so only the owners made from it are checked against the
	// storage it lands in.
	root, at, reads := prov_self_reads_into(graph, destination, element)
	region := prov_result_region(graph, value)
	copied := prov_take_self_sources(graph, reads, region, at, handle = true)
	owned := prov_result_region_at(graph, value, nil, .Owners)
	copied_owners := prov_take_owner_sources(graph, reads, value, type, owned, at)
	prov_self_reads_end(graph, reads)
	prov_store_region_set(graph, destination, region, owned, prov_owner_name(graph, prov_value(graph, value).origin), element)
	prov_define_copied_content(graph, root, copied)
	prov_define_copied_content(graph, root, copied_owners)
}

// The copies at `at` that `owned`, read since the last call, made from the
// parameter's own fields. An `.Owners` query reads a record field by field, so each
// copy is recorded at its field, as `prov_define_value_regions` records one. Recorded
// at the whole value, a later read of that field would add its step to a source that
// already ends in it, and a cycle of copies would grow the path without end.
@(private = "file")
prov_take_owner_sources :: proc(graph: ^Flow_Graph, reads: ^Prov_Self_Reads, value: Value_Id, type: Type_Id, owned: Region_Set, at: []Proj_Step) -> []Prov_Region_Content {
	if reads == nil { return nil }
	fields := region_field_shape(graph.k.c, type, graph.alloc)
	if len(fields) == 0 { return prov_take_self_sources(graph, reads, owned, at) }
	clear(&reads.sources)
	out := make([dynamic]Prov_Region_Content, graph.alloc)
	for field in fields {
		if field.handle { continue }
		set := prov_result_region_at(graph, value, field.path, field.own ? .Own : .All, type)
		append(&out, ..prov_take_self_sources(graph, reads, set, prov_concat_path(graph, at, field.path), own = field.own))
	}
	return out[:]
}

// Starts listing reads for a store through `destination` when the only storage
// it can land in is this body's writable parameter, as `state^.field` does
// for a `state: ^mut T` parameter; `at` is where in that parameter.
@(private = "file")
prov_self_reads_into :: proc(graph: ^Flow_Graph, destination: Value_Id, element: bool) -> (root: Root_Id, at: []Proj_Step, reads: ^Prov_Self_Reads) {
	if element { return NO_ROOT, nil, nil }
	if place_root, path, ok := prov_value_place_of(graph, destination); ok {
		root, at = place_root, path
	} else {
		targets := prov_written_targets(graph, destination)
		if len(targets) != 1 || targets[0].target == 0 { return NO_ROOT, nil, nil }
		root = prov_root_for_storage(graph, targets[0].target)
		at = prov_concat_path(graph, targets[0].at, prov_path_below_carrier(graph, destination))
	}
	reads = prov_self_reads_begin(graph, root)
	return
}

// `region` is every region the stored value is in, and `owned` the part that
// backs an owner, which the storage is checked against; the rest is an
// allocator handle's.
@(private)
prov_store_region_set :: proc(
	graph: ^Flow_Graph,
	destination: Value_Id,
	region: Region_Set,
	owned: Region_Set,
	owner: string,
	element := false,
	contents: []Prov_Region_Content = nil,
) {
	if region_is_empty(region) && len(contents) == 0 {
		return
	}
	if root, path, ok := prov_value_place_of(graph, destination); ok {
		if !region_is_empty(owned) {
			prov_region_escape_set(graph, destination, owned, owner)
		}
		prov_define_stored_contents(graph, root, element ? prov_extend(graph, path, proj_wild()) : path, region, owned, contents)
		return
	}
	prov_store_region_through(graph, destination, region, owned, owner, contents = contents)
}

// Records `region` and `owned` at `path`, or with `contents` each part at its
// own path below it; escape checks read the whole sets either way.
@(private = "file")
prov_define_stored_contents :: proc(graph: ^Flow_Graph, root: Root_Id, path: []Proj_Step, region, owned: Region_Set, contents: []Prov_Region_Content) {
	if contents == nil {
		prov_define_stored_content(graph, root, path, region, owned)
		return
	}
	for content in contents {
		at := prov_concat_path(graph, path, content.path)
		if from, copied := content.from.?; copied {
			prov_define_copied_region(graph, root, at, prov_concat_path(graph, path, from.path), from.query, content.handle, content.own)
			continue
		}
		prov_define_stored_content(graph, root, at, content.region, content.handle ? Region_Set{} : content.region, own = content.own)
	}
}

// A call's copy within one argument: `at` takes what `root` holds at `from`,
// recorded again as a copy when `root` is this body's own writable parameter.
@(private = "file")
prov_define_copied_region :: proc(graph: ^Flow_Graph, root: Root_Id, at, from: []Proj_Step, query: Region_Query, handle, own: bool) {
	reads := prov_self_reads_begin(graph, root)
	region := prov_region_content_at(graph, root, from, query)
	copied := prov_take_self_sources(graph, reads, region, at, handle, own)
	prov_self_reads_end(graph, reads)
	prov_define_stored_content(graph, root, at, region, handle ? Region_Set{} : region, own = own)
	prov_define_copied_content(graph, root, copied)
}

// Records copies within a writable parameter (`Prov_Region_Content.from`).
// Flow-insensitive, as other content is.
@(private)
prov_define_copied_content :: proc(graph: ^Flow_Graph, root: Root_Id, contents: []Prov_Region_Content) {
	storage := prov_storage_for_root(graph, root)
	if storage == 0 { return }
	next: for copied in contents {
		content := copied
		content.path = prov_region_path(graph, content.path)
		existing := graph.region_content[storage]
		for entry in existing {
			if prov_same_region_content(entry, content) { continue next }
		}
		grown := make([]Prov_Region_Content, len(existing) + 1, graph.alloc)
		copy(grown, existing)
		grown[len(existing)] = prov_clone_region_content(content, Region_Set{}, graph.alloc)
		graph.region_content[storage] = grown
	}
}

// Whether two entries record the same kind of fact at the same path, so one
// merges into the other.
prov_same_region_content :: proc(a, b: Prov_Region_Content) -> bool {
	if a.handle != b.handle || a.own != b.own || !prov_same_path(a.path, b.path) { return false }
	from_a, copied_a := a.from.?
	from_b, copied_b := b.from.?
	return copied_a == copied_b && (!copied_a || from_a.query == from_b.query && prov_same_path(from_a.path, from_b.path))
}

// `entry` with its paths in `allocator` and `region` in place of its own.
prov_clone_region_content :: proc(entry: Prov_Region_Content, region: Region_Set, allocator: mem.Allocator) -> Prov_Region_Content {
	out := entry
	out.path = slice.clone(entry.path, allocator)
	out.region = region
	if from, copied := entry.from.?; copied {
		out.from = Prov_Region_Source{slice.clone(from.path, allocator), from.query}
	}
	return out
}

// design.md "Minimum provenance precision": of what a call leaves in a record passed
// by value, the rows that went through the carrier at `held` in it, each at its path
// below where that carrier points. One copied from elsewhere in the record reads other
// storage: what `record` holds at that path itself, and what the `targets` of the carrier
// it came through hold there.
@(private = "file")
prov_contents_held_at :: proc(graph: ^Flow_Graph, contents: []Prov_Region_Content, held: []Proj_Step, targets: []Written_Alias, record: Value_Id) -> []Prov_Region_Content {
	out := make([dynamic]Prov_Region_Content, 0, len(contents), graph.alloc)
	for content in contents {
		if !paths_overlap(held, content.path) {
			continue
		}
		entry := content
		entry.path = content.path[min(len(held), len(content.path)):]
		if from, copied := content.from.?; copied {
			if len(from.path) >= len(held) && prov_same_path(from.path[:len(held)], held) {
				entry.from = Prov_Region_Source{from.path[len(held):], from.query}
			} else {
				entry.from, entry.region = nil, prov_targets_region_at(graph, targets, from)
				region_merge(&entry.region, prov_result_region_at(graph, record, from.path, from.query))
			}
		}
		append(&out, entry)
	}
	return out[:]
}

// What the carriers `targets` were read from lead to at `from` in the record holding them.
@(private = "file")
prov_targets_region_at :: proc(graph: ^Flow_Graph, targets: []Written_Alias, from: Prov_Region_Source) -> Region_Set {
	out := Region_Set{}
	for target in targets {
		if !paths_overlap(target.path, from.path) {
			continue
		}
		if target.target == 0 {
			out.unknown = true
			continue
		}
		below := from.path[min(len(target.path), len(from.path)):]
		region_merge(&out, prov_region_content_at(graph, prov_root_for_storage(graph, target.target), prov_concat_path(graph, target.at, below), from.query))
	}
	return out
}

// An owner written through the carriers `destination` reaches, into storage
// this body cannot name.
@(private)
prov_store_region_through :: proc(graph: ^Flow_Graph, destination: Value_Id, region: Region_Set, owned: Region_Set, owner: string, suffix: []Proj_Step = nil,
                                   contents: []Prov_Region_Content = nil, by_carrier := false) {
	if region_is_empty(region) && len(contents) == 0 {
		return
	}
	destination_type := prov_value(graph, destination).type
	span := expr_span(prov_value(graph, destination).origin)
	// A write through a carrier reaches the caller or the local place, and a static
	// place rejects only where an owner is stored.
	checked := !region_is_empty(owned) && (owner == CALL_LEFT_OWNER || type_is_managed(graph.k.c, destination_type))
	escaped := false
	seen := make(Written_Alias_Visits, graph.alloc)
	// `dst^.alloc` lands in the `alloc` field of what `dst` points at.
	below := prov_concat_path(graph, prov_path_below_carrier(graph, destination), suffix)
	// A call's rows say which of the destination's carriers they went through.
	targets := prov_written_targets(graph, destination, held = by_carrier)
	for alias in targets {
		at := prov_concat_path(graph, alias.at, below)
		landed := contents
		if by_carrier && len(alias.path) > 0 {
			landed = prov_contents_held_at(graph, contents, alias.path, targets, destination)
			if len(landed) == 0 {
				continue
			}
		}
		prov_define_stored_contents(graph, prov_root_for_storage(graph, alias.target), at, region, owned, landed)
		if owner == CALL_LEFT_OWNER && prov_type_reaches_mutable(graph.k.c, destination_type) {
			if landed != nil {
				for content in landed {
					prov_store_reachable_regions(graph, alias.target, prov_concat_path(graph, at, content.path), false, region, owned, &seen)
				}
			} else {
				prov_store_reachable_regions(graph, alias.target, at, false, region, owned, &seen)
			}
		}
		sym := symbol_of(graph.k.c, prov_storage(graph, alias.target).key.symbol)
		if !checked || escaped || sym == nil || sym.kind == .Parameter || !type_is_managed(graph.k.c, prov_type_at(graph.k.c, sym.type, at)) {
			continue
		}
		escaped = prov_region_escape_into(graph, span, prov_storage(graph, alias.target).key.symbol, owned, owner)
	}
	if escaped {
		return
	}
	// design.md "Allocator regions and region provenance": only owners are checked,
	// as in prov_store_region.
	prov_region_escape_through(graph, span, owned, owner)
}

@(private)
prov_store_spread_region :: proc(graph: ^Flow_Graph, destination, value: Value_Id) {
	recorded := prov_effect_active(graph)
	if recorded { prov_effect_begin(graph, Prov_Effect_Spread{destination, value}) }
	defer prov_effect_end(graph, recorded)
	region := prov_storage_region(graph, value)
	prov_store_region_set(graph, destination, region, region, prov_owner_name(graph, prov_value(graph, value).origin), element = true)
}

// design.md "Allocator regions and region provenance": a swap or sort moves what a
// view's elements hold among them, so each element takes what any of them holds.
// Nothing new enters the storage, so no escape is checked, and a summary records a
// copy of any element to any element, which its caller resolves in turn.
@(private)
prov_store_permuted_region :: proc(graph: ^Flow_Graph, receiver: Value_Id) {
	recorded := prov_effect_active(graph)
	if recorded { prov_effect_begin(graph, Prov_Effect_Permute{receiver}) }
	defer prov_effect_end(graph, recorded)
	nothing := Region_Set{}
	element := slice.clone([]Proj_Step{proj_wild()}, graph.alloc)
	contents := make([]Prov_Region_Content, 2, graph.alloc)
	contents[0] = Prov_Region_Content{path = element, region = nothing, handle = true, from = Prov_Region_Source{element, .All}}
	contents[1] = Prov_Region_Content{path = element, region = nothing, from = Prov_Region_Source{element, .Owners}}
	prov_store_region_through(graph, receiver, nothing, nothing, "", contents = contents)
}

@(private)
prov_store_map_key_region :: proc(graph: ^Flow_Graph, destination, value: Value_Id) {
	recorded := prov_effect_active(graph)
	if recorded { prov_effect_begin(graph, Prov_Effect_Map_Key{destination, value}) }
	defer prov_effect_end(graph, recorded)
	region := prov_result_region(graph, value)
	owned := prov_result_region_at(graph, value, nil, .Owners)
	prov_store_region_through(graph, destination, region, owned, prov_owner_name(graph, prov_value(graph, value).origin), {proj_wild(), proj_field(PROJ_MAP_KEY)})
}

// An outer carrier, mutable or read-only, can reach writable carriers in its
// contents. Normalized addresses keep the descriptor and its contents separate,
// so a callee's aggregate write summary must follow those nested destinations.
@(private = "file")
prov_store_reachable_regions :: proc(graph: ^Flow_Graph, storage: Storage_Id, path: []Proj_Step,
                                      writable: bool, region, owned: Region_Set, seen: ^Written_Alias_Visits) {
	if storage == 0 { return }
	bounded, first := prov_first_alias_visit(graph, seen, storage, path, writable)
	if !first { return }
	if writable { prov_define_stored_content(graph, prov_root_for_storage(graph, storage), bounded, region, owned) }
	type := prov_type_at(graph.k.c, prov_storage(graph, storage).type, bounded)
	for carrier in carrier_shape(graph.k.c, type) {
		for alias in prov_written_aliases_of(graph, storage, prov_concat_path(graph, bounded, carrier.steps)) {
			prov_store_reachable_regions(graph, alias.target, alias.at, carrier.mutable, region, owned, seen)
		}
	}
}

// design.md "Allocator regions and region provenance": an unresolved carrier
// destination cannot keep an owner from a local region or an unmarked move.
@(private = "file")
prov_region_escape_through :: proc(graph: ^Flow_Graph, span: Span, region: Region_Set, owner: string) -> bool {
	moved, rest := prov_moved_parameter(graph, region, .Stored)
	if moved == "" && !region_has_local(rest) {
		return false
	}
	prov_emit(graph, Prov_Event {
		kind   = .Region_Escape,
		span   = span,
		verb   = owner,
		name   = "storage reached through a pointer or slice",
		region = rest,
		moved  = moved,
	})
	return true
}

// The path a write through `destination` takes inside the storage its
// closest carrier points at: `[alloc]` for `dst^.alloc`, nothing for `dst^`
// or a carrier argument itself. Earlier carriers lead to other storage.
@(private)
prov_path_below_carrier :: proc(graph: ^Flow_Graph, destination: Value_Id) -> []Proj_Step {
	place := prov_value(graph, destination).place
	if _, indirect := place.base.(Value_Id); indirect { return place.path }
	return nil
}

@(private)
prov_storage_for_root :: proc(graph: ^Flow_Graph, root: Root_Id) -> Storage_Id {
	if root == NO_ROOT { return 0 }
	return graph.roots[int(root)].storage
}

@(private)
prov_root_for_storage :: proc(graph: ^Flow_Graph, storage: Storage_Id) -> Root_Id {
	if storage == 0 { return NO_ROOT }
	entry := prov_storage(graph, storage)
	if entry.key.symbol != INVALID_SYMBOL { return prov_root_for_symbol(graph, entry.key.symbol) }
	if root, found := graph.root_by_storage[storage]; found { return root }
	root := prov_new_root(graph, entry.kind, entry.span, "this temporary")
	graph.roots[int(root)].storage = storage
	graph.root_by_storage[storage] = root
	return root
}

// design.md "Allocator regions and region provenance": a call leaves in each
// argument it may write the owners its body leaves there, with the regions of
// the arguments they came from. With no body to summarize, every allocator or
// moved-owner argument may land in every such argument.
@(private)
prov_call_written_regions :: proc(graph: ^Flow_Graph, id: Value_Id) {
	form := prov_value(graph, id).form.(Prov_Form_Call)
	v, bound := form.call, prov_bound_values(form)
	recorded := prov_effect_active(graph) && prov_input_call(graph, v).writes_facts
	if recorded { prov_effect_begin(graph, Prov_Effect_Call{id, .Write}) }
	defer prov_effect_end(graph, recorded)
	c := graph.k.c
	proc_type := call_proc_type(c, v)
	info := underlying_info(c, proc_type)
	if info == nil {
		return
	}
	callee := call_contract_declaration(c, v)
	direct := prov_has_direct_body(c, callee)
	prov_note_summary_dependency(graph, callee)
	written, found := written_region_summary(c, callee)
	if !found && direct {
		return // no parameter it writes can hold an owner
	}
	// What backs an owner left there, as opposed to an allocator handle.
	owners, _ := written_region_summary(c, callee, owners = true)
	everything := Region_Set{}
	if !found {
		for argument, index in bound {
			if argument == 0 || index >= len(info.parameters) {
				continue
			}
			moved := param_mode_at(info, index) == .Move
			if moved || type_underlying(c, info.parameters[index]) == TYPE_ALLOCATOR {
				region_merge(&everything, prov_region_of(graph, argument))
			}
		}
	}
	// Where the summary keeps paths, what it leaves lands at them, so a field
	// the callee never wrote keeps its own regions.
	rows, has_rows := written_content_summary(c, callee)
	for destination, index in bound {
		packed := call_packs(v, index)
		if (destination == 0 && !packed) || index >= len(info.parameters) {
			continue
		}
		region, owned := everything, everything
		contents: []Prov_Region_Content
		if found {
			if index >= len(written) {
				continue
			}
			region = prov_substitute_region(graph, form, written[index])
			owned = Region_Set{}
			if index < len(owners) {
				owned = prov_substitute_region(graph, form, owners[index])
			}
			if has_rows && !packed && index < len(rows) {
				contents = make([]Prov_Region_Content, len(rows[index]), graph.alloc)
				for entry, position in rows[index] {
					contents[position] = entry
					contents[position].region = prov_substitute_region(graph, form, entry.region)
				}
			}
		} else if packed || !prov_argument_is_place(graph, v, index) {
			type := info.parameters[index]
			if !carrier_is_mutable(c, type) && !prov_type_reaches_mutable(c, type) {
				continue
			}
		}
		if packed {
			for element in form.pack { prov_leave_region(graph, element, region, owned) }
		} else if prov_argument_is_place(graph, v, index) {
			prov_leave_in_place(graph, destination, region, owned, contents)
		} else if prov_parameter_is_record_by_value(c, param_mode_at(info, index), info.parameters[index]) {
			prov_store_region_through(graph, destination, region, owned, CALL_LEFT_OWNER, contents = contents, by_carrier = contents != nil)
		} else {
			prov_leave_region(graph, destination, region, owned, contents)
		}
	}
}

CALL_LEFT_OWNER :: "an owner this call leaves"

// Where a carrier argument takes what the callee leaves through it. `&mut
// place` names the place, and also what the place's own mutable carriers
// reach; any other carrier, `&place` among them, is written through, as
// `p^ = owner` is (design.md "Allocator regions and region provenance").
@(private = "file")
prov_leave_region :: proc(graph: ^Flow_Graph, argument: Value_Id, region, owned: Region_Set, contents: []Prov_Region_Content = nil) {
	c := graph.k.c
	value := prov_value(graph, argument)
	if address, ok := value.form.(Prov_Form_Unary); ok && address.op == .Amp && carrier_is_mutable(c, value.type) {
		prov_leave_in_place(graph, address.operand, region, owned, contents)
		return
	}
	prov_store_region_through(graph, argument, region, owned, CALL_LEFT_OWNER, contents = contents)
}

// What a callee leaves in a place it is handed: there, and where the place's own mutable
// carriers lead, each row only where the carrier it went through does.
@(private = "file")
prov_leave_in_place :: proc(graph: ^Flow_Graph, place: Value_Id, region, owned: Region_Set, contents: []Prov_Region_Content) {
	prov_store_region_set(graph, place, region, owned, CALL_LEFT_OWNER, contents = contents)
	if prov_type_reaches_mutable(graph.k.c, prov_value(graph, place).type) {
		prov_store_region_through(graph, place, region, owned, CALL_LEFT_OWNER, contents = contents, by_carrier = contents != nil)
	}
}

@(private)
prov_owner_name :: proc(graph: ^Flow_Graph, value: Expr) -> string {
	owner := value
	if moved, is_move := value.(^Expr_Move); is_move {
		owner = moved.value
	}
	if sym := symbol_of(graph.k.c, place_root_symbol(owner)); sym != nil {
		return fmt.aprintf("`%s`", identifier_text(graph.k.c, sym.name), allocator = graph.alloc)
	}
	return "this value"
}

// design.md "Allocator regions and region provenance": an owner received by
// `move` may be kept only as far as its `@(escape=...)` level allows. Returns
// the first `move` parameter backing the set that may not be kept at `level`,
// and the set without its `move` parameters, which are not received regions.
@(private = "file")
prov_moved_parameter :: proc(graph: ^Flow_Graph, set: Region_Set, level: Escape_Level) -> (name: string, rest: Region_Set) {
	rest = set
	for id, index in graph.param_symbols {
		sym := symbol_of(graph.k.c, id)
		if sym == nil || sym.mode != .Move || !region_has_param(set, index) {
			continue
		}
		region_remove_param(&rest, index)
		if name == "" && sym.escape < level {
			name = identifier_text(graph.k.c, sym.name)
		}
	}
	return
}

// The caller's half: a moved owner the call may keep takes its region into each
// argument it may be written to, or into static storage.
@(private)
prov_call_moved_owner :: proc(graph: ^Flow_Graph, v: ^Expr_Call, index: int, level: Escape_Level) {
	value := v.bound[index]
	info := underlying_info(graph.k.c, call_proc_type(graph.k.c, v))
	if value == nil || info == nil {
		return
	}
	if level == .Static {
		prov_event(graph, Prov_Event_Static_Escape{prov_input_value(graph, value), expr_span(value), prov_owner_name(graph, value)})
	}
	for destination, target in v.bound {
		if target == index || destination == nil || target >= len(info.parameters) {
			continue
		}
		place := destination
		if !prov_argument_is_place(graph, v, target) {
			if !carrier_is_mutable(graph.k.c, info.parameters[target]) {
				continue
			}
			if unary, is_unary := destination.(^Expr_Unary); is_unary && unary.op == .Amp {
				place = unary.operand
			}
		}
		prov_store_region(graph, prov_input_value(graph, place), prov_input_value(graph, value))
	}
}

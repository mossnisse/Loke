// Allocator regions: which regions a value, a local, or a path of either is in, and
// how a call's result and a copy take theirs (design.md "Allocator regions and region
// provenance"). The walk records them as flow-insensitive facts.
package lokec

import "core:slice"
import "core:mem"
import "core:math/bits"

@(private)
prov_result_region :: proc(graph: ^Flow_Graph, id: Value_Id) -> Region_Set {
	if form, ok := prov_value(graph, id).form.(Prov_Form_Call); ok {
		if result, found := graph.call_results[form.call]; found {
			return result.region
		}
	}
	return prov_region_of(graph, id)
}

// What a region query reads at a path: `All` everything there, `Owners` owner
// fields only, `Own` the value's own backing entry.
Region_Query :: enum { All, Owners, Own }

// The regions of one projected field of value `id` at `path`. A record keeps
// its fields apart, recursively (`region_field_shape`), and its own dependency
// has an entry of its own at the record's path, so a scalar managed record
// keeps a moved parameter's escape contract through locals and results.
// Union steps name variant indices, so success and error payloads have
// independent facts, and widening remaps paths by variant label, through
// explicit conversions too. Temporary field projections, constructors,
// success unwrapping, and switch bindings are followed to their source.
@(private)
prov_result_region_at :: proc(graph: ^Flow_Graph, id: Value_Id, path: []Proj_Step, query := Region_Query.All, as_type := INVALID_TYPE) -> Region_Set {
	if id == 0 { return Region_Set{} }
	value := prov_value(graph, id)
	type := as_type == INVALID_TYPE ? value.type : as_type
	if query == .Owners {
		part := prov_type_at(graph.k.c, type, path)
		if !type_is_managed(graph.k.c, part) {
			return Region_Set{}
		}
		if fields := region_field_shape(graph.k.c, part, graph.alloc); len(fields) > 0 {
			out := Region_Set{}
			for field in fields {
				if field.own {
					region_merge(&out, prov_result_region_at(graph, id, prov_concat_path(graph, path, field.path), .Own, type))
				} else if !field.handle {
					// The shape already flattened owners. At its depth limit a
					// leaf is conservative; expanding it again would never stop
					// for recursive container types.
					region_merge(&out, prov_result_region_at(graph, id, prov_concat_path(graph, path, field.path), .All, type))
				}
			}
			return out
		}
	}
	if transfer := prov_value_transfer(graph, id); transfer != nil {
		return prov_transfer_region(graph, transfer, path, query)
	}
	if len(path) == 0 && query == .All { return prov_result_region(graph, id) }
	#partial switch form in value.form {
	case Prov_Form_Error:
		return prov_error_region_at(graph, form, path, query)
	case Prov_Form_Call:
		if region, known := prov_constructed_region_at(graph, id, path, query); known { return region }
		if result, found := graph.call_results[form.call]; found && len(result.region_content) > 0 {
			out := Region_Set{}
			if prov_merge_matching_content(&out, result.region_content, path, query) { return out }
		}
	case Prov_Form_Selector:
		if form.field && form.operand != 0 &&
		   underlying_kind(graph.k.c, prov_value(graph, form.operand).type) == .Struct {
			return prov_result_region_at(graph, form.operand, prov_concat_path(graph, prov_extend(graph, nil, form.step), path), query)
		}
	}
	if root, base, ok := prov_value_place_of(graph, id); ok {
		at := prov_concat_path(graph, base, path)
		set := prov_region_content_at(graph, root, at, query, id)
		if query == .All {
			prov_add_received_allocator(graph, &set, root, prov_type_at(graph.k.c, type, path), id, at)
		}
		return set
	}
	if region, known := prov_read_storage_regions(graph, id, path, query); known {
		return region
	} else if carrier := prov_place_carrier(graph, id); carrier != 0 && len(path) > 0 {
		return prov_unknown_target_read(graph, carrier, region, prov_type_at(graph.k.c, type, path))
	}
	return prov_result_region(graph, id)
}

// design.md "@(allocator_reset)": an allocator a parameter received inside another
// value, as an `Option(Allocator)`'s payload, a record's field, or what a carrier in
// a record leads to, is one the analysis cannot name. Region facts record only this
// body's writes there, so the incoming one is added at a read of `value` at `path` of
// its root, unless a write on every path to the read replaced it
// (`prov_received_replaced`). A parameter `prov_bind_parameters` gives a region of
// its own names it by that.
@(private = "file")
prov_add_received_allocator :: proc(graph: ^Flow_Graph, set: ^Region_Set, root: Root_Id, type: Type_Id, value: Value_Id, path: []Proj_Step) {
	c := graph.k.c
	if root == NO_ROOT || !prov_root_is_parameter(graph, root) || !prov_holds_allocator(c, type) {
		return
	}
	if !prov_type_keeps_argument_region(c, symbol_of(c, graph.roots[int(root)].symbol).type) && !prov_received_replaced(graph, value, path) {
		set.unknown = true
	}
}

// Whether `root` is one of this body's parameters, whose contents the caller
// supplied.
@(private = "file")
prov_root_is_parameter :: proc(graph: ^Flow_Graph, root: Root_Id) -> bool {
	sym := symbol_of(graph.k.c, graph.roots[int(root)].symbol)
	return sym != nil && sym.kind == .Parameter
}

@(private)
prov_widened_region_path :: proc(graph: ^Flow_Graph, from, to: Type_Id, path: []Proj_Step) -> ([]Proj_Step, bool) {
	if len(path) == 0 { return path, true }
	if path[0].kind != .Field { return path, true }
	for _, index in type_of(graph.k.c, from).variants {
		if widened_variant(graph.k.c, from, to, index) == int(path[0].lo) {
			return prov_concat_path(graph, prov_extend(graph, nil, proj_field(index)), path[1:]), true
		}
	}
	return nil, false // this alternative cannot be produced by the source
}

// The copied field facts of value `id` as `type`, which stores and escape
// checks share: each field's regions read below `source`, the projected
// source prefix, when one is given.
@(private)
prov_result_region_fields :: proc(
	graph: ^Flow_Graph, id: Value_Id, type: Type_Id, source: []Proj_Step = nil,
	copies := false, allocator := Region_Set{default = true},
) -> []Prov_Region_Content {
	out := region_field_shape(graph.k.c, prov_type_at(graph.k.c, type, source), graph.alloc)
	for &content in out {
		content.region = prov_stored_region_at(graph, id, prov_concat_path(graph, source, content.path), content.own ? .Own : .All, copies, allocator, type, source)
	}
	return out
}

// design.md "or_return operator": propagating a place copies its error;
// propagating a temporary transfers it. Both preserve the selected payload.
@(private)
prov_error_region_at :: proc(graph: ^Flow_Graph, error: Prov_Form_Error, path: []Proj_Step, query: Region_Query, target := INVALID_TYPE) -> Region_Set {
	shape, ok := fallible_of(graph.k.c, prov_value(graph, error.operand).type)
	if !ok { return Region_Set{} }
	from := shape.failure_type
	path := path
	if union_widens_to(graph.k.c, from, target) {
		mapped, possible := prov_widened_region_path(graph, from, target, path)
		if !possible { return Region_Set{} }
		path = mapped
	}
	path = prov_concat_path(graph, prov_extend(graph, nil, proj_field(shape.failure)), path)
	operand := error.operand
	if error.borrows && type_is_managed(graph.k.c, from) {
		return prov_copied_region_at(graph, Prov_Region_Copy{value = operand, allocator = Region_Set{default = true}}, shape.union_type, path, query)
	}
	return prov_result_region_at(graph, operand, path, query)
}

// An implicit failure return records the error's region and per-field facts
// in the enclosing result's failure variant; a mapper reads the same facts
// through `Expr_Propagated_Error`.
@(private)
prov_error_region_fields :: proc(graph: ^Flow_Graph, error: Prov_Form_Error, result_type: Type_Id) -> []Prov_Region_Content {
	target, ok := fallible_of(graph.k.c, result_type)
	if !ok { return nil }
	out := region_field_shape(graph.k.c, result_type, graph.alloc)
	for &content in out {
		if len(content.path) == 0 || content.path[0].kind != .Field || int(content.path[0].lo) != target.failure { continue }
		content.region = prov_error_region_at(graph, error, content.path[1:], content.own ? .Own : .All, target.failure_type)
	}
	return out
}

// A reset strands owned allocations and borrowed data, but leaves allocator
// handles usable (design.md "Allocator regions and region provenance").
@(private)
prov_reset_fields_region :: proc(graph: ^Flow_Graph, type: Type_Id, fields: []Prov_Region_Content) -> Region_Set {
	out := Region_Set{}
	for field in fields {
		if region_field_is_allocator(graph.k.c, type, field) { continue }
		region_merge(&out, field.region)
	}
	return out
}

// Whether `field` of a `type` value's region shape is an allocator handle, whose
// region is what it names rather than what backs it.
@(private)
region_field_is_allocator :: proc(c: ^Compiler, type: Type_Id, field: Prov_Region_Content) -> bool {
	return field.handle && type_underlying(c, prov_type_at(c, type, field.path)) == TYPE_ALLOCATOR
}

@(private)
prov_reset_value_region :: proc(graph: ^Flow_Graph, id: Value_Id) -> Region_Set {
	if id == 0 { return Region_Set{} }
	type := prov_value(graph, id).type
	return prov_reset_fields_region(graph, type, prov_result_region_fields(graph, id, type))
}

// As `prov_reset_value_region` for a live owner named by its symbol: a plain
// read of the local, which has no expression of its own.
@(private)
prov_reset_symbol_region :: proc(graph: ^Flow_Graph, id: Symbol_Id, type: Type_Id) -> Region_Set {
	fields := region_field_shape(graph.k.c, type, graph.alloc)
	for &field in fields {
		field.region = prov_symbol_region_at(graph, id, type, field.path, field.own ? .Own : .All)
	}
	return prov_reset_fields_region(graph, type, fields)
}

@(private = "file")
prov_symbol_region_at :: proc(graph: ^Flow_Graph, id: Symbol_Id, type: Type_Id, path: []Proj_Step, query: Region_Query) -> Region_Set {
	if len(path) == 0 && query == .All { return prov_symbol_region(graph, id, type) }
	if root := prov_root_for_symbol(graph, id); root != NO_ROOT {
		return prov_region_content_at(graph, root, path, query)
	}
	return prov_symbol_region(graph, id, type)
}

// What reading the local `id` as a `type` value depends on.
@(private = "file")
prov_symbol_region :: proc(graph: ^Flow_Graph, id: Symbol_Id, type: Type_Id, read: Value_Id = 0) -> Region_Set {
	if type != INVALID_TYPE && !prov_type_has_region(graph.k.c, type) {
		return Region_Set{}
	}
	// A provider as a value is backed by its parent; the region it provides is
	// reached through its handle.
	if type_is_region_provider(graph.k.c, type) {
		return graph.provider_parents[id]
	}
	return prov_region_for_symbol(graph, id, read = read)
}

// Returning a region provider transfers its parent dependency, not its local
// token; the caller makes a fresh token for the returned owner.
@(private)
prov_escape_region :: proc(graph: ^Flow_Graph, id: Value_Id) -> Region_Set {
	value := prov_value(graph, id)
	if id != 0 && type_is_region_provider(graph.k.c, value.type) {
		#partial switch form in value.form {
		case Prov_Form_Symbol:
			return graph.provider_parents[form.symbol]
		case Prov_Form_Move:
			return prov_escape_region(graph, form.operand)
		}
	}
	return prov_result_region(graph, id)
}

// Region facts only grow, within a pass and from one pass to the next. A write, as
// opposed to a round seeded from the last one's facts, that puts a parameter's own
// region back into it is noted (`prov_note_restored`).
@(private)
prov_merge_region_of :: proc(graph: ^Flow_Graph, id: Symbol_Id, set: Region_Set, written := true) {
	if written {
		prov_note_restored(graph, id, set)
	}
	if aliases := graph.region_aliases[id]; len(aliases) > 0 {
		sym := symbol_of(graph.k.c, id)
		for alias in aliases {
			prov_define_region_content(graph, alias.root, alias.path, set, handle = !type_is_managed(graph.k.c, sym.type))
		}
		if prov_aliases_settle(aliases) { return }
	}
	existing, found := graph.region_of[id]
	if !found {
		existing = Region_Set{}
	}
	region_merge(&existing, set)
	graph.region_of[id] = existing
}

@(private)
prov_merge_parent :: proc(graph: ^Flow_Graph, id: Symbol_Id, set: Region_Set) {
	parent := graph.provider_parents[id]
	region_merge(&parent, set)
	graph.provider_parents[id] = parent
}

// An assigned value's regions join a local's, or the parents a provider depends
// on, since a provider's own region stays its token.
@(private)
prov_merge_value_region :: proc(graph: ^Flow_Graph, symbol: Symbol_Id, value: Value_Id, source: []Proj_Step, storage, provider: bool) {
	recorded := prov_effect_active(graph)
	if recorded { prov_effect_begin(graph, Prov_Effect_Merge_Value{symbol, value, prov_effect_path(graph, source), storage, provider}) }
	defer prov_effect_end(graph, recorded)
	region := storage ? prov_storage_region(graph, value) : prov_result_region_at(graph, value, source)
	if provider {
		prov_merge_parent(graph, symbol, region)
	} else {
		prov_merge_region_of(graph, symbol, region)
	}
}

// Borrowed bindings are rebound independently for each case/defer expansion.
@(private)
prov_forget_region_binding :: proc(graph: ^Flow_Graph, symbol: Symbol_Id) {
	recorded := prov_effect_active(graph)
	if recorded { prov_effect_begin(graph, Prov_Effect_Forget_Binding{symbol}) }
	defer prov_effect_end(graph, recorded)
	delete_key(&graph.region_aliases, symbol)
}

// Starts a pass from carried facts, copied so this pass's merges leave them
// alone and the round that produced them can be reclaimed.
@(private)
prov_seed_regions :: proc(graph: ^Flow_Graph, seed: ^Prov_Facts) {
	for id, set in seed.region_of {
		prov_merge_region_of(graph, id, set, written = false)
	}
	for id in seed.restored {
		graph.restored[id] = true
	}
	for id, set in seed.provider_parents {
		prov_merge_parent(graph, id, set)
	}
	for id in seed.lent_locals {
		graph.lent_locals[id] = true
	}
	for id, aliases in seed.written_aliases {
		for alias in aliases {
			prov_add_written_alias(graph, id, alias)
		}
	}
	for id, content in seed.region_content {
		copied := make([]Prov_Region_Content, len(content), graph.alloc)
		for entry, index in content {
			copied[index] = prov_clone_region_content(entry, entry.region, graph.alloc)
		}
		graph.region_content[id] = copied
	}
	for id, merged in seed.merged_regions {
		prov_note_merged_region(graph, id, merged.region, merged.precision)
	}
}

// Records that a store left `region` in `storage` only through a target the
// budgets in `precision` merged in, so a reset it blocks says it may
// (design.md "Minimum provenance precision").
@(private)
prov_note_merged_region :: proc(graph: ^Flow_Graph, storage: Storage_Id, region: Region_Set, precision: Precision_Loss) {
	if storage == 0 || precision == {} || region_is_empty(region) {
		return
	}
	merged := graph.merged_regions[storage]
	region_merge(&merged.region, region)
	merged.precision |= precision
	graph.merged_regions[storage] = merged
}

// A round's facts alone, deep-copied into `allocator` to seed the next round
// after this one's graph is reclaimed.
@(private)
prov_carry_facts :: proc(graph: ^Flow_Graph, allocator: mem.Allocator) -> ^Prov_Facts {
	carry := new(Prov_Facts, allocator)
	carry.region_of = make(map[Symbol_Id]Region_Set, len(graph.region_of), allocator)
	for id, set in graph.region_of { carry.region_of[id] = set }
	carry.provider_parents = make(map[Symbol_Id]Region_Set, len(graph.provider_parents), allocator)
	for id, set in graph.provider_parents { carry.provider_parents[id] = set }
	carry.lent_locals = make(map[Symbol_Id]bool, len(graph.lent_locals), allocator)
	for id in graph.lent_locals { carry.lent_locals[id] = true }
	carry.restored = make(map[Symbol_Id]bool, len(graph.restored), allocator)
	for id in graph.restored { carry.restored[id] = true }
	carry.written_aliases = make(map[Storage_Id][]Written_Alias, len(graph.written_aliases), allocator)
	for id, aliases in graph.written_aliases {
		copied := make([]Written_Alias, len(aliases), allocator)
		for alias, index in aliases {
			copied[index] = Written_Alias{target = alias.target, at = slice.clone(alias.at, allocator), path = slice.clone(alias.path, allocator), loaded = alias.loaded, precision = alias.precision}
		}
		carry.written_aliases[id] = copied
	}
	carry.region_content = make(map[Storage_Id][]Prov_Region_Content, len(graph.region_content), allocator)
	for id, content in graph.region_content {
		copied := make([]Prov_Region_Content, len(content), allocator)
		for entry, index in content {
			copied[index] = prov_clone_region_content(entry, entry.region, allocator)
		}
		carry.region_content[id] = copied
	}
	carry.merged_regions = make(map[Storage_Id]Prov_Merged_Region, len(graph.merged_regions), allocator)
	for id, merged in graph.merged_regions { carry.merged_regions[id] = merged }
	return carry
}

// How many facts a round holds. They only grow, so a round that ends with as
// many as it was seeded with read every one at its final value.
@(private)
prov_fact_weight :: proc(facts: ^Prov_Facts) -> int {
	weight := 0
	for _, set in facts.region_of {
		weight += region_weight(set)
	}
	for _, set in facts.provider_parents {
		weight += region_weight(set)
	}
	for _, content in facts.region_content {
		for entry in content {
			weight += 1 + region_weight(entry.region)
		}
	}
	// An alias read at a load below a parameter is a fact of its own, which a replay
	// that only sets `loaded` grows by, and so is one found without a budget.
	for _, aliases in facts.written_aliases {
		weight += len(aliases)
		for alias in aliases {
			weight += int(alias.loaded) + int(alias.precision == {})
		}
	}
	for _, merged in facts.merged_regions {
		weight += 1 + region_weight(merged.region) + card(merged.precision)
	}
	return weight + len(facts.lent_locals) + len(facts.restored)
}

@(private = "file")
region_weight :: proc(set: Region_Set) -> int {
	return int(bits.count_ones(set.locals)) + int(bits.count_ones(set.params)) + int(bits.count_ones(set.loaded)) +
		int(bits.count_ones(set.loaded_handles)) + int(bits.count_ones(set.loaded_viewed)) +
		int(set.default) + int(set.unknown) + int(set.crowded)
}

// Every region dependency of a symbol, including its field facts. A carrier's
// own entry is what it views, which only a read through it reaches.
@(private)
prov_region_for_symbol :: proc(graph: ^Flow_Graph, id: Symbol_Id, viewed := false, read: Value_Id = 0) -> Region_Set {
	out := Region_Set{}
	sym := symbol_of(graph.k.c, id)
	if aliases := graph.region_aliases[id]; len(aliases) > 0 {
		for alias in aliases {
			region_merge(&out, prov_region_content_at(graph, alias.root, alias.path, .All))
			if sym != nil {
				prov_add_received_allocator(graph, &out, alias.root, sym.type, alias.from, alias.path)
			}
		}
		if prov_aliases_settle(aliases) { return out }
	}
	carrier := sym != nil && prov_type_is_view_carrier(graph.k.c, sym.type)
	if direct, found := graph.region_of[id]; found && (viewed || !carrier) {
		region_merge(&out, prov_received_region(graph, id, direct, read, nil))
	}
	for content in graph.region_content[prov_storage_id(graph, Written_Storage{symbol = id})] {
		region_merge(&out, content.region)
	}
	if viewed {
		for alias in prov_written_aliases_of(graph, prov_storage_id(graph, Written_Storage{symbol = id}), nil) {
			region_merge(&out, prov_region_content_at(graph, prov_root_for_storage(graph, alias.target), alias.at, .All))
		}
	}
	return out
}

// What a body leaves in a writable parameter by path below what the argument
// names, kept apart by field; the argument's prior value and the body's own
// regions say nothing new.
@(private)
prov_written_parameter_content :: proc(graph: ^Flow_Graph, id: Symbol_Id, index: int) -> []Prov_Region_Content {
	out := make([dynamic]Prov_Region_Content, graph.alloc)
	add :: proc(out: ^[dynamic]Prov_Region_Content, index: int, content: Prov_Region_Content, written := false) {
		content := content
		content.region.locals, content.region.crowded = 0, false
		if !written { region_remove_param(&content.region, index) }
		if content.from != nil || !region_is_empty(content.region) { append(out, content) }
	}
	whole, owned := Region_Set{}, Region_Set{}
	for alias in graph.region_aliases[id] {
		region_merge(&whole, prov_region_content_at(graph, alias.root, alias.path, .All))
		region_merge(&owned, prov_region_content_at(graph, alias.root, alias.path, .Owners))
	}
	if !prov_aliases_settle(graph.region_aliases[id]) {
		sym := symbol_of(graph.k.c, id)
		carrier := sym != nil && prov_type_is_view_carrier(graph.k.c, sym.type)
		if direct, found := graph.region_of[id]; found && !carrier {
			region_merge(&whole, direct)
			region_merge(&owned, direct)
		}
		for content in graph.region_content[prov_storage_id(graph, Written_Storage{symbol = id})] {
			add(&out, index, content, written = true)
		}
	}
	add(&out, index, Prov_Region_Content{region = owned})
	add(&out, index, Prov_Region_Content{region = whole, handle = true})
	return out[:]
}

// The region dependencies at one path; a whole-value fact reaches every path.
@(private)
prov_region_content_at :: proc(graph: ^Flow_Graph, root: Root_Id, path: []Proj_Step, query := Region_Query.All, read: Value_Id = 0) -> Region_Set {
	out := Region_Set{}
	if root == NO_ROOT {
		return out
	}
	id := graph.roots[int(root)].symbol
	storage := prov_storage_for_root(graph, root)
	if aliases := graph.region_aliases[id]; len(aliases) > 0 {
		for alias in aliases {
			region_merge(&out, prov_region_content_at(graph, alias.root, prov_concat_path(graph, alias.path, path), query))
		}
		if prov_aliases_settle(aliases) { return out }
	}
	reads := graph.self_reads
	if reads != nil && reads.symbol != id { reads = nil }
	if direct, found := graph.region_of[id]; found && reads == nil {
		direct = prov_received_region(graph, id, direct, read, path)
		region_merge(&out, direct)
		// A carrier read out of a parameter leads below what the parameter names, to
		// what a read through it decides (`region_read_through`).
		if prov_root_is_parameter(graph, root) && prov_type_holds_carrier(graph.k.c, prov_parameter_type_at(graph.k.c, symbol_of(graph.k.c, id), path)) {
			prov_add_loaded_parameter(&out, direct, .Viewed)
		}
	} else if found {
		// The parameter's own region here is what the argument held at `path`.
		rest := direct
		region_remove_param(&rest, reads.index)
		region_merge(&out, rest)
		// A read that finds none of what the parameter received copies none of it.
		if _, replaced := prov_seed_replaced(graph, id, read, path); !replaced {
			append(&reads.sources, Prov_Region_Source{slice.clone(path, graph.alloc), query})
		}
	}
	for content in graph.region_content[storage] {
		// Own backing facts stay at their value's path. In particular, a
		// container's allocation does not back its elements, and an element's
		// allocation does not back the container (design.md "Allocator regions
		// and region provenance").
		if query == .Own && len(content.path) > len(path) { continue }
		if content.own && len(content.path) < len(path) { continue }
		if (query == .All || !content.handle) && (len(path) == 0 || len(content.path) == 0 || paths_overlap(content.path, path)) {
			region_merge(&out, content.region)
			if from, copied := content.from.?; copied && reads != nil {
				append(&reads.sources, prov_copied_source(graph, from, content.path, path, query))
			}
		}
	}
	return out
}

// What a read at `path` takes from a copy at `at` of the argument's content at
// `from`: the same place below `from`, or all of `from` when the read covers
// the copy. The wider query keeps both reads' regions. A store through a carrier held
// in what it reads, as `p^.out^ = p^.items`, reads its own copy, so the path stops at
// the written-alias depth, where a cut source reads all below it, and the facts settle.
@(private = "file")
prov_copied_source :: proc(graph: ^Flow_Graph, from: Prov_Region_Source, at, path: []Proj_Step, query: Region_Query) -> Prov_Region_Source {
	out := Prov_Region_Source{path = from.path, query = from.query}
	if len(path) > len(at) {
		out.path = prov_concat_path(graph, from.path, path[len(at):])
	}
	if query == .All || from.query == .All {
		out.query = .All
	} else if query == .Owners || from.query == .Owners {
		out.query = .Owners
	}
	if len(out.path) > WRITTEN_ALIAS_DEPTH {
		out.path, out.query = out.path[:WRITTEN_ALIAS_DEPTH], .All
	}
	return out
}

// A record copied or moved as a whole keeps the same field facts as separate
// writes. In particular, its allocator handles do not back its owners. A copy
// allocates from `allocated_by`'s destination allocator, the default when none.
@(private)
prov_define_value_regions :: proc(
	graph: ^Flow_Graph, root: Root_Id, path: []Proj_Step, value: Value_Id, source: []Proj_Step = nil,
	copies := false, allocated_by := INVALID_SYMBOL,
) {
	recorded := prov_effect_active(graph) && value != 0 && prov_type_has_region(graph.k.c, prov_value(graph, value).type)
	if recorded { prov_effect_begin(graph, Prov_Effect_Define{prov_storage_for_root(graph, root), prov_effect_path(graph, path), value, prov_effect_path(graph, source), copies, allocated_by}) }
	defer prov_effect_end(graph, recorded)
	allocator := prov_destination_allocator(graph, allocated_by)
	type := prov_value(graph, value).type
	reads := prov_self_reads_begin(graph, root)
	defer prov_self_reads_end(graph, reads)
	fields := region_field_shape(graph.k.c, prov_type_at(graph.k.c, type, source), graph.alloc)
	if len(fields) == 0 {
		region := prov_stored_region_at(graph, value, source, .All, copies, allocator, copy_from = source)
		copied := prov_take_self_sources(graph, reads, region, path, handle = true)
		owned := prov_stored_region_at(graph, value, source, .Owners, copies, allocator, copy_from = source)
		copied_owners := prov_take_self_sources(graph, reads, owned, path)
		prov_define_stored_content(graph, root, path, region, owned)
		prov_define_copied_content(graph, root, copied)
		prov_define_copied_content(graph, root, copied_owners)
		return
	}
	for field in fields {
		at := prov_concat_path(graph, path, field.path)
		region := prov_stored_region_at(graph, value, prov_concat_path(graph, source, field.path), field.own ? .Own : .All, copies, allocator, type, source)
		copied := prov_take_self_sources(graph, reads, region, at, field.handle, field.own)
		owned := field.handle ? Region_Set{} : region
		prov_define_stored_content(graph, root, at, region, owned, own = field.own)
		prov_define_copied_content(graph, root, copied)
	}
}

// Starts listing the reads of the writable parameter `root` names, so a store
// into it can say which of the argument's own fields it copied. Nil for any
// other root.
@(private)
prov_self_reads_begin :: proc(graph: ^Flow_Graph, root: Root_Id) -> ^Prov_Self_Reads {
	if root == NO_ROOT || graph.self_reads != nil { return nil }
	// A pointer parameter's storage is the pointee's, which is not a `.Param` root.
	id := graph.roots[int(root)].symbol
	sym := symbol_of(graph.k.c, id)
	if sym == nil || sym.kind != .Parameter || !param_writes_caller(graph.k.c, sym) { return nil }
	index, is_own := prov_param_index(graph, id)
	if !is_own { return nil }
	graph.self_reads = new_clone(Prov_Self_Reads{symbol = id, index = index, sources = make([dynamic]Prov_Region_Source, graph.alloc)}, graph.alloc)
	return graph.self_reads
}

@(private)
prov_self_reads_end :: proc(graph: ^Flow_Graph, reads: ^Prov_Self_Reads) {
	if reads != nil { graph.self_reads = nil }
}

// The copies at `path` that `region`, read since the last call, made from the
// parameter's own fields. None when its own region reached `region` some other
// way: that dependency then stands for the whole argument.
@(private)
prov_take_self_sources :: proc(graph: ^Flow_Graph, reads: ^Prov_Self_Reads, region: Region_Set, path: []Proj_Step, handle := false, own := false) -> []Prov_Region_Content {
	if reads == nil { return nil }
	defer clear(&reads.sources)
	if len(reads.sources) == 0 || region_has_param(region, reads.index) { return nil }
	out := make([]Prov_Region_Content, len(reads.sources), graph.alloc)
	for source, index in reads.sources {
		out[index] = Prov_Region_Content{path = path, region = Region_Set{}, handle = handle, own = own, from = source}
	}
	return out
}

// A stored copy allocates in its destination's allocator before widening
// remaps the payload tag (design.md "Widening by label").
@(private = "file")
prov_stored_region_at :: proc(graph: ^Flow_Graph, value: Value_Id, path: []Proj_Step, query: Region_Query, copies: bool, allocator: Region_Set, as_type := INVALID_TYPE, copy_from: []Proj_Step = nil) -> Region_Set {
	if !copies { return prov_result_region_at(graph, value, path, query, as_type) }
	component := prov_input_stored_copy(graph, value, path, copy_from)
	if component.source == 0 { return Region_Set{} }
	return prov_copy_component_region(graph, component, nil, query, allocator)
}

@(private)
prov_destination_allocator :: proc(graph: ^Flow_Graph, id: Symbol_Id) -> Region_Set {
	if allocator := symbol_via_allocator(graph.k.c, id); allocator != nil { return prov_region_of(graph, prov_input_value(graph, allocator)) }
	return Region_Set{default = true}
}

// A borrowed binding's region facts live at its subject's payload path.
// An optional final NO_ROOT denotes unresolved carrier storage alongside the
// known targets; its reads and writes also keep local snapshots.
Prov_Region_Alias :: struct {
	root: Root_Id,
	path: []Proj_Step,
	// The value read at the place, when it names one directly: what was written on
	// every path to that read is still written where the binding is read, which it
	// dominates (`prov_received_replaced`).
	from: Value_Id,
}

// Whether `aliases` name every place the binding's facts live, with no local
// snapshot needed beside them.
@(private = "file")
prov_aliases_settle :: proc(aliases: []Prov_Region_Alias) -> bool {
	return len(aliases) > 0 && aliases[len(aliases) - 1].root != NO_ROOT
}

// Region facts are flow-insensitive, so one at an element of a dynamic array
// would stay at that index whatever later moved the element: it stands for any.
@(private)
prov_region_path :: proc(graph: ^Flow_Graph, path: []Proj_Step) -> []Proj_Step {
	for step, index in path {
		if step.shifts {
			out := slice.clone(path, graph.alloc)
			for &other in out[index:] {
				if other.shifts {
					other = proj_wild()
				}
			}
			return out
		}
	}
	return path
}

// Records a managed value stored at a path. Flow-insensitive, so writes merge.
@(private)
prov_define_region_content :: proc(
	graph: ^Flow_Graph,
	root: Root_Id,
	written: []Proj_Step,
	region: Region_Set,
	handle := false,
	own := false,
) {
	if root == NO_ROOT || region_is_empty(region) {
		return
	}
	path := prov_region_path(graph, written)
	id := graph.roots[int(root)].symbol
	storage := prov_storage_for_root(graph, root)
	if storage == 0 {
		return
	}
	if aliases := graph.region_aliases[id]; len(aliases) > 0 {
		for alias in aliases {
			prov_define_region_content(graph, alias.root, prov_concat_path(graph, alias.path, path), region, handle, own)
		}
		if prov_aliases_settle(aliases) { return }
	}
	// A handle's entry stays apart from an owner's at the same path, so what
	// backs an owner is still told from it (design.md "Allocator regions and
	// region provenance").
	added := Prov_Region_Content{path = path, region = region, handle = handle, own = own}
	content := graph.region_content[storage]
	for &entry in content {
		if prov_same_region_content(entry, added) {
			region_merge(&entry.region, region)
			return
		}
	}
	grown := make([]Prov_Region_Content, len(content) + 1, graph.alloc)
	copy(grown, content)
	grown[len(content)] = prov_clone_region_content(added, region, graph.alloc)
	graph.region_content[storage] = grown
}

// Records a stored value's regions at a path: `owned`, the part backing an
// owner, as an owner's entry, and the rest as an allocator handle's.
@(private)
prov_define_stored_content :: proc(graph: ^Flow_Graph, root: Root_Id, path: []Proj_Step, region, owned: Region_Set, own := false) {
	prov_define_region_content(graph, root, path, owned, own = own)
	handles := owned
	if region_merge(&handles, region) {
		prov_define_region_content(graph, root, path, region, handle = true, own = own)
	}
}

// One provider position in a local: a field path its type fixes, or the path
// of a container, union, or array whose providers share one token.
Provider_Path :: struct {
	key: []Proj_Step,
	bit: u64,
}

// Every token of one local. Past `REGION_LOCAL_LIMIT` the set is `crowded`, meaning "may
// be any of them".
@(private)
prov_provider_region :: proc(graph: ^Flow_Graph, id: Symbol_Id) -> Region_Set {
	out := Region_Set{}
	if !prov_provider_tokens(graph, id) {
		out.crowded = true
		return out
	}
	out.locals = graph.provider_bits[id]
	return out
}

// The tokens of the providers at or under `path` in a local, or containing it,
// whether its type fixes them there or they were moved in there.
@(private)
prov_provider_region_at :: proc(graph: ^Flow_Graph, id: Symbol_Id, path: []Proj_Step) -> Region_Set {
	out := Region_Set{}
	if !prov_provider_tokens(graph, id) {
		out.crowded = true
		return out
	}
	key := provider_key(path)
	for position in graph.provider_paths[id] {
		if provider_keys_overlap(position.key, key) { out.locals |= position.bit }
	}
	for moved in graph.provider_moved[id] {
		if provider_keys_overlap(moved.key, key) { out.locals |= moved.bit }
	}
	return out
}

// Where in a local a provider at `path` sits: its field prefix. A container,
// union, or array shares one position among its elements.
@(private = "file")
provider_key :: proc(path: []Proj_Step) -> []Proj_Step {
	for step, index in path {
		if step.kind != .Field {
			return path[:index]
		}
	}
	return path
}

// Whether one provider position holds the other, or is held in it.
@(private = "file")
provider_keys_overlap :: proc(a, b: []Proj_Step) -> bool {
	return path_has_exact_prefix(a, b) || path_has_exact_prefix(b, a)
}

// The tokens of every provider moved into a local, wherever it sits.
@(private = "file")
prov_moved_tokens :: proc(graph: ^Flow_Graph, id: Symbol_Id) -> u64 {
	bits: u64
	for moved in graph.provider_moved[id] {
		bits |= moved.bit
	}
	return bits
}

// Gives a local one token per provider position on first use, so every token
// exists before any reset or handle reads it. False when the bits run out.
@(private = "file")
prov_provider_tokens :: proc(graph: ^Flow_Graph, id: Symbol_Id) -> bool {
	if _, found := graph.provider_bits[id]; found {
		return true
	}
	positions := make([dynamic]Provider_Path, 0, 1, graph.alloc)
	if sym := symbol_of(graph.k.c, id); sym != nil {
		prov_provider_positions(graph, sym.type, nil, 0, &positions)
	}
	if len(positions) == 0 {
		append(&positions, Provider_Path{})
	}
	if len(graph.provider_symbols) + len(positions) > REGION_LOCAL_LIMIT {
		return false
	}
	bits := prov_moved_tokens(graph, id)
	for &position in positions {
		position.bit = u64(1) << u64(len(graph.provider_symbols))
		append(&graph.provider_symbols, id)
		bits |= position.bit
	}
	graph.provider_paths[id] = positions[:]
	graph.provider_bits[id] = bits
	return true
}

@(private = "file")
prov_provider_positions :: proc(graph: ^Flow_Graph, type: Type_Id, prefix: []Proj_Step, depth: int, out: ^[dynamic]Provider_Path) {
	c := graph.k.c
	if !type_carries_provider(c, type) {
		return
	}
	info := underlying_info(c, type)
	if type_is_region_provider(c, type) || info == nil || info.kind != .Struct || type_is_shared_handle(c, type) || depth >= CARRIER_DEPTH {
		append(out, Provider_Path{key = prefix})
		return
	}
	for field in info.fields {
		if sym := symbol_of(c, field); sym != nil {
			prov_provider_positions(graph, sym.type, prov_extend(graph, prefix, proj_field(int(sym.index))), depth + 1, out)
		}
	}
}

// Ending a provider reads its control block, which a fixed arena keeps in the
// caller's buffer, so the buffer stays borrowed until then — and with it, until
// every owner the region backs is gone, since those must end first.
@(private)
prov_provider_use :: proc(graph: ^Flow_Graph, id: Symbol_Id, span: Span) {
	sources := make([dynamic]int, 0, 1, graph.alloc)
	if slot, is_carrier := prov_slot_for_symbol(graph, id); is_carrier {
		append(&sources, slot)
	}
	for slot in prov_content_slots(graph, id) {
		if type_is_region_provider(graph.k.c, graph.prov_slots[slot].content_type) {
			append(&sources, slot)
		}
	}
	if len(sources) > 0 {
		prov_emit(graph, Prov_Event{kind = .Live, sources = sources[:], span = span})
	}
}

// design.md "Allocators": the providers a value moved out of locals carries,
// through composite literals, `exchange`, `unsafe.take`, and `box`, each keyed by
// where in the value it sits, so that moving the value into a local puts each
// token at its own field there and a sibling field keeps none of it.
@(private)
prov_moved_providers :: proc(graph: ^Flow_Graph, id: Value_Id) -> []Provider_Path {
	source: Value_Id
	#partial switch form in prov_value(graph, id).form {
	case Prov_Form_Move:
		source = form.operand
	case Prov_Form_Call:
		v, bound := form.call, prov_bound_values(form)
		if sym := symbol_of(graph.k.c, v.resolution.symbol); sym != nil && sym.builtin == .Exchange && len(bound) == 2 {
			source = bound[0]
		} else if sym != nil && sym.builtin == .Unsafe_Take && len(bound) == 1 {
			source = bound[0]
		} else if boxed_payload(graph.k.c, v) != nil {
			// A box is one position: its payload's fields are not the local's.
			return prov_rekey_providers(graph, prov_moved_providers(graph, bound[0]), prov_extend(graph, nil, proj_wild()))
		}
	case Prov_Form_Composite:
		out := make([dynamic]Provider_Path, graph.alloc)
		value := prov_value(graph, id)
		composite, _ := value.origin.(^Expr_Composite)
		for element, index in form.elements {
			if element == 0 { continue }
			// An element whose field is not known may be at any position.
			prefix := prov_extend(graph, nil, proj_wild())
			if composite != nil {
				prefix, _ = prov_element_prefix(graph, composite, value.type, index)
			}
			append(&out, ..prov_rekey_providers(graph, prov_moved_providers(graph, element), prefix))
		}
		return out[:]
	}
	// Only the providers at the place moved from go with it: a sibling field keeps
	// its own token.
	if source == 0 { return nil }
	root, path, ok := prov_value_place_of(graph, source)
	if !ok || graph.roots[int(root)].kind != .Local { return nil }
	symbol := graph.roots[int(root)].symbol
	// Moving a local's providers is a use of its tokens, which may not exist yet.
	// Past `REGION_LOCAL_LIMIT` they never will, and every region read of the local
	// is crowded, which overlaps any end of what it is moved into, so it carries none.
	if !prov_provider_tokens(graph, symbol) { return nil }
	key := provider_key(path)
	out := make([dynamic]Provider_Path, graph.alloc)
	take := proc(out: ^[dynamic]Provider_Path, held: Provider_Path, key: []Proj_Step) {
		if !provider_keys_overlap(held.key, key) { return }
		// What sat below the place moved keeps its place in the value; what held the
		// place, as a container of providers, is the whole value.
		below: []Proj_Step
		if len(held.key) > len(key) { below = held.key[len(key):] }
		append(out, Provider_Path{key = below, bit = held.bit})
	}
	for position in graph.provider_paths[symbol] { take(&out, position, key) }
	for moved in graph.provider_moved[symbol] { take(&out, moved, key) }
	return out[:]
}

// `moved`, read as held at `prefix`. A prefix past a field path, as a box's or an
// array element's, puts them all at the position holding it.
@(private = "file")
prov_rekey_providers :: proc(graph: ^Flow_Graph, moved: []Provider_Path, prefix: []Proj_Step) -> []Provider_Path {
	out := make([]Provider_Path, len(moved), graph.alloc)
	for held, index in moved {
		out[index] = Provider_Path{key = provider_key(prov_concat_path(graph, prefix, held.key)), bit = held.bit}
	}
	return out
}

// A provider moved into a local's existing storage, at `path` in it, joins that
// local's tokens there.
@(private)
prov_merge_moved_providers :: proc(graph: ^Flow_Graph, root: Symbol_Id, value: Value_Id, path: []Proj_Step = nil) {
	recorded := prov_effect_active(graph)
	if recorded { prov_effect_begin(graph, Prov_Effect_Move_Provider{root, value, prov_effect_path(graph, path)}) }
	defer prov_effect_end(graph, recorded)
	moved := prov_moved_providers(graph, value)
	if len(moved) == 0 {
		return
	}
	existing := prov_provider_region(graph, root)
	if existing.crowded {
		return // already "may be any of them"
	}
	bits := prov_add_moved_providers(graph, root, prov_rekey_providers(graph, moved, path))
	graph.provider_bits[root] = existing.locals | bits
	if set, found := graph.region_of[root]; found && type_is_region_provider(graph.k.c, symbol_of(graph.k.c, root).type) {
		set.locals |= bits
		graph.region_of[root] = set
	}
}

// A local declared from a value carrying moved providers holds each at its own
// position, whether or not the local's own tokens exist yet.
@(private)
prov_declare_moved_providers :: proc(graph: ^Flow_Graph, id: Symbol_Id, value: Value_Id) {
	moved := prov_moved_providers(graph, value)
	if len(moved) == 0 {
		return
	}
	bits := prov_add_moved_providers(graph, id, moved)
	if existing, found := graph.provider_bits[id]; found {
		graph.provider_bits[id] = existing | bits
	}
}

// Records `moved` among a local's moved-in providers, and returns their tokens.
@(private)
prov_add_moved_providers :: proc(graph: ^Flow_Graph, root: Symbol_Id, moved: []Provider_Path) -> u64 {
	bits: u64
	held := make([dynamic]Provider_Path, 0, len(graph.provider_moved[root]) + len(moved), graph.alloc)
	append(&held, ..graph.provider_moved[root])
	outer: for added in moved {
		bits |= added.bit
		for &known in held {
			if prov_same_path(known.key, added.key) {
				known.bit |= added.bit
				continue outer
			}
		}
		append(&held, Provider_Path{key = slice.clone(added.key, graph.alloc), bit = added.bit})
	}
	graph.provider_moved[root] = held[:]
	return bits
}

// The name of the one local region a set names, or "".
prov_region_name :: proc(graph: ^Flow_Graph, set: Region_Set) -> string {
	if set.crowded {
		return ""
	}
	found := ""
	for id, index in graph.provider_symbols {
		if set.locals & (u64(1) << u64(index)) == 0 {
			continue
		}
		name := ""
		if sym := symbol_of(graph.k.c, id); sym != nil {
			name = identifier_text(graph.k.c, sym.name)
		}
		if found != "" && found != name {
			return ""
		}
		found = name
	}
	return found
}

// A `leaf` type, or an `Option`/`Result`-style union around one: the wrapper
// carries what its payload carries (design.md "Allocators").
@(private)
prov_type_or_wrapped :: proc(
	c: ^Compiler,
	type: Type_Id,
	leaf: proc(c: ^Compiler, type: Type_Id) -> bool,
	depth := 0,
) -> bool {
	if type == INVALID_TYPE || depth > REGION_SHAPE_DEPTH {
		return false
	}
	if leaf(c, type) {
		return true
	}
	info := underlying_info(c, type)
	if info == nil || info.kind != .Union {
		return false
	}
	for payload in info.variants {
		if payload != TYPE_VOID && prov_type_or_wrapped(c, payload, leaf, depth + 1) {
			return true
		}
	}
	return false
}

@(private = "file")
prov_carries_allocator :: proc(c: ^Compiler, type: Type_Id) -> bool {
	return prov_type_or_wrapped(c, type, proc(c: ^Compiler, type: Type_Id) -> bool {
		return type_underlying(c, type) == TYPE_ALLOCATOR
	})
}

// Whether a value of `type` holds an allocator handle anywhere in it, a record's
// fields included, not behind a carrier.
@(private = "file")
prov_holds_allocator :: proc(c: ^Compiler, type: Type_Id, depth := 0) -> bool {
	if depth > REGION_SHAPE_DEPTH {
		return true
	}
	if prov_carries_allocator(c, type) {
		return true
	}
	info := underlying_info(c, type)
	if info == nil {
		return false
	}
	#partial switch info.kind {
	case .Struct:
		for field in info.fields {
			if sym := symbol_of(c, field); sym != nil && prov_holds_allocator(c, sym.type, depth + 1) {
				return true
			}
		}
	case .Union:
		for variant in info.variants {
			if variant != TYPE_VOID && prov_holds_allocator(c, variant, depth + 1) {
				return true
			}
		}
	case .Array:
		return prov_holds_allocator(c, info.element, depth + 1)
	}
	return false
}

// Whether a value of `type` can depend on an allocator region: somewhere in it
// is an owner, a view, an `Allocator`, or a provider (design.md "Allocator
// regions and region provenance"). An `int` read out of a region-backed
// container has no region.
@(private)
prov_type_has_region :: proc(c: ^Compiler, type: Type_Id, depth := 0) -> bool {
	if depth > REGION_SHAPE_DEPTH {
		return true
	}
	if type_is_managed(c, type) || type_is_carrier(c, type) || type_underlying(c, type) == TYPE_ALLOCATOR {
		return true
	}
	info := underlying_info(c, type)
	if info == nil {
		return false
	}
	#partial switch info.kind {
	case .Struct:
		for field in info.fields {
			if sym := symbol_of(c, field); sym != nil && prov_type_has_region(c, sym.type, depth + 1) {
				return true
			}
		}
	case .Union:
		for variant in info.variants {
			if variant != TYPE_VOID && prov_type_has_region(c, variant, depth + 1) {
				return true
			}
		}
	case .Array:
		return prov_type_has_region(c, info.element, depth + 1)
	}
	return false
}

@(private)
prov_region_of :: proc(graph: ^Flow_Graph, id: Value_Id) -> Region_Set {
	if id == 0 { return Region_Set{} }
	c := graph.k.c
	value := prov_value(graph, id)
	e := value.origin
	if value.type != INVALID_TYPE && !prov_type_has_region(c, value.type) {
		return Region_Set{}
	}
	// design.md "Allocators": the zero `Allocator` is the default provider.
	if base := expr_base(e); base.const_value.kind == .Nil && type_underlying(c, value.type) == TYPE_ALLOCATOR {
		return Region_Set{default = true}
	}
	if transfer := prov_value_transfer(graph, id); transfer != nil {
		return prov_transfer_region(graph, transfer, nil, .All)
	}
	#partial switch form in value.form {
	case Prov_Form_Symbol:
		return prov_symbol_region(graph, form.symbol, value.type, id)
	case Prov_Form_Error:
		return prov_error_region_at(graph, form, nil, .All)
	case Prov_Form_Selector, Prov_Form_Index:
		if call := prov_operator_value(graph, id); call != 0 {
			return prov_result_region(graph, call)
		}
		if root, path, ok := prov_value_place_of(graph, id); ok {
			set := prov_region_content_at(graph, root, path, read = id)
			// An allocator no write named is one the analysis cannot name.
			if region_is_empty(set) && type_underlying(c, value.type) == TYPE_ALLOCATOR {
				set.unknown = true
			}
			prov_add_received_allocator(graph, &set, root, value.type, id, path)
			return set
		}
		// A field of a temporary is in what produced it, each alternative of a
		// conditional or `or_else` included, and not in what its siblings are
		// (design.md "Allocator regions and region provenance"). One read through a
		// carrier is in what the carrier views.
		if selector, is_selector := form.(Prov_Form_Selector); is_selector && selector.field && selector.operand != 0 &&
		   underlying_kind(c, prov_value(graph, selector.operand).type) == .Struct && prov_place_carrier(graph, id) == 0 {
			return prov_result_region_at(graph, selector.operand, {selector.step}, .All)
		}
		return prov_read_region(graph, id)
	case Prov_Form_Binary, Prov_Form_Unary, Prov_Form_Slice:
		if call := prov_operator_value(graph, id); call != 0 {
			return prov_result_region(graph, call)
		}
	case Prov_Form_Postfix:
		if form.op == .Caret && form.boxed {
			if root, path, ok := prov_value_place_of(graph, id); ok {
				return prov_region_content_at(graph, root, path)
			}
			return prov_read_region(graph, id)
		}
		if form.op == .Caret {
			return prov_viewed_region(graph, form.operand)
		}
	case Prov_Form_Call:
		v := form.call
		// `arena.allocator()` names the provider's own region.
		if set, ok := prov_handle_region(graph, v, prov_receiver_value(form.arguments)); ok {
			return set
		}
		if result, found := graph.call_results[v]; found {
			return result.region
		}
		return prov_call_region(graph, id, value.type)
	}
	return Region_Set{unknown = prov_carries_allocator(c, value.type)}
}

// design.md "Allocator regions and region provenance": a copy of a managed
// value shares its source's allocation, since a copy that allocates is written
// as a clone, so it keeps the source's region. What a carrier views is backed
// by the regions of the owners it was taken from: a view or pointer local takes
// them from each value it is given, and a carrier parameter from its argument.
@(private)
prov_storage_region :: proc(graph: ^Flow_Graph, id: Value_Id) -> Region_Set {
	if id != 0 && prov_type_is_view_carrier(graph.k.c, prov_value(graph, id).type) {
		return prov_viewed_region(graph, id)
	}
	return prov_region_of(graph, id)
}

@(private)
prov_viewed_region :: proc(graph: ^Flow_Graph, id: Value_Id, whole := true) -> Region_Set {
	#partial switch form in prov_value(graph, id).form {
	case Prov_Form_Symbol:
		return prov_region_for_symbol(graph, form.symbol, viewed = true, read = id)
	case Prov_Form_Unary:
		if form.op == .Amp {
			return prov_storage_region(graph, form.operand)
		}
	case Prov_Form_Slice:
		if form.operator == 0 && form.operand != 0 {
			return prov_storage_region(graph, form.operand)
		}
	case Prov_Form_Move:
		return prov_viewed_region(graph, form.operand)
	case Prov_Form_Call:
		if bound := prov_bound_values(form); prov_receiver_is_shared_handle(graph, form.call) && len(bound) > 0 {
			return prov_source_region_at(graph, bound[0], {proj_wild()})
		}
	case Prov_Form_Selector, Prov_Form_Index:
		if _, _, ok := prov_value_place_of(graph, id); !ok {
			return prov_read_region(graph, id)
		}
		// A carrier held in named storage views what it was set to point at. Unless
		// `whole`, a part of that is read, which names an allocator of its own.
		viewed := INVALID_TYPE
		if info := underlying_info(graph.k.c, prov_value(graph, id).type); info != nil {
			viewed = info.element
		}
		out, known := prov_carrier_storage_regions(graph, id, nil, viewed, .All)
		// One a parameter holds, which no write here pointed anywhere, views what its
		// argument's carriers lead to (`prov_region_content_at`).
		if root, path, _ := prov_value_place_of(graph, id); !known && root != NO_ROOT && prov_root_is_parameter(graph, root) {
			region_merge(&out, prov_region_content_at(graph, root, path, .All, id))
		}
		return whole ? prov_unnamed_allocator(graph, out, known, viewed) : out
	}
	return Region_Set{}
}

// A value read out through a carrier (`view[0]`, `p.field`, `p^`) is in what
// the carrier views; a part of a value is in that value's regions.
// Known targets retain field precision, including anonymous backing arrays.
@(private = "file")
prov_read_storage_regions :: proc(graph: ^Flow_Graph, id: Value_Id, path: []Proj_Step, query: Region_Query) -> (Region_Set, bool) {
	carrier := prov_place_carrier(graph, id)
	if carrier == 0 { return {}, false }
	below := prov_concat_path(graph, prov_path_below_carrier(graph, id), path)
	type := prov_type_at(graph.k.c, prov_value(graph, id).type, path)
	out, known := prov_carrier_storage_regions(graph, carrier, below, type, query)
	region_read_through(&out, prov_loaded_read(graph.k.c, type))
	return out, known
}

// What `carrier`'s known targets hold at `below`, a value of `type`, and whether every
// target it may have is known.
@(private = "file")
prov_carrier_storage_regions :: proc(graph: ^Flow_Graph, carrier: Value_Id, below: []Proj_Step, type: Type_Id, query: Region_Query) -> (Region_Set, bool) {
	out := Region_Set{}
	aliases := prov_place_aliases(graph, carrier, unresolved = false)
	known := len(aliases) > 0
	for alias in aliases {
		if alias.target == 0 { known = false; continue }
		root := prov_root_for_storage(graph, alias.target)
		region_merge(&out, prov_region_content_at(graph, root, prov_concat_path(graph, alias.at, below), query))
		prov_add_received_allocator(graph, &out, root, type, 0, nil)
		// Read below what the parameter names, so no path of it says what this holds:
		// it stands for what the whole argument reaches (`prov_reached_regions`), as
		// the read through `carrier` decides (`region_read_through`).
		if direct, found := graph.region_of[graph.roots[int(root)].symbol]; found && alias.loaded {
			prov_add_loaded_parameter(&out, direct, .Viewed)
		}
	}
	return out, known
}

// What a read of a `type` value through carriers read, for a parameter's region
// read at a load below it (`Loaded_Read`): a carrier, whose region is what it views;
// a value holding an allocator handle; or owners alone.
@(private = "file")
prov_loaded_read :: proc(c: ^Compiler, type: Type_Id) -> Loaded_Read {
	switch {
	case type == INVALID_TYPE, prov_holds_allocator(c, type): return .Handles
	case prov_type_holds_carrier(c, type):                    return .Viewed
	}
	return .Owners
}

// Whether a value of `type` is or holds a carrier, so what is read through it is
// below where it is.
@(private)
prov_type_holds_carrier :: proc(c: ^Compiler, type: Type_Id) -> bool {
	return type != INVALID_TYPE && (type_is_carrier(c, type) || len(carrier_shape(c, type)) > 0)
}

// The type at `path` in what parameter `sym` names: a pointer's paths start at
// its pointee, as its storage is the pointee's.
@(private)
prov_parameter_type_at :: proc(c: ^Compiler, sym: ^Symbol, path: []Proj_Step) -> Type_Id {
	type := sym.type
	if sym.mode != .Inout && underlying_kind(c, type) == .Pointer {
		type = underlying_info(c, type).element
	}
	return prov_type_at(c, type, path)
}

// The region of a parameter, `direct`, read at a load below what it names
// (`Region_Set.loaded`), as `read`.
@(private = "file")
prov_add_loaded_parameter :: proc(set: ^Region_Set, direct: Region_Set, read: Loaded_Read) {
	region_merge(set, direct)
	params := direct.params
	for index in next_region_param(&params) {
		region_add_loaded_param(set, index, read)
	}
}

// design.md "Allocator regions and region provenance": a parameter's region read at a
// load below what it names stands at a call for what its argument's carriers lead to, at
// every load below, as well as what it names. A parameter of this body reached here
// with carriers in it is one more load below for this body's callers
// (`prov_region_content_at`). Unless the read may have been of `handles`, the allocator
// handles there are left out: what was read holds owners alone, and a handle beside
// them backs none of them (`Loaded_Read`).
@(private = "file")
prov_reached_regions :: proc(graph: ^Flow_Graph, argument: Value_Id, handles: bool) -> Region_Set {
	Walk :: struct {
		graph:   ^Flow_Graph,
		seen:    Written_Alias_Visits,
		out:     Region_Set,
		handles: bool,
	}
	walk :: proc(w: ^Walk, target: Storage_Id, at: []Proj_Step) {
		if target == 0 {
			return
		}
		graph := w.graph
		c := graph.k.c
		bounded, first := prov_first_alias_visit(graph, &w.seen, target, at, false)
		if !first {
			return
		}
		root := prov_root_for_storage(graph, target)
		type := prov_type_at(c, prov_storage(graph, target).type, bounded)
		if w.handles {
			region_merge(&w.out, prov_region_content_at(graph, root, bounded, .All))
		} else {
			for field in region_field_shape(c, type, graph.alloc) {
				if region_field_is_allocator(c, type, field) { continue }
				region_merge(&w.out, prov_region_content_at(graph, root, prov_concat_path(graph, bounded, field.path), field.own ? .Own : .All))
			}
		}
		for carrier in carrier_shape(c, type) {
			for alias in prov_written_aliases_of(graph, target, prov_concat_path(graph, bounded, carrier.steps)) {
				walk(w, alias.target, alias.at)
			}
		}
	}
	w := Walk{graph = graph, seen = make(Written_Alias_Visits, graph.alloc), handles = handles}
	for alias in prov_value_aliases(graph, argument) {
		walk(&w, alias.target, alias.at)
	}
	return w.out
}

// design.md "@(allocator_reset)": an allocator read through a carrier of unknown
// targets, which found nothing, is one the analysis cannot name.
@(private = "file")
prov_unnamed_allocator :: proc(graph: ^Flow_Graph, set: Region_Set, known: bool, type: Type_Id) -> Region_Set {
	out := set
	if !known && region_is_empty(out) && type != INVALID_TYPE && prov_holds_allocator(graph.k.c, type) {
		out.unknown = true
	}
	return out
}

// design.md "@(allocator_reset)": a read of `type` through `carrier`, whose targets are not
// all known, is in what the carrier views, and names an allocator the analysis cannot name
// only if what it reads holds one: a handle beside it in the pointee backs none of it.
@(private = "file")
prov_unknown_target_read :: proc(graph: ^Flow_Graph, carrier: Value_Id, found: Region_Set, type: Type_Id) -> Region_Set {
	out := found
	region_merge(&out, prov_viewed_region(graph, carrier, whole = false))
	region_read_through(&out, prov_loaded_read(graph.k.c, type))
	return prov_unnamed_allocator(graph, out, false, type)
}

@(private = "file")
prov_read_region :: proc(graph: ^Flow_Graph, id: Value_Id) -> Region_Set {
	out, known := prov_read_storage_regions(graph, id, nil, .All)
	if known { return out }
	if carrier := prov_place_carrier(graph, id); carrier != 0 {
		return prov_unknown_target_read(graph, carrier, out, prov_value(graph, id).type)
	}
	operand: Value_Id
	#partial switch form in prov_value(graph, id).form {
	case Prov_Form_Index:
		operand = form.operand
	case Prov_Form_Selector:
		if form.field {
			operand = form.operand
		}
	}
	if operand == 0 {
		return out
	}
	region_merge(&out, prov_storage_region(graph, operand))
	return prov_unnamed_allocator(graph, out, false, prov_value(graph, id).type)
}

// A loop element is in the storage of what the loop iterates. A `&mut` leaf,
// `traversed`, names it there at `element` below what the loop iterates, so
// what is stored through the leaf is in that storage too (design.md "Allocator
// regions and region provenance"), as for a borrowed case binding.
@(private)
prov_bind_element_region :: proc(graph: ^Flow_Graph, id: Symbol_Id, iterable: Value_Id, element: []Proj_Step = nil, traversed := false) {
	recorded := prov_effect_active(graph) && prov_effect_symbol_relevant(graph, id)
	if recorded { prov_effect_begin(graph, Prov_Effect_Element{id, iterable, prov_effect_path(graph, element), traversed}) }
	defer prov_effect_end(graph, recorded)
	sym := symbol_of(graph.k.c, id)
	if sym != nil && traversed && prov_type_has_region(graph.k.c, sym.type) {
		prov_bind_traversal_aliases(graph, id, iterable, element)
	}
	if sym == nil || !(type_is_managed(graph.k.c, sym.type) || type_is_carrier(graph.k.c, sym.type)) {
		return
	}
	if set := prov_storage_region(graph, iterable); !region_is_empty(set) {
		prov_merge_region_of(graph, id, set)
	}
}

// The storage a `&mut` loop leaf names: where the source is, or what its
// carriers may reach, with an unresolved alternative when that is not all
// known (`Prov_Region_Alias`).
@(private = "file")
prov_bind_traversal_aliases :: proc(graph: ^Flow_Graph, id: Symbol_Id, iterable: Value_Id, element: []Proj_Step) {
	carrier := type_is_carrier(graph.k.c, prov_value(graph, iterable).type)
	aliases := make([dynamic]Prov_Region_Alias, graph.alloc)
	uncertain := false
	add :: proc(graph: ^Flow_Graph, id: Symbol_Id, aliases: ^[dynamic]Prov_Region_Alias, uncertain: ^bool, root: Root_Id, path: []Proj_Step, from: Value_Id = 0) {
		if root == NO_ROOT || prov_region_alias_reaches(graph, root, id) {
			uncertain^ = true
		} else {
			append(aliases, Prov_Region_Alias{root = root, path = path, from = from})
		}
	}
	if root, path, named := prov_value_place_of(graph, iterable); named && !carrier {
		add(graph, id, &aliases, &uncertain, root, prov_concat_path(graph, path, element), iterable)
	} else {
		below := carrier ? nil : prov_path_below_carrier(graph, iterable)
		for target in prov_written_targets(graph, iterable, as_place = !carrier) {
			at := prov_concat_path(graph, prov_concat_path(graph, target.at, below), element)
			add(graph, id, &aliases, &uncertain, prov_root_for_storage(graph, target.target), at)
		}
	}
	if uncertain || len(aliases) == 0 {
		append(&aliases, Prov_Region_Alias{root = NO_ROOT})
	}
	graph.region_aliases[id] = aliases[:]
}

// The region an `arena.allocator()` names; unknown unless the receiver is a
// named provider.
@(private)
prov_handle_region :: proc(graph: ^Flow_Graph, v: ^Expr_Call, receiver: Value_Id) -> (Region_Set, bool) {
	if call_provider_op(graph.k.c, v) != .Handle || len(v.bound) == 0 {
		return Region_Set{}, false
	}
	id := receiver
	receiver := prov_value(graph, id)
	if ident, is_ident := receiver.form.(Prov_Form_Symbol); is_ident {
		if set, found := graph.region_of[ident.symbol]; found {
			return set, true
		}
	} else if receiver.temporary {
		return prov_temp_provider_region(graph, v), true
	} else if root, path, ok := prov_root_place(graph, receiver.place); ok {
		// A provider inside a local record or container: the token of its position.
		if descriptor := graph.roots[int(root)]; descriptor.kind == .Local && descriptor.symbol != INVALID_SYMBOL {
			return prov_provider_region_at(graph, descriptor.symbol, path), true
		}
	}
	if set, known := prov_provider_through_carrier(graph, id); known {
		return set, true
	}
	return Region_Set{unknown = true}, true
}

// A provider reached through a carrier, when that names one: what a local pointer
// points at, or what a call's result does, which for a handle's `get()` is the
// handle, whose end ends the provider (design.md "Shared ownership"). What a received
// carrier reaches is its argument's, which the parameter's position names.
@(private = "file")
prov_provider_through_carrier :: proc(graph: ^Flow_Graph, id: Value_Id) -> (Region_Set, bool) {
	value := prov_value(graph, id)
	carrier := id
	if base, indirect := value.place.base.(Value_Id); indirect { carrier = base }
	if !prov_type_is_view_carrier(graph.k.c, prov_value(graph, carrier).type) { return {}, false }
	aliases := prov_value_aliases(graph, carrier)
	if len(aliases) == 0 { return {}, false }
	set := Region_Set{}
	// A place reached through the carrier is that part of what it views.
	viewed := underlying_info(graph.k.c, prov_value(graph, carrier).type).element
	below: []Proj_Step
	if carrier != id { viewed, below = value.type, value.place.path }
	for alias in aliases {
		at := alias
		at.at = prov_concat_path(graph, alias.at, below)
		if !prov_merge_provider_viewed(graph, at, viewed, &set, 0) { return {}, false }
	}
	return set, true
}

// Merges the regions of the providers a value of type `viewed` at `alias` reaches: those
// it owns, and those the carriers it holds point at, as the elements of a `[]^mut Arena`
// do, or an arena beside a pointer to another. False when one of them names no provider
// this body knows.
@(private = "file")
prov_merge_provider_viewed :: proc(graph: ^Flow_Graph, alias: Written_Alias, viewed: Type_Id, set: ^Region_Set, depth: int) -> bool {
	c := graph.k.c
	if alias.target == 0 || depth >= CARRIER_DEPTH { return false }
	// Named apart: asking may add the root.
	root := prov_root_for_storage(graph, alias.target)
	descriptor := graph.roots[int(root)]
	holder := symbol_of(c, descriptor.symbol)
	if holder != nil && holder.kind == .Parameter {
		received, seeded := graph.region_of[descriptor.symbol]
		if !seeded || !prov_type_is_view_carrier(c, holder.type) { return false }
		region_merge(set, received)
		return true
	}
	named := false
	for carrier in carrier_shape(c, viewed) {
		if !prov_view_reaches_provider(c, carrier.type) { continue }
		held := prov_written_aliases_of(graph, alias.target, prov_concat_path(graph, alias.at, carrier.steps))
		if len(held) == 0 { return false }
		element := underlying_info(c, carrier.type).element
		for loaded in held {
			if !prov_merge_provider_viewed(graph, loaded, element, set, depth + 1) { return false }
		}
		named = true
	}
	if type_carries_provider(c, viewed) {
		if descriptor.kind != .Local || holder == nil || holder.kind != .Var { return false }
		region_merge(set, prov_provider_region_at(graph, descriptor.symbol, alias.at))
		named = true
	}
	return named
}

// The regions of the providers a carrier argument reaches, which a callee naming its
// parameter's region may have drawn from: unknown when the carrier names no one of them.
@(private)
prov_provider_viewed_by :: proc(graph: ^Flow_Graph, id: Value_Id) -> Region_Set {
	c := graph.k.c
	type := prov_value(graph, id).type
	if !prov_view_reaches_provider(c, type) {
		return {}
	}
	if set, known := prov_provider_through_carrier(graph, id); known {
		return set
	}
	return Region_Set{unknown = true}
}

// Whether a carrier views a provider, directly or through a carrier held in what it
// views, at any place there. A shape cut short may hold anything, so it may reach one.
@(private = "file")
prov_view_reaches_provider :: proc(c: ^Compiler, type: Type_Id) -> bool {
	visited := make(map[Type_Id]bool, 8, context.temp_allocator)
	return prov_view_reach_walk(c, type, &visited)
}

@(private = "file")
prov_view_reach_walk :: proc(c: ^Compiler, type: Type_Id, visited: ^map[Type_Id]bool) -> bool {
	if visited[type] || !prov_type_is_view_carrier(c, type) {
		return false
	}
	visited[type] = true
	viewed := underlying_info(c, type).element
	if type_carries_provider(c, viewed) {
		return true
	}
	for carrier in carrier_shape(c, viewed) {
		if .Width in carrier.precision || .Depth in carrier.precision || prov_view_reach_walk(c, carrier.type, visited) {
			return true
		}
	}
	return false
}

Temp_Provider :: struct {
	bit:  u64,
	span: Span,
}

// The value a `return` hands back, or the error an `or_return` propagates into
// `result`; its region is read where a deferred reset needs it.
Prov_Returning :: struct {
	value:      Value_Id,
	propagated: Maybe(Prov_Form_Error),
	result:     Type_Id,
	span:       Span,
}

// design.md "Allocator regions and region provenance": a temporary provider is
// a local region that ends with its statement, so its handle gets a token of
// its own, ended there. Unknown once the tokens run out.
@(private = "file")
prov_temp_provider_region :: proc(graph: ^Flow_Graph, v: ^Expr_Call) -> Region_Set {
	set := Region_Set{}
	bit, found := graph.temp_provider_bits[v]
	if !found {
		if len(graph.provider_symbols) >= REGION_LOCAL_LIMIT {
			set.unknown = true
			return set
		}
		bit = u64(1) << u64(len(graph.provider_symbols))
		append(&graph.provider_symbols, INVALID_SYMBOL)
		graph.temp_provider_bits[v] = bit
	}
	set.locals = bit
	return set
}

@(private)
prov_temp_provider_end :: proc(graph: ^Flow_Graph, provider: Temp_Provider, live: Reset_Liveness) {
	set := Region_Set{}
	set.locals = provider.bit
	prov_reset(graph, set, provider.span, true, nil, live, ends = "this temporary allocator, which ends with its statement,", provider_end = true)
}

// Exact constructor facts: backing storage is separate from payload fields,
// and a fallible result keeps each variant under its own field step.
@(private = "file")
prov_constructed_region_at :: proc(graph: ^Flow_Graph, id: Value_Id, path: []Proj_Step, query: Region_Query) -> (Region_Set, bool) {
	c := graph.k.c
	out := Region_Set{}
	value := prov_value(graph, id)
	form := value.form.(Prov_Form_Call)
	v, bound := form.call, prov_bound_values(form)
	payload, fallible := shared_constructor_payload(c, v)
	shared_copy := prov_call_keeps_shared_handle(graph, v, value.type)
	if payload == nil && !shared_copy { return out, false }
	path := path
	if shape, ok := fallible_of(graph.k.c, value.type); ok && (fallible || shared_copy) {
		if len(path) == 0 || path[0].kind != .Field || path[0].lo != i64(shape.success) { return out, true }
		path = path[1:]
	}
	// The payload is the first bound argument.
	if shared_copy { return prov_source_region_at(graph, bound[0], path, query), true }
	if len(path) == 0 { return prov_allocation_region(graph, bound), true }
	if expression_is_borrowed_place(payload) {
		return prov_clone_region_at(graph, bound, prov_value(graph, bound[0]).type, path[1:], query), true
	}
	return prov_result_region_at(graph, bound[0], path[1:], query), true
}

// Whether a logical copy can keep an input's allocation instead of allocating
// fresh storage. Mutable containers only qualify through their contents.
@(private = "file")
prov_type_shares_region :: proc(c: ^Compiler, type: Type_Id) -> bool {
	for content in region_field_shape(c, type, context.temp_allocator) {
		part := prov_type_at(c, type, content.path)
		if type_underlying(c, part) == TYPE_STRING || type_is_shared_handle(c, part) || type_is_carrier(c, part) { return true }
		// An aggregate leaf is a precision cut, not proof of independent storage.
		if !content.own {
			#partial switch underlying_kind(c, part) {
			case .Struct, .Union, .Array, .Dynamic_Array, .Map, .Box: return true
			}
		}
	}
	return false
}

// Whether a call on a shared handle gives back a handle to its control block: a
// strong copy, a weak handle, or a successful upgrade.
@(private = "file")
prov_call_keeps_shared_handle :: proc(graph: ^Flow_Graph, v: ^Expr_Call, type: Type_Id) -> bool {
	return prov_receiver_is_shared_handle(graph, v) && len(v.bound) > 0 && prov_type_or_wrapped(graph.k.c, type, type_is_shared_handle)
}

// The region of a call result: a direct summary substituted by position, or
// conservative input dependencies when no body is available.
@(private)
prov_call_region :: proc(graph: ^Flow_Graph, id: Value_Id, result_type: Type_Id) -> Region_Set {
	c := graph.k.c
	out := Region_Set{}
	form := prov_value(graph, id).form.(Prov_Form_Call)
	v, bound := form.call, prov_bound_values(form)
	allocator_result := prov_carries_allocator(c, result_type)
	// A diverging call's value is never produced, so it is in no region.
	if (!type_is_managed(c, result_type) && !allocator_result) || call_diverges(c, v) {
		return out
	}
	if transfer := prov_value_transfer(graph, id); transfer != nil {
		return prov_transfer_region(graph, transfer, nil, .All)
	}
	// design.md "Shared ownership": the control block is an allocation of
	// the selected allocator, even though its library record holds a raw pointer.
	if payload, _ := shared_constructor_payload(c, v); payload != nil {
		region_merge(&out, prov_allocation_region(graph, bound))
		if expression_is_borrowed_place(payload) {
			region_merge(&out, prov_clone_region_at(graph, bound, prov_value(graph, bound[0]).type, nil))
		} else {
			region_merge(&out, prov_region_of(graph, bound[0]))
		}
		return out
	}
	// Strong copies, weak handles, and successful upgrades keep the same
	// control block and therefore its region.
	if prov_call_keeps_shared_handle(graph, v, result_type) {
		return prov_storage_region(graph, bound[0])
	}
	if operation, conversion := v.operation.(Call_Text_Conversion); conversion && text_conversion_copies(operation.op) {
		return Region_Set{default = true}
	}
	if sym := symbol_of(c, v.resolution.symbol); sym != nil && sym.builtin == .Default_Allocator {
		return Region_Set{default = true}
	}
	// Also here, because a stored call result is consulted before `prov_region_of`.
	if set, ok := prov_handle_region(graph, v, prov_receiver_value(form.arguments)); ok {
		return set
	}
	// A fixed arena has no region parent; its buffer is an ordinary loan.
	if call_provider_op(c, v) == .Open_Fixed {
		return out
	}
	callee := call_contract_declaration(c, v)
	direct := prov_has_direct_body(c, callee)
	prov_note_summary_dependency(graph, callee)
	if summary, found := result_summary(c, callee); found {
		region_merge(&out, prov_substitute_region(graph, form, summary.region))
	}
	if direct {
		return out
	}
	info := underlying_info(c, call_proc_type(c, v))
	for argument, index in bound {
		if argument == 0 {
			continue
		}
		moved := param_mode_at(info, index) == .Move
		if moved || type_underlying(c, prov_value(graph, argument).type) == TYPE_ALLOCATOR {
			// design.md "Allocator regions and region provenance": without a body
			// to follow, an owner built with an allocator argument takes its
			// region. A direct call's summary already names the allocators its
			// result is built with, so one the body never uses backs nothing.
			region_merge(&out, prov_region_of(graph, argument))
		} else if prov_type_shares_region(c, result_type) {
			// A procedure value has no result summary. Logical copies may retain
			// borrowed inputs, even when a destination allocator is also supplied.
			region_merge(&out, prov_storage_region(graph, argument))
		}
	}
	out.unknown ||= region_is_empty(out)
	return out
}

// design.md "Allocator regions and region provenance": allocating copies use
// the destination allocator, while strings, shared handles, and borrowed parts
// keep their source regions. Generated clones apply that rule recursively.
Prov_Region_Copy :: struct {
	value: Value_Id,
	allocator: Region_Set,
	as_type: Type_Id,
	prefix: []Proj_Step,
}

@(private = "file")
prov_copy_source_region_at :: proc(graph: ^Flow_Graph, source: Prov_Region_Copy, path: []Proj_Step, query := Region_Query.All) -> Region_Set {
	return prov_source_region_at(graph, source.value, prov_concat_path(graph, source.prefix, path), query, source.as_type)
}

// An explicit clone's regions: `bound[0]` copied into the allocator its other
// operands name.
@(private = "file")
prov_clone_region_at :: proc(graph: ^Flow_Graph, bound: []Value_Id, type: Type_Id, path: []Proj_Step, query := Region_Query.All) -> Region_Set {
	return prov_copied_region_at(graph, Prov_Region_Copy{value = bound[0], allocator = prov_allocation_region(graph, bound)}, type, path, query)
}

// The regions at `path` of a copy of `source` as `type`: new storage in the
// copy's allocator, logical copies keep the source's.
@(private)
prov_copied_region_at :: proc(graph: ^Flow_Graph, source: Prov_Region_Copy, type: Type_Id, path: []Proj_Step, query: Region_Query) -> Region_Set {
	type := type
	for step, index in path {
		if type_is_shared_handle(graph.k.c, type) {
			return prov_copy_source_region_at(graph, source, path, query)
		}
		if hook := lifecycle_of(graph.k.c, type).custom_try_clone; hook != INVALID_SYMBOL {
			return prov_copy_hook_region(graph, source, hook, path[:index], path[index:], query)
		}
		type = prov_type_at(graph.k.c, type, {step})
	}
	return prov_copied_type_region(graph, source, type, path, query)
}

@(private = "file")
prov_allocation_region :: proc(graph: ^Flow_Graph, bound: []Value_Id) -> Region_Set {
	if len(bound) > 1 && bound[1] != 0 { return prov_region_of(graph, bound[1]) }
	return Region_Set{default = true}
}

@(private = "file")
prov_source_region_at :: proc(graph: ^Flow_Graph, id: Value_Id, path: []Proj_Step, query := Region_Query.All, as_type := INVALID_TYPE) -> Region_Set {
	value := prov_value(graph, id)
	if address, ok := value.form.(Prov_Form_Unary); ok && address.op == .Amp {
		return prov_result_region_at(graph, address.operand, path, query)
	}
	if type_is_carrier(graph.k.c, value.type) {
		return prov_storage_region(graph, id)
	}
	return prov_result_region_at(graph, id, path, query, as_type)
}

// Merges into `out` what `contents` hold at `path`, each entry's own query and
// depth applied; false when none is there.
@(private = "file")
prov_merge_matching_content :: proc(out: ^Region_Set, contents: []Prov_Region_Content, path: []Proj_Step, query: Region_Query) -> (matched: bool) {
	for content in contents {
		if query == .Own && (!content.own || !prov_same_path(content.path, path)) { continue }
		if content.own && len(content.path) < len(path) { continue }
		if paths_overlap(content.path, path) {
			matched = true
			region_merge(out, content.region)
		}
	}
	return
}

@(private = "file")
prov_copy_hook_region :: proc(graph: ^Flow_Graph, source: Prov_Region_Copy, hook: Symbol_Id, prefix, path: []Proj_Step, query: Region_Query) -> Region_Set {
	c := graph.k.c
	prov_note_summary_dependency(graph, hook)
	summary, found := result_summary(c, hook)
	out := Region_Set{}
	if !found {
		region_merge(&out, prov_copy_source_region_at(graph, source, prefix))
		region_merge(&out, source.allocator)
		return out
	}
	set := summary.region
	if len(path) > 0 || query != .All {
		projected_path := path
		if shape, ok := fallible_of(graph.k.c, summary.content_type); ok {
			projected_path = prov_concat_path(graph, prov_extend(graph, nil, proj_field(shape.success)), path)
		}
		projected: Region_Set
		if prov_merge_matching_content(&projected, summary.region_content, projected_path, query) { set = projected }
	}
	if region_has_param(set, 0) { region_merge(&out, prov_copy_source_region_at(graph, source, prefix)) }
	if region_has_param(set, 1) { region_merge(&out, source.allocator) }
	out.default ||= set.default
	out.unknown ||= set.unknown
	return out
}

@(private = "file")
prov_copied_type_region :: proc(graph: ^Flow_Graph, source: Prov_Region_Copy, type: Type_Id, path: []Proj_Step, query: Region_Query, depth := 0) -> Region_Set {
	c := graph.k.c
	out := Region_Set{}
	if !prov_type_has_region(c, type) { return out }
	if depth > REGION_SHAPE_DEPTH {
		region_merge(&out, prov_copy_source_region_at(graph, source, path))
		region_merge(&out, source.allocator)
		return out
	}
	if type_underlying(c, type) == TYPE_STRING || type_underlying(c, type) == TYPE_ALLOCATOR || type_is_shared_handle(c, type) || type_is_carrier(c, type) {
		return prov_copy_source_region_at(graph, source, path, query)
	}
	if hook := lifecycle_of(c, type).custom_try_clone; hook != INVALID_SYMBOL {
		return prov_copy_hook_region(graph, source, hook, path, nil, query)
	}
	info := underlying_info(c, type)
	if info == nil { return out }
	if query == .Own {
		if info.kind == .Dynamic_Array || info.kind == .Map || info.kind == .Box {
			return source.allocator
		}
		return out // a generated inline copy is fresh
	}
	#partial switch info.kind {
	case .Struct:
		for field, index in info.fields {
			if sym := symbol_of(c, field); sym != nil {
				region_merge(&out, prov_copied_type_region(graph, source, sym.type, prov_extend(graph, path, proj_field(index)), query, depth + 1))
			}
		}
	case .Union:
		for variant, index in info.variants {
			if variant != TYPE_VOID { region_merge(&out, prov_copied_type_region(graph, source, variant, prov_extend(graph, path, proj_field(index)), query, depth + 1)) }
		}
	case .Array, .Dynamic_Array, .Box, .Map:
		if info.kind != .Array { region_merge(&out, source.allocator) }
		elements := prov_extend(graph, path, proj_wild())
		if info.kind == .Map {
			region_merge(&out, prov_copied_type_region(graph, source, info.key, prov_extend(graph, elements, proj_field(PROJ_MAP_KEY)), query, depth + 1))
			elements = prov_extend(graph, elements, proj_field(PROJ_MAP_VALUE))
		}
		region_merge(&out, prov_copied_type_region(graph, source, info.element, elements, query, depth + 1))
	}
	return out
}

@(private)
prov_substitute_region :: proc(graph: ^Flow_Graph, form: Prov_Form_Call, summary: Region_Set) -> Region_Set {
	out := Region_Set{}
	bound := prov_bound_values(form)
	merge_argument := proc(graph: ^Flow_Graph, out: ^Region_Set, argument: Value_Id, loaded, handles: bool) {
		if argument != 0 {
			region_merge(out, prov_storage_region(graph, argument))
			region_merge(out, prov_provider_viewed_by(graph, argument))
			if loaded {
				region_merge(out, prov_reached_regions(graph, argument, handles))
			}
		}
	}
	params := summary.params
	for index in next_region_param(&params) {
		loaded, handles := region_has_loaded_param(summary, index), region_loaded_read(summary, index) != .Owners
		// A pack built from separate arguments has no bound value: the parameter's
		// region is its elements'.
		if call_packs(form.call, index) {
			for element in form.pack {
				merge_argument(graph, &out, element, loaded, handles)
			}
		} else if index < len(bound) {
			merge_argument(graph, &out, bound[index], loaded, handles)
		}
	}
	out.default ||= summary.default
	out.unknown ||= summary.unknown
	// Summary-local regions are reported in their own body, not substituted.
	return out
}

// Each summarized result field's region at the call site, or nil to use the
// whole-result region.
@(private)
prov_call_region_content :: proc(graph: ^Flow_Graph, id: Value_Id) -> []Prov_Region_Content {
	form := prov_value(graph, id).form.(Prov_Form_Call)
	v := form.call
	if transfer := prov_value_transfer(graph, id); transfer != nil {
		out := region_field_shape(graph.k.c, prov_value(graph, id).type, graph.alloc)
		for &content in out {
			content.region = prov_transfer_region(graph, transfer, content.path, content.own ? .Own : .All)
		}
		return out
	}
	callee := call_contract_declaration(graph.k.c, v)
	summary, found := result_summary(graph.k.c, callee)
	if !found || len(summary.region_content) == 0 {
		return nil
	}
	out := make([]Prov_Region_Content, len(summary.region_content), graph.alloc)
	for content, index in summary.region_content {
		out[index] = Prov_Region_Content {
			path = slice.clone(content.path, graph.alloc),
			region = prov_substitute_region(graph, form, content.region),
			handle = content.handle,
			own = content.own,
		}
	}
	return out
}

// A reset may end every allocation in its region (design.md "@(allocator_reset)"): checked for its
// promise and for live owners it would strand.
@(private)
prov_reset :: proc(
	graph: ^Flow_Graph,
	region: Prov_Reset_Region,
	span: Span,
	direct: bool,
	at: ^Expr_Call,
	cleanup_live: Reset_Liveness = {},
	ends := "",
	ending := INVALID_SYMBOL,
	provider_end := false,
) {
	// Liveness is lifecycle's answer, recorded one pass earlier.
	live := cleanup_live
	if at != nil {
		found: bool
		live, found = graph.k.c.reset_dead[reset_key(graph, at)]
		assert(found, "the provenance walk reached a reset the lifecycle walk did not")
	}
	if graph.current == NO_BLOCK {
		return
	}
	held := make([]Value_Id, len(graph.held_owners), graph.alloc)
	for value, index in graph.held_owners { held[index] = prov_input_value(graph, value) }
	temporaries := make([dynamic]Root_Id, 0, len(graph.temp_roots), graph.alloc)
	append(&temporaries, ..graph.temp_roots[:])
	for cleanup in graph.in_scope {
		if cleanup.kind == .Prov_Root { append(&temporaries, cleanup.root) }
	}
	op := Prov_Event_Reset {
		region = region, span = span, direct = direct, live = live, ends = ends, ending = ending,
		provider_end = provider_end, held = held, temporaries = temporaries[:],
	}
	if graph.expansion.unwinding { op.unwind_from = graph.unwind_at }
	if graph.returning != nil { op.returning = graph.returning^ }
	prov_event(graph, op)
}

// design.md "Evaluation order": an owned value already evaluated is live
// while later operands run, even when its named source has been moved.
@(private)
prov_hold_owner :: proc(graph: ^Flow_Graph, value: Expr) {
	if value != nil && type_is_managed(graph.k.c, prov_type(graph, value)) && !expression_is_borrowed_place(value) {
		append(&graph.held_owners, value)
	}
}

// design.md "Evaluation order": a managed place given to `box` is read when it is
// reached but cloned from the allocator evaluated after it, so it stays
// borrowed until then, as a call's argument does.
@(private)
prov_lend_copied_place :: proc(graph: ^Flow_Graph, value: Expr) -> []int {
	if !type_is_managed(graph.k.c, prov_type(graph, value)) || !expression_is_borrowed_place(value) {
		return nil
	}
	if root, path, named := prov_place_of(graph, value); named && !expression_converts_storage(value) {
		return prov_borrow(graph, root, path, false, expr_span(value), "borrow")
	}
	if carriers, _, through := prov_read_through_carrier(graph, value, reads_only = true); through {
		return prov_reborrow_traversal(graph, carriers, expr_span(value), false)
	}
	return nil
}

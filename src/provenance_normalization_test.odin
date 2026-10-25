package lokec

import "core:mem"
import "core:slice"
import "core:strings"
import "core:testing"

// These inspect the existing semantic boundary before normalization replaces
// its AST queries. Assert identities, paths, and decisions, not temporary IDs
// or complete graph dumps. See provenance-normalization-proposal.md.
@(private = "file")
normalization_checked :: proc(t: ^testing.T, p: ^Checked, source: string) -> bool {
	check_source(p, source)
	if !testing.expectf(t, p.c.error_count == 0, "checking failed: %v", p.c.diagnostics[:]) { return false }
	k := Checker{c = &p.c}
	analyze_program_provenance(&k)
	return testing.expectf(t, p.c.error_count == 0, "provenance failed: %v", p.c.diagnostics[:])
}

@(private = "file")
normalization_body :: proc(t: ^testing.T, p: ^Checked, name: string) -> ^Expr_Proc {
	for body in p.c.checked_bodies {
		if identifier_text(&p.c, symbol_of(&p.c, body.literal.symbol).name) == name { return body.literal }
	}
	testing.expectf(t, false, "missing body %s", name)
	return nil
}

@(private = "file")
normalization_graph :: proc(t: ^testing.T, k: ^Checker, p: ^Checked, name: string) -> ^Flow_Graph {
	body := normalization_body(t, p, name)
	if body == nil { return nil }
	k.c = &p.c
	return build_flow_graph(k, body, .Prov_Diagnose)
}

// The parameter facts a body starts from, before any of its operations.
@(private = "file")
normalization_parameter_seed :: proc(k: ^Checker, graph: ^Flow_Graph, program: ^Prov_Effect_Program) -> ^Flow_Graph {
	entry := new_flow_graph(k, graph.literal, graph.alloc, graph.mode, normalized_input = program.input)
	prov_bind_parameters(entry, graph.literal)
	return entry
}

@(private = "file")
normalization_symbol :: proc(t: ^testing.T, p: ^Checked, name: string) -> Symbol_Id {
	for sym, index in p.c.symbols {
		if sym != nil && identifier_text(&p.c, sym.name) == name { return Symbol_Id(index) }
	}
	testing.expectf(t, false, "missing symbol %s", name)
	return INVALID_SYMBOL
}

@(private = "file")
normalization_decl :: proc(t: ^testing.T, p: ^Checked, body: ^Expr_Proc, name: string) -> ^Decl {
	for stmt in body.body.stmts {
		if decl, ok := stmt.(^Decl); ok {
			for id in decl.symbols {
				if identifier_text(&p.c, symbol_of(&p.c, id).name) == name { return decl }
			}
		}
	}
	testing.expectf(t, false, "missing declaration %s", name)
	return nil
}

// design.md "Values that contain borrows", "Allocator regions and region provenance".
@(test)
normalization_storage_and_cleanup_contract :: proc(t: ^testing.T) {
	p: Checked
	defer destroy_checked(&p)
	if !normalization_checked(t, &p, `package main;
storage :: proc(initial_region: Allocator, stored_region: Allocator) {
    hidden := []mut Option([dynamic]int){.some(make([dynamic]int, 1, initial_region))};
    alias := hidden;
    switch (alias[0]) {
    case .some(&mut payload): payload = make([dynamic]int, 2, stored_region);
    case .none:
    }
}
main :: proc() {}`) { return }
	k: Checker
	graph := normalization_graph(t, &k, &p, "storage")
	if graph == nil { return }
	hidden := normalization_symbol(t, &p, "hidden")
	alias := normalization_symbol(t, &p, "alias")
	first := graph.written_aliases[prov_storage_id(graph, Written_Storage{symbol = hidden})]
	second := graph.written_aliases[prov_storage_id(graph, Written_Storage{symbol = alias})]
	if !testing.expect(t, len(first) == 1 && len(second) == 1, "both views must identify one backing object") { return }
	storage := first[0].target
	testing.expect(t, storage == second[0].target && prov_storage(graph, storage).key.temporary != nil, "copied views lost anonymous storage identity")
	testing.expect(t, underlying_kind(&p.c, prov_storage(graph, storage).type) == .Array, "a slice descriptor is not its hidden array")
	root, found := graph.root_by_storage[storage]
	if !testing.expect(t, found, "backing storage has no cleanup root") { return }
	bindings := graph.region_aliases[normalization_symbol(t, &p, "payload")]
	if testing.expect(t, len(bindings) == 1, "the borrowed payload must have one known destination") {
		testing.expect(t, bindings[0].root == root, "the payload binding created a second owner")
		path := bindings[0].path
		shape, _ := fallible_of(&k, underlying_info(&p.c, prov_storage(graph, storage).type).element)
		testing.expectf(t, len(path) == 2 && (path[0].kind == .Wild || (path[0].kind == .Range && path[0].lo == 0)) &&
		                   path[1].kind == .Field && path[1].lo == i64(shape.success),
		                "the payload lost its array-element and variant projections: %v", path)
	}
	initial, stored := false, false
	for content in graph.region_content[storage] {
		if content.handle || len(content.region.params) < 2 { continue }
		initial ||= content.region.params[0]
		stored ||= content.region.params[1]
	}
	testing.expect(t, initial && stored, "initial or later stored owners lost their received region")
	ended := false
	for block in graph.blocks {
		for event in block.prov { ended ||= event.kind == .Root_End && event.root == root }
	}
	testing.expect(t, ended, "the backing object has no actual cleanup event")
	// A second build may number roots differently, but must use the same storage
	// key. Keeping both graphs here also exposes accidental references to a
	// reclaimed pass buffer under the unit suite's memory tracking.
	again := build_flow_graph(&k, graph.literal, .Prov_Diagnose)
	key := prov_storage(graph, storage).key
	corresponding := again.input.storage_ids[key]
	_, retained := again.root_by_storage[corresponding]
	testing.expect(t, retained, "storage correspondence changed across graph builds")
}

// design.md "Storage roots and borrow carriers", "Allocator regions and region provenance".
@(test)
normalization_address_and_unknown_target_contract :: proc(t: ^testing.T) {
	p: Checked
	defer destroy_checked(&p)
	if !normalization_checked(t, &p, `package main;
untracked: []mut int;
targets :: proc(choose: bool) {
    destination := [1]int{1};
    pointer := &mut destination[:];
    if (choose) { pointer = untracked; }
    descriptor := &mut pointer;
    descriptor^ = &mut destination[:];
}
main :: proc() {}`) { return }
	k: Checker
	graph := normalization_graph(t, &k, &p, "targets")
	if graph == nil { return }
	pointer := normalization_symbol(t, &p, "pointer")
	destination := normalization_symbol(t, &p, "destination")
	known, unknown := false, false
	for alias in graph.written_aliases[prov_storage_id(graph, Written_Storage{symbol = pointer})] {
		known ||= prov_storage(graph, alias.target).key.symbol == destination
		unknown ||= alias.target == 0
	}
	testing.expectf(t, known && unknown, "a known assignment erased an unresolved alternative: %v", graph.written_aliases[prov_storage_id(graph, Written_Storage{symbol = pointer})])
	addresses := graph.written_aliases[prov_storage_id(graph, Written_Storage{symbol = normalization_symbol(t, &p, "descriptor")})]
	if testing.expect(t, len(addresses) == 1, "taking an address must name only that storage") {
		testing.expect(t, prov_storage(graph, addresses[0].target).key.symbol == pointer, "the descriptor's address was replaced by its pointee")
	}
}

// design.md "Last-use transfer", "Allocator regions and region provenance".
@(test)
normalization_checked_transfer_contract :: proc(t: ^testing.T) {
	p: Checked
	defer destroy_checked(&p)
	if !normalization_checked(t, &p, `package main;
transfers :: proc() {
    original := make([dynamic]int, 1);
    copied := original;
    assert(original.len() == 1);
    moved := move(original);
    last := copied;
}
main :: proc() {}`) { return }
	body := normalization_body(t, &p, "transfers")
	if body == nil { return }
	copied := normalization_decl(t, &p, body, "copied")
	moved := normalization_decl(t, &p, body, "moved")
	last := normalization_decl(t, &p, body, "last")
	if copied == nil || moved == nil || last == nil { return }
	testing.expect(t, len(copied.value_clones) == 1 && copied.value_clones[0], "a still-used owner must clone")
	for decl in ([]^Decl{moved, last}) {
		testing.expectf(t, len(decl.value_clones) == 0 || !decl.value_clones[0], "a settled move must not clone: %v", decl.value_clones)
		_, moves := decl.values[0].(^Expr_Move)
		testing.expect(t, moves, "normalization must consume the checked move decision")
	}
}

// design.md "Allocator regions and region provenance".
@(test)
normalization_summary_and_custom_copy_contract :: proc(t: ^testing.T) {
	p: Checked
	defer destroy_checked(&p)
	if !normalization_checked(t, &p, `package main;
Held :: struct { values: [dynamic]int, view: []int }
impl Held {
    copy_held :: hook(copy) proc(self, allocator: Allocator) -> Result(Held, Allocator_Error) {
        return .ok(Held{self.values.clone(allocator), self.view});
    }
}
Nested :: struct { held: Held }
hooked :: proc(input: Nested) -> Nested { return input.clone(); }
fresh :: proc(source: ^[dynamic]int, allocator: Allocator) -> [dynamic]int { return source^.clone(allocator); }
transferred :: proc(source: move [dynamic]int) -> [dynamic]int { return move(source); }
Fields :: struct { handle: Allocator, items: [dynamic]int }
separate :: proc(handle: Allocator, allocator: Allocator) -> Fields { return Fields{handle, make([dynamic]int, 1, allocator)}; }
forward :: proc(input: []int, depth: int) -> []int { return recurse(input, depth); }
recurse :: proc(input: []int, depth: int) -> []int {
    if (depth == 0) { return input; }
    return forward(input, depth - 1);
}
main :: proc() {}`) { return }
	for name in ([]string{"hooked", "forward", "recurse"}) {
		body := normalization_body(t, &p, name)
		if body == nil { continue }
		summary, found := p.c.result_summaries[body.symbol]
		if !testing.expectf(t, found, "%s lost its result summary", name) { continue }
		testing.expectf(t, result_uses_param(summary.result.dependencies, 0) && !summary.result.local && !summary.result.unknown,
		                "%s lost its precise source dependency", name)
	}
	hooked := normalization_body(t, &p, "hooked")
	if hooked != nil {
		held := symbol_of(&p.c, normalization_symbol(t, &p, "Held")).type
		copy_hook := lifecycle_of(&p.c, held).custom_try_clone
		hook_summary, found := p.c.result_summaries[copy_hook]
		if testing.expect(t, copy_hook != INVALID_SYMBOL && found, "the checked copy hook must have a result summary") {
			testing.expect(t, result_uses_param(hook_summary.result.dependencies, 0), "the hook lost its borrowed input")
			testing.expect(t, len(hook_summary.result.region.params) > 1 && hook_summary.result.region.params[1], "the hook lost its destination allocator")
			testing.expect(t, slice.contains(p.c.result_summary_dependencies[hooked.symbol], copy_hook),
			               "a generated copy must register the nested checked hook's summary dependency")
		}
	}
	forward := normalization_body(t, &p, "forward")
	recurse := normalization_body(t, &p, "recurse")
	if forward != nil && recurse != nil {
		testing.expect(t, slice.contains(p.c.result_summary_dependencies[forward.symbol], recurse.symbol) &&
		                  slice.contains(p.c.result_summary_dependencies[recurse.symbol], forward.symbol),
		               "recursive calls must register both summary dependencies")
	}
	for name, index in ([]string{"fresh", "transferred"}) {
		copies := index == 0
		body := normalization_body(t, &p, name)
		if body == nil { continue }
		summary, found := p.c.result_summaries[body.symbol]
		if !testing.expect(t, found) { continue }
		region := summary.result.region
		testing.expect(t, len(region.params) > 0 && region.params[0] != copies, "a clone replaces backing while a move keeps it")
		if copies { testing.expect(t, len(region.params) > 1 && region.params[1], "new backing must use the destination allocator") }
	}
	separate := normalization_body(t, &p, "separate")
	if separate == nil { return }
	summary, found := p.c.result_summaries[separate.symbol]
	if !testing.expect(t, found) { return }
	handle, owner := false, false
	for content in summary.result.region_content {
		if len(content.path) != 1 || content.path[0].kind != .Field { continue }
		if !testing.expect(t, len(content.region.params) == 2, "field regions must retain the parameter shape") { continue }
		if content.path[0].lo == 0 && content.handle {
			handle ||= content.region.params[0] && !content.region.params[1]
		}
		if content.path[0].lo == 1 && content.own && !content.handle {
			owner ||= !content.region.params[0] && content.region.params[1]
		}
	}
	testing.expect(t, handle && owner, "an allocator handle contaminated the independent owner's region")
}

// design.md "Splitting a mutable slice", "Weakening and reborrows".
@(test)
normalization_delayed_receiver_contract :: proc(t: ^testing.T) {
	p: Checked
	defer destroy_checked(&p)
	if !normalization_checked(t, &p, `package main;
split :: proc(receiver: []mut int) -> int {
    halves := receiver.split_at_mut(receiver.len() / 2);
    return halves.left.len() + halves.right.len();
}
main :: proc() {}`) { return }
	k: Checker
	graph := normalization_graph(t, &k, &p, "split")
	if graph == nil { return }
	decl := normalization_decl(t, &p, graph.literal, "halves")
	if decl == nil { return }
	call, is_call := decl.values[0].(^Expr_Call)
	if !testing.expect(t, is_call && len(call.bound) == 2) { return }
	source, tracked := graph.slot_by_symbol[normalization_symbol(t, &p, "receiver")]
	if !testing.expect(t, tracked, "the mutable receiver must have a carrier slot") { return }
	found := false
	for reborrow in graph.reborrows {
		if reborrow.source != source || reborrow.span != expr_span(call.bound[0]) { continue }
		testing.expect(t, reborrow.mutable, "the split must take a mutable reborrow")
		capture, capture_at, lend_at := -1, -1, -1
		position := 0
		for block in graph.blocks {
			for event in block.prov {
				if event.kind == .Def && event.slot == reborrow.derived && len(event.sources) == 1 {
					capture, lend_at = event.sources[0], position
				}
				position += 1
			}
		}
		if !testing.expect(t, capture >= 0 && capture != source, "the delayed reborrow must use a captured value") { continue }
		position = 0
		read_between := false
		for block in graph.blocks {
			for event in block.prov {
				if event.kind == .Def && event.slot == capture && slice.contains(event.sources, source) { capture_at = position }
				if event.kind == .Live && slice.contains(event.sources, source) && capture_at >= 0 && position > capture_at && position < lend_at { read_between = true }
				position += 1
			}
		}
		testing.expect(t, capture_at >= 0 && capture_at < lend_at && read_between, "the receiver must remain readable between capture and reborrow")
		found = true
	}
	testing.expect(t, found, "the split lost its relation to the original mutable binding")
}

// design.md "Owned values", "Inspecting a union", "Temporaries and procedure boundaries".
@(test)
normalization_payload_and_owner_view_contract :: proc(t: ^testing.T) {
	p: Checked
	defer destroy_checked(&p)
	if !normalization_checked(t, &p, `package main;
payloads :: proc(allocator: Allocator) {
    owner_view: []int = make([dynamic]int, 1, allocator);
    optional: Option([dynamic]int) = .some(make([dynamic]int, 1, allocator));
    selected := optional.as(.some) or_else [dynamic]int{};
    boxed := box(make([dynamic]int, 1, allocator));
    unpacked := move(boxed).unbox();
}
main :: proc() {}`) { return }
	k: Checker
	graph := normalization_graph(t, &k, &p, "payloads")
	if graph == nil { return }
	view := normalization_decl(t, &p, graph.literal, "owner_view")
	selected := normalization_decl(t, &p, graph.literal, "selected")
	unpacked := normalization_decl(t, &p, graph.literal, "unpacked")
	if view == nil || selected == nil || unpacked == nil { return }
	base := expr_base(view.values[0])
	borrow, borrows := prov_value_transfer(graph, prov_input_value(graph, view.values[0])).(Prov_Transfer_Borrow)
	if testing.expect(t, borrows, "an owner view must normalize as a borrow") {
		testing.expect(t, borrow.storage != 0 && graph.input.values[int(borrow.owner)].type == base.view_from,
		               "the view must retain its original owner")
	}
	testing.expect(t, underlying_kind(&p.c, base.view_from) == .Dynamic_Array && underlying_kind(&p.c, base.type) == .Slice,
	               "an implicit view must retain the original owner type")
	materialized := false
	for storage, root in graph.root_by_storage {
		if prov_storage(graph, storage).key.temporary != base { continue }
		owner := graph.roots[int(root)]
		materialized ||= owner.extended && owner.dropped == base.view_from && owner.owner != nil
	}
	testing.expect(t, materialized, "an anonymous owner's cleanup ended with its view's last use")
	choice, is_choice := selected.values[0].(^Expr_Or_Else)
	if testing.expect(t, is_choice, "checked extraction must retain the fallback edge") {
		call, is_call := choice.value.(^Expr_Call)
		if testing.expect(t, is_call) {
			extraction, checked := call.operation.(Call_Union_As)
			shape, ok := fallible_of(&k, expr_base(call.bound[0]).type)
			testing.expect(t, checked && ok && extraction.index == shape.success, "the selected variant must remain checked metadata")
			transfer, transfers := prov_value_transfer(graph, prov_input_value(graph, call)).(Prov_Transfer_Forward)
			if testing.expect(t, transfers) {
				part := transfer.component
				result, _ := fallible_of(&k, call.type)
				testing.expect(t, part.mode == .Clone && part.copy.type == union_variant_payload(&p.c, expr_base(call.bound[0]).type, extraction.index),
				               "checked extraction must select the payload's copy operation")
				testing.expect(t, len(part.from) == 1 && part.from[0] == proj_field(extraction.index) &&
				                  len(part.to) == 1 && part.to[0] == proj_field(result.success), "extraction must remap the selected payload into success")
			}
		}
	}
	unbox, is_call := unpacked.values[0].(^Expr_Call)
	if testing.expect(t, is_call) {
		_, unboxes := unbox.operation.(Call_Box_Unbox)
		_, consumes := unbox.bound[0].(^Expr_Move)
		testing.expect(t, unboxes && consumes, "unboxing must consume the box rather than copy its payload")
		transfer, transfers := prov_value_transfer(graph, prov_input_value(graph, unbox)).(Prov_Transfer_Forward)
		if testing.expect(t, transfers) {
			part := transfer.component
			testing.expect(t, part.mode == .Move && len(part.from) == 1 && part.from[0].kind == .Wild && len(part.to) == 0,
			               "unbox must move out of the box payload without retaining its backing allocation")
		}
	}
}

// design.md "Allocator regions and region provenance", "Panics and unwinding".
@(test)
normalization_defer_reset_correspondence_contract :: proc(t: ^testing.T) {
	p: Checked
	defer destroy_checked(&p)
	if !normalization_checked(t, &p, `package main;
cleanups :: proc(@(allocator_reset) allocator: Allocator, early: bool) {
    marker: [dynamic]int = {};
    drop(marker);
    defer free_all(allocator);
    if (early) { return; }
}
main :: proc() {}`) { return }
	k: Checker
	body := normalization_body(t, &p, "cleanups")
	if body == nil { return }
	normal, abrupt := false, false
	for key, live in p.c.reset_dead {
		if key.body != body || key.expansion.deferred == nil || !live.reached { continue }
		normal ||= key.expansion.exit == nil
		abrupt ||= key.expansion.exit != nil
	}
	testing.expect(t, normal && abrupt, "each defer exit needs lifecycle reset correspondence")
	count := len(p.c.reset_dead)
	graph := normalization_graph(t, &k, &p, "cleanups")
	if graph == nil { return }
	testing.expect_value(t, len(p.c.reset_dead), count)
	resets := 0
	for block in graph.blocks {
		for event in block.prov { if event.kind == .Reset { resets += 1 } }
	}
	testing.expect(t, resets >= 2 && p.c.error_count == 0, "rebuilding provenance lost a deferred reset or changed lifecycle decisions")
}

// design.md "Temporaries and procedure boundaries", "Minimum provenance precision".
@(test)
normalization_diagnostic_origin_contract :: proc(t: ^testing.T) {
	p: Checked
	defer destroy_checked(&p)
	check_source(&p, `package main;
bad :: proc() -> []int { local := [1]int{1}; return local[:]; }
main :: proc() {}`)
	if !testing.expect(t, p.c.error_count == 0) { return }
	k := Checker{c = &p.c}
	analyze_program_provenance(&k)
	if !testing.expect(t, p.c.error_count == 1 && len(p.c.diagnostics) == 1) { return }
	diagnostic := p.c.diagnostics[0]
	testing.expect_value(t, diagnostic.code, "L0526")
	testing.expect_value(t, p.c.sources[diagnostic.span.file].text[diagnostic.span.lo:diagnostic.span.hi], "local[:]")
	testing.expect(t, strings.contains(diagnostic.message, "local"), "synthetic analysis names replaced the source owner")
}

// design.md "Storage roots and borrow carriers", "Places and overlap".
@(test)
normalization_place_boundaries_contract :: proc(t: ^testing.T) {
	p: Checked
	defer destroy_checked(&p)
	if !normalization_checked(t, &p, `package main;
Pair :: struct { left: int, right: int }
places :: proc(input: ^mut Pair, outer: ^mut ^mut Pair) {
    named := Pair{1, 2};
    other_named := Pair{3, 4};
    direct := &named.left;
    indirect := &input.left;
    nested := &outer^^.right;
}
main :: proc() {}`) { return }
	k: Checker
	graph := normalization_graph(t, &k, &p, "places")
	if graph == nil { return }
	for name, index in ([]string{"direct", "indirect", "nested"}) {
		decl := normalization_decl(t, &p, graph.literal, name)
		if decl == nil { continue }
		address, ok := decl.values[0].(^Expr_Unary)
		if !testing.expect(t, ok) { continue }
		place := prov_input_place(graph, address.operand)
		testing.expect(t, len(place.path) == 1 && place.path[0].kind == .Field, "a field projection must remain explicit")
		testing.expect_value(t, place.type, TYPE_INT)
		if index == 0 {
			storage, direct := place.base.(Storage_Id)
			if testing.expect(t, direct, "a lexical place must name storage") {
				testing.expect(t, prov_storage(graph, storage).key.symbol == normalization_symbol(t, &p, "named"), "the selected field lost its owner")
			}
		} else {
			carrier, indirect := place.base.(Value_Id)
			if !testing.expect(t, indirect, "a dereference must name a carrier value") { continue }
			value := graph.input.values[int(carrier)]
			if index == 1 {
				_, descriptor := value.place.base.(Storage_Id)
				testing.expect(t, descriptor, "the pointer's descriptor is distinct from its pointee")
			} else {
				_, another_load := value.place.base.(Value_Id)
				testing.expect(t, another_load && place.path[0].lo == 1, "successive dereferences must preserve the last carrier and selected sibling")
			}
		}
		count := len(graph.input.places)
		again := prov_input_place(graph, address.operand)
		testing.expect(t, again.base == place.base && len(graph.input.places) == count, "a repeated query reconstructed the place")
	}
	// The region-reset builder reuses a stack identifier while querying several
	// owners of the same type. Its address is not a storage identity.
	named := normalization_symbol(t, &p, "named")
	other := normalization_symbol(t, &p, "other_named")
	scratch := Expr_Ident{base = Expr_Base{type = symbol_of(&p.c, named).type}, symbol = named}
	first := prov_input_place(graph, &scratch)
	scratch.symbol = other
	second := prov_input_place(graph, &scratch)
	testing.expect(t, first.base != second.base, "a synthetic symbol query reused another owner's cached place")
}

// design.md "defer statement", "Temporaries and procedure boundaries".
@(test)
normalization_defer_storage_contract :: proc(t: ^testing.T) {
	p: Checked
	defer destroy_checked(&p)
	if !normalization_checked(t, &p, `package main;
expanded :: proc(early: bool) {
    defer {
        deferred_view: []int = make([dynamic]int, 2);
        assert(deferred_view.len() == 2);
    }
    if (early) { return; }
}
main :: proc() {}`) { return }
	k: Checker
	graph := normalization_graph(t, &k, &p, "expanded")
	if graph == nil { return }
	normal, abrupt := Storage_Id(0), Storage_Id(0)
	for entry, index in graph.input.storages {
		if entry.key.temporary == nil || underlying_kind(&p.c, entry.type) != .Dynamic_Array { continue }
		if entry.key.expansion.deferred == nil { continue }
		testing.expect(t, graph.extended[entry.key.temporary], "an extended deferred owner needs scope cleanup")
		if entry.key.expansion.exit == nil { normal = Storage_Id(index) } else { abrupt = Storage_Id(index) }
	}
	testing.expect(t, normal != 0 && abrupt != 0 && normal != abrupt, "evaluations in different defer expansions need separate storage")
	named := normalization_symbol(t, &p, "deferred_view")
	count := 0
	for entry in graph.input.storages {
		if entry.key.symbol != named { continue }
		count += 1
		testing.expect(t, entry.key.expansion == (Defer_Expansion{}), "a named local keeps one identity across exits")
	}
	testing.expect_value(t, count, 1)
}

// design.md "Splitting a mutable slice": captures describe evaluated values;
// their source places identify bindings without turning captures into reloads.
@(test)
normalization_captured_reassignment_contract :: proc(t: ^testing.T) {
	p: Checked
	defer destroy_checked(&p)
	if !normalization_checked(t, &p, `package main;
replace :: proc(receiver: inout []mut int, @(escape=stored) replacement: []mut int) -> int {
    receiver = replacement;
    return 1;
}
capture :: proc() -> int {
    first := [2]int{1, 2};
    second := [2]int{3, 4};
    rebound := &mut first[:];
    halves := rebound.split_at_mut(replace(inout rebound, &mut second[:]));
    return halves.left[0];
}
main :: proc() {}`) { return }
	k: Checker
	graph := normalization_graph(t, &k, &p, "capture")
	if graph == nil { return }
	rebound := normalization_symbol(t, &p, "rebound")
	halves := normalization_decl(t, &p, graph.literal, "halves")
	if halves == nil { return }
	call := halves.values[0].(^Expr_Call)
	capture := prov_input_call(graph, call).capture
	from := prov_input_value(graph, call.bound[0])
	if !testing.expect(t, capture != 0 && capture != from && len(graph.captured_values[capture]) > 0,
	                   "the split must record the receiver capture, with independent fact slots, before later arguments run") { return }
	value, source := graph.input.values[int(capture)], graph.input.values[int(from)]
	storage, direct := source.place.base.(Storage_Id)
	testing.expect(t, direct && prov_storage(graph, storage).key.symbol == rebound, "the capture lost its original source binding")
	testing.expect(t, source.type == value.type && value.place.base == source.place.base, "capture metadata must retain its checked carrier type and source")
}

// design.md "Allocator regions and region provenance", "Widening by label".
@(test)
normalization_variant_region_transfer_contract :: proc(t: ^testing.T) {
	p: Checked
	defer destroy_checked(&p)
	if !normalization_checked(t, &p, `package main;
Small :: (word: string | blank:);
Wide :: (blank: | number: int | word: string);
widen :: proc(input: string) -> Wide {
    narrow: Small = .word(input);
    wide: Wide = move(narrow);
    return move(wide);
}
boxed :: proc(allocator: Allocator) -> Option(Box(int)) {
    return .some(box(1, allocator));
}
extracted :: proc(allocator: Allocator) -> [dynamic]int {
    values: Option([dynamic]int) = .some(make([dynamic]int, 2, allocator));
    copy := values.as(.some) or_else make([dynamic]int);
    drop(values);
    return move(copy);
}
main :: proc() {}`) { return }
	for name in ([]string{"widen", "boxed"}) {
		body := normalization_body(t, &p, name)
		if body == nil { continue }
		summary := p.c.result_summaries[body.symbol]
		kept := false
		for content in summary.result.region_content {
			kept ||= len(content.region.params) > 0 && content.region.params[0]
		}
		testing.expectf(t, kept, "%s lost the source's payload region: %v", name, summary.result.region_content)
	}
	extracted := normalization_body(t, &p, "extracted")
	if extracted != nil {
		region := p.c.result_summaries[extracted.symbol].result.region
		testing.expectf(t, region.default && !region.unknown && (len(region.params) == 0 || !region.params[0]),
		                "checked extraction must replace the source backing allocation: %v", region)
	}
}

// design.md "Allocator regions and region provenance": a checked copy operation
// retains hook identity, while each replay substitutes the hook's current facts.
@(test)
normalization_copy_summary_replay_contract :: proc(t: ^testing.T) {
	p: Checked
	defer destroy_checked(&p)
	if !normalization_checked(t, &p, `package main;
Held :: struct { values: [dynamic]int, view: []int }
impl Held {
    copy_held :: hook(copy) proc(self, allocator: Allocator) -> Result(Held, Allocator_Error) {
        return .ok(Held{self.values.clone(allocator), self.view});
    }
}


Nested :: struct { held: Held }
hooked :: proc(input: Nested) -> Nested { return input.clone(); }
main :: proc() {}`) { return }
	body := normalization_body(t, &p, "hooked")
	if body == nil { return }
	k := Checker{c = &p.c}
	graph := build_flow_graph(&k, body, .Prov_Summary)
	ret, returns := body.body.stmts[0].(^Stmt_Return)
	if !testing.expect(t, returns && ret.value != nil) { return }
	transfer := prov_value_transfer(graph, prov_input_value(graph, ret.value.expr))
	held := symbol_of(&p.c, normalization_symbol(t, &p, "Held")).type
	operation := prov_input_copy_operation(graph, held)
	if !testing.expect(t, operation.hook != INVALID_SYMBOL && prov_has_direct_body(&p.c, operation.hook)) { return }
	original := p.c.result_summaries[operation.hook]
	defer p.c.result_summaries[operation.hook] = original
	growing: Proc_Summary
	p.c.result_summaries[operation.hook] = &growing
	before := prov_transfer_region(graph, transfer, nil, .All)
	params := [2]bool{true, true}
	growing.result.region = Region_Set{params = params[:]}
	after := prov_transfer_region(graph, transfer, nil, .All)
	testing.expect(t, !before.default && (len(before.params) == 0 || !before.params[0]), "an empty hook summary supplied settled dependencies")
	testing.expect(t, after.default && len(after.params) > 0 && after.params[0], "replay did not observe the grown source and allocator dependencies")
	testing.expect(t, slice.contains(graph.summary_callees[:], operation.hook), "replay omitted the nested hook dependency")
	count := len(graph.input.transfers)
	again := prov_value_transfer(graph, prov_input_value(graph, ret.value.expr))
	testing.expect(t, len(graph.input.transfers) == count && again.(Prov_Transfer_Forward).component.source == transfer.(Prov_Transfer_Forward).component.source,
	               "summary growth changed the normalized transfer or its source identity")
}

// design.md "Allocator regions and region provenance": an earlier read sees
// allocator facts written later, through arbitrarily many local forwarding steps.
@(test)
normalization_effect_fixed_point_contract :: proc(t: ^testing.T) {
	source :: `package main;
chain :: proc(allocator: Allocator) {
    first: Allocator = {};
    second: Allocator = {};
    third: Allocator = {};
    contents: [dynamic]int = {};
    for (i := 0; i < 2; i += 1) {
        contents = make([dynamic]int, 1, first);
        first = second;
        second = third;
        third = allocator;
    }
    assert(contents.len() == 1);
}
main :: proc() {}`
	p: Checked
	defer destroy_checked(&p)
	if !normalization_checked(t, &p, source) { return }
	k: Checker
	graph := normalization_graph(t, &k, &p, "chain")
	if graph == nil { return }
	// The first iteration allocates from the default; later ones from what
	// `allocator` reached through the chain.
	current := prov_region_for_symbol(graph, normalization_symbol(t, &p, "contents"))
	testing.expect(t, len(current.params) > 0 && current.params[0], "the replay stopped before the forwarding chain reached the owner")
	testing.expect(t, current.default, "the replay lost the default allocator of the first iteration")
	testing.expect(t, !current.unknown, "a local forwarding chain made the region unknown")
	program := graph.normalized_effects
	testing.expect(t, program != nil && program.input.frozen && program.replays >= 4, "the loop did not saturate one frozen operation program")
}

// Rebuilding a body's events after its facts settle allocates only in the
// analysis arena, which each body's check reclaims: a language server checks
// the same bodies again on every edit.
@(test)
normalization_materialization_allocator_contract :: proc(t: ^testing.T) {
	p: Checked
	defer destroy_checked(&p)
	if !normalization_checked(t, &p, `package main;
forward :: proc(allocator: Allocator) {
    first: Allocator = {};
    second: Allocator = {};
    contents: [dynamic]int = {};
    for (i := 0; i < 2; i += 1) {
        contents = make([dynamic]int, 1, first);
        first = second;
        second = allocator;
    }
    assert(contents.len() == 1);
}
main :: proc() {}`) { return }
	tracking: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracking, context.allocator)
	defer mem.tracking_allocator_destroy(&tracking)
	k: Checker
	graph: ^Flow_Graph
	{
		context.allocator = mem.tracking_allocator(&tracking)
		graph = normalization_graph(t, &k, &p, "forward")
	}
	if graph == nil { return }
	program := graph.normalized_effects
	testing.expect(t, program != nil && program.replays > 0, "the body did not replay its recorded operations")
	testing.expectf(t, len(tracking.allocation_map) == 0, "materialization left %d allocations outside the analysis arena", len(tracking.allocation_map))
}

// design.md "Evaluation order", "Splitting a mutable slice": checked call
// descriptions retain source ordering and an independent receiver capture.
@(test)
normalization_call_input_contract :: proc(t: ^testing.T) {
	p: Checked
	defer destroy_checked(&p)
	if !normalization_checked(t, &p, `package main;
sum :: proc(left: int, right: int) -> int { return left + right; }
calls :: proc(receiver: []mut int) -> int {
    named := sum(right = 2, left = 1);
    halves := receiver.split_at_mut(receiver.len() / 2);
    return named + halves.left.len() + halves.right.len();
}
main :: proc() {}`) { return }
	k: Checker
	graph := normalization_graph(t, &k, &p, "calls")
	if graph == nil { return }
	named := normalization_decl(t, &p, graph.literal, "named")
	halves := normalization_decl(t, &p, graph.literal, "halves")
	if named == nil || halves == nil { return }
	call := prov_input_call(graph, named.values[0].(^Expr_Call))
	testing.expect(t, len(call.order) == 2 && call.order[0] == 1 && call.order[1] == 0, "named arguments lost their written order")
	testing.expect(t, len(call.arguments) == 2 && call.arguments[0].type == TYPE_INT, "checked parameter metadata was reconstructed incorrectly")
	split_call := halves.values[0].(^Expr_Call)
	split := prov_input_call(graph, split_call)
	testing.expect(t, split.capture != 0 && split.capture != prov_input_value(graph, split_call.bound[0]),
	               "the checked split call lost its evaluated receiver capture")
}

// design.md "Allocator regions and region provenance": program replay reads
// a nested hook's current summary without extending its checked input tables.
@(test)
normalization_effect_summary_growth_contract :: proc(t: ^testing.T) {
	p: Checked
	defer destroy_checked(&p)
	if !normalization_checked(t, &p, `package main;
Held :: struct { values: [dynamic]int, view: []int }
impl Held {
    copy_held :: hook(copy) proc(self, allocator: Allocator) -> Result(Held, Allocator_Error) {
        return .ok(Held{self.values.clone(allocator), self.view});
    }
}
Nested :: struct { held: Held }
hooked :: proc(input: Nested) -> Nested {
    output := input.clone();
    return move(output);
}
main :: proc() {}`) { return }
	k: Checker
	graph := normalization_graph(t, &k, &p, "hooked")
	if graph == nil { return }
	program := graph.normalized_effects
	if !testing.expect(t, program != nil) { return }
	values, storage, calls := len(program.input.values), len(program.input.storages), len(program.input.calls)
	held := symbol_of(&p.c, normalization_symbol(t, &p, "Held")).type
	hook := prov_input_copy_operation(graph, held).hook
	original := p.c.result_summaries[hook]
	defer p.c.result_summaries[hook] = original
	growing: Proc_Summary
	p.c.result_summaries[hook] = &growing
	entry := normalization_parameter_seed(&k, graph, program)
	before_graph := prov_fact_graph(&k, graph.literal, .Prov_Summary, program, graph.alloc)
	prov_seed_regions(before_graph, entry)
	prov_replay_fact_operations(before_graph, program)
	before := prov_region_for_symbol(before_graph, normalization_symbol(t, &p, "output"))
	params := [2]bool{true, true}
	growing.result.region = Region_Set{params = params[:]}
	after_graph := prov_fact_graph(&k, graph.literal, .Prov_Summary, program, graph.alloc)
	prov_seed_regions(after_graph, entry)
	prov_replay_fact_operations(after_graph, program)
	after := prov_region_for_symbol(after_graph, normalization_symbol(t, &p, "output"))
	testing.expect(t, !before.default && (len(before.params) == 0 || !before.params[0]), "an empty hook summary supplied dependencies")
	testing.expect(t, after.default && len(after.params) > 0 && after.params[0], "the replay did not read the grown hook summary")
	testing.expect_value(t, len(program.input.values), values)
	testing.expect_value(t, len(program.input.storages), storage)
	testing.expect_value(t, len(program.input.calls), calls)
	testing.expect(t, slice.contains(after_graph.summary_callees[:], hook), "replay lost the nested hook's dependency")
}

// design.md "Global write effects": an empty region fixed point still keeps
// the construction graph's accesses and global effects.
@(test)
normalization_effect_empty_fixed_point_contract :: proc(t: ^testing.T) {
	p: Checked
	defer destroy_checked(&p)
	if !normalization_checked(t, &p, `package main;
global_value: int;
write :: proc() { global_value = 3; }
main :: proc() { write(); }`) { return }
	k: Checker
	graph := normalization_graph(t, &k, &p, "write")
	if graph == nil { return }
	program := graph.normalized_effects
	if !testing.expect(t, program != nil && program.replays == 0, "a zero-weight construction graph should already be final") { return }
	global_value := normalization_symbol(t, &p, "global_value")
	written := false
	for block in graph.blocks {
		for event in block.prov {
			if event.kind == .Access && event.root != NO_ROOT {
				written ||= graph.roots[int(event.root)].symbol == global_value && event.access != .Read
			}
		}
	}
	testing.expect(t, written, "skipping fact replay discarded the global write event")
}

// design.md "Minimum provenance precision": a view of a named owner's field
// borrows that place; its carriers keep their paths below the field.
@(test)
normalization_named_owner_view_contract :: proc(t: ^testing.T) {
	p: Checked
	defer destroy_checked(&p)
	if !normalization_checked(t, &p, `package main;
Pair :: struct { items: [1]^mut int, other: int }
count :: proc(values: []^mut int) -> int { return values.len(); }
viewed :: proc() -> int {
    target := 1;
    pair := Pair{{&mut target}, 2};
    return count(pair.items);
}
main :: proc() {}`) { return }
	k: Checker
	graph := normalization_graph(t, &k, &p, "viewed")
	if graph == nil { return }
	storage := prov_storage_id(graph, Written_Storage{symbol = normalization_symbol(t, &p, "pair")})
	aliases := graph.written_aliases[storage]
	testing.expect(t, len(aliases) > 0, "the record must retain its field's carrier target")
	for alias in aliases {
		testing.expectf(t, len(alias.path) > 0 && alias.path[0].kind == .Field,
		                "a viewed field's carrier was re-recorded outside that field: %v", alias.path)
	}
}

// design.md "Allocator regions and region provenance": a recorded store keeps
// the destination whose allocator a copy uses, rather than its storage's symbol.
@(test)
normalization_define_allocator_contract :: proc(t: ^testing.T) {
	p: Checked
	defer destroy_checked(&p)
	if !normalization_checked(t, &p, `package main;
copied :: proc(allocator: Allocator, source: ^[dynamic]int) -> int {
    owners: [dynamic]int via allocator = {};
    owners = source^;
    table: map[string]int via allocator = {};
    table["key"] = owners.len();
    return table.len();
}
main :: proc() {}`) { return }
	k: Checker
	graph := normalization_graph(t, &k, &p, "copied")
	if graph == nil || !testing.expect(t, graph.normalized_effects != nil, "the body lost its recorded operations") { return }
	owners, table := normalization_symbol(t, &p, "owners"), normalization_symbol(t, &p, "table")
	copied, keyed := false, false
	for site in graph.normalized_effects.operations {
		define := site.operation.(Prov_Effect_Define) or_continue
		destination := prov_storage(graph, define.storage).key.symbol
		if destination == owners && define.copies {
			copied = true
			testing.expect_value(t, define.allocated_by, owners)
		}
		if destination == table {
			keyed = true
			testing.expect_value(t, define.allocated_by, INVALID_SYMBOL)
		}
	}
	testing.expect(t, copied && keyed, "the copy and the map key insertion must each record a store")
}

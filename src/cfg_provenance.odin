// Provenance event vocabulary and construction for the disposable flow graph.
// cfg.odin owns traversal, control-flow topology, and lifecycle events;
// borrow.odin solves the root and region facts recorded here.
package lokec

import "core:fmt"
import "core:math/bits"
import "core:mem"
import "core:slice"
import "core:strings"

// ------------------------------------------------------ provenance events --

// Kept apart from cfg.odin's lifecycle events: the analyses share block topology,
// not the facts they record.
Prov_Kind :: enum u8 {
	// A carrier slot receives its source slots plus one fresh loan.
	Def,
	// A carrier slot is read. This is what makes a loan live to its last use.
	Live,
	// Storage is reached through a name that is not a live borrow of it.
	Access,
	// A root's storage ends, so every loan of it does too.
	Root_End,
	// A binding that views another place is bound again, so it names new
	// storage: loans taken through its earlier instance stop naming its root.
	// They still carry the loans of what that instance viewed.
	Rebind,
	// A value leaves the body through `return`.
	Escape,
	// A borrow stored somewhere that outlives the statement: process/thread
	// storage, or caller-owned storage. `retain` says which.
	Retain,
	// An allocator region reset: `free_all`, or a call through a parameter marked
	// `@(allocator_reset)`.
	Reset,
	// An owner backed by a received allocator region is stored somewhere that
	// outlives that region.
	Region_Escape,
	// A value written through a carrier (`p^.view = values`, or an argument the
	// callee may keep). The destination resolves while solving, and joins because
	// the carrier may name more than one root.
	Publish,
	// A value read through a carrier; its content slots resolve while solving.
	Load,
	// Storage at `path` below the pointee of the carriers in `into` is read or
	// written, as `access` says, or handed to a call that may, as `verb` says.
	// Checked against the loans of places reached through carriers
	// (`prov_place_loan`).
	Through,
	// Storage reached through what the carriers in `sources` hold: read or
	// written through them, or handed to a call that may. Only the thread
	// summaries' reach effect reads it.
	Reach,
	// What `sources` borrow crosses between a task and its parent; `verb` is
	// "argument" or "result" (design.md "Borrows crossing between tasks").
	Cross,
	// design.md "Globals while tasks run": a spawn starts the task running
	// `symbol`, given what `sources` borrow, from the spawn site `slot`
	// indexes in `task_sites`; a join ends the window of the block whose bit
	// is `slot`, and every task started in it.
	Task_Start,
	Task_Join,
	// The body's own write of the global `symbol`, or with `access` `Read` its
	// reach through what the global stores, made by a call `name` describes
	// when it is not empty. Emitted only inside a `parallel` block.
	Shared_Effect,
	// The parent's allocator use of `region` inside a `parallel` block
	// (design.md "Allocators and tasks").
	Region_Use,
}

// One spawn of a body: the window bit of its `parallel` block, the regions
// its task reserves, and where it is (design.md "Allocators and tasks").
Task_Site :: struct {
	block:   int,
	reserve: Region_Set,
	span:    Span,
	// The spawned call, whose procedure value diagnostics resolve to the
	// bodies it may be.
	call:    ^Expr_Call,
}

// design.md "Capabilities and the one rule": a read is compatible with a
// read-only borrow, a write is not, an invalidation ends the value outright.
Access_Kind :: enum u8 {
	Read,
	Write,
	Invalidate,
}

Prov_Event :: struct {
	precision: Precision_Loss,
	kind:    Prov_Kind,
	span:    Span,
	slot:    int,
	loan:    Loan_Id,
	sources: []int,
	root:    Root_Id,
	path:    []Proj_Step,
	access:  Access_Kind,
	verb:    string,
	name:    string,
	// `Retain`: the destination's storage kind; `verb` names it.
	retain: Retain_Kind,
	// `Escape`: borrows reached through the returned value.
	// `Retain`/`Publish`: the carrier a destination was written through, whose
	// loans the solver resolves to roots. `Load`: the addressing carriers, with
	// `path` below their pointees and `slot` the content.
	into: []int,
	// `Escape`: the allocator region an owning result carries with it.
	region:         Region_Set,
	region_content: []Prov_Region_Content,
	// `Reset`: whether its promise is written. `access` is `Invalidate` for a
	// direct `free_all`, `Write` for handing an allocator onward.
	reset_covered: bool,
	provider_end: bool, // ends the control block as well as its allocations
	// A reset in a `return`'s deferred statements that may end the region of
	// the value already handed to the caller; `owner_span` is that value.
	ends_result: bool,
	// A reset on a panic's unwind path: the statement the panic unwinds from.
	unwind_from: Maybe(Span),
	owner_span:    Span,
	// `Reset`: the written operation ending a provider, such as "dropping `a`".
	ends:          string,
	// `Region_Escape`: the `move` parameter whose owner is being kept.
	moved:         string,
	// `Live`: re-establishes its loans. A loop head re-reads its iterable, so a
	// body invalidation must not cross the back edge.
	revives:       bool,
	// `Load`: also reads through what was read, at any depth.
	deep:          bool,
	// A deep `Load`: follows only the carriers a write may go through, and
	// keeps only what mutable ones name (`prov_load_writable`).
	writable:      bool,
	// `Live`: the carrier is only read, so a live read-only reborrow of it does
	// not conflict (design.md "Weakening and reborrows").
	reads_only:    bool,
	// `Load`: a carrier loaded on the way to a place through it
	// (`prov_reach_hop`), which only the access to that place uses, so its
	// reborrow of what it was loaded out of suspends nothing.
	walked:        bool,
	// `Def`: one more than the index of the place loan the slot is the
	// snapshot of, which its value then carries (`Prov_Place_Loan`), or 0.
	place_loan:    int,
	// `Publish`: for a store through carriers pointing at one place, `path`
	// below their pointee, the type stored there, which replaces what that
	// place held where they name one storage (`publish_into_loan`), or
	// INVALID_TYPE. `replaces` are the slots it replaces once reaching has
	// settled, whose earlier values it ends as a `Def` does.
	stored:        Type_Id,
	replaces:      []int,
	// `Publish`: a store of one carrier, whose copy `prov_reborrow` links to
	// every slot it may land in. Any other store through a parameter's loan
	// also joins into the parameter itself (`publish_into_loan`).
	linked:        bool,
	// `Task_Start`, `Shared_Effect`: see `Prov_Kind`.
	symbol:        Symbol_Id,
	// One more than the window bit of the pooled block whose join this
	// `thread_local` write is, or 0: it applies only where a task of that
	// block may have started (`settle_pool_joins`).
	joins:         int,
}

// A borrowed parameter arrives holding the caller's storage, which the entry
// block installs before the first statement.
Prov_Entry_Def :: struct {
	slot: int,
	loan: Loan_Id,
}

// The one result of a call: what it borrows and the allocator region it
// carries.
Prov_Call_Result :: struct {
	loans:          []int,
	// An `inout` result's place: what the `inout` arguments borrow.
	place:          []int,
	region:         Region_Set,
	region_content: []Prov_Region_Content,
}

// A path-indexed region fact, kept even where the field has no carrier shape
// (for example `[dynamic]int`).
Prov_Region_Content :: struct {
	path:   []Proj_Step,
	region: Region_Set,
	// Only allocator handles were stored here, no owner, so the region says what
	// an owner made from them is in but backs nothing itself.
	handle: bool,
	// The value's own backing allocation or moved-parameter dependency at
	// `path`, separate from its fields and elements.
	own: bool,
	// A copy within one writable parameter: `path` holds what the argument
	// itself held at `from`, which a call resolves in its caller instead of
	// taking the whole argument's regions. `region` is empty.
	from: Maybe(Prov_Region_Source),
}

// A read of a writable parameter's incoming value at `path`.
Prov_Region_Source :: struct {
	path:  []Proj_Step,
	query: Region_Query,
}

// While set, reads of `symbol`'s incoming value leave out its own parameter
// region and are listed in `sources`, so a store into the parameter can say
// which of its fields it copied (`prov_take_self_sources`).
Prov_Self_Reads :: struct {
	symbol:  Symbol_Id,
	index:   int,
	sources: [dynamic]Prov_Region_Source,
}

// The payload under a union's wildcard alternative: unwrapping keeps every borrow
// the wrapper carried. An `any_view` reads through its data pointer instead.
@(private)
prov_payload_content :: proc(
	graph: ^Flow_Graph, loans: []int, subject_type, payload_type: Type_Id, span: Span,
) -> []int {
	if len(loans) == 0 || payload_type == INVALID_TYPE || payload_type == subject_type {
		return loans
	}
	if subject_type == TYPE_ANY_VIEW {
		return prov_load_content(graph, loans, nil, payload_type, span)
	}
	if !type_is_union(graph.k.c, subject_type) {
		return loans
	}
	return prov_project_content(graph, loans, subject_type, {proj_wild()}, payload_type, span)
}

@(private)
prov_case_payload :: proc(
	graph: ^Flow_Graph, s: ^Stmt_Switch, entry: Switch_Case, subject: []int,
) -> []int {
	if entry.binding_symbol == INVALID_SYMBOL || s.subject == nil {
		return subject
	}
	return prov_payload_content(
		graph, subject, prov_type(graph, s.subject), entry.binding_type, entry.span,
	)
}

// One field of the payload a case binds (design.md "Inspecting a union").
@(private)
prov_case_field :: proc(
	graph: ^Flow_Graph, s: ^Stmt_Switch, field: Case_Field, subject: []int, span: Span,
) -> []int {
	if len(subject) == 0 || s.subject == nil {
		return subject
	}
	path := []Proj_Step{proj_wild(), proj_field(field.slot)}
	return prov_project_content(graph, subject, prov_type(graph, s.subject), path, field.type, span)
}

// The loan a binding that views another place holds. A lending binding's
// `&binding` names the source rather than the binding's frame slot; one whose
// loans end with its step names both.
@(private)
prov_bind_view :: proc(graph: ^Flow_Graph, id: Symbol_Id, loans: []int, lends := true) {
	if id == INVALID_SYMBOL || len(loans) == 0 {
		return
	}
	graph.view_loans[id] = loans
	if !lends {
		graph.step_views[id] = true
	}
}

// What a view binding's root stands for: every access through it, and every
// borrow of it, also uses the source it views (design.md "Borrowing iteration").
@(private)
prov_root_view :: proc(graph: ^Flow_Graph, root: Root_Id) -> []int {
	if root == NO_ROOT {
		return nil
	}
	symbol := graph.roots[int(root)].symbol
	if symbol == INVALID_SYMBOL {
		return nil
	}
	return graph.view_loans[symbol]
}

// What a use of a switch payload binding also uses: the slots of the named
// place holding its payload, or with `load` what is stored at `path` below
// the pointee of the carriers in `slots`.
Prov_View_Use :: struct {
	slots: []int,
	path:  []Proj_Step,
	load:  bool,
}

// design.md "Switch ownership": a payload binding over a place names the
// payload where the subject stores it, so a use of the binding uses the
// carrier stored there, and a mutable copy of that carrier, as `b := opt` or
// `b := cur^.next` beside `case .some(a):`, suspends the binding as it does
// the place. Reached through carriers, a use loads the payload through the
// carriers the subject view holds. A field binding, `slot` at or above zero,
// uses only its field.
@(private)
prov_note_view_use :: proc(graph: ^Flow_Graph, id: Symbol_Id, subject: Expr, slot := -1) {
	sym := symbol_of(graph.k.c, id)
	if sym == nil || subject == nil || !type_carries_borrow(graph.k.c, sym.type).mutable {
		return
	}
	payload := prov_extend(graph, nil, proj_wild())
	if slot >= 0 {
		payload = prov_extend(graph, payload, proj_field(slot))
	}
	if root, path, ok := prov_place_of(graph, subject); ok {
		if slots := prov_content_at(graph, root, prov_concat_path(graph, path, payload)); len(slots) > 0 {
			graph.view_uses[id] = Prov_View_Use{slots = slots}
		}
		return
	}
	hops := prov_place_hops(graph, subject)
	if carriers := graph.view_loans[id]; len(hops) > 0 && len(carriers) > 0 {
		graph.view_uses[id] = Prov_View_Use{slots = carriers, path = prov_concat_path(graph, hops[0].path, payload), load = true}
	}
}

// A `.name(&mut binding)` case borrows the subject exclusively for the case, as
// `&mut subject` would (design.md "Switch ownership"). A field binding, `slot`
// at or above zero, borrows only its field of the payload where the subject is
// a place with a path.
@(private)
prov_subject_view :: proc(graph: ^Flow_Graph, subject: Expr, mutable: bool, slot := -1) -> []int {
	if subject == nil {
		return nil
	}
	root, path, ok := prov_place_of(graph, subject)
	if slot >= 0 && ok {
		path = prov_extend(graph, prov_extend(graph, path, proj_wild()), proj_field(slot))
		if !mutable {
			return prov_borrow(graph, root, path, false, expr_span(subject), "payload")
		}
		if ident, is_ident := subject.(^Expr_Ident); is_ident {
			if loans, viewed := graph.view_loans[ident.symbol]; viewed && !graph.step_views[ident.symbol] {
				return loans
			}
		}
		prov_walk_subscripts(graph, subject)
		access_block, access_index := prov_access(graph, root, path, .Write, expr_span(subject))
		return prov_borrow(graph, root, path, true, expr_span(subject), "payload", access_block, access_index)
	}
	// Through carriers, a field binding borrows only its field there too.
	if mutable && slot >= 0 && !ok {
		if carriers, below, through := prov_read_through_carrier(graph, subject, reads = false); through {
			below = prov_extend(graph, prov_extend(graph, below, proj_wild()), proj_field(slot))
			prov_write_through(graph, carriers, below, expr_span(subject), "mutable borrow")
			return prov_place_loan(graph, carriers, below, true, "payload", subject, borrows = true)
		}
	}
	if mutable {
		return prov_borrow_place(graph, subject, true, expr_span(subject), "payload")
	}
	if !ok {
		// A subject reached through a pointer or view, as in `switch (p^)`, is
		// storage that carrier names, so the binding views what `&subject`
		// would borrow. A carrier loaded on the way, as `p^` for `p^^.first`,
		// only holds that storage's loans for the view: it no more suspends
		// what it was loaded out of than `p` does for `p^.first`.
		if carriers, below, through := prov_read_through_carrier(graph, subject, reads = false); through {
			for carrier in carriers {
				graph.prov_slots[carrier].viewed = graph.prov_slots[carrier].loaded
			}
			if slot >= 0 {
				below = prov_extend(graph, prov_extend(graph, below, proj_wild()), proj_field(slot))
			}
			prov_read_through(graph, carriers, below, expr_span(subject))
			return prov_join(graph, carriers, prov_place_loan(graph, carriers, below, false, "payload", subject))
		}
		return nil
	}
	return prov_borrow(graph, root, path, false, expr_span(subject), "payload")
}

// A loan of `place`, reached through `carriers`, at `path` below their
// pointee (`Prov_Place_Loan`). A switch over such a place, as `h^.first`,
// takes a read-only one while a payload binding is in use, as one over a
// local borrows it (design.md "Switch ownership"); each use of the binding
// keeps the snapshot live, and a write through a carrier naming the same
// storage at an overlapping path conflicts with it (`.Through`). The slot
// returned is the snapshot, whose value carries the loan wherever it is
// copied.
@(private)
prov_place_loan :: proc(
	graph: ^Flow_Graph, carriers: []int, path: []Proj_Step, mutable: bool, what: string, place: Expr, borrows := false,
) -> []int {
	if len(carriers) == 0 || graph.current == NO_BLOCK {
		return nil
	}
	span := expr_span(place)
	offsets, _ := prov_value_offset(graph, carriers)
	paths := make([][]Proj_Step, len(offsets), graph.alloc)
	for at, index in offsets {
		paths[index] = prov_concat_path(graph, at, path)
	}
	append(&graph.place_loans, Prov_Place_Loan {
		paths = paths, mutable = mutable, borrows = borrows, what = what, span = span,
		place = graph.k.c.sources[span.file].text[span.lo:span.hi],
	})
	slot := prov_temp_slot(graph)
	loan := &graph.place_loans[len(graph.place_loans) - 1]
	loan.slot = slot
	prov_emit(graph, Prov_Event {
		kind = .Def, slot = slot, loan = NO_LOAN, sources = carriers, span = span, place_loan = len(graph.place_loans),
	})
	// A borrow points at the place it is of (`Prov_Slot.offsets`).
	if borrows {
		graph.prov_slots[slot].offsets = loan.paths
	}
	return prov_one(graph, slot)
}

// A write through `carriers` at `path` below their pointee, which a place
// loan of the same storage forbids (`prov_place_loan`). A carrier that is a
// borrow of a place, as `count` for `count := &mut h^.count`, writes below
// that place (`prov_value_offset`). The event's index in the current block,
// or -1 when none is emitted.
@(private)
prov_write_through :: proc(graph: ^Flow_Graph, carriers: []int, path: []Proj_Step, span: Span, verb: string) -> int {
	return prov_access_through(graph, carriers, path, span, .Write, verb)
}

// A read through `carriers` at `path` below their pointee, which a mutable
// place loan of the same storage forbids.
@(private = "file")
prov_read_through :: proc(graph: ^Flow_Graph, carriers: []int, path: []Proj_Step, span: Span) {
	prov_access_through(graph, carriers, path, span, .Read, "read")
}

// Carriers pointing at different places, as a record holding `&mut h^.count`
// and `&mut h^.total` does, are each accessed at their own, and a carrier
// that may point at either, as one chosen between the two, at both. The
// events emitted are contiguous; the index of the first, or -1 when the
// access names no carriers.
@(private = "file")
prov_access_through :: proc(graph: ^Flow_Graph, carriers: []int, path: []Proj_Step, span: Span, access: Access_Kind, verb: string) -> int {
	if len(carriers) == 0 || graph.current == NO_BLOCK {
		return -1
	}
	first := len(graph.blocks[graph.current].prov)
	offsets, _ := prov_value_offset(graph, carriers)
	if prov_offsets_agree(graph, carriers, offsets) {
		for at in offsets {
			prov_emit(graph, Prov_Event {
				kind = .Through, into = carriers, path = prov_concat_path(graph, at, path), span = span, verb = verb, access = access,
			})
		}
		return first
	}
	for carrier in carriers {
		if graph.prov_slots[carrier].through_block == NO_BLOCK {
			prov_access_through(graph, prov_one(graph, carrier), path, span, access, verb)
		}
	}
	return first
}

// Whether every slot of `carriers` that names storage points at `offsets`.
@(private = "file")
prov_offsets_agree :: proc(graph: ^Flow_Graph, carriers: []int, offsets: [][]Proj_Step) -> bool {
	for carrier in carriers {
		if entry := graph.prov_slots[carrier]; entry.through_block == NO_BLOCK {
			own := prov_slot_offsets(entry)
			if !prov_offsets_cover(own, offsets) || !prov_offsets_cover(offsets, own) {
				return false
			}
		}
	}
	return true
}

// `prov_write_through` for a place its caller walked as a value, as a
// compound assignment or an `inout` receiver does. That walk only read the
// carriers, so they are read again as written through, which a reborrow of
// the place suspends (design.md "Weakening and reborrows"); the subscripts
// below the last carrier were walked already.
@(private = "file")
prov_write_through_place :: proc(graph: ^Flow_Graph, place: Expr, span: Span) {
	if carriers, below, through := prov_read_through_carrier(graph, place, store = true); through {
		prov_write_through(graph, carriers, below, span, "write")
	}
}


// A case binding keeps its selected payload's fields, including owner/handle
// separation (design.md "Inspecting a union").
@(private)
prov_bind_case_region :: proc(graph: ^Flow_Graph, id: Symbol_Id, subject: Value_Id, variants: []int, slot: int) {
	recorded := prov_effect_active(graph) && prov_effect_symbol_relevant(graph, id)
	if recorded { prov_effect_begin(graph, Prov_Effect_Case{id, prov_effect_value(graph, subject), slice.clone(variants, graph.effect_program.alloc), slot}) }
	defer prov_effect_end(graph, recorded)
	if id == INVALID_SYMBOL || subject == 0 {
		return
	}
	subject_type := prov_value(graph, subject).type
	sym := symbol_of(graph.k.c, id)
	if sym == nil {
		return
	}
	if !prov_type_has_region(graph.k.c, sym.type) {
		return
	}
	// design.md "Inspecting a union": a borrowed binding names the subject's
	// payload. Region writes through it must reach the same storage too.
	if sym.borrowed_binding != .None && underlying_kind(graph.k.c, subject_type) == .Union && len(variants) > 0 {
		places := make([dynamic]Prov_Region_Alias, graph.alloc)
		uncertain := false
		if root, at, ok := prov_value_place_of(graph, subject); ok {
			append(&places, Prov_Region_Alias{root, at})
		} else {
			below := prov_path_below_carrier(graph, subject)
			for target in prov_written_targets(graph, subject, as_place = true) {
				target_root := prov_root_for_storage(graph, target.target)
				if target_root == NO_ROOT { uncertain = true; continue }
				append(&places, Prov_Region_Alias{target_root, prov_concat_path(graph, target.at, below)})
			}
		}
		aliases := make([dynamic]Prov_Region_Alias, graph.alloc)
		for place in places {
			if prov_region_alias_reaches(graph, place.root, id) {
				uncertain = true
				continue
			}
			for variant in variants {
				path := prov_extend(graph, place.path, proj_field(variant))
				if slot >= 0 { path = prov_extend(graph, path, proj_field(slot)) }
				append(&aliases, Prov_Region_Alias{place.root, path})
			}
		}
		// Unknown storage, including a recursive cursor's next node, retains
		// the escape restriction and a snapshot for reads. Keep known targets
		// too: uncertainty cannot remove their lifetime constraints (design.md
		// "Allocator regions and region provenance"). NO_ROOT is always last.
		uncertain ||= len(aliases) == 0
		if uncertain { append(&aliases, Prov_Region_Alias{root = NO_ROOT}) }
		graph.region_aliases[id] = aliases[:]
		if !uncertain { return }
	}
	if underlying_kind(graph.k.c, subject_type) == .Union && len(variants) == 1 {
		path := prov_extend(graph, nil, proj_field(variants[0]))
		if slot >= 0 { path = prov_extend(graph, path, proj_field(slot)) }
		if type_is_carrier(graph.k.c, sym.type) || type_underlying(graph.k.c, sym.type) == TYPE_ALLOCATOR ||
		   type_is_region_provider(graph.k.c, sym.type) {
			prov_merge_region_of(graph, id, prov_result_region_at(graph, subject, path))
		} else {
			prov_define_value_regions(graph, prov_root_for_symbol(graph, id), nil, subject, path)
		}
		return
	}
	if set := prov_region_of(graph, subject); !region_is_empty(set) {
		prov_merge_region_of(graph, id, set)
	}
}

// Written carrier targets grow across loop passes. A cursor set from its own
// payload can refer back to the binding about to be installed; such storage
// needs the unresolved-carrier fallback, not a recursive region alias.
@(private = "file")
prov_region_alias_reaches :: proc(graph: ^Flow_Graph, root: Root_Id, id: Symbol_Id) -> bool {
	if root == NO_ROOT { return false }
	target := graph.roots[int(root)].symbol
	if target == id { return true }
	for alias in graph.region_aliases[target] {
		if prov_region_alias_reaches(graph, alias.root, id) { return true }
	}
	return false
}

// ------------------------------------------------- provenance construction --

// Graph construction for the lattices in `src/borrow.odin`: allocates in the
// graph's arena and reads the typed AST without reporting or changing it.
// Conversion walkers record the conversion they walk beneath in
// `graph.converting`; `prov_repr` and `prov_type` read the representation there.
// Leaf queries take values, which carry their own representation.

@(private)
prov_emit :: proc(graph: ^Flow_Graph, event: Prov_Event) {
	if graph.current == NO_BLOCK {
		return // unreachable code borrows nothing observable
	}
	if event.kind == .Reset || event.kind == .Region_Escape {
		graph.has_region_event = true
	}
	// An owner backed by an allocator region needs the solver even with no loan.
	if event.kind == .Escape {
		graph.has_region_event ||= !region_is_empty(event.region)
		for content in event.region_content {
			graph.has_region_event ||= !region_is_empty(content.region)
		}
	}
	if event.kind == .Def {
		prov_note_offset(graph, event.slot, event.sources)
	}
	append(&graph.blocks[graph.current].prov, event)
}

// The paths below the storage `slots` name that a value made of them may
// point at (`Prov_Slot.offsets`): any of theirs, as a borrow's place loan
// snapshot points at the place it is of. A slot standing for a borrow's
// access, which names no storage, takes no part. False when no slot names
// storage.
@(private)
prov_value_offset :: proc(graph: ^Flow_Graph, slots: []int) -> ([][]Proj_Step, bool) {
	out: [][]Proj_Step
	found := false
	for slot in slots {
		entry := graph.prov_slots[slot]
		if entry.through_block != NO_BLOCK {
			continue
		}
		offsets := prov_slot_offsets(entry)
		out = found ? prov_union_offsets(graph, out, offsets) : offsets
		found = true
	}
	return out, found
}

// Records what a definition of `slot` from `sources` may point at, besides
// what the slot's earlier definitions may.
@(private = "file")
prov_note_offset :: proc(graph: ^Flow_Graph, slot: int, sources: []int) {
	at, found := prov_value_offset(graph, sources)
	if !found {
		return
	}
	entry := &graph.prov_slots[slot]
	entry.offsets = entry.offsets != nil ? prov_union_offsets(graph, entry.offsets, at) : at
}

// The most places a value is told apart at; past it, places are merged into a
// prefix they share (`prov_union_offsets`).
@(private = "file")
PROV_OFFSET_LIMIT :: 8

// A slot whose definitions name no storage points at the whole of it.
@(private = "file")
prov_whole_offset: [1][]Proj_Step

@(private = "file")
prov_slot_offsets :: proc(entry: Prov_Slot) -> [][]Proj_Step {
	return entry.offsets if entry.offsets != nil else prov_whole_offset[:]
}

// The places of `a` and those of `b`, a place inside another taken as that
// one. Past the limit, the two places sharing the longest prefix, the first
// such pair among equals, are taken as that prefix until few enough are left,
// so `[inner, a]` and `[inner, b]` become `[inner]` while a place outside
// `inner` stays apart. Each place of `a` and `b` stays inside one of the
// result.
@(private = "file")
prov_union_offsets :: proc(graph: ^Flow_Graph, a, b: [][]Proj_Step) -> [][]Proj_Step {
	if prov_offsets_cover(a, b) {
		return a
	}
	if prov_offsets_cover(b, a) {
		return b
	}
	out := make([dynamic][]Proj_Step, 0, len(a) + len(b), graph.alloc)
	for at in a {
		prov_add_offset(&out, at)
	}
	for at in b {
		prov_add_offset(&out, at)
	}
	for len(out) > PROV_OFFSET_LIMIT {
		first, second, longest := 0, 1, -1
		for i in 0 ..< len(out) {
			for j in i + 1 ..< len(out) {
				if shared := len(prov_common_prefix(out[i], out[j])); shared > longest {
					first, second, longest = i, j, shared
				}
			}
		}
		shared := prov_common_prefix(out[first], out[second])
		ordered_remove(&out, second)
		ordered_remove(&out, first)
		prov_add_offset(&out, shared)
	}
	return out[:]
}

@(private = "file")
prov_add_offset :: proc(out: ^[dynamic][]Proj_Step, path: []Proj_Step) {
	if prov_offset_covered(out[:], path) {
		return
	}
	kept := 0
	for at in out {
		if !path_has_exact_prefix(at, path) {
			out[kept] = at
			kept += 1
		}
	}
	resize(out, kept)
	append(out, path)
}

// Whether every place of `inner` is inside one of `outer`.
@(private = "file")
prov_offsets_cover :: proc(outer, inner: [][]Proj_Step) -> bool {
	for path in inner {
		if !prov_offset_covered(outer, path) {
			return false
		}
	}
	return true
}

@(private = "file")
prov_offset_covered :: proc(offsets: [][]Proj_Step, path: []Proj_Step) -> bool {
	for at in offsets {
		if path_has_exact_prefix(path, at) {
			return true
		}
	}
	return false
}

// The steps `a` and `b` start with alike.
@(private = "file")
prov_common_prefix :: proc(a, b: []Proj_Step) -> []Proj_Step {
	length := 0
	for length < min(len(a), len(b)) && a[length] == b[length] {
		length += 1
	}
	return a[:length]
}

@(private = "file")
prov_one :: proc(graph: ^Flow_Graph, slot: int) -> []int {
	out := make([]int, 1, graph.alloc)
	out[0] = slot
	return out
}

@(private)
prov_join :: proc(graph: ^Flow_Graph, a, b: []int) -> []int {
	if len(a) == 0 {
		return b
	}
	if len(b) == 0 {
		return a
	}
	out := make([]int, len(a) + len(b), graph.alloc)
	copy(out, a)
	copy(out[len(a):], b)
	return out
}

@(private)
prov_result_region :: proc(graph: ^Flow_Graph, id: Value_Id) -> Region_Set {
	if form, ok := prov_value(graph, id).form.(Prov_Form_Call); ok {
		if result, found := graph.call_results[form.call]; found {
			return result.region
		}
	}
	return prov_region_of(graph, id)
}

// The allocator region of one projected result field, without joining siblings.
Region_Query :: enum { All, Owners, Own }

// The regions of one projected field of value `id` at `path`. A record keeps
// its fields apart, recursively (`region_field_shape`), and its own dependency
// has an entry of its own at the record's path, so a scalar managed record
// keeps a moved parameter's escape contract through locals and results.
// Union steps name variant indices, so success and error payloads have
// independent facts, and widening remaps paths by variant label, through
// explicit conversions too. Temporary field projections, constructors,
// success unwrapping, and switch bindings are followed to their source. A
// shape's conservative leaves are queried without expanding them again,
// including for recursive container types.
@(private)
prov_result_region_at :: proc(graph: ^Flow_Graph, id: Value_Id, path: []Proj_Step, query := Region_Query.All, as_type := INVALID_TYPE) -> Region_Set {
	if id == 0 { return prov_empty_region(graph) }
	value := prov_value(graph, id)
	type := as_type == INVALID_TYPE ? value.type : as_type
	if query == .Owners {
		part := prov_type_at(graph.k.c, type, path)
		if !type_is_managed(graph.k.c, part) {
			return prov_empty_region(graph)
		}
		if fields := region_field_shape(graph.k.c, part, graph.alloc); len(fields) > 0 {
			out := prov_empty_region(graph)
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
			out := prov_empty_region(graph)
			matched := false
			for content in result.region_content {
				if query == .Own && (!content.own || !prov_same_path(content.path, path)) {
					continue
				}
				if content.own && len(content.path) < len(path) { continue }
				if paths_overlap(content.path, path) {
					matched = true
					region_merge(&out, content.region)
				}
			}
			if matched { return out }
		}
	case Prov_Form_Selector:
		if form.field && form.operand != 0 &&
		   underlying_kind(graph.k.c, prov_value(graph, form.operand).type) == .Struct {
			return prov_result_region_at(graph, form.operand, prov_concat_path(graph, {form.step}, path), query)
		}
	}
	if root, base, ok := prov_value_place_of(graph, id); ok {
		return prov_region_content_at(graph, root, prov_concat_path(graph, base, path), query)
	}
	if region, known := prov_read_storage_regions(graph, id, path, query); known { return region }
	return prov_result_region(graph, id)
}

@(private = "file")
prov_widened_region_path :: proc(graph: ^Flow_Graph, from, to: Type_Id, path: []Proj_Step) -> ([]Proj_Step, bool) {
	if len(path) == 0 { return path, true }
	if path[0].kind != .Field { return path, true }
	for _, index in type_of(graph.k.c, from).variants {
		if widened_variant(graph.k.c, from, to, index) == int(path[0].lo) {
			return prov_concat_path(graph, {proj_field(index)}, path[1:]), true
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
	shape, ok := fallible_of(graph.k, prov_value(graph, error.operand).type)
	if !ok { return prov_empty_region(graph) }
	from := shape.info.variants[shape.failure]
	path := path
	if union_widens_to(graph.k.c, from, target) {
		mapped, possible := prov_widened_region_path(graph, from, target, path)
		if !possible { return prov_empty_region(graph) }
		path = mapped
	}
	path = prov_concat_path(graph, {proj_field(shape.failure)}, path)
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
	target, ok := fallible_of(graph.k, result_type)
	if !ok { return nil }
	out := region_field_shape(graph.k.c, result_type, graph.alloc)
	for &content in out {
		if len(content.path) == 0 || content.path[0].kind != .Field || int(content.path[0].lo) != target.failure { continue }
		content.region = prov_error_region_at(graph, error, content.path[1:], content.own ? .Own : .All, target.info.variants[target.failure])
	}
	return out
}

// A reset strands owned allocations and borrowed data, but leaves allocator
// handles usable (design.md "Allocator regions and region provenance").
@(private)
prov_reset_fields_region :: proc(graph: ^Flow_Graph, type: Type_Id, fields: []Prov_Region_Content) -> Region_Set {
	out := prov_empty_region(graph)
	for field in fields {
		if field.handle && type_underlying(graph.k.c, prov_type_at(graph.k.c, type, field.path)) == TYPE_ALLOCATOR { continue }
		region_merge(&out, field.region)
	}
	return out
}

@(private)
prov_reset_value_region :: proc(graph: ^Flow_Graph, id: Value_Id) -> Region_Set {
	if id == 0 { return prov_empty_region(graph) }
	type := prov_value(graph, id).type
	return prov_reset_fields_region(graph, type, prov_result_region_fields(graph, id, type))
}

// As `prov_reset_value_region` for a live owner named by its symbol: a plain
// read of the local, which has no expression of its own.
@(private = "file")
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
prov_symbol_region :: proc(graph: ^Flow_Graph, id: Symbol_Id, type: Type_Id) -> Region_Set {
	if type != INVALID_TYPE && !prov_type_has_region(graph.k.c, type) {
		return Region_Set{}
	}
	// A provider as a value is backed by its parent; the region it provides is
	// reached through its handle.
	if type_is_region_provider(graph.k.c, type) {
		return graph.provider_parents[id] or_else Region_Set{}
	}
	return prov_region_for_symbol(graph, id)
}

// Returning a region provider transfers its parent dependency, not its local
// token; the caller makes a fresh token for the returned owner.
@(private)
prov_escape_region :: proc(graph: ^Flow_Graph, id: Value_Id) -> Region_Set {
	value := prov_value(graph, id)
	if id != 0 && type_is_region_provider(graph.k.c, value.type) {
		#partial switch form in value.form {
		case Prov_Form_Symbol:
			if parent, found := graph.provider_parents[form.symbol]; found {
				return parent
			}
			return Region_Set{}
		case Prov_Form_Move:
			return prov_escape_region(graph, form.operand)
		}
	}
	return prov_result_region(graph, id)
}

// Static, thread-local, or file-scope storage: it outlives every procedure body.
@(private)
symbol_outlives_bodies :: proc(sym: ^Symbol) -> bool {
	return sym.duration != .None || (sym.decl != nil && sym.decl.top_level)
}

@(private = "file")
prov_new_root :: proc(graph: ^Flow_Graph, kind: Root_Kind, span: Span, name: string) -> Root_Id {
	append(&graph.roots, Prov_Root{kind = kind, span = span, name = name, param_index = -1, content = -1})
	return Root_Id(len(graph.roots) - 1)
}

// design.md "Storage roots and borrow carriers": every ordinary variable owns
// its inline storage and is a root for borrows of it. Static-duration storage is
// a root that outlives every body, and an `inout` parameter names the caller's.
@(private)
prov_root_for_symbol :: proc(graph: ^Flow_Graph, id: Symbol_Id) -> Root_Id {
	if id == INVALID_SYMBOL {
		return NO_ROOT
	}
	if existing, found := graph.root_by_symbol[id]; found {
		return existing
	}
	sym := symbol_of(graph.k.c, id)
	if sym == nil {
		return NO_ROOT
	}
	storage := prov_storage_id(graph, Written_Storage{symbol = id})
	if storage == 0 { return NO_ROOT }
	kind := prov_storage(graph, storage).kind
	root := prov_new_root(graph, kind, sym.span, identifier_text(graph.k.c, sym.name))
	graph.roots[int(root)].symbol = id
	graph.roots[int(root)].storage = storage
	graph.root_by_storage[storage] = root
	if kind == .Param {
		graph.roots[int(root)].param_index = int(sym.index)
	}
	graph.root_by_symbol[id] = root
	return root
}

// A carrier variable's slot. A static-duration one starts holding whatever
// another body may have stored there, as a global's content slots do.
@(private = "file")
prov_slot_for_symbol :: proc(graph: ^Flow_Graph, id: Symbol_Id) -> (int, bool) {
	if id == INVALID_SYMBOL {
		return 0, false
	}
	if existing, found := graph.slot_by_symbol[id]; found {
		return existing, true
	}
	sym := symbol_of(graph.k.c, id)
	if sym == nil {
		return 0, false
	}
	if !type_is_carrier(graph.k.c, sym.type) {
		return 0, false // a borrow inside it is a content slot instead
	}
	if sym.kind != .Var && sym.kind != .Parameter {
		return 0, false
	}
	entry := empty_prov_slot(id)
	entry.name = identifier_text(graph.k.c, sym.name)
	entry.span = sym.span
	append(&graph.prov_slots, entry)
	slot := len(graph.prov_slots) - 1
	graph.slot_by_symbol[id] = slot
	if symbol_outlives_bodies(sym) {
		loan := prov_new_loan(
			graph, prov_existing_content_root(graph, id, sym), nil,
			carrier_is_mutable(graph.k.c, sym.type), sym.span, carrier_noun(graph.k.c, sym.type),
		)
		append(&graph.entry_defs, Prov_Entry_Def{slot = slot, loan = loan})
	}
	return slot, true
}

// Another body may have filled static storage, with borrows that outlive the
// process, or the thread for a `thread_local` (design.md "Retaining a borrow").
@(private = "file")
prov_existing_content_root :: proc(graph: ^Flow_Graph, id: Symbol_Id, sym: ^Symbol) -> Root_Id {
	root := prov_new_root(
		graph, sym.duration == .Thread_Local ? .Thread_Local : .Static, sym.span,
		fmt.aprintf("existing content of `%s`", identifier_text(graph.k.c, sym.name), allocator = graph.alloc),
	)
	graph.roots[int(root)].origin = id
	return root
}

// Each literal element's borrows go to its own place; an element whose slot
// can't be resolved joins into every path.
@(private)
prov_composite_content :: proc(graph: ^Flow_Graph, v: ^Expr_Composite, content: []int) -> []int {
	// One part per element value, and for a map one more per key (design.md
	// "Values that contain borrows": a map carries its keys' borrows too).
	Part :: struct {
		loans:  []int,
		prefix: []Proj_Step,
		type:   Type_Id,
		known:  bool,
	}
	parts := make([dynamic]Part, 0, 2 * len(v.elements), graph.alloc)
	literal_type := prov_type(graph, v)
	is_map := underlying_kind(graph.k.c, literal_type) == .Map
	// What earlier elements hold, used again as each later mutable carrier is
	// lent, as `prov_call` does for arguments.
	held: []int
	for element, index in v.elements {
		if is_map {
			loans := walk_flow_expr(graph, element.key)
			prov_hold_owner(graph, element.key)
			// The key is evaluated before its own value, which may write what it
			// read, as may a later element.
			if len(loans) > 0 && (prov_expr_may_write(element.value) || prov_elements_may_write(v.elements[index + 1:])) {
				loans = prov_capture(graph, loans, expr_span(element.key))
			}
			entry := prov_extend(graph, nil, prov_map_entry_step(graph, literal_type, element.key))
			key_type := prov_type(graph, element.key)
			append(&parts, Part{loans, prov_extend(graph, entry, proj_field(PROJ_MAP_KEY)), key_type, true})
		}
		if element.value == nil {
			continue
		}
		element_type := prov_element_type(graph, v, literal_type, index)
		loans := prov_walk_stored(graph, element.value, element_type)
		prov_hold_owner(graph, element.value)
		// design.md "Weakening and reborrows": a mutable carrier stored in an element is a reborrow of it, live
		// until the literal is built, so no later element may use the same
		// carrier: `Pair{xs, xs}` would hold two mutable views of one sequence.
		// A record element is checked as the carriers inside it are (design.md
		// "Values that contain borrows"), so `Outer{Inner{xs}, Inner{xs}}` is
		// caught too.
		lent := type_carries_borrow(graph.k.c, element_type).mutable
		if lent {
			prov_use_copied(graph, loans, element_type, expr_span(element.value), true)
			loans = prov_lend_carrier(graph, loans, held, expr_span(element.value))
		}
		// A later element may write what this one read (design.md "Evaluation
		// order"). A lent carrier needs no copy: it is suspended, so a later
		// element cannot write it, and a copy would end the reborrow early. The
		// read-only carriers of a lent record are still copied.
		if len(loans) > 0 && prov_elements_may_write(v.elements[index + 1:]) {
			loans = prov_capture(graph, loans, expr_span(element.value), keep_reborrows = lent)
		}
		held = prov_join(graph, held, loans)
		prefix, known := prov_element_prefix(graph, v, literal_type, index)
		append(&parts, Part{loans, prefix, prov_type(graph, element.value), known})
	}
	// Building the literal uses each reborrow its elements took, so the
	// carrier stays suspended through every later element, not only the
	// lent ones: `Pair{xs, g(xs)}` uses `xs` while the pair's view is live.
	reborrows := make([dynamic]int, 0, len(held), graph.alloc)
	for slot in held {
		if prov_slot_is_reborrow(graph, slot) {
			append(&reborrows, slot)
		}
	}
	if len(reborrows) > 0 {
		prov_emit(graph, Prov_Event{kind = .Live, sources = reborrows[:], span = v.span})
	}
	for slot in content {
		sources: []int
		for part in parts {
			if len(part.loans) == 0 {
				continue
			}
			if !part.known {
				sources = prov_join(graph, sources, part.loans)
				continue
			}
			if paths_overlap(graph.prov_slots[slot].path, part.prefix) {
				path := graph.prov_slots[slot].path
				suffix := path[min(len(part.prefix), len(path)):]
				sources = prov_join(graph, sources, prov_select_content(graph, part.loans, part.type, suffix))
			}
		}
		prov_define_one_content(graph, slot, sources, v.span)
	}
	return content
}

// The type one literal element is stored as, after any weakening: a `[]mut T`
// stored in a `[]T` field is only read.
@(private)
prov_element_type :: proc(graph: ^Flow_Graph, v: ^Expr_Composite, type: Type_Id, index: int) -> Type_Id {
	c := graph.k.c
	info := underlying_info(c, type)
	if info == nil {
		return prov_type(graph, v.elements[index].value)
	}
	#partial switch info.kind {
	case .Array, .Slice, .Dynamic_Array, .Map:
		return info.element
	case .Struct:
		field := INVALID_SYMBOL
		if key := v.elements[index].key; key == nil {
			if index < len(v.field_indices) && v.field_indices[index] >= 0 && v.field_indices[index] < len(info.fields) {
				field = info.fields[v.field_indices[index]]
			}
		} else if name, is_ident := key.(^Expr_Ident); is_ident {
			field = struct_field(c, type, intern_identifier(c, name.name))
		}
		if sym := symbol_of(c, field); sym != nil {
			return sym.type
		}
	}
	return prov_type(graph, v.elements[index].value)
}

@(private = "file")
prov_elements_may_write :: proc(elements: []Element) -> bool {
	for element in elements {
		if prov_expr_may_write(element.key) || prov_expr_may_write(element.value) {
			return true
		}
	}
	return false
}

@(private = "file")
prov_expr_may_write :: proc(e: Expr) -> bool {
	return e != nil && !is_const_expr(e) && !is_effect_free_place(e)
}

// The path one literal element's value fills: a field, an index range, or a
// map entry's value under its key's entry.
@(private)
prov_element_prefix :: proc(graph: ^Flow_Graph, v: ^Expr_Composite, type: Type_Id, index: int) -> ([]Proj_Step, bool) {
	#partial switch underlying_kind(graph.k.c, type) {
	case .Map:
		entry := prov_extend(graph, nil, prov_map_entry_step(graph, type, v.elements[index].key))
		return prov_extend(graph, entry, proj_field(PROJ_MAP_VALUE)), true
	case .Array:
		step, known := prov_element_step(graph, v, type, true, index)
		return prov_extend(graph, nil, step), known
	}
	step, known := prov_element_step(graph, v, type, false, index)
	return prov_extend(graph, nil, step), known
}

// Which slot one literal element fills. Array elements and fields use different
// step kinds, which must never be compared with each other.
@(private = "file")
prov_element_step :: proc(
	graph: ^Flow_Graph,
	v: ^Expr_Composite,
	value_type: Type_Id,
	is_array: bool,
	index: int,
) -> (Proj_Step, bool) {
	key := v.elements[index].key
	if is_array {
		// design.md "Fixed arrays": a designated element fills its index range.
		lo, hi := composite_element_slots(v, index)
		return proj_range(i64(lo), i64(hi)), true
	}
	if key == nil {
		// Positional elements skip padding, so the checked slot is the field.
		if index < len(v.field_indices) && v.field_indices[index] >= 0 {
			return proj_field(v.field_indices[index]), true
		}
		return proj_field(index), true
	}
	name, is_ident := key.(^Expr_Ident)
	if !is_ident {
		return proj_wild(), false
	}
	field := struct_field(graph.k.c, value_type, intern_identifier(graph.k.c, name.name))
	sym := symbol_of(graph.k.c, field)
	if sym == nil {
		return proj_wild(), false
	}
	return proj_field(int(sym.index)), true
}

// design.md "Unions": a variant's payload sits under the wildcard alternative.
@(private)
prov_variant_content :: proc(graph: ^Flow_Graph, v: ^Expr_Call, loans: []int) -> []int {
	content := prov_temp_content(graph, prov_type(graph, v))
	if len(content) == 0 {
		return nil
	}
	prefix := prov_extend(graph, nil, proj_wild())
	payload_type := INVALID_TYPE
	if len(v.bound) == 1 && v.bound[0] != nil {
		payload_type = prov_type(graph, v.bound[0])
	}
	for slot in content {
		sources: []int
		if len(loans) > 0 && paths_overlap(graph.prov_slots[slot].path, prefix) {
			path := graph.prov_slots[slot].path
			suffix := path[min(len(prefix), len(path)):]
			sources = prov_select_content(graph, loans, payload_type, suffix)
		}
		prov_define_one_content(graph, slot, sources, v.span)
	}
	return content
}

// A value that is not itself a borrow can still hold one. Every place
// `carrier_shape` names gets its own slot, so a field read does not inherit
// what a sibling borrows.
@(private = "file")
prov_content_slots :: proc(graph: ^Flow_Graph, id: Symbol_Id) -> []int {
	if id == INVALID_SYMBOL {
		return nil
	}
	if existing, found := graph.content_by_symbol[id]; found {
		return existing
	}
	sym := symbol_of(graph.k.c, id)
	if sym == nil || type_is_carrier(graph.k.c, sym.type) {
		return nil // a bare carrier already has its own slot
	}
	if sym.kind != .Var && sym.kind != .Parameter {
		return nil
	}
	shape := carrier_shape(graph.k.c, sym.type)
	if len(shape) == 0 {
		return nil // an all-scalar value initializes no payload facts
	}
	unknown_root := NO_ROOT
	if symbol_outlives_bodies(sym) {
		unknown_root = prov_existing_content_root(graph, id, sym)
	}
	slots := make([]int, len(shape), graph.alloc)
	for path, index in shape {
		entry := empty_prov_slot(id)
		entry.name = identifier_text(graph.k.c, sym.name)
		entry.span = sym.span
		entry.path = path.steps
		entry.content_type = path.truncated ? INVALID_TYPE : path.type
		entry.content_shape = sym.type
		entry.content_truncated = path.truncated
		entry.precision = path.precision
		append(&graph.prov_slots, entry)
		slots[index] = len(graph.prov_slots) - 1
		if unknown_root != NO_ROOT {
			loan := prov_new_loan(
				graph, unknown_root, nil, path.mutable, sym.span,
				path.truncated ? "borrow" : carrier_noun(graph.k.c, path.type),
			)
			append(&graph.entry_defs, Prov_Entry_Def{slot = slots[index], loan = loan})
		}
	}
	graph.content_by_symbol[id] = slots
	return slots
}

// The content slots whose shape path overlaps the place's projection.
@(private = "file")
prov_content_at :: proc(graph: ^Flow_Graph, root: Root_Id, path: []Proj_Step) -> []int {
	if root == NO_ROOT {
		return nil
	}
	slots := prov_content_slots(graph, graph.roots[int(root)].symbol)
	if len(slots) == 0 {
		return nil
	}
	if len(path) == 0 {
		return slots
	}
	out := make([dynamic]int, 0, len(slots), graph.alloc)
	for slot in slots {
		if paths_overlap(graph.prov_slots[slot].path, path) {
			append(&out, slot)
		}
	}
	return out[:]
}

// Content slots for an unnamed value, ordered by its carrier shape.
@(private)
prov_temp_content :: proc(graph: ^Flow_Graph, type: Type_Id) -> []int {
	shape := carrier_shape(graph.k.c, type)
	if len(shape) == 0 {
		return nil
	}
	slots := make([]int, len(shape), graph.alloc)
	for path, index in shape {
		entry := empty_prov_slot(INVALID_SYMBOL)
		entry.path = path.steps
		entry.content_type = path.truncated ? INVALID_TYPE : path.type
		entry.content_shape = type
		entry.content_truncated = path.truncated
		entry.precision = path.precision
		append(&graph.prov_slots, entry)
		slots[index] = len(graph.prov_slots) - 1
	}
	return slots
}

// Sources describing this shape are selected by path; others reach every path.
// A distinct type has its underlying type's carrier shape, so a conversion
// between them keeps each carrier's own sources.
@(private = "file")
prov_select_content :: proc(graph: ^Flow_Graph, sources: []int, type: Type_Id, path: []Proj_Step) -> []int {
	c := graph.k.c
	selected: []int
	for source in sources {
		entry := graph.prov_slots[source]
		if type == INVALID_TYPE || entry.content_shape == INVALID_TYPE ||
		   type_underlying(c, entry.content_shape) != type_underlying(c, type) || paths_overlap(entry.path, path) {
			selected = prov_join(graph, selected, prov_one(graph, source))
		}
	}
	return selected
}

// A read's slots are relative to the value read, so a later projection can
// select its own fields.
@(private)
prov_project_content :: proc(
	graph: ^Flow_Graph,
	sources: []int,
	source_type: Type_Id,
	path: []Proj_Step,
	result_type: Type_Id,
	span: Span,
	reads_only := false,
) -> []int {
	if len(sources) == 0 {
		return nil
	}
	content := prov_temp_content(graph, result_type)
	for slot in content {
		full := prov_concat_path(graph, path, graph.prov_slots[slot].path)
		graph.prov_slots[slot].precision |= path_precision(full)
		selected := prov_select_content(graph, sources, source_type, full)
		prov_emit(graph, Prov_Event{kind = .Live, sources = selected, span = span, reads_only = reads_only})
		prov_define_one_content(graph, slot, selected, span)
	}
	return content
}

@(private)
prov_read_content :: proc(graph: ^Flow_Graph, root: Root_Id, path: []Proj_Step, type: Type_Id, span: Span, reads_only := false) -> []int {
	sym := symbol_of(graph.k.c, graph.roots[int(root)].symbol)
	if sym == nil {
		return nil
	}
	return prov_project_content(graph, prov_content_at(graph, root, path), sym.type, path, type, span, reads_only)
}

// Without a field mapping, every result path gets every source.
@(private)
prov_value_content :: proc(graph: ^Flow_Graph, sources: []int, type: Type_Id, span: Span) -> []int {
	return prov_project_content(graph, sources, INVALID_TYPE, nil, type, span)
}

// A `walked` load is of a carrier on the way to a place (`Prov_Event.walked`).
@(private)
prov_load_content :: proc(
	graph: ^Flow_Graph, carriers: []int, path: []Proj_Step, type: Type_Id, span: Span, reads_only := false,
	walked := false,
) -> []int {
	if len(carriers) == 0 {
		return nil
	}
	prov_reach(graph, carriers, span)
	content := prov_temp_content(graph, type)
	graph.has_content_load ||= len(content) > 0
	for slot in content {
		graph.prov_slots[slot].loaded = true
		prov_emit(graph, Prov_Event {
			kind       = .Load,
			slot       = slot,
			into       = carriers,
			path       = prov_concat_path(graph, path, graph.prov_slots[slot].path),
			span       = span,
			reads_only = reads_only,
			walked     = walked,
		})
	}
	prov_emit(graph, Prov_Event{kind = .Live, sources = content, span = span, reads_only = reads_only})
	prov_name_loaded(graph, content, carriers)
	return content
}

// design.md "Weakening and reborrows": a value read out through a carrier only
// reads it when the value carries no mutable borrow, so a read-only reborrow
// of the carrier does not suspend it.
prov_read_is_reads_only :: proc(c: ^Compiler, type: Type_Id) -> bool {
	return !type_carries_borrow(c, type).mutable
}

// design.md "Weakening and reborrows": a carrier stored where a read-only one
// is wanted is only read, which a read-only reborrow of it allows, so
// `Views{xs, xs}`, and `v: []int = xs` or `v = xs` beside another read-only
// view of `xs`, are accepted.
// An erased value is not only read: a stored `any_view` borrows the place it
// views (design.md "any_view type"), which a call argument does only for the
// call.
@(private)
prov_walk_stored :: proc(graph: ^Flow_Graph, value: Expr, destination: Type_Id) -> []int {
	if expr_base(value) != nil && prov_repr(graph, value).erased_from == INVALID_TYPE &&
	   prov_argument_only_read(graph, value, destination) {
		return prov_read_carrier(graph, value, true)
	}
	return walk_flow_expr(graph, value)
}

// A field, element, or pointee that `walk_flow_expr` would read by loading it
// through the carriers it is reached by, with no box, operator, or conversion
// of its own.
@(private = "file")
prov_reads_plainly_through :: proc(graph: ^Flow_Graph, e: Expr) -> bool {
	if base := expr_base(e); base == nil || prov_repr(graph, e).erased_from != INVALID_TYPE || prov_repr(graph, e).view_from != INVALID_TYPE {
		return false
	}
	#partial switch v in e {
	case ^Expr_Postfix:
		return v.op == .Caret && !type_is_box(graph.k.c, prov_type(graph, v.operand))
	case ^Expr_Selector:
		return true
	case ^Expr_Index:
		return v.resolution.kind != .User_Operator
	}
	return false
}

// The carriers `operand` holds, for a read through them.
@(private = "file")
prov_read_carrier :: proc(graph: ^Flow_Graph, operand: Expr, reads_only: bool) -> []int {
	if reads_only {
		if ident, is_ident := operand.(^Expr_Ident); is_ident {
			return prov_read_ident(graph, ident, .Read, reads_only = true)
		}
		if root, path, ok := prov_place_of(graph, operand); ok {
			prov_walk_subscripts(graph, operand)
			prov_access(graph, root, path, .Read, expr_span(operand), reads_only = true)
			return prov_read_content(graph, root, path, prov_type(graph, operand), expr_span(operand), reads_only = true)
		}
		// Copied out through a carrier, as `p^` passed to a `^T` parameter, the
		// stored carrier is only read too.
		if prov_reads_plainly_through(graph, operand) {
			if carriers, path, through := prov_read_through_carrier(graph, operand, reads_only = true); through {
				return prov_load_content(graph, carriers, path, prov_type(graph, operand), expr_span(operand), reads_only = true)
			}
		}
	}
	return walk_flow_expr(graph, operand)
}

// Consuming a value: read what it held, then end the source's own storage. The
// borrows inside it are of other roots and survive (design.md).
@(private)
prov_consume :: proc(graph: ^Flow_Graph, place: Expr, span: Span, verb: string) -> []int {
	source := place
	if moved, is_move := place.(^Expr_Move); is_move {
		provider_move_end(graph, moved)
		source = moved.value
	}
	consumed: []int
	if root, path, ok := prov_place_of(graph, source); ok {
		consumed = prov_content_at(graph, root, path)
	}
	// A bare carrier holds its loans in its own slot rather than as content, and
	// they move with it.
	if ident, is_ident := source.(^Expr_Ident); is_ident && len(consumed) == 0 {
		if slot, is_carrier := prov_slot_for_symbol(graph, ident.symbol); is_carrier {
			consumed = prov_one(graph, slot)
			prov_emit(graph, Prov_Event{kind = .Live, sources = consumed, span = span})
		}
	} else if is_ident && prov_drop_reads(graph, ident.symbol) {
		// The destination takes the borrows, and the local gives them up, or the
		// drop its scope exit still reaches would keep them in use.
		sym := symbol_of(graph.k.c, ident.symbol)
		consumed = prov_project_content(graph, consumed, sym.type, nil, sym.type, span)
		prov_clear_content(graph, ident.symbol, span)
	}
	prov_invalidate(graph, source, span, verb)
	return consumed
}

// design.md "Owners and `drop`": dropping a local runs its `drop` hooks, which
// may read what it borrows, so the drop uses those borrows. A container's own
// drop reads none, so a local without a hand-written hook is not asked. One
// that is or reaches an `@(wakes_on_drop)` type is, hook or not: its drop is
// what the join check asks about (design.md "Releasing before the join").
@(private)
prov_drop_reads :: proc(graph: ^Flow_Graph, id: Symbol_Id) -> bool {
	sym := symbol_of(graph.k.c, id)
	if sym == nil || len(prov_content_slots(graph, id)) == 0 {
		return false
	}
	return type_drop_runs_hook(graph.k.c, sym.type) || type_reaches_waker(graph.k.c, sym.type) != INVALID_TYPE
}

@(private)
prov_drop_use :: proc(graph: ^Flow_Graph, id: Symbol_Id, span: Span, at_scope_exit := false) {
	// A `parallel` block's join uses what its tasks hold.
	if held, joins := graph.task_slots[id]; joins {
		sources := prov_one(graph, held)
		if holds, reborrowed := graph.task_holds[id]; reborrowed {
			sources = prov_join(graph, sources, holds[:])
		}
		prov_emit(graph, Prov_Event{kind = .Live, sources = sources, span = span})
		bit := prov_window_bit(graph, id)
		if tasks, pooled := graph.pool_tasks[id]; pooled && graph.current != NO_BLOCK {
			// Before the join closes the window, which decides where they apply.
			events := &graph.blocks[graph.current].prov
			first := len(events)
			prov_pool_join_effects(graph, tasks[:], span)
			for &event in events[first:] {
				event.joins = bit + 1
			}
		}
		prov_emit(graph, Prov_Event{kind = .Task_Join, slot = bit, span = span})
		// The tasks are done, so a block entered again, as a loop body's is,
		// starts holding nothing.
		for slot in sources {
			prov_emit(graph, Prov_Event{kind = .Def, slot = slot, loan = NO_LOAN, span = span})
		}
	}
	if !prov_drop_reads(graph, id) {
		return
	}
	prov_emit(graph, Prov_Event{kind = .Live, sources = prov_content_slots(graph, id), span = span})
	// The hook may read or write through what the value holds.
	prov_reach(graph, prov_content_slots(graph, id), span)
	if at_scope_exit {
		if graph.scope_drops == nil {
			graph.scope_drops = make(map[Span]bool, 4, graph.alloc)
		}
		graph.scope_drops[span] = true
	}
}

// design.md "Temporaries and procedure boundaries": an extended temporary is
// dropped with its block's locals. Nothing can name it, so nothing moves it
// first: its drop hooks always run there, and what they read stays live.
@(private)
prov_extended_drop :: proc(graph: ^Flow_Graph, root: Prov_Root, effects_at, span: Span) {
	prov_drop_effects(graph, root.dropped, effects_at, "this temporary", unnamed = true)
	if root.content < 0 {
		return
	}
	prov_emit(graph, Prov_Event{kind = .Live, sources = prov_one(graph, root.content), span = span})
	if graph.scope_drops == nil {
		graph.scope_drops = make(map[Span]bool, 4, graph.alloc)
	}
	graph.scope_drops[span] = true
}

// A dropped or moved-out local holds no borrows until it is assigned again.
@(private)
prov_clear_content :: proc(graph: ^Flow_Graph, id: Symbol_Id, span: Span) {
	for slot in prov_content_slots(graph, id) {
		prov_define_one_content(graph, slot, nil, span)
	}
}

// Binds loans to a name no declaration defines: a `foreach` element or a case
// binding.
@(private)
prov_bind_value :: proc(graph: ^Flow_Graph, id: Symbol_Id, sources: []int, span: Span, copies := true) {
	if id == INVALID_SYMBOL {
		return
	}
	if slot, is_carrier := prov_slot_for_symbol(graph, id); is_carrier {
		sym := symbol_of(graph.k.c, id)
		if sym != nil && copies {
			prov_reborrow(graph, sources, sym.type, slot, span, copies = true)
		} else if !copies {
			graph.lent_aliases[slot] = sources
		}
		prov_emit(graph, Prov_Event{kind = .Def, slot = slot, loan = NO_LOAN, sources = sources, span = span})
		return
	}
	if content := prov_content_slots(graph, id); len(content) > 0 {
		prov_define_content(graph, content, sources, span, copies = copies)
	}
}

// design.md "Chunks of a mutable slice": a chunk is a reborrow of the view that
// does not suspend the view, so the view advances while earlier chunks are
// held, and through it the chunk keeps the sliced carrier suspended. Each step
// binds a value disjoint from the last, so redefining the binding severs the
// reborrows taken from the chunk before. False when the binding is not a
// carrier slot.
@(private)
prov_bind_chunk :: proc(graph: ^Flow_Graph, id: Symbol_Id, sources: []int, span: Span) -> bool {
	slot, is_carrier := prov_slot_for_symbol(graph, id)
	if !is_carrier {
		return false
	}
	for source in sources {
		append(&graph.reborrows, Prov_Reborrow{source = source, derived = slot, span = span, mutable = true, passes_on = true})
	}
	graph.fresh_slots[slot] = true
	prov_emit(graph, Prov_Event{kind = .Def, slot = slot, loan = NO_LOAN, sources = sources, span = span})
	return true
}

// Publishes content into another value's slots by matching paths.
@(private = "file")
prov_define_content :: proc(
	graph: ^Flow_Graph,
	into: []int,
	from: []int,
	span: Span,
	written: []Proj_Step = nil,
	value_type: Type_Id = INVALID_TYPE,
	preserve_previous := false,
	copies := true,
	replace_matching := false,
) {
	indistinct := path_is_indistinct(written)
	for slot in into {
		entry := graph.prov_slots[slot]
		type := value_type
		if type == INVALID_TYPE && len(written) == 0 {
			type = entry.content_shape
		}
		path := entry.path[min(len(written), len(entry.path)):]
		sources := prov_select_content(graph, from, type, path)
		// A path standing for many places (container elements, union alternatives)
		// joins, as does a fallible write; a known whole-path write replaces.
		partial_truncated_write := entry.content_truncated && len(written) > len(entry.path)
		whole_replacement := (!indistinct && path_has_exact_prefix(entry.path, written)) ||
		                     (replace_matching && prov_same_path(entry.path, written))
		if preserve_previous || (!whole_replacement &&
		   (indistinct || path_is_indistinct(entry.path) || partial_truncated_write)) {
			sources = prov_join(graph, prov_one(graph, slot), sources)
		}
		prov_define_one_content(graph, slot, sources, span, path_precision(written), copies)
	}
}

@(private = "file")
path_is_indistinct :: proc(path: []Proj_Step) -> bool {
	for step in path {
		if step.kind == .Wild {
			return true
		}
	}
	return false
}

// Whether `path` selects one place: fields and single constant elements,
// none merged.
@(private = "file")
prov_path_names_one_place :: proc(path: []Proj_Step) -> bool {
	for step in path {
		if step.kind != .Field && !(step.kind == .Range && step.hi == step.lo + 1) || step.precision != {} {
			return false
		}
	}
	return true
}

@(private = "file")
path_has_exact_prefix :: proc(path, prefix: []Proj_Step) -> bool {
	if len(prefix) > len(path) {
		return false
	}
	for step, index in prefix {
		other := path[index]
		if step.kind != other.kind || step.lo != other.lo || step.hi != other.hi {
			return false
		}
	}
	return true
}

// A mutable borrow published into a read-only field weakens as at a local.
@(private = "file")
prov_define_one_content :: proc(
	graph: ^Flow_Graph, slot: int, sources: []int, span: Span, precision: Precision_Loss = {}, copies := true,
) {
	entry := graph.prov_slots[slot]
	type := entry.content_type
	if type == INVALID_TYPE && entry.content_shape == INVALID_TYPE {
		if sym := symbol_of(graph.k.c, entry.symbol); sym != nil { type = sym.type }
	}
	if copies {
		prov_reborrow(graph, sources, type, slot, span, copies = true)
	} else {
		graph.lent_aliases[slot] = sources
	}
	prov_emit(graph, Prov_Event{kind = .Def, slot = slot, loan = NO_LOAN, sources = sources, span = span, precision = precision})
	if len(graph.region_aliases[entry.symbol]) > 0 {
		prov_event(graph, Prov_Event_View_Publish {
			symbol = entry.symbol, path = entry.path, sources = sources, span = span,
			type = type, through = graph.view_loans[entry.symbol],
		})
	}
}

// The storage a borrowed binding names can grow as the facts settle, so its
// write is published into the construction graph's slots with the aliases
// `graph` has at the site.
@(private)
prov_materialize_view_publish :: proc(graph: ^Flow_Graph, op: Prov_Event_View_Publish) {
	output := prov_output(graph)
	if output == graph {
		prov_publish_view_content(graph, prov_root_for_symbol(graph, op.symbol), nil, op.path, op.sources, op.span, op.type, op.through)
		return
	}
	aliases, current, expansion := output.region_aliases, output.current, output.expansion
	output.region_aliases, output.current, output.expansion = graph.region_aliases, graph.current, graph.expansion
	defer output.region_aliases, output.current, output.expansion = aliases, current, expansion
	first := graph.current == NO_BLOCK ? 0 : len(output.blocks[graph.current].prov)
	prov_publish_view_content(output, prov_root_for_symbol(output, op.symbol), nil, op.path, op.sources, op.span, op.type, op.through)
	if graph.current == NO_BLOCK { return }
	// The events are the materialization's, which replaces the site's.
	emitted := &output.blocks[graph.current].prov
	append(&graph.blocks[graph.current].prov, ..emitted[first:])
	resize(emitted, first)
}

// A borrowed case binding is a name for the subject's payload. Keep its
// carrier writes in that storage as well, so later reads and scope exits see
// them (design.md "Values that contain borrows"). Resolve known aliases before
// publishing; only unresolved storage needs the solver's carrier fallback.
@(private = "file")
prov_publish_view_content :: proc(
	graph: ^Flow_Graph, root: Root_Id, prefix, path: []Proj_Step,
	sources: []int, span: Span, type: Type_Id, through: []int, unique := true,
) {
	if root != NO_ROOT {
		id := graph.roots[int(root)].symbol
		if aliases := graph.region_aliases[id]; len(aliases) > 0 {
			for alias in aliases {
				prov_publish_view_content(graph, alias.root, prov_concat_path(graph, alias.path, prefix),
				                          path, sources, span, type, through, unique && len(aliases) == 1)
			}
			return
		}
		if sym := symbol_of(graph.k.c, id); sym != nil && !type_is_carrier(graph.k.c, sym.type) {
			// Region paths distinguish union tags; carrier shapes use a wildcard
			// for the payload. Convert only the alias prefix, not the leaf path.
			borrowed := make([]Proj_Step, len(prefix), graph.alloc)
			current := sym.type
			exact := unique && path_precision(prefix) == {}
			for step, index in prefix {
				kind := underlying_kind(graph.k.c, current)
				borrowed[index] = kind == .Union ? proj_wild() : step
				if step.kind == .Wild && kind != .Box { exact = false }
				current = prov_type_at(graph.k.c, current, {step})
			}
			written := prov_concat_path(graph, borrowed, path)
			// This is the binding slot's complete content, including any join
			// for a partial write. A selected tag does not make that leaf partial.
			// design.md "Values that contain borrows": a possible target keeps
			// its old borrows, since the write may reach another alias instead.
			prov_define_content(graph, prov_content_at(graph, root, written), sources, span, written, type,
			                    preserve_previous = !exact, replace_matching = exact)
			return
		}
	}
	prov_emit(graph, Prov_Event{kind = .Publish, span = span, sources = sources, into = through})
}

// design.md "defer statement": a result is taken before its exit path's
// deferred statements run, and what it borrows must survive them. The caller
// emits a `Live` of the hold after the cleanups.
@(private)
prov_hold_result :: proc(graph: ^Flow_Graph, sources: []int, result_type: Type_Id, span: Span) -> []int {
	if len(sources) == 0 {
		return nil
	}
	held := prov_temp_slot(graph)
	graph.prov_slots[held].returned = true
	prov_reborrow(graph, sources, result_type, held, span)
	prov_emit(graph, Prov_Event{kind = .Def, slot = held, loan = NO_LOAN, sources = sources, span = span})
	return prov_one(graph, held)
}

// design.md "Evaluation order": a value is evaluated before the expressions
// after it, and keeps what its carriers held then, whatever those expressions
// write. A mutable carrier is reborrowed into a derived slot, which keeps the
// source suspended as storing it would; any other slot is copied into a
// temporary. A copy of a reborrow is a reborrow of the same source, so the
// source stays suspended while the copy is live, though the slot it came from
// may be assigned. With `keep_reborrows`, a slot that is already a mutable
// reborrow, as a lent carrier is, is kept as it is: the carrier it suspends
// cannot be written meanwhile. A read-only reborrow, such as a `[]int` field
// weakened from a `[]mut int`, is still copied: a later element may assign
// the field.
@(private = "file")
prov_capture :: proc(graph: ^Flow_Graph, slots: []int, span: Span, keep_reborrows := false) -> []int {
	out := make([dynamic]int, 0, len(slots), graph.alloc)
	for slot in slots {
		if keep_reborrows && prov_slot_is_reborrow(graph, slot, mutable_only = true) {
			append(&out, slot)
			continue
		}
		if prov_slot_is_mutable_carrier(graph, slot) {
			append(&out, ..prov_reborrow_traversal(graph, prov_one(graph, slot), span, true))
			continue
		}
		held := prov_hold_slot(graph, slot, span)
		for index in 0 ..< len(graph.reborrows) {
			if reborrow := graph.reborrows[index]; reborrow.derived == slot {
				reborrow.derived = held
				reborrow.span = span
				append(&graph.reborrows, reborrow)
			}
		}
		append(&out, held)
	}
	return out[:]
}

// The slots among `slots` that a later write in the same evaluation will
// redefine, each replaced by a temporary holding what it holds now.
@(private = "file")
prov_capture_slots :: proc(graph: ^Flow_Graph, slots: []int, rewritten: []int, span: Span) -> []int {
	out := make([dynamic]int, 0, len(slots), graph.alloc)
	for slot in slots {
		if !slice.contains(rewritten, slot) {
			append(&out, slot)
			continue
		}
		append(&out, prov_hold_slot(graph, slot, span))
	}
	return out[:]
}

// A temporary holding what `slot` holds now. It keeps the place in a value's
// shape that `slot` stands for, so a later field selection still tells it
// apart from its siblings (design.md "Minimum provenance precision"): the
// first element of `[2]Pair{{"static", source}, {"x", other}}` is captured
// while the second is built, and its `a` must not take `b`'s borrow.
@(private = "file")
prov_hold_slot :: proc(graph: ^Flow_Graph, slot: int, span: Span) -> int {
	held := prov_temp_slot(graph)
	source := graph.prov_slots[slot]
	entry := &graph.prov_slots[held]
	entry.path = source.path
	entry.content_type = source.content_type
	entry.content_shape = source.content_shape
	entry.content_truncated = source.content_truncated
	entry.precision = source.precision
	prov_emit(graph, Prov_Event{kind = .Def, slot = held, loan = NO_LOAN, sources = prov_one(graph, slot), span = span})
	return held
}

// A slice local whose elements are plain data, which reading cannot turn into
// a way to write (design.md "Weakening and reborrows").
@(private)
prov_plain_slice_local :: proc(graph: ^Flow_Graph, e: Expr) -> (^Expr_Ident, bool) {
	ident, is_ident := e.(^Expr_Ident)
	// A conversion such as `[dynamic]T` to `[]T` borrows an owner instead.
	if !is_ident || prov_repr(graph, ident).view_from != INVALID_TYPE {
		return nil, false
	}
	// An erased operand's own type is `any_view`.
	type := prov_repr(graph, ident).erased_from != INVALID_TYPE ? prov_repr(graph, ident).erased_from : prov_type(graph, ident)
	if underlying_kind(graph.k.c, type) != .Slice {
		return nil, false
	}
	if _, is_carrier := prov_slot_for_symbol(graph, ident.symbol); !is_carrier {
		return nil, false
	}
	return ident, !type_carries_borrow(graph.k.c, underlying_info(graph.k.c, type).element).any
}

// A carrier place passed to a parameter that can write through nothing it
// receives, as `held.items` passed to a `[]int`, or one read out through a
// carrier, as `p^` passed to a `^T`: the call only reads it.
@(private = "file")
prov_argument_only_read :: proc(graph: ^Flow_Graph, argument: Expr, parameter: Type_Id) -> bool {
	c := graph.k.c
	if expr_base(argument) == nil {
		return false
	}
	repr := prov_repr(graph, argument)
	// A conversion such as `[dynamic]T` to `[]T` borrows an owner instead.
	if repr.view_from != INVALID_TYPE || type_carries_borrow(c, parameter).mutable {
		return false
	}
	// An erased operand's own type is `any_view`.
	type := repr.erased_from != INVALID_TYPE ? repr.erased_from : repr.type
	if !type_is_carrier(c, type) {
		return false
	}
	if _, is_ident := argument.(^Expr_Ident); is_ident {
		return true
	}
	_, _, place := prov_place_of(graph, argument)
	return place || prov_reads_plainly_through(graph, argument) && len(prov_place_hops(graph, argument)) > 0
}

@(private = "file")
prov_temp_slot :: proc(graph: ^Flow_Graph) -> int {
	append(&graph.prov_slots, empty_prov_slot(INVALID_SYMBOL))
	return len(graph.prov_slots) - 1
}

// A carrier stored into `into` from `slots` (design.md "Weakening and
// reborrows"). A fresh mutable loan weakens to a read-only destination, which
// settles both the loan and its access. An existing mutable carrier is instead
// reborrowed, read-only or mutably, and suspended while `into` is live. `into`
// is -1 for a call argument, which `prov_call` instead gives derived slots of
// its own, live until the call returns. A `copies` destination that is named
// storage, a local or a field of one, or storage written through a carrier
// (`into` -1), takes a copy that uses all of what the carrier points to
// (`prov_use_copied`); a call argument says so itself, and a temporary
// holding a read is no copy.
@(private = "file")
prov_reborrow :: proc(graph: ^Flow_Graph, slots: []int, destination: Type_Id, into := -1, span := Span{}, copies := false) {
	if !type_is_carrier(graph.k.c, destination) {
		return
	}
	weakens := !carrier_is_mutable(graph.k.c, destination)
	if copies && (into < 0 || graph.prov_slots[into].symbol != INVALID_SYMBOL) {
		prov_use_copied(graph, slots, destination, span, !weakens, into)
	}
	for slot in slots {
		entry := graph.prov_slots[slot]
		// A borrow weakened to a read-only destination is taken read-only.
		if weakens {
			for &loan in graph.place_loans {
				if loan.borrows && loan.slot == slot {
					loan.mutable = false
				}
			}
		}
		if entry.through_block != NO_BLOCK {
			if weakens {
				// It still reads what it borrows.
				for index in entry.through_index ..< entry.through_end {
					graph.blocks[entry.through_block].prov[index].access = .Read
				}
				prov_weaken_walk(graph, entry)
			}
			continue
		}
		if entry.fresh_loan != NO_LOAN {
			if weakens && !path_is_synchronized(graph.loans[int(entry.fresh_loan)].path) {
				graph.loans[int(entry.fresh_loan)].mutable = false
				if entry.fresh_access_index >= 0 {
					graph.blocks[entry.fresh_access_block].prov[entry.fresh_access_index].access = .Read
				}
			}
			continue
		}
		// Storing a carrier into itself, as `xs = xs[1:]`, suspends nothing. A
		// reborrow passes on to its copies and to what is taken from its elements.
		if into < 0 || into == slot {
			continue
		}
		// A copy of a lent element reborrows the stored carrier it names.
		if aliased, lent := graph.lent_aliases[slot]; lent {
			prov_reborrow(graph, aliased, destination, into, span, copies)
		}
		mutable_source := prov_slot_is_mutable_carrier(graph, slot) || prov_slot_is_loaded_mutable(graph, slot)
		reborrowed := prov_slot_is_reborrow(graph, slot)
		if !mutable_source && !reborrowed {
			continue
		}
		// An unnamed value read out of a mutable carrier, as `held.items`, has
		// only this destination, so it takes the destination's capability as a
		// fresh loan does.
		if weakens && graph.prov_slots[slot].symbol == INVALID_SYMBOL {
			for &earlier in graph.reborrows {
				if earlier.derived == slot {
					earlier.mutable = false
				}
			}
		}
		// A named read-only reborrow is not itself suspended by its copies.
		passes_on := !mutable_source && graph.prov_slots[slot].symbol != INVALID_SYMBOL
		append(&graph.reborrows, Prov_Reborrow {
			source = slot, derived = into, span = span, mutable = !weakens, passes_on = passes_on,
		})
	}
}

// The reads of the carriers a mutable borrow through them went through, made
// reads only once the borrow is weakened (`Prov_Slot.walk_reads`).
@(private = "file")
prov_weaken_walk :: proc(graph: ^Flow_Graph, marker: Prov_Slot) {
	for at in marker.walk_reads {
		graph.blocks[at.block].prov[at.event].reads_only = true
	}
}

// A mutable carrier copied out through a pointer, as `pp^`, reborrows each
// carrier the `Load` read, a local's or what a parameter's caller storage
// holds (design.md "Weakening and reborrows"); `prov_reborrow` has already
// linked it to where it was stored.
@(private)
prov_reborrow_loaded :: proc(graph: ^Flow_Graph, event: Prov_Event) {
	if !prov_slot_is_loaded_mutable(graph, event.slot) {
		return
	}
	// Its capability is the one the copy is stored with.
	mutable := true
	for reborrow in graph.reborrows {
		if reborrow.source == event.slot {
			mutable = reborrow.mutable
		}
	}
	passes_on := graph.prov_slots[event.slot].viewed
	for source in event.sources {
		if prov_slot_is_mutable_carrier(graph, source) || graph.prov_slots[source].caller_mutable {
			append(&graph.reborrows, Prov_Reborrow {
				source = source, derived = event.slot, span = event.span, mutable = mutable, passes_on = passes_on, via = event.into,
				walked = event.walked,
			})
		}
	}
}

@(private = "file")
prov_slot_is_loaded_mutable :: proc(graph: ^Flow_Graph, slot: int) -> bool {
	entry := graph.prov_slots[slot]
	c := graph.k.c
	return entry.loaded && entry.content_type != INVALID_TYPE &&
		!type_is_region_provider(c, entry.content_type) && carrier_is_mutable(c, entry.content_type)
}

// A traversal of a mutable carrier reborrows it for as long as the traversal,
// or anything taken from an element, is used: the carrier is suspended, as a
// local source is by its loop loan.
@(private)
prov_reborrow_traversal :: proc(graph: ^Flow_Graph, sources: []int, span: Span, mutable: bool) -> []int {
	out := make([dynamic]int, 0, len(sources), graph.alloc)
	for slot in sources {
		if !prov_slot_is_mutable_carrier(graph, slot) {
			append(&out, slot)
			continue
		}
		derived := prov_temp_slot(graph)
		prov_emit(graph, Prov_Event{kind = .Def, slot = derived, loan = NO_LOAN, sources = prov_one(graph, slot), span = span})
		append(&graph.reborrows, Prov_Reborrow{source = slot, derived = derived, span = span, mutable = mutable})
		append(&out, derived)
	}
	return out[:]
}

// A reborrow of a carrier, named or a traversal's, whose copies extend it.
@(private = "file")
prov_slot_is_reborrow :: proc(graph: ^Flow_Graph, slot: int, mutable_only := false) -> bool {
	for reborrow in graph.reborrows {
		if reborrow.derived == slot && (reborrow.mutable || !mutable_only) {
			return true
		}
	}
	return false
}

// A named slot, or a field of one, holding a mutable view (`^mut T`, `[]mut T`,
// `dyn mut I`); a temporary is left alone. A region provider is not one: copies
// of an allocator share it by design.
@(private = "file")
prov_slot_is_mutable_carrier :: proc(graph: ^Flow_Graph, slot: int) -> bool {
	entry := graph.prov_slots[slot]
	type := entry.content_type
	if type == INVALID_TYPE {
		sym := symbol_of(graph.k.c, entry.symbol)
		if sym == nil {
			return false
		}
		type = sym.type
	}
	c := graph.k.c
	return entry.symbol != INVALID_SYMBOL && !type_is_region_provider(c, type) && carrier_is_mutable(c, type)
}

@(private = "file")
prov_new_loan :: proc(
	graph: ^Flow_Graph,
	root: Root_Id,
	path: []Proj_Step,
	mutable: bool,
	span: Span,
	what: string,
) -> Loan_Id {
	if mutable {
		prov_note_static_write(graph, root, span)
		descriptor := graph.roots[int(root)]
		if descriptor.kind == .Local && descriptor.symbol != INVALID_SYMBOL {
			graph.lent_locals[descriptor.symbol] = true
		}
		// Whatever is written through the loan, the variable may now hold.
		prov_note_proc_store(graph, descriptor.symbol, nil)
	}
	append(&graph.loans, Prov_Loan{root = root, path = path, mutable = mutable, span = span, what = what})
	return Loan_Id(len(graph.loans) - 1)
}

// A fresh borrow in a temporary slot; its consumer decides how long it lives.
@(private)
prov_borrow :: proc(
	graph: ^Flow_Graph,
	root: Root_Id,
	path: []Proj_Step,
	mutable: bool,
	span: Span,
	what: string,
	access_block := NO_BLOCK,
	access_index := -1,
) -> []int {
	// design.md "@(synchronized)": even a read-only borrow of a synchronized
	// field excludes every other access while it lasts.
	loan := prov_new_loan(graph, root, path, mutable || path_is_synchronized(path), span, what)
	slot := prov_temp_slot(graph)
	graph.prov_slots[slot].fresh_loan = loan
	graph.prov_slots[slot].fresh_access_block = access_block
	graph.prov_slots[slot].fresh_access_index = access_index
	prov_emit(graph, Prov_Event{kind = .Def, slot = slot, loan = loan, span = span})
	return prov_join(graph, prov_one(graph, slot), prov_root_view(graph, root))
}

// Returns where the event landed so weakening can revise it; `index` is -1 when
// nothing was emitted.
@(private)
prov_access :: proc(
	graph: ^Flow_Graph,
	root: Root_Id,
	path: []Proj_Step,
	kind: Access_Kind,
	span: Span,
	verb := "",
	reads_only := false,
) -> (block: Block_Id, index: int) {
	if root == NO_ROOT {
		return NO_BLOCK, -1
	}
	if kind != .Read {
		prov_note_static_write(graph, root, span)
	}
	// design.md "@(synchronized)": a synchronizing operation may write the
	// field through any read-only borrow, so even reading it conflicts with one.
	// It is still no write to a global's effect.
	access := kind
	if kind == .Read && path_is_synchronized(path) {
		access = .Write
	}
	// A use through a view binding is reported under the binding's name.
	// Reached through carriers, it uses them only for the payload, as reading
	// it there would.
	name := graph.roots[int(root)].name
	use, found := graph.view_uses[graph.roots[int(root)].symbol]
	if viewed := prov_root_view(graph, root); len(viewed) > 0 {
		event := Prov_Event{kind = .Live, sources = viewed, span = span, name = name}
		if found && use.load {
			event.reads_only = reads_only
		}
		prov_emit(graph, event)
	}
	if found && use.load {
		graph.has_content_load = true
		prov_emit(graph, Prov_Event {
			kind = .Load, slot = prov_temp_slot(graph), into = use.slots, path = use.path, span = span,
			name = name, reads_only = reads_only,
		})
	} else if found {
		prov_emit(graph, Prov_Event{kind = .Live, sources = use.slots, span = span, name = name, reads_only = reads_only})
	}
	prov_emit(graph, Prov_Event {
		kind   = .Access,
		root   = root,
		path   = path,
		access = access,
		span   = span,
		verb   = verb,
	})
	if graph.current == NO_BLOCK {
		return NO_BLOCK, -1
	}
	return graph.current, len(graph.blocks[graph.current].prov) - 1
}

@(private)
prov_extend :: proc(graph: ^Flow_Graph, path: []Proj_Step, step: Proj_Step) -> []Proj_Step {
	out := make([]Proj_Step, len(path) + 1, graph.alloc)
	copy(out, path)
	out[len(path)] = step
	return out
}

@(private)
prov_concat_path :: proc(graph: ^Flow_Graph, prefix, path: []Proj_Step) -> []Proj_Step {
	out := make([]Proj_Step, len(prefix) + len(path), graph.alloc)
	copy(out, prefix)
	copy(out[len(prefix):], path)
	return out
}

// design.md: a borrowed parameter starts with one loan of the caller's root.
@(private)
prov_bind_parameters :: proc(graph: ^Flow_Graph, literal: ^Expr_Proc) {
	if literal.signature == nil {
		return
	}
	position := 0
	for parameter in literal.signature.params {
		position += len(parameter.symbols)
	}
	graph.param_count = position
	position = 0
	for parameter in literal.signature.params {
		for id in parameter.symbols {
			index := position
			position += 1
			sym := symbol_of(graph.k.c, id)
			if sym == nil {
				continue
			}
			// design.md "Allocator regions and region provenance": an owner moved in,
			// a copy of one passed in, and what a carrier passed in views keep the
			// argument's region, which the caller substitutes.
			if type_underlying(graph.k.c, sym.type) == TYPE_ALLOCATOR || type_is_managed(graph.k.c, sym.type) ||
			   type_is_carrier(graph.k.c, sym.type) && !type_is_region_provider(graph.k.c, sym.type) {
				set := prov_empty_region(graph)
				set.params[index] = true
				graph.region_of[id] = set
			}
			// A `move` parameter is dropped when the body returns; callers see
			// that write through this body's effect, and its release frees in
			// the argument's region.
			if parameter.mode == .Move {
				prov_scope_drop_effects(graph, id, sym.span)
			}
			slot, is_carrier := prov_slot_for_symbol(graph, id)
			// An aggregate parameter gets one loan per shape path.
			content := prov_content_slots(graph, id)
			if !is_carrier && len(content) == 0 {
				continue
			}
			name := identifier_text(graph.k.c, sym.name)
			root := prov_new_root(graph, .Param, sym.span, name)
			first_loan := len(graph.loans)
			graph.roots[int(root)].symbol = id
			graph.roots[int(root)].storage = prov_storage_id(graph, Written_Storage{symbol = id})
			graph.roots[int(root)].param_index = index
			// What the caller storage it reaches holds, which loads through it yield.
			depths := make([]Loan_Id, max(1, load_depth(graph.k.c, sym.type)), graph.alloc)
			for &loan, depth in depths {
				loan = prov_new_loan(graph, root, nil, type_carries_borrow(graph.k.c, sym.type).mutable, sym.span, carrier_noun(graph.k.c, sym.type))
				graph.loans[int(loan)].content = true
				graph.loans[int(loan)].depth = depth + 1
			}
			graph.roots[int(root)].content_loans = depths
			if !is_carrier {
				shape := carrier_shape(graph.k.c, sym.type)
				for path, path_index in shape {
					loan := prov_new_loan(
						graph,
						root,
						path.steps,
						path.mutable,
						sym.span,
						path.truncated ? "borrow" : carrier_noun(graph.k.c, path.type),
					)
					graph.loans[int(loan)].content = true
					append(&graph.entry_defs, Prov_Entry_Def{slot = content[path_index], loan = loan})
				}
				prov_caller_slots(graph, root, first_loan, name)
				continue
			}
			loan := prov_new_loan(graph, root, nil, carrier_is_mutable(graph.k.c, sym.type), sym.span, carrier_noun(graph.k.c, sym.type))
			append(&graph.entry_defs, Prov_Entry_Def{slot = slot, loan = loan})
			// design.md "Procedure result contracts": a load along one path of the
			// pointee reads only that path, and so do the loads below it, so a
			// field read out of `[]Pair` or `d.pair.a` names none of its siblings.
			// One path tells nothing apart.
			if pointee := carrier_pointee_shape(graph.k.c, sym.type); len(pointee) > 1 {
				paths := make([][]Loan_Id, len(pointee), graph.alloc)
				for path, at in pointee {
					paths[at] = make([]Loan_Id, len(depths), graph.alloc)
					for &deeper, depth in paths[at] {
						first := depth == 0
						deeper = prov_new_loan(
							graph, root, nil, first ? path.mutable : graph.loans[int(depths[depth])].mutable, sym.span,
							first && path.truncated ? "borrow" : carrier_noun(graph.k.c, first ? path.type : sym.type),
						)
						graph.loans[int(deeper)].content = true
						graph.loans[int(deeper)].depth = depth + 1
						graph.loans[int(deeper)].pointee = at + 1
					}
				}
				graph.roots[int(root)].pointee_loans = paths
			}
			prov_caller_slots(graph, root, first_loan, name)
		}
	}
}

// design.md "Weakening and reborrows": the caller storage a parameter's loan
// names has no content here, so a slot stands for what it holds, holding the
// loan one more load through it reads, as a local's content slot holds what
// was stored there. A load through the parameter reads these slots, so a
// mutable copy out of the caller's storage reborrows what holds it there, as
// a copy out of a local's does, and is suspended by the same uses. Storage
// whose type is known holds a slot per carrier path in it, as `p^^.head` and
// `p^^.tail` with `p: ^mut ^mut List`; the own loan of a parameter with more
// than one pointee path has a slot per path holding that path's own loan.
// A slot is a mutable carrier when what is stored there is one, as `head` is
// in `h: ^Holder` with `head: ^mut Node` (design.md "Values that contain
// borrows"), whatever the loan reaching it allows. Where the storage's type is
// not known, it may be one when the parameter reaches any mutable carrier.
// A store through a loan naming one storage, reached through pointers alone,
// lands in these slots and replaces the one holding exactly the carrier
// stored (`publish_into_caller`); one through a view, whose slots stand for
// every element, joins into the parameter itself. Slots of different loans
// are taken to name different storage.
@(private = "file")
prov_caller_slots :: proc(graph: ^Flow_Graph, root: Root_Id, first: int, name: string) {
	c := graph.k.c
	descriptor := graph.roots[int(root)]
	type := symbol_of(c, descriptor.symbol).type
	pointee: []Carrier_Path
	if len(descriptor.pointee_loans) > 0 {
		pointee = carrier_pointee_shape(c, type)
	}
	shape := carrier_shape(c, type)
	reaches_mutable := type_carries_borrow(c, type).mutable
	last := len(graph.loans)
	for index in first ..< last {
		loan := graph.loans[index]
		if !loan.content && len(pointee) > 0 {
			one := prov_pointers_below(c, type, 0)
			for loans, position in descriptor.pointee_loans {
				prov_caller_slot(graph, Loan_Id(index), pointee[position], loans[0], name, pointee[position].mutable, one)
			}
			continue
		}
		held := Loan_Id(deeper_content_loan(descriptor, loan, index))
		// The carrier type holding this loan, followed down from the parameter
		// while each storage holds one carrier; the last content loan stands
		// for every depth below it, so its storage is not one type.
		holder := INVALID_TYPE
		one := false
		switch {
		case loan.pointee > 0:
			at := pointee[loan.pointee - 1]
			holder = prov_carrier_below(c, at.type, loan.depth - 1)
			one = prov_pointers_below(c, type, 0) && prov_path_names_one_place(at.steps) &&
				prov_pointers_below(c, at.type, loan.depth - 1)
		case !loan.content:
			holder = type
			one = prov_pointers_below(c, type, 0)
		case loan.depth == 0:
			for path in shape {
				if slice.equal(path.steps, loan.path) && !path.truncated {
					holder = path.type
				}
			}
			one = holder != INVALID_TYPE && prov_path_names_one_place(loan.path) && prov_pointers_below(c, holder, 0)
		case loan.depth < len(descriptor.content_loans):
			holder = prov_carrier_below(c, type, loan.depth)
			one = holder != INVALID_TYPE && prov_pointers_below(c, type, loan.depth)
		}
		paths: []Carrier_Path
		if element := prov_pointee_type(c, holder); element != INVALID_TYPE {
			paths = carrier_shape(c, element)
		}
		if len(paths) < 2 {
			// One carrier path at the storage itself is the slot's whole content.
			whole := Carrier_Path{type = INVALID_TYPE}
			if len(paths) == 1 && len(paths[0].steps) == 0 {
				whole = paths[0]
			}
			mutable := len(paths) == 1 ? paths[0].mutable : graph.loans[int(held)].mutable || reaches_mutable
			prov_caller_slot(graph, Loan_Id(index), whole, held, name, mutable, one)
			continue
		}
		for path in paths {
			// Each carrier in one storage holds a loan of its own, as each
			// pointee path's does, so what `p^^.head` and `p^^.tail` point at
			// are told apart. Loads below it read what `held` stands for.
			own := held
			if one {
				own = prov_new_loan(
					graph, root, nil, path.mutable, descriptor.span, path.truncated ? "borrow" : carrier_noun(c, path.type),
				)
				graph.loans[int(own)].content = true
				graph.loans[int(own)].depth = graph.loans[int(held)].depth
				graph.loans[int(own)].pointee = graph.loans[int(held)].pointee
			}
			prov_caller_slot(graph, Loan_Id(index), path, own, name, path.mutable, one)
		}
	}
}

// Whether `depth` loads below a carrier of `type`, and the carrier itself,
// name one storage: each carrier on the way is a pointer, not a view of
// several elements, and each storage between holds one carrier.
@(private = "file")
prov_pointers_below :: proc(c: ^Compiler, type: Type_Id, depth: int) -> bool {
	at := type
	for step in 0 ..= depth {
		if underlying_kind(c, at) != .Pointer {
			return false
		}
		if step == depth {
			break
		}
		inner := carrier_shape(c, prov_pointee_type(c, at))
		if len(inner) != 1 || inner[0].truncated {
			return false
		}
		at = inner[0].type
	}
	return true
}

// What a pointer or slice of `type` points at, or INVALID_TYPE.
@(private = "file")
prov_pointee_type :: proc(c: ^Compiler, type: Type_Id) -> Type_Id {
	if info := underlying_info(c, type); type != INVALID_TYPE && info != nil && (info.kind == .Pointer || info.kind == .Slice) {
		return info.element
	}
	return INVALID_TYPE
}

// The carrier `depth` loads below one of `type`, when each storage on the way
// holds exactly one; INVALID_TYPE otherwise.
@(private = "file")
prov_carrier_below :: proc(c: ^Compiler, type: Type_Id, depth: int) -> Type_Id {
	at := type
	for _ in 0 ..< depth {
		element := prov_pointee_type(c, at)
		if element == INVALID_TYPE {
			return INVALID_TYPE
		}
		inner := carrier_shape(c, element)
		if len(inner) != 1 || inner[0].truncated {
			return INVALID_TYPE
		}
		at = inner[0].type
	}
	return at
}

@(private = "file")
prov_caller_slot :: proc(
	graph: ^Flow_Graph, loan: Loan_Id, path: Carrier_Path, held: Loan_Id, name: string, mutable: bool, one: bool,
) {
	entry := empty_prov_slot(INVALID_SYMBOL)
	entry.name = name
	entry.path = path.steps
	entry.content_type = path.truncated ? INVALID_TYPE : path.type
	entry.content_truncated = path.truncated
	entry.caller_mutable = mutable
	entry.caller_one = one
	append(&graph.prov_slots, entry)
	slot := len(graph.prov_slots) - 1
	if loan not_in graph.caller_slots {
		graph.caller_slots[loan] = make([dynamic]int, 0, 4, graph.alloc)
	}
	append(&graph.caller_slots[loan], slot)
	append(&graph.entry_defs, Prov_Entry_Def{slot = slot, loan = held})
}

// Erasing into an `any_view` keeps the source root with a read-only loan
// (design.md).
@(private)
prov_erase :: proc(graph: ^Flow_Graph, e: Expr) -> []int {
	span := expr_span(e)
	// design.md "Borrowed callable views": a procedure is the view's data word
	// itself, so holding one borrows nothing.
	if repr := prov_repr(graph, e); dyn_proc_signature(graph.k.c, repr.type) != INVALID_TYPE &&
	   underlying_kind(graph.k.c, repr.erased_from) == .Proc {
		return walk_flow_expr_erased(graph, e)
	}
	// Also a use of what a carrier already refers to, so erasure cannot hide
	// a stale view. A view of a slice local only reads it, so it holds a
	// read-only reborrow, as a `[]T` parameter would.
	// A field or element holding such a slice is read the same way, so two
	// views of `held.items` may be live together.
	loans: []int
	if ident, plain := prov_plain_slice_local(graph, e); plain {
		loans = prov_reborrow_traversal(graph, prov_read_ident(graph, ident, .Read, reads_only = true), span, false)
	} else if prov_plain_slice_place(graph, e) {
		loans = prov_reborrow_traversal(graph, prov_read_erased_place(graph, e), span, false)
	} else {
		loans = walk_flow_expr_erased(graph, e)
	}
	if root, path, ok := prov_place_of(graph, e); ok {
		return prov_join(graph, loans, prov_borrow(graph, root, path, false, span, "view"))
	}
	// A temporary ends with its statement unless a local's value extends it
	// (design.md "Temporaries and procedure boundaries"), and the view with it.
	if !expr_base(e).is_const {
		return prov_join(graph, loans, prov_borrow(graph, prov_temp_root_of(graph, e, loans), nil, false, span, "view"))
	}
	if len(loans) > 0 {
		return loans
	}
	// A constant's hidden storage is a frame slot that follows the lexical scope.
	root := prov_hidden_root(graph, span, "this erased value")
	graph.roots[int(root)].extended = true
	return prov_borrow(graph, root, nil, false, span, "view")
}

// design.md "string type conversions", "Dynamic arrays", and "Fixed arrays": a
// `string` read as a `string_view`, or a `[dynamic]T` or `[N]T` as a `[]T`, borrows the owner it came
// from, or the temporary that holds it. A constant's storage is static.
@(private)
prov_owner_view :: proc(graph: ^Flow_Graph, e: Expr) -> []int {
	base := expr_base(e)
	viewed := prov_type(graph, e)
	prov_begin_conversion(graph, e, .View)
	defer prov_end_conversion(graph)
	noun := "string view"
	#partial switch underlying_kind(graph.k.c, viewed) {
	case .Slice:   noun = "slice"
	case .Pointer: noun = "pointer"
	}
	span := expr_span(e)
	if root, path, ok := prov_place_of(graph, e); ok {
		loans := walk_flow_expr(graph, e)
		if base.is_const {
			return loans
		}
		return prov_join(graph, loans, prov_borrow(graph, root, path, false, span, noun))
	}
	// Reached through a pointer or view: the view borrows what that names.
	if carriers, _, through := prov_read_through_carrier(graph, e); through {
		return carriers
	}
	loans := walk_flow_expr(graph, e)
	if base.is_const || !prov_expr_is_temporary(e) {
		return loans
	}
	return prov_join(graph, loans, prov_borrow(graph, prov_temp_root_of(graph, e, loans), nil, false, span, noun))
}

// A compiler-created root ending with its scope.
@(private = "file")
prov_hidden_root :: proc(graph: ^Flow_Graph, span: Span, name: string) -> Root_Id {
	root := prov_new_root(graph, .Temporary, span, name)
	append(&graph.in_scope, Flow_Cleanup{kind = .Prov_Root, root = root, span = span})
	return root
}

// As `prov_plain_slice_local`, for a field or element of a local: an erased
// slice whose elements hold no borrows.
@(private = "file")
prov_plain_slice_place :: proc(graph: ^Flow_Graph, e: Expr) -> bool {
	if expr_base(e) == nil {
		return false
	}
	repr := prov_repr(graph, e)
	if repr.view_from != INVALID_TYPE || repr.erased_from == INVALID_TYPE {
		return false
	}
	if _, is_ident := e.(^Expr_Ident); is_ident {
		return false
	}
	c := graph.k.c
	if underlying_kind(c, repr.erased_from) != .Slice ||
	   type_carries_borrow(c, underlying_info(c, repr.erased_from).element).any {
		return false
	}
	_, _, place := prov_place_of(graph, e)
	return place
}

// What an erased place holds, read only, with the erasure hook suppressed.
@(private = "file")
prov_read_erased_place :: proc(graph: ^Flow_Graph, e: Expr) -> []int {
	prov_begin_conversion(graph, e, .Erasure)
	defer prov_end_conversion(graph)
	return prov_read_carrier(graph, e, true)
}

// The ordinary walk with the erasure hook suppressed.
@(private = "file")
walk_flow_expr_erased :: proc(graph: ^Flow_Graph, e: Expr) -> []int {
	prov_begin_conversion(graph, e, .Erasure)
	defer prov_end_conversion(graph)
	return walk_flow_expr(graph, e)
}

// ------------------------------------------------------------- regions --

@(private)
prov_empty_region :: proc(graph: ^Flow_Graph) -> Region_Set {
	return Region_Set{params = make([]bool, max(graph.param_count, 1), graph.alloc)}
}

// Region facts only grow, within a pass and from one pass to the next.
@(private)
prov_merge_region_of :: proc(graph: ^Flow_Graph, id: Symbol_Id, set: Region_Set) {
	if aliases := graph.region_aliases[id]; len(aliases) > 0 {
		sym := symbol_of(graph.k.c, id)
		for alias in aliases {
			prov_define_region_content(graph, alias.root, alias.path, set, handle = !type_is_managed(graph.k.c, sym.type))
		}
		if aliases[len(aliases) - 1].root != NO_ROOT { return }
	}
	existing, found := graph.region_of[id]
	if !found {
		existing = prov_empty_region(graph)
	}
	region_merge(&existing, set)
	graph.region_of[id] = existing
}

// Starts a pass from carried facts, copied so this pass's merges leave them
// alone and the round that produced them can be reclaimed.
@(private)
prov_seed_regions :: proc(graph: ^Flow_Graph, seed: ^Prov_Facts) {
	for id, set in seed.region_of {
		prov_merge_region_of(graph, id, set)
	}
	for id, set in seed.provider_parents {
		parent := graph.provider_parents[id] or_else prov_empty_region(graph)
		region_merge(&parent, set)
		graph.provider_parents[id] = parent
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
			copied[index] = prov_clone_region_content(entry, prov_empty_region(graph), graph.alloc)
			region_merge(&copied[index].region, entry.region)
		}
		graph.region_content[id] = copied
	}
}

// A round's facts alone, deep-copied into `allocator` to seed the next round
// after this one's graph is reclaimed.
@(private)
prov_carry_facts :: proc(graph: ^Flow_Graph, allocator: mem.Allocator) -> ^Prov_Facts {
	carry := new(Prov_Facts, allocator)
	copied_region :: proc(set: Region_Set, params: int, allocator: mem.Allocator) -> Region_Set {
		out := Region_Set{params = make([]bool, max(params, 1), allocator)}
		region_merge(&out, set)
		return out
	}
	carry.region_of = make(map[Symbol_Id]Region_Set, len(graph.region_of), allocator)
	for id, set in graph.region_of { carry.region_of[id] = copied_region(set, graph.param_count, allocator) }
	carry.provider_parents = make(map[Symbol_Id]Region_Set, len(graph.provider_parents), allocator)
	for id, set in graph.provider_parents { carry.provider_parents[id] = copied_region(set, graph.param_count, allocator) }
	carry.lent_locals = make(map[Symbol_Id]bool, len(graph.lent_locals), allocator)
	for id in graph.lent_locals { carry.lent_locals[id] = true }
	carry.written_aliases = make(map[Storage_Id][]Written_Alias, len(graph.written_aliases), allocator)
	for id, aliases in graph.written_aliases {
		copied := make([]Written_Alias, len(aliases), allocator)
		for alias, index in aliases {
			copied[index] = Written_Alias{target = alias.target, at = slice.clone(alias.at, allocator), path = slice.clone(alias.path, allocator)}
		}
		carry.written_aliases[id] = copied
	}
	carry.region_content = make(map[Storage_Id][]Prov_Region_Content, len(graph.region_content), allocator)
	for id, content in graph.region_content {
		copied := make([]Prov_Region_Content, len(content), allocator)
		for entry, index in content {
			copied[index] = prov_clone_region_content(entry, copied_region(entry.region, graph.param_count, allocator), allocator)
		}
		carry.region_content[id] = copied
	}
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
	for _, aliases in facts.written_aliases {
		weight += len(aliases)
	}
	return weight + len(facts.lent_locals)
}

@(private = "file")
region_weight :: proc(set: Region_Set) -> int {
	weight := int(bits.count_ones(set.locals)) + int(set.default) + int(set.unknown) + int(set.crowded)
	for value in set.params {
		weight += int(value)
	}
	return weight
}

// Every region dependency of a symbol, including its field facts. A carrier's
// own entry is what it views, which only a read through it reaches.
@(private)
prov_region_for_symbol :: proc(graph: ^Flow_Graph, id: Symbol_Id, viewed := false, owners := false) -> Region_Set {
	out := prov_empty_region(graph)
	if aliases := graph.region_aliases[id]; len(aliases) > 0 {
		for alias in aliases {
			region_merge(&out, prov_region_content_at(graph, alias.root, alias.path, owners ? .Owners : .All))
		}
		if aliases[len(aliases) - 1].root != NO_ROOT { return out }
	}
	sym := symbol_of(graph.k.c, id)
	carrier := sym != nil && type_is_carrier(graph.k.c, sym.type) && !type_is_region_provider(graph.k.c, sym.type) && type_underlying(graph.k.c, sym.type) != TYPE_ALLOCATOR
	if direct, found := graph.region_of[id]; found && (viewed || !carrier) {
		region_merge(&out, direct)
	}
	for content in graph.region_content[prov_storage_id(graph, Written_Storage{symbol = id})] {
		// `owners` asks only what backs an owner stored there.
		if !owners || !content.handle {
			region_merge(&out, content.region)
		}
	}
	if viewed {
		for alias in prov_written_aliases_of(graph, prov_storage_id(graph, Written_Storage{symbol = id}), nil) {
			region_merge(&out, prov_region_content_at(graph, prov_root_for_storage(graph, alias.target), alias.at,
			                                        owners ? .Owners : .All))
		}
	}
	return out
}

// What a body leaves in a writable parameter by path below what the argument
// names: the region `prov_region_for_symbol` joins, kept apart by field. A
// direct fact and a borrowed binding's aliases reach the whole argument. What
// the argument already was, and the body's own regions, say nothing new.
// Field entries are the body's writes, so one that copies from the argument
// keeps its dependency: by path where the copy named the field it read
// (`Prov_Region_Content.from`), otherwise for the whole argument.
@(private)
prov_written_parameter_content :: proc(graph: ^Flow_Graph, id: Symbol_Id, index: int) -> []Prov_Region_Content {
	out := make([dynamic]Prov_Region_Content, graph.alloc)
	add :: proc(out: ^[dynamic]Prov_Region_Content, index: int, content: Prov_Region_Content, written := false) {
		content := content
		content.region.locals, content.region.crowded = 0, false
		if !written && index < len(content.region.params) { content.region.params[index] = false }
		if content.from != nil || !region_is_empty(content.region) { append(out, content) }
	}
	whole, owned := prov_empty_region(graph), prov_empty_region(graph)
	if aliases := graph.region_aliases[id]; len(aliases) > 0 {
		for alias in aliases {
			region_merge(&whole, prov_region_content_at(graph, alias.root, alias.path, .All))
			region_merge(&owned, prov_region_content_at(graph, alias.root, alias.path, .Owners))
		}
	}
	if len(graph.region_aliases[id]) == 0 || graph.region_aliases[id][len(graph.region_aliases[id]) - 1].root == NO_ROOT {
		sym := symbol_of(graph.k.c, id)
		carrier := sym != nil && type_is_carrier(graph.k.c, sym.type) && !type_is_region_provider(graph.k.c, sym.type) && type_underlying(graph.k.c, sym.type) != TYPE_ALLOCATOR
		if direct, found := graph.region_of[id]; found && !carrier {
			region_merge(&whole, direct)
			region_merge(&owned, direct)
		}
		for content in graph.region_content[prov_storage_id(graph, Written_Storage{symbol = id})] {
			copied := content
			copied.region = prov_empty_region(graph)
			region_merge(&copied.region, content.region)
			add(&out, index, copied, written = true)
		}
	}
	add(&out, index, Prov_Region_Content{region = owned})
	add(&out, index, Prov_Region_Content{region = whole, handle = true})
	return out[:]
}

// The region dependencies at one path; a whole-value fact reaches every path.
@(private = "file")
prov_region_content_at :: proc(graph: ^Flow_Graph, root: Root_Id, path: []Proj_Step, query := Region_Query.All) -> Region_Set {
	out := prov_empty_region(graph)
	if root == NO_ROOT {
		return out
	}
	id := graph.roots[int(root)].symbol
	storage := prov_storage_for_root(graph, root)
	if aliases := graph.region_aliases[id]; len(aliases) > 0 {
		for alias in aliases {
			region_merge(&out, prov_region_content_at(graph, alias.root, prov_concat_path(graph, alias.path, path), query))
		}
		if aliases[len(aliases) - 1].root != NO_ROOT { return out }
	}
	reads := graph.self_reads
	if reads != nil && reads.symbol != id { reads = nil }
	if direct, found := graph.region_of[id]; found && reads == nil {
		region_merge(&out, direct)
	} else if found {
		// The parameter's own region here is what the argument held at `path`.
		rest := prov_empty_region(graph)
		region_merge(&rest, direct)
		if reads.index < len(rest.params) { rest.params[reads.index] = false }
		region_merge(&out, rest)
		append(&reads.sources, Prov_Region_Source{slice.clone(path, graph.alloc), query})
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
// the copy. The wider query keeps both reads' regions.
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
	if recorded { prov_effect_begin(graph, Prov_Effect_Define{prov_storage_for_root(graph, root), prov_effect_path(graph, path), prov_effect_value(graph, value), prov_effect_path(graph, source), copies, allocated_by}) }
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
		owned := field.handle ? prov_empty_region(graph) : region
		prov_define_stored_content(graph, root, at, region, owned, own = field.own)
		prov_define_copied_content(graph, root, copied)
	}
}

// Starts listing the reads of the writable parameter `root` names, so a store
// into it can say which of the argument's own fields it copied. Nil for any
// other root.
@(private = "file")
prov_self_reads_begin :: proc(graph: ^Flow_Graph, root: Root_Id) -> ^Prov_Self_Reads {
	if root == NO_ROOT || graph.self_reads != nil || graph.literal.signature == nil { return nil }
	// A pointer parameter's storage is the pointee's, which is not a `.Param` root.
	id := graph.roots[int(root)].symbol
	sym := symbol_of(graph.k.c, id)
	if sym == nil || sym.kind != .Parameter || !param_writes_caller(graph.k.c, sym) { return nil }
	index := 0
	for parameter in graph.literal.signature.params {
		for symbol in parameter.symbols {
			if symbol == id {
				graph.self_reads = new_clone(Prov_Self_Reads{symbol = id, index = index, sources = make([dynamic]Prov_Region_Source, graph.alloc)}, graph.alloc)
				return graph.self_reads
			}
			index += 1
		}
	}
	return nil
}

@(private = "file")
prov_self_reads_end :: proc(graph: ^Flow_Graph, reads: ^Prov_Self_Reads) {
	if reads != nil { graph.self_reads = nil }
}

// The copies at `path` that `region`, read since the last call, made from the
// parameter's own fields. None when its own region reached `region` some other
// way: that dependency then stands for the whole argument.
@(private = "file")
prov_take_self_sources :: proc(graph: ^Flow_Graph, reads: ^Prov_Self_Reads, region: Region_Set, path: []Proj_Step, handle := false, own := false) -> []Prov_Region_Content {
	if reads == nil { return nil }
	defer clear(&reads.sources)
	if len(reads.sources) == 0 || reads.index < len(region.params) && region.params[reads.index] { return nil }
	out := make([]Prov_Region_Content, len(reads.sources), graph.alloc)
	for source, index in reads.sources {
		out[index] = Prov_Region_Content{path = path, region = prov_empty_region(graph), handle = handle, own = own, from = source}
	}
	return out
}

// A stored copy allocates in its destination's allocator before widening
// remaps the payload tag (design.md "Widening by label").
@(private = "file")
prov_stored_region_at :: proc(graph: ^Flow_Graph, value: Value_Id, path: []Proj_Step, query: Region_Query, copies: bool, allocator: Region_Set, as_type := INVALID_TYPE, copy_from: []Proj_Step = nil) -> Region_Set {
	if !copies { return prov_result_region_at(graph, value, path, query, as_type) }
	component := prov_input_stored_copy(graph, value, path, copy_from, as_type)
	if component.source == 0 { return prov_empty_region(graph) }
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
}

// Records a managed value stored at a path. Flow-insensitive, so writes merge.
@(private = "file")
prov_define_region_content :: proc(
	graph: ^Flow_Graph,
	root: Root_Id,
	path: []Proj_Step,
	region: Region_Set,
	handle := false,
	own := false,
) {
	if root == NO_ROOT || region_is_empty(region) {
		return
	}
	id := graph.roots[int(root)].symbol
	storage := prov_storage_for_root(graph, root)
	if storage == 0 {
		return
	}
	if aliases := graph.region_aliases[id]; len(aliases) > 0 {
		for alias in aliases {
			prov_define_region_content(graph, alias.root, prov_concat_path(graph, alias.path, path), region, handle, own)
		}
		if aliases[len(aliases) - 1].root != NO_ROOT { return }
	}
	// A handle's entry stays apart from an owner's at the same path, so what
	// backs an owner is still told from it (design.md "Allocator regions and
	// region provenance").
	content := graph.region_content[storage]
	for &entry in content {
		if entry.from == nil && entry.handle == handle && entry.own == own && len(entry.path) == len(path) && path_has_exact_prefix(entry.path, path) {
			region_merge(&entry.region, region)
			graph.region_content[storage] = content
			return
		}
	}
	stored_path := make([]Proj_Step, len(path), graph.alloc)
	copy(stored_path, path)
	grown := make([dynamic]Prov_Region_Content, len(content), len(content) + 1, graph.alloc)
	copy(grown[:], content)
	append(&grown, Prov_Region_Content{path = stored_path, region = region, handle = handle, own = own})
	graph.region_content[storage] = grown[:]
}

// Records a stored value's regions at a path: `owned`, the part backing an
// owner, as an owner's entry, and the rest as an allocator handle's.
@(private = "file")
prov_define_stored_content :: proc(graph: ^Flow_Graph, root: Root_Id, path: []Proj_Step, region, owned: Region_Set, own := false) {
	prov_define_region_content(graph, root, path, owned, own = own)
	handles := prov_empty_region(graph)
	region_merge(&handles, owned)
	if merge_region_provenance(&handles, region) {
		prov_define_region_content(graph, root, path, region, handle = true, own = own)
	}
}

// One provider position in a local: a field path its type fixes, or the path
// of a container, union, or array whose providers share one token.
Provider_Path :: struct {
	key: []Proj_Step,
	bit: u64,
}

// Every token of one local. Past 64 tokens the set is `crowded`, meaning "may
// be any of them".
@(private)
prov_provider_region :: proc(graph: ^Flow_Graph, id: Symbol_Id) -> Region_Set {
	out := prov_empty_region(graph)
	if !prov_provider_tokens(graph, id) {
		out.crowded = true
		return out
	}
	out.locals = graph.provider_bits[id]
	return out
}

// The tokens of the providers at or under `path` in a local, or containing it,
// and of any provider moved in.
@(private)
prov_provider_region_at :: proc(graph: ^Flow_Graph, id: Symbol_Id, path: []Proj_Step) -> Region_Set {
	out := prov_empty_region(graph)
	if !prov_provider_tokens(graph, id) {
		out.crowded = true
		return out
	}
	key := path
	for step, index in path {
		if step.kind != .Field {
			key = path[:index]
			break
		}
	}
	out.locals = graph.provider_moved[id]
	for position in graph.provider_paths[id] {
		if path_has_exact_prefix(position.key, key) || path_has_exact_prefix(key, position.key) {
			out.locals |= position.bit
		}
	}
	return out
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
	if len(graph.provider_symbols) + len(positions) > 64 {
		return false
	}
	bits := graph.provider_moved[id]
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
	if type_is_region_provider(c, type) || info == nil || info.kind != .Struct || depth >= CARRIER_DEPTH {
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

// The provider tokens a value moved out of locals carries, through composite
// literals, `exchange`, and `box`, or 0.
@(private = "file")
prov_moved_bits :: proc(graph: ^Flow_Graph, id: Value_Id) -> u64 {
	source: Value_Id
	#partial switch form in prov_value(graph, id).form {
	case Prov_Form_Move:
		source = form.operand
	case Prov_Form_Call:
		v, bound := form.call, prov_bound_values(form)
		if sym := symbol_of(graph.k.c, v.resolution.symbol); sym != nil && sym.builtin == .Exchange && len(bound) == 2 {
			source = bound[0]
		} else if boxed_payload(graph.k.c, v) != nil {
			return prov_moved_bits(graph, bound[0])
		}
	case Prov_Form_Composite:
		bits: u64
		for element in form.elements {
			if element != 0 {
				bits |= prov_moved_bits(graph, element)
			}
		}
		return bits
	}
	if source != 0 {
		if root, _, ok := prov_value_place_of(graph, source); ok && graph.roots[int(root)].kind == .Local {
			return graph.provider_bits[graph.roots[int(root)].symbol]
		}
	}
	return 0
}

// A provider moved into a local's existing storage joins that local's tokens.
@(private)
prov_merge_moved_bits :: proc(graph: ^Flow_Graph, root: Symbol_Id, value: Value_Id) {
	recorded := prov_effect_active(graph)
	if recorded { prov_effect_begin(graph, Prov_Effect_Move_Provider{root, prov_effect_value(graph, value)}) }
	defer prov_effect_end(graph, recorded)
	bits := prov_moved_bits(graph, value)
	if bits == 0 {
		return
	}
	existing := prov_provider_region(graph, root)
	if existing.crowded {
		return // already "may be any of them"
	}
	graph.provider_moved[root] |= bits
	graph.provider_bits[root] = existing.locals | bits
	if set, found := graph.region_of[root]; found && type_is_region_provider(graph.k.c, symbol_of(graph.k.c, root).type) {
		set.locals |= bits
		graph.region_of[root] = set
	}
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
@(private = "file")
prov_type_or_wrapped :: proc(
	c: ^Compiler,
	type: Type_Id,
	leaf: proc(c: ^Compiler, type: Type_Id) -> bool,
	depth := 0,
) -> bool {
	if type == INVALID_TYPE || depth > 8 {
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

// Whether a value of `type` can depend on an allocator region: somewhere in it
// is an owner, a view, an `Allocator`, or a provider (design.md "Allocator
// regions and region provenance"). An `int` read out of a region-backed
// container has no region.
@(private)
prov_type_has_region :: proc(c: ^Compiler, type: Type_Id, depth := 0) -> bool {
	if depth > 8 {
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
	if base := expr_base(e); base.is_const && base.const_value.kind == .Nil && type_underlying(c, value.type) == TYPE_ALLOCATOR {
		set := prov_empty_region(graph)
		set.default = true
		return set
	}
	if transfer := prov_value_transfer(graph, id); transfer != nil {
		return prov_transfer_region(graph, transfer, nil, .All)
	}
	#partial switch form in value.form {
	case Prov_Form_Symbol:
		return prov_symbol_region(graph, form.symbol, value.type)
	case Prov_Form_Error:
		return prov_error_region_at(graph, form, nil, .All)
	case Prov_Form_Selector, Prov_Form_Index:
		if call := prov_operator_value(graph, id); call != 0 {
			return prov_result_region(graph, call)
		}
		if root, path, ok := prov_value_place_of(graph, id); ok {
			set := prov_region_content_at(graph, root, path)
			// An allocator no write named, such as one in a received record's
			// field, is one the analysis cannot name.
			if region_is_empty(set) && type_underlying(c, value.type) == TYPE_ALLOCATOR {
				set.unknown = true
			}
			return set
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
		if sym := symbol_of(c, v.resolution.symbol); sym != nil && sym.builtin == .Default_Allocator {
			set := prov_empty_region(graph)
			set.default = true
			return set
		}
		// `arena.allocator()` names the provider's own region.
		if set, ok := prov_handle_region(graph, v, prov_receiver_value(form.arguments)); ok {
			return set
		}
		if result, found := graph.call_results[v]; found {
			return result.region
		}
		return prov_call_region(graph, id, value.type)
	}
	if prov_carries_allocator(c, value.type) {
		set := prov_empty_region(graph)
		set.unknown = true
		return set
	}
	return Region_Set{}
}

// design.md "Allocator regions and region provenance": a copy of a managed
// value shares its source's allocation, since a copy that allocates is written
// as a clone, so it keeps the source's region. What a carrier views is backed
// by the regions of the owners it was taken from: a view or pointer local takes
// them from each value it is given, and a carrier parameter from its argument.
@(private)
prov_storage_region :: proc(graph: ^Flow_Graph, id: Value_Id) -> Region_Set {
	c := graph.k.c
	type := prov_value(graph, id).type
	if id != 0 && type_underlying(c, type) == TYPE_ALLOCATOR {
		return prov_region_of(graph, id)
	}
	if id != 0 && type_is_carrier(c, type) && !type_is_region_provider(c, type) {
		return prov_viewed_region(graph, id)
	}
	return prov_region_of(graph, id)
}

@(private = "file")
prov_viewed_region :: proc(graph: ^Flow_Graph, id: Value_Id) -> Region_Set {
	#partial switch form in prov_value(graph, id).form {
	case Prov_Form_Symbol:
		return prov_region_for_symbol(graph, form.symbol, viewed = true)
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
	}
	return Region_Set{}
}

// A value read out through a carrier (`view[0]`, `p.field`, `p^`) is in what
// the carrier views; a part of a value is in that value's regions.
// Known targets retain field precision, including anonymous backing arrays.
@(private = "file")
prov_read_storage_regions :: proc(graph: ^Flow_Graph, id: Value_Id, path: []Proj_Step, query: Region_Query) -> (Region_Set, bool) {
	out := prov_empty_region(graph)
	carrier := prov_place_carrier(graph, id)
	if carrier == 0 { return out, false }
	aliases := prov_written_aliases_at(graph, carrier)
	known := len(aliases) > 0
	below := prov_concat_path(graph, prov_path_below_carrier(graph, id), path)
	for alias in aliases {
		if alias.target == 0 { known = false; continue }
		region_merge(&out, prov_region_content_at(graph, prov_root_for_storage(graph, alias.target),
		                                        prov_concat_path(graph, alias.at, below), query))
	}
	return out, known
}

@(private = "file")
prov_read_region :: proc(graph: ^Flow_Graph, id: Value_Id) -> Region_Set {
	out, known := prov_read_storage_regions(graph, id, nil, .All)
	if known { return out }
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
	return out
}

// A loop element is in the storage of what the loop iterates.
@(private)
prov_bind_element_region :: proc(graph: ^Flow_Graph, id: Symbol_Id, iterable: Value_Id) {
	recorded := prov_effect_active(graph) && prov_effect_symbol_relevant(graph, id)
	if recorded { prov_effect_begin(graph, Prov_Effect_Element{id, prov_effect_value(graph, iterable)}) }
	defer prov_effect_end(graph, recorded)
	sym := symbol_of(graph.k.c, id)
	if sym == nil || !(type_is_managed(graph.k.c, sym.type) || type_is_carrier(graph.k.c, sym.type)) {
		return
	}
	if set := prov_storage_region(graph, iterable); !region_is_empty(set) {
		prov_merge_region_of(graph, id, set)
	}
}

// The region an `arena.allocator()` names; unknown unless the receiver is a
// named provider.
@(private)
prov_handle_region :: proc(graph: ^Flow_Graph, v: ^Expr_Call, receiver: Value_Id) -> (Region_Set, bool) {
	if call_provider_op(graph.k.c, v) != .Handle || len(v.bound) == 0 {
		return Region_Set{}, false
	}
	receiver := prov_value(graph, receiver)
	ident, is_ident := receiver.form.(Prov_Form_Symbol)
	if !is_ident && receiver.temporary {
		return prov_temp_provider_region(graph, v), true
	}
	if !is_ident {
		// A provider inside a local record or container: the token of its position.
		if root, path, ok := prov_root_place(graph, receiver.place); ok {
			if descriptor := graph.roots[int(root)]; descriptor.kind == .Local && descriptor.symbol != INVALID_SYMBOL {
				return prov_provider_region_at(graph, descriptor.symbol, path), true
			}
		}
		set := prov_empty_region(graph)
		set.unknown = true
		return set, true
	}
	if set, found := graph.region_of[ident.symbol]; found {
		return set, true
	}
	set := prov_empty_region(graph)
	set.unknown = true
	return set, true
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
	set := prov_empty_region(graph)
	bit, found := graph.temp_provider_bits[v]
	if !found {
		if len(graph.provider_symbols) >= 64 {
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

// The end of a temporary provider's statement ends its region.
@(private)
prov_temp_provider_end :: proc(graph: ^Flow_Graph, provider: Temp_Provider, live: Reset_Liveness) {
	set := prov_empty_region(graph)
	set.locals = provider.bit
	prov_reset(graph, set, provider.span, true, nil, live, ends = "this temporary allocator, which ends with its statement,", provider_end = true)
}

// Exact constructor facts: backing storage is separate from payload fields,
// and a fallible result keeps each variant under its own field step.
@(private = "file")
prov_constructed_region_at :: proc(graph: ^Flow_Graph, id: Value_Id, path: []Proj_Step, query: Region_Query) -> (Region_Set, bool) {
	c := graph.k.c
	out := prov_empty_region(graph)
	value := prov_value(graph, id)
	form := value.form.(Prov_Form_Call)
	v, bound := form.call, prov_bound_values(form)
	payload, fallible := shared_constructor_payload(c, v)
	shared_copy := prov_receiver_is_shared_handle(graph, v) && len(bound) > 0 &&
	               prov_type_or_wrapped(c, value.type, type_is_shared_handle)
	if payload == nil && !shared_copy { return out, false }
	path := path
	if shape, ok := fallible_of(graph.k, value.type); ok && (fallible || shared_copy) {
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

// The region of a call result: a direct summary substituted by position, or
// conservative input dependencies when no body is available.
@(private)
prov_call_region :: proc(graph: ^Flow_Graph, id: Value_Id, result_type: Type_Id) -> Region_Set {
	c := graph.k.c
	out := prov_empty_region(graph)
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
	if prov_receiver_is_shared_handle(graph, v) && len(bound) > 0 &&
	   prov_type_or_wrapped(c, result_type, type_is_shared_handle) {
		return prov_storage_region(graph, bound[0])
	}
	// design.md "string type conversions": these copy into the default allocator.
	if operation, conversion := v.operation.(Call_Text_Conversion); conversion &&
	   (operation.op == .String_From_Bytes || operation.op == .String_From_C_View) {
		out.default = true
		return out
	}
	if _, extraction := v.operation.(Call_Extract); extraction && type_is_managed(c, result_type) {
		out.default = true
		return out
	}
	if sym := symbol_of(c, v.resolution.symbol); sym != nil && sym.builtin == .Default_Allocator {
		out.default = true
		return out
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
	prov_note_summary_dependency(graph, callee, direct)
	if summary, found := result_summary(c, callee); found {
		region_merge(&out, prov_substitute_region(graph, bound, summary.region))
	}
	info := underlying_info(c, call_proc_type(c, v))
	for argument, index in bound {
		if argument == 0 {
			continue
		}
		if type_underlying(c, prov_value(graph, argument).type) == TYPE_ALLOCATOR && !direct {
			// design.md "Allocator regions and region provenance": without a body
			// to follow, an owner built with an allocator argument takes its
			// region. A direct call's summary already names the allocators its
			// result is built with, so one the body never uses backs nothing.
			region_merge(&out, prov_region_of(graph, argument))
			continue
		}
		if !direct && info != nil && index < len(info.param_modes) && info.param_modes[index] == .Move {
			region_merge(&out, prov_region_of(graph, argument))
		} else if !direct && prov_type_shares_region(c, result_type) {
			// A procedure value has no result summary. Logical copies may retain
			// borrowed inputs, even when a destination allocator is also supplied.
			region_merge(&out, prov_storage_region(graph, argument))
		}
	}
	if !direct && region_is_empty(out) {
		out.unknown = true
	}
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
// operands name. Copied declarations and assignments, implicit variant
// copies, and copied error payloads use the same rule through
// `prov_copied_region_at`.
@(private = "file")
prov_clone_region_at :: proc(graph: ^Flow_Graph, bound: []Value_Id, type: Type_Id, path: []Proj_Step, query := Region_Query.All) -> Region_Set {
	return prov_copied_region_at(graph, Prov_Region_Copy{value = bound[0], allocator = prov_allocation_region(graph, bound)}, type, path, query)
}

// The regions at `path` of a copy of `source` as `type`. Newly allocated
// storage is in the copy's allocator, while logical copies keep the source's
// regions, read at the projected source prefix. Destructuring starts at the
// field type (`Destructure.clones`); only the source query prepends the
// containing record's path. A widened destination path is remapped to the
// source type before the query. Custom copy hooks, including hooks nested in
// generated copies, substitute their result summaries. Shared and weak
// handles keep the control block's allocator apart from the payload's
// regions through copies, downgrades, and upgrades.
@(private)
prov_copied_region_at :: proc(graph: ^Flow_Graph, source: Prov_Region_Copy, type: Type_Id, path: []Proj_Step, query := Region_Query.All) -> Region_Set {
	type := type
	for step, index in path {
		if type_is_shared_handle(graph.k.c, type) {
			return prov_copy_source_region_at(graph, source, path, query)
		}
		if operation := prov_input_copy_operation(graph, type); operation.hook != INVALID_SYMBOL {
			return prov_copy_hook_region(graph, source, operation, path[:index], path[index:], query)
		}
		type = prov_type_at(graph.k.c, type, {step})
	}
	return prov_copied_type_region(graph, source, type, path, query)
}

@(private = "file")
prov_allocation_region :: proc(graph: ^Flow_Graph, bound: []Value_Id, allocator_index := 1) -> Region_Set {
	if len(bound) > allocator_index && bound[allocator_index] != 0 { return prov_region_of(graph, bound[allocator_index]) }
	out := prov_empty_region(graph)
	out.default = true
	return out
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

@(private = "file")
prov_copy_hook_region :: proc(graph: ^Flow_Graph, source: Prov_Region_Copy, operation: Prov_Copy_Operation, prefix, path: []Proj_Step, query: Region_Query) -> Region_Set {
	c := graph.k.c
	prov_note_summary_dependency(graph, operation.hook, prov_has_direct_body(c, operation.hook))
	summary, found := result_summary(c, operation.hook)
	out := prov_empty_region(graph)
	if !found {
		region_merge(&out, prov_copy_source_region_at(graph, source, prefix))
		region_merge(&out, source.allocator)
		return out
	}
	set := summary.region
	if len(path) > 0 || query != .All {
		projected_path := path
		if shape, ok := fallible_of(graph.k, summary.content_type); ok {
			projected_path = prov_concat_path(graph, {proj_field(shape.success)}, path)
		}
		projected := Region_Set{params = make([]bool, len(set.params), graph.alloc)}
		matched := false
		for content in summary.region_content {
			if query == .Own && (!content.own || !prov_same_path(content.path, projected_path)) { continue }
			if content.own && len(content.path) < len(projected_path) { continue }
			if paths_overlap(content.path, projected_path) {
				matched = true
				region_merge(&projected, content.region)
			}
		}
		if matched { set = projected }
	}
	for wanted, index in set.params {
		if !wanted { continue }
		if index == 0 { region_merge(&out, prov_copy_source_region_at(graph, source, prefix)) }
		if index == 1 { region_merge(&out, source.allocator) }
	}
	out.default ||= set.default
	out.unknown ||= set.unknown
	return out
}

@(private = "file")
prov_copied_type_region :: proc(graph: ^Flow_Graph, source: Prov_Region_Copy, type: Type_Id, path: []Proj_Step, query: Region_Query, depth := 0) -> Region_Set {
	c := graph.k.c
	out := prov_empty_region(graph)
	if !prov_type_has_region(c, type) { return out }
	if depth > 8 {
		region_merge(&out, prov_copy_source_region_at(graph, source, path))
		region_merge(&out, source.allocator)
		return out
	}
	if type_underlying(c, type) == TYPE_STRING || type_underlying(c, type) == TYPE_ALLOCATOR || type_is_shared_handle(c, type) || type_is_carrier(c, type) {
		return prov_copy_source_region_at(graph, source, path, query)
	}
	if operation := prov_input_copy_operation(graph, type); operation.hook != INVALID_SYMBOL {
		return prov_copy_hook_region(graph, source, operation, path, nil, query)
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

@(private = "file")
prov_substitute_region :: proc(graph: ^Flow_Graph, bound: []Value_Id, summary: Region_Set) -> Region_Set {
	out := prov_empty_region(graph)
	for wanted, index in summary.params {
		if wanted && index < len(bound) && bound[index] != 0 {
			region_merge(&out, prov_storage_region(graph, bound[index]))
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
		path := make([]Proj_Step, len(content.path), graph.alloc)
		copy(path, content.path)
		out[index] = Prov_Region_Content {
			path = path,
			region = prov_substitute_region(graph, prov_bound_values(form), content.region),
			handle = content.handle,
			own = content.own,
		}
	}
	return out
}

// Whether every allocator parameter the set names carries the reset promise,
// or the name of one that does not.
@(private = "file")
prov_reset_promise :: proc(graph: ^Flow_Graph, set: Region_Set) -> (covered: bool, name: string) {
	for wanted, index in set.params {
		if !wanted {
			continue
		}
		sym := prov_parameter_symbol(graph, index)
		if sym == nil {
			continue
		}
		if !sym.allocator_reset {
			return false, identifier_text(graph.k.c, sym.name)
		}
		covered = true
	}
	// Every alternative that is not this body's own needs the promise; the
	// default or an unknown allocator, such as one extracted from an `any_view`,
	// never has it.
	if set.default || set.unknown {
		return false, ""
	}
	return covered, ""
}

@(private = "file")
prov_parameter_symbol :: proc(graph: ^Flow_Graph, index: int) -> ^Symbol {
	literal := graph.literal
	if literal == nil || literal.signature == nil {
		return nil
	}
	position := 0
	for parameter in literal.signature.params {
		for id in parameter.symbols {
			if position == index {
				return symbol_of(graph.k.c, id)
			}
			position += 1
		}
	}
	return nil
}

// A reset may end every allocation in its region (design.md): checked for its
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
		live, found = graph.k.c.reset_dead[Reset_Key{graph.literal, at, INVALID_SYMBOL, graph.expansion}]
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
	if graph.unwinding { op.unwind_from = graph.unwind_at }
	if graph.returning != nil { op.returning = graph.returning^ }
	prov_event(graph, op)
}

// What a recorded reset ends, from the facts at hand.
@(private)
prov_materialize_reset :: proc(graph: ^Flow_Graph, op: Prov_Event_Reset) {
	set: Region_Set
	switch region in op.region {
	case Region_Set:
		set = region
	case Value_Id:
		set = prov_region_of(graph, region)
	case Prov_Reset_Indirect:
		// Only a provider something was lent can be reached through a pointer.
		set = prov_empty_region(graph)
		for id in region.owners {
			if graph.lent_locals[id] { region_merge(&set, prov_provider_region(graph, id)) }
		}
		if region_is_empty(set) { return }
	}
	// A region the analysis cannot name, such as an allocator in a received
	// record's field, is pre-existing: it stays uncovered.
	covered, unmarked := prov_reset_promise(graph, set)
	// A locally created region needs no promise (design.md).
	if region_is_local_only(set) {
		covered, unmarked = true, ""
	}
	event := Prov_Event {
		kind          = .Reset,
		span          = op.span,
		access        = op.direct ? .Invalidate : .Write,
		name          = unmarked,
		region        = set,
		reset_covered = unmarked == "" && covered,
		ends          = op.ends,
		provider_end  = op.provider_end,
		unwind_from   = op.unwind_from,
	}
	// A live owner in an overlapping region blocks the reset, since its cleanup
	// still runs; a dropped owner no longer blocks (design.md).
	for id in op.live.owners {
		owner := symbol_of(graph.k.c, id)
		if owner == nil {
			continue
		}
		// The local being ended is what ends the region, not a dependant of it.
		if id == op.ending {
			continue
		}
		if type_is_region_provider(graph.k.c, owner.type) {
			// A live child provider depends on its parent's region.
			parent, found := graph.provider_parents[id]
			if found && regions_may_overlap(parent, set) {
				event.verb = identifier_text(graph.k.c, owner.name)
				event.owner_span = owner.span
				break
			}
			continue
		}
		owner_region := prov_region_for_symbol(graph, id)
		if !op.provider_end {
			owner_region = prov_reset_symbol_region(graph, id, owner.type)
		}
		if region_is_empty(owner_region) {
			continue
		}
		if !regions_may_overlap(owner_region, set) {
			continue
		}
		event.verb = identifier_text(graph.k.c, owner.name)
		event.owner_span = owner.span
		break
	}
	// Evaluated operands remain live while later operands run.
	if event.verb == "" {
		for held in op.held {
			region := op.provider_end ? prov_result_region(graph, held) : prov_reset_value_region(graph, held)
			if !region_is_empty(region) && regions_may_overlap(region, set) {
				event.verb = "this temporary"
				event.owner_span = expr_span(prov_value(graph, held).origin)
				break
			}
		}
	}
	if event.verb == "" {
		for root in op.temporaries {
			if prov_reset_temporary(graph, root, &event) { break }
		}
	}
	// design.md "Allocators": a result reaches the caller before the deferred
	// statements run, so it is live across a reset among them.
	if returning, held := op.returning.?; held && event.verb == "" && !op.provider_end {
		if regions_may_overlap(prov_returning_region(graph, returning), set) {
			event.ends_result = true
			event.owner_span = returning.span
		}
	}
	prov_emit(graph, event)
}

// design.md "Temporaries and procedure boundaries": a converted view still
// lends from its managed temporary until that root's actual cleanup boundary.
@(private = "file")
prov_reset_temporary :: proc(graph: ^Flow_Graph, root: Root_Id, event: ^Prov_Event) -> bool {
	temporary := graph.roots[int(root)]
	region := prov_empty_region(graph)
	if temporary.owner != nil {
		fields := prov_result_region_fields(graph, prov_input_value(graph, temporary.owner), temporary.dropped)
		if event.provider_end {
			for field in fields { region_merge(&region, field.region) }
		} else {
			region = prov_reset_fields_region(graph, temporary.dropped, fields)
		}
	}
	// Later writes into a temporary's backing storage are live until its
	// actual cleanup, just as its initial owners are (design.md
	// "Allocator regions and region provenance").
	if prov_storage(graph, temporary.storage).key.temporary != nil && type_is_managed(graph.k.c, prov_storage(graph, temporary.storage).type) {
		fields := graph.region_content[temporary.storage]
		if event.provider_end {
			for field in fields { region_merge(&region, field.region) }
		} else {
			region_merge(&region, prov_reset_fields_region(graph, prov_storage(graph, temporary.storage).type, fields))
		}
	}
	if region_is_empty(region) || !regions_may_overlap(region, event.region) { return false }
	event.verb, event.owner_span = temporary.name, temporary.span
	return true
}

// design.md "Evaluation order": an owned value already evaluated is live
// while later operands run, even when its named source has been moved.
@(private)
prov_hold_owner :: proc(graph: ^Flow_Graph, value: Expr) {
	if value != nil && type_is_managed(graph.k.c, prov_type(graph, value)) && !expression_is_borrowed_place(value) {
		append(&graph.held_owners, value)
	}
}

// A borrow stored where it outlives the statement, resolved as a place so fields,
// elements, and writes through an alias are all seen.
@(private = "file")
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
@(private = "file")
prov_retain_through_carrier :: proc(graph: ^Flow_Graph, place: Expr) -> []int {
	if carrier := prov_place_carrier(graph, prov_input_value(graph, place)); carrier != 0 {
		return prov_carrier_slots(graph, prov_value(graph, carrier).origin)
	}
	return nil
}

// The last carrier crossed on the way to this place. Loading a carrier from
// that storage is a separate step from finding the storage itself.
@(private = "file")
prov_place_carrier :: proc(graph: ^Flow_Graph, place: Value_Id) -> Value_Id {
	carrier, _ := prov_value(graph, place).place.base.(Value_Id)
	return carrier
}

// The slots holding a carrier value, without reading it.
@(private = "file")
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
@(private = "file")
prov_region_escape :: proc(graph: ^Flow_Graph, target: Expr, value: Value_Id, source: []Proj_Step = nil, copies := false) {
	prov_event(graph, Prov_Event_Region_Escape{prov_input_value(graph, target), value, slice.clone(source, graph.alloc), copies, place_root_symbol(target)})
}

// Escape checks use the same copied fields as a store, without including facts
// from later assignments to the destination (design.md "Allocator regions and region provenance").
@(private)
prov_copied_owner_region :: proc(graph: ^Flow_Graph, value: Value_Id, source: []Proj_Step, copies: bool, allocator: Region_Set) -> Region_Set {
	owned := prov_empty_region(graph)
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
	current := type
	for step in path {
		if payload := shared_payload_type(c, current); payload != INVALID_TYPE && step.kind == .Wild {
			current = payload
			continue
		}
		info := underlying_info(c, current)
		if info == nil {
			return current
		}
		#partial switch info.kind {
		case .Struct:
			if step.kind != .Field || step.lo < 0 || int(step.lo) >= len(info.fields) {
				return current
			}
			field := symbol_of(c, info.fields[int(step.lo)])
			if field == nil {
				return current
			}
			current = field.type
		case .Union:
			if step.kind != .Field || step.lo < 0 || int(step.lo) >= len(info.variants) { return current }
			current = info.variants[int(step.lo)]
		case .Map:
			if step.kind == .Field {
				current = step.lo == PROJ_MAP_KEY ? info.key : info.element
			} else if step.kind != .Range && step.kind != .Wild { return current }
		case .Array, .Dynamic_Array, .Slice, .Box:
			if step.kind != .Range && step.kind != .Wild {
				return current
			}
			current = info.element
		case:
			return current
		}
	}
	return current
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
	case sym.duration == .Thread_Local: storage = "`thread_local` storage"
	case sym.duration == .Static:       storage = "`static` storage"
	case sym.decl != nil && sym.decl.top_level: storage = "file-scope storage"
	case param:                         storage = "storage the caller owns"
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
@(private = "file")
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
	if recorded { prov_effect_begin(graph, Prov_Effect_Store{prov_effect_value(graph, destination), prov_effect_value(graph, value), element}) }
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
	copied_owners := prov_take_self_sources(graph, reads, owned, at)
	prov_self_reads_end(graph, reads)
	prov_store_region_set(graph, destination, region, owned, prov_owner_name(graph, prov_value(graph, value).origin), element)
	prov_define_copied_content(graph, root, copied)
	prov_define_copied_content(graph, root, copied_owners)
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
	if region_is_empty(region) {
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
		prov_define_stored_content(graph, root, at, content.region, content.handle ? prov_empty_region(graph) : content.region, own = content.own)
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
	prov_define_stored_content(graph, root, at, region, handle ? prov_empty_region(graph) : region, own = own)
	prov_define_copied_content(graph, root, copied)
}

// Records copies within a writable parameter (`Prov_Region_Content.from`).
// Flow-insensitive, as other content is.
@(private = "file")
prov_define_copied_content :: proc(graph: ^Flow_Graph, root: Root_Id, contents: []Prov_Region_Content) {
	storage := prov_storage_for_root(graph, root)
	if storage == 0 { return }
	next: for content in contents {
		existing := graph.region_content[storage]
		for entry in existing {
			if prov_same_region_content(entry, content) { continue next }
		}
		grown := make([]Prov_Region_Content, len(existing) + 1, graph.alloc)
		copy(grown, existing)
		grown[len(existing)] = prov_clone_region_content(content, prov_empty_region(graph), graph.alloc)
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

// An owner written through the carriers `destination` reaches, into storage
// this body cannot name.
@(private)
prov_store_region_through :: proc(graph: ^Flow_Graph, destination: Value_Id, region: Region_Set, owned: Region_Set, owner: string, suffix: []Proj_Step = nil,
                                   contents: []Prov_Region_Content = nil) {
	if region_is_empty(region) {
		return
	}
	destination_type := prov_value(graph, destination).type
	span := expr_span(prov_value(graph, destination).origin)
	// A write through a parameter's carrier, or a local one set from it, is
	// what the caller learns of; one through a local set from `&mut place` lands
	// in that place, which a later reset then sees. A file-scope, `static`, or
	// `thread_local` place outlives a received region, so an owner landing there
	// is rejected as a store by name into it is: only where an owner is stored,
	// and a call leaves owners through its carrier arguments.
	checked := !region_is_empty(owned) && (owner == CALL_LEFT_OWNER || type_is_managed(graph.k.c, destination_type))
	escaped := false
	seen := make([dynamic]Written_Alias_Visit, graph.alloc)
	// `dst^.alloc` lands in the `alloc` field of what `dst` points at.
	below := prov_concat_path(graph, prov_path_below_carrier(graph, destination), suffix)
	for alias in prov_written_targets(graph, destination) {
		at := prov_concat_path(graph, alias.at, below)
		prov_define_stored_contents(graph, prov_root_for_storage(graph, alias.target), at, region, owned, contents)
		if owner == CALL_LEFT_OWNER && prov_type_reaches_mutable(graph.k.c, destination_type) {
			prov_store_reachable_regions(graph, alias.target, at, false, region, owned, &seen)
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
	// design.md "Allocator regions and region provenance": an allocator handle
	// is not an owner, so only the owners' regions are checked here; the handle
	// keeps its region in the stored content above.
	prov_region_escape_through(graph, span, owned, owner)
}

// An outer carrier, mutable or read-only, can reach writable carriers in its
// contents. Normalized addresses keep the descriptor and its contents separate,
// so a callee's aggregate write summary must follow those nested destinations.
@(private = "file")
prov_store_reachable_regions :: proc(graph: ^Flow_Graph, storage: Storage_Id, path: []Proj_Step,
                                      writable: bool, region, owned: Region_Set, seen: ^[dynamic]Written_Alias_Visit) {
	if storage == 0 { return }
	bounded := path[:min(len(path), WRITTEN_ALIAS_DEPTH)]
	for visit in seen^ {
		if visit.target == storage && visit.writable == writable && prov_same_path(visit.path, bounded) { return }
	}
	append(seen, Written_Alias_Visit{storage, bounded, writable})
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
@(private = "file")
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


@(private = "file")
prov_written_storage_type :: proc(graph: ^Flow_Graph, storage: Storage_Id) -> Type_Id {
	return prov_storage(graph, storage).type
}

// What a local's carriers may reach: a writable parameter's storage, or a
// variable's place, at `at` in it, that `&mut place` or `place[:]` lent. `path` is
// where in the local those carriers are held; nil when the whole local may
// hold them. A zero target is an unresolved alternative, not an empty set,
// and unknown or cyclic targets keep one beside any known ones. A target is
// the storage it names, not the targets of carriers inside that storage:
// alias reads load those separately (`prov_place_carrier`), so a pointer
// variable is never its own pointee. Reslicing a carrier forwards its
// targets; slicing owned storage records its address. `at` and `path` stop
// at WRITTEN_ALIAS_DEPTH and carry the precision marker, and a truncated
// projection joins the previous content.
Written_Alias :: struct {
	target: Storage_Id,
	at:     []Proj_Step,
	path:   []Proj_Step,
}

// Region field shapes also stop at eight projections. A recursive cursor can
// keep extending its target path across passes; retain a conservative prefix
// so that target facts converge (design.md "Minimum provenance precision").
WRITTEN_ALIAS_DEPTH :: 8

// The storage a write through `destination` may land in, as `p^`, `p.x`, or
// `p[i]` reach it: a parameter's, directly or through a local set from one,
// or a local place a local carrier was set to point at.
@(private)
prov_written_targets :: proc(graph: ^Flow_Graph, destination: Value_Id, as_place := false) -> []Written_Alias {
	carrier := destination
	value := prov_value(graph, destination)
	if as_place || !type_is_carrier(graph.k.c, value.type) {
		if through := prov_place_carrier(graph, destination); through != 0 {
			carrier = through
		} else if as_place && value.temporary && !type_is_carrier(graph.k.c, value.type) {
			storage := prov_storage_id(graph, Written_Storage{temporary = expr_base(value.origin), type = value.type})
			prov_note_alias_source(graph, storage, destination, nil)
			return slice.clone([]Written_Alias{{target = storage}}, graph.alloc)
		}
	}
	out := make([dynamic]Written_Alias, 0, 2, graph.alloc)
	for alias in prov_written_aliases_at(graph, carrier) {
		known := false
		for seen in out {
			known ||= seen.target == alias.target && prov_same_path(seen.at, alias.at)
		}
		if !known {
			append(&out, Written_Alias{target = alias.target, at = alias.at})
		}
	}
	return out[:]
}

@(private)
prov_same_path :: proc(a, b: []Proj_Step) -> bool {
	return len(a) == len(b) && path_has_exact_prefix(a, b)
}

// What the carriers in the storage `e` names or reads through may reach, each
// with its path below that storage (design.md "Minimum provenance precision").
// A read through a carrier first selects its storage, then loads the carriers
// held there; it does not conflate successive levels of indirection.
@(private)
prov_written_aliases_at :: proc(graph: ^Flow_Graph, id: Value_Id) -> []Written_Alias {
	if id == 0 { return nil }
	value := prov_value(graph, id)
	if transfer := prov_value_transfer(graph, id); transfer != nil {
		return prov_value_aliases(graph, id)
	}
	if root, path, ok := prov_value_place_of(graph, id); ok {
		return prov_written_aliases_of(graph, prov_storage_for_root(graph, root), path)
	}
	if carrier := prov_place_carrier(graph, id); carrier != 0 {
		return prov_load_aliases(graph, prov_written_aliases_at(graph, carrier), prov_path_below_carrier(graph, id),
		                         prov_input_read(graph, id).unknown_alias)
	}
	if symbol, named := value.form.(Prov_Form_Symbol); named {
		return prov_written_aliases_of(graph, prov_storage_id(graph, Written_Storage{symbol = symbol.symbol}), nil)
	}
	return prov_written_aliases_at(graph, prov_input_read(graph, id).fallback)
}

@(private)
prov_written_aliases_of :: proc(graph: ^Flow_Graph, id: Storage_Id, path: []Proj_Step) -> []Written_Alias {
	if sym := symbol_of(graph.k.c, prov_storage(graph, id).key.symbol); sym != nil && sym.kind == .Parameter && param_writes_caller(graph.k.c, sym) {
		return slice.clone([]Written_Alias{{target = id}}, graph.alloc)
	}
	out := make([dynamic]Written_Alias, 0, 2, graph.alloc)
	if aliases := graph.region_aliases[prov_storage(graph, id).key.symbol]; len(aliases) > 0 {
		for alias in aliases {
			if alias.root == NO_ROOT {
				append(&out, Written_Alias{})
			} else {
				append(&out, ..prov_written_aliases_of(graph, prov_storage_for_root(graph, alias.root), prov_concat_path(graph, alias.path, path)))
			}
		}
	}
	for alias in graph.written_aliases[id] {
		if !paths_overlap(alias.path, path) {
			continue
		}
		// What lies below the asked-for storage keeps its place there.
		rest: []Proj_Step
		if len(alias.path) > len(path) {
			rest = alias.path[len(path):]
		}
		append(&out, Written_Alias{target = alias.target, at = alias.at, path = rest})
	}
	return out[:]
}

// design.md "Allocator regions and region provenance": a local set from a
// writable parameter's storage, as `alias := dst`, `&mut dst^.items`, or
// `dst[1:]` set it, reaches the caller's storage. So does a copy of a read-only
// carrier reaching a mutable one, as `alias := outs` of `outs: ..^mut T`, and a
// value holding one, as `b := box^` or `b := Box{box.out}` of `box: ^Box`,
// whichever operand of a conditional, `or_else`, or `move` supplies it. A
// local set from `&mut out` or `Box{&mut out}` reaches `out`.
// `path` is where in the local the value is stored, as `pair.local = ...`
// stores it, and `type` the type stored there.
@(private = "file")
prov_note_written_alias :: proc(graph: ^Flow_Graph, local: Symbol_Id, value: Expr, path: []Proj_Step = nil, type := INVALID_TYPE) {
	c := graph.k.c
	sym := symbol_of(c, local)
	if value == nil || sym == nil || sym.kind != .Var || sym.duration != .None {
		return
	}
	stored := type == INVALID_TYPE ? sym.type : type
	if !type_is_carrier(c, stored) && !type_carries_borrow(c, stored).any {
		return
	}
	prov_note_alias_source(graph, prov_storage_id(graph, Written_Storage{symbol = local}), prov_input_value(graph, value), path)
}

// Records what `value` holds of writable parameters at `prefix` in `local`: a
// literal's fields at their own paths, so one field's carrier is not
// another's (design.md "Minimum provenance precision").
@(private)
prov_note_alias_source :: proc(graph: ^Flow_Graph, local: Storage_Id, value: Value_Id, prefix: []Proj_Step) {
	type := prov_value(graph, value).type
	recorded := prov_effect_active(graph) && value != 0 && (type_is_carrier(graph.k.c, type) || type_carries_borrow(graph.k.c, type).any)
	if recorded { prov_effect_begin(graph, Prov_Effect_Targets{local, prov_effect_value(graph, value), prov_effect_path(graph, prefix)}) }
	defer prov_effect_end(graph, recorded)
	if value == 0 { return }
	_ = prov_value_transfer(graph, value)
	for alias in prov_value_aliases(graph, value) {
		prov_add_written_alias(graph, local, Written_Alias{target = alias.target, at = alias.at,
		                       path = prov_concat_path(graph, prefix, alias.path)})
	}
}

@(private)
prov_alias_source_is_unknown :: proc(c: ^Compiler, type: Type_Id, value: Expr) -> bool {
	if !type_is_carrier(c, type) && !type_carries_borrow(c, type).any { return false }
	// make's zero elements contain no incoming carriers.
	if call, ok := value.(^Expr_Call); ok {
		if sym := symbol_of(c, call.resolution.symbol); sym != nil && (sym.builtin == .Make || sym.builtin == .Try_Make) { return false }
	}
	return true
}

@(private)
prov_add_written_alias :: proc(graph: ^Flow_Graph, local: Storage_Id, alias: Written_Alias) {
	alias := alias
	if alias.target == 0 {
		alias.at = nil // uncertainty has no storage path to extend
	}
	paths := [2]^[]Proj_Step{&alias.at, &alias.path}
	for path in paths {
		if len(path^) >= WRITTEN_ALIAS_DEPTH {
			path^ = slice.clone(path^[:WRITTEN_ALIAS_DEPTH], graph.alloc)
			path^[WRITTEN_ALIAS_DEPTH - 1].precision += {.Depth}
		}
	}
	existing := graph.written_aliases[local]
	for known in existing {
		if known.target == alias.target && prov_same_path(known.at, alias.at) && prov_same_path(known.path, alias.path) {
			return
		}
	}
	grown := make([]Written_Alias, len(existing) + 1, graph.alloc)
	copy(grown, existing)
	grown[len(existing)] = Written_Alias {
		target = alias.target,
		at     = slice.clone(alias.at, graph.alloc),
		path   = slice.clone(alias.path, graph.alloc),
	}
	graph.written_aliases[local] = grown
}

// A call may replace writable carrier storage without a source expression in
// this body. Keep an unresolved alternative there, including through nested
// carriers (design.md "Allocator regions and region provenance").
@(private)
prov_call_written_aliases :: proc(graph: ^Flow_Graph, id: Value_Id) {
	form := prov_value(graph, id).form.(Prov_Form_Call)
	call := form.call
	recorded := prov_effect_active(graph) && prov_input_call(graph, call).writes_facts
	if recorded { prov_effect_begin(graph, Prov_Effect_Call{prov_effect_value(graph, id), .Invalidate}) }
	defer prov_effect_end(graph, recorded)
	c := graph.k.c
	info := underlying_info(c, call_proc_type(c, call))
	if info == nil { return }
	seen := make([dynamic]Written_Alias_Visit, graph.alloc)
	for argument, index in prov_bound_values(form) {
		if index >= len(info.parameters) { continue }
		if call_packs(call, index) {
			// Separate elements at the element type, then spreads at the pack's.
			element := underlying_info(c, info.parameters[index]).element
			for value, position in form.pack { if !call.variadic_order[position] { prov_forget_argument_aliases(graph, value, element, false, &seen) } }
			for value, position in form.pack { if call.variadic_order[position] { prov_forget_argument_aliases(graph, value, info.parameters[index], false, &seen) } }
			continue
		}
		inout := index < len(info.param_modes) && info.param_modes[index] == .Inout
		prov_forget_argument_aliases(graph, argument, info.parameters[index], inout, &seen)
	}
}

// The effective parameter capability applies to the normalized value's paths.
@(private = "file")
prov_forget_argument_aliases :: proc(
	graph: ^Flow_Graph, id: Value_Id, parameter: Type_Id, inout: bool, seen: ^[dynamic]Written_Alias_Visit,
) {
	if id == 0 { return }
	c := graph.k.c
	if !inout && !carrier_is_mutable(c, parameter) && !prov_type_reaches_mutable(c, parameter) { return }
	if inout { prov_forget_place_aliases(graph, id, true, seen); return }
	_ = prov_value_transfer(graph, id)
	aliases := prov_value_aliases(graph, id)
	for carrier in carrier_shape(c, parameter) {
		for alias in aliases {
			if paths_overlap(alias.path, carrier.steps) {
				prov_forget_storage_aliases(graph, alias.target, alias.at, carrier.mutable, seen)
			}
		}
	}
}

Written_Alias_Visit :: struct {
	target: Storage_Id,
	path: []Proj_Step,
	writable: bool,
}

@(private = "file")
prov_forget_place_aliases :: proc(graph: ^Flow_Graph, place: Value_Id, writable: bool, seen: ^[dynamic]Written_Alias_Visit) {
	if root, path, ok := prov_value_place_of(graph, place); ok {
		prov_forget_storage_aliases(graph, prov_storage_for_root(graph, root), path, writable, seen)
		return
	}
	if prov_place_carrier(graph, place) == 0 {
		// A temporary literal has no named storage, but the carriers it holds
		// still reach caller storage through their own capabilities.
		prov_forget_argument_aliases(graph, place, prov_value(graph, place).type, false, seen)
		return
	}
	below := prov_path_below_carrier(graph, place)
	for alias in prov_written_targets(graph, place, as_place = true) {
		prov_forget_storage_aliases(graph, alias.target, prov_concat_path(graph, alias.at, below), writable, seen)
	}
}

@(private = "file")
prov_forget_storage_aliases :: proc(
	graph: ^Flow_Graph, target: Storage_Id, storage: []Proj_Step, writable: bool, seen: ^[dynamic]Written_Alias_Visit,
) {
	type := prov_written_storage_type(graph, target)
	if type == INVALID_TYPE { return }
	path := storage[:min(len(storage), WRITTEN_ALIAS_DEPTH)]
	for visit in seen^ {
		if visit.target == target && visit.writable == writable && prov_same_path(visit.path, path) { return }
	}
	append(seen, Written_Alias_Visit{target, path, writable})
	for alias in graph.region_aliases[prov_storage(graph, target).key.symbol] {
		if alias.root != NO_ROOT {
			prov_forget_storage_aliases(graph, prov_storage_for_root(graph, alias.root),
			                           prov_concat_path(graph, alias.path, path), writable, seen)
		}
	}
	for carrier in carrier_shape(graph.k.c, prov_type_at(graph.k.c, type, path)) {
		at := prov_concat_path(graph, path, carrier.steps)
		previous := prov_written_aliases_of(graph, target, at)
		if writable && (carrier.truncated || prov_type_reaches_mutable(graph.k.c, carrier.type)) {
			prov_add_written_alias(graph, target, Written_Alias{path = at})
		}
		for alias in previous {
			prov_forget_storage_aliases(graph, alias.target, alias.at, carrier.mutable, seen)
		}
	}
}

// design.md "Allocator regions and region provenance": a call leaves in each
// argument it may write the owners its body leaves there, with the regions of
// the arguments they came from. With no body to summarize, every allocator or
// moved-owner argument may land in every such argument.
@(private)
prov_call_written_regions :: proc(graph: ^Flow_Graph, id: Value_Id, proc_type: Type_Id) {
	form := prov_value(graph, id).form.(Prov_Form_Call)
	v, bound := form.call, prov_bound_values(form)
	recorded := prov_effect_active(graph) && prov_input_call(graph, v).writes_facts
	if recorded { prov_effect_begin(graph, Prov_Effect_Call{prov_effect_value(graph, id), .Write}) }
	defer prov_effect_end(graph, recorded)
	c := graph.k.c
	info := underlying_info(c, proc_type)
	if info == nil {
		return
	}
	callee := call_contract_declaration(c, v)
	direct := prov_has_direct_body(c, callee)
	prov_note_summary_dependency(graph, callee, direct)
	written, found := written_region_summary(c, callee)
	if !found && direct {
		return // no parameter it writes can hold an owner
	}
	// What backs an owner left there, as opposed to an allocator handle.
	owners, _ := written_region_summary(c, callee, owners = true)
	everything := prov_empty_region(graph)
	if !found {
		for argument, index in bound {
			if argument == 0 || index >= len(info.parameters) {
				continue
			}
			moved := index < len(info.param_modes) && info.param_modes[index] == .Move
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
			region = prov_substitute_region(graph, bound, written[index])
			owned = prov_empty_region(graph)
			if index < len(owners) {
				owned = prov_substitute_region(graph, bound, owners[index])
			}
			if has_rows && !packed && index < len(rows) {
				contents = make([]Prov_Region_Content, len(rows[index]), graph.alloc)
				for entry, position in rows[index] {
					contents[position] = entry
					contents[position].region = prov_substitute_region(graph, bound, entry.region)
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
			prov_store_region_set(graph, destination, region, owned, CALL_LEFT_OWNER, contents = contents)
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
		prov_store_region_set(graph, address.operand, region, owned, CALL_LEFT_OWNER, contents = contents)
		if prov_type_reaches_mutable(c, prov_value(graph, address.operand).type) {
			prov_store_region_through(graph, address.operand, region, owned, CALL_LEFT_OWNER, contents = contents)
		}
		return
	}
	prov_store_region_through(graph, argument, region, owned, CALL_LEFT_OWNER, contents = contents)
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
	rest = prov_empty_region(graph)
	region_merge(&rest, set)
	if graph.literal.signature == nil {
		return
	}
	index := 0
	for parameter in graph.literal.signature.params {
		for id in parameter.symbols {
			defer index += 1
			sym := symbol_of(graph.k.c, id)
			if sym == nil || sym.mode != .Move || index >= len(set.params) || !set.params[index] {
				continue
			}
			rest.params[index] = false
			if name == "" && sym.escape < level {
				name = identifier_text(graph.k.c, sym.name)
			}
		}
	}
	return
}

// The caller's half: a moved owner the call may keep takes its region into each
// argument it may be written to, or into static storage.
@(private = "file")
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

// ------------------------------------------------------------- places --

@(private)
prov_field_step :: proc(graph: ^Flow_Graph, v: ^Expr_Selector) -> Proj_Step {
	if !type_is_union(graph.k.c, prov_type(graph, v.operand)) {
		if field := symbol_of(graph.k.c, v.resolution.symbol); field != nil {
			step := proj_field(int(field.index))
			step.synchronized = v.synchronized
			return step
		}
	}
	return proj_wild()
}

@(private)
prov_index_path :: proc(graph: ^Flow_Graph, v: ^Expr_Index) -> []Proj_Step {
	return prov_index_path_in(graph, v, prov_type(graph, v.operand))
}

// The projection `v` selects in a value of `type`.
@(private)
prov_index_path_in :: proc(graph: ^Flow_Graph, v: ^Expr_Index, type: Type_Id) -> []Proj_Step {
	#partial switch underlying_kind(graph.k.c, type) {
	case .Array:
		return prov_extend(graph, nil, prov_index_step(graph, v.indices))
	case .Map:
		key: Expr
		if len(v.indices) == 1 {
			key = v.indices[0]
		}
		entry := prov_extend(graph, nil, prov_map_entry_step(graph, type, key))
		return prov_extend(graph, entry, proj_field(PROJ_MAP_VALUE))
	}
	return prov_extend(graph, nil, proj_wild())
}

// design.md "Weakening and reborrows": one carrier an access to a place goes
// through, read off the normalized place. `path` is where below the carrier's
// pointee the access goes on: to the place itself for the first hop, to the
// carrier of the hop before it for each later one.
Place_Hop :: struct {
	carrier: Value_Id,
	path:    []Proj_Step,
}

// The carriers a place is reached through, the one whose pointee holds it
// first and the outermost last; none for a place in lexical storage or one
// not reached through a carrier. Every access to a place, whether it loads,
// borrows, or stores, goes through these.
@(private)
prov_place_hops :: proc(graph: ^Flow_Graph, place: Expr) -> []Place_Hop {
	hops := make([dynamic]Place_Hop, 0, 2, graph.alloc)
	for at := prov_input_place(graph, place); true; {
		carrier, indirect := at.base.(Value_Id)
		if !indirect {
			break
		}
		// A view's loans already name the elements it views, so an element is
		// at no step below them.
		path := at.path
		#partial switch underlying_kind(graph.k.c, prov_value(graph, carrier).type) {
		case .Slice, .C_Pointer, .String_View, .CString_View:
			path = path[min(1, len(path)):]
		}
		append(&hops, Place_Hop{carrier, path})
		at = prov_value(graph, carrier).place
	}
	return hops[:]
}

// Reads the carriers `place` is reached through, outermost first, loading each
// inner one out of the pointee of the one before it, and returns the slots of
// the one whose pointee holds `place`, with the path below it. A `store`
// leaves the subscripts below the last carrier to itself. False when `place`
// is not reached through a carrier. `walk`, when given, collects the events
// reading the carriers (`Prov_Slot.walk_reads`).
@(private)
prov_read_through_carrier :: proc(
	graph: ^Flow_Graph, place: Expr, reads_only := false, store := false, walk: ^[dynamic]Prov_Event_At = nil, reads := true,
) -> ([]int, []Proj_Step, bool) {
	hops := prov_place_hops(graph, place)
	if len(hops) == 0 {
		return nil, nil, false
	}
	carriers := prov_reach_hop(graph, place, hops, 0, reads_only, store, walk)
	if !store && reads {
		prov_read_through(graph, carriers, hops[0].path, expr_span(place))
	}
	return carriers, hops[0].path, true
}

// Adds to `walk` the `.Live` and `.Load` events emitted in the current block
// from index `from` on.
@(private = "file")
prov_note_walk_reads :: proc(graph: ^Flow_Graph, walk: ^[dynamic]Prov_Event_At, from: int) {
	if walk == nil || graph.current == NO_BLOCK {
		return
	}
	events := graph.blocks[graph.current].prov[:]
	for index in from ..< len(events) {
		if events[index].kind == .Live || events[index].kind == .Load {
			append(walk, Prov_Event_At{graph.current, index})
		}
	}
}

// The index of the next event in the current block.
@(private = "file")
prov_next_event :: proc(graph: ^Flow_Graph) -> int {
	return graph.current == NO_BLOCK ? 0 : len(graph.blocks[graph.current].prov)
}

// The slots holding `hops[at]`'s carrier, read through the hops outside it,
// and then the subscripts between it and what it leads to. Read only, a
// mutable carrier copied out of another, as `p^` in `p^^[0]`, reborrows the
// carrier it came from read-only, which another read-only reborrow of that one
// allows (design.md "Weakening and reborrows"): a loop over `p^^` may still
// read through `p`. Only the carriers' own reads go to `walk`: an index may
// write, as `idx(q)` in `p^.cells[idx(q)]` does, so a subscript, or a carrier
// whose own subscripts may, is walked without it.
@(private = "file")
prov_reach_hop :: proc(graph: ^Flow_Graph, place: Expr, hops: []Place_Hop, at: int, reads_only, store: bool, walk: ^[dynamic]Prov_Event_At) -> []int {
	carrier := prov_value(graph, hops[at].carrier).origin
	inner := at == 0 ? place : prov_value(graph, hops[at - 1].carrier).origin
	indices := make([dynamic]Expr, 0, 0, graph.alloc)
	prov_segment_indices(inner, carrier, &indices)
	// An index that may write the carrier, read after it, sees it as it was.
	captures := prov_indices_may_write(indices[:]) && !(store && at == 0)
	only := reads_only && !captures
	slots: []int
	if at == len(hops) - 1 {
		if _, _, named := prov_place_of(graph, carrier); named {
			own := make([dynamic]Expr, 0, 0, graph.alloc)
			prov_segment_indices(carrier, nil, &own)
			from := prov_next_event(graph)
			slots = prov_read_carrier(graph, carrier, only)
			if !prov_indices_may_write(own[:]) {
				prov_note_walk_reads(graph, walk, from)
			}
		} else {
			slots = walk_flow_expr(graph, carrier)
		}
	} else {
		loads := only || prov_read_is_reads_only(graph.k.c, prov_type(graph, carrier))
		outer := prov_reach_hop(graph, place, hops, at + 1, loads, false, walk)
		from := prov_next_event(graph)
		slots = prov_load_content(
			graph, outer, hops[at + 1].path, prov_type(graph, carrier), expr_span(carrier), reads_only = loads, walked = true,
		)
		prov_note_walk_reads(graph, walk, from)
		if only {
			slots = prov_reborrow_read_only(graph, slots, expr_span(carrier))
		}
	}
	if captures {
		slots = prov_capture(graph, slots, expr_span(inner))
	}
	if !(store && at == 0) {
		for index in indices {
			walk_flow_expr(graph, index)
		}
	}
	return prov_reach(graph, slots, expr_span(inner))
}

// A carrier loaded through another, as `p^` for `p^^.count`, is named in
// diagnostics by the carrier it was loaded through, `p`.
@(private = "file")
prov_name_loaded :: proc(graph: ^Flow_Graph, slots, outer: []int) {
	name := ""
	for slot in outer {
		if graph.prov_slots[slot].name != "" {
			name = graph.prov_slots[slot].name
			break
		}
	}
	for slot in slots {
		if entry := &graph.prov_slots[slot]; entry.name == "" && entry.loaded && entry.symbol == INVALID_SYMBOL {
			entry.name = name
		}
	}
}

// The index expressions from `from` down to the carrier `to`, or to the root
// when `to` is nil, in the order they are evaluated.
@(private = "file")
prov_segment_indices :: proc(from, to: Expr, out: ^[dynamic]Expr) {
	if from == nil || to != nil && expr_base(from) == expr_base(to) {
		return
	}
	#partial switch v in from {
	case ^Expr_Selector:
		prov_segment_indices(v.operand, to, out)
	case ^Expr_Postfix:
		prov_segment_indices(v.operand, to, out)
	case ^Expr_Index:
		prov_segment_indices(v.operand, to, out)
		append(out, ..v.indices)
	}
}

// Each loaded mutable carrier in `slots` replaced by a read-only reborrow of it.
@(private = "file")
prov_reborrow_read_only :: proc(graph: ^Flow_Graph, slots: []int, span: Span) -> []int {
	out := make([dynamic]int, 0, len(slots), graph.alloc)
	for slot in slots {
		if !prov_slot_is_loaded_mutable(graph, slot) {
			append(&out, slot)
			continue
		}
		derived := prov_temp_slot(graph)
		prov_emit(graph, Prov_Event{kind = .Def, slot = derived, loan = NO_LOAN, sources = prov_one(graph, slot), span = span})
		append(&graph.reborrows, Prov_Reborrow{source = slot, derived = derived, span = span, mutable = false})
		append(&out, derived)
	}
	return out[:]
}

// An index that is not a constant or a plain read may call something that
// writes the carrier being indexed.
@(private)
prov_indices_may_write :: proc(indices: []Expr) -> bool {
	for index in indices {
		if !is_const_expr(index) && !is_effect_free_place(index) {
			return true
		}
	}
	return false
}

// The root and projection a place names, or none when it goes through a carrier;
// that is a use of the carrier, not a competing access to a root.
@(private)
prov_place_of :: proc(graph: ^Flow_Graph, e: Expr) -> (Root_Id, []Proj_Step, bool) {
	return prov_root_place(graph, prov_input_place(graph, e))
}

@(private)
prov_value_place_of :: proc(graph: ^Flow_Graph, id: Value_Id) -> (Root_Id, []Proj_Step, bool) {
	return prov_root_place(graph, prov_value(graph, id).place)
}

@(private = "file")
prov_root_place :: proc(graph: ^Flow_Graph, place: Prov_Place) -> (Root_Id, []Proj_Step, bool) {
	if storage, direct := place.base.(Storage_Id); direct {
		root := prov_root_for_storage(graph, storage)
		return root, place.path, root != NO_ROOT
	}
	return NO_ROOT, nil, false
}

// Walks a place chain's index expressions; the place is one access, not one per
// link.
@(private)
prov_walk_subscripts :: proc(graph: ^Flow_Graph, e: Expr, publish_map_keys := false) {
	#partial switch v in e {
	case ^Expr_Selector:
		prov_walk_subscripts(graph, v.operand, publish_map_keys)
	case ^Expr_Postfix:
		if v.boxed {
			prov_walk_subscripts(graph, v.operand, publish_map_keys)
		}
	case ^Expr_Index:
		prov_walk_subscripts(graph, v.operand, publish_map_keys)
		key_sources: []int
		for index, position in v.indices {
			loans := walk_flow_expr(graph, index)
			if position == 0 {
				key_sources = loans
			}
		}
		// A map index hashes its key and compares it with the stored ones.
		if len(v.bound) == 0 && underlying_kind(graph.k.c, prov_type(graph, v.operand)) == .Map {
			prov_key_effects(graph, prov_type(graph, v.operand), v.span)
		}
		if !publish_map_keys || len(v.bound) > 0 || len(v.indices) != 1 ||
		   underlying_kind(graph.k.c, prov_type(graph, v.operand)) != .Map {
			return
		}
		info := underlying_info(graph.k.c, prov_type(graph, v.operand))
		if info == nil {
			return
		}
		// Assigning through a map place may insert its key; an existing equal key
		// stays, so the key dependency joins.
		prov_retain_escape(graph, v.operand, key_sources, v.span)
		root, path, ok := prov_place_of(graph, v.operand)
		if !ok {
			prov_store_map_key_region(graph, prov_input_value(graph, v.operand), prov_input_value(graph, v.indices[0]))
			// Reached through a carrier: publish to what it may name.
			if through := prov_retain_through_carrier(graph, v.operand); len(through) > 0 {
				prov_reborrow(graph, key_sources, info.key)
				prov_emit(graph, Prov_Event {
					kind = .Publish, span = v.span, sources = key_sources, into = through,
				})
			}
			return
		}
		entry := prov_extend(graph, path, prov_map_entry_step(graph, prov_type(graph, v.operand), v.indices[0]))
		written := prov_extend(graph, entry, proj_field(PROJ_MAP_KEY))
		prov_event(graph, Prov_Event_Key_Escape{prov_input_value(graph, v.indices[0]), expr_span(v.indices[0]), graph.roots[int(root)].symbol, prov_owner_name(graph, v.indices[0])})
		prov_define_value_regions(graph, root, written, prov_input_value(graph, v.indices[0]))
		if content := prov_content_at(graph, root, written); len(content) > 0 {
			prov_define_content(graph, content, key_sources, v.span, written, info.key, true)
		}
	}
}

@(private = "file")
prov_const_int :: proc(graph: ^Flow_Graph, e: Expr) -> (i64, bool) {
	base := expr_base(e)
	if base == nil || !base.is_const || base.const_value.kind != .Integer {
		return 0, false
	}
	return bi_to_i64(graph.k.c, base.const_value.integer)
}

// A constant key's own entry while slots remain, else the wildcard, which
// overlaps every keyed entry.
@(private)
prov_map_entry_step :: proc(graph: ^Flow_Graph, map_type: Type_Id, key: Expr) -> Proj_Step {
	if key == nil || !map_shape_is_keyed(graph.k.c, map_type) {
		return proj_wild()
	}
	base := expr_base(key)
	if base == nil || !base.is_const {
		return proj_wild()
	}
	name: string
	#partial switch base.const_value.kind {
	case .String:
		name = fmt.aprintf("s:%s", base.const_value.text, allocator = graph.alloc)
	case .Integer:
		value, ok := bi_to_i64(graph.k.c, base.const_value.integer)
		if !ok {
			return proj_wild()
		}
		name = fmt.aprintf("i:%d", value, allocator = graph.alloc)
	case .Rune:
		value, ok := bi_to_i64(graph.k.c, base.const_value.integer)
		if !ok {
			return proj_wild()
		}
		name = fmt.aprintf("r:%d", value, allocator = graph.alloc)
	case .Boolean:
		name = fmt.aprintf("b:%v", base.const_value.boolean, allocator = graph.alloc)
	case:
		return proj_wild()
	}
	if entry, found := graph.input.map_key_entries[name]; found {
		return proj_range(i64(entry), i64(entry) + 1)
	}
	entry := len(graph.input.map_key_entries)
	if entry >= MAP_KEY_SLOTS {
		step := proj_wild()
		step.precision = {.Map_Keys}
		return step
	}
	prov_writable_input(graph)
	graph.input.map_key_entries[strings.clone(name, graph.input.alloc)] = entry
	return proj_range(i64(entry), i64(entry) + 1)
}

@(private = "file")
prov_index_step :: proc(graph: ^Flow_Graph, indices: []Expr) -> Proj_Step {
	if len(indices) != 1 {
		return proj_wild()
	}
	value, ok := prov_const_int(graph, indices[0])
	if !ok {
		return proj_wild()
	}
	return proj_range(value, value + 1)
}

@(private = "file")
prov_range_step :: proc(graph: ^Flow_Graph, v: ^Expr_Slice) -> Proj_Step {
	low, low_ok := i64(0), true
	if v.lo != nil {
		low, low_ok = prov_const_int(graph, v.lo)
	}
	high, high_ok := i64(0), false
	if v.hi != nil {
		high, high_ok = prov_const_int(graph, v.hi)
	} else if info := v.operand == nil ? nil : underlying_info(graph.k.c, prov_type(graph, v.operand));
	   info != nil && info.kind == .Array {
		high, high_ok = i64(info.count), true
	}
	if !low_ok || !high_ok || high <= low {
		return proj_wild()
	}
	return proj_range(low, high)
}

// ------------------------------------------------------- statement hooks --

@(private)
prov_read_ident :: proc(graph: ^Flow_Graph, v: ^Expr_Ident, kind: Access_Kind, reads_only := false) -> []int {
	if root := prov_root_for_symbol(graph, v.symbol); root != NO_ROOT {
		prov_access(graph, root, nil, kind, v.span, reads_only = reads_only)
	}
	if slot, is_carrier := prov_slot_for_symbol(graph, v.symbol); is_carrier {
		sources := prov_one(graph, slot)
		prov_emit(graph, Prov_Event {
			kind = .Live, sources = sources, span = v.span, reads_only = reads_only,
		})
		return sources
	}
	if content := prov_content_slots(graph, v.symbol); len(content) > 0 {
		prov_emit(graph, Prov_Event{kind = .Live, sources = content, span = v.span})
		return content
	}
	return nil
}

@(private = "file")
prov_invalidate :: proc(graph: ^Flow_Graph, place: Expr, span: Span, verb: string) {
	if root, path, ok := prov_place_of(graph, place); ok {
		prov_walk_subscripts(graph, place)
		prov_access(graph, root, path, .Invalidate, span, verb)
		return
	}
	walk_flow_expr(graph, place)
	prov_write_through_place(graph, place, span)
}

@(private)
prov_address_of :: proc(graph: ^Flow_Graph, v: ^Expr_Unary) -> []int {
	return prov_borrow_place(graph, v.operand, v.mutable, v.span, "pointer")
}

// A borrow of `operand` as a place, for `&operand` and `return inout operand`.
prov_borrow_place :: proc(graph: ^Flow_Graph, operand: Expr, mutable: bool, span: Span, what: string) -> []int {
	// design.md "Capabilities and the one rule". A binding that views another
	// owner's storage is not its own root: the pointer names the source.
	if ident, is_ident := operand.(^Expr_Ident); is_ident {
		if loans, viewed := graph.view_loans[ident.symbol]; viewed && !graph.step_views[ident.symbol] {
			return loans
		}
	}
	root, path, ok := prov_place_of(graph, operand)
	if !ok {
		// design.md "Weakening and reborrows": a borrow of a place reached
		// through carriers is a place loan of it, read-only or mutable, which
		// an access through any carrier naming that storage at an overlapping
		// place conflicts with while the borrow is in use. A read-only borrow
		// only reads the carriers it goes through, which another read-only
		// reborrow of them allows; a mutable one writes what it borrows, which
		// covers the read.
		walk := make([dynamic]Prov_Event_At, 0, 0, graph.alloc)
		if carriers, below, through := prov_read_through_carrier(graph, operand, reads_only = !mutable, walk = &walk, reads = !mutable); through {
			at, end := -1, -1
			if mutable {
				at = prov_write_through(graph, carriers, below, span, "mutable borrow")
				end = at < 0 ? -1 : prov_next_event(graph)
			}
			held := prov_next_event(graph)
			prov_use_held(graph, carriers, below, prov_type(graph, operand), span, !mutable)
			prov_note_walk_reads(graph, &walk, held)
			marker := prov_through_marker(graph, at, end, walk[:])
			return prov_join(graph, prov_place_loan(graph, carriers, below, mutable, what, operand, borrows = true), marker)
		}
		if place, is_inout := prov_inout_result_place(graph, operand); is_inout {
			return place
		}
		loans := walk_flow_expr(graph, operand)
		if !prov_expr_is_temporary(operand) {
			return loans
		}
		// A borrow of a temporary cannot escape its expression (design.md), even
		// when the temporary also holds borrows, as `&box(view)^` does.
		temporary := prov_borrow(graph, prov_temp_root_of(graph, operand, loans), nil, mutable, span, what)
		return prov_join(graph, loans, temporary)
	}
	prov_walk_subscripts(graph, operand)
	access_block, access_index := prov_access(graph, root, path, mutable ? .Write : .Read, span)
	if held := prov_carrier_slots(graph, operand); len(held) > 0 {
		prov_emit(graph, Prov_Event{kind = .Live, sources = held, span = span, reads_only = !mutable})
	}
	return prov_borrow(graph, root, path, mutable, span, what, access_block, access_index)
}

// A slot standing for a borrow through carriers (`Prov_Slot.through_block`):
// its `.Through` events from `at` up to `end`, -1 for both when it writes
// nothing, and the reads of the carriers it went through. Weakened to a read-only destination, as
// `look(&mut p[0])` passes it, the borrow writes nothing and only reads the
// carriers, which the slot lets `prov_reborrow` settle.
@(private = "file")
prov_through_marker :: proc(graph: ^Flow_Graph, at, end: int, walk: []Prov_Event_At) -> []int {
	if graph.current == NO_BLOCK {
		return nil
	}
	marker := prov_temp_slot(graph)
	entry := &graph.prov_slots[marker]
	entry.through_block, entry.through_index, entry.through_end, entry.walk_reads = graph.current, at, end, walk
	return prov_one(graph, marker)
}

// design.md "Weakening and reborrows": a borrow of a place reaches the
// carriers it holds, so it uses them, and `both(held, &mut held)` cannot hand
// on `held` while it is reborrowed for the call, nor `&mut list^.head` the
// carrier a copy of `list^.head` reborrows. Through `carriers`, those are
// loaded from `path` below their pointee.
@(private = "file")
prov_use_held :: proc(graph: ^Flow_Graph, carriers: []int, path: []Proj_Step, type: Type_Id, span: Span, reads_only: bool) {
	if len(carriers) == 0 || !type_carries_borrow(graph.k.c, type).mutable {
		return
	}
	graph.has_content_load = true
	prov_emit(graph, Prov_Event{kind = .Load, slot = prov_temp_slot(graph), into = carriers, path = path, span = span, reads_only = reads_only})
}

@(private)
prov_slice :: proc(graph: ^Flow_Graph, v: ^Expr_Slice) -> []int {
	if v.resolution.kind == .User_Operator {
		return prov_call(graph, prov_operator_call(graph, v))
	}
	mutable := slice_is_mutable(graph.k.c, prov_type(graph, v))
	// An array, string, or dynamic array is sliced out of its own root (design.md
	// "Dynamic arrays"); reslicing a carrier keeps its loans.
	operand_kind := underlying_kind(graph.k.c, prov_type(graph, v.operand))
	array := operand_kind == .Array || operand_kind == .String || operand_kind == .Dynamic_Array
	if root, path, ok := prov_place_of(graph, v.operand); ok && array {
		prov_walk_subscripts(graph, v.operand)
		if v.lo != nil {
			walk_flow_expr(graph, v.lo)
		}
		if v.hi != nil {
			walk_flow_expr(graph, v.hi)
		}
		full := prov_extend(graph, path, prov_range_step(graph, v))
		access_block, access_index := prov_access(graph, root, full, mutable ? .Write : .Read, v.span)
		return prov_borrow(
			graph, root, full, mutable, v.span, carrier_noun(graph.k.c, prov_type(graph, v)),
			access_block, access_index,
		)
	}
	// Storage reached through a pointer or view borrows what that carrier names,
	// as `&p.items` does.
	if array {
		if carriers, below, through := prov_read_through_carrier(graph, v.operand, reads_only = !mutable); through {
			if v.lo != nil { walk_flow_expr(graph, v.lo) }
			if v.hi != nil { walk_flow_expr(graph, v.hi) }
			if mutable {
				prov_write_through(graph, carriers, below, expr_span(v.operand), "mutable slice")
			}
			return prov_join(graph, prov_place_loan(
				graph, carriers, below, mutable, carrier_noun(graph.k.c, prov_type(graph, v)), v.operand, borrows = true,
			), prov_through_marker(graph, -1, -1, nil))
		}
	}
	source: []int
	if ident, plain := prov_plain_slice_local(graph, v.operand); plain && !mutable {
		source = prov_read_ident(graph, ident, .Read, reads_only = true) // a read-only view only reads
	} else {
		source = walk_flow_expr(graph, v.operand)
	}
	if v.lo != nil {
		walk_flow_expr(graph, v.lo)
	}
	if v.hi != nil {
		walk_flow_expr(graph, v.hi)
	}
	// Reslicing a carrier keeps its loans; slicing an owner also borrows it, and
	// a temporary owner such as `[dynamic]int{1, 2}` ends with its statement
	// unless a local's value extends it.
	if !array {
		return source
	}
	if prov_expr_is_temporary(v.operand) {
		temporary := prov_borrow(graph, prov_temp_root_of(graph, v.operand, source), nil, mutable, v.span, "slice")
		return prov_join(graph, source, temporary)
	}
	return source
}

// design.md "Slice literals": the hidden array is always extended, an owner
// ending with its block, and a slice of it also carries its elements' loans.
@(private)
prov_slice_literal :: proc(graph: ^Flow_Graph, literal: ^Expr_Composite, mutable: bool, elements: []int) -> []int {
	span := literal.span
	storage := prov_storage_id(graph, Written_Storage{temporary = &literal.base, type = prov_repr(graph, literal).backing}, .Slice_Literal)
	root := prov_root_for_storage(graph, storage)
	graph.roots[int(root)].kind = .Slice_Literal
	graph.roots[int(root)].name = "this slice literal"
	for element, index in literal.elements {
		if element.value == nil { continue }
		step, _ := prov_element_step(graph, literal, prov_repr(graph, literal).backing, true, index)
		copies := index < len(literal.element_clones) && literal.element_clones[index]
		prov_define_value_regions(graph, root, {step}, prov_input_value(graph, element.value), copies = copies)
	}
	append(&graph.in_scope, Flow_Cleanup{kind = .Prov_Root, root = root, span = span})
	return prov_join(graph, elements, prov_borrow(graph, root, nil, mutable, span, "slice"))
}

// Iterating a place borrows it, mutably for a `ref` binding.
@(private)
prov_iterate :: proc(graph: ^Flow_Graph, s: ^Stmt_Foreach, iterated: []int) -> []int {
	iterable := s.iterable
	if type_is_carrier(graph.k.c, prov_type(graph, iterable)) {
		prov_reach(graph, iterated, expr_span(iterable))
	}
	mutable := foreach_is_place_loop(s)
	// A mutable carrier is reborrowed by the traversal instead: the elements live
	// in what it views, not in the variable.
	if type := prov_type(graph, iterable); carrier_is_mutable(graph.k.c, type) && !type_is_region_provider(graph.k.c, type) {
		return iterated
	}
	span := expr_span(s.iterable)
	root, path, ok := prov_place_of(graph, iterable)
	if !ok {
		// design.md "Temporary roots": a temporary owner lives for the whole
		// statement and lends its elements like any other source.
		if (s.borrows || mutable) && prov_expr_is_temporary(iterable) && !type_is_carrier(graph.k.c, prov_type(graph, iterable)) {
			return prov_join(graph, iterated, prov_borrow(graph, prov_temp_root(graph, span), nil, mutable, span, "iterator"))
		}
		return iterated
	}
	prov_access(graph, root, path, mutable ? .Write : .Read, span)
	return prov_join(graph, iterated, prov_borrow(graph, root, path, mutable, span, "iterator"))
}

// A root that ends with the statement that created it.
@(private)
prov_temp_root :: proc(graph: ^Flow_Graph, span: Span) -> Root_Id {
	root := prov_new_root(graph, .Temporary, span, "this temporary")
	append(&graph.temp_roots, root)
	return root
}

// The root of the temporary `e` holds: one ending with its block when the
// statement extends it (design.md "Temporaries and procedure boundaries"), and
// with the statement otherwise. `content` is what the borrowed value carries.
@(private)
prov_temp_root_of :: proc(graph: ^Flow_Graph, e: Expr, content: []int) -> Root_Id {
	span := expr_span(e)
	extends := graph.extended[expr_base(e)]
	storage := prov_storage_id(graph, Written_Storage{temporary = expr_base(e), type = prov_type(graph, e)})
	root := prov_root_for_storage(graph, storage)
	if extends {
		append(&graph.in_scope, Flow_Cleanup{kind = .Prov_Root, root = root, span = span})
	} else {
		append(&graph.temp_roots, root)
	}
	extended := &graph.roots[int(root)]
	extended.extended = extends
	// Dropped with the block's locals, so its drop hooks run there and read
	// what it borrows then, as a named local's would (design.md "Global write
	// effects", "Capabilities and the one rule").
	holder := extended_temporary(e)
	extended.dropped = prov_type(graph, holder)
	if erased := prov_repr(graph, holder).erased_from; erased != INVALID_TYPE {
		extended.dropped = erased
	}
	if type_is_managed(graph.k.c, extended.dropped) && !expression_is_borrowed_place(holder) {
		extended.owner = holder
	}
	if extends {
		held := content
		if holder != e {
			held = prov_join(graph, held, graph.extended_content[expr_base(holder)])
		}
		if len(held) > 0 && type_drop_runs_hook(graph.k.c, extended.dropped) {
			slot := prov_temp_slot(graph)
			prov_emit(graph, Prov_Event{kind = .Def, slot = slot, loan = NO_LOAN, sources = held, span = span})
			graph.roots[int(root)].content = slot
		}
	}
	prov_define_value_regions(graph, root, nil, prov_input_value(graph, e))
	return root
}

// The temporary that holds the borrowed value `e`: a field, an element, or a
// box's payload is part of it. An erased value's own type is its source's.
@(private = "file")
extended_temporary :: proc(e: Expr) -> Expr {
	node := e
	for {
		#partial switch v in node {
		case ^Expr_Selector:
			if v.resolution.kind == .Field {
				node = v.operand
				continue
			}
		case ^Expr_Index:
			if v.resolution.kind != .User_Operator {
				node = v.operand
				continue
			}
		case ^Expr_Postfix:
			if v.boxed {
				node = v.operand
				continue
			}
		}
		break
	}
	return node
}

// A value no name holds, which ends with its statement: a call or literal
// result, an operator's (`a + "yz"`), a conditional's or `or_else`'s, or a
// moved value. A field or element of one is part of it, so `build().items[:]`
// ends with its statement too.
@(private)
prov_expr_is_temporary :: proc(e: Expr) -> bool {
	#partial switch v in e {
	case ^Expr_Composite, ^Expr_Call, ^Expr_Cond, ^Expr_Or_Else, ^Expr_Move, ^Expr_Propagated_Error:
		return true
	case ^Expr_Binary:
		return v.value_category != .Place // a user operator may return a place
	case ^Expr_Postfix:
		// A temporary box's payload ends with the box.
		return v.op == .Or_Return || (v.boxed && prov_expr_is_temporary(v.operand))
	case ^Expr_Selector:
		// `pkg.name` is a whole global, not a field of its operand.
		return v.resolution.kind != .Value && prov_expr_is_temporary(v.operand)
	case ^Expr_Index:
		return prov_expr_is_temporary(v.operand)
	}
	return false
}

@(private)
prov_declare :: proc(graph: ^Flow_Graph, d: ^Decl, value_loans: [][]int) {
	for id, symbol_index in d.symbols {
		sym := symbol_of(graph.k.c, id)
		if sym == nil || sym.kind != .Var {
			continue
		}
		root := prov_root_for_symbol(graph, id)
		if root != NO_ROOT && graph.roots[int(root)].kind == .Local {
			append(&graph.in_scope, Flow_Cleanup{kind = .Prov_Root, root = root, span = sym.span})
		}
		initializer: Expr
		if d.destructure.active {
			initializer = d.values[0]
		} else if symbol_index < len(d.values) {
			initializer = d.values[symbol_index]
		}
		projected := d.destructure.active ? symbol_index : -1
		clones := d.destructure.active ? d.destructure.clones : d.value_clones
		if projected >= 0 { projected = prov_destructure_index(graph.k.c, &d.destructure, symbol_index) }
		prov_declare_region(graph, id, sym, prov_input_value(graph, initializer), projected, symbol_index < len(clones) && clones[symbol_index])
		if projected < 0 {
			prov_note_written_alias(graph, id, initializer)
		}
		slot, is_carrier := prov_slot_for_symbol(graph, id)
		content := prov_content_slots(graph, id)
		if !is_carrier && len(content) == 0 {
			continue
		}
		sources: []int
		if value_loans != nil {
			if d.destructure.active {
				// design.md "Destructuring": each binding takes its own field's root,
				// not the record's joined set.
				sources = prov_destructure_field(
					graph, value_loans[0], &d.destructure, symbol_index, sym.type, sym.span,
				)
			} else if symbol_index < len(value_loans) {
				sources = value_loans[symbol_index]
			}
		}
		if !is_carrier {
			prov_define_content(graph, content, sources, sym.span)
			continue
		}
		prov_reborrow(graph, sources, sym.type, slot, expr_span(initializer) if initializer != nil else sym.span, copies = true)
		prov_emit(graph, Prov_Event {
			kind    = .Def,
			slot    = slot,
			loan    = NO_LOAN,
			sources = sources,
			span    = sym.span,
		})
	}
}

// An allocator binding takes its initializer's region; a managed owner takes
// its constructing call's.
@(private)
prov_declare_region :: proc(
	graph: ^Flow_Graph,
	id: Symbol_Id,
	sym: ^Symbol,
	value: Value_Id,
	projected: int = -1,
	copies := false,
) {
	recorded := prov_effect_active(graph) && prov_effect_symbol_relevant(graph, id)
	if recorded { prov_effect_begin(graph, Prov_Effect_Declare{id, prov_effect_value(graph, value), projected, copies}) }
	defer prov_effect_end(graph, recorded)
	initializer := prov_value(graph, value).origin
	initializer_region := Region_Set{}
	if initializer != nil && type_is_carrier(graph.k.c, sym.type) && !type_is_region_provider(graph.k.c, sym.type) {
		initializer_region = prov_storage_region(graph, value)
	} else if initializer != nil {
		if projected >= 0 {
			initializer_region = prov_result_region_at(graph, value, {proj_field(projected)})
		} else {
			initializer_region = prov_result_region(graph, value)
		}
	}
	// A provider moved in keeps its region, and so its token.
	if initializer != nil && sym.duration == .None && projected < 0 {
		if _, found := graph.provider_bits[id]; !found {
			if bits := prov_moved_bits(graph, value); bits != 0 {
				graph.provider_moved[id] = bits
			}
		}
	}
	// design.md: a local `mem.Arena`/`mem.Scratch` is a region of its own.
	if type_is_region_provider(graph.k.c, sym.type) && sym.duration == .None {
		prov_merge_region_of(graph, id, prov_provider_region(graph, id))
		if initializer != nil {
			parent := graph.provider_parents[id] or_else prov_empty_region(graph)
			region_merge(&parent, initializer_region)
			if !region_is_empty(parent) {
				graph.provider_parents[id] = parent
			}
		}
		return
	}
	if type_underlying(graph.k.c, sym.type) == TYPE_ALLOCATOR || type_is_carrier(graph.k.c, sym.type) {
		if initializer != nil {
			prov_merge_region_of(graph, id, initializer_region)
		}
		return
	}
	// A record holding an allocator handle keeps its region as an owner does
	// (design.md "Allocator regions and region provenance"), but owns nothing a
	// reset would strand.
	managed := type_is_managed(graph.k.c, sym.type)
	if !managed && !prov_type_has_region(graph.k.c, sym.type) {
		return
	}
	set := prov_empty_region(graph)
	// An explicit `via` allocator decides the region (design.md).
	if written := symbol_via_allocator(graph.k.c, id); written != nil {
		// An incoming owner keeps its allocator. Only an eager binding of an
		// empty container needs a policy fact of its own; copies and nonempty
		// literals already query the allocator they actually use.
		empty := initializer == nil
		if literal, ok := prov_value(graph, value).form.(Prov_Form_Composite); ok { empty = len(literal.elements) == 0 }
		if empty && type_is_container(graph.k.c, sym.type) { region_merge(&set, prov_region_of(graph, prov_input_value(graph, written))) }
	}
	if initializer != nil {
		// A record's handles and owners keep their own field regions rather
		// than making every field depend on the whole initializer.
		source: []Proj_Step
		if projected >= 0 { source = {proj_field(projected)} }
		prov_define_value_regions(graph, prov_root_for_symbol(graph, id), nil, value, source, copies, id)
	}
	// An owner copied from a place may be cloned.
	if initializer != nil && clone_may_allocate(graph.k.c, sym.type) && expression_is_borrowed_place(initializer) {
		cloned := prov_empty_region(graph)
		region_merge(&cloned, prov_destination_allocator(graph, id))
		region_merge(&cloned, initializer_region)
		prov_note_allocator_use(graph, cloned, sym.span, owned = true)
	}
	if !region_is_empty(set) {
		kind := underlying_kind(graph.k.c, sym.type)
		if kind == .Dynamic_Array || kind == .Map || kind == .Box {
			prov_define_region_content(graph, prov_root_for_symbol(graph, id), nil, set, own = true)
		} else {
			prov_merge_region_of(graph, id, set)
		}
	}
	if sym.duration != .None {
		source: []Proj_Step
		if projected >= 0 { source = {proj_field(projected)} }
		owned := prov_copied_owner_region(graph, value, source, copies, prov_destination_allocator(graph, id))
		region_merge(&owned, set)
		if region_is_parameter_backed(owned) || region_has_local(owned) {
			storage := sym.duration == .Thread_Local ? "`thread_local` storage" : "`static` storage"
			prov_emit(graph, Prov_Event {
				kind   = .Region_Escape,
				span   = sym.span,
				verb   = fmt.aprintf("`%s`", identifier_text(graph.k.c, sym.name), allocator = graph.alloc),
				name   = storage,
				region = owned,
			})
		}
	}
}

@(private = "file")
prov_destructure_field :: proc(
	graph: ^Flow_Graph,
	sources: []int,
	plan: ^Destructure,
	index: int,
	field_type: Type_Id,
	span: Span,
) -> []int {
	if len(sources) == 0 {
		return nil
	}
	// A padding field fills no binding, so the field's own slot is projected.
	slot := prov_destructure_index(graph.k.c, plan, index)
	return prov_project_content(graph, sources, plan.record, {proj_field(slot)}, field_type, span)
}

@(private = "file")
prov_destructure_index :: proc(c: ^Compiler, plan: ^Destructure, index: int) -> int {
	if field := symbol_of(c, plan.fields[index]); field != nil { return int(field.index) }
	return index
}

@(private)
prov_assign :: proc(graph: ^Flow_Graph, s: ^Stmt_Assign, value_loans: [][]int) {
	// design.md "Evaluation order": every value is evaluated before any write,
	// so a value read from a variable this statement also writes, as in
	// `a, b = b, a`, keeps what the variable held then.
	value_loans := value_loans
	if len(s.lhs) > 1 && !s.destructure.active && value_loans != nil {
		written := make([dynamic]int, 0, len(s.lhs), graph.alloc)
		for target in s.lhs {
			if ident, is_ident := target.(^Expr_Ident); is_ident {
				if slot, is_carrier := prov_slot_for_symbol(graph, ident.symbol); is_carrier {
					append(&written, slot)
				}
			}
		}
		if len(written) > 0 {
			captured := make([][]int, len(value_loans), graph.alloc)
			for loans, index in value_loans {
				captured[index] = prov_capture_slots(graph, loans, written[:], s.op_span)
			}
			value_loans = captured
		}
	}
	for target, index in s.lhs {
		clones := s.destructure.active ? s.destructure.clones : s.rhs_clones
		copies := index < len(clones) && clones[index]
		source: []Proj_Step
		if s.destructure.active { source = {proj_field(prov_destructure_index(graph.k.c, &s.destructure, index))} }
		sources: []int
		value: Expr
		if s.destructure.active {
			value = s.rhs[0]
			if value_loans != nil && len(value_loans) > 0 {
				sources = prov_destructure_field(
					graph, value_loans[0], &s.destructure, index, prov_type(graph, target), expr_span(target),
				)
			}
		} else if index < len(s.rhs) {
			value = s.rhs[index]
			if value_loans != nil && index < len(value_loans) {
				sources = value_loans[index]
			}
		}
		if value != nil && s.op == .Assign {
			prov_region_escape(graph, target, prov_input_value(graph, value), source, copies)
			// An owner copied from a place may be cloned.
			if prov_tracks_allocator_use(graph) && clone_may_allocate(graph.k.c, prov_type(graph, target)) &&
			   expression_is_borrowed_place(value) {
				prov_event(graph, Prov_Event_Allocator_Use{prov_input_value(graph, value), expr_span(value), true})
			}
		}
		target_type := prov_type(graph, target)
		if s.op == .Assign {
			// The old value ends first; a provider moved in then joins the local.
			// A destination already moved out holds nothing to drop.
			if index >= len(s.destination_live) || s.destination_live[index] != .Dead {
				prov_drop_effects(graph, target_type, expr_span(target), region = prov_drop_region(graph, target))
			}
			if ident, is_ident := target.(^Expr_Ident); is_ident {
				provider_assign_end(graph, ident)
			} else {
				provider_field_assign_end(graph, target)
			}
			if root := provider_place_root(graph, target); root != INVALID_SYMBOL && value != nil {
				prov_merge_moved_bits(graph, root, prov_input_value(graph, value))
			}
		}
		if ident, is_ident := target.(^Expr_Ident); is_ident && s.op == .Assign {
			if value != nil && type_is_region_provider(graph.k.c, target_type) {
				// A provider's own region stays its token; the new value's parent joins
				// the parents it depends on.
				prov_merge_provider_parent(graph, ident.symbol, prov_input_value(graph, value), source, storage = !s.destructure.active && type_is_carrier(graph.k.c, target_type))
			} else if value != nil &&
			   (type_underlying(graph.k.c, target_type) == TYPE_ALLOCATOR || type_is_managed(graph.k.c, target_type) ||
			    prov_type_has_region(graph.k.c, target_type)) {
				if !type_is_carrier(graph.k.c, target_type) && type_underlying(graph.k.c, target_type) != TYPE_ALLOCATOR {
					prov_define_value_regions(graph, prov_root_for_symbol(graph, ident.symbol), nil, prov_input_value(graph, value), source, copies, ident.symbol)
				} else {
					prov_assign_value_region(graph, ident.symbol, prov_input_value(graph, value), source, storage = !s.destructure.active && type_is_carrier(graph.k.c, target_type))
				}
			}
			prov_note_written_alias(graph, ident.symbol, value)
			prov_retain_escape(graph, target, sources, expr_span(target))
			// The old value is dropped here.
			prov_drop_use(graph, ident.symbol, expr_span(target))
			prov_invalidate(graph, target, expr_span(target), "assigned")
			if slot, is_carrier := prov_slot_for_symbol(graph, ident.symbol); is_carrier {
				prov_define_one_content(graph, slot, sources, expr_span(target))
			} else if content := prov_content_slots(graph, ident.symbol); len(content) > 0 {
				prov_define_content(graph, content, sources, expr_span(target))
			}
			continue
		}
		prov_retain_escape(graph, target, sources, expr_span(target))
		root, path, place_ok := prov_place_of(graph, target)
		if place_ok && s.op == .Assign {
			prov_note_written_alias(graph, graph.roots[int(root)].symbol, value, path, target_type)
		}
		if !place_ok && s.op == .Assign {
			// A store through a carrier, or into what an `inout` result names.
			// design.md "Weakening and reborrows": the store reads each carrier
			// it goes through, so one read out of another, as `p^^.a` in
			// `p^^.a^.value = 3`, uses what a copy of it, as `node := p^^.a`,
			// suspends.
			through, below, reached := prov_read_through_carrier(graph, target, store = true)
			walked := false
			if !reached {
				through, walked = prov_inout_result_place(graph, target)
			}
			if reached && len(through) == 0 {
				prov_walk_subscripts(graph, target, true)
				continue
			}
			if len(through) > 0 || walked {
				if !walked {
					prov_write_through(graph, through, below, expr_span(target), "write")
				}
				prov_store_region(graph, prov_input_value(graph, target), prov_input_value(graph, value))
				if !walked {
					prov_walk_subscripts(graph, target, true)
				}
				// design.md "Weakening and reborrows".
				if len(through) > 0 {
					stored := prov_type(graph, target)
					if len(sources) > 0 {
						prov_reborrow(graph, sources, stored, span = expr_span(target), copies = true)
						// Which storage `target` names is known only to the solve, so the
						// carrier reborrows every named slot of its type, and every slot
						// standing for one caller storage that may hold it; one stays
						// suspended only while it holds the source's loan.
						for entry, candidate in graph.prov_slots {
							if entry.symbol != INVALID_SYMBOL && entry.content_type == stored ||
							   entry.caller_one && (entry.content_type == stored || entry.content_type == INVALID_TYPE) {
								prov_reborrow(graph, sources, stored, candidate, expr_span(target))
							}
						}
					}
					publish := Prov_Event {
						kind = .Publish, span = expr_span(target), sources = sources, into = through,
						linked = type_is_carrier(graph.k.c, stored),
					}
					// design.md "Values that contain borrows": carriers pointing at
					// one place replace what it holds wherever they name one storage
					// (`publish_into_loan`).
					if offsets, found := prov_value_offset(graph, through); found && len(offsets) == 1 &&
					   prov_offsets_agree(graph, through, offsets) && prov_path_names_one_place(offsets[0]) &&
					   prov_path_names_one_place(below) {
						publish.path, publish.stored = prov_concat_path(graph, offsets[0], below), stored
						graph.has_replacing_store = true
					}
					if len(sources) > 0 || publish.stored != INVALID_TYPE {
						prov_emit(graph, publish)
					}
				}
				if walked {
					prov_emit(graph, Prov_Event{kind = .Live, sources = through, span = expr_span(target)})
					prov_reach(graph, through, expr_span(target))
				}
				continue
			}
		}
		if place_ok {
			// As for a whole local: a record holding only handles keeps their
			// regions too (design.md "Allocator regions and region provenance").
			if value != nil && s.op == .Assign &&
			   (type_is_managed(graph.k.c, target_type) || type_underlying(graph.k.c, target_type) == TYPE_ALLOCATOR ||
			    prov_type_has_region(graph.k.c, target_type) && !type_is_carrier(graph.k.c, target_type)) {
				prov_define_value_regions(graph, root, path, prov_input_value(graph, value), source, copies, place_root_symbol(target))
			}
			prov_walk_subscripts(graph, target, s.op == .Assign)
			prov_access(graph, root, path, .Write, expr_span(target))
			if written := prov_content_at(graph, root, path); len(written) > 0 && s.op == .Assign {
				prov_define_content(graph, written, sources, expr_span(target), path, prov_type(graph, target))
			}
			continue
		}
		walk_flow_expr(graph, target)
		if !place_ok && s.op != .Assign {
			prov_write_through_place(graph, target, expr_span(target))
		}
	}
}

// design.md "Operator declarations": a user operator is a call to the procedure
// it resolved to, its operands bound in parameter order. Each operator node keeps
// one call node, so a later region or place query finds that call's result. The
// call yields the procedure's result, beneath any implicit conversion of the
// node: an erased `[dynamic]T` result still depends on its allocator.
@(private)
prov_operator_call :: proc(graph: ^Flow_Graph, e: Expr) -> ^Expr_Call {
	if call, found := graph.operator_calls[rawptr(expr_base(e))]; found {
		return call
	}
	bound: []Expr
	indexes := false
	#partial switch v in e {
	case ^Expr_Index:
		bound, indexes = v.bound, true
	case ^Expr_Slice:
		bound, indexes = v.bound, true
	case ^Expr_Binary:
		bound = make([]Expr, 2, graph.alloc)
		bound[0], bound[1] = v.lhs, v.rhs
	case ^Expr_Unary:
		bound = make([]Expr, 1, graph.alloc)
		bound[0] = v.operand
	}
	base := expr_base(e)
	call := prov_synthetic_call(graph, base.resolution.chosen_overload, bound, prov_unconverted_type(e), base.span, indexes)
	graph.operator_calls[rawptr(base)] = call
	return call
}

// A call to `callee` that no `Expr_Call` spells: a user operator, a compound
// assignment's, or `operator([]=)`. An indexing receiver is borrowed after its
// operands, as a built-in container is, so `x[x.len() - 1]` and the `len()` an
// omitted endpoint reads are not uses under the receiver's own borrow; an
// operand's borrow that outlives it still conflicts at the call.
@(private)
prov_synthetic_call :: proc(
	graph: ^Flow_Graph, callee: Symbol_Id, bound: []Expr, type: Type_Id, span: Span, indexes := false,
) -> ^Expr_Call {
	key := Prov_Synthetic_Call_Key{callee, type, span, graph.expansion, indexes}
	cached := graph.effect_program != nil
	if cached {
		if call, found := graph.input.synthetic_calls[key]; found { return call }
		prov_writable_input(graph)
	}
	allocator := graph.effect_program != nil ? graph.effect_program.alloc : graph.alloc
	call := new(Expr_Call, allocator)
	call.span = span
	call.type = type
	call.bound = slice.clone(bound, allocator)
	call.resolution = Resolution{kind = .User_Operator, symbol = callee, chosen_overload = callee}
	call.operation = Call_Procedure{}
	if indexes && len(bound) > 1 {
		call.bound_order = make([]int, len(bound), allocator)
		for index in 1 ..< len(bound) {
			call.bound_order[index - 1] = index
		}
		call.bound_order[len(bound) - 1] = 0
	}
	if cached { graph.input.synthetic_calls[key] = call }
	return call
}

// The call an expression makes, if it is one: a spelled call or a user operator.
@(private = "file")
prov_call_node :: proc(graph: ^Flow_Graph, e: Expr) -> ^Expr_Call {
	#partial switch v in e {
	case ^Expr_Call:
		return v.dispatch == nil ? v : nil
	case ^Expr_Index, ^Expr_Slice, ^Expr_Binary, ^Expr_Unary:
		if expr_base(e).resolution.kind == .User_Operator {
			return prov_operator_call(graph, e)
		}
	}
	return nil
}

// design.md "`inout` results": walks a call whose result is `inout` and returns
// the place that result names, which its `inout` arguments borrow.
@(private = "file")
prov_inout_result_place :: proc(graph: ^Flow_Graph, e: Expr) -> ([]int, bool) {
	call := prov_call_node(graph, e)
	if call == nil || !prov_result_is_inout(graph, call) {
		return nil, false
	}
	walk_flow_expr(graph, e)
	return graph.call_results[call].place, true
}

// The procedure type a call goes through: the chosen overload's, or the callee
// value's for an indirect call, which is where `@(escape=...)` matters most.
@(private)
call_proc_type :: proc(c: ^Compiler, v: ^Expr_Call) -> Type_Id {
	if sym := symbol_of(c, v.resolution.chosen_overload); sym != nil {
		return sym.proc_type
	}
	if base := expr_base(v.callee); base != nil {
		return base.type
	}
	return INVALID_TYPE
}

// The loans of every argument not marked `@(escape=none)`.
@(private = "file")
prov_escaping_actuals :: proc(graph: ^Flow_Graph, v: ^Expr_Call, actuals: [][]int) -> []int {
	proc_type := call_proc_type(graph.k.c, v)
	out: []int
	for slots, index in actuals {
		if proc_param_escape(graph.k.c, proc_type, index) == .None {
			continue
		}
		out = prov_join(graph, out, prov_with_content(graph, slots, v.span))
	}
	return out
}

// What is stored behind `carriers`, `from` loads down and at every depth below:
// what a callee may hand back or keep from the storage an argument reaches.
// `path` narrows the first load to one place in what `carriers` name.
@(private)
prov_load_deep :: proc(graph: ^Flow_Graph, carriers: []int, span: Span, from := 1, path: []Proj_Step = nil) -> []int {
	if len(carriers) == 0 {
		return nil
	}
	graph.has_content_load = true
	through := carriers
	for depth in 1 ..= from {
		slot := prov_temp_slot(graph)
		prov_emit(graph, Prov_Event{
			kind = .Load, slot = slot, into = through, path = depth == 1 ? path : nil, deep = depth == from, span = span,
		})
		through = prov_one(graph, slot)
	}
	return through
}

// Where a write through `carriers` may land at any depth: the storage each
// mutable carrier below them names, reached through mutable carriers and
// through read-only ones whose pointee still reaches a destination, so
// `view: ^int` beside a recursive `next: ^mut Node` names no destination.
prov_load_writable :: proc(graph: ^Flow_Graph, carriers: []int, span: Span) -> []int {
	if len(carriers) == 0 {
		return nil
	}
	graph.has_content_load = true
	slot := prov_temp_slot(graph)
	prov_emit(graph, Prov_Event{kind = .Load, slot = slot, into = carriers, deep = true, writable = true, span = span})
	return prov_one(graph, slot)
}

// An argument and everything it reaches, for a callee with no summary to say
// which of the two it hands back or keeps.
@(private = "file")
prov_with_content :: proc(graph: ^Flow_Graph, slots: []int, span: Span) -> []int {
	return prov_join(graph, slots, prov_load_deep(graph, slots, span))
}

// Whether an argument names the caller's storage. A receiver answers with its
// declared mode: a provider handle takes a managed receiver by value.
@(private = "file")
prov_argument_borrows_caller :: proc(
	graph: ^Flow_Graph,
	v: ^Expr_Call,
	index: int,
	receiver: Param_Mode,
	has_receiver: bool,
) -> bool {
	if index == 0 && has_receiver {
		return receiver == .Borrow
	}
	c := graph.k.c
	return param_borrows_caller_storage(
		c,
		proc_parameter_mode(c, call_proc_type(graph.k.c, v), index),
		prov_parameter_type(graph, v, index),
	)
}

// A call dispatching through the `dyn` view it takes as its receiver: a slot
// call, or a view's forwarding member.
@(private)
prov_dispatches_on_view :: proc(c: ^Compiler, v: ^Expr_Call) -> bool {
	if _, slot := v.operation.(Call_Dyn_Slot); slot {
		return true
	}
	sym := symbol_of(c, v.resolution.symbol)
	return sym != nil && sym.synth == .Dyn_Forward
}

@(private)
prov_parameter_type :: proc(graph: ^Flow_Graph, v: ^Expr_Call, index: int) -> Type_Id {
	input := prov_input_call(graph, v)
	return index < len(input.arguments) ? input.arguments[index].type : INVALID_TYPE
}

prov_has_direct_body :: proc(c: ^Compiler, id: Symbol_Id) -> bool {
	if is_contract_join(c, id) {
		for member in symbol_of(c, id).members {
			if !prov_has_direct_body(c, member) {
				return false
			}
		}
		return true
	}
	sym := symbol_of(c, id)
	if sym == nil || sym.kind != .Proc {
		return false
	}
	if sym.proc_literal != nil {
		return sym.proc_literal.body != nil
	}
	if literal := sym.decl != nil ? decl_proc(sym.decl) : nil; literal != nil {
		return literal.body != nil
	}
	// A hook member's declaration is not a procedure declaration; the
	// checked-body registry is authoritative for it.
	return c.checked_body_symbols[id]
}

@(private = "file")
prov_result_is_inout :: proc(graph: ^Flow_Graph, v: ^Expr_Call) -> bool {
	return prov_input_call(graph, v).result_inout
}

@(private = "file")
prov_argument_is_inout :: proc(graph: ^Flow_Graph, v: ^Expr_Call, index: int) -> bool {
	input := prov_input_call(graph, v)
	return index < len(input.arguments) && input.arguments[index].mode == .Inout
}

@(private)
prov_call :: proc(graph: ^Flow_Graph, v: ^Expr_Call) -> []int {
	c := graph.k.c
	input := prov_input_call(graph, v)
	defer prov_call_written_aliases(graph, prov_input_value(graph, v))
	held := len(graph.held_owners)
	defer resize(&graph.held_owners, held)
	// A spawned call's arguments are copied for its task, which runs it.
	graph.task_effects = v == graph.spawning && !c.thread_facts_pending
	prov_event(graph, Prov_Event_Call_Allocator_Use{v})
	graph.task_effects = false
	#partial switch _ in v.operation {
	case Call_Text, Call_Text_Conversion:
		return prov_text_call(graph, v)
	case Call_Conversion:
		// design.md "any_view type", "Borrowed callable views": `any_view(value)`
		// and a `dyn proc` conversion are the implicit conversion written out.
		// The operand is erased and is the result, so it borrows what it views
		// as at a typed destination.
		if operand, erasing := explicit_erasure_operand(v); erasing {
			return walk_flow_expr(graph, operand)
		}
	}
	if result, handled := prov_builtin_call(graph, v); handled {
		return result
	}
	if call_provider_op(c, v) == .Handle && len(v.bound) > 0 {
		// design.md "Allocators": the control block follows the region's
		// lifecycle, independently of its movable owner's inline storage.
		receiver := v.bound[0]
		held := walk_flow_expr(graph, receiver)
		receiver_value := prov_input_value(graph, receiver)
		region, _ := prov_handle_region(graph, v, receiver_value)
		// Querying a policy does not evaluate it. Only this walk creates a
		// provider whose lifetime ends with the statement (design.md "Allocators").
		if prov_expr_is_temporary(receiver) && region.locals != 0 {
			append(&graph.temp_providers, Temp_Provider{bit = region.locals, span = expr_span(receiver)})
		}
		root: Root_Id
		if place, path, ok := prov_place_of(graph, receiver); ok {
			provider := graph.roots[int(place)]
			if provider.kind == .Local {
				root = prov_new_root(graph, .Provider, expr_span(receiver), "this allocator control block")
				graph.roots[int(root)].region = region
				// A named provider's region is a carried fact, settled later; one in
				// a record is its position's token, from the walk.
				if _, named := receiver.(^Expr_Ident); named && graph.effect_program != nil {
					append(&graph.effect_program.root_regions, Prov_Root_Region{root, v, receiver_value})
				}
			} else {
				return prov_join(graph, held, prov_borrow(graph, place, path, false, v.span, "allocator handle"))
			}
		} else if prov_expr_is_temporary(receiver) {
			root = prov_temp_root(graph, expr_span(receiver))
		} else {
			return held
		}
		return prov_join(graph, held, prov_borrow(graph, root, nil, false, v.span, "allocator handle"))
	}
	#partial switch call_provider_op(c, v) {
	case .Open, .Try_Open, .Open_Fixed:
		held: []int
		for argument in v.bound {
			if argument != nil { held = prov_join(graph, held, walk_flow_expr(graph, argument)) }
		}
		return prov_value_content(graph, held, prov_type(graph, v), v.span)
	}
	receiver, has_receiver, container_op := input.receiver, input.has_receiver, input.container
	callee: []int
	if !call_receiver_is_bound(c, v) {
		// A procedure the call names is not used as a value; one an
		// immediately called literal or other expression evaluates is.
		if !call_through_value(c, v) {
			graph.callee_expr = v.callee
		}
		callee = walk_flow_expr(graph, v.callee)
	}
	// design.md "Spawn statements": a procedure value a task calls is evaluated
	// on the parent, before the arguments, and held with them until the join.
	if v == graph.spawning && input.callee != 0 {
		graph.spawn_held = callee
	}
	if len(v.bound) == 0 {
		actuals := make([][]int, max(len(v.args), 1), graph.alloc)
		borrowed: []int
		for argument, index in v.args {
			actuals[index] = walk_flow_expr(graph, argument.value)
			prov_hold_owner(graph, argument.value)
			borrowed = prov_join(graph, borrowed, actuals[index])
		}
		spawned := v == graph.spawning && !graph.k.c.thread_facts_pending
		if !spawned {
			prov_reach_call(graph, callee, actuals, v.span)
		}
		// The reset precedes the boundary use, so the actuals are live at it.
		prov_call_resets(graph, v)
		graph.task_effects = spawned
		prov_call_effects(graph, v)
		graph.task_effects = false
		if len(borrowed) > 0 {
			prov_emit(graph, Prov_Event{kind = .Live, sources = borrowed, span = v.span})
		}
		return prov_store_call_results(graph, v, actuals)
	}
	actuals := make([][]int, len(v.bound), graph.alloc)
	borrowed: []int
	// Evaluation order, not parameter order: a named argument written first
	// borrows before a later one invalidates.
	split_receiver: []int
	split_value: Value_Id
	for index in input.order {
		if index == 0 && prov_op_lends_receiver(container_op) && v.bound[0] != nil {
			split_receiver = walk_flow_expr(graph, v.bound[0])
			split_value = input.capture
			graph.captured_values[split_value] = prov_snapshot(graph, split_receiver, expr_span(v.bound[0]))
			continue
		}
		actuals[index] = prov_call_argument(graph, v, index, receiver, has_receiver, container_op, &borrowed)
		prov_hold_owner(graph, v.bound[index])
	}
	if prov_op_lends_receiver(container_op) && len(v.bound) > 0 && v.bound[0] != nil {
		actuals[0] = prov_lend_split_receiver(graph, split_receiver, graph.captured_values[split_value], expr_span(v.bound[0]))
		borrowed = prov_join(graph, borrowed, actuals[0])
	}
	// A spawned call runs on its task, whose reach and effects its start
	// checks; the parent only prepares the arguments.
	spawned := v == graph.spawning && !graph.k.c.thread_facts_pending
	if !spawned {
		prov_reach_call(graph, callee, actuals, v.span)
	}
	// A moved argument now belongs to the callee, which checks its own resets
	// against that parameter's lifetime. Value arguments remain caller-owned
	// until the call returns (design.md "Parameter semantics and ABI lowering").
	resize(&graph.held_owners, held)
	for argument, index in v.bound {
		mode := proc_parameter_mode(c, call_proc_type(c, v), index)
		if index == 0 && has_receiver { mode = receiver }
		if mode != .Move { prov_hold_owner(graph, argument) }
	}
	prov_call_resets(graph, v)
	prov_call_cross_thread(graph, v)
	prov_call_retention(graph, v, actuals)
	graph.task_effects = spawned
	prov_call_effects(graph, v)
	prov_argument_drop_effects(graph, v)
	graph.task_effects = false
	if len(borrowed) > 0 {
		prov_emit(graph, Prov_Event{kind = .Live, sources = borrowed, span = v.span})
	}
	// What the container stores reborrows the arguments, so it is stored after
	// their use in the call: the operation's own read of an argument is not a
	// use of it while the stored copy lives.
	prov_container_content(graph, v, container_op, actuals)
	if v == graph.spawning {
		graph.spawn_held = prov_join(graph, graph.spawn_held, borrowed)
		for actual in actuals {
			graph.spawn_held = prov_join(graph, graph.spawn_held, actual)
		}
	}
	return prov_store_call_results(graph, v, actuals)
}

// design.md "Task borrows and the join": a spawn is checked as
// a call whose duration extends to the join. What its arguments lend and
// carry, and the result local it reserves, are held by the block's hidden
// scope from here on, so its drop at the join is a use of every loan. The
// result takes the call's provenance as an assignment would, with no access:
// the parent cannot reach it before the join.
@(private)
prov_spawn :: proc(graph: ^Flow_Graph, s: ^Stmt_Spawn) {
	call, is_call := s.call.(^Expr_Call)
	if !is_call {
		return
	}
	outer, outer_held, outer_owned, outer_pooled := graph.spawning, graph.spawn_held, graph.spawn_owned, graph.spawning_pooled
	graph.spawning, graph.spawn_held, graph.spawn_owned = call, nil, nil
	graph.spawning_pooled = s.task != nil && s.task.pooled
	graph.task_reserve = {}
	result := walk_flow_expr(graph, call)
	kept := make([dynamic]int, 0, len(graph.spawn_held), graph.alloc)
	for slot in graph.spawn_held {
		if !slice.contains(graph.spawn_owned, slot) {
			append(&kept, slot)
		}
	}
	held := kept[:]
	graph.spawning, graph.spawn_held, graph.spawn_owned, graph.spawning_pooled = outer, outer_held, outer_owned, outer_pooled
	task := s.task
	if task == nil {
		return
	}
	prov_spawn_transfers(graph, s, call, held, result)
	if s.result != nil {
		prov_store_region(graph, prov_input_value(graph, s.result), prov_input_value(graph, call))
		prov_store_loans(graph, s.result, result, call.span)
		if root, path, ok := prov_place_of(graph, s.result); ok {
			held = prov_join(graph, held, prov_borrow(graph, root, path, true, s.result.span, "task result"))
		}
	}
	// The task runs from here: what it reaches, and what the parent does
	// until the join, are checked against the globals (design.md "Globals while
	// tasks run").
	runs := spawn_runs(graph, s)
	graph.has_window_event = true
	if graph.task_sites == nil {
		graph.task_sites = make([dynamic]Task_Site, 0, 2, graph.alloc)
	}
	append(&graph.task_sites, Task_Site{block = prov_window_bit(graph, task.scope), reserve = graph.task_reserve, span = s.span, call = call})
	prov_emit(graph, Prov_Event{
		kind = .Task_Start, slot = len(graph.task_sites) - 1, symbol = runs, sources = held, span = s.span,
		name = spawn_callee_name(graph.k.c, call),
	})
	slot, found := graph.task_slots[task.scope]
	hold, has_hold := graph.spawn_holds[s]
	if !found || !has_hold {
		return // registered by `prov_enter_parallel` unless its block failed to lower
	}
	join := s.span
	if scope := symbol_of(graph.k.c, task.scope); scope != nil {
		join = scope.span
	}
	prov_hold_until_join(graph, slot, held, s.span, join)
	prov_spawn_reborrows(graph, hold, held, s.span, join)
}

// The procedure a spawn's task runs: its `run` wrapper, or the declared
// callee when the effect analysis has no body for the wrapper.
@(private = "file")
spawn_runs :: proc(graph: ^Flow_Graph, s: ^Stmt_Spawn) -> Symbol_Id {
	callee := s.call.(^Expr_Call).resolution.symbol
	sym := symbol_of(graph.k.c, callee)
	if s.task.run in graph.k.c.effect_program.index_of || s.task.through_value || sym == nil || sym.synth != .None {
		return s.task.run
	}
	return callee
}

// design.md "Task borrows and the join": every exit of a `parallel` block
// joins its tasks, including an exit the walk reaches before a spawn that a
// loop's back edge runs earlier. So the slot of what the block's tasks lend,
// each spawn site's reborrow slot, and a pooled block's tasks are registered
// as the block is entered, before the walk reaches any exit.
@(private)
prov_enter_parallel :: proc(graph: ^Flow_Graph, s: ^Stmt_Parallel) {
	if len(s.spawns) == 0 {
		return
	}
	prov_window_bit(graph, s.scope)
	if graph.task_slots == nil {
		graph.task_slots = make(map[Symbol_Id]int, 4, graph.alloc)
		graph.task_holds = make(map[Symbol_Id][dynamic]int, 4, graph.alloc)
		graph.spawn_holds = make(map[^Stmt_Spawn]int, 4, graph.alloc)
	}
	graph.task_slots[s.scope] = prov_temp_slot(graph)
	holds := make([dynamic]int, 0, len(s.spawns), graph.alloc)
	tasks: [dynamic]Pool_Task
	for spawn in s.spawns {
		hold := prov_temp_slot(graph)
		append(&holds, hold)
		graph.spawn_holds[spawn] = hold
		if spawn.task.pooled {
			if tasks == nil {
				tasks = make([dynamic]Pool_Task, 0, len(s.spawns), graph.alloc)
			}
			append(&tasks, Pool_Task{runs = spawn_runs(graph, spawn), name = spawn_callee_name(graph.k.c, spawn.call.(^Expr_Call))})
		}
	}
	graph.task_holds[s.scope] = holds
	if tasks != nil {
		if graph.pool_tasks == nil {
			graph.pool_tasks = make(map[Symbol_Id][dynamic]Pool_Task, 2, graph.alloc)
		}
		graph.pool_tasks[s.scope] = tasks
	}
}

// Adds what a task holds to `slot`. Earlier tasks, of another spawn or of this
// one on an earlier iteration, still hold theirs through this spawn's own
// accesses: a redefinition alone is not a use of what it keeps, so the slot is
// used first, at the join, which is what holds it.
@(private = "file")
prov_hold_until_join :: proc(graph: ^Flow_Graph, slot: int, held: []int, span, join: Span) {
	prov_emit(graph, Prov_Event{kind = .Live, sources = prov_one(graph, slot), span = join})
	prov_emit(graph, Prov_Event{kind = .Def, slot = slot, loan = NO_LOAN, sources = prov_join(graph, prov_one(graph, slot), held), span = span})
}

// design.md "Task borrows and the join": a mutable carrier the spawned call
// reborrows stays reborrowed until the join, so the carrier it came from is
// suspended until then, and `spawn add(view); spawn add(view);` uses `view`
// while the first task holds it. The hold is the spawn site's own, so the next
// spawn's argument is not mistaken for what an earlier task holds, and a loop's
// chunk binding, fresh on each step, may be lent again on the next.
@(private = "file")
prov_spawn_reborrows :: proc(graph: ^Flow_Graph, hold: int, held: []int, span, join: Span) {
	reborrows := false
	existing := len(graph.reborrows)
	for lent in held {
		for index in 0 ..< existing {
			reborrow := graph.reborrows[index]
			if reborrow.derived != lent || !reborrow.mutable {
				continue
			}
			reborrows = true
			append(&graph.reborrows, Prov_Reborrow{source = reborrow.source, derived = hold, span = span, mutable = true})
		}
	}
	if reborrows {
		prov_hold_until_join(graph, hold, held, span, join)
	}
}

// A `parallel` block's index, in the order the walk enters it.
@(private)
prov_window_bit :: proc(graph: ^Flow_Graph, scope: Symbol_Id) -> int {
	for existing, index in graph.parallel_scopes {
		if existing == scope {
			return index
		}
	}
	if graph.parallel_scopes == nil {
		graph.parallel_scopes = make([dynamic]Symbol_Id, 0, 2, graph.alloc)
	}
	append(&graph.parallel_scopes, scope)
	return len(graph.parallel_scopes) - 1
}

// The calls with provenance rules of their own: a shared constructor and the
// builtins. `handled` is false for every other call.
@(private = "file")
prov_builtin_call :: proc(graph: ^Flow_Graph, v: ^Expr_Call) -> (result: []int, handled: bool) {
	c := graph.k.c
	// design.md "Shared ownership": the payload's borrows land below the
	// handle's one step, as for a box; the library body hides them in a `rawptr`.
	if payload, fallible := shared_constructor_payload(c, v); payload != nil {
		loans := walk_flow_expr(graph, payload)
		prov_hold_owner(graph, payload)
		for argument in v.bound[1:] {
			if argument != nil {
				walk_flow_expr(graph, argument)
			}
		}
		depth := fallible ? 2 : 1
		content := prov_temp_content(graph, prov_type(graph, v))
		for slot in content {
			path := graph.prov_slots[slot].path
			suffix := path[min(depth, len(path)):]
			prov_define_one_content(graph, slot, prov_select_content(graph, loans, prov_type(graph, payload), suffix), v.span)
		}
		return content, true
	}
	if sym := symbol_of(c, v.resolution.symbol); sym != nil && sym.kind == .Builtin {
		#partial switch sym.builtin {
		case .Fmt_Format_View:
			// The interface view borrows exactly what the erased input borrows.
			return walk_flow_expr(graph, v.bound[0]), true
		case .Box_New, .Try_Box:
			// design.md "Owned values": the payload's borrows land below the box's
			// one step, path by path, so a box keeps its fields apart as a record
			// does. The allocator is only read. A call that failed to check bound
			// nothing.
			if len(v.bound) == 0 {
				return nil, true
			}
			loans := walk_flow_expr(graph, v.bound[0])
			prov_hold_owner(graph, v.bound[0])
			if len(v.bound) > 1 {
				walk_flow_expr(graph, v.bound[1])
			}
			allocation := v.operation.(Call_Allocation)
			depth := allocation.fallible ? 2 : 1
			content := prov_temp_content(graph, prov_type(graph, v))
			for slot in content {
				path := graph.prov_slots[slot].path
				suffix := path[min(depth, len(path)):]
				prov_define_one_content(graph, slot, prov_select_content(graph, loans, allocation.type, suffix), v.span)
			}
			return content, true
		case .Default_Allocator:
			return prov_synthetic_borrow(graph, v, .Static, TYPE_ALLOCATOR), true
		case .Unsafe_Free:
			// design.md "What is not checked": the operands are only read.
			for bound in v.bound {
				walk_flow_expr(graph, bound)
			}
			return nil, true
		case .Free_All:
			if len(v.bound) >= 1 {
				allocator := prov_input_value(graph, v.bound[0])
				walk_flow_expr(graph, v.bound[0])
				prov_event(graph, Prov_Event_Allocator_Use{allocator, v.span, false})
				prov_reset(graph, allocator, v.span, true, v)
			}
			return nil, true
		case .Drop:
			if len(v.bound) == 1 {
				provider_drop_end(graph, v)
				prov_drop_effects(graph, prov_type(graph, v.bound[0]), v.span, region = prov_drop_region(graph, v.bound[0]))
				if ident, is_ident := v.bound[0].(^Expr_Ident); is_ident {
					prov_drop_use(graph, ident.symbol, v.span)
					prov_clear_content(graph, ident.symbol, v.span)
				}
				prov_invalidate(graph, v.bound[0], v.span, "dropped")
			}
			return nil, true
		case .Exchange:
			if len(v.bound) == 2 {
				provider_exchange_end(graph, v)
				// `old := x; x = value; return old`, for loans as for regions.
				type := prov_type(graph, v.bound[0])
				old := prov_project_content(graph, walk_flow_expr(graph, v.bound[0]), type, nil, type, v.span)
				prov_invalidate(graph, v.bound[0], v.span, "exchanged")
				sources := walk_flow_expr(graph, v.bound[1])
				prov_store_region(graph, prov_input_value(graph, v.bound[0]), prov_input_value(graph, v.bound[1]))
				prov_store_loans(graph, v.bound[0], sources, v.span)
				return old, true
			}
			return nil, true
		case .Atomic_Load, .Atomic_Store, .Atomic_Exchange, .Atomic_Compare_Exchange,
		     .Atomic_Add, .Atomic_Sub, .Atomic_And, .Atomic_Or, .Atomic_Xor, .Atomic_Fence:
			// An atomic returns the stored value, not a borrow of its address, or an
			// `Atomic(^T)` could never load.
			for argument in v.bound {
				if argument != nil {
					walk_flow_expr(graph, argument)
				}
			}
			return nil, true
		case .Unsafe_Take:
			// design.md "The `unsafe` package": the value is read out, and keeps
			// what it borrows.
			if len(v.bound) == 1 {
				type := prov_type(graph, v.bound[0])
				taken := prov_project_content(graph, walk_flow_expr(graph, v.bound[0]), type, nil, type, v.span)
				prov_invalidate(graph, v.bound[0], v.span, "taken")
				return taken, true
			}
			return nil, true
		case .Unsafe_Write:
			// Stored the way an initialization takes it, loans and region alike.
			if len(v.bound) == 2 {
				prov_invalidate(graph, v.bound[0], v.span, "overwritten")
				sources := walk_flow_expr(graph, v.bound[1])
				prov_store_region(graph, prov_input_value(graph, v.bound[0]), prov_input_value(graph, v.bound[1]))
				prov_store_loans(graph, v.bound[0], sources, v.span)
			}
			return nil, true
		case .Unsafe_Forget:
			if len(v.bound) == 1 {
				// A borrow of the forgotten value dies here, as at a `drop`.
				prov_consume(graph, v.bound[0], v.span, "forgotten")
			}
			return nil, true
		}
	}
	return nil, false
}

// One argument of `v`, in slot `index`: what it lends to the call. Loans that
// must stay live through the call are added to `borrowed`.
@(private = "file")
prov_call_argument :: proc(
	graph: ^Flow_Graph,
	v: ^Expr_Call,
	index: int,
	receiver: Param_Mode,
	has_receiver: bool,
	container_op: Container_Op,
	borrowed: ^[]int,
) -> (actual: []int) {
	c := graph.k.c
	argument := v.bound[index]
	// design.md "Variadic parameters": the pack slot holds no written
	// expression unless a sole spread is forwarded.
	// Each operand lends as one argument of its type would: an element as the
	// pack's element, a spread as the slice it views. A mutable carrier passed
	// by name is reborrowed, so `fill(out, out)` uses `out` while it is lent.
	if call_packs(v, index) {
		pack := prov_parameter_type(graph, v, index)
		element := slice_element(c, pack)
		next_element, next_spread := 0, 0
		for is_spread in v.variadic_order {
			operand: Expr
			type := element
			if is_spread {
				operand, type = v.variadic_spreads[next_spread], pack
				next_spread += 1
			} else {
				operand = v.variadic_elements[next_element]
				next_element += 1
			}
			lent := walk_flow_expr(graph, operand)
			prov_reborrow(graph, lent, type)
			if type_carries_borrow(c, type).mutable {
				lent = prov_lend_carrier(graph, lent, borrowed^, expr_span(operand))
			} else if type_is_carrier(c, type) {
				lent = prov_reborrow_traversal(graph, lent, expr_span(operand), false)
			}
			borrowed^ = prov_join(graph, borrowed^, lent)
			actual = prov_join(graph, actual, lent)
		}
		return actual
	}
	if argument == nil {
		return actual
	}
	if index == 0 && receiver == .Move {
		actual = prov_consume(graph, argument, expr_span(argument), "moved")
		borrowed^ = prov_join(graph, borrowed^, actual)
		return actual
	}
	// design.md "`inout` results": an `inout` call result passed on `inout`
	// is the place its own `inout` arguments borrow.
	if prov_argument_is_inout(graph, v, index) {
		if place, is_inout := prov_inout_result_place(graph, argument); is_inout {
			actual = place
			borrowed^ = prov_join(graph, borrowed^, place)
			return actual
		}
	}
	if index == 0 && receiver == .Inout {
		// An `inout` receiver invalidates borrows of it (design.md), and its held
		// borrows stay live through the call, as `iterator.next()` reads its slice.
		borrowed^ = prov_join(graph, borrowed^, prov_carrier_slots(graph, argument))
		prov_invalidate(graph, argument, v.span, "modified")
		// design.md "Borrowing iteration": a result derived from a view the
		// receiver holds names that view's source, not the receiver, so
		// advancing the receiver cannot invalidate an element already handed
		// back. The summary tells the two apart. The two lending synths have no
		// body to summarize, so they are named here; `indexed()` lends only
		// while it wraps a lending source.
		lends := prov_result_reads_through_receiver(c, v, prov_type(graph, v), index)
		if callee := symbol_of(c, v.resolution.chosen_overload); callee != nil {
			lends ||= callee.synth == .Slice_Ref_Next || indexed_next_lends(c, callee)
		}
		if lends {
			actual = prov_carrier_slots(graph, argument)
			return actual
		}
		if root, path, ok := prov_place_of(graph, argument); ok {
			if prov_op_removes_element(container_op) {
				// A removal returns what the element held, not a container borrow.
				actual = prov_content_at(
					graph, root, prov_element_path(graph, v, path, container_op),
				)
			} else {
				actual = prov_join(graph, prov_carrier_slots(graph, argument),
					prov_borrow(graph, root, path, true, expr_span(argument), "borrow"))
			}
			borrowed^ = prov_join(graph, borrowed^, actual)
		}
		return actual
	}
	if index == 0 && prov_op_returns_view(container_op) {
		// design.md "Iteration adapters": a map view read-borrows the map, and
		// also carries what the stored elements borrow.
		held := walk_flow_expr(graph, argument)
		if root, path, ok := prov_place_of(graph, argument); ok {
			prov_access(graph, root, path, .Read, expr_span(argument))
			held = prov_join(
				graph, held, prov_borrow(graph, root, path, false, expr_span(argument), "view"),
			)
		} else if prov_expr_is_temporary(argument) {
			held = prov_join(
				graph, held,
				prov_borrow(graph, prov_temp_root(graph, expr_span(argument)), nil, false, v.span, "view"),
			)
		}
		actual = held
		borrowed^ = prov_join(graph, borrowed^, held)
		return actual
	}
	if prov_argument_is_inout(graph, v, index) {
		if root, path, ok := prov_place_of(graph, argument); ok {
			borrowed^ = prov_join(graph, borrowed^, prov_carrier_slots(graph, argument))
			prov_walk_subscripts(graph, argument)
			prov_access(graph, root, path, .Write, expr_span(argument))
			actual = prov_join(graph, prov_carrier_slots(graph, argument),
				prov_borrow(graph, root, path, true, expr_span(argument), "borrow"))
			borrowed^ = prov_join(graph, borrowed^, actual)
			return actual
		}
		// design.md "Weakening and reborrows": `inout p^` lends what `p` names,
		// as `&mut p^` would, so `p` is suspended for the call.
		if carriers, below, through := prov_read_through_carrier(graph, argument); through {
			prov_write_through(graph, carriers, below, expr_span(argument), "mutable argument")
			actual = prov_lend_carrier(graph, carriers, borrowed^, expr_span(argument))
			borrowed^ = prov_join(graph, borrowed^, actual)
			return actual
		}
	}
	if index == 0 && container_op == .Map_Lookup_Value {
		// `lookup_value` copies the payload, carrying its stored dependencies.
		result_type := prov_type(graph, v)
		entry_step := prov_map_call_step(graph, v)
		if root, path, ok := prov_place_of(graph, argument); ok {
			prov_walk_subscripts(graph, argument)
			prov_access(graph, root, path, .Read, expr_span(argument))
			entry := prov_extend(graph, path, entry_step)
			value := prov_extend(graph, entry, proj_field(PROJ_MAP_VALUE))
			actual = prov_read_content(graph, root, value, result_type, v.span)
		} else {
			receiver := walk_flow_expr(graph, argument)
			entry := prov_extend(graph, nil, entry_step)
			value := prov_extend(graph, entry, proj_field(PROJ_MAP_VALUE))
			actual = prov_project_content(
				graph, receiver, prov_type(graph, argument), value, result_type, v.span,
			)
		}
	} else if prov_argument_borrows_caller(graph, v, index, receiver, has_receiver) {
		// design.md "Receiver forms": a read-only borrow of the caller's value,
		// plus whatever borrows the receiver itself carries.
		callee := symbol_of(c, v.resolution.chosen_overload)
		if ident, plain := prov_plain_slice_local(graph, argument); plain && callee != nil &&
		   (callee.synth == .Standard_Len || callee.synth == .Standard_Cap || callee.synth == .Standard_Hash) {
			// Measuring or hashing only reads, and the plain result keeps nothing.
			prov_read_ident(graph, ident, .Read, reads_only = true)
			return actual
		}
		held := walk_flow_expr(graph, argument)
		if callee != nil && (callee.synth == .Adapter_Iter || callee.synth == .Iterator_Copy ||
		   (callee.synth == .Adapter_View && type_of(c, callee.result).adapter_by_value) ||
		   clone_copies_receiver(c, callee)) {
			actual = held
			borrowed^ = prov_join(graph, borrowed^, held)
			return actual
		}
		loan: []int
		// Walking the argument above already read the place.
		if root, path, ok := prov_place_of(graph, argument); ok && !expression_converts_storage(argument) {
			loan = prov_borrow(graph, root, path, false, expr_span(argument), "borrow")
		} else if carriers, _, through := prov_read_through_carrier(graph, argument, reads_only = true); through {
			// `Type.method(&value)`, or a place behind a pointer. The borrow is
			// read-only, so a mutable carrier is reborrowed read-only for the
			// call, as one passed to a read-only parameter is, which another
			// read-only reborrow of it allows (design.md "Weakening and
			// reborrows").
			loan = prov_reborrow_traversal(graph, carriers, expr_span(argument), false)
		} else if index == 0 && prov_dispatches_on_view(c, v) {
			// design.md "Borrowed dynamic interface values": the slot is given the
			// viewed value, never the view itself, so a temporary view lends only
			// what it views, which walking it gave.
		} else {
			loan = prov_borrow(graph, prov_temp_root(graph, expr_span(argument)), nil, false, v.span, "borrow")
			// design.md "Spawn statements": a spawn's temporary belongs to the
			// task, so only a result borrowing it outlives the statement.
			if v == graph.spawning {
				graph.spawn_owned = prov_join(graph, graph.spawn_owned, loan)
			}
		}
		// A `value: T` callee shares the owner's allocations only for the call
		// (design.md "Parameter semantics and ABI lowering"): the argument stays
		// borrowed until it returns, but the result cannot derive from it.
		if !(index == 0 && has_receiver) && proc_parameter_mode(c, call_proc_type(c, v), index) == .Value {
			borrowed^ = prov_join(graph, borrowed^, loan)
		} else {
			if index == 0 && has_receiver &&
			   type_underlying(c, prov_type(graph, argument)) == type_underlying(c, prov_parameter_type(graph, v, index)) {
				graph.receiver_content[v] = held
			}
			held = prov_join(graph, held, loan)
		}
		actual = held
	} else if !(index == 0 && has_receiver) && prov_argument_only_read(graph, argument, prov_parameter_type(graph, v, index)) {
		// Weakened to a read-only parameter, the carrier is only read, all of
		// what it points to.
		actual = prov_read_carrier(graph, argument, true)
		prov_use_reached(graph, actual, prov_parameter_type(graph, v, index), expr_span(argument))
		prov_read_through(graph, actual, nil, expr_span(argument))
	} else {
		actual = walk_flow_expr(graph, argument)
		reached := -1
		if !(index == 0 && has_receiver) {
			reached = prov_use_reached(graph, actual, prov_parameter_type(graph, v, index), expr_span(argument))
		}
		// A callee given a mutable carrier may write what it names, below where
		// the argument points, as `[count]` for `&mut h^.count` or a record
		// holding it, and through what that holds; a read-only one reads it.
		if type_carries_borrow(c, prov_parameter_type(graph, v, index)).mutable {
			prov_write_through(graph, actual, nil, expr_span(argument), "mutable argument")
			if reached >= 0 {
				prov_write_through(graph, prov_one(graph, reached), nil, expr_span(argument), "mutable argument")
			}
		} else if type_is_carrier(c, prov_parameter_type(graph, v, index)) {
			prov_read_through(graph, actual, nil, expr_span(argument))
		}
	}
	param_type := prov_parameter_type(graph, v, index)
	prov_reborrow(graph, actual, param_type)
	// A mutable carrier passed on as one is reborrowed until the call and what
	// it returns are done with it, so no other argument may use it meanwhile.
	// A record holding one is lent as its carriers are (design.md "Values that
	// contain borrows").
	if type_carries_borrow(c, param_type).mutable && !(index == 0 && has_receiver) {
		actual = prov_lend_carrier(graph, actual, borrowed^, expr_span(argument))
	} else if type_is_carrier(c, param_type) && !(index == 0 && has_receiver) {
		// design.md "Weakening and reborrows": an existing mutable carrier
		// weakened to a read-only parameter is reborrowed for the call, which
		// suspends it while later arguments are evaluated.
		actual = prov_reborrow_traversal(graph, actual, expr_span(argument), false)
	}
	borrowed^ = prov_join(graph, borrowed^, actual)
	return actual
}

// design.md "Weakening and reborrows": a carrier handed to a call lets the
// callee use the carriers stored where it points, so passing `list` uses
// `list^.head`, which a mutable copy of it, as `node := list^.head`, suspends
// until its last use. A read-only carrier lets it only read them.
// The slot the load reads into, or -1 when there is none.
@(private = "file")
prov_use_reached :: proc(graph: ^Flow_Graph, slots: []int, parameter: Type_Id, span: Span) -> int {
	c := graph.k.c
	info := underlying_info(c, parameter)
	if len(slots) == 0 || info == nil || !type_is_carrier(c, parameter) || type_is_region_provider(c, parameter) ||
	   !type_carries_borrow(c, info.element).mutable {
		return -1
	}
	graph.has_content_load = true
	slot := prov_temp_slot(graph)
	prov_emit(graph, Prov_Event {
		kind = .Load, slot = slot, into = slots, deep = true, span = span,
		reads_only = !carrier_is_mutable(c, parameter),
	})
	return slot
}

// design.md "Weakening and reborrows": copying carriers out of storage, named
// or loaded, into `destination` uses all of what they point to, as passing
// them does (`prov_use_reached`), and a `mutable` copy may write it, which a
// place loan of it forbids (design.md "Switch ownership"). Only the carriers
// read out of storage are copied: a borrow taken here is a temporary that
// already accessed the place it is of, as is a call's result, so in
// `&mut other if flag else h` only `h` is, and storing a carrier into
// itself, `into`, copies nothing.
@(private = "file")
prov_use_copied :: proc(graph: ^Flow_Graph, slots: []int, destination: Type_Id, span: Span, mutable: bool, into := -1) {
	copied := make([dynamic]int, 0, len(slots), graph.alloc)
	written := make([dynamic]int, 0, len(slots), graph.alloc)
	for slot in slots {
		entry := graph.prov_slots[slot]
		if slot == into || (entry.symbol == INVALID_SYMBOL && !entry.loaded) {
			continue
		}
		append(&copied, slot)
		if prov_slot_is_mutable_carrier(graph, slot) || prov_slot_is_loaded_mutable(graph, slot) {
			append(&written, slot)
		}
	}
	reached := prov_use_reached(graph, copied[:], destination, span)
	if mutable && len(written) > 0 {
		prov_write_through(graph, written[:], nil, span, "mutable copy")
		if reached >= 0 {
			prov_write_through(graph, prov_one(graph, reached), nil, span, "mutable copy")
		}
	} else if type_is_carrier(graph.k.c, destination) {
		prov_read_through(graph, copied[:], nil, span)
	}
}

// design.md "Global write effects": a temporary lent to a value parameter is
// dropped once the call is done with it, and its drop hooks write what they
// would anywhere. A container operation may keep its element, so it is left
// to the container's own effects.
@(private = "file")
prov_argument_drop_effects :: proc(graph: ^Flow_Graph, v: ^Expr_Call) {
	c := graph.k.c
	if sym := symbol_of(c, v.resolution.chosen_overload); sym != nil && sym.synth == .Container_Op {
		return
	}
	info := underlying_info(c, call_proc_type(c, v))
	if info == nil {
		return
	}
	for argument, index in v.bound {
		if argument == nil || index >= len(info.param_modes) || info.param_modes[index] != .Value ||
		   expression_is_borrowed_place(argument) {
			continue
		}
		prov_drop_effects(graph, prov_type(graph, argument), expr_span(argument), region = prov_drop_region(graph, argument))
	}
}

// What `slots` hold now, in temporaries a later write cannot redefine.
@(private = "file")
prov_snapshot :: proc(graph: ^Flow_Graph, slots: []int, span: Span) -> []int {
	out := make([]int, len(slots), graph.alloc)
	for slot, index in slots {
		out[index] = prov_temp_slot(graph)
		prov_emit(graph, Prov_Event{kind = .Def, slot = out[index], loan = NO_LOAN, sources = prov_one(graph, slot), span = span})
	}
	return out
}

// design.md "Splitting a mutable slice": the receiver is read before `mid` and
// lent after it, so `xs.split_at_mut(xs.len() / 2)` may still read `xs`. The
// value read is what is lent, so the halves stay tied to it even if `mid`
// reassigns `xs`; the reborrow suspends `xs` only while `xs` still views the
// same storage.
@(private = "file")
prov_lend_split_receiver :: proc(graph: ^Flow_Graph, receiver, read: []int, span: Span) -> []int {
	out := make([]int, len(read), graph.alloc)
	for slot, index in read {
		out[index] = prov_temp_slot(graph)
		prov_emit(graph, Prov_Event{kind = .Def, slot = out[index], loan = NO_LOAN, sources = prov_one(graph, slot), span = span})
		if prov_slot_is_mutable_carrier(graph, receiver[index]) {
			append(&graph.reborrows, Prov_Reborrow{source = receiver[index], derived = out[index], span = span, mutable = true})
		}
	}
	return out
}

// design.md "Weakening and reborrows": a mutable carrier lent to a call is
// reborrowed for it. The arguments already evaluated are held through the call,
// so they are used again after the reborrow is taken, which catches one that
// reads through the same carrier.
@(private = "file")
prov_lend_carrier :: proc(graph: ^Flow_Graph, carriers, held: []int, span: Span) -> []int {
	lent := prov_reborrow_traversal(graph, carriers, span, true)
	if len(held) > 0 {
		prov_emit(graph, Prov_Event{kind = .Live, sources = held, span = span})
	}
	return lent
}

// The caller's half of `@(escape=...)`. `static` must outlive the process;
// `stored` is modelled as an assignment into each writable argument, so the loan
// travels and ordinary scope rules handle the rest.
@(private = "file")
prov_call_retention :: proc(graph: ^Flow_Graph, v: ^Expr_Call, actuals: [][]int) {
	proc_type := call_proc_type(graph.k.c, v)
	info := underlying_info(graph.k.c, proc_type)
	if info == nil {
		return
	}
	prov_call_written_regions(graph, prov_input_value(graph, v), proc_type)
	prov_call_thread_local_writes(graph, v, actuals)
	destinations: []int
	for held, index in actuals {
		level := proc_param_escape(graph.k.c, proc_type, index)
		if level >= .Stored && index < len(info.param_modes) && info.param_modes[index] == .Move {
			prov_call_moved_owner(graph, v, index, level)
		}
		if len(held) == 0 || level < .Stored {
			continue
		}
		// The callee may keep what the argument reaches as well as the argument.
		slots := prov_with_content(graph, held, v.span)
		if level == .Static {
			prov_emit(graph, Prov_Event {
				kind    = .Retain,
				span    = v.span,
				sources = slots,
				root    = NO_ROOT,
				retain  = .Process,
				verb    = prov_parameter_label(graph, v, index),
			})
		}
		if destinations == nil {
			destinations = prov_writable_arguments(graph, v, proc_type)
		}
		for target in destinations {
			if target == index {
				prov_retain_into_self(graph, v, index, slots)
			} else {
				prov_retain_into_argument(graph, v, target, actuals[target], slots)
			}
		}
	}
}

// What a `thread_local` borrow a spawned call leaves in an argument is called.
// The spawn reports it from the summary, so the crossing check passes over it;
// one left by any other call crosses no further than a borrow taken directly.
WRITTEN_BACK_BORROW :: "written-back borrow"

// design.md "Borrows crossing between tasks": what the task's call may write
// into an argument stays behind after the worker's thread ends, wherever the
// argument came from, a local or the parent's own caller.
@(private = "file")
report_thread_local_writes :: proc(c: ^Compiler, call: ^Expr_Call, body: Symbol_Id) {
	consulted := make([dynamic]Symbol_Id, 0, 4, context.temp_allocator)
	reported := make([]bool, len(call.bound), context.temp_allocator)
	for left in call_thread_local_left(c, call, body, false, &consulted) {
		if left.global == INVALID_SYMBOL || left.at >= len(call.bound) || reported[left.at] {
			continue
		}
		span, written := prov_argument_span(call, left.at)
		sym := symbol_of(c, left.global)
		if sym == nil || !written {
			continue
		}
		reported[left.at] = true
		errorf(
			c, span, "L0730",
			"this task's call may leave a borrow of `%s` in this argument, but it is the worker's own `thread_local` storage, so it cannot cross to the parent",
			identifier_text(c, sym.name),
		)
		add_notef(c, sym.span, "each thread has its own `thread_local` storage, which ends with that thread")
	}
}

// Where bound argument `index` is written: its expression, or for a variadic
// pack its first operand. False for an empty pack, which nothing is left in.
@(private = "file")
prov_argument_span :: proc(call: ^Expr_Call, index: int) -> (Span, bool) {
	if !call_packs(call, index) {
		argument := call.bound[index]
		return argument == nil ? Span{} : expr_span(argument), argument != nil
	}
	if len(call.variadic_order) == 0 {
		return Span{}, false
	}
	if call.variadic_order[0] {
		return expr_span(call.variadic_spreads[0]), true
	}
	return expr_span(call.variadic_elements[0]), true
}

// design.md "Borrows crossing between tasks": a callee that may leave a borrow
// of a `thread_local` global in an argument leaves it in the caller's storage,
// so a task's call that does is seen to hand it to the parent. While a body is
// summarized, a callback it received leaves its stand-in instead.
@(private = "file")
prov_call_thread_local_writes :: proc(graph: ^Flow_Graph, v: ^Expr_Call, actuals: [][]int) {
	c := graph.k.c
	consulted := make([dynamic]Symbol_Id, 0, 4, context.temp_allocator)
	lefts := call_thread_local_left(c, v, graph.literal.symbol, graph.mode == .Prov_Summary, &consulted)
	for target in consulted {
		prov_note_summary_dependency(graph, target, prov_has_direct_body(c, target))
	}
	what := v == graph.spawning ? WRITTEN_BACK_BORROW : "borrow"
	for left in lefts {
		if left.at >= len(actuals) || (v.bound[left.at] == nil && !call_packs(v, left.at)) {
			continue
		}
		if left.callback != INVALID_SYMBOL {
			stand_in := prov_forwarded_root(graph, left.callback, left.argument, v.span)
			sources := prov_borrow(graph, stand_in, nil, false, v.span, "callback's write")
			prov_write_back_into_argument(graph, v, left.at, actuals[left.at], sources)
		}
		if left.global != INVALID_SYMBOL {
			sources := prov_borrow(graph, prov_root_for_symbol(graph, left.global), nil, false, v.span, what)
			prov_write_back_into_argument(graph, v, left.at, actuals[left.at], sources)
		}
	}
}

// design.md "Borrows crossing between tasks": what a callee writes back lands
// in the storage the argument's mutable carriers name, and below that only
// where another mutable carrier leads (`prov_mutable_reach`), so neither what
// `slot: ^int` points at in `publish(&mut slot)` nor a read-only field beside
// a mutable one is a destination.
@(private = "file")
prov_write_back_into_argument :: proc(graph: ^Flow_Graph, v: ^Expr_Call, index: int, carrier, sources: []int) {
	prov_retain_into_argument(graph, v, index, carrier, sources, mutable_only = true)
}

// The carriers among `carriers`, a value of `type`, that a write may go
// through: each mutable one, and in what any carrier points at, each mutable
// one again. A read-only carrier is no destination, but a mutable one read
// through it is. Below a truncated path, or a pointee whose type is already
// being walked, the walk goes on in the analysis (`prov_load_writable`), since
// a recursive type reaches any depth; a read-only truncated path counts when a
// carrier in it leads to a destination.
@(private = "file")
prov_mutable_reach :: proc(graph: ^Flow_Graph, carriers: []int, type: Type_Id, span: Span, walking: ^map[Type_Id]bool = nil) -> []int {
	c := graph.k.c
	chain := walking
	if chain == nil {
		chain = new(map[Type_Id]bool, context.temp_allocator)
		chain^ = make(map[Type_Id]bool, context.temp_allocator)
	}
	out: []int
	for path in carrier_shape(c, type) {
		if path.truncated && !path.mutable {
			visited := make(map[Type_Id]bool, context.temp_allocator)
			if !truncated_reaches_destination(c, path, &visited) {
				continue
			}
		}
		selected := prov_select_content(graph, carriers, type, path.steps)
		if len(selected) == 0 {
			continue
		}
		if path.mutable {
			out = prov_join(graph, out, selected)
		}
		info := underlying_info(c, path.type)
		if !path.truncated && (info == nil || !prov_type_reaches_destination(c, info.element)) {
			continue
		}
		if path.truncated || chain[info.element] {
			below := prov_load_writable(graph, selected, span)
			// design.md "Minimum provenance precision": what is below a cut is
			// merged, so a borrow written there may land in any of it. A
			// recursive type merges nothing the walk would have kept apart.
			if path.truncated {
				for slot in below { graph.prov_slots[slot].precision |= path.precision }
			}
			out = prov_join(graph, out, below)
			continue
		}
		// design.md "Slice literals": a slice also carries its elements' loans,
		// as a variadic pack does its operands', so what it holds may be an
		// element as well as the storage it views. That storage is searched by
		// its own carriers' types, since an element's loan names no element.
		if info.kind == .Slice {
			chain[info.element] = true
			out = prov_join(graph, out, prov_mutable_reach(graph, selected, info.element, span, chain))
			chain[info.element] = false
			out = prov_join(graph, out, prov_load_writable(graph, selected, span))
			continue
		}
		pointee := prov_temp_content(graph, info.element)
		for slot in pointee {
			prov_emit(graph, Prov_Event{kind = .Load, slot = slot, into = selected, path = graph.prov_slots[slot].path, span = span})
		}
		graph.has_content_load ||= len(pointee) > 0
		chain[info.element] = true
		out = prov_join(graph, out, prov_mutable_reach(graph, pointee, info.element, span, chain))
		chain[info.element] = false
	}
	return out
}

// The stand-in for what the callback in `callback`, this body's parameter,
// leaves in its argument `argument`.
@(private = "file")
prov_forwarded_root :: proc(graph: ^Flow_Graph, callback: Symbol_Id, argument: int, span: Span) -> Root_Id {
	sym := symbol_of(graph.k.c, callback)
	root := prov_new_root(graph, .Static, span, identifier_text(graph.k.c, sym.name))
	graph.roots[int(root)].forwarded = true
	graph.roots[int(root)].param_index = int(sym.index)
	graph.roots[int(root)].argument = argument
	return root
}

// Where a `stored` argument may land: an `inout` parameter or receiver, or a
// mutable carrier, each only when it can hold a borrow. Matches the body check.
@(private = "file")
prov_writable_arguments :: proc(graph: ^Flow_Graph, v: ^Expr_Call, proc_type: Type_Id) -> []int {
	c := graph.k.c
	out := make([dynamic]int, 0, len(v.bound), graph.alloc)
	sym := symbol_of(c, v.resolution.chosen_overload)
	start := 0
	if sym != nil && sym.has_receiver {
		start = 1
		if len(v.bound) > 0 && v.bound[0] != nil {
			type := prov_type(graph, v.bound[0])
			if sym.receiver == .Inout && type_carries_borrow(c, type).any || prov_type_reaches_destination(c, type) {
				append(&out, 0)
			}
		}
	}
	info := underlying_info(c, proc_type)
	if info == nil {
		return out[:]
	}
	for index in start ..< min(len(v.bound), len(info.parameters)) {
		type := info.parameters[index]
		if prov_argument_is_inout(graph, v, index) && type_carries_borrow(c, type).any || prov_type_reaches_destination(c, type) {
			append(&out, index)
		}
	}
	return out[:]
}

// Whether a callee receiving `type` can write a borrow through it: through a
// mutable carrier, at any depth, to storage that can hold one, as `p^.view =
// values` or `ctx.destination.view = values` does. Searched over the types
// reached, each once, so no depth hides one.
prov_type_reaches_destination :: proc(c: ^Compiler, type: Type_Id) -> bool {
	visited := make(map[Type_Id]bool, context.temp_allocator)
	return type_reaches_destination(c, type, &visited)
}

// design.md "Allocator regions and region provenance": whether a callee
// receiving `type` can write an owner through it: through a mutable carrier at
// any depth, whatever it points at, as `outs[0]^ = make(...)` does through
// `outs: ..^mut [dynamic]int`.
prov_type_reaches_mutable :: proc(c: ^Compiler, type: Type_Id) -> bool {
	visited := make(map[Type_Id]bool, context.temp_allocator)
	return type_reaches_destination(c, type, &visited, owners = true)
}

// With `owners`, any mutable carrier is a destination, not only one whose
// pointee can hold a borrow.
@(private = "file")
type_reaches_destination :: proc(c: ^Compiler, type: Type_Id, visited: ^map[Type_Id]bool, owners := false) -> bool {
	if visited[type] {
		return false
	}
	visited[type] = true
	for path in carrier_shape(c, type) {
		if path.truncated {
			if truncated_reaches_destination(c, path, visited, owners) {
				return true
			}
			continue
		}
		info := underlying_info(c, path.type)
		if info == nil {
			continue
		}
		if path.mutable && (owners || type_carries_borrow(c, info.element).any) {
			return true
		}
		if type_reaches_destination(c, info.element, visited, owners) {
			return true
		}
	}
	return false
}

// A truncated path names no carrier, so the value it cut is searched instead:
// a mutable carrier in it is a destination, and a read-only one leads to one
// when its pointee reaches one, as `ptr: ^Leaf` does with `Leaf{out: ^mut ^int}`
// below the depth budget.
@(private = "file")
truncated_reaches_destination :: proc(c: ^Compiler, path: Carrier_Path, visited: ^map[Type_Id]bool, owners := false) -> bool {
	if path.mutable {
		return true
	}
	leaves := make([dynamic]Type_Id, 0, 4, context.temp_allocator)
	walking := make(map[Type_Id]bool, context.temp_allocator)
	carrier_leaves(c, path.cut, &leaves, &walking)
	for leaf in leaves {
		info := underlying_info(c, leaf)
		if info != nil && type_reaches_destination(c, info.element, visited, owners) {
			return true
		}
	}
	return false
}

// The carrier types in a value of `type`, without following any of them; the
// same walk `type_carries_borrow` takes.
@(private = "file")
carrier_leaves :: proc(c: ^Compiler, type: Type_Id, out: ^[dynamic]Type_Id, walking: ^map[Type_Id]bool) {
	if type == INVALID_TYPE || walking[type] {
		return
	}
	if type_is_carrier(c, type) {
		append(out, type)
		return
	}
	info := underlying_info(c, type)
	if info == nil || !type_carries_borrow(c, type).any {
		return
	}
	walking[type] = true
	if payload := shared_payload_type(c, type); payload != INVALID_TYPE {
		carrier_leaves(c, payload, out, walking)
		return
	}
	#partial switch info.kind {
	case .Struct:
		for field in info.fields {
			if sym := symbol_of(c, field); sym != nil {
				carrier_leaves(c, sym.type, out, walking)
			}
		}
	case .Union:
		for variant in info.variants {
			carrier_leaves(c, variant, out, walking)
		}
	case .Array, .Dynamic_Array, .Box:
		carrier_leaves(c, info.element, out, walking)
	case .Map:
		carrier_leaves(c, info.key, out, walking)
		carrier_leaves(c, info.element, out, walking)
	}
}

// One argument receiving what another may leave in it, joined since the callee
// may leave it alone. An `inout` argument is the place; a `^mut`/`[]mut` one
// goes through its `carrier` loans.
@(private = "file")
prov_retain_into_argument :: proc(
	graph: ^Flow_Graph,
	v: ^Expr_Call,
	index: int,
	carrier: []int,
	sources: []int,
	mutable_only := false,
) {
	argument := v.bound[index]
	// A variadic pack is a slice over its operands, which no place names.
	packed := call_packs(v, index)
	if argument == nil && !packed {
		return
	}
	if packed || !prov_argument_is_place(graph, v, index) {
		// Through the argument's carriers, and what they reach in turn.
		through: []int
		if mutable_only {
			through = prov_mutable_reach(graph, carrier, prov_parameter_type(graph, v, index), v.span)
		} else {
			through = prov_with_content(graph, carrier, v.span)
		}
		prov_publish_through(graph, through, sources, v.span)
		return
	}
	// `inout p` with `p: ^mut T`: through `p` as well as into it.
	if prov_type_reaches_destination(graph.k.c, prov_type(graph, argument)) {
		held := prov_carrier_slots(graph, argument)
		through: []int
		if mutable_only {
			through = prov_mutable_reach(graph, held, prov_type(graph, argument), v.span)
		} else {
			through = prov_with_content(graph, held, v.span)
		}
		prov_publish_through(graph, through, sources, v.span)
	}
	root, path, ok := prov_place_of(graph, argument)
	if !ok {
		return
	}
	prov_retain_escape(graph, argument, sources, v.span)
	slots := prov_content_at(graph, root, path)
	if len(slots) == 0 {
		ident, is_ident := argument.(^Expr_Ident)
		if !is_ident {
			return
		}
		slot, is_carrier := prov_slot_for_symbol(graph, ident.symbol)
		if !is_carrier {
			return
		}
		slots = prov_one(graph, slot)
	}
	for slot in slots {
		prov_define_one_content(graph, slot, prov_join(graph, prov_one(graph, slot), sources), v.span)
	}
}

@(private = "file")
prov_publish_through :: proc(graph: ^Flow_Graph, carriers, sources: []int, span: Span) {
	if len(carriers) == 0 {
		return
	}
	prov_emit(graph, Prov_Event{kind = .Retain, span = span, sources = sources, root = NO_ROOT, into = carriers})
	prov_emit(graph, Prov_Event{kind = .Publish, span = span, sources = sources, into = carriers})
}

// A `stored` argument that is also a destination may be left borrowing its own
// storage, as `h.view = h.items[:]` leaves it. Each content slot of the place
// gets a new borrow of it, weakened to that slot's capability; the argument's
// own loan keeps its. Any other carrier publishes its loans as they are.
@(private = "file")
prov_retain_into_self :: proc(graph: ^Flow_Graph, v: ^Expr_Call, index: int, carrier: []int) {
	place := v.bound[index]
	if !prov_argument_is_place(graph, v, index) {
		unary, is_unary := place.(^Expr_Unary)
		if !is_unary || unary.op != .Amp {
			prov_retain_into_argument(graph, v, index, carrier, carrier)
			return
		}
		place = unary.operand
	}
	root, path, ok := prov_place_of(graph, place)
	if !ok {
		return
	}
	// design.md "Escape levels": the callee may store any of the argument's
	// content into any compatible part of it, so each part keeps its own
	// sources, gains every other part's, and borrows the argument's own root.
	for slot in prov_content_at(graph, root, path) {
		own := prov_borrow(graph, root, path, true, v.span, "borrow")
		kept := prov_join(graph, prov_one(graph, slot), carrier)
		prov_define_one_content(graph, slot, prov_join(graph, kept, own), v.span)
	}
}

// Whether this argument names the destination itself rather than pointing at it.
@(private = "file")
prov_argument_is_place :: proc(graph: ^Flow_Graph, v: ^Expr_Call, index: int) -> bool {
	input := prov_input_call(graph, v)
	return index < len(input.arguments) && input.arguments[index].place
}

@(private = "file")
prov_parameter_label :: proc(graph: ^Flow_Graph, v: ^Expr_Call, index: int) -> string {
	sym := symbol_of(graph.k.c, v.resolution.chosen_overload)
	if sym == nil || index >= len(sym.param_symbols) {
		return "a parameter this call may keep"
	}
	bound := symbol_of(graph.k.c, sym.param_symbols[index])
	if bound == nil {
		return "a parameter this call may keep"
	}
	return fmt.aprintf(
		"`%s`, which `%s` may keep",
		identifier_text(graph.k.c, bound.name),
		identifier_text(graph.k.c, sym.name),
		allocator = graph.k.c.semantic_allocator,
	)
}

@(private = "file")
prov_op_returns_view :: proc(op: Container_Op) -> bool {
	#partial switch op {
	case .Map_Entries, .Map_Keys, .Map_Values:
		return true
	}
	return false
}

// design.md "Splitting a mutable slice", "Chunks of a mutable slice": the
// result views what the receiver views, so the receiver is lent as a mutable
// carrier argument is.
@(private)
prov_op_lends_receiver :: proc(op: Container_Op) -> bool {
	return op == .Split_At_Mut || op == .Chunks_Mut
}

@(private = "file")
prov_op_removes_element :: proc(op: Container_Op) -> bool {
	#partial switch op {
	case .Pop, .Remove, .Remove_Unordered, .Map_Remove:
		return true
	}
	return false
}

// The content path a removal reads; a map removal reads only the value.
@(private = "file")
prov_element_path :: proc(
	graph: ^Flow_Graph,
	v: ^Expr_Call,
	path: []Proj_Step,
	op: Container_Op,
) -> []Proj_Step {
	if op != .Map_Remove {
		return prov_extend(graph, path, proj_wild())
	}
	entry := prov_extend(graph, path, prov_map_call_step(graph, v))
	return prov_extend(graph, entry, proj_field(PROJ_MAP_VALUE))
}

// The entry step for a map operation that takes its key as an argument.
@(private = "file")
prov_map_call_step :: proc(graph: ^Flow_Graph, v: ^Expr_Call) -> Proj_Step {
	if len(v.bound) < 2 || v.bound[0] == nil {
		return proj_wild()
	}
	return prov_map_entry_step(graph, prov_type(graph, v.bound[0]), v.bound[1])
}

// Stored key/value borrows become the container's, checked like an indexed
// assignment. A fallible write joins, since its failure edge changes nothing.
@(private = "file")
prov_container_content :: proc(graph: ^Flow_Graph, v: ^Expr_Call, op: Container_Op, actuals: [][]int) {
	#partial switch op {
	case .Append, .Insert, .Map_Try_Insert, .Map_Find_Or_Insert, .Clear, .Map_Clear:
	case:
		return
	}
	if len(v.bound) == 0 || v.bound[0] == nil {
		return
	}
	info := underlying_info(graph.k.c, prov_type(graph, v.bound[0]))
	if info == nil {
		return
	}
	// A spread's elements are copied in, keeping the regions they are in.
	if op == .Append && type_is_managed(graph.k.c, info.element) {
		spreads := v.variadic_spreads
		if v.variadic_forwards {
			spreads = v.bound[v.variadic_slot:][:1]
		}
		for spread in spreads {
			prov_store_spread_region(graph, prov_input_value(graph, v.bound[0]), prov_input_value(graph, spread))
		}
	}
	stored_values: []Expr
	#partial switch op {
	case .Append:
		stored_values = v.is_variadic ? v.variadic_elements : v.bound[1:]
	case .Insert:
		stored_values = v.bound[min(2, len(v.bound)):]
	case .Map_Try_Insert, .Map_Find_Or_Insert:
		stored_values = v.bound[1:]
	}
	for value in stored_values {
		prov_store_region(graph, prov_input_value(graph, v.bound[0]), prov_input_value(graph, value), element = true)
	}
	if op == .Clear || op == .Map_Clear {
		if root, path, ok := prov_place_of(graph, v.bound[0]); ok {
			if content := prov_content_at(graph, root, path); len(content) > 0 {
				prov_define_content(
					graph, content, nil, v.span, path, prov_type(graph, v.bound[0]),
				)
			}
		}
		return
	}
	stored: []int
	#partial switch op {
	case .Append:
		if type_carries_borrow(graph.k.c, info.element).any && len(actuals) > 1 {
			stored = actuals[1]
		}
	case .Insert:
		if type_carries_borrow(graph.k.c, info.element).any && len(actuals) > 2 {
			stored = actuals[2]
		}
	case .Map_Try_Insert, .Map_Find_Or_Insert:
		if type_carries_borrow(graph.k.c, info.key).any && len(actuals) > 1 {
			stored = actuals[1]
		}
		if type_carries_borrow(graph.k.c, info.element).any && len(actuals) > 2 {
			stored = prov_join(graph, stored, actuals[2])
		}
	}
	if len(stored) == 0 {
		return
	}
	// Also covers a receiver reached through a carrier.
	prov_retain_escape(graph, v.bound[0], stored, v.span)
	root, path, ok := prov_place_of(graph, v.bound[0])
	if !ok {
		return
	}
	if op == .Map_Try_Insert || op == .Map_Find_Or_Insert {
		entry := prov_extend(graph, path, prov_map_call_step(graph, v))
		if len(actuals) > 1 && len(actuals[1]) > 0 {
			written := prov_extend(graph, entry, proj_field(PROJ_MAP_KEY))
			if content := prov_content_at(graph, root, written); len(content) > 0 {
				prov_define_content(graph, content, actuals[1], v.span, written, info.key, true)
			}
		}
		if len(actuals) > 2 && len(actuals[2]) > 0 {
			written := prov_extend(graph, entry, proj_field(PROJ_MAP_VALUE))
			if content := prov_content_at(graph, root, written); len(content) > 0 {
				prov_define_content(graph, content, actuals[2], v.span, written, info.element, true)
			}
		}
		return
	}
	written := prov_extend(graph, path, proj_wild())
	if content := prov_content_at(graph, root, written); len(content) > 0 {
		prov_define_content(graph, content, stored, v.span, written, info.element)
	}
}

// design.md "string type conversions": a text operation either borrows its
// operand or returns a fresh owner with no loans.
@(private = "file")
// The checker binds a text operation's one operand: the text, or the bytes
// or runes a conversion reads.
prov_text_call :: proc(graph: ^Flow_Graph, v: ^Expr_Call) -> []int {
	if len(v.bound) != 1 || v.bound[0] == nil {
		return nil
	}
	operand := v.bound[0]
	source := walk_flow_expr(graph, operand)
	if text_reads_bytes(v) {
		prov_reach(graph, source, v.span)
	}
	if !text_result_borrows(graph.k.c, v, prov_type(graph, v)) {
		return nil
	}
	// An owning `string` operand lends its own storage, which a temporary gives
	// up at the end of its statement.
	if len(source) == 0 {
		if root, path, ok := prov_place_of(graph, operand); ok {
			return prov_borrow(graph, root, path, false, v.span, "view")
		}
		if !type_is_carrier(graph.k.c, prov_type(graph, operand)) && prov_expr_is_temporary(operand) {
			return prov_borrow(graph, prov_temp_root(graph, expr_span(operand)), nil, false, v.span, "view")
		}
	}
	return source
}

// Whether a text operation reads the bytes its operand views. `byte_len` reads
// only the header, and `bytes`, `runes`, and `rune_offsets` only derive views,
// whose later reads, returns, and stores are recorded where they happen.
@(private = "file")
text_reads_bytes :: proc(v: ^Expr_Call) -> bool {
	if operation, is_text := v.operation.(Call_Text); is_text {
		#partial switch operation.op {
		case .Byte_Len, .Bytes, .Runes, .Rune_Offsets:
			return false
		}
	}
	return true
}

// design.md "Standard customization procedures": a clone is ownership-recursive,
// so a generated `try_clone`/`clone` result carries what its receiver carries,
// never a loan of the receiver's own storage. A `hook(copy)` taking `self: ^`
// is the exception, since its body could hand one out.
@(private = "file")
clone_copies_receiver :: proc(c: ^Compiler, callee: ^Symbol) -> bool {
	if callee.synth != .Clone && callee.synth != .Try_Clone {
		return false
	}
	hook := symbol_of(c, lifecycle_of(c, callee.owner_type).custom_try_clone)
	return hook == nil || !param_mode_is_pointer(symbol_param_mode(c, hook, 0))
}

@(private = "file")
text_result_borrows :: proc(c: ^Compiler, v: ^Expr_Call, type: Type_Id) -> bool {
	#partial switch operation in v.operation {
	case Call_Text:
		if operation.op == .Copy || operation.op == .From_Runes { return false }
	case Call_Text_Conversion:
		if operation.op == .String_From_Bytes || operation.op == .String_From_C_View { return false }
	}
	return prov_carries_borrow(c, type)
}

@(private = "file")
prov_carries_borrow :: proc(c: ^Compiler, type: Type_Id) -> bool {
	return prov_type_or_wrapped(c, type, type_is_carrier)
}

@(private)
prov_store_call_results :: proc(graph: ^Flow_Graph, v: ^Expr_Call, actuals: [][]int) -> []int {
	type := prov_type(graph, v)
	recorded := prov_effect_active(graph) && prov_type_has_region(graph.k.c, type)
	if recorded { prov_effect_begin(graph, Prov_Effect_Call{prov_effect_value(graph, prov_input_value(graph, v)), .Result}) }
	defer prov_effect_end(graph, recorded)
	// A diverging call's value is never produced (design.md "Diverging
	// procedures"), so it contributes no sources.
	if type == TYPE_VOID || type == INVALID_TYPE || call_diverges(graph.k.c, v) {
		return nil
	}
	id := prov_input_value(graph, v)
	result := Prov_Call_Result {
		loans          = prov_call_result(graph, v, actuals, type),
		region         = prov_call_region(graph, id, type),
		region_content = prov_call_region_content(graph, id),
	}
	if prov_result_is_inout(graph, v) {
		result.place = prov_inout_actuals(graph, v, actuals)
	}
	graph.call_results[v] = result
	return result.loans
}

// Resets propagate through wrappers and indirect calls (design.md).
@(private = "file")
prov_call_resets :: proc(graph: ^Flow_Graph, v: ^Expr_Call) {
	proc_type := call_proc_type(graph.k.c, v)
	if proc_type == INVALID_TYPE {
		return
	}
	for argument, index in v.bound {
		if argument == nil || !proc_param_resets(graph.k.c, proc_type, index) {
			continue
		}
		prov_reset(graph, prov_input_value(graph, argument), v.span, false, v)
	}
}

// design.md "@(cross_thread)": what an argument takes to another thread must
// be able to go. `@(escape=static)` already keeps its borrows to storage that
// lasts for the process, so a `thread_local` one cannot cross; what remains is
// thread affinity, erasure that hides it, and an allocator region the other
// thread may not be allowed to use. Only the default region is known to
// accept use from any thread; one this procedure received may be a region
// that does not (design.md "Allocator regions and region provenance").
@(private = "file")
prov_call_cross_thread :: proc(graph: ^Flow_Graph, v: ^Expr_Call) {
	c := graph.k.c
	if graph.mode != .Prov_Diagnose || !committing(c) {
		return
	}
	proc_type := call_proc_type(c, v)
	info := underlying_info(c, proc_type)
	if info == nil || len(info.param_cross_thread) == 0 {
		return
	}
	for argument, index in v.bound {
		if argument == nil || index >= len(info.parameters) || !proc_param_crosses_thread(c, proc_type, index) ||
		   underlying_kind(c, info.parameters[index]) == .Proc {
			continue
		}
		base := expr_base(argument)
		if base == nil || base.type == INVALID_TYPE {
			continue
		}
		facts := transfer_facts(c, prov_transferred_type(c, argument), through_views = true)
		span := expr_span(argument)
		report_transfer_facts(c, base.type, facts, span)
		prov_event(graph, Prov_Event_Received_Region{prov_input_value(graph, argument), span, prov_owner_name(graph, argument)})
	}
}

// design.md "@(thread_affine)": a value crossing to another thread holds or
// reaches nothing thread-affine, and no erased value whose eligibility the
// compiler cannot see. A `dyn` view shows it through each type converted to it.
@(private = "file")
report_transfer_facts :: proc(c: ^Compiler, type: Type_Id, facts: Transfer_Facts, span: Span) {
		base_type := type
		switch {
		case facts.affine != INVALID_TYPE:
			if facts.affine_via.view != INVALID_TYPE {
				errorf(
					c, span, "L0724", "%s, which is `@(thread_affine)`, so it cannot cross to another thread",
					viewed_subject(c, base_type, facts.affine, facts.affine_via),
				)
			} else if facts.affine == base_type {
				errorf(c, span, "L0724", "`%s` is `@(thread_affine)`, so it cannot cross to another thread", type_name(c, base_type))
			} else {
				errorf(
					c, span, "L0724",
					"`%s` holds or reaches `%s`, which is `@(thread_affine)`, so it cannot cross to another thread",
					type_name(c, base_type), type_name(c, facts.affine),
				)
			}
			if declared := symbol_of(c, type_of(c, facts.affine).symbol); declared != nil {
				add_notef(c, declared.span, "`%s` is declared here", type_name(c, facts.affine))
			}
		case facts.erased != INVALID_TYPE && facts.erased_via.view != INVALID_TYPE:
			errorf(
				c, span, "L0725", "%s, which hides the type it erased, so nothing shows that it may cross to another thread",
				viewed_subject(c, base_type, facts.erased, facts.erased_via),
			)
			add_notef(c, span, "pass the concrete value instead, or convert it to the view at this call")
		case facts.erased == base_type:
			errorf(
				c, span, "L0725",
				"`%s` hides the type it erased, so nothing shows that it may cross to another thread",
				type_name(c, base_type),
			)
			add_notef(c, span, "pass the concrete value instead, or convert it to the view at this call")
		case facts.erased != INVALID_TYPE:
			errorf(
				c, span, "L0725",
				"`%s` reaches `%s`, which hides the type it erased, so nothing shows that it may cross to another thread",
				type_name(c, base_type), type_name(c, facts.erased),
			)
			add_notef(c, span, "pass the concrete value instead, or convert it to the view at this call")
		}
}

// design.md "Sharing with tasks" and "Borrows crossing between tasks" at a
// spawn. An argument the task shares with the parent, one neither moved, nor
// `inout`, nor a mutable carrier passed itself, reaches no mutable carrier;
// nothing that crosses in either direction is or reaches a thread-affine type
// or an erased value of unknown eligibility; and no borrow of `thread_local`
// storage crosses, which the solver checks on `crossing`.
@(private = "file")
prov_spawn_transfers :: proc(graph: ^Flow_Graph, s: ^Stmt_Spawn, call: ^Expr_Call, held, result: []int) {
	c := graph.k.c
	task := s.task
	if graph.mode != .Prov_Diagnose || !committing(c) {
		return
	}
	info := underlying_info(c, call_proc_type(c, call))
	for argument, index in call.bound {
		if info == nil || index >= len(info.parameters) || index >= len(task.kinds) {
			continue
		}
		// A pack element is the task's own when it is a temporary or moved in.
		// One copied from a place the parent keeps is shared, as a copy of
		// what that place reaches, and so is a spread, as the slice it views.
		if call_packs(call, index) {
			next_element, next_spread := 0, 0
			for is_spread in call.variadic_order {
				if is_spread {
					prov_transfer_argument(c, call.variadic_spreads[next_spread], true)
					next_spread += 1
					continue
				}
				element := call.variadic_elements[next_element]
				next_element += 1
				_, moved := element.(^Expr_Move)
				prov_transfer_argument(c, element, !moved && expression_is_borrowed_place(element))
			}
			continue
		}
		if argument == nil {
			continue
		}
		mode := index < len(info.param_modes) ? info.param_modes[index] : Param_Mode.Value
		// A moved argument is the task's alone, even one copied into the frame.
		_, moved := argument.(^Expr_Move)
		prov_transfer_argument(c, argument, task.kinds[index] != .Owned && mode != .Inout && !moved)
	}
	if s.result != nil {
		if sym := symbol_of(c, task.result); sym != nil {
			report_transfer_facts(c, sym.type, transfer_facts(c, sym.type, through_views = true), call.span)
		}
	}
	report_thread_local_writes(c, call, graph.literal.symbol)
	prov_emit(graph, Prov_Event {
		kind = .Cross, sources = prov_join(graph, held, prov_load_deep(graph, held, call.span)),
		span = call.span, verb = "argument",
	})
	if len(result) > 0 {
		prov_emit(graph, Prov_Event {
			kind = .Cross, sources = prov_join(graph, result, prov_load_deep(graph, result, call.span)),
			span = call.span, verb = "result",
		})
	}
}

// One value crossing to a task, which it shares with the parent unless it is
// the task's alone.
@(private = "file")
prov_transfer_argument :: proc(c: ^Compiler, argument: Expr, shared: bool) {
	base := expr_base(argument)
	if base == nil || base.type == INVALID_TYPE {
		return
	}
	span := expr_span(argument)
	transferred := prov_transferred_type(c, argument)
	facts := transfer_facts(c, transferred, through_views = true)
	// A task may share an erased value only as its own, and moving one would
	// still not show that it may cross (design.md "Sharing with tasks").
	if shared && base.erased_from == INVALID_TYPE && (base.type == facts.erased && !carrier_is_mutable(c, base.type)) {
		errorf(c, span, "L0729", "`%s` hides what it captures, so a task cannot share it", type_name(c, base.type))
		add_notef(c, span, "pass the concrete value instead, or convert it to the view at this call")
		return
	}
	report_transfer_facts(c, base.type, facts, span)
	// What a read-only view may view is shared however the view is passed:
	// moving the view gives the task nothing of its own.
	if facts.viewed != INVALID_TYPE {
		errorf(
			c, span, "L0729", "%s, so a task sharing it could write what the parent reaches too",
			viewed_subject(c, base.type, facts.viewed, facts.viewed_via),
		)
		add_notef(c, span, "pass the concrete value instead, or convert it to the view at this call")
	}
	if shared && facts.mutable != INVALID_TYPE && !carrier_is_mutable(c, transferred) {
		// A view made at this call only borrows what it converts, so moving the
		// view gives the task nothing of its own.
		advice := ": move it into the task, or pass the mutable borrow itself"
		if transferred != base.type {
			advice = "; the view only borrows what it converts: pass the mutable borrow itself instead"
			if dyn_proc_signature(c, base.type) != INVALID_TYPE {
				advice = "; the view only borrows the callable: move the callable into the task through a generic `Callable` parameter instead"
			}
		}
		errorf(
			c, span, "L0729", "`%s` reaches `%s`, so a task sharing it could write what the parent reaches too%s",
			type_name(c, base.type), type_name(c, facts.mutable), advice,
		)
	}
}

// A fact reached through a read-only view, said of the value that holds it:
// "`dyn I`, which may view ..." or "`Holder` reaches `dyn I`, which may view ...".
@(private = "file")
viewed_subject :: proc(c: ^Compiler, base, reached: Type_Id, via: Transfer_Via) -> string {
	chain := view_chain_text(c, reached, via)
	if via.view == base {
		return chain
	}
	return fmt.tprintf("`%s` reaches %s", type_name(c, base), chain)
}

// What an argument takes across: a `dyn` or `any_view` made at the call is
// checked through what it erased, which is known there. An explicit conversion
// to either is the implicit one written out, so its operand is what was erased.
@(private = "file")
prov_transferred_type :: proc(c: ^Compiler, argument: Expr) -> Type_Id {
	base := expr_base(argument)
	if base.erased_from != INVALID_TYPE {
		return base.erased_from
	}
	if call, is_call := argument.(^Expr_Call); is_call && len(call.bound) == 1 && call.bound[0] != nil {
		kind := underlying_kind(c, call.type)
		#partial switch _ in call.operation {
		case Call_Dyn_Conversion, Call_Conversion:
			if kind == .Dyn || kind == .Any_View {
				return prov_transferred_type(c, call.bound[0])
			}
		}
	}
	return base.type
}

// Whether `set` names a region this body received and has not had checked: an
// owner that arrived through a `@(cross_thread)` `move` parameter was checked
// at the call that passed it.
@(private)
prov_has_received_region :: proc(graph: ^Flow_Graph, set: Region_Set) -> bool {
	if graph.literal.signature == nil {
		return region_is_parameter_backed(set)
	}
	index := 0
	for parameter in graph.literal.signature.params {
		for id in parameter.symbols {
			defer index += 1
			if index >= len(set.params) || !set.params[index] {
				continue
			}
			if sym := symbol_of(graph.k.c, id); sym == nil || !sym.cross_thread || sym.mode != .Move {
				return true
			}
		}
	}
	return false
}

// design.md "Temporaries and procedure boundaries": a direct call substitutes
// argument roots into the callee's result summary. An indirect call has none,
// so its result derives from every escaping argument.
@(private = "file")
prov_call_result :: proc(
	graph: ^Flow_Graph,
	v: ^Expr_Call,
	actuals: [][]int,
	result_type: Type_Id,
) -> []int {
	c := graph.k.c
	// design.md "`inout` results": the result aliases the `inout` arguments.
	if prov_result_is_inout(graph, v) {
		out := prov_inout_actuals(graph, v, actuals)
		return type_is_carrier(c, result_type) ? out : prov_value_content(graph, out, result_type, v.span)
	}
	// design.md "Shared ownership": a borrow from a handle derives from it. The
	// body can't show that through its `rawptr`, so it is asserted here.
	if len(actuals) > 0 && prov_receiver_is_shared_handle(graph, v) {
		if type_is_carrier(c, result_type) {
			return actuals[0]
		}
		return prov_value_content(graph, actuals[0], result_type, v.span)
	}
	// A result that is not itself a borrow can still hold one.
	if !type_is_carrier(c, result_type) && !type_carries_borrow(c, result_type).any {
		return nil
	}
	// A conversion's result is its operand, carrier by carrier: a distinct
	// type and its underlying type share one carrier shape.
	if _, conversion := v.operation.(Call_Conversion); conversion && len(v.bound) == 1 && v.bound[0] != nil {
		if type_is_carrier(c, result_type) {
			return actuals[0]
		}
		return prov_project_content(graph, actuals[0], expr_base(v.bound[0]).type, nil, result_type, v.span)
	}
	callee := call_contract_declaration(c, v)
	direct := prov_has_direct_body(c, callee)
	prov_note_summary_dependency(graph, callee, direct)
	out: []int
	if summary, found := result_summary(c, callee); found {
		// Sibling fields share one synthesized root per kind.
		synthetic := make(map[Root_Kind]Root_Id, graph.alloc)
		read := prov_callback_result(graph, v, callee, result_type)
		if summary.content_type == result_type && len(summary.content) > 0 {
			content := prov_temp_content(graph, result_type)
			for slot in content {
				sources := read
				for path in summary.content {
					if paths_overlap(graph.prov_slots[slot].path, path.path.steps) {
						leaf_type := path.path.truncated ? result_type : path.path.type
						sources = prov_join(graph, sources, prov_substitute_result(graph, v, actuals, path.dependencies, leaf_type, &synthetic))
					}
				}
				prov_define_one_content(graph, slot, sources, v.span)
			}
			return content
		}
		out = prov_join(graph, read, prov_substitute_result(graph, v, actuals, summary.dependencies, result_type, &synthetic))
	} else if direct {
		// No summary yet is a forward fixed-point edge, not erased metadata.
		return nil
	} else {
		// Without a mapping every escaping argument can reach every result path.
		out = prov_escaping_actuals(graph, v, actuals)
		if _, is_call := v.operation.(Call_Procedure); is_call && symbol_of(c, callee) == nil {
			append(&graph.plain_calls, v)
		}
		// design.md "Temporaries and procedure boundaries": with no escaping
		// argument to derive from, the result's root is unknown. An argument
		// borrowed only for the call establishes nothing.
		if len(out) == 0 {
			out = prov_synthetic_borrow(graph, v, .Unknown, result_type)
		}
		out = prov_join(graph, out, prov_callback_returned(graph, v, result_type))
	}
	return type_is_carrier(c, result_type) ? out : prov_value_content(graph, out, result_type, v.span)
}

// design.md "Borrows crossing between tasks": what the result may hold that a
// callback the callee calls leaves in an argument, with the callback this call
// passes: its `thread_local` borrow, or while a body is summarized and the
// callback is that body's own, its stand-in.
@(private = "file")
prov_callback_result :: proc(graph: ^Flow_Graph, v: ^Expr_Call, callee: Symbol_Id, result_type: Type_Id) -> []int {
	c := graph.k.c
	consulted := make([dynamic]Symbol_Id, 0, 4, context.temp_allocator)
	reads := call_callback_reads(c, v, callee, graph.literal.symbol, graph.mode == .Prov_Summary, &consulted)
	for target in consulted {
		prov_note_summary_dependency(graph, target, prov_has_direct_body(c, target))
	}
	out: []int
	for read in reads {
		root := NO_ROOT
		if read.callback != INVALID_SYMBOL {
			root = prov_forwarded_root(graph, read.callback, read.argument, v.span)
		} else {
			root = prov_root_for_symbol(graph, read.global)
		}
		mutable := type_carries_borrow(c, result_type).mutable
		out = prov_join(graph, out, prov_borrow(graph, root, nil, mutable, v.span, carrier_noun(c, result_type)))
	}
	return out
}

// design.md "Borrows crossing between tasks": a call through a value may
// return a borrow of the `thread_local` storage of the thread that runs it,
// which an unknown root does not show: what each procedure the value may be
// returns, or while a body is summarized and the value is a callback that body
// received, the one its caller passes (`call_callback_returns`).
@(private = "file")
prov_callback_returned :: proc(graph: ^Flow_Graph, v: ^Expr_Call, result_type: Type_Id) -> []int {
	c := graph.k.c
	consulted := make([dynamic]Symbol_Id, 0, 4, context.temp_allocator)
	returned := call_callback_returns(c, v, graph.literal.symbol, graph.mode == .Prov_Summary, &consulted)
	for target in consulted {
		prov_note_summary_dependency(graph, target, prov_has_direct_body(c, target))
	}
	out: []int
	for left in returned {
		root := NO_ROOT
		if left.callback != INVALID_SYMBOL {
			root = prov_forwarded_root(graph, left.callback, left.argument, v.span)
		} else {
			root = prov_root_for_symbol(graph, left.global)
		}
		mutable := type_carries_borrow(c, result_type).mutable
		out = prov_join(graph, out, prov_borrow(graph, root, nil, mutable, v.span, carrier_noun(c, result_type)))
	}
	return out
}

@(private = "file")
prov_inout_actuals :: proc(graph: ^Flow_Graph, v: ^Expr_Call, actuals: [][]int) -> []int {
	out: []int
	for slots, index in actuals {
		if prov_argument_is_inout(graph, v, index) {
			out = prov_join(graph, out, slots)
		}
	}
	return out
}

@(private = "file")
prov_receiver_is_shared_handle :: proc(graph: ^Flow_Graph, v: ^Expr_Call) -> bool {
	sym := symbol_of(graph.k.c, v.resolution.chosen_overload)
	if sym == nil || !sym.has_receiver {
		return false
	}
	return type_is_shared_handle(graph.k.c, sym.owner_type)
}

// Substitutes one result path's dependencies, matching parameter paths by shape.
@(private = "file")
prov_substitute_result :: proc(
	graph: ^Flow_Graph,
	v: ^Expr_Call,
	actuals: [][]int,
	dependencies: Result_Dependencies,
	type: Type_Id,
	synthetic: ^map[Root_Kind]Root_Id,
) -> []int {
	out: []int
	for depths, index in dependencies.param_loads {
		if index >= len(actuals) {
			continue
		}
		// design.md "Procedure result contracts": a `self: ^` receiver's actual
		// also holds what its place holds, which is what one load through the
		// receiver reads, selected at the loaded path. Loading through those
		// carriers instead would reach what every field views, and loading
		// through the borrow of the place adds nothing but, for a temporary,
		// the temporary itself.
		through := actuals[index]
		held: []int
		if content, found := graph.receiver_content[v]; found && index == 0 {
			through, held = nil, content
		}
		for depth in 1 ..= 8 {
			if depths & (u8(1) << u8(depth - 1)) == 0 {
				continue
			}
			// A load narrowed to some of the pointee's paths goes along only
			// those, and so do the loads below it.
			paths := result_load_paths(dependencies, index, depth)
			shape := prov_parameter_pointee_shape(graph, v, index)
			if len(paths) == 0 || len(paths) != len(shape) {
				out = prov_join(graph, out, prov_load_deep(graph, through, v.span, depth))
				out = prov_join(graph, out, prov_load_held(graph, v, held, depth, nil))
				continue
			}
			for named, position in paths {
				if named {
					out = prov_join(graph, out, prov_load_deep(graph, through, v.span, depth, shape[position].steps))
					out = prov_join(graph, out, prov_load_held(graph, v, held, depth, shape[position].steps))
				}
			}
		}
	}
	for wanted, index in dependencies.params {
		if !wanted || index >= len(actuals) {
			continue
		}
		paths := index < len(dependencies.param_paths) ? dependencies.param_paths[index] : nil
		param_type := prov_parameter_type(graph, v, index)
		shape := carrier_shape(graph.k.c, param_type)
		if len(paths) == 0 || len(paths) != len(shape) {
			out = prov_join(graph, out, actuals[index])
			continue
		}
		for named, position in paths {
			if named {
				out = prov_join(graph, out, prov_select_content(graph, actuals[index], param_type, shape[position].steps))
			}
		}
	}
	// design.md "Global write effects": a borrow of a named global is a loan on
	// that global's own root, as the same borrow written here would be.
	for global in dependencies.globals {
		out = prov_join(graph, out, prov_borrow(
			graph, prov_root_for_symbol(graph, global), nil, type_carries_borrow(graph.k.c, type).mutable,
			v.span, carrier_noun(graph.k.c, type),
		))
	}
	kinds := [3]Root_Kind{.Static, .Thread_Local, .Unknown}
	wanted := [3]bool{dependencies.static, dependencies.thread, dependencies.unknown || dependencies.local}
	for needed, index in wanted {
		if !needed {
			continue
		}
		kind := kinds[index]
		root, found := synthetic^[kind]
		if !found {
			root = prov_synthetic_root(graph, v, kind)
			synthetic^[kind] = root
		}
		out = prov_join(graph, out, prov_borrow(
			graph, root, nil, type_carries_borrow(graph.k.c, type).mutable,
			v.span, carrier_noun(graph.k.c, type),
		))
	}
	if dependencies.precision != {} && len(out) > 0 {
		slot := prov_temp_slot(graph)
		graph.prov_slots[slot].precision = dependencies.precision
		prov_define_one_content(graph, slot, out, v.span)
		return prov_one(graph, slot)
	}
	return out
}

// What `depth` loads through a `self: ^` receiver read of what its place holds,
// `held`, with the first load along `path`: the first load is `held` itself.
@(private = "file")
prov_load_held :: proc(graph: ^Flow_Graph, v: ^Expr_Call, held: []int, depth: int, path: []Proj_Step) -> []int {
	if len(held) == 0 {
		return nil
	}
	selected := prov_select_content(graph, held, prov_parameter_type(graph, v, 0), path)
	if depth == 1 {
		return selected
	}
	return prov_load_deep(graph, selected, v.span, depth - 1)
}

// The carrier paths of what one load through parameter `index` reads. A
// `self: ^` receiver's signature type is the pointee itself.
@(private = "file")
prov_parameter_pointee_shape :: proc(graph: ^Flow_Graph, v: ^Expr_Call, index: int) -> []Carrier_Path {
	type := prov_parameter_type(graph, v, index)
	if input := prov_input_call(graph, v); index == 0 && input.has_receiver && input.receiver == .Borrow {
		return carrier_shape(graph.k.c, type)
	}
	return carrier_pointee_shape(graph.k.c, type)
}

@(private = "file")
prov_note_summary_dependency :: proc(graph: ^Flow_Graph, callee: Symbol_Id, direct: bool) {
	if graph.mode != .Prov_Summary || !direct || callee == INVALID_SYMBOL {
		return
	}
	if is_contract_join(graph.k.c, callee) {
		for member in symbol_of(graph.k.c, callee).members {
			prov_note_summary_dependency(graph, member, direct)
		}
		return
	}
	for existing in graph.summary_callees {
		if existing == callee {
			return
		}
	}
	append(&graph.summary_callees, callee)
}

@(private = "file")
prov_synthetic_root :: proc(graph: ^Flow_Graph, v: ^Expr_Call, kind: Root_Kind) -> Root_Id {
	name: string
	#partial switch kind {
	case .Static:       name = "static storage"
	case .Thread_Local: name = "`thread_local` storage"
	case:               name = "unknown storage"
	}
	return prov_new_root(graph, kind, v.span, name)
}

@(private = "file")
prov_synthetic_borrow :: proc(graph: ^Flow_Graph, v: ^Expr_Call, kind: Root_Kind, type: Type_Id) -> []int {
	root := prov_synthetic_root(graph, v, kind)
	return prov_borrow(
		graph,
		root,
		nil,
		carrier_is_mutable(graph.k.c, type),
		v.span,
		carrier_noun(graph.k.c, type),
	)
}

// Whether the result reaches this parameter only through a view it holds: a
// narrowed summary entry means exactly that, since `merge_param_paths` widens
// on any loan of the parameter's own storage.
@(private = "file")
prov_result_reads_through_receiver :: proc(c: ^Compiler, v: ^Expr_Call, type: Type_Id, index: int) -> bool {
	// A mutable yield keeps naming the receiver (design.md "By-reference
	// iteration"); a mutable slice out of `operator([:])` reborrows the view
	// it reads through instead (design.md "Indexing and slicing").
	sym := symbol_of(c, v.resolution.chosen_overload)
	if type_carries_borrow(c, type).mutable && (sym == nil || sym.operator != "[:]") {
		return false
	}
	summary, found := result_summary(c, call_contract_declaration(c, v))
	if !found || index >= len(summary.param_paths) {
		return false
	}
	if summary.param_loads[index] != 0 && !summary.params[index] {
		return true
	}
	for named in summary.param_paths[index] {
		if named {
			return true
		}
	}
	return false
}

// ------------------------------------------------------- thread summaries --
// compiler-architecture.md "Ownership, lifecycle, and provenance": facts
// recorded only while `compute_thread_summaries` builds each body's graph, so
// no other pass pays for them.

// What `carriers` hold is reached here; the reach effect resolves it to the
// globals whose stored carriers those are. Returns `carriers`.
@(private)
prov_reach :: proc(graph: ^Flow_Graph, carriers: []int, span: Span) -> []int {
	if (graph.k.c.thread_facts_pending || graph.parallel_depth > 0) && len(carriers) > 0 {
		prov_emit(graph, Prov_Event{kind = .Reach, sources = carriers, span = span})
	}
	return carriers
}

// A callee may read or write through anything it is given, and a call through
// a view dispatches through it.
@(private = "file")
prov_reach_call :: proc(graph: ^Flow_Graph, callee: []int, actuals: [][]int, span: Span) {
	if !graph.k.c.thread_facts_pending && graph.parallel_depth == 0 {
		return
	}
	reached := callee
	for loans in actuals {
		reached = prov_join(graph, reached, loans)
	}
	prov_reach(graph, reached, span)
}

// The allocator-use effect: an operation here may allocate, resize, free,
// reset, or destroy in `set`. An `owned` set is an owner's, which with no
// region recorded is bound to the default provider (design.md "Allocators").
@(private)
prov_note_allocator_use :: proc(graph: ^Flow_Graph, set: Region_Set, span: Span, owned := false) {
	if !prov_tracks_allocator_use(graph) {
		return
	}
	if !graph.k.c.thread_facts_pending {
		used := prov_region_closure(graph, set)
		if owned && region_is_empty(set) {
			used.default = true
		}
		prov_note_window_allocator_use(graph, used, span)
		return
	}
	visible := prov_caller_region(graph, set)
	if owned && region_is_empty(set) {
		visible.default = true
	}
	output := prov_output(graph)
	if output.allocator_use.regions.params == nil {
		output.allocator_use = new_allocator_use(output.param_count, output.alloc)
	}
	merge_allocator_use(&output.allocator_use, visible, Effect_Source{span = span})
}

// Whether allocator use is being recorded: while the thread summaries collect,
// and inside a `parallel` block once they have settled, for its reservations.
@(private)
prov_tracks_allocator_use :: proc(graph: ^Flow_Graph) -> bool {
	c := graph.k.c
	return c.thread_facts_pending || (graph.parallel_depth > 0 && c.global_writes_ready)
}

// design.md "Allocators and tasks": inside a `parallel` block, a spawned
// call's allocator use is what its task reserves, and any other is the
// parent's, checked against the reservations of the tasks that may be running.
// The default provider's region permits concurrent use, so it reserves
// nothing.
@(private)
prov_note_window_allocator_use :: proc(graph: ^Flow_Graph, set: Region_Set, span: Span) {
	if graph.task_effects {
		reserve := &graph.task_reserve
		if output := graph.materialized; output != nil { reserve = &output.task_sites[graph.task_index].reserve }
		if reserve.params == nil {
			reserve^ = prov_empty_region(prov_output(graph))
		}
		region_merge(reserve, set)
		reserve.default = false
		return
	}
	used := set
	used.default = false
	if region_is_empty(used) {
		return
	}
	graph.has_window_event = true
	prov_emit(graph, Prov_Event{kind = .Region_Use, region = used, span = span})
}

// `set` with every local provider's parent added, as `prov_caller_region`
// finds them, but keeping the locals: two arenas over one unsynchronized
// parent share that parent's state.
@(private)
prov_region_closure :: proc(graph: ^Flow_Graph, set: Region_Set) -> Region_Set {
	out := prov_empty_region(graph)
	region_merge(&out, set)
	pending, seen := set.locals, u64(0)
	for pending & ~seen != 0 {
		position := bits.count_trailing_zeros(pending & ~seen)
		seen |= u64(1) << position
		if int(position) >= len(graph.provider_symbols) {
			out.unknown = true
			continue
		}
		if parent, found := graph.provider_parents[graph.provider_symbols[position]]; found {
			region_merge(&out, parent)
			pending |= parent.locals
		}
	}
	return out
}

// What a caller can name of `set`. A region this body created stands for the
// parent its provider draws blocks from: one with no parent recorded, as
// `mem.Arena.init()` has, for the default provider, and a temporary
// provider's, whose parent is not tracked, for an unknown region.
@(private)
prov_caller_region :: proc(graph: ^Flow_Graph, set: Region_Set) -> Region_Set {
	out := prov_empty_region(graph)
	region_merge(&out, set)
	out.unknown ||= set.crowded
	pending, seen := set.locals, u64(0)
	for pending & ~seen != 0 {
		position := bits.count_trailing_zeros(pending & ~seen)
		seen |= u64(1) << position
		provider := INVALID_SYMBOL
		if int(position) < len(graph.provider_symbols) {
			provider = graph.provider_symbols[position]
		}
		if provider == INVALID_SYMBOL {
			out.unknown = true
			continue
		}
		parent, found := graph.provider_parents[provider]
		if !found {
			out.default = true
			continue
		}
		region_merge(&out, parent)
		out.unknown ||= parent.crowded
		pending |= parent.locals
	}
	out.locals, out.crowded = 0, false
	return out
}

// The region an operation given `e` may use: an allocator the analysis cannot
// name, such as one read from a global, is an unknown one.
@(private = "file")
prov_used_region :: proc(graph: ^Flow_Graph, id: Value_Id) -> Region_Set {
	set := prov_storage_region(graph, id)
	if region_is_empty(set) && type_underlying(graph.k.c, prov_value(graph, id).type) == TYPE_ALLOCATOR {
		set = prov_empty_region(graph)
		set.unknown = true
	}
	return set
}

// The region a dropped value is in, for `prov_drop_effects`; nil unless the
// thread summaries collect.
@(private)
prov_drop_region :: proc(graph: ^Flow_Graph, e: Expr) -> Maybe(Prov_Use_Region) {
	if !prov_tracks_allocator_use(graph) || e == nil {
		return nil
	}
	return prov_input_value(graph, e)
}

@(private)
prov_symbol_drop_region :: proc(graph: ^Flow_Graph, id: Symbol_Id) -> Maybe(Prov_Use_Region) {
	if !prov_tracks_allocator_use(graph) {
		return nil
	}
	return id
}

// Each argument's region by callee parameter, which a followed callee's
// allocator use is substituted with; nil when no argument has one.
@(private)
prov_argument_regions :: proc(graph: ^Flow_Graph, v: ^Expr_Call) -> []Region_Set {
	c := graph.k.c
	arguments := prov_call_values(graph, v)
	count := len(arguments)
	out: []Region_Set
	for argument, index in arguments {
		if argument == 0 || !prov_type_has_region(c, prov_value(graph, argument).type) {
			continue
		}
		used := prov_used_region(graph, argument)
		set := prov_caller_region(graph, used) if graph.k.c.thread_facts_pending else prov_region_closure(graph, used)
		if region_is_empty(set) {
			continue
		}
		if out == nil {
			out = make([]Region_Set, count, graph.alloc)
		}
		out[index] = set
	}
	return out
}

// Container operations that may allocate, resize, or free their storage, or
// drop elements that own storage.
@(private = "file")
ALLOCATING_OPS :: bit_set[Container_Op]{
	.Append, .Insert, .Clear, .Resize, .Reserve, .Shrink,
	.Map_Find_Or_Insert, .Map_Try_Insert, .Map_Remove, .Map_Clear, .Map_Reserve, .Map_Shrink,
}

// The allocator use of a call the summaries do not follow into a body: a
// builtin, a compiler-supplied member, a foreign procedure, or a conversion.
// A followed call's, direct or through a value, comes from what its callees'
// summaries settle to. Either way an owner copied from a place may be cloned
// for the call.
@(private)
prov_call_allocator_use :: proc(graph: ^Flow_Graph, v: ^Expr_Call) {
	c := graph.k.c
	if !prov_tracks_allocator_use(graph) || v.dispatch != nil {
		return
	}
	builtin := Builtin_Kind.None
	if sym := symbol_of(c, v.resolution.symbol); sym != nil {
		builtin = sym.builtin
	}
	// `drop` and `free_all` note their operand where they are walked.
	if builtin == .Drop || builtin == .Free_All {
		return
	}
	// A supplied member changes storage only as a growing or shrinking
	// container operation does.
	member := symbol_of(c, v.resolution.chosen_overload)
	supplied := member != nil && member.synth != .None
	changes_storage := !supplied || (member.synth == .Container_Op && member.container_op in ALLOCATING_OPS)
	followed := call_follows_bodies(c, v)
	info := underlying_info(c, call_proc_type(c, v))
	// A text operation borrows its operands rather than copying them.
	_, text := v.operation.(Call_Text)
	_, conversion := v.operation.(Call_Text_Conversion)
	text ||= conversion
	allocators := prov_empty_region(graph)
	for argument, index in prov_call_values(graph, v) {
		if argument == 0 {
			continue
		}
		value := prov_value(graph, argument)
		type := value.type
		span := expr_span(value.origin)
		mode := Param_Mode.Value
		if info != nil && index < len(info.param_modes) {
			mode = info.param_modes[index]
		}
		owns := type_owns_allocation(c, type)
		switch {
		case !text && mode == .Value && clone_may_allocate(c, type) && expression_is_borrowed_place(value.origin):
			prov_note_allocator_use(graph, Region_Set{}, span, owned = true)
		case followed:
		case type_underlying(c, type) == TYPE_ALLOCATOR:
			set := prov_used_region(graph, argument)
			region_merge(&allocators, set)
			prov_note_allocator_use(graph, set, span)
		case !changes_storage:
		case owns && (mode == .Inout || mode == .Move):
			prov_note_allocator_use(graph, prov_storage_region(graph, argument), span, owned = true)
		case !supplied && carrier_is_mutable(c, type) && !type_is_region_provider(c, type):
			if set := prov_viewed_region(graph, argument); !region_is_empty(set) {
				prov_note_allocator_use(graph, set, span)
			}
		}
	}
	if followed || type_is_region_provider(c, prov_type(graph, v)) {
		return
	}
	// An owner a builtin or a supplied member makes, such as `make`'s, `box`'s,
	// or a clone, comes from the allocator it is given or the default.
	allocates := builtin == .Unsafe_New || builtin == .Unsafe_Try_New || builtin == .Unsafe_Free
	if type_owns_allocation(c, prov_type(graph, v)) || allocates {
		prov_note_allocator_use(graph, allocators, v.span, owned = true)
	}
}

// A non-empty container literal allocates from its destination's `via`
// allocator or the default, and a computed string, such as a concatenation,
// from the default.
@(private)
prov_note_fresh_owner :: proc(graph: ^Flow_Graph, e: Expr, via: Expr = nil) {
	if !prov_tracks_allocator_use(graph) || !type_owns_allocation(graph.k.c, prov_type(graph, e)) {
		return
	}
	set: Prov_Use_Region = Region_Set{}
	if via != nil {
		set = prov_input_value(graph, via)
	}
	prov_event(graph, Prov_Event_Allocator_Use{set, expr_span(e), true})
}

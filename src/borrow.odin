// Root and region provenance (design.md "Borrows and lifetimes" and "Allocator
// regions and region provenance"). Root provenance asks which storage a carrier
// borrows, whether it is still there, and whether competing accesses are
// compatible; region provenance asks which allocator region backs a value and
// whether anything survives a reset of it. Both run after every body is checked,
// over a disposable graph from `src/cfg.odin` built in a read-only mode.
//
// What is deliberately not checked is design.md's "What is not checked";
// `tests/run/m5b_trust_boundary.loke` keeps that list executable.
package lokec

import "core:fmt"
import "core:mem"
import "core:slice"

Root_Id :: distinct int
Loan_Id :: distinct int

// The root of storage nothing names: a loan or alias alternative kept beside
// known roots so unresolved storage stays unresolved.
NO_ROOT :: Root_Id(-1)
NO_LOAN :: Loan_Id(-1)

// design.md "Storage roots and borrow carriers". `Param` is the caller's
// storage reached through a borrowed parameter.
Root_Kind :: enum u8 {
	Local,
	Slice_Literal,
	Temporary,
	Static,       // `static` and file-scope storage
	Thread_Local, // outlives every frame on its own thread, nothing on another
	Materialized,
	Provider, // stable control block; moving its owner does not end it
	Param,
	Unknown,
}

// Whether the storage survives the procedure's return. Thread and process
// storage both do; `root_satisfies_retention` tells them apart.
root_outlives_body :: proc(kind: Root_Kind) -> bool {
	#partial switch kind {
	case .Local, .Slice_Literal, .Temporary, .Provider:
		return false
	}
	return true
}

// Whether a root is a binding that names another owner's storage rather than
// a frame slot of its own, such as a switch payload bound over a place
// (design.md "Switch ownership"). A borrow of it also holds the source's loans
// (`prov_borrow`), and those decide where it may go. A binding whose loans end
// with its step, or whose source is unknown, stays a local.
root_names_source :: proc(graph: ^Flow_Graph, root: Prov_Root) -> bool {
	if root.kind != .Local || root.symbol == INVALID_SYMBOL {
		return false
	}
	loans, viewed := graph.view_loans[root.symbol]
	return viewed && len(loans) > 0 && !graph.step_views[root.symbol]
}

// How a diagnostic names a root: quoted source text, or the root's own
// description when the reader wrote no name.
root_label :: proc(root: Prov_Root) -> string {
	if root.symbol == INVALID_SYMBOL {
		return root.name
	}
	return fmt.tprintf("`%s`", root.name)
}

// The subject of a sentence about a root.
root_phrase :: proc(root: Prov_Root) -> string {
	if root.symbol != INVALID_SYMBOL {
		return root_label(root)
	}
	#partial switch root.kind {
	case .Unknown, .Static, .Thread_Local:
		if root.name != "" {
			return root.name
		}
	}
	return fmt.tprintf("the %s it borrows", root_kind_text(root.kind))
}

root_kind_text :: proc(kind: Root_Kind) -> string {
	switch kind {
	case .Local:         return "local"
	case .Slice_Literal: return "slice literal"
	case .Temporary:     return "temporary"
	case .Static:        return "static-duration storage"
	case .Thread_Local:  return "thread-duration storage"
	case .Materialized:  return "materialized constant"
	case .Provider:      return "allocator control block"
	case .Param:         return "caller storage"
	case .Unknown:       return "unknown storage"
	}
	return "storage"
}

Prov_Root :: struct {
	kind:   Root_Kind,
	symbol: Symbol_Id,
	// Canonical storage identity, independent of this pass's root ID.
	storage: Storage_Id,
	span:   Span,
	name:   string,
	// `Param`: which borrowed parameter, for substitution at a direct call.
	param_index: int,
	// What another body may have stored in a global: that global, so the reach
	// effect can tell whose stored carriers a borrow came from.
	origin: Symbol_Id,
	// A `Param` that reaches caller storage: per load depth, the `content` loan
	// standing for what that many loads through it read. The last stands for
	// every depth from its own on.
	content_loans: []Loan_Id,
	// A carrier `Param` whose pointee has carrier paths: per path of
	// `carrier_pointee_shape`, and per load depth as `content_loans`, the
	// `content` loan standing for what that many loads read when the first goes
	// along that path, so a result read out of one field does not name its
	// siblings (design.md "Procedure result contracts").
	pointee_loans: [][]Loan_Id,
	// A `Static` stand-in, while a body is summarized, for what the callback in
	// parameter `param_index` may leave in its argument `argument`. Only the
	// `Callback_Write` and `Callback_Read` summaries read it; it constrains
	// nothing else.
	forwarded: bool,
	argument:  int,
	// `Provider`: the region the control block belongs to. Empty means
	// unrecorded, which every reset reaches.
	region: Region_Set,
	// `Temporary`: whether a local extended it to the block's end, its source
	// type, and the slot keeping its borrows live when its drop runs a hook.
	extended: bool,
	dropped:  Type_Id,
	content:  int,
	// `Slice_Literal`: the slots holding what its hidden array holds, by the
	// array's carrier shape, which stores and loads through a loan of it find as
	// they find a named local's content.
	slots:    []int,
	// The managed temporary lending this root, before a view or erasure.
	owner:    Expr,
}

// The slots holding what a root's own storage holds, a local's or a slice
// literal's; none for a temporary root.
root_own_slots :: proc(graph: ^Flow_Graph, root: Prov_Root) -> []int {
	return root.slots if len(root.slots) > 0 else graph.own_slots[root.symbol]
}

// The slots of the storage a loan names that this body holds itself. What a
// parameter already held when the call began, and what its carrier points at,
// are in storage it cannot name (`read_caller_slots`).
loan_own_slots :: proc(graph: ^Flow_Graph, loan: Prov_Loan, root: Prov_Root) -> []int {
	if len(root.slots) == 0 && root.kind == .Param {
		sym := symbol_of(graph.k.c, root.symbol)
		if sym == nil || loan.content || type_is_carrier(graph.k.c, sym.type) {
			return nil
		}
	}
	return root_own_slots(graph, root)
}

// ---------------------------------------------------------- projections --

Proj_Kind :: enum u8 {
	Field,
	Range, // half-open constant element range; an index `i` is [i, i+1)
	Wild,  // anything not statically distinct; overlaps every sibling
}

Proj_Step :: struct {
	precision: Precision_Loss,
	kind:      Proj_Kind,
	// design.md "@(synchronized)": the step selects a synchronized field from
	// outside its package, so reaching the place is exclusive access.
	synchronized: bool,
	// An element of a dynamic array, which an operation may move to another
	// index. Carrier slots see that happen (`rearrange_carriers`); region facts,
	// being flow-insensitive, do not (`prov_region_path`).
	shifts:    bool,
	lo:        i64,
	hi:        i64,
}

path_is_synchronized :: proc(path: []Proj_Step) -> bool {
	for step in path {
		if step.synchronized {
			return true
		}
	}
	return false
}

proj_field :: proc(index: int) -> Proj_Step {
	return Proj_Step{kind = .Field, lo = i64(index)}
}

proj_range :: proc(lo, hi: i64) -> Proj_Step {
	return Proj_Step{kind = .Range, lo = lo, hi = hi}
}

proj_wild :: proc() -> Proj_Step {
	return Proj_Step{kind = .Wild}
}

// Element `index` of a dynamic array, one by itself up to the budget.
proj_dynamic_element :: proc(index: i64) -> Proj_Step {
	return Proj_Step{kind = .Range, lo = index, hi = index + 1, shifts = true}
}

// Whether two steps name one place, whatever else each records of how it was
// reached.
same_step :: proc(a, b: Proj_Step) -> bool {
	return a.kind == b.kind && a.lo == b.lo && a.hi == b.hi
}

// Two paths into one root overlap unless some step proves them disjoint, so a
// prefix overlaps everything below it.
paths_overlap :: proc(a, b: []Proj_Step) -> bool {
	shared := min(len(a), len(b))
	for index in 0 ..< shared {
		if !steps_overlap(a[index], b[index]) {
			return false
		}
	}
	return true
}

@(private)
steps_overlap :: proc(a, b: Proj_Step) -> bool {
	if a.kind != b.kind {
		return true // nothing was proven distinct
	}
	#partial switch a.kind {
	case .Field:
		return a.lo == b.lo
	case .Range:
		return a.lo < b.hi && b.lo < a.hi
	}
	return true
}

@(private)
path_is_indistinct :: proc(path: []Proj_Step) -> bool {
	for step in path {
		if step.kind == .Wild || step.kind == .Range && step.hi - step.lo > 1 {
			return true
		}
	}
	return false
}

// Whether `path` selects one place: fields and single constant elements,
// none merged.
@(private)
prov_path_names_one_place :: proc(path: []Proj_Step) -> bool {
	for step in path {
		if step.kind != .Field && !(step.kind == .Range && step.hi == step.lo + 1) || step.precision != {} {
			return false
		}
	}
	return true
}

@(private)
path_has_exact_prefix :: proc(path, prefix: []Proj_Step) -> bool {
	if len(prefix) > len(path) {
		return false
	}
	for step, index in prefix {
		if !same_step(step, path[index]) {
			return false
		}
	}
	return true
}

// Whether the place `path` names may be the one `tail` names inside a value
// stored at some place: whether its last steps may overlap `tail`.
@(private)
prov_path_may_end_in :: proc(path, tail: []Proj_Step) -> bool {
	return len(path) >= len(tail) && paths_overlap(path[len(path) - len(tail):], tail)
}

@(private)
prov_same_path :: proc(a, b: []Proj_Step) -> bool {
	return len(a) == len(b) && path_has_exact_prefix(a, b)
}

// ---------------------------------------------------------------- loans --

// One borrow. A `mutable` one excludes every competing access; an immutable one
// permits compatible reads.
Prov_Loan :: struct {
	root:    Root_Id,
	path:    []Proj_Step,
	mutable: bool,
	span:    Span,
	what:    string,
	// A `Param` loan of what the parameter already held when the call began, as
	// opposed to one of its own storage (design.md "Retaining a borrow").
	content: bool,
	// A `content_loans` entry: how many loads below the parameter it stands for.
	depth: int,
	// A `pointee_loans` entry: the position in `carrier_pointee_shape` of the
	// path its first load goes along, plus one; zero for every other loan.
	pointee: int,
	// A `thread_local` borrow a spawned call leaves in an argument, which the
	// spawn reports from the summary. One left by any other call crosses no
	// further than a borrow taken directly.
	written_back: bool,
}

// What a later event wants of a slot's value. A `Kept` value is only held on to by
// a use of a view of its storage (`Prov_Event.keeps_live`): what it borrows must
// last, but nothing reads it, so it suspends nothing it reborrows
// (`live_reborrow_of`).
Slot_Use :: enum u8 {
	None,
	Kept,
	Used,
}

// What a slot is part of. `Local` is a variable's or parameter's own storage,
// `Literal` a slice literal's hidden array, and `Caller` what a parameter's loan
// stands for in storage this body cannot name (`prov_caller_slots`). A `Temporary`
// is a value only its own expression reads.
Prov_Slot_Kind :: enum u8 {
	Temporary,
	Local,
	Literal,
	Caller,
}

// A carrier value the analysis follows: a variable, parameter or expression
// temporary. Reaching loans are per slot, so overwriting one carrier ends only
// the value that was overwritten.
Prov_Slot :: struct {
	precision: Precision_Loss,
	kind:      Prov_Slot_Kind,
	// Holds a read-only view of what its loans lend, which may be mutable, so a read
	// of the same storage conflicts with none of them (`prov_view_through_carrier`).
	read_only_hold: bool,
	symbol:    Symbol_Id,
	name:      string,
	span:      Span,
	// The place inside the value this slot holds, from `carrier_shape`; empty for
	// the whole value.
	path: []Proj_Step,
	// The leaf carrier's type at `path`, so a borrow published into it takes the
	// field's own capability. INVALID_TYPE for non-content and truncated paths.
	content_type: Type_Id,
	// The value type `path` belongs to; an unshaped dependency is not projected.
	content_shape: Type_Id,
	// `path` stands for every carrier below it, so a write joins rather than
	// replaces.
	content_truncated: bool,
	// The borrow this temporary stands for, weakened once its destination is known.
	borrow: Prov_Slot_Borrow,
	// A result held across its exit path's deferred statements.
	returned: bool,
	// Read out through a carrier, so what it copies is known only once the
	// `Load` is resolved.
	loaded: bool,
	// Stands for what caller storage a parameter reaches holds at `path`
	// (`prov_caller_slots`), and that is a mutable carrier; `caller_one` when
	// that storage is one place, so a store lands here (`publish_into_caller`).
	caller_mutable: bool,
	caller_one:     bool,
	// Stands for one element of a view parameter's caller storage, which only
	// a store naming that element lands in and replaces (`prov_view_element`).
	caller_element: bool,
	// A definition has pointed it into an element of a view parameter, and one has
	// pointed it anywhere else (`prov_note_element_pointer`).
	element_defs:   bool,
	other_defs:     bool,
	// Read by a reordering, or handed back by a container's removal, whose reborrow
	// of what it read is a move (`Prov_Reborrow.moved`).
	moved_out:      bool,
	// Loaded on the way to a switch subject, which a payload binding views
	// through it (`prov_subject_view`).
	viewed: bool,
	// The paths, below the storage this slot's loans name, that its value may
	// point at, as `[count]` for `&mut h^.count`, and both `[count]` and
	// `[total]` for a pointer chosen between borrows of the two
	// (`prov_note_offset`). Nil until a definition names storage, and then
	// taken to point at the whole of it.
	offsets: []Prov_Offset,
	// Places past the limits were merged into a shared prefix
	// (`prov_union_offsets`), so this covers places the value may never point at
	// (design.md "Minimum provenance precision").
	offsets_merged: bool,
}

// One place a value may point at (`Prov_Slot.offsets`): `path` below the
// storage it was reached in, which the carrier slot `storage` named. A value
// holding places of several such storages is taken to point at each of its
// places in every storage it names; `storage` only says which a place counts
// against when the limits merge places (`prov_union_offsets`).
Prov_Offset :: struct {
	path:    []Proj_Step,
	storage: int,
}

// How one definition of a named view slot relates what it views to the range
// a fresh borrow lends (`prov_note_view`): that borrow itself, as
// `s := &mut a[0:2]`; elements `lo` up to `hi` of another such slot, as
// `t := &mut s[1:]`, with `hi` -1 for its end; or `unknown`. A borrow whose
// end is not constant, as `&mut d[:]` of a dynamic array, lends a range its
// loan's last step cannot name, so it is `open`, starting at element `lo`
// of what it is taken from.
Prov_View_Def :: struct {
	// For the reslice about to be defined, one more than the slot it defines.
	slot:     int,
	loan:     Loan_Id,
	// One more than the slot resliced, or 0.
	from:     int,
	lo, hi:   i64,
	unknown:  bool,
	open:     bool,
	// For a reslice, the definitions of the slot resliced that may reach it,
	// as indices into its `view_defs`, the slot's count among them standing
	// for one not recorded (`solve_view_defs`).
	reaching: []int,
}

// design.md "Places and overlap": the constant element `index` of a named
// view that a place reached through it is in, as `s[1]` for `s[1].count`
// (`prov_view_at`). `slot` is one more than the view's slot, or 0 when the place
// is in no such element. For a view parameter, `loan` is one more than its own
// loan. For a local view, `loan` is 0 and `reaching` are the definitions of the
// slot that may reach the place (`solve_view_defs`).
Prov_View_At :: struct {
	slot:     int,
	loan:     int,
	index:    i64,
	reaching: []int,
}

// A slot holding no fresh borrow. Zero would name loan 0 and event 0.
empty_prov_slot :: proc(symbol: Symbol_Id) -> Prov_Slot {
	return Prov_Slot {
		kind               = symbol != INVALID_SYMBOL ? .Local : .Temporary,
		symbol             = symbol,
		content_type       = INVALID_TYPE,
		content_shape      = INVALID_TYPE,
	}
}

// Whether a slot holds a carrier stored in lasting storage, a local's or a slice
// literal's hidden array's (design.md "Slice literals"), rather than a value
// only its own expression reads.
prov_slot_is_stored :: proc(entry: Prov_Slot) -> bool {
	return entry.kind == .Local || entry.kind == .Literal
}

// One provenance event, by its block and its index there.
Prov_Event_At :: struct {
	block: Block_Id,
	event: int,
}

// A carrier derived from an existing mutable carrier reborrows it, read-only or
// mutably: the source is suspended until the reborrow's last use (design.md
// "Weakening and reborrows").
Prov_Reborrow :: struct {
	source:  int,
	derived: int,
	span:    Span,
	mutable: bool,
	// Only extends the reborrow `source` belongs to: its copies do not suspend it.
	passes_on: bool,
	// `derived` was loaded out of `source` through these carriers, so storing it
	// back into one of them, as `cur = cur^.next` does, replaces that
	// carrier's value rather than holding a second path to `source`.
	via: []int,
	// Taken from a read-only carrier that may come to hold a reborrow of a mutable one,
	// which extends it only if that carrier does, which is settled once every link is
	// made (`prov_settle_pending_reborrows`). Until then the solve does not see it.
	pending: bool,
	// Links a carrier to where a store through carriers landed it, or carriers a call
	// may have copied to each other, in both directions (`prov_link_copied_carriers`):
	// the `Prov_Event.store_id` of that store or call, before which it holds nothing here.
	from_store: int,
	// `derived` took the carrier from `source` in a reordering (`prov_assign_permutes`),
	// which leaves `source` a carrier of its own, or a container's removal, which leaves
	// the next element there, so `source` is not suspended, while what `source` was
	// itself derived from goes on to where the carrier went.
	moved: bool,
}

// A loan of `place`, reached through carriers, at `path` below their pointee
// (compiler-architecture.md "Ownership, lifecycle, and provenance"). `slot` is a
// snapshot of the carriers, whose value carries a bit of its own (`place_bit`).
// `what` names what it lends. A borrow, slice, or traversal of a place `borrows`
// it (design.md "Weakening and reborrows"), where a switch's payload bindings do
// not (design.md "Switch ownership"). `element` is the constant element of a view
// the place is in, if any.
Prov_Place_Loan :: struct {
	slot:    int,
	paths:   [][]Proj_Step,
	mutable: bool,
	borrows: bool,
	what:    string,
	span:    Span,
	place:   string,
	element: Prov_View_At,
	// The slots of the view parameter's element the place is in (`carriers_element`).
	in_element: Prov_Element_Slots,
}

// ---------------------------------------------------- retention targets --

// How long a destination that stores a borrow lives.
Retain_Kind :: enum u8 {
	None,
	Process,
	Thread,
	Caller,
}

// Whether a root's storage is still valid at a destination of this kind. An
// allocation may be released or reset first, a `Param` answers with its own
// `@(escape)` contract, and unknown provenance proves nothing.
root_satisfies_retention :: proc(kind: Root_Kind, into: Retain_Kind) -> bool {
	#partial switch kind {
	case .Static, .Materialized:
		return true
	case .Thread_Local:
		return into != .Process
	}
	return false
}

retain_kind_for_root :: proc(kind: Root_Kind) -> Retain_Kind {
	#partial switch kind {
	case .Static:       return .Process
	case .Thread_Local: return .Thread
	case .Param:        return .Caller
	}
	return .None
}

retain_kind_text :: proc(kind: Retain_Kind) -> string {
	switch kind {
	case .Process: return "process-lifetime storage"
	case .Thread:  return "thread-lifetime storage"
	case .Caller:  return "storage the caller owns"
	case .None:    return "storage"
	}
	return "storage"
}

// The level a parameter must be written at to be stored in this kind of place.
retain_kind_level :: proc(kind: Retain_Kind) -> Escape_Level {
	#partial switch kind {
	case .Process, .Thread:
		return .Static
	}
	return .Stored
}

// ------------------------------------------------------- escape levels --

// `@(escape=<level>)`: what a call may leave behind that depends on one
// parameter. Each level allows everything the one before it does.
Escape_Level :: enum u8 {
	None,   // nothing outlives the call, not even a result
	Result, // a result may borrow it (the default)
	Stored, // it may be retained in one of the call's mutable destinations
	Static, // it may be retained in process-lifetime storage
}

escape_level_name :: proc(level: Escape_Level) -> string {
	switch level {
	case .None:   return "none"
	case .Result: return "result"
	case .Stored: return "stored"
	case .Static: return "static"
	}
	return "result"
}

// ------------------------------------------------------------- the solver --

// Per-body solver state. `reach` (forward) is which loans each slot may hold,
// `live` (backward) which slots have a later use; a loan is live wherever a slot
// holding it is.
@(private)
Prov_Solve :: struct {
	// The slots a `Publish` being run lands in (`link_landed_stores`).
	landed: ^[dynamic]int,
	// Why a diagnostic may be imprecise; never consulted by the rules.
	precision:            []Precision_Loss,
	merged_precision:     Precision_Loss,
	diagnostic_precision: Precision_Loss,
	graph:   ^Flow_Graph,
	k:       ^Checker,
	slots:   int,
	loans:   int,
	// Bytes per slot row, two bits per loan. Bytes measured faster than 64-bit
	// words and than unpacked rows on the corpus. Bit `i` says the slot may hold
	// loan `i`; bit `loans + i` says it may hold it on a path that already ended
	// it, so `free` may release it twice. Kept per slot, a pointer reassigned
	// after its release is not confused with the released one, and the stale
	// bits travel with every copy of the row.
	row_bytes: int,
	reach:   []u8,
	// A loan ended on every path to here. Checks skip only these, so an
	// invalidation that reaches its own loop head still meets the loan it ends.
	ended:   []bool,
	// The slots the last `Rearrange` reached.
	rearranged: [dynamic]int,
	// Per slot, which links its value may have come through, as a handle of
	// `link_rows` (`solve_links_held`).
	links_held: []u32,
	// Each distinct row, with one bit per reborrow, kept once however many slots and
	// blocks hold it. Handle 0 holds no link.
	link_rows:      [dynamic][]u8,
	link_row_ids:   map[string]u32,
	link_row_bytes: int,
	// Scratch: a value being defined, a row being changed, and the reborrows of one
	// slot.
	link_row_value: []u8,
	link_row_edit:  []u8,
	link_row_mask:  []u8,
	// The reborrows into each slot, those through each carrier they were loaded
	// through (`Prov_Reborrow.via`), and those each `store_id` makes.
	links_into:     [][dynamic]int,
	links_via:      [][dynamic]int,
	links_of_store: [][dynamic]int,
	// Whether a definition of a reborrow's derived slot names its source. One that none
	// does, as a capture's copy of what its source derives from, is made by each of them.
	link_is_named:  []bool,
	// The reborrows of each source slot, by index in `graph.reborrows` and in
	// its order (`reborrows_of`), as of `reborrows_indexed` of them.
	reborrow_starts:    []int,
	reborrow_indices:   []int,
	reborrows_indexed:  int,
	// Scratch: the loans one event ends, and their indices.
	released: []bool,
	released_indices: [dynamic]int,
	// Scratch: the slots `live_place_bits` gathered.
	live_slots: [dynamic]int,
	// Scratch: the loans a load has gone on through, and those it has yet to.
	load_expanded: []bool,
	load_pending:  []u8,
	live:    []Slot_Use,
	uses:    []Span,
	merged:  []u8,
}

@(private)
reach_row :: proc(state: ^Prov_Solve, buffer: []u8, slot: int) -> []u8 {
	return buffer[slot * state.row_bytes:(slot + 1) * state.row_bytes]
}

// The bit a place loan's snapshot sets in its row, after every loan's two
// (`Prov_Place_Loan`). Only rows are joined over it, so no loan's check sees it.
@(private = "file")
place_bit :: proc(state: ^Prov_Solve, place_loan: int) -> int {
	return 2 * state.loans + place_loan
}

// The later use keeping a place loan lent: of its snapshot, or else of a live
// slot carrying its bit. False when nothing live carries it. `carrying` is what
// `live_place_bits` gathered for this event.
@(private = "file")
place_loan_use :: proc(state: ^Prov_Solve, place_loan: int, live: []Slot_Use, uses: []Span, carrying: Live_Place_Bits) -> (Span, bool) {
	snapshot := state.graph.place_loans[place_loan].slot
	if live[snapshot] != .None {
		return uses[snapshot], true
	}
	bit := place_bit(state, place_loan)
	if !bit_get(carrying.row, bit) {
		return {}, false
	}
	for slot in carrying.slots {
		if bit_get(reach_row(state, state.reach, slot), bit) {
			return uses[slot], true
		}
	}
	return {}, false
}

// The slots an event's place loans may be kept lent by, and every bit they hold.
// A read conflicts with no slot holding only a read-only view
// (`Prov_Slot.read_only_hold`).
@(private = "file")
Live_Place_Bits :: struct {
	slots: []int,
	row:   []u8,
}

@(private = "file")
live_place_bits :: proc(state: ^Prov_Solve, live: []Slot_Use, read: bool) -> Live_Place_Bits {
	clear(&state.live_slots)
	mem.zero_slice(state.merged)
	for use, slot in live {
		if use != .None && !(read && state.graph.prov_slots[slot].read_only_hold) {
			append(&state.live_slots, slot)
			bytes_or(state.merged, reach_row(state, state.reach, slot))
		}
	}
	return {state.live_slots[:], state.merged}
}

@(private)
bit_get :: proc(row: []u8, index: int) -> bool {
	return row[index >> 3] & (1 << u8(index & 7)) != 0
}

// Iterates every still-valid loan held by some slots, as (slot, loan index):
// each slot with a later use (`live_loans`), or each of a list (`slots_loans`).
@(private = "file")
Live_Loans :: struct {
	state: ^Prov_Solve,
	slots: []int,
	every: bool, // every slot in `state`, rather than `slots`
	live:  []Slot_Use,
	at:    int,
	index: int,
	slot:  int,
	row:   []u8,
}

@(private = "file")
live_loans :: proc(state: ^Prov_Solve, live: []Slot_Use) -> Live_Loans {
	return Live_Loans{state = state, live = live, every = true, at = -1, index = -1}
}

@(private)
slots_loans :: proc(state: ^Prov_Solve, slots: []int) -> Live_Loans {
	return Live_Loans{state = state, slots = slots, at = -1, index = -1}
}

// `it.index < 0` means the next slot's row still has to be fetched.
@(private)
next_live_loan :: proc(it: ^Live_Loans) -> (slot: int, index: int, ok: bool) {
	count := it.every ? it.state.slots : len(it.slots)
	for {
		if it.index < 0 {
			it.at += 1
			if it.at >= count {
				return 0, 0, false
			}
			it.slot = it.every ? it.at : it.slots[it.at]
			if it.live != nil && it.live[it.slot] == .None {
				continue
			}
			it.row = reach_row(it.state, it.state.reach, it.slot)
			it.index = 0
		}
		if it.index >= it.state.loans {
			it.index = -1
			continue
		}
		index = it.index
		it.index += 1
		if bit_get(it.row, index) && !it.state.ended[index] {
			return it.slot, index, true
		}
	}
}

// Sets up `state` as a walk reaches `block`; false for a block no path reaches.
@(private = "file")
enter_block :: proc(state: ^Prov_Solve, block: ^Flow_Block) -> bool {
	copy(state.reach, block.reach_entry)
	copy(state.precision, block.precision_entry)
	copy(state.ended, block.ended_entry)
	return block.prov_visited
}

@(private)
bit_mark :: proc(row: []u8, index: int) {
	row[index >> 3] |= 1 << u8(index & 7)
}

@(private)
bit_clear :: proc(row: []u8, index: int) {
	row[index >> 3] &~= 1 << u8(index & 7)
}

@(private)
bytes_or :: proc(into: []u8, from: []u8) {
	for value, index in from {
		into[index] |= value
	}
}

// A body whose checking failed is skipped, so provenance adds no noise to it.
Checked_Body :: struct {
	literal: ^Expr_Proc,
	clean:   bool,
}

// The whole program's provenance, after every body is checked. Summaries settle
// first, over a worklist of direct callers, then each body's diagnostics run.
// One graph is built and released at a time.
analyze_program_provenance :: proc(k: ^Checker) {
	compute_global_writes(k)
	settle_result_summaries(k)
	check_proc_contracts(k)
	if k.c.thread_summaries_wanted {
		compute_thread_summaries(k)
	}
	for body in k.c.checked_bodies {
		if body.clean {
			analyze_provenance(k, body.literal)
		}
	}
	for body in k.c.checked_bodies {
		if body.clean {
			check_declared_escape(k, body.literal)
		}
	}
}

// A caller may precede its callee, so every body is queued again; one is revisited
// only if a summary it read grew since its last visit (`clock` stamps `grew_at`
// and `visited_at`).
@(private = "file")
settle_result_summaries :: proc(k: ^Checker) {
	clock := 0
	grew_at := make([]int, len(k.c.symbols), context.temp_allocator)
	visited_at := make([]int, len(k.c.symbols), context.temp_allocator)
	visit :: proc(k: ^Checker, clock: ^int, grew_at, visited_at: []int, literal: ^Expr_Proc) -> bool {
		visited_at[int(literal.symbol)] = clock^
		grew := summarize_body(k, literal)
		if grew {
			clock^ += 1
			grew_at[int(literal.symbol)] = clock^
		}
		return grew
	}
	stale :: proc(c: ^Compiler, grew_at, visited_at: []int, literal: ^Expr_Proc) -> bool {
		for callee in c.result_summary_dependencies[literal.symbol] {
			if grew_at[int(callee)] > visited_at[int(literal.symbol)] { return true }
		}
		return false
	}
	for body in k.c.checked_bodies {
		if body.clean {
			_ = visit(k, &clock, grew_at, visited_at, body.literal)
		}
	}
	queue := make([dynamic]^Expr_Proc, 0, len(k.c.checked_bodies), context.temp_allocator)
	queued := make([]bool, len(k.c.symbols), context.temp_allocator)
	callers := make(map[Symbol_Id][dynamic]^Expr_Proc, context.temp_allocator)
	// How many of each body's dependencies `callers` has: a resolved callback
	// adds more on a later round, appended after them.
	registered := make([]int, len(k.c.symbols), context.temp_allocator)
	register :: proc(c: ^Compiler, callers: ^map[Symbol_Id][dynamic]^Expr_Proc, registered: []int, literal: ^Expr_Proc) {
		dependencies := c.result_summary_dependencies[literal.symbol]
		for callee in dependencies[registered[int(literal.symbol)]:] {
			if callee not_in callers^ {
				callers^[callee] = make([dynamic]^Expr_Proc, 0, 4, context.temp_allocator)
			}
			append(&callers^[callee], literal)
		}
		registered[int(literal.symbol)] = len(dependencies)
	}
	for body in k.c.checked_bodies {
		if !body.clean {
			continue
		}
		append(&queue, body.literal)
		queued[int(body.literal.symbol)] = true
		register(k.c, &callers, registered, body.literal)
	}
	for head := 0; head < len(queue); head += 1 {
		literal := queue[head]
		queued[int(literal.symbol)] = false
		if !stale(k.c, grew_at, visited_at, literal) {
			continue
		}
		grew := visit(k, &clock, grew_at, visited_at, literal)
		register(k.c, &callers, registered, literal)
		if !grew {
			continue
		}
		// Bound to a local first: iterating the map index directly miscompiles.
		affected := callers[literal.symbol]
		for caller in affected {
			index := int(caller.symbol)
			if !queued[index] {
				append(&queue, caller)
				queued[index] = true
			}
		}
	}
}

// `@(escape=none)` contradicted by the body's own result summary.
@(private = "file")
check_declared_escape :: proc(k: ^Checker, literal: ^Expr_Proc) {
	sym := symbol_of(k.c, literal.symbol)
	if sym == nil {
		return
	}
	summary, found := k.c.result_summaries[literal.symbol]
	if !found {
		return
	}
	for id, index in sym.param_symbols {
		bound := symbol_of(k.c, id)
		if bound == nil || bound.escape != .None {
			continue
		}
		if result_uses_param(summary^, index) {
			errorf(
				k.c,
				bound.span,
				"L0644",
				"`%s` is written `@(escape=none)`, but the result of `%s` may borrow it",
				identifier_text(k.c, bound.name),
				identifier_text(k.c, sym.name),
			)
			add_precision_notes(k.c, bound.span, summary.precision)
		}
	}
}

// One round of one body's result equations; returns whether its summary grew.
@(private = "file")
summarize_body :: proc(k: ^Checker, literal: ^Expr_Proc) -> bool {
	sym := symbol_of(k.c, literal.symbol)
	if sym == nil {
		return false
	}
	writes := proc_may_write_owners(k.c, sym)
	returns := sym.result != INVALID_TYPE
	if !returns && !writes {
		return false
	}
	defer free_all(k.c.analysis_allocator)
	graph := build_flow_graph(k, literal, .Prov_Summary)
	if graph == nil {
		return false
	}
	changed := writes && collect_written_regions(k.c, graph, literal.symbol, sym)
	record_summary_dependencies(k.c, literal.symbol, graph.summary_callees[:])
	// What a body stores in caller storage needs solving only when it borrows
	// `thread_local` storage at all, or may store what an argument held.
	stores_thread_local := writes && graph_borrows_thread_local(graph)
	moves_carriers := writes && graph_may_move_carriers(graph)
	summary: ^Result_Provenance
	if returns {
		found: bool
		if summary, found = k.c.result_summaries[literal.symbol]; !found {
			summary = new(Result_Provenance, k.c.semantic_allocator)
			summary^ = new_result_provenance(k.c, len(sym.param_symbols), sym.result, true, k.c.semantic_allocator)
			k.c.result_summaries[literal.symbol] = summary
		}
	}
	if !returns && !stores_thread_local && !moves_carriers {
		return changed
	}
	state := Prov_Solve{graph = graph, k = k}
	if !prepare_state(&state) {
		return changed
	}
	solve_reaching(&state)
	if stores_thread_local {
		changed = collect_thread_local_writes(&state, literal.symbol) || changed
	}
	if moves_carriers {
		changed = collect_carrier_moves(&state, literal.symbol) || changed
	}
	if returns {
		changed = collect_escape_provenance(&state, literal.symbol, summary) || changed
	}
	return changed
}

// design.md "Values that contain borrows": what a body may store in the storage
// a writable parameter names out of what that argument held, as `links[0] =
// links[1]` or `pair^.a = pair^.b` (`prov_call_carrier_moves`).
Carrier_Move :: struct {
	// The carrier types stored there, or `any` for every one.
	types: []Type_Id,
	any:   bool,
	// A mutable carrier stored there may also stay where it was read, unlike
	// one read from below the place it lands, as `list^.head = list^.head^.next`
	// (design.md "Weakening and reborrows").
	copied: bool,
}

@(private = "file")
graph_may_move_carriers :: proc(graph: ^Flow_Graph) -> bool {
	for block in graph.blocks {
		for event in block.prov {
			switch {
			case event.kind == .Publish && len(event.sources) > 0 && len(event.into) > 0, event.kind == .Rearrange:
				return true
			case event.kind == .Def && len(event.sources) > 0:
				if slot_stores_in_inout(graph, event.slot) {
					return true
				}
			}
		}
	}
	return false
}

// Whether `slot` is storage of an `inout` parameter: a store into it needs no
// carrier to name the caller's storage.
@(private = "file")
slot_stores_in_inout :: proc(graph: ^Flow_Graph, slot: int) -> bool {
	sym := symbol_of(graph.k.c, graph.prov_slots[slot].symbol)
	return sym != nil && sym.kind == .Parameter && sym.mode == .Inout
}

// `Carrier_Move` of a body, read off each store that reaches its end of solving.
@(private = "file")
collect_carrier_moves :: proc(state: ^Prov_Solve, declaration: Symbol_Id) -> bool {
	changed := false
	for block in state.graph.blocks {
		if !enter_block(state, block) {
			continue
		}
		for event in block.prov {
			#partial switch event.kind {
			case .Publish:
				changed = note_published_move(state, event, declaration) || changed
			case .Def:
				changed = note_inout_move(state, event, declaration) || changed
			case .Rearrange:
				changed = note_rearranged_move(state, event, declaration) || changed
			}
			run_prov_event(state, event, state.reach, state.ended)
		}
	}
	return changed
}

// A store through carriers moves what it stores to every loan they hold.
@(private = "file")
note_published_move :: proc(state: ^Prov_Solve, event: Prov_Event, declaration: Symbol_Id) -> bool {
	graph := state.graph
	mem.zero_slice(state.merged)
	for source in event.sources {
		bytes_or(state.merged, reach_row(state, state.reach, source))
	}
	if event.strips {
		for slot in event.into {
			for &byte, index in state.merged {
				byte &= ~reach_row(state, state.reach, slot)[index]
			}
		}
	}
	types, any := carried_types(graph.k.c, event.carried, graph.alloc)
	changed := false
	it := slots_loans(state, event.into)
	for _, index in next_live_loan(&it) {
		loan := graph.loans[index]
		// Reordering copies nothing: no place is deep enough to count.
		level := event.permutes ? -1 : loan.depth + 1
		changed = note_carrier_move(state, declaration, loan.root, level, types, any) || changed
	}
	return changed
}

// A definition of an `inout` parameter's storage moves what it stores there.
@(private = "file")
note_inout_move :: proc(state: ^Prov_Solve, event: Prov_Event, declaration: Symbol_Id) -> bool {
	graph := state.graph
	if len(event.sources) == 0 || !slot_stores_in_inout(graph, event.slot) {
		return false
	}
	mem.zero_slice(state.merged)
	for source in event.sources {
		if source != event.slot {
			bytes_or(state.merged, reach_row(state, state.reach, source))
		}
	}
	types, any := carried_types(graph.k.c, slot_carrier_type(graph, event.slot), graph.alloc)
	symbol := graph.prov_slots[event.slot].symbol
	changed := false
	for root, at in graph.roots {
		if root.kind == .Param && root.symbol == symbol {
			changed = note_carrier_move(state, declaration, Root_Id(at), 0, types, any) || changed
		}
	}
	return changed
}

// A call's own moves apply to every parameter its argument's carriers name.
@(private = "file")
note_rearranged_move :: proc(state: ^Prov_Solve, event: Prov_Event, declaration: Symbol_Id) -> bool {
	graph := state.graph
	changed := false
	it := slots_loans(state, event.into)
	for _, index in next_live_loan(&it) {
		root := graph.roots[int(graph.loans[index].root)]
		if root.kind == .Param {
			changed = merge_carrier_move(graph.k.c, declaration, root.param_index, event.rearranged) || changed
		}
	}
	return changed
}

// A store of `types` into parameter storage at `root`, at `level` loads below
// the parameter, of what `state.merged` holds: a move when that holds what the
// same parameter held, and a copy when it came from no deeper than it lands.
@(private = "file")
note_carrier_move :: proc(
	state: ^Prov_Solve, declaration: Symbol_Id, root: Root_Id, level: int, types: []Type_Id, any: bool,
) -> bool {
	graph := state.graph
	c := graph.k.c
	descriptor := graph.roots[int(root)]
	if descriptor.kind != .Param {
		return false
	}
	type := symbol_of(c, descriptor.symbol).type
	pointee := carrier_pointee_shape(c, type)
	held, copied := false, false
	for loan, index in graph.loans {
		if loan.root != root || !loan.content || !bit_get(state.merged, index) {
			continue
		}
		held = true
		// A mutable carrier stored as a read-only one is a reborrow all the same.
		// One pointee path's loan says whether that path holds one; otherwise
		// the path it is on is not known.
		mutable := loan.mutable
		if loan.pointee == 0 && len(pointee) > 0 {
			mutable = false
			for path in pointee { mutable ||= path.mutable }
		}
		copied ||= mutable && loan.depth <= level
	}
	if !held {
		return false
	}
	return merge_carrier_move(c, declaration, descriptor.param_index, Carrier_Move{types, any, copied})
}

// The carriers in a value of `type`, or `any` when they are not all known. An
// allocator and a region provider are shared by design, so moving one says
// nothing (design.md "Weakening and reborrows").
carried_types :: proc(c: ^Compiler, type: Type_Id, allocator: mem.Allocator) -> (out: []Type_Id, any: bool) {
	if type == INVALID_TYPE {
		return nil, true
	}
	list := make([dynamic]Type_Id, 0, 2, allocator)
	add :: proc(c: ^Compiler, list: ^[dynamic]Type_Id, type: Type_Id) {
		if !type_is_region_provider(c, type) && type_underlying(c, type) != TYPE_ALLOCATOR && !slice.contains(list[:], type) {
			append(list, type)
		}
	}
	if type_is_carrier(c, type) {
		add(c, &list, type)
		return list[:], false
	}
	for path in carrier_shape(c, type) {
		if path.truncated {
			return nil, true
		}
		add(c, &list, path.type)
	}
	return list[:], false
}

@(private = "file")
merge_carrier_move :: proc(c: ^Compiler, declaration: Symbol_Id, index: int, move: Carrier_Move) -> bool {
	if !move.any && len(move.types) == 0 {
		return false
	}
	rows, found := c.carrier_moves[declaration]
	if !found {
		rows = make([]Carrier_Move, len(symbol_of(c, declaration).param_symbols), c.semantic_allocator)
		c.carrier_moves[declaration] = rows
	}
	row := &rows[index]
	changed := move.any && !row.any || move.copied && !row.copied
	row.any ||= move.any
	row.copied ||= move.copied
	for type in move.types {
		changed = set_add(&row.types, type, c.semantic_allocator) || changed
	}
	return changed
}

// What a call may do to each of its `count` arguments' carriers, by argument,
// from the summary of every body it may run; `consulted` collects those. A
// foreign procedure may do anything with what it can reach.
call_carrier_moves :: proc(
	c: ^Compiler, call: ^Expr_Call, body: Symbol_Id, count: int, consulted: ^[dynamic]Symbol_Id, allocator: mem.Allocator,
) -> []Carrier_Move {
	if !c.global_writes_ready || !call_writes_caller(c, call) {
		return nil
	}
	targets, _ := call_summary_targets(c, call, body, forward = false)
	out := make([]Carrier_Move, count, allocator)
	for index := 0; index < len(targets); index += 1 {
		target := targets[index]
		if original, shifted := c.receiver_contract_of[target]; shifted {
			target = original
		}
		if is_contract_join(c, target) {
			append(&targets, ..symbol_of(c, target).members)
			continue
		}
		sym := symbol_of(c, target)
		if sym == nil {
			continue
		}
		append(consulted, target)
		if sym.is_foreign {
			for &move in out { move.any = true }
			continue
		}
		shift := count - len(sym.param_symbols)
		for row, position in c.carrier_moves[target] {
			if at := position + shift; at >= 0 && at < count {
				out[at].any ||= row.any
				out[at].copied ||= row.copied
				for type in row.types {
					set_add(&out[at].types, type, allocator)
				}
			}
		}
	}
	return out
}

// Whether a carrier of `source` may have been stored where one of `destination`
// is: it is the same carrier, perhaps weakened, or `destination` erases what it
// holds. An unshaped slot stands for every carrier below it.
@(private)
carrier_may_land_in :: proc(c: ^Compiler, destination, source: Type_Id) -> bool {
	if destination == source || destination == INVALID_TYPE || source == INVALID_TYPE {
		return true
	}
	into, from := underlying_info(c, destination), underlying_info(c, source)
	if into == nil || from == nil {
		return true
	}
	#partial switch into.kind {
	case .Pointer, .Slice, .String_View, .CString_View:
		return into.kind == from.kind && into.element == from.element
	}
	return true
}

// The carrier type a slot holds, or INVALID_TYPE for one standing for every
// carrier below its path.
@(private)
slot_carrier_type :: proc(graph: ^Flow_Graph, index: int) -> Type_Id {
	slot := graph.prov_slots[index]
	if slot.content_truncated || slot.content_type != INVALID_TYPE {
		return slot.content_type
	}
	if bare, exists := graph.slot_by_symbol[slot.symbol]; exists && bare == index {
		return symbol_of(graph.k.c, slot.symbol).type
	}
	return INVALID_TYPE
}

// design.md "Values that contain borrows": a call moves carriers among the
// storage its argument's mutable carriers lead to, so each there of a type the
// call moves may now hold what any there of a type it may have come from held.
@(private = "file")
rearrange_carriers :: proc(state: ^Prov_Solve, event: Prov_Event, reach: []u8) {
	clear(&state.rearranged)
	load_writable_content(state, event, reach, &state.rearranged)
	reads := state.rearranged
	join :: proc(state: ^Prov_Solve, reach: []u8, reads: []int, type: Type_Id, every: bool) {
		graph := state.graph
		mem.zero_slice(state.merged)
		loss: Precision_Loss
		for index in reads {
			if every || carrier_may_land_in(graph.k.c, type, slot_carrier_type(graph, index)) {
				bytes_or(state.merged, reach_row(state, reach, index))
				loss |= state.precision[index]
			}
		}
		for index in reads {
			if every || slot_carrier_type(graph, index) == type || slot_carrier_type(graph, index) == INVALID_TYPE {
				bytes_or(reach_row(state, reach, index), state.merged)
				state.precision[index] |= loss
			}
		}
	}
	if event.rearranged.any {
		join(state, reach, reads[:], INVALID_TYPE, true)
		return
	}
	for type in event.rearranged.types {
		join(state, reach, reads[:], type, false)
	}
}

// The bodies whose summaries this one read. A callback's summary is read only
// once a callee is seen to call it, so the set may grow on a later round.
@(private = "file")
record_summary_dependencies :: proc(c: ^Compiler, declaration: Symbol_Id, callees: []Symbol_Id) {
	known := c.result_summary_dependencies[declaration]
	added := 0
	for callee in callees {
		if !slice.contains(known, callee) {
			added += 1
		}
	}
	if added == 0 {
		return
	}
	grown := make([dynamic]Symbol_Id, 0, len(known) + added, c.semantic_allocator)
	append(&grown, ..known)
	for callee in callees {
		if !slice.contains(grown[:], callee) {
			append(&grown, callee)
		}
	}
	c.result_summary_dependencies[declaration] = grown[:]
}

@(private = "file")
graph_borrows_thread_local :: proc(graph: ^Flow_Graph) -> bool {
	for root in graph.roots {
		if root.kind == .Thread_Local || root.forwarded {
			return true
		}
	}
	return false
}

// design.md "Borrows crossing between tasks": for each parameter, a
// `thread_local` global whose borrow the body may store in the caller storage
// it names, and what a callback it received may leave there, read off each
// store there. A call leaves the same borrow in its argument
// (`prov_call_thread_local_writes`), so a task's call that hands one back to
// its parent is seen at the spawn.
@(private = "file")
collect_thread_local_writes :: proc(state: ^Prov_Solve, declaration: Symbol_Id) -> bool {
	graph := state.graph
	c := state.k.c
	written, found := c.thread_local_writes[declaration]
	if !found {
		written = make([]Symbol_Id, len(symbol_of(c, declaration).param_symbols), c.semantic_allocator)
		for &global in written {
			global = INVALID_SYMBOL
		}
		c.thread_local_writes[declaration] = written
	}
	changed := false
	for block in graph.blocks {
		if !enter_block(state, block) {
			continue
		}
		for event in block.prov {
			if event.kind == .Retain {
				changed = note_thread_local_write(state, event, declaration, written) || changed
			}
			run_prov_event(state, event, state.reach, state.ended)
		}
	}
	return changed
}

// The first `thread_local` global a stored value borrows, and each callback's
// stand-in it holds, recorded for each parameter whose caller storage receives
// it: the stored place's root, or the roots of the carrier it was written
// through.
@(private = "file")
note_thread_local_write :: proc(state: ^Prov_Solve, event: Prov_Event, declaration: Symbol_Id, written: []Symbol_Id) -> bool {
	graph := state.graph
	global, forwarded := stored_thread_facts(state, event.sources)
	if global == INVALID_SYMBOL && len(forwarded) == 0 {
		return false
	}
	destinations := make([dynamic]Prov_Root, 0, 2, context.temp_allocator)
	if len(event.into) > 0 {
		it := slots_loans(state, event.into)
		for _, index in next_live_loan(&it) {
			append(&destinations, graph.roots[int(graph.loans[index].root)])
		}
	} else if event.root != NO_ROOT {
		append(&destinations, graph.roots[int(event.root)])
	}
	changed := false
	for root in destinations {
		if root.kind != .Param || root.param_index >= len(written) {
			continue
		}
		if global != INVALID_SYMBOL && written[root.param_index] == INVALID_SYMBOL {
			written[root.param_index] = global
			changed = true
		}
		for stand_in in forwarded {
			write := Callback_Write{callback = stand_in.param_index, argument = stand_in.argument, into = root.param_index}
			changed = add_unique(state.k.c, &state.k.c.callback_thread_local_writes, declaration, write) || changed
		}
	}
	return changed
}

// What a store's sources hold that a task's write-back cares about: the first
// `thread_local` global they borrow, and each callback's stand-in.
@(private = "file")
stored_thread_facts :: proc(state: ^Prov_Solve, sources: []int) -> (global: Symbol_Id, forwarded: []Prov_Root) {
	graph := state.graph
	global = INVALID_SYMBOL
	out := make([dynamic]Prov_Root, 0, 2, context.temp_allocator)
	it := slots_loans(state, sources)
	for _, index in next_live_loan(&it) {
		root := graph.roots[int(graph.loans[index].root)]
		switch {
		case root.forwarded:
			append(&out, root)
		case root.kind != .Thread_Local || global != INVALID_SYMBOL:
		case root.symbol != INVALID_SYMBOL:
			global = root.symbol
		case:
			global = root.origin
		}
	}
	return global, out[:]
}

param_writes_caller :: proc(c: ^Compiler, param: ^Symbol) -> bool {
	return param != nil && (param.mode == .Inout || carrier_is_mutable(c, param.type) || prov_type_reaches_mutable(c, param.type))
}

@(private = "file")
proc_may_write_owners :: proc(c: ^Compiler, sym: ^Symbol) -> bool {
	for id in sym.param_symbols {
		if param_writes_caller(c, symbol_of(c, id)) {
			return true
		}
	}
	return false
}

// What a body leaves in each argument it may write: the regions, those backing
// owners rather than allocator handles, and the same by path, to which a call
// resolves what stays within one argument.
Written_Summary :: struct {
	regions: []Region_Set,
	owners:  []Region_Set,
	content: [][]Prov_Region_Content,
}

// design.md "Allocator regions and region provenance": the regions of owners a
// body leaves in each argument it may write, read off its flow-insensitive
// region facts. A region local to the body is its own error there.
@(private = "file")
collect_written_regions :: proc(c: ^Compiler, graph: ^Flow_Graph, declaration: Symbol_Id, sym: ^Symbol) -> bool {
	summary, found := c.written_summaries[declaration]
	if !found {
		count := len(sym.param_symbols)
		summary = Written_Summary{
			regions = make([]Region_Set, count, c.semantic_allocator),
			owners  = make([]Region_Set, count, c.semantic_allocator),
			content = make([][]Prov_Region_Content, count, c.semantic_allocator),
		}
		c.written_summaries[declaration] = summary
	}
	changed := false
	for id, index in sym.param_symbols {
		if !param_writes_caller(c, symbol_of(c, id)) {
			continue
		}
		// The whole-argument unions join the path-indexed row; there a copy
		// within the argument stands for the whole argument, and only what is
		// not an allocator handle backs an owner.
		content := prov_written_parameter_content(graph, id, index)
		for entry in content {
			region := entry.region
			if from, copied := entry.from.?; copied {
				// Moving what any element holds to any element leaves the argument
				// nothing it did not hold, so only its row says so.
				if prov_same_path(from.path, entry.path) {
					continue
				}
				region = {}
				region_add_param(&region, index)
			}
			changed = region_merge(&summary.regions[index], region) || changed
			if !entry.handle {
				changed = region_merge(&summary.owners[index], region) || changed
			}
		}
		changed = merge_written_content(c, &summary.content[index], content) || changed
	}
	return changed
}

// Merges a body's path-indexed content into a parameter's summary row. A
// region reaching a new path is growth even when the row's union is unchanged.
// Paths stop at the written-alias depth, as a recursive call can lengthen them
// on every round; a cut entry reaches every path below it.
@(private = "file")
merge_written_content :: proc(c: ^Compiler, row: ^[]Prov_Region_Content, from: []Prov_Region_Content) -> bool {
	changed := false
	next: for entry in from {
		entry := entry
		if len(entry.path) > WRITTEN_ALIAS_DEPTH {
			entry.path, entry.own = entry.path[:WRITTEN_ALIAS_DEPTH], false
		}
		if from, copied := entry.from.?; copied && len(from.path) > WRITTEN_ALIAS_DEPTH {
			entry.from = Prov_Region_Source{from.path[:WRITTEN_ALIAS_DEPTH], .All}
		}
		for &existing in row^ {
			if prov_same_region_content(existing, entry) {
				changed = region_merge(&existing.region, entry.region) || changed
				continue next
			}
		}
		grown := make([]Prov_Region_Content, len(row^) + 1, c.semantic_allocator)
		copy(grown, row^)
		grown[len(row^)] = prov_clone_region_content(entry, entry.region, c.semantic_allocator)
		row^ = grown
		changed = true
	}
	return changed
}

// The path-indexed written content of a call's declaration, or not found for a
// contract join, whose members a call takes together as whole regions.
written_content_summary :: proc(c: ^Compiler, declaration: Symbol_Id) -> ([][]Prov_Region_Content, bool) {
	if original, shifted := c.receiver_contract_of[declaration]; shifted {
		rows, found := written_content_summary(c, original)
		if !found {
			return nil, false
		}
		out := make([][]Prov_Region_Content, len(rows) + 1, context.temp_allocator)
		for row, index in rows {
			shifted_row := make([]Prov_Region_Content, len(row), context.temp_allocator)
			for entry, position in row {
				shifted_row[position] = entry
				shifted_row[position].region = receiver_region(entry.region)
			}
			out[index + 1] = shifted_row
		}
		return out, true
	}
	if is_contract_join(c, declaration) {
		return nil, false
	}
	summary, found := c.written_summaries[declaration]
	return summary.content, found
}

// The written regions of a call's declaration; a join's members are unioned.
// `owners` asks only for the regions backing owners left there, without an
// allocator handle's.
written_region_summary :: proc(c: ^Compiler, declaration: Symbol_Id, owners := false) -> ([]Region_Set, bool) {
	// A view's own row is empty: a plain receiver is not written.
	if original, shifted := c.receiver_contract_of[declaration]; shifted {
		written, found := written_region_summary(c, original, owners)
		if !found {
			return nil, false
		}
		out := make([]Region_Set, len(written) + 1, context.temp_allocator)
		for set, index in written {
			out[index + 1] = receiver_region(set)
		}
		return out, true
	}
	if !is_contract_join(c, declaration) {
		summary, found := c.written_summaries[declaration]
		return owners ? summary.owners : summary.regions, found
	}
	out: []Region_Set
	for member in symbol_of(c, declaration).members {
		summary, found := c.written_summaries[member]
		if !found {
			continue
		}
		written := owners ? summary.owners : summary.regions
		if out == nil {
			out = make([]Region_Set, len(written), context.temp_allocator)
		}
		for set, index in written {
			if index < len(out) {
				region_merge(&out[index], set)
			}
		}
	}
	return out, out != nil
}

// Every loan that can reach a `return` becomes a possibility in the summary.
@(private = "file")
collect_escape_provenance :: proc(state: ^Prov_Solve, declaration: Symbol_Id, summary: ^Result_Provenance) -> bool {
	changed := false
	for block in state.graph.blocks {
		if !enter_block(state, block) {
			continue
		}
		for event in block.prov {
			if event.kind == .Escape {
				changed = merge_escape_event(state, event, declaration, summary) || changed
			}
			run_prov_event(state, event, state.reach, state.ended)
		}
	}
	return changed
}

@(private = "file")
merge_escape_event :: proc(state: ^Prov_Solve, event: Prov_Event, declaration: Symbol_Id, into: ^Result_Provenance) -> bool {
	graph := state.graph
	changed := region_merge(&into.region, event.region)
	for escaped in event.region_content {
		for &content in into.region_content {
			if prov_same_path(content.path, escaped.path) {
				changed = region_merge(&content.region, escaped.region) || changed
			}
		}
	}
	for source in event.sources {
		slot := graph.prov_slots[source]
		changed = merge_precision(&into.precision, state.precision[source]) || changed
		row := reach_row(state, state.reach, source)
		for &content in into.content {
			if slot.content_shape == into.content_type && !paths_overlap(slot.path, content.path.steps) {
				continue
			}
			changed = merge_precision(&content.dependencies.precision, state.precision[source]) || changed
			for index in 0 ..< state.loans {
				if bit_get(row, index) && !graph.roots[int(graph.loans[index].root)].forwarded {
					changed = merge_loan_provenance(state, &content.dependencies, index) || changed
				}
			}
		}
		for index in 0 ..< state.loans {
			if !bit_get(row, index) {
				continue
			}
			// What a callback leaves is the caller's to name.
			if stand_in := graph.roots[int(graph.loans[index].root)]; stand_in.forwarded {
				read := Callback_Read{callback = stand_in.param_index, argument = stand_in.argument}
				changed = add_unique(state.k.c, &state.k.c.callback_result_reads, declaration, read) || changed
				continue
			}
			changed = merge_loan_provenance(state, &into.dependencies, index) || changed
		}
	}
	return changed
}

@(private = "file")
merge_loan_provenance :: proc(state: ^Prov_Solve, into: ^Result_Dependencies, index: int) -> bool {
	loan := state.graph.loans[index]
	root := state.graph.roots[int(loan.root)]
	one := Result_Dependencies{}
	switch root.kind {
	case .Param:
		if loan.depth > 0 && root.param_index < len(into.param_loads) {
			bit := u8(1) << u8(loan.depth - 1)
			changed := into.param_loads[root.param_index] & bit == 0
			changed = merge_param_load_paths(state, into, root, loan) || changed
			into.param_loads[root.param_index] |= bit
			return changed
		}
		if root.param_index >= 0 && root.param_index < len(into.params) {
			changed := merge_param_paths(state, into, root, loan)
			if !into.params[root.param_index] {
				into.params[root.param_index] = true
				changed = true
			}
			return changed
		}
		one.unknown = true
	case .Static, .Thread_Local:
		if root.symbol != INVALID_SYMBOL {
			one.globals = []Symbol_Id{root.symbol}
		} else if root.kind == .Static {
			one.static = true
		} else {
			one.thread = true
		}
	case .Materialized:
		one.static = true
	case .Local, .Slice_Literal, .Temporary, .Provider:
		one.local = true
	case .Unknown:
		one.unknown = true
	}
	return merge_provenance(into, one, state.k.c.semantic_allocator)
}

// Narrows a parameter dependency to the shape paths the loan overlaps, so a
// caller substitutes only those fields. Nil means the whole parameter.
@(private)
merge_param_paths :: proc(
	state: ^Prov_Solve,
	into: ^Result_Dependencies,
	root: Prov_Root,
	loan: Prov_Loan,
) -> bool {
	index := root.param_index
	if index >= len(into.param_paths) {
		return false
	}
	sym := symbol_of(state.k.c, root.symbol)
	shape: []Carrier_Path
	if sym != nil && !type_is_carrier(state.k.c, sym.type) {
		shape = carrier_shape(state.k.c, sym.type)
	}
	if len(shape) == 0 {
		changed := len(into.param_paths[index]) > 0
		into.param_paths[index] = nil
		return changed
	}
	if into.param_paths[index] == nil && into.params[index] {
		return false // already widened to the whole parameter
	}
	if into.param_paths[index] == nil {
		into.param_paths[index] = make([]bool, len(shape), state.k.c.semantic_allocator)
	}
	loan_path := slice.clone(loan.path, state.graph.alloc)
	widen_summary_map_path(state.k.c, sym.type, loan_path)
	changed := merge_precision(&into.precision, path_precision(loan_path))
	matched := false
	for path, position in shape {
		if !paths_overlap(path.steps, loan_path) {
			continue
		}
		matched = true
		if !into.param_paths[index][position] {
			into.param_paths[index][position] = true
			changed = true
		}
	}
	if !matched {
		// The parameter's own storage (`&self.count`), which no carrier path
		// describes: depend on all of it.
		into.param_paths[index] = nil
		return true
	}
	return changed
}

// Narrows a load dependency to the pointee path the loan's first load goes
// along, so a caller loads only through those fields. Nil means every path.
// Runs before the load's bit is set, which is how a first narrowing tells
// itself apart from a dependency already widened to the whole pointee.
@(private = "file")
merge_param_load_paths :: proc(
	state: ^Prov_Solve,
	into: ^Result_Dependencies,
	root: Prov_Root,
	loan: Prov_Loan,
) -> bool {
	index := root.param_index
	if index >= len(into.param_load_paths) {
		return false
	}
	c := state.k.c
	first := into.param_loads[index] & (u8(1) << u8(loan.depth - 1)) == 0
	sym := symbol_of(c, root.symbol)
	shape := sym == nil ? nil : carrier_pointee_shape(c, sym.type)
	paths := result_load_paths(into^, index, loan.depth)
	if loan.pointee == 0 || loan.pointee > len(shape) {
		if paths == nil {
			return false
		}
		load_paths_at(into, index, loan.depth, c.semantic_allocator)^ = nil
		return true
	}
	if paths == nil {
		if !first {
			return false // already widened to the whole pointee
		}
		paths = make([]bool, len(shape), c.semantic_allocator)
		load_paths_at(into, index, loan.depth, c.semantic_allocator)^ = paths
	}
	if paths[loan.pointee - 1] {
		return false
	}
	paths[loan.pointee - 1] = true
	return true
}

// One concrete body's root and region diagnostics.
analyze_provenance :: proc(k: ^Checker, literal: ^Expr_Proc) {
	defer free_all(k.c.analysis_allocator)
	first := len(k.c.diagnostics)
	defer note_instance_sites(k, literal, first)
	graph := build_flow_graph(k, literal, .Prov_Diagnose)
	if graph == nil {
		return
	}
	solve_provenance(k, graph)
}

// An error in a generic instance's body names the call that selected it, as
// the checker's do, which run before this pass: the body may be a library's,
// and the call the caller's.
@(private)
note_instance_sites :: proc(k: ^Checker, literal: ^Expr_Proc, first: int) {
	instance := k.c.procedure_instances[literal.symbol]
	if instance == nil || instance.selected_at.file == NO_FILE {
		return
	}
	append(&k.c.instantiation_stack, Instantiation_Frame {
		description = identifier_text(k.c, symbol_of(k.c, literal.symbol).name),
		span        = instance.selected_at,
	})
	defer pop(&k.c.instantiation_stack)
	note_instantiation_stack(k, first)
}

// design.md "Globals while tasks run": the globals whose
// stored carriers the body itself reaches, from each `Reach` event and from
// what it returns or stores where another body may reach through it. A
// global's stored carrier is a loan of its existing content, a loan of the
// global's own storage when that holds carriers, or the global's own slot,
// which another call may have refilled. A `@(synchronized)` variable's package
// vouches for every access through it.
body_global_reach :: proc(k: ^Checker, graph: ^Flow_Graph, out: ^[dynamic]Global_Effect) {
	state := Prov_Solve{graph = graph, k = k}
	if !prepare_state(&state) {
		return
	}
	solve_reaching(&state)
	for block in graph.blocks {
		if !enter_block(&state, block) {
			continue
		}
		for event in block.prov {
			#partial switch event.kind {
			case .Reach, .Escape, .Retain, .Publish:
				for slot in event.sources {
					note_reached_globals(&state, slot, event.span, out)
				}
			}
			run_prov_event(&state, event, state.reach, state.ended)
		}
	}
}

@(private)
note_reached_globals :: proc(state: ^Prov_Solve, slot: int, span: Span, out: ^[dynamic]Global_Effect) {
	graph := state.graph
	c := state.k.c
	source := Effect_Source{span = span, precision = state.precision[slot]}
	add_reached_global(c, out, graph.prov_slots[slot].symbol, source)
	row := reach_row(state, state.reach, slot)
	for index in 0 ..< state.loans {
		if !bit_get(row, index) {
			continue
		}
		root := graph.roots[int(graph.loans[index].root)]
		if root.origin != INVALID_SYMBOL {
			add_reached_global(c, out, root.origin, source)
		} else if root.kind == .Static || root.kind == .Thread_Local {
			add_reached_global(c, out, root.symbol, source)
		}
	}
}

@(private = "file")
add_reached_global :: proc(c: ^Compiler, out: ^[dynamic]Global_Effect, global: Symbol_Id, source: Effect_Source) {
	sym := symbol_of(c, global)
	if sym == nil || sym.kind != .Var || !symbol_outlives_bodies(sym) || sym.synchronized ||
	   !type_carries_borrow(c, sym.type).any {
		return
	}
	for existing in out {
		if existing.global == global {
			return
		}
	}
	append(out, Global_Effect{global = global, source = source})
}

@(private = "file")
solve_provenance :: proc(k: ^Checker, graph: ^Flow_Graph) {
	state := Prov_Solve{graph = graph, k = k}
	if !prepare_state(&state) {
		return
	}
	solve_reaching(&state)
	// Links depend on reach, and what each slot holds of them on the links.
	link_landed_stores(&state)
	resolve_content_reads(&state)
	prov_settle_pending_reborrows(graph)
	solve_links_held(&state)
	solve_loan_liveness(&state)
	report_provenance(&state)
}

// Sizes the per-block lattice storage; false when there is nothing to solve.
@(private = "file")
prepare_state :: proc(state: ^Prov_Solve) -> bool {
	graph := state.graph
	state.slots = len(graph.prov_slots)
	state.loans = len(graph.loans)
	if state.loans == 0 && !graph.has_region_event && !graph.has_window_event {
		return false
	}
	// A row holds each loan's bit, whether it was invalidated, and then a bit
	// per place loan (`place_bit`).
	state.row_bytes = (2 * state.loans + len(graph.place_loans) + 7) / 8
	width := max(state.slots * state.row_bytes, 1)
	for block in graph.blocks {
		block.reach_entry = make([]u8, width, graph.alloc)
		block.precision_entry = make([]Precision_Loss, state.slots, graph.alloc)
		block.precision_exit = make([]Precision_Loss, state.slots, graph.alloc)
		block.reach_exit = make([]u8, width, graph.alloc)
		block.ended_entry = make([]bool, state.loans, graph.alloc)
		block.ended_exit = make([]bool, state.loans, graph.alloc)
		block.live_entry = make([]Slot_Use, state.slots, graph.alloc)
		block.live_exit = make([]Slot_Use, state.slots, graph.alloc)
		block.use_entry = make([]Span, state.slots, graph.alloc)
		block.use_exit = make([]Span, state.slots, graph.alloc)
		block.prov_visited = false
	}
	state.reach = make([]u8, width, graph.alloc)
	state.precision = make([]Precision_Loss, state.slots, graph.alloc)
	state.released = make([]bool, state.loans, graph.alloc)
	state.released_indices = make([dynamic]int, graph.alloc)
	state.live_slots = make([dynamic]int, graph.alloc)
	state.load_expanded = make([]bool, state.loans, graph.alloc)
	state.load_pending = make([]u8, state.row_bytes, graph.alloc)
	state.ended = make([]bool, state.loans, graph.alloc)
	state.rearranged = make([dynamic]int, graph.alloc)
	state.live = make([]Slot_Use, state.slots, graph.alloc)
	state.uses = make([]Span, state.slots, graph.alloc)
	state.merged = make([]u8, state.row_bytes, graph.alloc)
	settle_pool_joins(state)
	solve_view_defs(graph)
	return true
}

// Links each store's copies to the slots it lands in, at the settled reach.
@(private)
link_landed_stores :: proc(state: ^Prov_Solve) {
	graph := state.graph
	if !graph.has_linked_store {
		return
	}
	stores := 0
	for block in graph.blocks {
		if !enter_block(state, block) {
			continue
		}
		for &event in block.prov {
			retained, is_retained := event.store.(Prov_Store_Retained)
			copies := event.kind == .Rearrange && event.rearranged.copied
			if !copies && (event.kind != .Publish || !event.links_copies && !is_retained) {
				run_prov_event(state, event, state.reach, state.ended)
				continue
			}
			landed := make([dynamic]int, 0, 4, graph.alloc)
			state.landed = &landed
			run_prov_event(state, event, state.reach, state.ended)
			state.landed = nil
			stores += 1
			event.store_id = stores
			taken := len(graph.reborrows)
			if copies {
				prov_link_copied_carriers(graph, event, state.rearranged[:])
			} else if is_retained {
				prov_link_retained(graph, event, retained, landed[:])
			} else {
				prov_link_landed(graph, event, landed[:])
			}
			for &reborrow in graph.reborrows[taken:] {
				reborrow.from_store = stores
			}
		}
	}
}

// Forward: which loans each carrier slot may hold, and which loans an earlier
// invalidation already ended.
@(private = "file")
solve_reaching :: proc(state: ^Prov_Solve) {
	graph := state.graph
	queue := make([dynamic]Block_Id, 0, len(graph.blocks), graph.alloc)
	queued := make([]bool, len(graph.blocks), graph.alloc)
	append(&queue, Block_Id(0))
	queued[0] = true
	for head := 0; head < len(queue); head += 1 {
		id := int(queue[head])
		block := graph.blocks[id]
		queued[id] = false
		mem.zero_slice(state.reach)
		mem.zero_slice(state.precision)
		mem.zero_slice(state.ended)
		if id != 0 {
			seen := false
			for predecessor in block.preds {
				source := graph.blocks[predecessor]
				if !source.prov_visited {
					continue
				}
				bytes_or(state.reach, source.reach_exit)
				for loss, slot in source.precision_exit { state.precision[slot] |= loss }
				// A predecessor not visited yet stays out of the meet.
				if seen {
					for value, index in source.ended_exit {
						state.ended[index] &&= value
					}
				} else {
					copy(state.ended, source.ended_exit)
				}
				seen = true
			}
		} else {
			// A borrowed parameter arrives already holding the caller's root.
			for entry in graph.entry_defs {
				bit_mark(reach_row(state, state.reach, entry.slot), int(entry.loan))
				state.precision[entry.slot] |= graph.prov_slots[entry.slot].precision
			}
		}
		copy(block.reach_entry, state.reach)
		copy(block.precision_entry, state.precision)
		copy(block.ended_entry, state.ended)
		for event in block.prov {
			run_prov_event(state, event, state.reach, state.ended)
		}
		if block.prov_visited &&
		   slice.equal(block.precision_exit, state.precision) &&
		   slice.equal(block.reach_exit, state.reach) &&
		   slice.equal(block.ended_exit, state.ended) {
			continue
		}
		copy(block.reach_exit, state.reach)
		copy(block.precision_exit, state.precision)
		copy(block.ended_exit, state.ended)
		block.prov_visited = true
		for successor in block.succs {
			if !queued[int(successor)] {
				append(&queue, successor)
				queued[int(successor)] = true
			}
		}
	}
}

// design.md "Weakening and reborrows": forward, once every reborrow has settled, which of
// them each slot's value may have come through. A copy takes what its source held and the
// link it was copied by, and a new value in a slot ends what was taken from the old, so
// which definition reaches is in the row: a reborrow of a value no slot holds any more
// suspends nothing, on the paths where that is so.
@(private)
solve_links_held :: proc(state: ^Prov_Solve) {
	graph := state.graph
	links := len(graph.reborrows)
	if links == 0 {
		return
	}
	state.link_row_bytes = (links + 7) / 8
	state.links_held = make([]u32, state.slots, graph.alloc)
	state.link_row_value = make([]u8, state.link_row_bytes, graph.alloc)
	state.link_row_edit = make([]u8, state.link_row_bytes, graph.alloc)
	state.link_row_mask = make([]u8, state.link_row_bytes, graph.alloc)
	state.link_rows = make([dynamic][]u8, 0, 16, graph.alloc)
	state.link_row_ids = make(map[string]u32, graph.alloc)
	intern_link_row(state, state.link_row_value)
	index_links(state)
	visited := make([]bool, len(graph.blocks), graph.alloc)
	queued := make([]bool, len(graph.blocks), graph.alloc)
	queue := make([dynamic]Block_Id, 0, len(graph.blocks), graph.alloc)
	append(&queue, Block_Id(0))
	queued[0] = true
	for head := 0; head < len(queue); head += 1 {
		id := int(queue[head])
		block := graph.blocks[id]
		queued[id] = false
		mem.zero_slice(state.links_held)
		for predecessor in block.preds {
			if visited[int(predecessor)] {
				join_links_held(state, graph.blocks[predecessor].links_exit)
			}
		}
		if block.links_entry == nil {
			block.links_entry = make([]u32, state.slots, graph.alloc)
			block.links_exit = make([]u32, state.slots, graph.alloc)
		}
		copy(block.links_entry, state.links_held)
		for event in block.prov {
			run_links_held_event(state, event, state.links_held)
		}
		if visited[id] && slice.equal(block.links_exit, state.links_held) {
			continue
		}
		visited[id] = true
		copy(block.links_exit, state.links_held)
		for successor in block.succs {
			if !queued[int(successor)] {
				append(&queue, successor)
				queued[int(successor)] = true
			}
		}
	}
}

// The reborrows into, through and made by each slot or store, and which of them a
// definition of the derived slot names.
@(private = "file")
index_links :: proc(state: ^Prov_Solve) {
	graph := state.graph
	context.allocator = graph.alloc
	state.links_into = make([][dynamic]int, state.slots)
	state.links_via = make([][dynamic]int, state.slots)
	state.link_is_named = make([]bool, len(graph.reborrows))
	stores := 0
	for link, index in graph.reborrows {
		append(&state.links_into[link.derived], index)
		for carrier in link.via {
			append(&state.links_via[carrier], index)
		}
		stores = max(stores, link.from_store)
	}
	state.links_of_store = make([][dynamic]int, stores + 1)
	for link, index in graph.reborrows {
		if link.from_store > 0 {
			append(&state.links_of_store[link.from_store], index)
		}
	}
	for block in graph.blocks {
		for event in block.prov {
			if event.kind != .Def && event.kind != .Load {
				continue
			}
			for index in state.links_into[event.slot] {
				if slice.contains(event.sources, graph.reborrows[index].source) {
					state.link_is_named[index] = true
				}
			}
		}
	}
}

@(private = "file")
intern_link_row :: proc(state: ^Prov_Solve, row: []u8) -> u32 {
	if id, found := state.link_row_ids[string(row)]; found {
		return id
	}
	kept := slice.clone(row, state.graph.alloc)
	id := u32(len(state.link_rows))
	append(&state.link_rows, kept)
	state.link_row_ids[string(kept)] = id
	return id
}

@(private = "file")
join_links_held :: proc(state: ^Prov_Solve, from: []u32) {
	for row, slot in from {
		held := state.links_held[slot]
		if row == held || row == 0 {
			continue
		}
		if held == 0 {
			state.links_held[slot] = row
			continue
		}
		copy(state.link_row_edit, state.link_rows[held])
		bytes_or(state.link_row_edit, state.link_rows[row])
		state.links_held[slot] = intern_link_row(state, state.link_row_edit)
	}
}

// A new value in `slot` ends what was taken from its old one, unless it came from there,
// as then the old value goes on being held, as `cur = copy_of_cur` does.
@(private = "file")
end_links_of_value :: proc(state: ^Prov_Solve, held: []u32, slot: int, value: []u8) {
	links := reborrows_of(state, slot)
	for index in links {
		if bit_get(value, index) {
			return
		}
	}
	if len(links) == 0 {
		return
	}
	mask := state.link_row_mask
	for index in links {
		bit_mark(mask, index)
	}
	for &row in held {
		if row == 0 {
			continue
		}
		edit := state.link_row_edit
		changed := false
		for byte, at in state.link_rows[row] {
			edit[at] = byte &~ mask[at]
			changed ||= edit[at] != byte
		}
		if changed {
			row = intern_link_row(state, edit)
		}
	}
	for index in links {
		bit_clear(mask, index)
	}
}

@(private = "file")
run_links_held_event :: proc(state: ^Prov_Solve, event: Prov_Event, held: []u32) {
	graph := state.graph
	if state.link_row_bytes == 0 {
		return
	}
	#partial switch event.kind {
	case .Def, .Load:
		slot := event.slot
		value := state.link_row_value
		mem.zero_slice(value)
		// A definition joining the slot's own value does not end it.
		joins := event.kind == .Def && slice.contains(event.sources, slot)
		if joins {
			bytes_or(value, state.link_rows[held[slot]])
		}
		for index in state.links_into[slot] {
			link := graph.reborrows[index]
			if link.from_store > 0 || state.link_is_named[index] && !slice.contains(event.sources, link.source) {
				continue
			}
			bytes_or(value, state.link_rows[held[link.source]])
			bit_mark(value, index)
		}
		// What was loaded through this carrier and is stored back, as `cur = cur^.next`,
		// is the carrier's own value, not a competing use of what it was loaded out of.
		for index in state.links_via[slot] {
			bit_clear(value, index)
		}
		if !joins {
			end_links_of_value(state, held, slot, value)
		}
		held[slot] = intern_link_row(state, value)
	case .Publish, .Rearrange:
		// A store or a call starts what it links, and a store ends what was taken from a
		// slot it replaces, which holds another carrier now.
		stored := state.link_row_value
		mem.zero_slice(stored)
		for source in event.sources {
			bytes_or(stored, state.link_rows[held[source]])
		}
		for slot in event.replaces {
			held[slot] = 0
		}
		if event.store_id > 0 && event.store_id < len(state.links_of_store) {
			// A call's links run both ways through a hub, so this goes until they settle.
			for changed := true; changed; {
				changed = false
				for index in state.links_of_store[event.store_id] {
					link := graph.reborrows[index]
					copy(state.link_row_edit, state.link_rows[held[link.derived]])
					bit_mark(state.link_row_edit, index)
					bytes_or(state.link_row_edit, state.link_rows[held[link.source]])
					row := intern_link_row(state, state.link_row_edit)
					if row != held[link.derived] {
						held[link.derived] = row
						changed = true
					}
				}
			}
		}
		for slot in event.replaces {
			end_links_of_value(state, held, slot, stored)
		}
	}
}

@(private = "file")
run_prov_event :: proc(state: ^Prov_Solve, event: Prov_Event, reach: []u8, ended: []bool) {
	graph := state.graph
	mark_released(state, event, reach)
	end_loans(state, event, reach, ended)
	#partial switch event.kind {
	case .Def:
		mem.zero_slice(state.merged)
		loss := graph.prov_slots[event.slot].precision | path_precision(event.path) | event.precision
		for source in event.sources {
			loss |= state.precision[source]
			bytes_or(state.merged, reach_row(state, reach, source))
		}
		if event.loan != NO_LOAN {
			// A creation site that runs again starts a new, valid instance.
			loss |= path_precision(graph.loans[int(event.loan)].path)
			bit_mark(state.merged, int(event.loan))
			bit_clear(state.merged, state.loans + int(event.loan))
		}
		if event.place_loan > 0 {
			bit_mark(state.merged, place_bit(state, event.place_loan - 1))
		}
		copy(reach_row(state, reach, event.slot), state.merged)
		state.precision[event.slot] = loss
	case .Load:
		load_pointee_content(state, event, reach)
	case .Rearrange:
		rearrange_carriers(state, event, reach)
	case .Rebind:
		for loan, index in graph.loans {
			if loan.root != event.root {
				continue
			}
			for slot in 0 ..< state.slots {
				row := reach_row(state, reach, slot)
				bit_clear(row, index)
				bit_clear(row, state.loans + index)
			}
		}
	case .Publish:
		// Joins into every root the carrier may name.
		settled := publish_place_settled(state, event, reach)
		mem.zero_slice(state.merged)
		state.merged_precision = path_precision(settled.path)
		for source in event.sources {
			state.merged_precision |= state.precision[source]
			bytes_or(state.merged, reach_row(state, reach, source))
		}
		if event.strips {
			for slot in event.into {
				row := reach_row(state, reach, slot)
				for &byte, index in state.merged {
					byte &= ~row[index]
				}
			}
		}
		one := publish_one_loan(state, settled, reach, ended)
		for slot in event.into {
			row := reach_row(state, reach, slot)
			for index in 0 ..< state.loans {
				if !bit_get(row, index) || ended[index] {
					continue
				}
				publish_into_loan(state, reach, index, settled, index == one, state.precision[slot])
			}
		}
	}
}

// design.md "Places and overlap": the one element of a view parameter that `carriers` all
// point into here, as `p` after `p := &mut s[0]`, so what goes through them is in that element
// as what goes through `s[0]` is. Each must hold a borrow of it and no borrow of anything
// else, which the place loan bits show wherever that borrow was made, past a loop's back edge
// too. A definition that makes no such borrow the walk has ruled out, if it had met one
// (`prov_may_point_at_element`), and one it had not uses all of `s`, and so conflicts with
// what is left in it. Given `loan_held`, only the carriers holding that loan count.
@(private)
carriers_element :: proc(state: ^Prov_Solve, carriers: []int, reach: []u8, loan_held := -1) -> Prov_Element_Slots {
	found: Prov_Element_Slots
	for slot in carriers {
		row := reach_row(state, reach, slot)
		if loan_held >= 0 && !bit_get(row, loan_held) {
			continue
		}
		held := false
		for loan, index in state.graph.place_loans {
			if !loan.borrows || !bit_get(row, place_bit(state, index)) {
				continue
			}
			if len(loan.in_element.slots) == 0 || len(found.slots) > 0 && raw_data(found.slots) != raw_data(loan.in_element.slots) {
				return {}
			}
			found = loan.in_element
			held = true
		}
		if !held {
			return {}
		}
	}
	return found
}

// A store whose carriers the walk took to point at one place (`Prov_Event.place_path`),
// or that place's store with nothing known of where it lands when a borrow they may hold
// here names another: `p` in a loop that ends in `p = &mut r^.b` names `r^.b` from the
// second iteration on, as the walk had not reached when it met a store through `p`.
@(private)
publish_place_settled :: proc(state: ^Prov_Solve, event: Prov_Event, reach: []u8) -> Prov_Event {
	settled := event
	if event.through_element && event.store == nil {
		if element := carriers_element(state, event.into, reach); len(element.slots) > 0 {
			settled.store = element
		}
	}
	if len(event.place_path) == 0 {
		return settled
	}
	for slot in event.into {
		row := reach_row(state, reach, slot)
		for loan, index in state.graph.place_loans {
			if !loan.borrows || !bit_get(row, place_bit(state, index)) {
				continue
			}
			for path in loan.paths {
				for step, at in path[:min(len(path), len(event.place_path))] {
					if step != event.place_path[at] {
						settled.path, settled.one_place, settled.place_path = nil, false, nil
						return settled
					}
				}
			}
		}
	}
	return settled
}

// The one loan a store's carriers name (`Prov_Event.one_place`, as settled by
// `publish_place_settled`), or -1 when it may land in more than one storage
// (design.md "Values that contain borrows"). A pointer holding no loan on some path
// is unchecked, whose use is the program's responsibility (design.md "What is not
// checked").
@(private = "file")
publish_one_loan :: proc(state: ^Prov_Solve, settled: Prov_Event, reach: []u8, ended: []bool) -> int {
	if !settled.one_place {
		return -1
	}
	one := -1
	for slot in settled.into {
		row := reach_row(state, reach, slot)
		for index in 0 ..< state.loans {
			if !bit_get(row, index) || ended[index] || index == one {
				continue
			}
			if one >= 0 {
				return -1
			}
			one = index
		}
	}
	return one
}

// Marks the loans an event ends as released in every slot that may hold them,
// and clears the mark where a loop head re-establishes them.
@(private = "file")
mark_released :: proc(state: ^Prov_Solve, event: Prov_Event, reach: []u8) {
	revived := event.kind == .Live && event.revives
	#partial switch event.kind {
	case .Live:
		if !revived {
			return
		}
		mem.zero_slice(state.released)
		for source in event.sources {
			row := reach_row(state, reach, source)
			for index in 0 ..< state.loans {
				state.released[index] ||= bit_get(row, index)
			}
		}
	case .Access, .Root_End, .Reset:
		mem.zero_slice(state.released)
		end_loans(state, event, reach, state.released)
	case:
		return
	}
	// Rows change only at released loans, and most events release none; this beat
	// looping loans outside slots on bench/dense.loke.
	clear(&state.released_indices)
	for released, index in state.released {
		if released {
			append(&state.released_indices, index)
		}
	}
	if len(state.released_indices) == 0 {
		return
	}
	for slot in 0 ..< state.slots {
		row := reach_row(state, reach, slot)
		for index in state.released_indices {
			if revived {
				bit_clear(row, state.loans + index)
			} else if bit_get(row, index) {
				bit_mark(row, state.loans + index)
			}
		}
	}
}

// Which loans an event ends or starts afresh, over the loans ended on every
// path, and once per event over the loans it releases.
@(private = "file")
end_loans :: proc(state: ^Prov_Solve, event: Prov_Event, reach: []u8, ended: []bool) {
	graph := state.graph
	#partial switch event.kind {
	case .Def:
		// A creation site that runs again starts a new, valid instance.
		if event.loan != NO_LOAN {
			ended[int(event.loan)] = false
		}
	case .Live:
		// A loop head re-establishes the loans, so an end inside the body does not
		// reach its entry through the back edge.
		if !event.revives {
			break
		}
		for source in event.sources {
			row := reach_row(state, reach, source)
			for index in 0 ..< state.loans {
				if bit_get(row, index) {
					ended[index] = false
				}
			}
		}
	case .Access:
		if event.access != .Invalidate {
			break
		}
		for loan, index in graph.loans {
			if loan.root == event.root && paths_overlap(loan.path, event.path) {
				ended[index] = true
			}
		}
	case .Root_End:
		for loan, index in graph.loans {
			if loan.root == event.root {
				ended[index] = true
			}
		}
	case .Reset:
		for loan, index in graph.loans {
			if reset_ends_root(graph.roots[int(loan.root)], event) {
				ended[index] = true
			}
		}
	}
}

// A load reads the slots at the pointee path through the addressing loans and
// copies their dependencies. Storage with no local content keeps the loan. A
// deep load goes on through what it read until nothing new turns up.
@(private = "file")
load_pointee_content :: proc(state: ^Prov_Solve, event: Prov_Event, reach: []u8, reads: ^[dynamic]int = nil) {
	graph := state.graph
	if event.load == .Writable {
		load_writable_content(state, event, reach, reads)
		return
	}
	mem.zero_slice(state.merged)
	loss := graph.prov_slots[event.slot].precision | path_precision(event.path)
	named := event.load_element
	if event.through_element {
		named = carriers_element(state, event.into, reach)
	}
	for carrier in event.into {
		row := reach_row(state, reach, carrier)
		for index in 0 ..< state.loans {
			if !bit_get(row, index) {
				continue
			}
			elements := named.slots if Loan_Id(index) == named.loan else nil
			// Out of a local view, the one element the load names, where it is
			// known among those the loan lends (`view_element_loan`).
			lent: []Proj_Step
			if narrowed, known := view_element_loan(graph, event.element, index); known {
				lent = narrowed.path
			}
			if !load_through_loan(state, index, event.path, reach, &loss, reads, elements, lent) {
				loss |= state.precision[carrier]
			}
		}
	}
	if event.load == .Deep || event.load == .At_Once {
		expanded := state.load_expanded
		mem.zero_slice(expanded)
		for grew := true; grew; {
			grew = false
			for index in 0 ..< state.loans {
				if !expanded[index] && bit_get(state.merged, index) {
					expanded[index] = true
					grew = true
					load_through_loan(state, index, nil, reach, &loss, reads)
				}
			}
		}
	}
	carry_place_bits(state, event, reach)
	copy(reach_row(state, reach, event.slot), state.merged)
	state.precision[event.slot] = loss
}

// What is loaded through a carrier holding a place loan's bit is read out
// through that loan, so it carries the bit on (`place_loan_use`), and an
// access through it is the loan's own: `&mut left^` for a `&mut left`
// binding, or what a call given it reaches.
@(private = "file")
carry_place_bits :: proc(state: ^Prov_Solve, event: Prov_Event, reach: []u8) {
	for carrier in event.into {
		row := reach_row(state, reach, carrier)
		for index in 0 ..< len(state.graph.place_loans) {
			if bit := place_bit(state, index); bit_get(row, bit) {
				bit_mark(state.merged, bit)
			}
		}
	}
}

// A `writable` load: the loans of every mutable carrier reached from
// `event.into`, going on through those and through read-only carriers whose
// pointee reaches a destination (`prov_load_writable`). What `into` names is
// only read through, as `prov_mutable_reach` already kept the mutable ones.
@(private = "file")
load_writable_content :: proc(state: ^Prov_Solve, event: Prov_Event, reach: []u8, reads: ^[dynamic]int) {
	graph := state.graph
	mem.zero_slice(state.merged)
	loss := graph.prov_slots[event.slot].precision
	pending := state.load_pending
	mem.zero_slice(pending)
	for carrier in event.into {
		bytes_or(pending, reach_row(state, reach, carrier))
	}
	expanded := state.load_expanded
	mem.zero_slice(expanded)
	for grew := true; grew; {
		grew = false
		for index in 0 ..< state.loans {
			if bit_get(pending, index) && !expanded[index] {
				expanded[index] = true
				grew = true
				load_writable_through(state, index, reach, &loss, reads, pending)
			}
		}
	}
	carry_place_bits(state, event, reach)
	copy(reach_row(state, reach, event.slot), state.merged)
	state.precision[event.slot] = loss
}

// The carriers in the storage one loan names, as `load_through_loan` finds
// them: a mutable one's loans join `state.merged`, and those of any carrier a
// write may go on through become `pending`. Storage with no local content
// stands for what it holds, unless its type holds nothing a write could reach.
@(private = "file")
load_writable_through :: proc(
	state: ^Prov_Solve,
	loan_index: int,
	reach: []u8,
	loss: ^Precision_Loss,
	reads: ^[dynamic]int,
	pending: []u8,
) {
	graph := state.graph
	c := graph.k.c
	loan := graph.loans[loan_index]
	root := graph.roots[int(loan.root)]
	sym := symbol_of(c, root.symbol)
	found := false
	for index in loan_own_slots(graph, loan, root) {
		slot := graph.prov_slots[index]
		if !paths_overlap(slot.path, loan.path) {
			continue
		}
		found = true
		loss^ |= state.precision[index]
		note_read(reads, index)
		// A truncated or unshaped slot stands for every carrier below it.
		destination, follow := true, true
		type := slot_carrier_type(graph, index)
		if type != INVALID_TYPE && !slot.content_truncated {
			info := underlying_info(c, type)
			pointee := info != nil ? info.element : INVALID_TYPE
			destination = carrier_is_mutable(c, type) && type_carries_borrow(c, pointee).any
			// design.md "Variadic parameters": a pack also carries its operands'
			// loans, so a mutable operand's are destinations as well.
			if info != nil && info.kind == .Slice {
				element := underlying_info(c, pointee)
				destination ||= carrier_is_mutable(c, pointee) && element != nil && type_carries_borrow(c, element.element).any
			}
			follow = destination || prov_type_reaches_destination(c, pointee)
		}
		row := reach_row(state, reach, index)
		if destination {
			bytes_or(state.merged, row)
		}
		if follow {
			bytes_or(pending, row)
		}
	}
	if found || sym != nil && root.kind != .Param && !type_carries_borrow(c, sym.type).any {
		return
	}
	loss^ |= path_precision(loan.path)
	if !read_caller_slots(state, loan_index, nil, reach, loss, reads) {
		bit_mark(state.merged, deeper_content_loan(root, loan, loan_index))
		return
	}
	// A carrier stored there from elsewhere is followed as one in a local's
	// storage is; what the parameter reached already stands for every depth.
	for slot in state.graph.caller_slots[Loan_Id(loan_index)] {
		row := reach_row(state, reach, slot)
		for held in 0 ..< state.loans {
			if bit_get(row, held) && graph.loans[held].root != loan.root {
				bit_mark(pending, held)
			}
		}
	}
}

// The `content` loan standing for what one more load through a parameter's
// loan reads, the last standing for every depth from its own on. A pointee
// loan's keeps the path its first load went along.
@(private)
deeper_content_loan :: proc(root: Prov_Root, loan: Prov_Loan, loan_index: int) -> int {
	count := len(root.content_loans)
	if count == 0 {
		return loan_index
	}
	next := min(loan.depth, count - 1)
	if loan.pointee > 0 {
		return int(root.pointee_loans[loan.pointee - 1][next])
	}
	return int(root.content_loans[next])
}

// Joins into `state.merged` what the storage one loan names holds at `path`;
// false when that storage has no local content, and the loan stands for it. A
// parameter's caller storage is never local: its `content_loans` stand for it,
// and `elements`, when given, for the one element of it the load names.
@(private = "file")
load_through_loan :: proc(
	state: ^Prov_Solve,
	loan_index: int,
	path: []Proj_Step,
	reach: []u8,
	loss: ^Precision_Loss,
	reads: ^[dynamic]int,
	elements: []int = nil,
	lent: []Proj_Step = nil,
) -> bool {
	graph := state.graph
	loan := graph.loans[loan_index]
	root := graph.roots[int(loan.root)]
	found := false
	// Given `lent`, the part of what the loan lends the load names, as one
	// element of a local view (`view_element_loan`), only slots there.
	within := lent if lent != nil else loan.path
	for index in loan_own_slots(graph, loan, root) {
		slot := graph.prov_slots[index]
		if !paths_overlap(slot.path, within) {
			continue
		}
		suffix := slot.path[min(len(within), len(slot.path)):]
		if !paths_overlap(suffix, path) {
			continue
		}
		found = true
		loss^ |= state.precision[index]
		bytes_or(state.merged, reach_row(state, reach, index))
		note_read(reads, index)
	}
	if found {
		return true
	}
	loss^ |= path_precision(loan.path)
	if !read_caller_slots(state, loan_index, path, reach, loss, reads, elements) &&
	   !(root.kind == .Param && !loan.content && load_pointee_paths(state, root, path)) {
		bit_mark(state.merged, deeper_content_loan(root, loan, loan_index))
	}
	return false
}

@(private = "file")
note_read :: proc(reads: ^[dynamic]int, slot: int) {
	if reads != nil && !slice.contains(reads[:], slot) {
		append(reads, slot)
	}
}

// A load through a parameter's loan reads the slots standing for the caller
// storage it names, along `path`, as one through a local's loan reads its
// content: what was stored there, or what the storage held when the call
// began. Given `elements`, the slots of the one element of a view parameter
// the load names, it reads those instead (`prov_view_element`). False when
// no slot lies along `path`.
@(private = "file")
read_caller_slots :: proc(
	state: ^Prov_Solve,
	loan_index: int,
	path: []Proj_Step,
	reach: []u8,
	loss: ^Precision_Loss,
	reads: ^[dynamic]int,
	elements: []int = nil,
) -> bool {
	// A loan with no caller slots has no entry.
	listed, found := state.graph.caller_slots[Loan_Id(loan_index)]
	if !found {
		return false
	}
	slots := elements if len(elements) > 0 else listed[:]
	read := false
	for slot in slots {
		if !paths_overlap(state.graph.prov_slots[slot].path, path) {
			continue
		}
		read = true
		loss^ |= state.precision[slot]
		bytes_or(state.merged, reach_row(state, reach, slot))
		note_read(reads, slot)
	}
	return read
}

// A load along `path` through a carrier parameter's own loan reads only the
// pointee paths it overlaps. False when it names none of them, as a load of
// the whole pointee or of storage beside its carriers does.
@(private = "file")
load_pointee_paths :: proc(state: ^Prov_Solve, root: Prov_Root, path: []Proj_Step) -> bool {
	if len(path) == 0 || len(root.pointee_loans) == 0 {
		return false
	}
	graph := state.graph
	shape := carrier_pointee_shape(graph.k.c, symbol_of(graph.k.c, root.symbol).type)
	marked := false
	for loans, position in root.pointee_loans {
		if paths_overlap(shape[position].steps, path) {
			bit_mark(state.merged, int(loans[0]))
			marked = true
		}
	}
	return marked
}

// Records which slots each indirect read uses before the backward pass, so a
// mutation before `p^.view` conflicts with the borrow held in the pointee.
@(private = "file")
resolve_content_reads :: proc(state: ^Prov_Solve) {
	content_loans := make([dynamic]int, 0, 2, state.graph.alloc)
	for loan, index in state.graph.loans {
		if len(loan_own_slots(state.graph, loan, state.graph.roots[int(loan.root)])) > 0 {
			append(&content_loans, index)
		}
	}
	if len(content_loans) == 0 && !state.graph.has_content_load && !state.graph.has_replacing_store { return }
	for block in state.graph.blocks {
		if !enter_block(state, block) {
			continue
		}
		for &event in block.prov {
			if event.kind == .Load {
				reads := make([dynamic]int, 0, 4, state.graph.alloc)
				load_pointee_content(state, event, state.reach, &reads)
				if event.load == .At_Once {
					// A record or array passed by value is no carrier to read through.
					for slot in event.into {
						if prov_slot_is_stored(state.graph.prov_slots[slot]) {
							note_read(&reads, slot)
						}
					}
				}
				event.sources = reads[:]
				prov_reborrow_loaded(state.graph, event)
			} else {
				if event.kind == .Publish {
					event.replaces = publish_replaced_slots(state, event, state.reach, state.ended)
				}
				if event.kind == .Live {
					event.keeps_live = with_held_content(state, event.hands_on ? event.sources : event.keeps_live, content_loans[:])
				}
				run_prov_event(state, event, state.reach, state.ended)
			}
		}
	}
}

// design.md "Values that contain borrows": what the storage a use's sources lend
// holds now, and so on through any carrier held there. Whatever a carrier is handed
// to may read what it reaches, so what that storage borrows stays live for the
// call.
@(private)
with_held_content :: proc(state: ^Prov_Solve, sources, content_loans: []int) -> []int {
	if len(content_loans) == 0 {
		return nil
	}
	graph := state.graph
	out := make([dynamic]int, 0, len(sources) + 2, graph.alloc)
	append(&out, ..sources)
	for at := 0; at < len(out); at += 1 {
		row := reach_row(state, state.reach, out[at])
		for index in content_loans {
			if !bit_get(row, index) {
				continue
			}
			loan := graph.loans[index]
			for slot in loan_own_slots(graph, loan, graph.roots[int(loan.root)]) {
				if paths_overlap(graph.prov_slots[slot].path, loan.path) && !slice.contains(out[:], slot) {
					append(&out, slot)
				}
			}
		}
	}
	return out[len(sources):]
}

// `view_element_loan`'s loan, narrowed or not; a store needs no `known`.
@(private)
publish_view_loan :: proc(graph: ^Flow_Graph, event: Prov_Event, one: int) -> Prov_Loan {
	loan, _ := view_element_loan(graph, event.element, one)
	return loan
}

// design.md "Places and overlap": whether the elements `a` and `b` name are
// different elements of what the slots `a_slot` and `b_slot` view, relative
// to every loan both hold (`view_element_in`). A loan an access goes through
// that either element is not known in may name the same element.
@(private = "file")
view_elements_apart :: proc(state: ^Prov_Solve, a: Prov_View_At, a_slot: int, b: Prov_View_At, b_slot: int) -> bool {
	if a.slot == 0 || b.slot == 0 {
		return false
	}
	first := reach_row(state, state.reach, a_slot)
	second := reach_row(state, state.reach, b_slot)
	shared := false
	for index in 0 ..< state.loans {
		if !bit_get(first, index) || state.ended[index] || !bit_get(second, index) {
			continue
		}
		left, left_known := view_element_in(state.graph, a, index)
		right, right_known := view_element_in(state.graph, b, index)
		if !left_known || !right_known || left == right {
			return false
		}
		shared = true
	}
	return shared
}

// The slots a store through carriers replaces (`publish_into_loan`).
@(private = "file")
publish_replaced_slots :: proc(state: ^Prov_Solve, event: Prov_Event, reach: []u8, ended: []bool) -> []int {
	settled := publish_place_settled(state, event, reach)
	one := publish_one_loan(state, settled, reach, ended)
	if one < 0 {
		return nil
	}
	graph := state.graph
	out := make([dynamic]int, 0, 1, graph.alloc)
	// One element of a view parameter is one place (`prov_view_element`).
	slots, caller := graph.caller_slots[Loan_Id(one)]
	candidates: []int
	if element, is_element := settled.store.(Prov_Element_Slots); is_element && Loan_Id(one) == element.loan {
		candidates = element.slots
	} else if caller && graph.prov_slots[slots[0]].caller_one {
		candidates = slots[:]
	}
	if candidates != nil {
		for index in candidates {
			if caller_replaces(graph.k.c, graph.prov_slots[index], event.path, event.carried) {
				append(&out, index)
			}
		}
		return out[:]
	}
	loan := publish_view_loan(graph, event, one)
	for index in root_own_slots(graph, graph.roots[int(loan.root)]) {
		if publish_replaces(graph, index, loan, event.path, event.carried) {
			append(&out, index)
		}
	}
	return out[:]
}

// Backward: which slots have a later use, and where. A loan lives until the
// last use of every copy.
@(private = "file")
solve_loan_liveness :: proc(state: ^Prov_Solve) {
	graph := state.graph
	queue := make([dynamic]Block_Id, 0, len(graph.blocks), graph.alloc)
	queued := make([]bool, len(graph.blocks), graph.alloc)
	for index := len(graph.blocks) - 1; index >= 0; index -= 1 {
		append(&queue, Block_Id(index))
		queued[index] = true
	}
	for head := 0; head < len(queue); head += 1 {
		id := int(queue[head])
		block := graph.blocks[id]
		queued[id] = false
		mem.zero_slice(state.live)
		slice.fill(state.uses, no_span())
		for successor in block.succs {
			target := graph.blocks[successor]
			for value, index in target.live_entry {
				if value > state.live[index] {
					state.live[index] = value
					state.uses[index] = target.use_entry[index]
				}
			}
		}
		copy(block.live_exit, state.live)
		copy(block.use_exit, state.uses)
		for index := len(block.prov) - 1; index >= 0; index -= 1 {
			run_live_event(block.prov[index], state.live, state.uses)
		}
		if slice.equal(block.live_entry, state.live) {
			continue
		}
		copy(block.live_entry, state.live)
		copy(block.use_entry, state.uses)
		for predecessor in block.preds {
			if !queued[int(predecessor)] {
				append(&queue, predecessor)
				queued[int(predecessor)] = true
			}
		}
	}
}

// Joins `state.merged` into the slots holding what one loan's storage contains at
// the event's `path` below it. A carrier whose loans were merged may name storage
// the write never reaches, so what lands there carries the carrier's precision as
// well. When `one`, the store's carriers name only this loan, so a slot holding
// exactly that place is replaced instead (`publish_replaces`).
@(private)
publish_into_loan :: proc(state: ^Prov_Solve, reach: []u8, loan_index: int, event: Prov_Event, one: bool, carrier_loss: Precision_Loss) {
	graph := state.graph
	loan := publish_view_loan(graph, event, loan_index) if one else graph.loans[loan_index]
	stored := event.carried if one else INVALID_TYPE
	linked := event.carried if event.linked else INVALID_TYPE
	by_type := event.carried if event.lands_by_type else INVALID_TYPE
	_, retained := event.store.(Prov_Store_Retained)
	// A store whose copies no reborrow links to where it lands is still seen
	// by every later load through the parameter, which then reborrows what
	// it copied from.
	slots, caller := graph.caller_slots[Loan_Id(loan_index)]
	if caller && graph.prov_slots[slots[0]].caller_one {
		if publish_into_caller(state, reach, slots[:], loan, event.path, stored, carrier_loss, linked, by_type) || retained {
			return
		}
	} else if retained {
		// What a call leaves in a view may be in any element, each of which
		// these slots stand for, and which `prov_link_retained` links, unless
		// all it was given of that view is a pointer to one.
		if caller {
			landing := slots[:]
			if event.through_element {
				if at := carriers_element(state, event.into, reach, loan_index); len(at.slots) > 0 && Loan_Id(loan_index) == at.loan {
					landing = at.slots
				}
			}
			publish_into_caller(state, reach, landing, loan, event.path, INVALID_TYPE, carrier_loss, INVALID_TYPE, by_type)
		}
	} else if element, names_element := event.store.(Prov_Element_Slots); names_element && one && Loan_Id(loan_index) == element.loan {
		if publish_into_caller(state, reach, element.slots, loan, event.path, stored, carrier_loss, linked, by_type) {
			return
		}
	} else if caller && event.linked &&
	   publish_into_caller(state, reach, slots[:], loan, event.path, INVALID_TYPE, carrier_loss, linked, by_type) {
		// It names no one element or place of what the loan's slots stand for,
		// so it replaces none of them, and its copy is linked to each.
		return
	}
	for index in root_own_slots(graph, graph.roots[int(loan.root)]) {
		slot := graph.prov_slots[index]
		if carrier_may_land_in(graph.k.c, slot_carrier_type(graph, index), by_type) && paths_overlap_joined(slot.path, loan.path, event.path) {
			land_in_slot(state, reach, index, publish_replaces(graph, index, loan, event.path, stored), loan.path, carrier_loss)
		}
	}
}

// Replaces or joins `state.merged` into a slot a store lands in.
@(private = "file")
land_in_slot :: proc(state: ^Prov_Solve, reach: []u8, index: int, replaces: bool, loan_path: []Proj_Step, carrier_loss: Precision_Loss) {
	loss := state.merged_precision | carrier_loss | state.graph.prov_slots[index].precision
	if state.landed != nil { append(state.landed, index) }
	if replaces {
		copy(reach_row(state, reach, index), state.merged)
		state.precision[index] = loss
		return
	}
	bytes_or(reach_row(state, reach, index), state.merged)
	state.precision[index] |= loss | path_precision(loan_path)
}

// design.md "Values that contain borrows": a store through a parameter's
// loan lands in the slots standing for the caller storage it names, at
// `path`, which a later load through the loan reads (`read_caller_slots`).
// Only a slot of one place is replaced (`caller_replaces`). True when the
// store is `linked` and each slot it lands in is one its copies are linked
// to, so the parameter itself need not hold it.
@(private)
publish_into_caller :: proc(
	state: ^Prov_Solve, reach: []u8, slots: []int, loan: Prov_Loan, path: []Proj_Step, stored: Type_Id,
	carrier_loss: Precision_Loss, linked: Type_Id, by_type: Type_Id,
) -> bool {
	c := state.graph.k.c
	// A value holding carriers is linked only where it lands in a slot.
	carrier := linked != INVALID_TYPE && type_is_carrier(c, linked)
	landed, found := linked != INVALID_TYPE, carrier
	for index in slots {
		slot := state.graph.prov_slots[index]
		if !paths_overlap(slot.path, path) || !carrier_may_land_in(c, slot_carrier_type(state.graph, index), by_type) {
			continue
		}
		found = true
		landed = landed && (carrier || slot.content_type != INVALID_TYPE && prov_slot_holds_stored(c, slot, linked))
		land_in_slot(state, reach, index, caller_replaces(c, slot, path, stored), loan.path, carrier_loss)
	}
	return landed && found
}

// Whether a store of `stored` at `path` below a parameter loan's caller storage
// replaces `slot`, one of its caller slots: the storage is one place, or one
// element of a view, and `replaces_at` holds.
@(private)
caller_replaces :: proc(c: ^Compiler, slot: Prov_Slot, path: []Proj_Step, stored: Type_Id) -> bool {
	if stored == INVALID_TYPE || !slot.caller_one && !slot.caller_element || slot.content_type == INVALID_TYPE ||
	   !path_is_exact(slot.path) || !path_is_exact(path) || !paths_overlap(slot.path, path) {
		return false
	}
	return replaces_at(c, slot.path, len(path), stored, slot.content_type)
}

// Whether `slot`, of `loan`'s storage, holds exactly the one place a store of
// `stored` at `path` below that storage writes. A view's loan ends in the range it
// lends, so an element below it is one step longer than any slot of its type.
@(private = "file")
publish_replaces :: proc(graph: ^Flow_Graph, index: int, loan: Prov_Loan, path: []Proj_Step, stored: Type_Id) -> bool {
	slot := graph.prov_slots[index]
	type := slot_carrier_type(graph, index)
	if stored == INVALID_TYPE || type == INVALID_TYPE || !path_is_exact(slot.path) ||
	   !path_is_exact(loan.path) || !path_is_exact(path) || !paths_overlap_joined(slot.path, loan.path, path) {
		return false
	}
	return replaces_at(graph.k.c, slot.path, len(loan.path) + len(path), stored, type)
}

// Whether a store of `stored`, `at` steps down, replaces a slot of `type` at
// `slot_path`: it holds exactly that carrier, or a carrier inside a value holding
// carriers, stored whole, as storing it into a local does (design.md "Values that
// contain borrows").
@(private = "file")
replaces_at :: proc(c: ^Compiler, slot_path: []Proj_Step, at: int, stored, type: Type_Id) -> bool {
	if type == stored {
		return len(slot_path) == at
	}
	return len(slot_path) > at && !type_is_carrier(c, stored) && stored_carrier_at(c, stored, slot_path[at:], type)
}

// Whether a carrier of `type` lies exactly at `below` inside a `stored` value.
@(private = "file")
stored_carrier_at :: proc(c: ^Compiler, stored: Type_Id, below: []Proj_Step, type: Type_Id) -> bool {
	for inner in carrier_shape(c, stored) {
		if !inner.truncated && inner.type == type && len(inner.steps) == len(below) && path_is_exact(inner.steps) &&
		   paths_overlap(inner.steps, below) {
			return true
		}
	}
	return false
}

// Whether `path` names one place: no wildcard, range of several elements, or
// merged step.
@(private)
path_is_exact :: proc(path: []Proj_Step) -> bool {
	for step in path {
		if step.kind == .Wild || step.kind == .Range && step.hi != step.lo + 1 || step.precision != {} {
			return false
		}
	}
	return true
}

// `paths_overlap` of `a` and `prefix` followed by `rest`.
@(private = "file")
paths_overlap_joined :: proc(a, prefix, rest: []Proj_Step) -> bool {
	for step, index in a {
		other: Proj_Step
		switch {
		case index < len(prefix):
			other = prefix[index]
		case index - len(prefix) < len(rest):
			other = rest[index - len(prefix)]
		case:
			return true
		}
		if !steps_overlap(step, other) {
			return false
		}
	}
	return true
}

// What a slot's liveness was before a replayed event changed it.
@(private = "file")
Live_Change :: struct {
	slot: int,
	live: Slot_Use,
	use:  Span,
}

// A backward step of liveness. `changes`, when given, gathers what it overwrites.
@(private = "file")
run_live_event :: proc(event: Prov_Event, live: []Slot_Use, uses: []Span, changes: ^[dynamic]Live_Change = nil) {
	set :: proc(live: []Slot_Use, uses: []Span, changes: ^[dynamic]Live_Change, slot: int, value: Slot_Use, use: Span) {
		if changes != nil {
			append(changes, Live_Change{slot, live[slot], uses[slot]})
		}
		live[slot], uses[slot] = value, use
	}
	#partial switch event.kind {
	case .Def:
		// A definition joining the slot's own value, as a store that may have
		// left what the slot held does, does not end that value (design.md
		// "Places and overlap").
		if !slice.contains(event.sources, event.slot) {
			set(live, uses, changes, event.slot, .None, uses[event.slot])
		}
	case .Publish:
		for slot in event.replaces {
			set(live, uses, changes, slot, .None, uses[slot])
		}
	case .Load:
		set(live, uses, changes, event.slot, .None, uses[event.slot])
		for source in event.sources {
			set(live, uses, changes, source, .Used, event.span)
		}
	case .Live, .Escape:
		for source in event.sources {
			set(live, uses, changes, source, .Used, event.span)
		}
		for slot in event.keeps_live {
			if live[slot] != .Used {
				set(live, uses, changes, slot, .Kept, event.span)
			}
		}
	}
}

// ------------------------------------------------------------ reporting --

@(private = "file")
report_provenance :: proc(state: ^Prov_Solve) {
	graph := state.graph
	// One expression gets one borrow diagnostic: a receiver and the call it
	// starts, or two rules meeting the same mistake, report once.
	reported := make(map[[2]u32]bool, graph.alloc)
	window_entry := solve_window(state)
	window := make([]u8, (len(graph.task_sites) + 7) / 8, graph.alloc)
	shared := Shared_Reports{
		seen   = make(map[Shared_Report]bool, graph.alloc),
		scopes = make(map[int]bool, graph.alloc),
	}
	// What each event's replay changed, so going forward undoes it.
	changes := make([dynamic]Live_Change, 0, 64, graph.alloc)
	marks := make([dynamic]int, 0, 64, graph.alloc)
	for block, id in graph.blocks {
		if !block.prov_visited || len(block.prov) == 0 {
			continue
		}
		copy(window, window_entry[id])
		count := len(block.prov)
		// Replayed from the block's exit; event `index`'s changes are those from
		// `marks[index + 1]` up to `marks[index]`.
		clear(&changes)
		resize(&marks, count + 1)
		copy(state.live, block.live_exit)
		copy(state.uses, block.use_exit)
		marks[count] = 0
		for index := count - 1; index >= 0; index -= 1 {
			run_live_event(block.prov[index], state.live, state.uses, &changes)
			marks[index] = len(changes)
		}
		enter_block(state, block)
		copy(state.links_held, block.links_entry)
		for event, index in block.prov {
			// Liveness after this event, which is what it consults.
			undo := changes[marks[index + 1]:marks[index]]
			#reverse for change in undo {
				state.live[change.slot], state.uses[change.slot] = change.live, change.use
			}
			// A temporary's end has no span of its own and is never merged.
			at := [2]u32{event.span.file, event.span.lo}
			placed := event.span != Span{}
			if !placed || !reported[at] {
				before := len(state.k.c.diagnostics)
				already := event.repeats_inner && reported_within(reported, event.span)
				if !already {
					check_prov_event(state, event, state.live, state.uses)
				}
				if placed && (already || len(state.k.c.diagnostics) > before) {
					reported[at] = true
				}
			}
			check_shared_event(state, event, window, &shared)
			window_step(graph, window, event)
			run_prov_event(state, event, state.reach, state.ended)
			run_links_held_event(state, event, state.links_held)
		}
	}
}

// Whether a diagnostic was reported inside `span`, as for an argument of the call
// `span` is.
@(private = "file")
reported_within :: proc(reported: map[[2]u32]bool, span: Span) -> bool {
	for at in reported {
		if at[0] == span.file && at[1] >= span.lo && at[1] < span.hi {
			return true
		}
	}
	return false
}

// Whether a reset ends storage rooted here: a control block the provider's
// destruction ends, in a region it may name or one never recorded. `free_all`
// leaves handles usable.
@(private = "file")
reset_ends_root :: proc(root: Prov_Root, event: Prov_Event) -> bool {
	if root.kind != .Provider || !event.provider_end {
		return false
	}
	return region_is_empty(root.region) || regions_may_overlap(root.region, event.region)
}

@(private = "file")
access_conflicts :: proc(loan: Prov_Loan, event: Prov_Event) -> bool {
	if loan.root != event.root || !paths_overlap(loan.path, event.path) {
		return false
	}
	return event.access != .Read || loan.mutable
}

@(private = "file")
check_prov_event :: proc(state: ^Prov_Solve, event: Prov_Event, live: []Slot_Use, uses: []Span) {
	graph := state.graph
	before := len(state.k.c.diagnostics)
	state.diagnostic_precision = path_precision(event.path)
	for source in event.sources { state.diagnostic_precision |= state.precision[source] }
	defer {
		if len(state.k.c.diagnostics) > before {
			add_precision_notes(state.k.c, event.span, state.diagnostic_precision, event.region.crowded, event.region.crowded_params)
		}
	}
	#partial switch event.kind {
	case .Cross:
		check_crossing(state, event)
	case .Access:
		it := live_loans(state, live)
		for slot, index in next_live_loan(&it) {
			loan := graph.loans[index]
			if !access_conflicts(loan, event) || event.access == .Read && graph.prov_slots[slot].read_only_hold {
				continue
			}
			state.diagnostic_precision |= state.precision[slot]
			report_borrow_conflict(state, event, loan, uses[slot])
			return
		}
	case .Task_Join:
		check_join_retention(state, event, live)
	case .Through:
		check_place_loans(state, event, live, uses)
	case .Live, .Load:
		// A reborrow suspends its source until its own last use, and the last use
		// of whatever was reborrowed from it in turn.
		for source in event.sources {
			if reborrow, derived, found := live_reborrow_of(state, source, live, event); found {
				state.diagnostic_precision |= state.precision[derived]
				report_suspended_reborrow(state, event, reborrow, event.span if event.load == .At_Once else uses[derived])
				return
			}
		}
	case .Root_End:
		it := live_loans(state, live)
		for slot, index in next_live_loan(&it) {
			loan := graph.loans[index]
			// A result borrowing frame storage is the `Escape` event's error.
			if loan.root != event.root || graph.prov_slots[slot].returned {
				continue
			}
			state.diagnostic_precision |= state.precision[slot]
			report_root_outlived(state, event, loan, uses[slot])
			return
		}
	case .Escape:
		check_escape(state, event)
	case .Retain:
		check_retention(state, event)
	case .Reset:
		check_region_reset(state, event, live, uses)
	case .Region_Escape:
		check_region_escape(state, event)
	}
}

// A result backed by a region created here, as an owner or an allocation, or
// borrowing storage that ends with the frame.
@(private = "file")
check_escape :: proc(state: ^Prov_Solve, event: Prov_Event) {
	graph := state.graph
	c := state.k.c
	if region_has_local(event.region) {
		if event.name != "" {
			errorf(c, event.span, "L0592", "this result is backed by `%s`, an allocator region that ends when this procedure returns", event.name)
		} else {
			errorf(c, event.span, "L0592", "this result is backed by an allocator region created in this procedure, which ends when it returns")
		}
		return
	}
	it := slots_loans(state, prov_join(graph, event.sources, event.into))
	for _, index in next_live_loan(&it) {
		loan := graph.loans[index]
		root := graph.roots[int(loan.root)]
		if root_outlives_body(root.kind) || root_names_source(graph, root) {
			continue
		}
		// As in `report_borrow_conflict`.
		escaping := "this %s cannot be returned: %s ends when this procedure returns"
		if state.diagnostic_precision != {} {
			escaping = "this %s may depend on %s, which ends when this procedure returns"
		}
		errorf(c, event.span, "L0526", escaping, loan.what, root_phrase(root))
		add_root_notes(state, root, loan)
		add_plain_call_note(state, loan)
		return
	}
}

// An owner stored in longer-lived storage than its region.
@(private = "file")
check_region_escape :: proc(state: ^Prov_Solve, event: Prov_Event) {
	c := state.k.c
	if event.moved != "" {
		errorf(c, event.span, "L0536", "`%s` was received by `move`, and its `@(escape=...)` level does not let it be stored in %s", event.moved, event.name)
		return
	}
	errorf(
		c, event.span, "L0536", "%s is backed by an allocator region %s, so it cannot be stored in %s, which outlives that region",
		event.verb, region_has_local(event.region) ? "created in this procedure" : "this procedure received", event.name,
	)
}

// design.md "Weakening and reborrows": the first reborrow of `source` that a live slot still
// holds a value derived through (`solve_links_held`), and that live slot.
@(private = "file")
live_reborrow_of :: proc(state: ^Prov_Solve, source: int, live: []Slot_Use, use: Prov_Event) -> (Prov_Reborrow, int, bool) {
	graph := state.graph
	links := reborrows_of(state, source)
	if len(links) == 0 {
		return {}, -1, false
	}
	at_once := use.load == .At_Once
	candidates := make([dynamic]int, 0, 8, context.temp_allocator)
	for row, slot in state.links_held {
		if row == 0 {
			continue
		}
		if at_once ? slice.contains(use.sources, slot) : slot != source && live[slot] == .Used {
			append(&candidates, slot)
		}
	}
	for index in links {
		reborrow := graph.reborrows[index]
		// Only a mutable reborrow excludes a read; what is derived from a
		// read-only one is read-only too.
		if reborrow.passes_on || reborrow.moved || (use.reads_only && !reborrow.mutable) {
			continue
		}
		// Only its own expression reads a temporary, so a later use of one is of a new
		// value; what it was copied from is what a store's link suspends.
		if reborrow.from_store > 0 && graph.prov_slots[source].kind == .Temporary {
			continue
		}
		for slot in candidates {
			if !bit_get(state.link_rows[state.links_held[slot]], index) {
				continue
			}
			// A slot standing for many places holds the copy too, whichever it is.
			if slot == source {
				return reborrow, source, true
			}
			// What was stored back into the carrier it was loaded through is that one's
			// current value, not a competing use; nor is a carrier the use itself goes
			// through, as a slice argument holding a reborrow of the elements a call
			// reads through it.
			if use.kind == .Load && !at_once && slice.contains(use.into, slot) {
				continue
			}
			// A load defines its slot afresh, as a loop's `list^.head` loads its temporary
			// again, so that slot's later uses are of the new value.
			if use.kind == .Load && slot == use.slot || use.reads_only && graph.prov_slots[slot].read_only_hold || !prov_slots_overlap(state, source, slot) {
				continue
			}
			if !at_once || at_once_reaches(state, use, source) {
				return reborrow, slot, true
			}
		}
	}
	return {}, -1, false
}

// Whether a call's `At_Once` load reaches `source` by other than what was reborrowed
// from it. A copy points where `source` does, so what it reaches is not `source` in
// any program that keeps one mutable path to each place: finding `source` that way
// only says the copy's loan names storage holding `source` too, as a value split out
// of a view borrows the view (design.md "Weakening and reborrows").
@(private = "file")
at_once_reaches :: proc(state: ^Prov_Solve, use: Prov_Event, source: int) -> bool {
	if slice.contains(use.into, source) {
		return true
	}
	derived := make([dynamic]int, 0, 8, context.temp_allocator)
	append(&derived, source)
	links := reborrows_of(state, source)
	for held, slot in state.links_held {
		if slot == source || held == 0 {
			continue
		}
		for index in links {
			if bit_get(state.link_rows[held], index) {
				append(&derived, slot)
				break
			}
		}
	}
	saved := make([]u8, state.row_bytes * len(derived), context.temp_allocator)
	for slot, at in derived[1:] {
		row := reach_row(state, state.reach, slot)
		copy(saved[at * state.row_bytes:], row)
		mem.zero_slice(row)
	}
	reads := make([dynamic]int, 0, 8, context.temp_allocator)
	load_pointee_content(state, use, state.reach, &reads)
	for slot, at in derived[1:] {
		copy(reach_row(state, state.reach, slot), saved[at * state.row_bytes:][:state.row_bytes])
	}
	return slice.contains(reads[:], source)
}

// The index is rebuilt once materialization has added reborrows since, so a search
// through a long chain of reborrows reads only each slot's own.
@(private = "file")
reborrows_of :: proc(state: ^Prov_Solve, slot: int) -> []int {
	graph := state.graph
	if state.reborrow_starts == nil || state.reborrows_indexed != len(graph.reborrows) {
		slots := len(graph.prov_slots)
		starts := make([]int, slots + 1, graph.alloc)
		for reborrow in graph.reborrows {
			starts[reborrow.source + 1] += 1
		}
		for index in 0 ..< slots {
			starts[index + 1] += starts[index]
		}
		indices := make([]int, len(graph.reborrows), graph.alloc)
		filled := make([]int, slots, context.temp_allocator)
		for reborrow, index in graph.reborrows {
			indices[starts[reborrow.source] + filled[reborrow.source]] = index
			filled[reborrow.source] += 1
		}
		state.reborrow_starts, state.reborrow_indices, state.reborrows_indexed = starts, indices, len(graph.reborrows)
	}
	return state.reborrow_indices[state.reborrow_starts[slot]:state.reborrow_starts[slot + 1]]
}

// An access through carriers that name storage a live place loan names, at
// an overlapping path, as a store replacing the payload a switch binding
// still views (design.md "Switch ownership"), or a read of a place a mutable
// borrow through another carrier still holds (design.md "Weakening and
// reborrows"). An access through the loan itself, a carrier holding its bit,
// is its own.
@(private = "file")
check_place_loans :: proc(state: ^Prov_Solve, event: Prov_Event, live: []Slot_Use, uses: []Span) {
	carrying: Live_Place_Bits
	gathered := false
	for loan, index in state.graph.place_loans {
		if (event.access == .Read && !loan.mutable) || !place_loan_overlaps(loan, event.path) {
			continue
		}
		if !gathered {
			carrying, gathered = live_place_bits(state, live, event.access == .Read), true
		}
		later, lent := place_loan_use(state, index, live, uses, carrying)
		if !lent {
			continue
		}
		bit := place_bit(state, index)
		for carrier in event.into {
			if !prov_slots_overlap(state, loan.slot, carrier) || bit_get(reach_row(state, state.reach, carrier), bit) ||
			   accessed_beside(state, index, carrier) || view_elements_apart(state, loan.element, loan.slot, event.element, carrier) {
				continue
			}
			state.diagnostic_precision |= state.precision[loan.slot] | state.precision[carrier] | event.precision
			if loan.borrows {
				report_place_borrowed(state, event, loan, carrier, later)
				return
			}
			// As in `report_borrow_conflict`.
			errorf(
				state.k.c, event.span, "L0511",
				"this %s %s the %s %s of `%s` that is still in use",
				event.verb, state.diagnostic_precision != {} ? "may not be compatible with" : "is not compatible with",
				loan.mutable ? "mutable" : "read-only", loan.what, loan.place,
			)
			add_notef(state.k.c, loan.span, "the switch borrows the %s here", loan.what)
			add_use_note(state, later)
			return
		}
	}
}

// Whether `carrier` was read out through another place loan of the storage
// place loan `index` names, at a place beside it, as `left` is for `right`
// in `.add(&mut left, &mut right)`: what it reaches is inside that place, so
// an access through it is beside this one too.
@(private = "file")
accessed_beside :: proc(state: ^Prov_Solve, index: int, carrier: int) -> bool {
	loans := state.graph.place_loans
	row := reach_row(state, state.reach, carrier)
	for other, at in loans {
		if at == index || !other.borrows || !bit_get(row, place_bit(state, at)) || !prov_slots_overlap(state, other.slot, loans[index].slot) {
			continue
		}
		if !place_loans_overlap(other, loans[index]) || view_elements_apart(state, other.element, other.slot, loans[index].element, loans[index].slot) {
			return true
		}
	}
	return false
}

@(private = "file")
place_loan_overlaps :: proc(loan: Prov_Place_Loan, path: []Proj_Step) -> bool {
	for at in loan.paths {
		if paths_overlap(at, path) {
			return true
		}
	}
	return false
}

@(private = "file")
place_loans_overlap :: proc(a, b: Prov_Place_Loan) -> bool {
	for at in a.paths {
		if place_loan_overlaps(b, at) {
			return true
		}
	}
	return false
}

// The source is suspended only while both slots' current values share a valid
// loan, so overwriting either one ends the reborrow.
@(private = "file")
prov_slots_overlap :: proc(state: ^Prov_Solve, source_slot, derived_slot: int) -> bool {
	source := reach_row(state, state.reach, source_slot)
	derived := reach_row(state, state.reach, derived_slot)
	for index in 0 ..< state.loans {
		if bit_get(source, index) && !state.ended[index] && bit_get(derived, index) {
			return true
		}
	}
	return false
}

// A reset is rejected when the body may not reset that region at all, or when an
// owner or borrow of the region is still live.
@(private = "file")
check_region_reset :: proc(state: ^Prov_Solve, event: Prov_Event, live: []Slot_Use, uses: []Span) {
	graph := state.graph
	if event.access == .Invalidate && !event.reset_covered {
		errorf(
			state.k.c, event.span, "L0538",
			"this resets a region that existed before the call, so the allocator must arrive through an `@(allocator_reset)` parameter",
		)
		return
	}
	if event.access == .Write && !event.reset_covered {
		// A reset-capable call given one of this body's own allocators.
		if event.name != "" {
			errorf(state.k.c, event.span, "L0538", "this call may reset `%s`, so `%s` must be marked `@(allocator_reset)`", event.name, event.name)
		} else {
			errorf(
				state.k.c, event.span, "L0538",
				"this call may reset a pre-existing or unknown allocator region, so the reset cannot be hidden in this procedure",
			)
		}
		return
	}
	if event.ends_result {
		errorf(
			state.k.c, event.span, "L0537",
			"%s would end the region backing the returned value, which the caller already holds when deferred statements run",
			event.ends != "" ? event.ends : "this reset",
		)
		add_notef(state.k.c, event.owner_span, "the value is returned here")
		return
	}
	if event.verb != "" {
		errorf(
			state.k.c, event.span, "L0537", "%s would end the region backing `%s`, which is still live here",
			event.ends != "" ? event.ends : "this reset", event.verb,
		)
		add_notef(state.k.c, event.owner_span, "`%s` is declared here and is cleaned up after this point", event.verb)
		if from, unwinding := event.unwind_from.?; unwinding {
			add_notef(state.k.c, from, "a panic in this statement unwinds through the cleanup, before `%s` is dropped", event.verb)
		}
		return
	}
	it := live_loans(state, live)
	for slot, index in next_live_loan(&it) {
		loan := graph.loans[index]
		root := graph.roots[int(loan.root)]
		if !reset_ends_root(root, event) {
			continue
		}
		// A result backed by this frame's region is the `Escape` event's error.
		if graph.prov_slots[slot].returned && region_is_local_only(root.region) {
			continue
		}
		errorf(state.k.c, event.span, "L0537", "%s would end an allocator control block whose handle is still in use", event.ends != "" ? event.ends : "this cleanup")
		state.diagnostic_precision |= state.precision[slot]
		add_notef(state.k.c, loan.span, "the %s is created here", loan.what)
		add_use_note(state, uses[slot])
		return
	}
}

@(private = "file")
report_borrow_conflict :: proc(state: ^Prov_Solve, event: Prov_Event, loan: Prov_Loan, later: Span) {
	k := state.k
	root := state.graph.roots[int(loan.root)]
	// A merged dependency may be the only reason these two look like one place,
	// so the message claims no more than the analysis knows (design.md "Minimum
	// provenance precision"); the notes added after it say which budget merged
	// them and how to keep the two apart.
	merged := state.diagnostic_precision != {}
	invalidated := "%s cannot be %s here: a %s %s of it is still in use"
	conflicting := "this %s of %s is not compatible with the %s %s of it that is still in use"
	if merged {
		invalidated = "%s cannot be %s here: a %s %s of it may still be in use"
		conflicting = "this %s of %s may overlap the %s %s of it that is still in use"
	}
	if event.access == .Invalidate {
		errorf(
			k.c, event.span, "L0512", invalidated,
			root_label(root), event.verb == "" ? "invalidated" : event.verb, loan.mutable ? "mutable" : "read-only", loan.what,
		)
	} else if event.access == .Read && event.verb != "" {
		// design.md "Global write effects": a call's read of a global.
		errorf(k.c, event.span, "L0511", invalidated, root_label(root), event.verb, "mutable", loan.what)
	} else {
		// design.md "@(synchronized)": such an access counts as a write, and a
		// borrow of the field as a mutable one, whatever was written.
		access := event.access == .Write ? "write" : "read"
		if path_is_synchronized(event.path) {
			access = "access through a synchronized field"
		}
		errorf(
			k.c, event.span, "L0511", conflicting,
			access, root_label(root), path_is_synchronized(loan.path) ? "exclusive" : loan.mutable ? "mutable" : "read-only", loan.what,
		)
	}
	add_borrow_notes(state, root, loan, later)
	note_last_use_move(k.c, event.verb)
}

// A move the program did not write needs saying where it came from.
@(private = "file")
note_last_use_move :: proc(c: ^Compiler, verb: string) {
	if verb == LAST_USE_VERB {
		add_notef(c, no_span(), "a copy of a local that nothing reads afterwards moves it; write `.clone()` to copy it instead")
	}
}

@(private = "file")
report_suspended_reborrow :: proc(
	state: ^Prov_Solve,
	event: Prov_Event,
	reborrow: Prov_Reborrow,
	later: Span,
) {
	k := state.k
	source := state.graph.prov_slots[reborrow.source]
	derived := state.graph.prov_slots[reborrow.derived]
	capability := reborrow.mutable ? "mutable" : "read-only"
	// A place, or a temporary, used through a binding that views it. A slice
	// literal's element has a description rather than a name.
	name := fmt.tprintf("`%s`", event.name if event.name != "" else source.name)
	if event.name == "" && source.kind == .Literal {
		name = source.name
	}
	covers := state.diagnostic_precision != {} ? " that may cover this place" : ""
	errorf(k.c, event.span, "L0641", "%s cannot be used here: a %s reborrow of it%s is still in use", name, capability, covers)
	if derived.name != "" {
		add_notef(k.c, reborrow.span, "`%s` reborrows it %s here", derived.name, reborrow.mutable ? "mutably" : "read-only")
	} else {
		add_notef(k.c, reborrow.span, "the %s reborrow is taken here", capability)
	}
	add_use_note(state, later)
}

// A carrier used for a place a borrow through another carrier still holds,
// as `h` for `h^.count += 1` while `count := &mut h^.count` is in use.
@(private = "file")
report_place_borrowed :: proc(state: ^Prov_Solve, event: Prov_Event, loan: Prov_Place_Loan, carrier: int, later: Span) {
	k := state.k
	name := event.name if event.name != "" else carrier_name(state.graph, carrier)
	capability := loan.mutable ? "mutable" : "read-only"
	// As in `report_borrow_conflict`.
	covers := state.diagnostic_precision != {} ? " that may cover this place" : ""
	errorf(k.c, event.span, "L0641", "`%s` cannot be used here: a %s reborrow of it%s is still in use", name, capability, covers)
	add_notef(k.c, loan.span, "the %s reborrow of `%s` is taken here", capability, loan.place)
	add_use_note(state, later)
}

// A carrier's name, or for a temporary reborrowed from one, as the read-only
// reborrow of `p^` that `p^^[1]` reads through, the name of what it reborrows.
@(private = "file")
carrier_name :: proc(graph: ^Flow_Graph, carrier: int) -> string {
	at := carrier
	for _ in 0 ..< len(graph.reborrows) + 1 {
		if graph.prov_slots[at].name != "" {
			return graph.prov_slots[at].name
		}
		source := -1
		for reborrow in graph.reborrows {
			if reborrow.derived == at {
				source = reborrow.source
				break
			}
		}
		if source < 0 {
			break
		}
		at = source
	}
	return ""
}

@(private = "file")
report_root_outlived :: proc(state: ^Prov_Solve, event: Prov_Event, loan: Prov_Loan, later: Span) {
	k := state.k
	root := state.graph.roots[int(loan.root)]
	label := root_label(root)
	// As in `report_borrow_conflict`.
	used := state.diagnostic_precision != {} ? "may be used" : "is used"
	// Points at the later use: the storage ends at no written operation.
	span := later.file == NO_FILE ? event.span : later
	if root.symbol == INVALID_SYMBOL {
		errorf(k.c, span, "L0513", "this %s %s after %s has ended", loan.what, used, label)
	} else {
		errorf(k.c, span, "L0513", "this %s %s after %s, the %s it borrows, has ended", loan.what, used, label, root_kind_text(root.kind))
	}
	if root.span.file != NO_FILE {
		if root.kind == .Temporary && root.extended {
			add_notef(k.c, root.span, "%s is kept until the end of the block that created it", label)
		} else if root.kind == .Temporary {
			add_notef(k.c, root.span, "%s ends with the statement that created it", label)
		} else {
			add_notef(k.c, root.span, "%s is declared here and ends with its scope", label)
		}
	}
	add_notef(k.c, loan.span, "the %s is created here", loan.what)
	// design.md "Task borrows and the join": the block's own
	// locals end before its join.
	if later_is_task_hold(state, later) {
		add_notef(
			k.c, later,
			"a task holds the %s until this `parallel` block joins, after its own locals end; declare the storage before the block, or spawn from a `parallel` block nested after it",
			loan.what,
		)
	}
}

// Whether a later use is a `parallel` block's join, which holds what its tasks hold.
@(private = "file")
later_is_task_hold :: proc(state: ^Prov_Solve, later: Span) -> bool {
	for scope in state.graph.task_slots {
		if sym := symbol_of(state.k.c, scope); sym != nil && sym.span == later {
			return true
		}
	}
	return false
}

@(private = "file")
add_root_notes :: proc(state: ^Prov_Solve, root: Prov_Root, loan: Prov_Loan) {
	if root.symbol != INVALID_SYMBOL && root.span.file != NO_FILE {
		add_notef(state.k.c, root.span, "%s is declared here", root_label(root))
	}
	add_notef(state.k.c, loan.span, "the %s is created here", loan.what)
}

// design.md "Procedure result contracts": a loan created in the arguments of a
// call through a type with no result contract reached the result only because
// that type states no bound. Names the innermost such call.
@(private = "file")
add_plain_call_note :: proc(state: ^Prov_Solve, loan: Prov_Loan) {
	found: ^Expr_Call
	for call in state.graph.plain_calls {
		if call.span.file == loan.span.file && call.span.lo <= loan.span.lo && loan.span.hi <= call.span.hi &&
		   (found == nil || call.span.hi - call.span.lo < found.span.hi - found.span.lo) {
			found = call
		}
	}
	if found != nil {
		add_notef(
			state.k.c, found.span,
			"a call through `%s` may return a borrow of any argument, because that type states no result bound; `@(escape=none)` on a parameter excludes it",
			type_name(state.k.c, call_proc_type(state.k.c, found)),
		)
	}
}

@(private = "file")
add_borrow_notes :: proc(state: ^Prov_Solve, root: Prov_Root, loan: Prov_Loan, later: Span) {
	k := state.k
	if root.symbol != INVALID_SYMBOL && root.span.file != NO_FILE {
		add_notef(
			k.c,
			root.span,
			"%s is the %s this %s borrows",
			root_label(root),
			root_kind_text(root.kind),
			loan.what,
		)
	}
	add_notef(k.c, loan.span, "the %s is created here", loan.what)
	add_use_note(state, later)
}

// The later use keeping a borrow live. One at a declaration is that local's
// `drop` hook, run when its scope ends.
@(private = "file")
add_use_note :: proc(state: ^Prov_Solve, later: Span) {
	if later.file == NO_FILE {
		return
	}
	if later_is_task_hold(state, later) {
		add_notef(state.k.c, later, "and a task holds it until this `parallel` block joins, which keeps it live")
		return
	}
	if state.graph.scope_drops[later] {
		add_notef(state.k.c, later, "and is still used when this is dropped at the end of its scope, which keeps it live")
	} else {
		add_notef(state.k.c, later, "and is still used here, which keeps it live")
	}
}

// A stored borrow must still be valid for as long as its destination lives.
@(private = "file")
check_retention :: proc(state: ^Prov_Solve, event: Prov_Event) {
	graph := state.graph
	// Written through a carrier (`p^.view`): the destinations are its loans' roots,
	// live or not.
	if len(event.into) > 0 {
		seen := make(map[Root_Id]bool, context.temp_allocator)
		it := slots_loans(state, event.into)
		for slot, index in next_live_loan(&it) {
			target := graph.loans[index].root
			if seen[target] {
				continue
			}
			seen[target] = true
			destination := graph.roots[int(target)]
			into := retain_kind_for_root(destination.kind)
			if into != .None && report_retention(state, event, into, target, destination, state.precision[slot]) {
				return
			}
		}
		return
	}
	destination := Prov_Root{symbol = INVALID_SYMBOL}
	if event.root != NO_ROOT {
		destination = graph.roots[int(event.root)]
	}
	report_retention(state, event, event.retain, event.root, destination)
}

// Reports the first loan of the stored value that does not reach the
// destination; returns whether it did. `destination_loss` is the precision of
// the carrier that names the destination.
//
// design.md "Minimum provenance precision": a merged dependency may be the
// only reason the value looks like a borrow of that storage, or the carrier
// like one naming that destination, so the message says each may be so.
@(private = "file")
report_retention :: proc(
	state: ^Prov_Solve,
	event: Prov_Event,
	into: Retain_Kind,
	target: Root_Id,
	destination: Prov_Root,
	destination_loss: Precision_Loss = {},
) -> bool {
	graph := state.graph
	borrows := state.diagnostic_precision != {} ? "may borrow" : "borrows"
	stored := destination_loss != {} ? ", where it may be stored" : ""
	it := slots_loans(state, event.sources)
	for _, index in next_live_loan(&it) {
		loan := graph.loans[index]
		root := graph.roots[int(loan.root)]
		// Storing into the same storage is not retention. A parameter has two
		// roots (entry loan and places), so compare the symbol too. A new
		// borrow of a parameter's own storage is, since the caller's root would
		// then borrow itself.
		same := loan.root == target || (root.symbol != INVALID_SYMBOL && root.symbol == destination.symbol)
		if same && (root.kind != .Param || loan.content) {
			continue
		}
		if root.kind == .Param {
			if parameter_allows_retention(state, root, into) {
				continue
			}
			errorf(
				state.k.c, event.span, "L0646",
				"this %s %s %s, which is not written `@(escape=%s)`, so it cannot reach %s%s",
				loan.what, borrows, root_phrase(root), escape_level_name(retain_kind_level(into)), retain_destination(event, destination), stored,
			)
		} else {
			if root_satisfies_retention(root.kind, into) || root_names_source(graph, root) {
				continue
			}
			errorf(
				state.k.c, event.span, "L0647",
				"this %s %s %s, which does not outlive %s%s: %s",
				loan.what, borrows, root_phrase(root), retain_destination(event, destination), stored, retain_kind_text(into),
			)
		}
		state.diagnostic_precision |= destination_loss
		add_root_notes(state, root, loan)
		// design.md "@(cross_thread)": this is why one cannot reach a thread.
		if root.kind == .Thread_Local && into == .Process {
			add_notef(state.k.c, root.span, "each thread has its own `thread_local` storage, which ends with that thread")
		}
		return true
	}
	return false
}

// The destination place, or the callee parameter that may keep the borrow.
@(private = "file")
retain_destination :: proc(event: Prov_Event, destination: Prov_Root) -> string {
	if destination.symbol == INVALID_SYMBOL || destination.name == "" {
		return event.verb
	}
	return fmt.tprintf("`%s`", destination.name)
}

@(private = "file")
parameter_allows_retention :: proc(state: ^Prov_Solve, root: Prov_Root, into: Retain_Kind) -> bool {
	sym := symbol_of(state.k.c, root.symbol)
	if sym == nil {
		return false
	}
	return sym.escape >= retain_kind_level(into)
}

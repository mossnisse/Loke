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

// A new path, one step below `path`.
path_extend :: proc(path: []Proj_Step, step: Proj_Step, allocator: mem.Allocator) -> []Proj_Step {
	out := make([]Proj_Step, len(path) + 1, allocator)
	copy(out, path)
	out[len(path)] = step
	return out
}

// `path` below `prefix`, which is one of the two when the other is empty.
path_concat :: proc(prefix, path: []Proj_Step, allocator: mem.Allocator) -> []Proj_Step {
	if len(prefix) == 0 {
		return path
	}
	if len(path) == 0 {
		return prefix
	}
	out := make([]Proj_Step, len(prefix) + len(path), allocator)
	copy(out, prefix)
	copy(out[len(prefix):], path)
	return out
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
	// A loan of one of the carriers in the storage a chain of loads leads to, each
	// load between reading one carrier (`prov_caller_slots`): its position in that
	// storage's `last_load_shape`, plus one; zero when they share a loan, or the
	// loan stands for every depth below it.
	last: int,
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
	// Holds an element a `&mut` traversal's binding names, loaded through a mutable
	// view; what it reborrows is `Prov_Reborrow.names_element`.
	names_element:  bool,
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
	// A `&mut` traversal's read of the elements it walks. Its binding is the element,
	// not a copy of it, so a reordering through the binding moves the carrier stored in
	// the element, and what it moves holds nothing of this read (`run_links_held_event`).
	names_element: bool,
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
	// Each row `reach` holds, by handle, and which rows have changed since
	// (`src/borrow_tables.odin`).
	reach_rows:    Interned_Rows,
	reach_handles: []u32,
	reach_written: [dynamic]int,
	// A loan ended on every path to here. Checks skip only these, so an
	// invalidation that reaches its own loop head still meets the loan it ends.
	ended:   []bool,
	// The slots the last `Rearrange` reached.
	rearranged: [dynamic]int,
	// Per slot, which links its value may have come through, as a handle of
	// `link_rows` (`solve_links_held`).
	links_held: []u32,
	// Per slot, which carriers its value was loaded below (`Loaded_Below`).
	below: Loaded_Below,
	// Each distinct row, with one bit per reborrow.
	link_rows:      Interned_Rows,
	link_row_bytes: int,
	// Scratch: a value being defined, and a row being changed.
	link_row_value: []u8,
	link_row_edit:  []u8,
	// The reborrows into each slot, and those each `store_id` makes.
	links_into:     [][dynamic]int,
	// A bit per reborrow that is `names_element`.
	links_naming_element: []u8,
	links_of_store: [][dynamic]int,
	// Whether an interned link row holds a reborrow of a slot with many
	// (`row_holds_reborrow_of`), as of `row_holds_indexed` reborrows.
	row_holds:         map[u64]bool,
	row_holds_indexed: int,
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
@(private)
place_bit :: proc(state: ^Prov_Solve, place_loan: int) -> int {
	return 2 * state.loans + place_loan
}

// The later use keeping a place loan lent: of its snapshot, or else of a live
// slot carrying its bit. False when nothing live carries it. `carrying` is what
// `live_place_bits` gathered for this event.
@(private)
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
@(private)
Live_Place_Bits :: struct {
	slots: []int,
	row:   []u8,
}

@(private)
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

@(private)
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
@(private)
solve_enter_block :: proc(state: ^Prov_Solve, block: ^Flow_Block) -> bool {
	enter_block_tables(state, block.reach_entry, block.precision_entry, block.ended_entry)
	return block.prov_visited
}

@(private = "file")
enter_block_tables :: proc(state: ^Prov_Solve, reach: [][]u32, precision: [][]Precision_Loss, ended: [][]bool) {
	reach_load(state, reach)
	block_table_put(precision, state.precision)
	block_table_put(ended, state.ended)
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
		// design.md "Variadic parameters": a `..^T` pack's values are lent for the
		// call, so the result may hold only what they hold.
		if param_symbol_lends(k.c, bound) && index < len(summary.params) && (summary.params[index] || summary.param_loads[index] & 1 != 0) {
			errorf(
				k.c, bound.span, "L0644",
				"`%s` lends its values only for the call, but the result of `%s` may borrow one",
				identifier_text(k.c, bound.name), identifier_text(k.c, sym.name),
			)
			add_precision_notes(k.c, bound.span, summary.precision)
			continue
		}
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
@(private)
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
	if returns {
		changed = collect_escape_provenance(&state, literal.symbol, summary) || changed
	}
	// Last, as whether a copy outlasts the body takes solving the links, which settles
	// the graph's loads and stores for the checks.
	if moves_carriers {
		changed = collect_carrier_moves(&state, literal.symbol) || changed
	}
	return changed
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
		symbol   = instance.template,
		bindings = instance.bindings,
		span     = instance.selected_at,
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
		if !solve_enter_block(&state, block) {
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

@(private)
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
	for block in graph.blocks {
		block.prov_visited = false
	}
	state.reach = make([]u8, max(state.slots * state.row_bytes, 1), graph.alloc)
	state.reach_rows = interned_rows_make(state.row_bytes, graph.alloc)
	state.reach_handles = make([]u32, state.slots, graph.alloc)
	state.reach_written = make([dynamic]int, 0, 16, graph.alloc)
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
		if !solve_enter_block(state, block) {
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
	queue := block_queue_from_entry(graph)
	for id in block_queue_pop(&queue) {
		block := graph.blocks[id]
		first := join_block_entry(state, block, id)
		reach_settle(state)
		block_table_take(&block.reach_entry, state.reach_handles, first == nil ? nil : first.reach_exit, graph.alloc)
		block_table_take(&block.precision_entry, state.precision, first == nil ? nil : first.precision_exit, graph.alloc)
		block_table_take(&block.ended_entry, state.ended, first == nil ? nil : first.ended_exit, graph.alloc)
		for event in block.prov {
			run_prov_event(state, event, state.reach, state.ended)
		}
		reach_settle(state)
		if block.prov_visited &&
		   block_table_equal(block.precision_exit, state.precision) &&
		   block_table_equal(block.reach_exit, state.reach_handles) &&
		   block_table_equal(block.ended_exit, state.ended) {
			continue
		}
		block_table_take(&block.reach_exit, state.reach_handles, block.reach_entry, graph.alloc)
		block_table_take(&block.precision_exit, state.precision, block.precision_entry, graph.alloc)
		block_table_take(&block.ended_exit, state.ended, block.ended_entry, graph.alloc)
		block.prov_visited = true
		block_queue_wake(&queue, block.succs[:])
	}
}

// Makes the flat tables what reaches `block`, and returns the first predecessor they were
// taken from. A predecessor not visited yet stays out of the meet.
@(private = "file")
join_block_entry :: proc(state: ^Prov_Solve, block: ^Flow_Block, id: int) -> ^Flow_Block {
	graph := state.graph
	if id == 0 {
		enter_block_tables(state, nil, nil, nil)
		// A borrowed parameter arrives already holding the caller's root.
		for entry in graph.entry_defs {
			bit_mark(reach_row_written(state, state.reach, entry.slot), int(entry.loan))
			state.precision[entry.slot] |= graph.prov_slots[entry.slot].precision
		}
		return nil
	}
	first: ^Flow_Block
	for predecessor in block.preds {
		source := graph.blocks[predecessor]
		if !source.prov_visited {
			continue
		}
		if first == nil {
			first = source
			enter_block_tables(state, source.reach_exit, source.precision_exit, source.ended_exit)
			continue
		}
		reach_join(state, source.reach_exit)
		for page, at in source.precision_exit {
			for loss, index in page { state.precision[at * BLOCK_TABLE_PAGE + index] |= loss }
		}
		for page, at in source.ended_exit {
			for value, index in page { state.ended[at * BLOCK_TABLE_PAGE + index] &&= value }
		}
	}
	if first == nil {
		enter_block_tables(state, nil, nil, nil)
	}
	return first
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
	state.link_rows = interned_rows_make(state.link_row_bytes, graph.alloc)
	index_links(state)
	loaded_below_make(state)
	visited := make([]bool, len(graph.blocks), graph.alloc)
	queue := block_queue_from_entry(graph)
	for id in block_queue_pop(&queue) {
		block := graph.blocks[id]
		mem.zero_slice(state.links_held)
		first, first_below: [][]u32
		joined := false
		for predecessor in block.preds {
			if visited[int(predecessor)] {
				from := graph.blocks[predecessor]
				join_links_held(state, from.links_exit)
				join_loaded_below(state, from.below_exit, !joined)
				if !joined { first, first_below = from.links_exit, from.below_exit }
				joined = true
			}
		}
		if !joined {
			mem.zero_slice(state.below.held)
		}
		block_table_take(&block.links_entry, state.links_held, first, graph.alloc)
		block_table_take(&block.below_entry, state.below.held, first_below, graph.alloc)
		for event in block.prov {
			run_links_held_event(state, event, state.links_held)
		}
		if visited[id] && block_table_equal(block.links_exit, state.links_held) && block_table_equal(block.below_exit, state.below.held) {
			continue
		}
		visited[id] = true
		block_table_take(&block.links_exit, state.links_held, block.links_entry, graph.alloc)
		block_table_take(&block.below_exit, state.below.held, block.below_entry, graph.alloc)
		block_queue_wake(&queue, block.succs[:])
	}
}

// The reborrows into, through and made by each slot or store, and which of them a
// definition of the derived slot names.
@(private = "file")
index_links :: proc(state: ^Prov_Solve) {
	graph := state.graph
	context.allocator = graph.alloc
	state.links_into = make([][dynamic]int, state.slots)
	state.link_is_named = make([]bool, len(graph.reborrows))
	state.links_naming_element = make([]u8, state.link_row_bytes, graph.alloc)
	stores := 0
	for link, index in graph.reborrows {
		if link.names_element {
			bit_mark(state.links_naming_element, index)
		}
		append(&state.links_into[link.derived], index)
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
join_links_held :: proc(state: ^Prov_Solve, from: [][]u32) {
	for page, at in from {
		for row, index in page {
			slot := at * BLOCK_TABLE_PAGE + index
			held := state.links_held[slot]
			if row == held || row == 0 {
				continue
			}
			if held == 0 {
				state.links_held[slot] = row
				continue
			}
			copy(state.link_row_edit, state.link_rows.rows[held])
			bytes_or(state.link_row_edit, state.link_rows.rows[row])
			state.links_held[slot] = intern_row(&state.link_rows, state.link_row_edit)
		}
	}
}

// A new value in `slot` ends what was taken from its old one, unless it came from there,
// as then the old value goes on being held, as `cur = copy_of_cur` does.
@(private)
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
	// A row holding none of them stays as it is, so this asks each row only about these
	// links: a row may be as wide as the body has reborrows.
	edit := state.link_row_edit
	for &row in held {
		if row == 0 || !row_holds_reborrow_of(state, row, slot, links) {
			continue
		}
		copy(edit, state.link_rows.rows[row])
		for index in links {
			bit_clear(edit, index)
		}
		row = intern_row(&state.link_rows, edit)
	}
}

// Past this many reborrows of one slot, whether a row holds one is kept.
@(private = "file")
ROW_HOLDS_KEPT_PAST :: 8

// Whether interned link row `row` holds any of `links`, the reborrows of `slot`. A row
// never changes once interned, so for a slot with many reborrows the answer is kept: a
// carrier given a new value after each of thousands of copies asked every row about
// every copy again, and took cubic time.
@(private = "file")
row_holds_reborrow_of :: proc(state: ^Prov_Solve, row: u32, slot: int, links: []int) -> bool {
	kept := state.link_rows.rows[row]
	if len(links) <= ROW_HOLDS_KEPT_PAST {
		for index in links {
			if bit_get(kept, index) {
				return true
			}
		}
		return false
	}
	if state.row_holds == nil || state.row_holds_indexed != state.reborrows_indexed {
		state.row_holds = make(map[u64]bool, 64, state.graph.alloc)
		state.row_holds_indexed = state.reborrows_indexed
	}
	key := u64(row) << 32 | u64(slot)
	if holds, found := state.row_holds[key]; found {
		return holds
	}
	holds := false
	for index in links {
		if bit_get(kept, index) {
			holds = true
			break
		}
	}
	state.row_holds[key] = holds
	return holds
}

@(private)
run_links_held_event :: proc(state: ^Prov_Solve, event: Prov_Event, held: []u32) {
	graph := state.graph
	if state.link_row_bytes == 0 {
		return
	}
	run_loaded_below_event(state, event)
	#partial switch event.kind {
	case .Def, .Load:
		slot := event.slot
		value := state.link_row_value
		mem.zero_slice(value)
		// A definition joining the slot's own value does not end it.
		joins := event.kind == .Def && slice.contains(event.sources, slot)
		if joins {
			bytes_or(value, state.link_rows.rows[held[slot]])
		}
		// What was read below an old value that is no copy is reached no more.
		keeps_nothing := event.replaces_read && !holds_a_copy(state, held[slot])
		for index in state.links_into[slot] {
			link := graph.reborrows[index]
			if keeps_nothing || link.from_store > 0 || state.link_is_named[index] && !slice.contains(event.sources, link.source) {
				continue
			}
			from := state.link_rows.rows[held[link.source]]
			if link.moved {
				for byte, at in from {
					value[at] |= byte &~ state.links_naming_element[at]
				}
			} else {
				bytes_or(value, from)
			}
			bit_mark(value, index)
		}
		if !joins {
			end_links_of_value(state, held, slot, value)
		}
		held[slot] = intern_row(&state.link_rows, value)
	case .Publish, .Rearrange:
		// A store or a call starts what it links, and a store ends what was taken from a
		// slot it replaces, which holds another carrier now.
		stored := state.link_row_value
		mem.zero_slice(stored)
		for source in event.sources {
			bytes_or(stored, state.link_rows.rows[held[source]])
		}
		links := event.store_id > 0 && event.store_id < len(state.links_of_store)
		if links && event.replaces_read {
			links = !lands_on_nothing_held(state, event.store_id, held)
		}
		for slot in event.replaces {
			held[slot] = 0
		}
		if links {
			// A call's links run both ways through a hub, so this goes until they settle.
			for changed := true; changed; {
				changed = false
				for index in state.links_of_store[event.store_id] {
					link := graph.reborrows[index]
					copy(state.link_row_edit, state.link_rows.rows[held[link.derived]])
					bit_mark(state.link_row_edit, index)
					bytes_or(state.link_row_edit, state.link_rows.rows[held[link.source]])
					row := intern_row(&state.link_rows, state.link_row_edit)
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

// Whether every slot a store lands in holds no copy of another carrier, so a value read
// below the place it replaces is reached no more once it does (`Prov_Event.replaces_read`).
@(private = "file")
lands_on_nothing_held :: proc(state: ^Prov_Solve, store_id: int, held: []u32) -> bool {
	for index in state.links_of_store[store_id] {
		if holds_a_copy(state, held[state.graph.reborrows[index].derived]) {
			return false
		}
	}
	return true
}

// Whether a link row holds a reborrow other than a `&mut` traversal's read of the
// element its binding names, which is that element and no copy of it.
@(private = "file")
holds_a_copy :: proc(state: ^Prov_Solve, row: u32) -> bool {
	for byte, at in state.link_rows.rows[row] {
		if byte &~ state.links_naming_element[at] != 0 {
			return true
		}
	}
	return false
}

@(private)
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
		copy(reach_row_written(state, reach, event.slot), state.merged)
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
				if bit_get(row, index) || bit_get(row, state.loans + index) {
					row = reach_row_written(state, reach, slot)
					bit_clear(row, index)
					bit_clear(row, state.loans + index)
				}
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
			stale := state.loans + index
			if revived {
				if bit_get(row, stale) { bit_clear(reach_row_written(state, reach, slot), stale) }
			} else if bit_get(row, index) && !bit_get(row, stale) {
				bit_mark(reach_row_written(state, reach, slot), stale)
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
@(private)
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
			if event.load_places == nil {
				if !load_through_loan(state, index, event.path, reach, &loss, reads, elements, lent) {
					loss |= state.precision[carrier]
				}
				continue
			}
			for place in event.load_places {
				if !load_through_loan(state, index, place, reach, &loss, reads, elements, lent) {
					loss |= state.precision[carrier]
				}
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
	copy(reach_row_written(state, reach, event.slot), state.merged)
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
@(private)
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
	copy(reach_row_written(state, reach, event.slot), state.merged)
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
@(private)
resolve_content_reads :: proc(state: ^Prov_Solve) {
	content_loans := make([dynamic]int, 0, 2, state.graph.alloc)
	for loan, index in state.graph.loans {
		if len(loan_own_slots(state.graph, loan, state.graph.roots[int(loan.root)])) > 0 {
			append(&content_loans, index)
		}
	}
	if len(content_loans) == 0 && !state.graph.has_content_load && !state.graph.has_replacing_store { return }
	for block in state.graph.blocks {
		if !solve_enter_block(state, block) {
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
@(private)
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
	queue := block_queue_last_first(graph)
	for id in block_queue_pop(&queue) {
		block := graph.blocks[id]
		mem.zero_slice(state.live)
		slice.fill(state.uses, NO_SPAN)
		first: ^Flow_Block
		for successor in block.succs {
			target := graph.blocks[successor]
			if target.live_entry == nil {
				continue
			}
			if first == nil { first = target }
			for page, at in target.live_entry {
				for value, offset in page {
					index := at * BLOCK_TABLE_PAGE + offset
					if value > state.live[index] {
						state.live[index] = value
						state.uses[index] = block_table_at(target.use_entry, index)
					}
				}
			}
		}
		block_table_take(&block.live_exit, state.live, first == nil ? nil : first.live_entry, graph.alloc)
		block_table_take(&block.use_exit, state.uses, first == nil ? nil : first.use_entry, graph.alloc)
		for index := len(block.prov) - 1; index >= 0; index -= 1 {
			run_live_event(block.prov[index], state.live, state.uses)
		}
		if block_table_equal(block.live_entry, state.live) {
			continue
		}
		block_table_take(&block.live_entry, state.live, block.live_exit, graph.alloc)
		block_table_take(&block.use_entry, state.uses, block.use_exit, graph.alloc)
		block_queue_wake(&queue, block.preds[:])
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
			return
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
		copy(reach_row_written(state, reach, index), state.merged)
		state.precision[index] = loss
		return
	}
	bytes_or(reach_row_written(state, reach, index), state.merged)
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
@(private)
Live_Change :: struct {
	slot: int,
	live: Slot_Use,
	use:  Span,
}

// A backward step of liveness. `changes`, when given, gathers what it overwrites.
@(private)
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

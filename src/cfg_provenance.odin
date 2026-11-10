// Provenance event vocabulary and construction for the disposable flow graph.
// cfg.odin owns traversal, control-flow topology, and lifecycle events;
// borrow.odin solves the root and region facts recorded here.
package lokec

import "core:fmt"
import "core:mem"
import "core:slice"

// The state only the provenance modes build.
Prov_State :: struct {
	input: ^Prov_Input,
	// The conversions the walk is evaluating the sources of (`prov_repr`).
	converting: [dynamic]Prov_Converting,
	roots:          [dynamic]Prov_Root,
	loans:          [dynamic]Prov_Loan,
	prov_slots:     [dynamic]Prov_Slot,
	reborrows:      [dynamic]Prov_Reborrow,
	// The loans of places reached through carriers (`prov_place_loan`).
	place_loans:    [dynamic]Prov_Place_Loan,
	entry_defs:     [dynamic]Prov_Entry_Def,
	root_by_symbol: map[Symbol_Id]Root_Id,
	root_by_storage: map[Storage_Id]Root_Id,
	captured_values: map[Value_Id][]int,
	slot_by_symbol: map[Symbol_Id]int,
	// What a non-owning binding (a loop element, a switch payload over a place)
	// views: every access and borrow through it also uses the source.
	view_loans:     map[Symbol_Id][]int,
	// The stored carrier a switch payload binding over a place names, which a
	// use of the binding uses (`prov_note_view_use`).
	view_uses:      map[Symbol_Id]Prov_View_Use,
	// The view bindings whose own loans end with their step (design.md
	// "By-reference iteration"), so `&binding` borrows the binding too.
	step_views:     map[Symbol_Id]bool,
	// The carrier slots of a lent loop element, which is the stored carrier
	// rather than a copy: a copy taken from one reborrows these instead.
	lent_aliases:   map[int][]int,
	// The `&mut` loop bindings, and where a store through each lands
	// (`prov_note_traversal`).
	traversals:     map[Symbol_Id]Prov_Traversal,
	// The slots standing for what the caller storage each parameter loan names
	// holds (`prov_caller_slots`).
	caller_slots:   map[Loan_Id][dynamic]int,
	// Per view parameter's own loan and constant index, the caller slots
	// standing for that one element (`prov_view_element`).
	view_elements:  map[Prov_View_Element][]int,
	// Per named slot, how each of its definitions relates its view to a fresh
	// borrow, and the reslice the definition being emitted makes, if any
	// (`prov_note_view`).
	view_defs:      map[int][dynamic]Prov_View_Def,
	// Once the solve starts: what `view_start_of` has answered, and the symbols a
	// loan borrows.
	view_answers:   map[Prov_View_Query]Prov_View_Start,
	view_borrowed:  map[Symbol_Id]bool,
	view_reslice:   Prov_View_Def,
	// Per call with a `self: ^` receiver, what the receiver's place holds, which
	// the call's actual joins with its borrow of that place: a load through the
	// receiver reads these at its path rather than through them.
	receiver_content: map[^Expr_Call][]int,
	// Per `parallel` block's hidden scope, the slot holding what its tasks
	// lend (`prov_spawn`), and each task's reborrows of mutable carriers, one
	// slot per spawn site, all registered as the block is entered
	// (`prov_enter_parallel`); `spawning` is the call whose lending is
	// collected into `spawn_held`.
	task_slots:     map[Symbol_Id]int,
	task_holds:     map[Symbol_Id][]int,
	// design.md "Parallel blocks": a pooled block's tasks, by its hidden scope,
	// which its join may run on the joining thread.
	pool_tasks:     map[Symbol_Id][]Pool_Task,
	// Each spawn site's slot in `task_holds`.
	spawn_holds:    map[^Stmt_Spawn]int,
	spawning:       ^Expr_Call,
	spawn_held:     []int,
	// Loans of the spawned call's temporaries, which its frame holds, so the
	// task's use of them ends with the task (design.md "Spawn statements").
	spawn_owned:    []int,
	// The call being spawned belongs to a pooled block.
	spawning_pooled: bool,
	// design.md "Globals while tasks run": how many `parallel` blocks enclose
	// the statement being walked, and each block's hidden scope by its index.
	parallel_depth:   int,
	parallel_scopes:  [dynamic]Symbol_Id,
	has_window_event: bool,
	// The effects being recorded are a spawned call's, which run on its task;
	// `effect_name` describes the call whose writes are being recorded.
	task_effects:     bool,
	effect_name:      string,
	// design.md "Allocators and tasks": the regions the spawned call's task
	// reserves, collected while its effects are, and each spawn in the order
	// walked: its block's window bit, its reservation, and where it is.
	task_reserve:     Region_Set,
	// While a body's events materialize: the task site its spawned call's
	// effects reserve for, and the graph receiving the summary outputs.
	task_index:       int,
	materialized:     ^Flow_Graph,
	task_sites:       [dynamic]Task_Site,
	// Per named slot, what each of its definitions may point at, so a borrow
	// through it takes the places of those reaching it (`prov_reaching_offsets`).
	offset_reach:   Prov_Reach,
	// A local's own slots (`root_own_slots`): its carrier's one, or one per
	// `carrier_shape` path when it holds carriers.
	own_slots: map[Symbol_Id][]int,
	// Call results settled for this fact-building pass.
	call_results:   map[^Expr_Call]Prov_Call_Result,
	// The call each user operator stands for, keyed by its node.
	operator_calls: map[rawptr]^Expr_Call,
	// Summary mode: the direct callees whose result summaries this body reads.
	summary_callees: [dynamic]Symbol_Id,
	// Calls through a procedure type with no result contract, for notes.
	plain_calls: [dynamic]^Expr_Call,
	// design.md "Global write effects": this body's own writes and reads of
	// globals, and its calls while the effects are still settling.
	effect_writes: [dynamic]Symbol_Id,
	effect_reads:  [dynamic]Symbol_Id,
	effect_calls:  [dynamic]Effect_Call,
	// The `hook(copy)`s this body's copies may run, which only read.
	effect_copy_hooks: [dynamic]Symbol_Id,
	// Procedures this body uses as values, and the callee being walked, which is
	// a call rather than a use.
	effect_values: [dynamic]Symbol_Id,
	// What each variable holding a procedure may be given.
	effect_stores: [dynamic]Effect_Store,
	// `thread.spawn` calls, kept on the graph so a repeated pass notes each once.
	thread_spawns: [dynamic]Thread_Spawn,
	// The allocator use this body's own operations make, while the thread
	// summaries collect (`prov_note_allocator_use`).
	allocator_use: Region_Set,
	// A direct call's callee, which `prov_note_proc_value` does not count as
	// a procedure used as a value.
	callee_expr:   Expr,
	// The facts the fixed point carries between rounds.
	using facts: Prov_Facts,
	// Borrowed payload bindings name storage in their switch subject.
	region_aliases:  map[Symbol_Id][]Prov_Region_Alias,
	// Set while a store into a writable parameter reads its regions.
	self_reads:      ^Prov_Self_Reads,
	// The body's parameters, in the positions a `Region_Set` numbers.
	param_symbols:   []Symbol_Id,
	// One bit per local `mem.Arena`/`mem.Scratch`.
	provider_bits:    map[Symbol_Id]u64,
	provider_symbols: [dynamic]Symbol_Id,
	// Per local, one token per provider position its type fixes, and the tokens
	// of providers moved in, keyed by the position each was moved into.
	provider_paths: map[Symbol_Id][]Provider_Path,
	provider_moved: map[Symbol_Id][]Provider_Path,
	// A temporary provider, as in `mem.Arena.init().allocator()`: the token of
	// each handle taken of one, and the ones the current statement ends.
	temp_provider_bits: map[^Expr_Call]u64,
	// The value a `return` hands back while its deferred statements are walked.
	returning: ^Prov_Returning,
	temp_providers:     [dynamic]Temp_Provider,
	has_region_event: bool,
	// The uses that are a local's `drop` at scope exit, for the note naming them.
	scope_drops:      map[Span]bool,
	has_content_load: bool,
	// A store through carriers that may replace what one place held
	// (`Prov_Event.one_place`), which the solve settles once reaching has.
	has_replacing_store: bool,
	// A `Publish` the solve links to where it lands (`link_landed_stores`).
	has_linked_store: bool,
	// The parameter places the walk's assignments wrote, by block.
	overwrites: Prov_Overwrites,
}

// design.md "Allocator regions and region provenance": the flow-insensitive
// facts a body's fixed point carries from one round to the next. They only
// grow, and their weight (`prov_fact_weight`) tells when a round read every
// one at its final value. A round rebuilds everything else it holds from the
// frozen input and the construction graph's topology (`prov_fact_graph`).
//
// Range over a `[dynamic]` row as `m[key][:]`: `for x in m[key]` ranges
// through the slot's address, which is nil for a missing key.
Prov_Facts :: struct {
	// Each local's allocator regions, and the path-indexed regions of storage.
	region_of:        map[Symbol_Id]Region_Set,
	region_content:   map[Storage_Id][dynamic]Prov_Region_Content,
	// The parent allocator a provider depends on until it is dropped.
	provider_parents: map[Symbol_Id]Region_Set,
	// Locals a mutable loan was ever taken of: only these can be reached through
	// a pointer or slice.
	lent_locals:      map[Symbol_Id]bool,
	// What each local's carriers were ever set to reach, at the path in the local
	// holding them: a writable parameter's storage, so a write through it is a
	// write the caller learns of, or a variable's place `&mut place` lent, so a
	// reset sees an owner written there and static storage rejects one.
	written_aliases:  map[Storage_Id][dynamic]Written_Alias,
	// The parameters a write put their own region back into (`prov_note_restored`).
	restored:         map[Symbol_Id]bool,
	// What stores left in storage only through a target an analysis budget merged
	// in (`prov_note_merged_region`).
	merged_regions:   map[Storage_Id]Prov_Merged_Region,
}

Prov_Merged_Region :: struct {
	region:    Region_Set,
	precision: Precision_Loss,
}

@(private)
new_prov_state :: proc(allocator: mem.Allocator, input: ^Prov_Input) -> ^Prov_State {
	state := new(Prov_State, allocator)
	state.input = input
	state.converting = make([dynamic]Prov_Converting, allocator)
	state.overwrites = new_prov_overwrites(allocator)
	state.roots = make([dynamic]Prov_Root, allocator)
	state.loans = make([dynamic]Prov_Loan, allocator)
	state.prov_slots = make([dynamic]Prov_Slot, allocator)
	state.place_loans = make([dynamic]Prov_Place_Loan, allocator)
	state.entry_defs = make([dynamic]Prov_Entry_Def, allocator)
	state.root_by_symbol = make(map[Symbol_Id]Root_Id, allocator)
	state.root_by_storage = make(map[Storage_Id]Root_Id, allocator)
	state.captured_values = make(map[Value_Id][]int, allocator)
	state.slot_by_symbol = make(map[Symbol_Id]int, allocator)
	state.view_loans = make(map[Symbol_Id][]int, allocator)
	state.view_uses = make(map[Symbol_Id]Prov_View_Use, allocator)
	state.step_views = make(map[Symbol_Id]bool, allocator)
	state.lent_aliases = make(map[int][]int, allocator)
	state.traversals = make(map[Symbol_Id]Prov_Traversal, allocator)
	state.caller_slots = make(map[Loan_Id][dynamic]int, allocator)
	state.view_elements = make(map[Prov_View_Element][]int, allocator)
	state.view_defs = make(map[int][dynamic]Prov_View_Def, allocator)
	state.receiver_content = make(map[^Expr_Call][]int, allocator)
	state.offset_reach = Prov_Reach {
		places  = make(map[int][dynamic]Prov_Offset, allocator),
		defined = make(map[Prov_Reach_Key]u128, allocator),
		exits   = make(map[Prov_Reach_Key]Prov_Reach_Exit, allocator),
		frames  = make([dynamic]Prov_Reach_Frame, allocator),
		blocks  = make([dynamic]Prov_Reach_Block, allocator),
		scc     = make([dynamic]Block_Id, allocator),
		stale   = make([dynamic]Block_Id, allocator),
	}
	state.own_slots = make(map[Symbol_Id][]int, allocator)
	state.call_results = make(map[^Expr_Call]Prov_Call_Result, allocator)
	state.operator_calls = make(map[rawptr]^Expr_Call, allocator)
	state.summary_callees = make([dynamic]Symbol_Id, allocator)
	state.plain_calls = make([dynamic]^Expr_Call, allocator)
	state.effect_writes = make([dynamic]Symbol_Id, allocator)
	state.effect_reads = make([dynamic]Symbol_Id, allocator)
	state.effect_copy_hooks = make([dynamic]Symbol_Id, allocator)
	state.effect_calls = make([dynamic]Effect_Call, allocator)
	state.effect_values = make([dynamic]Symbol_Id, allocator)
	state.effect_stores = make([dynamic]Effect_Store, allocator)
	state.thread_spawns = make([dynamic]Thread_Spawn, allocator)
	state.region_of = make(map[Symbol_Id]Region_Set, allocator)
	state.region_content = make(map[Storage_Id][dynamic]Prov_Region_Content, allocator)
	state.region_aliases = make(map[Symbol_Id][]Prov_Region_Alias, allocator)
	state.provider_parents = make(map[Symbol_Id]Region_Set, allocator)
	state.provider_bits = make(map[Symbol_Id]u64, allocator)
	state.reborrows = make([dynamic]Prov_Reborrow, allocator)
	state.provider_symbols = make([dynamic]Symbol_Id, allocator)
	state.provider_paths = make(map[Symbol_Id][]Provider_Path, allocator)
	state.provider_moved = make(map[Symbol_Id][]Provider_Path, allocator)
	state.temp_provider_bits = make(map[^Expr_Call]u64, allocator)
	state.temp_providers = make([dynamic]Temp_Provider, allocator)
	state.lent_locals = make(map[Symbol_Id]bool, allocator)
	state.restored = make(map[Symbol_Id]bool, allocator)
	state.written_aliases = make(map[Storage_Id][dynamic]Written_Alias, allocator)
	state.merged_regions = make(map[Storage_Id]Prov_Merged_Region, allocator)
	state.scope_drops = make(map[Span]bool, allocator)
	return state
}

// ------------------------------------------------------ provenance events --

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
	// A call may have stored what `into` lead to among each other, as `rearranged`
	// says (`Carrier_Move`).
	Rearrange,
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

// What a `Load` reads, from `path` below what its carriers name.
Prov_Load_Kind :: enum u8 {
	// The carriers stored at `path`.
	Place,
	// Also reads through what was read, at any depth.
	Deep,
	// A deep load of all a call's arguments reach: a live reborrow of what it reads
	// is also one it reads itself (`prov_use_reached_at_once`).
	At_Once,
	// A deep load following only the carriers a write may go through, keeping
	// only what mutable ones name (`prov_load_writable`).
	Writable,
}

// One element of a view parameter, `s[k]` with a constant `k`: the parameter's
// own loan and the caller slots standing for that element (`prov_view_element`).
Prov_Element_Slots :: struct {
	loan:  Loan_Id,
	slots: []int,
}

// What a call leaves of a `stored` argument, each carrier of which
// `prov_link_retained` links to every slot it may land in: those of what the carriers
// name, and `places`, of a destination the argument names itself. `mutable` when the
// parameter it is passed as can carry a mutable borrow.
Prov_Store_Retained :: struct {
	mutable: bool,
	places:  []int,
}

// Where in what its carriers name a `Publish` lands, when the walk knows more
// than that they name it (`publish_into_loan`). `Prov_Element_Slots` applies
// when that loan is the one its carriers name.
Prov_Store_Target :: union {
	Prov_Element_Slots,
	Prov_Store_Retained,
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
	load:          Prov_Load_Kind,
	// `Live`: the carrier is only read, so a live read-only reborrow of it does
	// not conflict (design.md "Weakening and reborrows").
	reads_only:    bool,
	// `Live`: what the storage a call's arguments lend holds, which stays live for
	// the call, though it may read one element and is no use of the others
	// (`with_held_content`, `Slot_Use`). Without `hands_on`, what a measured receiver
	// holds, and so what that storage holds in turn.
	keeps_live:    []int,
	// `Live`: a call's use of what it borrows, which may read whatever they reach.
	hands_on:      bool,
	// Checks nothing when a diagnostic was reported inside its span: it uses again
	// what an expression there used, and one report of that is enough.
	repeats_inner: bool,
	// `Def`: one more than the index of the place loan the slot is the
	// snapshot of, which its value then carries (`Prov_Place_Loan`), or 0.
	place_loan:    int,
	// `Publish`: see `Prov_Store_Target`.
	store:         Prov_Store_Target,
	// `Publish`: a store through carriers pointing at one place, `path` below
	// their pointee, which replaces what that place held where they name one
	// storage (`publish_into_loan`). `replaces` are the slots it replaces once
	// reaching has settled, whose earlier values it ends as a `Def` does.
	one_place:     bool,
	replaces:      []int,
	// `Publish`: what the walk took its carriers to point at, which `path` starts with:
	// what the definitions it had met said, so one over a loop's back edge may say more
	// (`publish_place_settled`).
	place_path:    []Proj_Step,
	// `Publish`: each carrier it copies is linked as a reborrow to every slot it
	// may land in: one carrier, which `prov_reborrow` links, or a value holding
	// carriers, each on a path of one type, to the slots of that type where it
	// lands (`prov_link_landed`).
	// Any other store through a parameter's loan, and one of such a value landing
	// in another slot, also joins into the parameter itself (`publish_into_loan`).
	linked:        bool,
	// `Publish`: the solve links each carrier it copies to the slots it lands in
	// (`prov_link_landed`), from this store on, which `store_id` tells its links from
	// another's (`from_store`).
	links_copies:  bool,
	store_id:      int,
	// `Publish`, `Def`: the value stored was read below the place it replaces, as
	// `cur^.next = cur^.next^.next`. Where that place's old value holds no reborrow, no
	// copy of it outlives the statement, so what was read below it is reached no more
	// and its copies are linked nowhere (`run_links_held_event`).
	replaces_read: bool,
	// `Publish`: the type stored, or INVALID_TYPE when not known
	// (`Carrier_Move`).
	carried:       Type_Id,
	// `Publish`: part of an assignment that only reorders its targets' values
	// (`prov_assign_permutes`).
	permutes:      bool,
	// `Rearrange`: see `Prov_Kind`.
	rearranged:    Carrier_Move,
	// `Publish`: `into` hold the source's own loans, as a traversal's do, which what
	// is stored holds only for having been read through them: the source does not
	// come to borrow itself (`prov_publish_traversal`).
	strips:        bool,
	// `Publish`: of a store through a user's iterator's binding, which says nothing
	// of where it lands, so it lands only in slots that could hold `carried`
	// (`Prov_Traversal.lent`).
	lands_by_type: bool,
	// `Load`: the one element of a view parameter it names, whose caller slots it
	// reads when through that loan, instead of those standing for every element.
	// `Load`: what it reads below the storage its carriers name, where one of them
	// points below the whole of it (`prov_load_places`); nil reads `path`.
	load_places:   [][]Proj_Step,
	load_element:  Prov_Element_Slots,
	// `Load`, `Publish`: its carriers may all point into one element of a view
	// parameter, which the solve settles (`carriers_element`).
	through_element: bool,
	// `Def` of a named slot: one more than the index of its definition in
	// `view_defs` (`prov_note_view`), or 0.
	view_def:      int,
	// `Through`, the `Def` of a place loan's snapshot, and a `Load` out of or a
	// `Publish` into a local view: the constant element of a named view the place
	// is in (`Prov_View_At`), for a `Publish` one of the range the borrow the view
	// holds lends (`prov_local_view_element`).
	element:       Prov_View_At,
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

// A fresh borrow of a root, with its own `.Access` event, -1 when there is none,
// so `ro: []int = xs[0:2]` registers a read, not a write.
Prov_Fresh_Borrow :: struct {
	loan:   Loan_Id,
	access: Prov_Event_At,
}

// A borrow through carriers, which this otherwise empty slot stands for, so a
// read-only destination can settle it as it does a fresh loan's access
// (`prov_reborrow`). `writes` are its `.Through` events up to `writes_end`, none
// for a borrow that writes nothing. `walk_reads` are the events reading the
// carriers it goes through, which that destination makes reads only; the
// subscripts on the way are not among them, as they may write.
Prov_Through_Borrow :: struct {
	writes:     Prov_Event_At,
	writes_end: int,
	walk_reads: []Prov_Event_At,
}

Prov_Slot_Borrow :: union {
	Prov_Fresh_Borrow,
	Prov_Through_Borrow,
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

// What a use of a switch payload binding also uses: the slots of the named
// place holding its payload, or with `load` what is stored at `path` below
// the pointee of the carriers in `slots`.
Prov_View_Use :: struct {
	slots: []int,
	path:  []Proj_Step,
	load:  bool,
}


// ------------------------------------------------- provenance construction --

// Graph construction for the lattices in `src/borrow.odin`: allocates in the
// graph's arena and reads the typed AST without reporting or changing it.
// Conversion walkers record the conversion they walk beneath in
// `graph.converting`; `prov_repr` and `prov_type` read the representation there.
// Leaf queries take values, which carry their own representation.

// The payload under a union's wildcard alternative: unwrapping keeps every borrow
// the wrapper carried.
@(private)
prov_payload_content :: proc(
	graph: ^Flow_Graph, loans: []int, subject_type, payload_type: Type_Id, span: Span,
) -> []int {
	if len(loans) == 0 || payload_type == INVALID_TYPE || payload_type == subject_type {
		return loans
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
	return graph.view_loans[graph.roots[int(root)].symbol]
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
	payload := prov_payload_path(graph, nil, slot)
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

// Where a case's binding is below `base`, where the subject is: the payload, or
// with `slot` one of its fields.
@(private = "file")
prov_payload_path :: proc(graph: ^Flow_Graph, base: []Proj_Step, slot: int) -> []Proj_Step {
	path := prov_extend(graph, base, proj_wild())
	return slot >= 0 ? prov_extend(graph, path, proj_field(slot)) : path
}

// The read-only view of a place subject that a switch's whole-payload bindings
// share. Its cases exclude each other and each runs the view's `Def` afresh, as
// a creation site that runs again does, so one loan and slot stand for them all:
// the solver's tables grow with loans and blocks together, and a loan per case
// is one per block.
@(private)
Prov_Case_View :: struct {
	sources: []int,
	slot:    int,
	loan:    Loan_Id,
}

// A `.name(&mut binding)` case borrows the subject exclusively for the case, as
// `&mut subject` would (design.md "Switch ownership"). A field binding, `slot`
// at or above zero, borrows only its field of the payload where the subject is
// a place with a path, or is reached through carriers.
@(private)
prov_subject_view :: proc(graph: ^Flow_Graph, subject: Expr, mutable: bool, slot: int, shared: ^Prov_Case_View) -> []int {
	if subject == nil {
		return nil
	}
	span := expr_span(subject)
	root, path, ok := prov_place_of(graph, subject)
	if ok && !mutable {
		if slot >= 0 {
			return prov_borrow(graph, root, prov_payload_path(graph, path, slot), false, span, "payload")
		}
		if shared.sources == nil {
			shared.slot, shared.loan = prov_new_borrow_slot(graph, root, path, false, span, "payload")
			shared.sources = prov_join(graph, prov_one(graph, shared.slot), prov_root_view(graph, root))
		}
		prov_emit(graph, Prov_Event{kind = .Def, slot = shared.slot, loan = shared.loan, span = span})
		return shared.sources
	}
	if mutable && slot >= 0 && ok {
		if ident, is_ident := subject.(^Expr_Ident); is_ident {
			if loans, viewed := graph.view_loans[ident.symbol]; viewed && !graph.step_views[ident.symbol] {
				return loans
			}
		}
		path = prov_payload_path(graph, path, slot)
		prov_walk_subscripts(graph, subject)
		access_block, access_index := prov_access(graph, root, path, .Write, span)
		return prov_borrow(graph, root, path, true, span, "payload", access_block, access_index)
	}
	if mutable && slot >= 0 {
		if carriers, below, through := prov_read_through_carrier(graph, subject, reads = false); through {
			below = prov_payload_path(graph, below, slot)
			prov_write_through(graph, carriers, below, span, "mutable borrow", subject)
			return prov_place_loan(graph, carriers, below, true, "payload", subject, borrows = true)
		}
	}
	if mutable {
		return prov_borrow_place(graph, subject, true, span, "payload")
	}
	// A subject reached through a pointer or view, as in `switch (p^)`, is
	// storage that carrier names, so the binding views what `&subject`
	// would borrow. A carrier loaded on the way, as `p^` for `p^^.first`,
	// only holds that storage's loans for the view: it no more suspends
	// what it was loaded out of than `p` does for `p^.first`.
	carriers, below, through := prov_read_through_carrier(graph, subject, reads = false)
	if !through {
		return nil
	}
	for carrier in carriers {
		graph.prov_slots[carrier].viewed = graph.prov_slots[carrier].loaded
	}
	if slot >= 0 {
		below = prov_payload_path(graph, below, slot)
	}
	prov_read_through(graph, carriers, below, span, subject)
	return prov_join(graph, carriers, prov_place_loan(graph, carriers, below, false, "payload", subject))
}

// A loan of `place`, reached through `carriers`, at `path` below their
// pointee (`Prov_Place_Loan`), as a switch over `h^.first` takes while a payload
// binding is in use (design.md "Switch ownership"). The slot returned is the
// snapshot, whose value carries the loan wherever it is copied.
@(private)
prov_place_loan :: proc(
	graph: ^Flow_Graph, carriers: []int, path: []Proj_Step, mutable: bool, what: string, place: Expr, borrows := false,
) -> []int {
	if len(carriers) == 0 || graph.current == NO_BLOCK {
		return nil
	}
	span := expr_span(place)
	offsets, _, merged := prov_value_offset(graph, carriers)
	places := make([]Prov_Offset, len(offsets), graph.alloc)
	for at, index in offsets {
		places[index] = Prov_Offset{prov_concat_path(graph, at.path, path), at.storage}
	}
	element := prov_view_at(graph, place, carriers)
	in_element: Prov_Element_Slots
	if borrows {
		in_element, _ = prov_view_element(graph, place)
	}
	slot := prov_temp_slot(graph)
	append(&graph.place_loans, Prov_Place_Loan {
		slot = slot, paths = prov_offset_paths(graph, places), mutable = mutable, borrows = borrows, what = what, span = span,
		place = span_text(graph.k.c, span), element = element, in_element = in_element,
	})
	graph.prov_slots[slot].element_defs = len(in_element.slots) > 0
	// design.md "Minimum provenance precision": a loan of places merged past
	// the limit, or of places of several storages, may cover a place the
	// carriers never point at, so a rejection it causes names the limit.
	graph.prov_slots[slot].precision |= prov_offset_precision(places, merged)
	prov_emit(graph, Prov_Event {
		kind = .Def, slot = slot, loan = NO_LOAN, sources = carriers, span = span, place_loan = len(graph.place_loans),
		element = element,
	})
	// A borrow points at the place it is of (`Prov_Slot.offsets`).
	if borrows {
		graph.prov_slots[slot].offsets = places
		graph.prov_slots[slot].offsets_merged = merged
	}
	return prov_one(graph, slot)
}

// A write through `carriers` at `path` below their pointee, which a place
// loan of the same storage forbids (`prov_place_loan`). A carrier that is a
// borrow of a place, as `count` for `count := &mut h^.count`, writes below
// that place (`prov_value_offset`). The event's index in the current block,
// -1 without carriers. `place`, when given, is the place accessed, which may be
// one element of a view (`prov_view_at`).
@(private)
prov_write_through :: proc(graph: ^Flow_Graph, carriers: []int, path: []Proj_Step, span: Span, verb: string, place: Expr = nil) -> int {
	return prov_access_through(graph, carriers, path, span, .Write, verb, prov_view_at(graph, place, carriers))
}

// A read through `carriers` at `path` below their pointee, which a mutable
// place loan of the same storage forbids.
@(private)
prov_read_through :: proc(graph: ^Flow_Graph, carriers: []int, path: []Proj_Step, span: Span, place: Expr = nil) {
	prov_access_through(graph, carriers, path, span, .Read, "read", prov_view_at(graph, place, carriers))
}

// Carriers pointing at different places, as a record holding `&mut h^.count`
// and `&mut h^.total` does, are each accessed at their own, and a carrier
// that may point at either, as one chosen between the two, at both. The
// events emitted are contiguous; the index of the first.
@(private = "file")
prov_access_through :: proc(
	graph: ^Flow_Graph, carriers: []int, path: []Proj_Step, span: Span, access: Access_Kind, verb: string, element: Prov_View_At,
) -> int {
	if len(carriers) == 0 || graph.current == NO_BLOCK {
		return -1
	}
	first := len(graph.blocks[graph.current].prov)
	offsets, _, merged := prov_value_offset(graph, carriers)
	if prov_offsets_agree(graph, carriers, offsets) {
		// As for a place loan (`prov_place_loan`): merged places name the limit.
		precision := prov_offset_precision(offsets, merged)
		for at in prov_offset_paths(graph, offsets) {
			prov_emit(graph, Prov_Event {
				kind = .Through, into = carriers, path = prov_concat_path(graph, at, path), span = span, verb = verb, access = access,
				precision = precision, element = element,
			})
		}
		return first
	}
	for carrier in carriers {
		if !prov_slot_is_through(graph, carrier) {
			prov_access_through(graph, prov_one(graph, carrier), path, span, access, verb, element)
		}
	}
	return first
}

// design.md "Places and overlap": the constant element of a named view that
// `place` is in, when `carriers` are that view's own slot, as for `s[1].count`
// (`Prov_View_At`). A view parameter's element is where its index says
// relative to the parameter's own loan; a local view's is worked out by the
// solve from where the view starts. None for any other place, or one reached
// through a copy of the view, whose start is not known.
@(private)
prov_view_at :: proc(graph: ^Flow_Graph, place: Expr, carriers: []int) -> Prov_View_At {
	if place == nil || len(carriers) != 1 {
		return {}
	}
	view, index, found := prov_constant_view_element(graph, place)
	if !found {
		return {}
	}
	slot, named := prov_slot_for_symbol(graph, view)
	if !named || carriers[0] != slot {
		return {}
	}
	if symbol_of(graph.k.c, view).kind != .Parameter {
		return Prov_View_At{slot = slot + 1, index = index}
	}
	if _, own := prov_view_parameter_loan(graph, view); own != NO_LOAN {
		return Prov_View_At{slot = slot + 1, loan = int(own) + 1, index = index}
	}
	return {}
}

// Whether every slot of `carriers` that names storage points at `offsets`.
@(private = "file")
prov_offsets_agree :: proc(graph: ^Flow_Graph, carriers: []int, offsets: []Prov_Offset) -> bool {
	for carrier in carriers {
		if !prov_slot_is_through(graph, carrier) {
			own, _ := prov_carrier_offsets(graph, carrier)
			if !prov_offsets_cover(own, offsets, any_storage = true) || !prov_offsets_cover(offsets, own, any_storage = true) {
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
// below the last carrier were walked already. Returns what
// `prov_read_through_carrier` does.
@(private = "file")
prov_write_through_place :: proc(graph: ^Flow_Graph, place: Expr, span: Span) -> (carriers: []int, below: []Proj_Step, through: bool) {
	carriers, below, through = prov_read_through_carrier(graph, place, store = true)
	if through {
		prov_write_through(graph, carriers, below, span, "write", place)
	}
	return
}

// A case binding keeps its selected payload's fields, including owner/handle
// separation (design.md "Inspecting a union").
@(private)
prov_bind_case_region :: proc(graph: ^Flow_Graph, id: Symbol_Id, subject: Value_Id, variants: []int, slot: int) {
	recorded := prov_effect_active(graph) && prov_effect_symbol_relevant(graph, id)
	if recorded { prov_effect_begin(graph, Prov_Effect_Case{id, subject, slice.clone(variants, graph.alloc), slot}) }
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
		aliases, uncertain := prov_case_region_aliases(graph, id, subject, variants, slot)
		graph.region_aliases[id] = aliases
		if !uncertain { return }
	}
	if underlying_kind(graph.k.c, subject_type) == .Union && len(variants) == 1 {
		path := prov_extend(graph, nil, proj_field(variants[0]))
		if slot >= 0 { path = prov_extend(graph, path, proj_field(slot)) }
		if type_is_carrier(graph.k.c, sym.type) || type_is_allocator(graph.k.c, sym.type) ||
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

// The storage a borrowed case binding names. Unknown storage, including a
// recursive cursor's next node, retains the escape restriction and a snapshot for
// reads. Keep known targets too: uncertainty cannot remove their lifetime
// constraints (design.md "Allocator regions and region provenance"). NO_ROOT is
// always last.
@(private = "file")
prov_case_region_aliases :: proc(
	graph: ^Flow_Graph, id: Symbol_Id, subject: Value_Id, variants: []int, slot: int,
) -> (aliases: []Prov_Region_Alias, uncertain: bool) {
	places := make([dynamic]Prov_Region_Alias, graph.alloc)
	if root, at, ok := prov_value_place_of(graph, subject); ok {
		append(&places, Prov_Region_Alias{root = root, path = at, from = subject})
	} else {
		below := prov_path_below_carrier(graph, subject)
		for target in prov_written_targets(graph, subject, as_place = true) {
			target_root := prov_root_for_storage(graph, target.target)
			if target_root == NO_ROOT { uncertain = true; continue }
			append(&places, Prov_Region_Alias{root = target_root, path = prov_concat_path(graph, target.at, below)})
		}
	}
	out := make([dynamic]Prov_Region_Alias, graph.alloc)
	for place in places {
		if prov_region_alias_reaches(graph, place.root, id) {
			uncertain = true
			continue
		}
		for variant in variants {
			path := prov_extend(graph, place.path, proj_field(variant))
			if slot >= 0 { path = prov_extend(graph, path, proj_field(slot)) }
			append(&out, Prov_Region_Alias{root = place.root, path = path, from = place.from})
		}
	}
	uncertain ||= len(out) == 0
	if uncertain { append(&out, Prov_Region_Alias{root = NO_ROOT}) }
	return out[:], uncertain
}

// Written carrier targets grow across loop passes. A cursor set from its own
// payload can refer back to the binding about to be installed; such storage
// needs the unresolved-carrier fallback, not a recursive region alias.
@(private)
prov_region_alias_reaches :: proc(graph: ^Flow_Graph, root: Root_Id, id: Symbol_Id) -> bool {
	if root == NO_ROOT { return false }
	target := graph.roots[int(root)].symbol
	if target == id { return true }
	for alias in graph.region_aliases[target] {
		if prov_region_alias_reaches(graph, alias.root, id) { return true }
	}
	return false
}

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
	emitted := event
	if event.kind == .Def {
		prov_note_offset(graph, event.slot, event.sources)
		prov_note_element_pointer(graph, event)
		emitted.view_def = prov_note_view(graph, event)
	}
	if event.kind == .Load && event.load != .Writable {
		emitted.load_places = prov_load_places(graph, event.into, event.path)
	}
	append(&graph.blocks[graph.current].prov, emitted)
}

// Records how a definition of a named slot relates its view to a fresh
// borrow (`Prov_View_Def`), so a constant subscript of a view held there
// names one element of the range that borrow lends
// (`prov_local_view_element`): the borrow itself, the reslice
// `prov_note_reslice` announced, or anything else. One more than the
// definition's index among the slot's (`Prov_Event.view_def`), or 0, as for
// an event a fact graph emits into the graph it materializes, whose
// definitions it does not record.
@(private)
prov_note_view :: proc(graph: ^Flow_Graph, event: Prov_Event) -> int {
	reslice := graph.view_reslice
	graph.view_reslice = {}
	if graph.prov_slots[event.slot].symbol == INVALID_SYMBOL || graph.materialized != nil {
		return 0
	}
	fresh := NO_LOAN
	if event.place_loan == 0 && event.loan == NO_LOAN && len(event.sources) == 1 {
		fresh = prov_slot_fresh_loan(graph, event.sources[0])
	}
	reslices := reslice.slot == event.slot + 1
	def := Prov_View_Def{loan = NO_LOAN, unknown = true}
	switch {
	case reslices && reslice.open:
		if fresh != NO_LOAN {
			def = Prov_View_Def{loan = fresh, lo = reslice.lo, open = true}
		}
	case reslices && event.place_loan == 0 && event.loan == NO_LOAN:
		def = reslice
		def.slot = 0
	case event.place_loan == 0 && event.loan != NO_LOAN && len(event.sources) == 0:
		def = Prov_View_Def{loan = event.loan}
	case fresh != NO_LOAN:
		def = Prov_View_Def{loan = fresh}
	}
	if event.slot not_in graph.view_defs {
		graph.view_defs[event.slot] = make([dynamic]Prov_View_Def, 0, 1, graph.alloc)
	}
	append(&graph.view_defs[event.slot], def)
	return len(graph.view_defs[event.slot])
}

// Announces that the next definition of `slot` takes `value`, when that is a
// constant reslice of a local view, as `&mut s[1:]` or `s[0:2]`, or a fresh
// borrow of elements from a constant start to an end that is not constant,
// as `&mut d[:]` of a dynamic array, which is `open` (`prov_note_view`).
@(private = "file")
prov_note_reslice :: proc(graph: ^Flow_Graph, slot: int, value: Expr) {
	graph.view_reslice = {}
	c := graph.k.c
	slice_expr, is_slice := value.(^Expr_Slice)
	if !is_slice || len(slice_expr.bound) > 0 {
		return
	}
	if prov_note_open_borrow(graph, slot, slice_expr) {
		return
	}
	ident, named := slice_expr.operand.(^Expr_Ident)
	if !named {
		return
	}
	sym := symbol_of(c, ident.symbol)
	if sym == nil || sym.kind == .Parameter || underlying_kind(c, sym.type) != .Slice {
		return
	}
	from, found := prov_slot_for_symbol(graph, ident.symbol)
	if !found {
		return
	}
	lo, lo_constant := prov_const_bound(graph, slice_expr.lo, 0)
	hi, hi_constant := prov_const_bound(graph, slice_expr.hi, -1)
	if !lo_constant || !hi_constant || slice_expr.hi != nil && hi < 0 {
		return
	}
	graph.view_reslice = Prov_View_Def{slot = slot + 1, loan = NO_LOAN, from = from + 1, lo = lo, hi = hi}
}

// `prov_note_reslice` for a slice of an array or dynamic array in a local
// place whose range step is a wildcard (`prov_range_step`) though it starts
// at a constant element, as `&mut d[:]` or `&mut a[1:n]`: the borrow it makes
// lends the elements from there on (`Prov_View_Def.open`).
@(private = "file")
prov_note_open_borrow :: proc(graph: ^Flow_Graph, slot: int, slice_expr: ^Expr_Slice) -> bool {
	kind := underlying_kind(graph.k.c, prov_type(graph, slice_expr.operand))
	if kind != .Array && kind != .Dynamic_Array || prov_range_step(graph, slice_expr).kind != .Wild {
		return false
	}
	if _, _, local := prov_place_of(graph, slice_expr.operand); !local {
		return false
	}
	lo, constant := prov_const_bound(graph, slice_expr.lo, 0)
	if !constant || lo < 0 {
		return false
	}
	if slice_expr.hi != nil {
		if _, hi_constant := prov_const_int(graph, slice_expr.hi); hi_constant {
			return false
		}
	}
	graph.view_reslice = Prov_View_Def{slot = slot + 1, loan = NO_LOAN, lo = lo, hi = -1, open = true}
	return true
}

@(private)
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
prov_new_root :: proc(graph: ^Flow_Graph, kind: Root_Kind, span: Span, name: string) -> Root_Id {
	append(&graph.roots, Prov_Root{kind = kind, span = span, name = name, param_index = -1, content = -1})
	return Root_Id(len(graph.roots) - 1)
}

// design.md "Storage roots and borrow carriers": every ordinary variable owns
// its inline storage and is a root for borrows of it. Static-duration storage is
// a root that outlives every body, and an `inout` parameter names the caller's.
@(private)
prov_root_for_symbol :: proc(graph: ^Flow_Graph, id: Symbol_Id) -> Root_Id {
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
@(private)
prov_slot_for_symbol :: proc(graph: ^Flow_Graph, id: Symbol_Id) -> (int, bool) {
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
	slot := prov_add_slot(graph, entry)
	graph.slot_by_symbol[id] = slot
	graph.own_slots[id] = prov_one(graph, slot)
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
prov_composite_content :: proc(graph: ^Flow_Graph, v: ^Expr_Composite, content: []int, literal_type: Type_Id) -> []int {
	// One part per element value, and for a map one more per key (design.md
	// "Values that contain borrows": a map carries its keys' borrows too).
	Part :: struct {
		loans:  []int,
		prefix: []Proj_Step,
		type:   Type_Id,
		known:  bool,
	}
	parts := make([dynamic]Part, 0, 2 * len(v.elements), graph.alloc)
	is_map := underlying_kind(graph.k.c, literal_type) == .Map
	// What earlier elements hold, used again as each later mutable carrier is
	// lent, as `prov_call` does for arguments.
	held := make([dynamic]int, 0, len(v.elements), graph.alloc)
	// A borrow an element takes, which lasts until the literal is built.
	borrows := make([dynamic]int, 0, len(v.elements), graph.alloc)
	last_write := -1
	for element, index in v.elements {
		if prov_expr_may_write(graph.k.c, element.key) || prov_expr_may_write(graph.k.c, element.value) {
			last_write = index
		}
	}
	for element, index in v.elements {
		if is_map {
			loans := walk_flow_expr(graph, element.key)
			prov_hold_owner(graph, element.key)
			// The key is evaluated before its own value, which may write what it
			// read, as may a later element.
			if len(loans) > 0 && (prov_expr_may_write(graph.k.c, element.value) || index < last_write) {
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
		prov_repeated_element_effects(graph, v, literal_type, index, loans)
		// design.md "Weakening and reborrows": a mutable carrier stored in an
		// element, or in a record there, is a reborrow of it, live until the literal
		// is built: `Pair{xs, xs}` would hold two mutable views of one sequence.
		for slot in loans {
			if graph.prov_slots[slot].borrow != nil {
				append(&borrows, slot)
			}
		}
		lent := type_carries_borrow(graph.k.c, element_type).mutable
		if lent {
			prov_use_copied(graph, loans, element_type, expr_span(element.value), true)
			loans = prov_lend_carrier(graph, loans, held[:], expr_span(element.value))
		}
		// design.md "Evaluation order": a later element may write what this one
		// read. A lent carrier is suspended, so it needs no copy.
		if len(loans) > 0 && index < last_write {
			loans = prov_capture(graph, loans, expr_span(element.value), keep_reborrows = lent)
		}
		append(&held, ..loans)
		prefix, known := prov_element_prefix(graph, v, literal_type, index)
		append(&parts, Part{loans, prefix, prov_type(graph, element.value), known})
	}
	// Building the literal uses each borrow and reborrow its elements took, so what
	// they lend stays lent through every later element, not only the lent ones:
	// `Pair{xs, g(xs)}` uses `xs` while the pair's view is live.
	for slot in held {
		if prov_slot_is_reborrow(graph, slot) || prov_slot_is_pending(graph, slot) {
			append(&borrows, slot)
		}
	}
	if len(borrows) > 0 {
		prov_emit(graph, Prov_Event{kind = .Live, sources = borrows[:], span = v.span})
	}
	for slot in content {
		sources := make([dynamic]int, 0, len(parts), graph.alloc)
		for part in parts {
			if part.known {
				append(&sources, ..prov_part_sources(graph, slot, part.prefix, part.loans, part.type))
			} else {
				append(&sources, ..part.loans)
			}
		}
		prov_define_one_content(graph, slot, sources[:], v.span)
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
	case .Array, .Dynamic_Array, .Map:
		return info.element
	case .Struct:
		if field := prov_element_field(v, index); field >= 0 && field < len(info.fields) {
			return symbol_of(c, info.fields[field]).type
		}
	}
	return prov_type(graph, v.elements[index].value)
}

// Whether evaluating `e` may run a program's code, which could write a carrier read
// beside it. A constant and a plain read of a place run nothing, and neither does a
// built-in operation on scalars, whose values copy as plain bits: `xs[x - 1]` and
// `xs[xs.len() - 1]` only read. A read of anything else may run a hook, and a map's
// key a hash.
@(private)
prov_expr_may_write :: proc(c: ^Compiler, e: Expr) -> bool {
	if e == nil || is_const_expr(e) {
		return false
	}
	scalar :: proc(c: ^Compiler, e: Expr) -> bool {
		base := expr_base(e)
		return base != nil && type_is_panic_free_scalar(c, base.type)
	}
	#partial switch v in e {
	case ^Expr_Ident:
		return false
	case ^Expr_Selector:
		return prov_expr_may_write(c, v.operand)
	case ^Expr_Postfix:
		return v.op != .Caret || prov_expr_may_write(c, v.operand)
	case ^Expr_Unary:
		return v.op == .Amp || v.resolution.kind == .User_Operator || !scalar(c, v) || !scalar(c, v.operand) ||
		       prov_expr_may_write(c, v.operand)
	case ^Expr_Binary:
		return v.resolution.kind != .Builtin_Operator || !scalar(c, v) || !scalar(c, v.lhs) || !scalar(c, v.rhs) ||
		       prov_expr_may_write(c, v.lhs) || prov_expr_may_write(c, v.rhs)
	case ^Expr_Cond:
		return !scalar(c, v) || prov_expr_may_write(c, v.cond) || prov_expr_may_write(c, v.then) ||
		       prov_expr_may_write(c, v.otherwise)
	case ^Expr_Index:
		if v.resolution.kind == .User_Operator || len(v.bound) != 0 || !scalar(c, v) ||
		   underlying_kind(c, expr_base(v.operand).type) == .Map {
			return true
		}
		return prov_expr_may_write(c, v.operand) || prov_indices_may_write(c, v.indices)
	case ^Expr_Call:
		// A numeric conversion, as `int(x)`.
		if _, converts := v.operation.(Call_Conversion); converts && len(v.args) == 1 && scalar(c, v) && scalar(c, v.args[0].value) {
			return prov_expr_may_write(c, v.args[0].value)
		}
		// A built-in container's `len()` or `cap()` only reads its header.
		if chosen := symbol_of(c, v.resolution.chosen_overload); chosen != nil && (chosen.synth == .Standard_Len || chosen.synth == .Standard_Cap) && len(v.bound) == 1 {
			return prov_expr_may_write(c, v.bound[0])
		}
	}
	return true
}

// The path one literal element's value fills: a field, an index range, or a
// map entry's value under its key's entry.
@(private)
prov_element_prefix :: proc(graph: ^Flow_Graph, v: ^Expr_Composite, type: Type_Id, index: int) -> ([]Proj_Step, bool) {
	#partial switch underlying_kind(graph.k.c, type) {
	case .Map:
		entry := prov_extend(graph, nil, prov_map_entry_step(graph, type, v.elements[index].key))
		return prov_extend(graph, entry, proj_field(PROJ_MAP_VALUE)), true
	case .Array, .Dynamic_Array:
		return prov_extend(graph, nil, prov_array_element_step(v, index)), true
	}
	field := prov_element_field(v, index)
	if field < 0 {
		return prov_extend(graph, nil, proj_wild()), false
	}
	return prov_extend(graph, nil, proj_field(field)), true
}

// design.md "Fixed arrays": a designated element fills its index range.
@(private = "file")
prov_array_element_step :: proc(v: ^Expr_Composite, index: int) -> Proj_Step {
	lo, hi := composite_element_slots(v, index)
	return proj_range(i64(lo), i64(hi))
}

// The field one element of a record literal fills, as the checker resolved it,
// or -1.
@(private = "file")
prov_element_field :: proc(v: ^Expr_Composite, index: int) -> int {
	return index < len(v.field_indices) ? v.field_indices[index] : -1
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
		prov_define_one_content(graph, slot, prov_part_sources(graph, slot, prefix, loans, payload_type), v.span)
	}
	return content
}

// A value that is not itself a borrow can still hold one. Every place
// `carrier_shape` names gets its own slot, so a field read does not inherit
// what a sibling borrows.
@(private)
prov_content_slots :: proc(graph: ^Flow_Graph, id: Symbol_Id) -> []int {
	if _, bare := graph.slot_by_symbol[id]; bare {
		return nil // a bare carrier already has its own slot
	}
	if existing, found := graph.own_slots[id]; found {
		return existing
	}
	sym := symbol_of(graph.k.c, id)
	if sym == nil || type_is_carrier(graph.k.c, sym.type) {
		return nil
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
		entry := prov_content_entry(id, path, sym.type)
		entry.name = identifier_text(graph.k.c, sym.name)
		entry.span = sym.span
		slots[index] = prov_add_slot(graph, entry)
		if unknown_root != NO_ROOT {
			loan := prov_new_loan(graph, unknown_root, nil, path.mutable, sym.span, carrier_path_noun(graph.k.c, path))
			append(&graph.entry_defs, Prov_Entry_Def{slot = slots[index], loan = loan})
		}
	}
	graph.own_slots[id] = slots
	return slots
}

// The content slots whose shape path overlaps the place's projection.
@(private)
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
		slots[index] = prov_add_slot(graph, prov_content_entry(INVALID_SYMBOL, path, type))
	}
	return slots
}

// A slot for the place `path` names in a value of type `shape`.
@(private = "file")
prov_content_entry :: proc(symbol: Symbol_Id, path: Carrier_Path, shape: Type_Id) -> Prov_Slot {
	entry := empty_prov_slot(symbol)
	entry.path = path.steps
	entry.content_type = path.truncated ? INVALID_TYPE : path.type
	entry.content_shape = shape
	entry.content_truncated = path.truncated
	entry.precision = path.precision
	return entry
}

// Sources describing this shape are selected by path; others reach every path.
// A distinct type has its underlying type's carrier shape, so a conversion
// between them keeps each carrier's own sources.
@(private)
prov_select_content :: proc(graph: ^Flow_Graph, sources: []int, type: Type_Id, path: []Proj_Step) -> []int {
	c := graph.k.c
	selected := make([dynamic]int, 0, len(sources), graph.alloc)
	for source in sources {
		entry := graph.prov_slots[source]
		if type == INVALID_TYPE || entry.content_shape == INVALID_TYPE ||
		   type_underlying(c, entry.content_shape) != type_underlying(c, type) || paths_overlap(entry.path, path) {
			append(&selected, source)
		}
	}
	return selected[:]
}

// What of `loans`, a part of type `type` filling `prefix`, `slot` holds.
@(private = "file")
prov_part_sources :: proc(graph: ^Flow_Graph, slot: int, prefix: []Proj_Step, loans: []int, type: Type_Id) -> []int {
	path := graph.prov_slots[slot].path
	if !paths_overlap(path, prefix) {
		return nil
	}
	return prov_select_content(graph, loans, type, path[min(len(prefix), len(path)):])
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
		taken := len(graph.reborrows)
		prov_define_one_content(graph, slot, selected, span)
		// design.md "Weakening and reborrows": what is only read reborrows
		// read-only, whatever the carrier's capability.
		if reads_only {
			for &reborrow in graph.reborrows[taken:] {
				reborrow.mutable = false
			}
		}
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

@(private)
prov_load_content :: proc(
	graph: ^Flow_Graph, carriers: []int, path: []Proj_Step, type: Type_Id, span: Span, reads_only := false, place: Expr = nil,
) -> []int {
	if len(carriers) == 0 {
		return nil
	}
	prov_reach(graph, carriers, span)
	content := prov_temp_content(graph, type)
	graph.has_content_load ||= len(content) > 0
	// One element of a view parameter is read alone (`prov_view_element`),
	// and so is one of a local view where the solve knows where it starts
	// (`Prov_Event.element`).
	load_element: Prov_Element_Slots
	element: Prov_View_At
	if place != nil && len(content) > 0 {
		load_element, _ = prov_view_element(graph, place)
		if at := prov_view_at(graph, place, carriers); at.loan == 0 {
			element = at
		}
	}
	through_element := len(load_element.slots) == 0 && prov_may_point_at_element(graph, carriers)
	for slot in content {
		graph.prov_slots[slot].loaded = true
		prov_emit(graph, Prov_Event {
			kind            = .Load,
			slot            = slot,
			into            = carriers,
			path            = prov_concat_path(graph, path, graph.prov_slots[slot].path),
			span            = span,
			reads_only      = reads_only,
			load_element    = load_element,
			element         = element,
			through_element = through_element,
		})
	}
	prov_emit(graph, Prov_Event{kind = .Live, sources = content, span = span, reads_only = reads_only})
	prov_name_loaded(graph, content, carriers)
	return content
}

// design.md "Weakening and reborrows": a value read out through a carrier only
// reads it when the value carries no mutable borrow, so a read-only reborrow
// of the carrier does not suspend it.
@(private)
prov_read_is_reads_only :: proc(c: ^Compiler, type: Type_Id) -> bool {
	return !type_carries_borrow(c, type).mutable
}

// design.md "Weakening and reborrows": a carrier stored where a read-only one
// is wanted is only read, so `Views{xs, xs}` is accepted. An erased value is not:
// a stored `dyn proc` borrows the place it views (design.md "Borrowed callable
// views").
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
		return v.op == .Caret && !v.boxed
	case ^Expr_Selector:
		return true
	case ^Expr_Index:
		return v.resolution.kind != .User_Operator
	}
	return false
}

// The carriers `operand` holds, for a read through them.
@(private)
prov_read_carrier :: proc(graph: ^Flow_Graph, operand: Expr, reads_only: bool) -> []int {
	if reads_only {
		if ident, is_ident := operand.(^Expr_Ident); is_ident {
			return prov_read_ident(graph, ident, reads_only = true)
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
				return prov_load_content(graph, carriers, path, prov_type(graph, operand), expr_span(operand), reads_only = true, place = operand)
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
			sources = prov_join(graph, sources, holds)
		}
		prov_emit(graph, Prov_Event{kind = .Live, sources = sources, span = span})
		bit := prov_window_bit(graph, id)
		if tasks, pooled := graph.pool_tasks[id]; pooled && graph.current != NO_BLOCK {
			// Before the join closes the window, which decides where they apply.
			events := &graph.blocks[graph.current].prov
			first := len(events)
			prov_pool_join_effects(graph, tasks, span)
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
		graph.scope_drops[span] = true
	}
}

// design.md "Temporaries and procedure boundaries": an extended temporary is
// dropped with its block's locals. Nothing can name it, so nothing moves it
// first: its drop hooks always run there, and what they read stays live.
@(private)
prov_extended_drop :: proc(graph: ^Flow_Graph, root: Prov_Root, effects_at, span: Span) {
	prov_drop_effects(graph, root.dropped, effects_at, root.name, unnamed = true)
	held := root.slots if root.content < 0 else prov_one(graph, root.content)
	if len(held) == 0 || !type_drop_runs_hook(graph.k.c, root.dropped) {
		return
	}
	prov_emit(graph, Prov_Event{kind = .Live, sources = held, span = span})
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
		if copies {
			prov_reborrow(graph, sources, symbol_of(graph.k.c, id).type, slot, span, copies = true)
		} else {
			graph.lent_aliases[slot] = sources
		}
		prov_emit(graph, Prov_Event{kind = .Def, slot = slot, loan = NO_LOAN, sources = sources, span = span})
		return
	}
	if content := prov_content_slots(graph, id); len(content) > 0 {
		prov_define_content(graph, content, sources, span, copies = copies)
	}
}

// standard-library.md "Chunks of a mutable slice": a chunk is a reborrow of the view that
// does not suspend the view, so the view advances while earlier chunks are
// held, and through it the chunk keeps the sliced carrier suspended. Each step
// binds a value disjoint from the last, so redefining the binding ends the
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
	prov_emit(graph, Prov_Event{kind = .Def, slot = slot, loan = NO_LOAN, sources = sources, span = span})
	return true
}

// Publishes content into another value's slots by matching paths.
@(private)
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
	reborrows := true,
	replaces_read := false,
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
		prov_define_one_content(graph, slot, sources, span, path_precision(written), copies, reborrows, replaces_read)
	}
}

// A mutable borrow published into a read-only field weakens as at a local.
@(private)
prov_define_one_content :: proc(
	graph: ^Flow_Graph, slot: int, sources: []int, span: Span, precision: Precision_Loss = {}, copies := true,
	reborrows := true, replaces_read := false,
) {
	entry := graph.prov_slots[slot]
	type := entry.content_type
	if type == INVALID_TYPE && entry.content_shape == INVALID_TYPE {
		if sym := symbol_of(graph.k.c, entry.symbol); sym != nil { type = sym.type }
	}
	if !copies {
		graph.lent_aliases[slot] = sources
	} else if reborrows {
		// A value read below the place it replaces was used by that read
		// (`prov_publish_store`).
		prov_reborrow(graph, sources, type, slot, span, copies = !replaces_read)
	}
	prov_emit(graph, Prov_Event{kind = .Def, slot = slot, loan = NO_LOAN, sources = sources, span = span, precision = precision, replaces_read = replaces_read})
	if traversal, traversed := graph.traversals[entry.symbol]; traversed {
		prov_publish_traversal(graph, traversal, slot, sources, span, type, reborrows, replaces_read)
	} else if len(graph.region_aliases[entry.symbol]) > 0 {
		prov_event(graph, Prov_Event_View_Publish {
			symbol = entry.symbol, path = entry.path, sources = sources, span = span,
			type = type, through = graph.view_loans[entry.symbol],
		})
	}
}

// Where a store through a `foreach (&mut x in source)` binding lands: the
// element it names, in a named place at `path` of `root`, or else in what the
// slots `into` name, along `path` when `known` says it is one place.
Prov_Traversal :: struct {
	root:  Root_Id,
	path:  []Proj_Step,
	into:  []int,
	known: bool,
	// A user's iterator lends it: `root` and `path` are the source, and `into`
	// the storage it may reach through carriers.
	lent:  bool,
}

// design.md "Values that contain borrows": a `&mut` binding names an element
// of the source, so a carrier stored through it is in the source too. `below`
// is where the binding is inside the element, and `element` where it is below
// the source, nil for a user's iterator, which says nothing of where it lends,
// so a store lands anywhere a carrier of its type may be: in the source or
// where its mutable carriers lead. Which element is not known, so what is
// stored joins what every element holds.
@(private)
prov_note_traversal :: proc(
	graph: ^Flow_Graph, s: ^Stmt_Foreach, id: Symbol_Id, below, element: []Proj_Step, iterated, elements, through: []int,
) {
	if id == INVALID_SYMBOL {
		return
	}
	protocol := s.kind == .Protocol
	carrier := type_is_carrier(graph.k.c, prov_type(graph, s.iterable))
	traversal := Prov_Traversal{root = NO_ROOT, lent = protocol}
	if carrier && !protocol && len(elements) > 0 {
		// What a view lends is below its loans, at no step of its own.
		traversal.into, traversal.path, traversal.known = elements, below, true
	} else if len(through) > 0 {
		traversal.into = through
		entry := graph.prov_slots[through[0]]
		if paths := prov_offset_paths(graph, entry.offsets); !protocol && len(through) == 1 && !entry.offsets_merged && len(paths) == 1 {
			traversal.path, traversal.known = prov_concat_path(graph, paths[0], element), true
		}
		if protocol {
			traversal.into = prov_join(graph, through, prov_load_writable(graph, through, expr_span(s.iterable)))
		}
	} else if root, path, named := prov_place_of(graph, s.iterable); named && !carrier {
		traversal.root, traversal.path = root, prov_concat_path(graph, path, element)
		if protocol {
			traversal.into = prov_mutable_reach(graph, prov_content_at(graph, root, path), prov_type(graph, s.iterable), expr_span(s.iterable))
		}
	} else {
		traversal.into = iterated
	}
	graph.traversals[id] = traversal
}

// What `slot`, of a `&mut` binding, was just set to, also in the source
// (`prov_note_traversal`). What the slot already held is there already.
@(private = "file")
prov_publish_traversal :: proc(
	graph: ^Flow_Graph, traversal: Prov_Traversal, slot: int, sources: []int, span: Span, type: Type_Id, reborrows, replaces_read: bool,
) {
	stored := make([dynamic]int, 0, len(sources), graph.alloc)
	for source in sources {
		if source != slot {
			append(&stored, source)
		}
	}
	if len(stored) == 0 {
		return
	}
	at := graph.prov_slots[slot].path
	if traversal.root != NO_ROOT && traversal.lent {
		for held in prov_content_at(graph, traversal.root, traversal.path) {
			if carrier_may_land_in(graph.k.c, slot_carrier_type(graph, held), type) {
				prov_define_one_content(graph, held, prov_join(graph, prov_one(graph, held), stored[:]), span, reborrows = reborrows, replaces_read = replaces_read)
			}
		}
	} else if traversal.root != NO_ROOT {
		written := prov_concat_path(graph, traversal.path, at)
		prov_define_content(graph, prov_content_at(graph, traversal.root, written), stored[:], span, written, type, preserve_previous = true, reborrows = reborrows, replaces_read = replaces_read)
		return
	}
	if len(traversal.into) == 0 {
		return
	}
	publish := Prov_Event{
		kind = .Publish, span = span, sources = stored[:], into = traversal.into, strips = true, carried = type, lands_by_type = traversal.lent,
		replaces_read = replaces_read,
	}
	if traversal.known {
		publish.path = prov_concat_path(graph, traversal.path, at)
	}
	if type != INVALID_TYPE && type_is_carrier(graph.k.c, type) {
		publish.linked = true
		if reborrows {
			if !replaces_read {
				prov_reborrow(graph, stored[:], type, span = span, copies = true)
			}
			publish.links_copies = true
			graph.has_linked_store = true
		}
	}
	prov_emit(graph, publish)
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
	first := prov_next_event(output)
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
	prov_emit(graph, Prov_Event{kind = .Publish, span = span, sources = sources, into = through, carried = type})
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

// design.md "Evaluation order": a value keeps what its carriers held when it
// was evaluated. A mutable carrier is reborrowed, others copied. With
// `keep_reborrows`, a slot that is already a mutable reborrow is kept as it is,
// since the carrier it suspends cannot be written meanwhile.
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
		if prov_slot_may_come_to_reborrow(graph, slot) {
			append(&graph.reborrows, Prov_Reborrow{source = slot, derived = held, span = span, passes_on = true, pending = true})
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
	prov_def_copy(graph, held, slot, span)
	return held
}

// A carrier local read as itself: a conversion such as `[dynamic]T` to `[]T`
// borrows an owner instead. An erased operand's own type is a `dyn` view.
@(private = "file")
prov_view_local :: proc(graph: ^Flow_Graph, e: Expr) -> (ident: ^Expr_Ident, type: Type_Id, ok: bool) {
	named, is_ident := e.(^Expr_Ident)
	if !is_ident {
		return nil, INVALID_TYPE, false
	}
	repr := prov_repr(graph, named)
	if repr.view_from != INVALID_TYPE {
		return nil, INVALID_TYPE, false
	}
	if _, is_carrier := prov_slot_for_symbol(graph, named.symbol); !is_carrier {
		return nil, INVALID_TYPE, false
	}
	return named, repr.erased_from != INVALID_TYPE ? repr.erased_from : repr.type, true
}

// A slice local whose elements are plain data, which reading cannot turn into
// a way to write (design.md "Weakening and reborrows").
@(private)
prov_plain_slice_local :: proc(graph: ^Flow_Graph, e: Expr) -> (^Expr_Ident, bool) {
	ident, type, ok := prov_view_local(graph, e)
	if !ok || underlying_kind(graph.k.c, type) != .Slice {
		return nil, false
	}
	return ident, !type_carries_borrow(graph.k.c, underlying_info(graph.k.c, type).element).any
}

// A place, named or reached through carriers, whose value can be read where it is.
// A conversion such as `[dynamic]T` to `[]T` borrows an owner instead.
@(private)
prov_reads_as_place :: proc(graph: ^Flow_Graph, argument: Expr) -> bool {
	if expr_base(argument) == nil || prov_repr(graph, argument).view_from != INVALID_TYPE {
		return false
	}
	if _, is_ident := argument.(^Expr_Ident); is_ident {
		return true
	}
	_, _, place := prov_place_of(graph, argument)
	if place { return true }
	_, through := prov_input_place(graph, argument).base.(Value_Id)
	return through && prov_reads_plainly_through(graph, argument)
}

// A carrier place passed to a parameter that can write through nothing it
// receives, as `held.items` passed to a `[]int`, or one read out through a
// carrier, as `p^` passed to a `^T`: the call only reads it.
@(private)
prov_argument_only_read :: proc(graph: ^Flow_Graph, argument: Expr, parameter: Type_Id) -> bool {
	c := graph.k.c
	if expr_base(argument) == nil {
		return false
	}
	repr := prov_repr(graph, argument)
	if type_carries_borrow(c, parameter).mutable {
		return false
	}
	// An erased operand's own type is a `dyn` view.
	type := repr.erased_from != INVALID_TYPE ? repr.erased_from : repr.type
	return type_is_carrier(c, type) && prov_reads_as_place(graph, argument)
}

@(private)
prov_temp_slot :: proc(graph: ^Flow_Graph) -> int {
	return prov_add_slot(graph, empty_prov_slot(INVALID_SYMBOL))
}

// Adds a slot and answers its index.
@(private = "file")
prov_add_slot :: proc(graph: ^Flow_Graph, entry: Prov_Slot) -> int {
	append(&graph.prov_slots, entry)
	return len(graph.prov_slots) - 1
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
	} else {
		prov_note_static_read(graph, root)
	}
	append(&graph.loans, Prov_Loan{root = root, path = path, mutable = mutable, span = span, what = what})
	return Loan_Id(len(graph.loans) - 1)
}

// A loan standing for what caller storage holds, `depth` loads down, of the
// `pointee`th pointee path when that is above zero.
@(private = "file")
prov_new_content_loan :: proc(graph: ^Flow_Graph, root: Root_Id, path: []Proj_Step, mutable: bool, span: Span, what: string, depth: int, pointee := 0) -> Loan_Id {
	loan := prov_new_loan(graph, root, path, mutable, span, what)
	entry := &graph.loans[int(loan)]
	entry.content, entry.depth, entry.pointee = true, depth, pointee
	return loan
}

@(private = "file")
carrier_path_noun :: proc(c: ^Compiler, path: Carrier_Path) -> string {
	return path.truncated ? "borrow" : carrier_noun(c, path.type)
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
	slot, loan := prov_new_borrow_slot(graph, root, path, mutable, span, what, access_block, access_index)
	prov_emit(graph, Prov_Event{kind = .Def, slot = slot, loan = loan, span = span})
	return prov_join(graph, prov_one(graph, slot), prov_root_view(graph, root))
}

// The loan and slot of a fresh borrow, before anything defines the slot.
@(private = "file")
prov_new_borrow_slot :: proc(
	graph: ^Flow_Graph,
	root: Root_Id,
	path: []Proj_Step,
	mutable: bool,
	span: Span,
	what: string,
	access_block := NO_BLOCK,
	access_index := -1,
) -> (slot: int, loan: Loan_Id) {
	// design.md "@(synchronized)": even a read-only borrow of a synchronized
	// field excludes every other access while it lasts.
	loan = prov_new_loan(graph, root, path, mutable || path_is_synchronized(path), span, what)
	slot = prov_temp_slot(graph)
	graph.prov_slots[slot].borrow = Prov_Fresh_Borrow{loan, Prov_Event_At{access_block, access_index}}
	return
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
	} else {
		prov_note_static_read(graph, root)
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
	return path_extend(path, step, graph.alloc)
}

@(private)
prov_concat_path :: proc(graph: ^Flow_Graph, prefix, path: []Proj_Step) -> []Proj_Step {
	return path_concat(prefix, path, graph.alloc)
}

// A place read by its root, when it has one.
@(private = "file")
prov_read_rooted :: proc(graph: ^Flow_Graph, e: Expr) -> (content: []int, ok: bool) {
	root, path, rooted := prov_place_of(graph, e)
	if !rooted {
		return nil, false
	}
	prov_walk_subscripts(graph, e)
	prov_access(graph, root, path, .Read, expr_span(e))
	// The read yields the place's content, with no lasting borrow.
	return prov_read_content(graph, root, path, prov_type(graph, e), expr_span(e)), true
}

// A place read through the carriers reaching it, when it has any.
@(private = "file")
prov_read_carried :: proc(graph: ^Flow_Graph, e: Expr) -> (content: []int, ok: bool) {
	only := prov_read_is_reads_only(graph.k.c, prov_type(graph, e))
	carriers, path, through := prov_read_through_carrier(graph, e, only)
	if !through {
		return nil, false
	}
	return prov_load_content(graph, carriers, path, prov_type(graph, e), expr_span(e), only, place = e), true
}

@(private)
prov_read_deref :: proc(graph: ^Flow_Graph, v: ^Expr_Postfix) -> []int {
	// design.md "Owned values": reading `b^` reads the box, as reading `xs[i]`
	// reads a dynamic array.
	if v.boxed {
		if content, ok := prov_read_rooted(graph, v); ok {
			return content
		}
		if content, ok := prov_read_carried(graph, v); ok {
			return content
		}
		loans := walk_flow_expr(graph, v.operand)
		return prov_project_content(graph, loans, prov_type(graph, v.operand), {proj_wild()}, prov_type(graph, v), v.span)
	}
	only := prov_read_is_reads_only(graph.k.c, prov_type(graph, v))
	carriers, _, _ := prov_read_through_carrier(graph, v, only)
	return prov_load_content(graph, carriers, nil, prov_type(graph, v), v.span, only)
}

@(private)
prov_read_selector :: proc(graph: ^Flow_Graph, v: ^Expr_Selector) -> []int {
	if content, ok := prov_read_rooted(graph, v); ok {
		return content
	}
	if content, ok := prov_read_carried(graph, v); ok {
		return content
	}
	loans := walk_flow_expr(graph, v.operand)
	if v.resolution.kind == .Field && v.operand != nil {
		return prov_project_content(
			graph, loans, prov_type(graph, v.operand), {prov_field_step(graph, v)}, prov_type(graph, v), v.span,
		)
	}
	return nil
}

@(private)
prov_read_index :: proc(graph: ^Flow_Graph, v: ^Expr_Index) -> []int {
	if v.resolution.kind == .User_Operator {
		return prov_call(graph, prov_operator_call(graph, v))
	}
	// Reading a map's element clones it out, which writing one does not.
	if len(v.bound) == 0 && underlying_kind(graph.k.c, prov_type(graph, v.operand)) == .Map {
		prov_copy_effects(graph, prov_type(graph, v), v.span)
	}
	if content, ok := prov_read_rooted(graph, v); ok {
		return content
	}
	// An element of plain data read out of a slice local only reads the
	// carrier (design.md "Weakening and reborrows").
	if ident, plain := prov_plain_slice_local(graph, v.operand); plain && len(v.bound) == 0 &&
	   !prov_indices_may_write(graph.k.c, v.indices) {
		carriers := prov_read_ident(graph, ident, reads_only = true)
		for index in v.indices {
			walk_flow_expr(graph, index)
		}
		return prov_load_content(graph, carriers, nil, prov_type(graph, v), v.span)
	}
	if content, ok := prov_read_carried(graph, v); ok {
		return content
	}
	loans := walk_flow_expr(graph, v.operand)
	for index in v.indices {
		loans = prov_join(graph, loans, walk_flow_expr(graph, index))
	}
	return prov_project_content(
		graph, loans, prov_type(graph, v.operand), prov_index_path(graph, v), prov_type(graph, v), v.span,
	)
}

// What a `return` hands back: the borrows it carries and what they reach escape,
// and the slots holding them stay live through the cleanups. `graph.returning`
// names the value while they run, which the caller restores.
@(private)
prov_return_value :: proc(graph: ^Flow_Graph, value: ^Return_Value) -> []int {
	// design.md "`inout` results": `return inout place` hands back a
	// borrow of the place, which must outlive the frame.
	sources: []int
	if value.is_inout {
		sources = prov_borrow_place(graph, value.expr, true, expr_span(value.expr), "`inout` result")
	} else {
		sources = walk_flow_expr(graph, value.expr)
	}
	returned := prov_input_value(graph, value.expr)
	if !value.is_inout {
		graph.returning = new_clone(Prov_Returning{value = returned, span = expr_span(value.expr)}, graph.alloc)
	}
	result_type := prov_type(graph, value.expr)
	if sym := symbol_of(graph.k.c, graph.literal.symbol); sym != nil {
		result_type = sym.result
	}
	contents := prov_load_deep(graph, sources, expr_span(value.expr))
	prov_event(graph, Prov_Event_Escape{sources = sources, into = contents, returning = {value = returned, result = result_type, span = expr_span(value.expr)}})
	return prov_hold_result(graph, prov_join(graph, sources, contents), result_type, expr_span(value.expr))
}

// What an `or_return` propagates, as `prov_return_value` for a `return`.
@(private)
prov_or_return_escape :: proc(graph: ^Flow_Graph, v: ^Expr_Postfix, operand_loans: []int) -> []int {
	proc_symbol := symbol_of(graph.k.c, graph.literal.symbol)
	if proc_symbol == nil || proc_symbol.result == INVALID_TYPE {
		return nil
	}
	shape, operand_fallible := fallible_of(graph.k.c, prov_type(graph, v.operand))
	target, target_fallible := fallible_of(graph.k.c, proc_symbol.result)
	if !operand_fallible || !target_fallible {
		return nil
	}
	from := shape.failure_type
	into := target.failure_type
	escaping := prov_payload_content(graph, operand_loans, prov_type(graph, v.operand), from, v.span)
	if failure_assignment_borrows(graph.k.c, from, into) {
		if root, path, is_place := prov_place_of(graph, v.operand); is_place {
			block, index := prov_access(graph, root, path, .Read, v.span)
			escaping = prov_join(graph, escaping, prov_borrow(graph, root, path, false, v.span, "view", block, index))
		} else {
			escaping = prov_join(graph, escaping, prov_borrow(graph, prov_temp_root(graph, v.span), nil, false, v.span, "view"))
		}
	}
	contents := prov_load_deep(graph, escaping, v.span)
	propagated := prov_error_form(graph, v)
	graph.returning = new_clone(Prov_Returning{propagated = propagated, result = proc_symbol.result, span = v.span}, graph.alloc)
	prov_event(graph, Prov_Event_Escape{sources = escaping, into = contents, returning = graph.returning^})
	return prov_hold_result(graph, prov_join(graph, escaping, contents), proc_symbol.result, v.span)
}

// What a level of a `foreach` pattern takes apart: a map entry's and an
// `indexed()` pair's fields are no fields of what the source stores.
@(private = "file")
Foreach_Pattern :: enum { Value, Map_Entry, Indexed_Pair }

@(private = "file")
foreach_element_pattern :: proc(s: ^Stmt_Foreach) -> Foreach_Pattern {
	if s.indexed {
		return .Indexed_Pair
	}
	return s.kind == .Map ? .Map_Entry : .Value
}

// Binds what each of a `foreach`'s bindings holds at a step.
@(private)
prov_bind_foreach :: proc(graph: ^Flow_Graph, s: ^Stmt_Foreach, iterated, elements, through: []int) {
	walk_foreach_binding_provenance(graph, s, s.bindings, iterated, elements, through, s.element_type, foreach_element_pattern(s), nil)
}

// `below` is where this level of the pattern is inside the element, which
// a `&mut` leaf names (`prov_note_traversal`).
@(private = "file")
walk_foreach_binding_provenance :: proc(
	graph: ^Flow_Graph, s: ^Stmt_Foreach, bindings: []Foreach_Binding, iterated, elements, through: []int,
	logical: Type_Id, pattern: Foreach_Pattern, below: []Proj_Step,
) {
	if len(bindings) == 1 && len(bindings[0].group) > 0 {
		walk_foreach_binding_provenance(graph, s, bindings[0].group, iterated, elements, through, logical, pattern, below)
		return
	}
	// design.md "Destructuring": a padding field fills no binding.
	fields: []Symbol_Id
	if info := underlying_info(graph.k.c, logical); len(bindings) > 1 && info != nil && info.kind == .Struct {
		fields = named_fields(graph.k.c, info)
	}
	for binding, position in bindings {
		part, part_pattern, at := logical, pattern, below
		if position < len(fields) {
			field := symbol_of(graph.k.c, fields[position])
			part, part_pattern = field.type, .Value
			switch pattern {
			case .Value:
				at = prov_extend(graph, below, proj_field(int(field.index)))
			case .Map_Entry:
				at = prov_extend(graph, below, proj_field(position == 0 ? PROJ_MAP_KEY : PROJ_MAP_VALUE))
			case .Indexed_Pair:
				if s.kind == .Map { part_pattern = .Map_Entry }
			}
		}
		if len(binding.group) > 0 {
			walk_foreach_binding_provenance(graph, s, binding.group, iterated, elements, through, part, part_pattern, at)
			continue
		}
		// What a leaf holds is what the element holds. Only a borrow of it takes
		// the traversal's own loans, which the view below gives it.
		loans := iterated
		if s.kind != .Protocol && len(elements) > 0 {
			loans = elements
		}
		// standard-library.md "Chunks of a mutable slice": a chunk takes the view's loans
		// without reborrowing the view, so the view advances while earlier
		// chunks are held. The chunks are disjoint by construction.
		if foreach_yields_chunks(graph.k.c, s) && prov_bind_chunk(graph, binding.symbol, loans, expr_span(s.iterable)) {
			continue
		}
		// A lent element is the stored carrier, not a copy of it, so it does not
		// reborrow what the container holds (design.md "Borrowing iteration"):
		// reading it reads that carrier, which the iterator loan already guards.
		sym := symbol_of(graph.k.c, binding.symbol)
		lent := sym != nil && sym.borrowed_binding != .None
		carrier := s.kind != .Protocol && len(elements) > 0 && type_is_carrier(graph.k.c, prov_type(graph, s.iterable))
		// design.md "Procedure result contracts": the value of a carrier's lent
		// element is what `values[i]` would load through the carrier, so a copy
		// of it keeps only the element's own borrows; reading the binding still
		// uses the carrier through the view below.
		if lent && carrier {
			loans = prov_load_content(
				graph, elements, binding.is_ref ? at : nil, sym.type, expr_span(s.iterable),
				reads_only = prov_read_is_reads_only(graph.k.c, sym.type),
			)
			if binding.is_ref {
				for slot in loans {
					graph.prov_slots[slot].names_element = true
				}
			}
		}
		// The leaf starts as what the element holds, which only a store through
		// it afterwards adds to.
		delete_key(&graph.traversals, binding.symbol)
		prov_forget_region_binding(graph, binding.symbol)
		prov_bind_value(graph, binding.symbol, loans, expr_span(s.iterable), copies = !lent)
		// A user's iterator says nothing of where in the source it lends.
		element := s.kind == .Protocol ? nil : prov_concat_path(graph, prov_extend(graph, nil, proj_wild()), at)
		prov_bind_element_region(graph, binding.symbol, prov_input_value(graph, s.iterable), element, binding.is_ref)
		// A lent or mutable element is the source's storage (design.md "Borrowing
		// iteration"), so the binding views what `&iterable` would; the loop's own
		// reads already hold that.
		if lent {
			viewed := iterated
			if carrier {
				viewed = elements
			} else if len(through) > 0 {
				viewed = through
			} else if s.kind != .Protocol {
				if carriers, _, reached := prov_read_through_carrier(graph, s.iterable); reached && len(carriers) > 0 {
					viewed = carriers
				}
			}
			prov_bind_view(graph, binding.symbol, viewed, lends = !foreach_is_place_loop(s))
		}
		if binding.is_ref {
			prov_note_traversal(graph, s, binding.symbol, at, element, iterated, elements, through)
		}
	}
}

@(private = "file")
foreach_yields_chunks :: proc(c: ^Compiler, s: ^Stmt_Foreach) -> bool {
	next := symbol_of(c, s.next_symbol)
	return s.kind == .Protocol && next != nil && next.synth == .Chunks_Next
}

// One name a case binds: the payload, or with `slot` one of its fields.
@(private)
prov_bind_case_name :: proc(
	graph: ^Flow_Graph, s: ^Stmt_Switch, symbol: Symbol_Id, is_ref: bool, sources: []int, span: Span,
	consumes: bool, variants: []int, shared_view: ^Prov_Case_View, slot := -1,
) {
	// Over a place, the binding is the stored payload, not a copy of it.
	// A deferred switch can be expanded more than once in the same graph.
	prov_forget_region_binding(graph, symbol)
	prov_bind_value(graph, symbol, sources, span, copies = consumes)
	prov_bind_case_region(graph, symbol, prov_input_value(graph, s.subject), variants, slot)
	// A place subject keeps its payload, so the binding views its storage;
	// a consumed one is the binding's own, which ends with its case
	// (design.md "Switch ownership").
	if !consumes {
		// design.md "Switch ownership": `cursor = &mut node.next` keeps a
		// loan of this case's `node`, which the next pass binds afresh.
		if is_ref {
			prov_emit(graph, Prov_Event{kind = .Rebind, root = prov_root_for_symbol(graph, symbol), span = span})
		}
		prov_bind_view(graph, symbol, prov_subject_view(graph, s.subject, is_ref, slot, shared_view))
		if !is_ref {
			prov_note_view_use(graph, symbol, s.subject, slot)
		}
	} else {
		root := prov_root_for_symbol(graph, symbol)
		append(&graph.in_scope, Flow_Cleanup{kind = .Prov_Root, root = root, span = span})
	}
}

// design.md "Procedure result contracts": a borrowed parameter starts with one
// loan of the caller's root.
// A parameter that keeps its argument's region names it by its position. One that is or
// holds view carriers and no allocator handle stands for what those carriers view, which
// only a read through them says the read of (`Region_Read`).
@(private = "file")
prov_seed_parameter_region :: proc(graph: ^Flow_Graph, id: Symbol_Id, sym: ^Symbol, index: int) {
	c := graph.k.c
	if prov_type_keeps_argument_region(c, sym.type) {
		set: Region_Set
		region_add_param(&set, index, prov_parameter_read(c, sym.type))
		graph.region_of[id] = set
	}
}

// An aggregate parameter gets one loan per shape path.
@(private = "file")
prov_bind_shape_loans :: proc(graph: ^Flow_Graph, root: Root_Id, sym: ^Symbol, content: []int) {
	for path, path_index in carrier_shape(graph.k.c, sym.type) {
		loan := prov_new_content_loan(graph, root, path.steps, path.mutable, sym.span, carrier_path_noun(graph.k.c, path), 0)
		append(&graph.entry_defs, Prov_Entry_Def{slot = content[path_index], loan = loan})
	}
}

// design.md "Procedure result contracts": a load along one path of the pointee
// reads only that path, and so do the loads below it, so a field read out of
// `[]Pair` or `d.pair.a` names none of its siblings. One path tells nothing apart.
@(private = "file")
prov_bind_pointee_loans :: proc(graph: ^Flow_Graph, root: Root_Id, sym: ^Symbol, depths: []Loan_Id) {
	pointee := carrier_pointee_shape(graph.k.c, sym.type)
	if len(pointee) <= 1 {
		return
	}
	paths := make([][]Loan_Id, len(pointee), graph.alloc)
	for path, at in pointee {
		paths[at] = make([]Loan_Id, len(depths), graph.alloc)
		for &deeper, depth in paths[at] {
			first := depth == 0
			deeper = prov_new_content_loan(
				graph, root, nil, first ? path.mutable : graph.loans[int(depths[depth])].mutable, sym.span,
				first ? carrier_path_noun(graph.k.c, path) : carrier_noun(graph.k.c, sym.type), depth + 1, at + 1,
			)
		}
	}
	graph.roots[int(root)].pointee_loans = paths
}

@(private)
prov_bind_parameters :: proc(graph: ^Flow_Graph, literal: ^Expr_Proc) {
	if literal.signature == nil {
		return
	}
	index := 0
	for parameter in literal.signature.params {
		for id in parameter.symbols {
			defer index += 1
			sym := symbol_of(graph.k.c, id)
			if sym == nil {
				continue
			}
			prov_seed_parameter_region(graph, id, sym, index)
			// A `move` parameter is dropped when the body returns; callers see
			// that write through this body's effect, and its release frees in
			// the argument's region.
			if parameter.mode == .Move {
				prov_scope_drop_effects(graph, id, sym.span)
				// A provider moved in is this body's to end, as a local's is: what it
				// backs must end first. Its own parents are still the argument's.
				if provider_local(graph.k.c, id) {
					if type_is_region_provider(graph.k.c, sym.type) {
						graph.provider_parents[id] = graph.region_of[id]
						graph.region_of[id] = prov_provider_region(graph, id)
					}
					append(&graph.in_scope, Flow_Cleanup{kind = .Prov_Root, root = prov_root_for_symbol(graph, id), span = sym.span})
				}
			}
			slot, is_carrier := prov_slot_for_symbol(graph, id)
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
			// What the caller storage it reaches holds, which loads through it yield. A
			// `..^T` pack's lent values have a loan apart from what they hold, which a
			// call may keep, even where they hold no borrow (design.md "Variadic
			// parameters").
			least := param_symbol_lends(graph.k.c, sym) ? 2 : 1
			depths := make([]Loan_Id, max(least, load_depth(graph.k.c, sym.type)), graph.alloc)
			for &loan, depth in depths {
				loan = prov_new_content_loan(graph, root, nil, type_carries_borrow(graph.k.c, sym.type).mutable, sym.span, carrier_noun(graph.k.c, sym.type), depth + 1)
			}
			graph.roots[int(root)].content_loans = depths
			if !is_carrier {
				prov_bind_shape_loans(graph, root, sym, content)
				prov_caller_slots(graph, root, first_loan, name)
				continue
			}
			loan := prov_new_loan(graph, root, nil, carrier_is_mutable(graph.k.c, sym.type), sym.span, carrier_noun(graph.k.c, sym.type))
			append(&graph.entry_defs, Prov_Entry_Def{slot = slot, loan = loan})
			prov_bind_pointee_loans(graph, root, sym, depths)
			prov_caller_slots(graph, root, first_loan, name)
		}
	}
}

// design.md "Weakening and reborrows": the caller storage a parameter's loan
// names has no content here, so a slot stands for what it holds, holding the
// loan one more load through it reads. A load through the parameter reads these
// slots; `publish_into_caller` says where a store lands. Slots of different loans
// are taken to name different storage.
@(private)
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
			one := underlying_kind(c, type) == .Pointer
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
			below, pointers := carrier_below(c, at.type, loan.depth - 1)
			holder = below
			one = underlying_kind(c, type) == .Pointer && path_is_exact(at.steps) && pointers
		case !loan.content:
			holder = type
			one = underlying_kind(c, type) == .Pointer
		case loan.depth == 0:
			for path in shape {
				if slice.equal(path.steps, loan.path) && !path.truncated {
					holder = path.type
				}
			}
			one = holder != INVALID_TYPE && path_is_exact(loan.path) && underlying_kind(c, holder) == .Pointer
		case loan.depth < len(descriptor.content_loans):
			below, pointers := carrier_below(c, type, loan.depth)
			holder = below
			one = pointers
		}
		paths: []Carrier_Path
		if element := prov_pointee_type(c, holder); element != INVALID_TYPE {
			paths = carrier_shape(c, element)
		}
		if len(paths) < 2 {
			// One carrier path in the storage is the slot's content, kept with
			// its place and type so a store of exactly that carrier replaces it
			// (`caller_replaces`), as `p^.head` with `p: ^mut One` and
			// `One :: struct { head: ^mut Node, count: int }`.
			whole := Carrier_Path{type = INVALID_TYPE}
			if len(paths) == 1 {
				whole = paths[0]
			}
			mutable := len(paths) == 1 ? paths[0].mutable : graph.loans[int(held)].mutable || reaches_mutable
			prov_caller_slot(graph, Loan_Id(index), whole, held, name, mutable, one)
			continue
		}
		// `paths` are what a load one below this loan's reads, its `last_load_shape`
		// at `held`'s depth, unless `held` is this loan: the last content loan,
		// standing for every depth below it.
		names_last := graph.loans[int(held)].depth == loan.depth + 1
		for path, position in paths {
			// Each carrier in one storage holds a loan of its own, as each
			// pointee path's does, so what `p^^.head` and `p^^.tail` point at
			// are told apart, and a result's contract says which it holds. Loads
			// below it read what `held` stands for.
			own := held
			if one {
				own = prov_new_content_loan(
					graph, root, nil, path.mutable, descriptor.span, carrier_path_noun(c, path),
					graph.loans[int(held)].depth, graph.loans[int(held)].pointee,
				)
				if names_last {
					graph.loans[int(own)].last = position + 1
				}
			}
			prov_caller_slot(graph, Loan_Id(index), path, own, name, path.mutable, one)
		}
	}
}

// What a pointer or slice of `type` points at, or INVALID_TYPE.
@(private = "file")
prov_pointee_type :: proc(c: ^Compiler, type: Type_Id) -> Type_Id {
	if info := underlying_info(c, type); type != INVALID_TYPE && info != nil && (info.kind == .Pointer || info.kind == .Slice) {
		return info.element
	}
	return INVALID_TYPE
}

@(private = "file")
prov_caller_slot :: proc(
	graph: ^Flow_Graph, loan: Loan_Id, path: Carrier_Path, held: Loan_Id, name: string, mutable: bool, one: bool,
) {
	entry := empty_prov_slot(INVALID_SYMBOL)
	entry.kind = .Caller
	entry.name = name
	entry.path = path.steps
	entry.content_type = path.truncated ? INVALID_TYPE : path.type
	entry.content_truncated = path.truncated
	entry.caller_mutable = mutable
	entry.caller_one = one
	slot := prov_add_slot(graph, entry)
	if loan not_in graph.caller_slots {
		graph.caller_slots[loan] = make([dynamic]int, 0, 4, graph.alloc)
	}
	append(&graph.caller_slots[loan], slot)
	append(&graph.entry_defs, Prov_Entry_Def{slot = slot, loan = held})
}

// One element of a view parameter's caller storage (`prov_view_element`).
Prov_View_Element :: struct {
	loan:  Loan_Id,
	index: i64,
}

// design.md "Values that contain borrows": a parameter binding is read-only, so
// `s[k]`, with `s` a view parameter and `k` a constant, always names one element of
// the caller's view (`caller_replaces`). It gets slots of its own beside those for
// every element (`prov_caller_slots`). False when `place` names no such element.
@(private)
prov_view_element :: proc(graph: ^Flow_Graph, place: Expr) -> (Prov_Element_Slots, bool) {
	c := graph.k.c
	view, element, found_element := prov_constant_view_element(graph, place)
	if !found_element {
		return {}, false
	}
	root, own := prov_view_parameter_loan(graph, view)
	if own == NO_LOAN {
		return {}, false
	}
	key := Prov_View_Element{loan = own, index = element}
	slots, found := graph.view_elements[key]
	if !found {
		// As `prov_caller_slots` makes the slots standing for every element.
		descriptor := graph.roots[int(root)]
		pointee := carrier_pointee_shape(c, symbol_of(c, view).type)
		first := len(graph.prov_slots)
		if len(descriptor.pointee_loans) > 0 {
			for loans, position in descriptor.pointee_loans {
				prov_caller_slot(graph, own, pointee[position], loans[0], descriptor.name, pointee[position].mutable, false)
			}
		} else if len(pointee) == 1 {
			held := Loan_Id(deeper_content_loan(descriptor, graph.loans[int(own)], int(own)))
			prov_caller_slot(graph, own, pointee[0], held, descriptor.name, pointee[0].mutable, false)
		}
		slots = make([]int, len(graph.prov_slots) - first, graph.alloc)
		for &slot, at in slots {
			slot = first + at
			graph.prov_slots[slot].caller_element = true
		}
		graph.view_elements[key] = slots
	}
	if len(slots) == 0 {
		return {}, false
	}
	return Prov_Element_Slots{own, slots}, true
}

// design.md "Places and overlap": whether `carriers` have only been defined to point into
// an element of a view parameter, as `p` is by `p := &mut s[0]`, so far as the walk has
// seen. Which element, and whether a definition it has yet to meet says otherwise, is for
// the solve (`carriers_element`).
@(private)
prov_may_point_at_element :: proc(graph: ^Flow_Graph, carriers: []int) -> bool {
	for slot in carriers {
		entry := graph.prov_slots[slot]
		if !entry.element_defs || entry.other_defs {
			return false
		}
	}
	return len(carriers) > 0
}

// Records whether a definition of `slot` points it into an element of a view parameter
// (`Prov_Slot.element_defs`): a borrow of that itself, or a copy of what only has been.
@(private)
prov_note_element_pointer :: proc(graph: ^Flow_Graph, event: Prov_Event) {
	if event.place_loan > 0 {
		return
	}
	elements := false
	for source in event.sources {
		if prov_slot_is_through(graph, source) {
			continue
		}
		entry := graph.prov_slots[source]
		if !entry.element_defs || entry.other_defs {
			elements = false
			break
		}
		elements = true
	}
	slot := &graph.prov_slots[event.slot]
	if elements {
		slot.element_defs = true
	} else {
		slot.other_defs = true
	}
}

// design.md "Values that contain borrows": `s[k]`, with `s` a local view and `k` a
// constant, names one element of the storage a fresh `&mut a[lo:hi]` lends, when
// where `s` starts is known (`Prov_View_Def`) and nothing else writes `s`. The solve
// checks both (`publish_view_loan`). None when `place` names no such element.
@(private = "file")
prov_local_view_element :: proc(graph: ^Flow_Graph, place: Expr) -> Prov_View_At {
	view, element, found_element := prov_constant_view_element(graph, place)
	if !found_element || symbol_of(graph.k.c, view).kind == .Parameter {
		return {}
	}
	slot, found := prov_slot_for_symbol(graph, view)
	if !found {
		return {}
	}
	return Prov_View_At{slot = slot + 1, index = element}
}

// The named view `s` and the constant `k` when `place` is `s[k]`, or a place
// inside it reached through selectors, with `k` nonnegative and `s`'s pointee
// holding the place: `s` is the one carrier it is reached through.
@(private = "file")
prov_constant_view_element :: proc(graph: ^Flow_Graph, place: Expr) -> (Symbol_Id, i64, bool) {
	c := graph.k.c
	// The subscript applied to a named view, found before the hops.
	index, operand: Expr
	for e := place; e != nil && index == nil; {
		#partial switch v in e {
		case ^Expr_Selector:
			e = v.operand
		case ^Expr_Index:
			if _, named := v.operand.(^Expr_Ident); named && len(v.indices) == 1 {
				index, operand = v.indices[0], v.operand
			}
			e = v.operand
		case:
			e = nil
		}
	}
	if index == nil {
		return INVALID_SYMBOL, 0, false
	}
	element, is_constant := prov_const_int(graph, index)
	ident := operand.(^Expr_Ident)
	sym := symbol_of(c, ident.symbol)
	if !is_constant || element < 0 || sym == nil || underlying_kind(c, sym.type) != .Slice {
		return INVALID_SYMBOL, 0, false
	}
	hops := prov_place_hops(graph, place)
	if len(hops) != 1 || expr_base(prov_value(graph, hops[0].carrier).origin) != expr_base(operand) {
		return INVALID_SYMBOL, 0, false
	}
	return ident.symbol, element, true
}

// The root of `view` when it is a view parameter, whose binding is read-only,
// and its own loan, the first not standing for content; NO_LOAN otherwise.
@(private = "file")
prov_view_parameter_loan :: proc(graph: ^Flow_Graph, view: Symbol_Id) -> (Root_Id, Loan_Id) {
	sym := symbol_of(graph.k.c, view)
	if sym == nil || sym.kind != .Parameter || !sym.immutable {
		return NO_ROOT, NO_LOAN
	}
	root := NO_ROOT
	for entry, at in graph.roots {
		if entry.kind == .Param && entry.symbol == view {
			root = Root_Id(at)
			break
		}
	}
	for loan, at in graph.loans {
		if root != NO_ROOT && loan.root == root && !loan.content {
			return root, Loan_Id(at)
		}
	}
	return NO_ROOT, NO_LOAN
}

// `prov_view_element` for a store of `stored` at `target`, whose copies reborrow
// the slots of that element it lands in (`prov_link_landed`).
@(private = "file")
prov_view_element_store :: proc(graph: ^Flow_Graph, target: Expr, stored: Type_Id) -> (Prov_Element_Slots, bool) {
	if !prov_store_linked(graph.k.c, stored) {
		return {}, false
	}
	element, found := prov_view_element(graph, target)
	if !found {
		return {}, false
	}
	below := prov_place_hops(graph, target)[0].path
	if !path_is_exact(below) {
		return {}, false
	}
	return element, true
}

// An implicit `dyn` view keeps the source root with a read-only loan
// (design.md "Variadic parameters", "Borrowed callable views").
@(private)
prov_erase :: proc(graph: ^Flow_Graph, e: Expr) -> []int {
	span := expr_span(e)
	// design.md "Borrowed callable views": a procedure is the view's data word
	// itself, so holding one borrows nothing.
	repr := prov_repr(graph, e)
	if dyn_proc_signature(graph.k.c, repr.type) != INVALID_TYPE && underlying_kind(graph.k.c, repr.erased_from) == .Proc {
		return walk_flow_expr_erased(graph, e)
	}
	// Also a use of what a carrier already refers to, so erasure cannot hide
	// a stale view.
	held, lent := prov_read_only_view(graph, e, span)
	if lent || len(held) > 0 {
		return held
	}
	// A constant's hidden storage is a frame slot that follows the lexical scope.
	root := prov_new_root(graph, .Temporary, span, "this erased value")
	append(&graph.in_scope, Flow_Cleanup{kind = .Prov_Root, root = root, span = span})
	graph.roots[int(root)].extended = true
	return prov_borrow(graph, root, nil, false, span, "view")
}

// What a read-only view of `e` holds, as an erased `dyn` view does; `lent` when
// that is more than what it read, which for a constant it is not. A view of a slice
// or pointer local only reads it, so it holds a read-only reborrow, as a `[]T`
// parameter would. A field or element holding one is read the same way, so two views
// of `held.items` may be live together.
@(private = "file")
prov_read_only_view :: proc(graph: ^Flow_Graph, e: Expr, span: Span) -> (held: []int, lent: bool) {
	if ident, plain := prov_plain_view_local(graph, e); plain {
		return prov_lend_read_only(graph, e, prov_reborrow_traversal(graph, prov_read_ident(graph, ident, reads_only = true), span, false), span)
	}
	loans: []int
	plain_place := prov_plain_view_place(graph, e, prov_repr(graph, e).erased_from)
	{
		prov_begin_conversion(graph, e, .Erasure)
		defer prov_end_conversion(graph)
		if plain_place {
			loans = prov_read_carrier(graph, e, true)
		} else {
			if content, kept, through := prov_view_parts_through_carrier(graph, e, span); through {
				return prov_join(graph, content, kept), true
			}
			loans = walk_flow_expr(graph, e)
		}
	}
	if plain_place {
		loans = prov_reborrow_traversal(graph, loans, span, false)
	}
	return prov_lend_read_only(graph, e, loans, span)
}

// What a read-only view of `e` holds beside the `loans` it read: a loan of the
// place, or of the temporary holding the value. A constant has neither, and
// holds the `loans` alone.
@(private = "file")
prov_lend_read_only :: proc(graph: ^Flow_Graph, e: Expr, loans: []int, span: Span) -> (held: []int, lent: bool) {
	if root, path, ok := prov_place_of(graph, e); ok {
		return prov_join(graph, loans, prov_borrow(graph, root, path, false, span, "view")), true
	}
	// A temporary ends with its statement unless a local's value extends it
	// (design.md "Temporaries and procedure boundaries"), and the view with it.
	if !is_const_expr(e) {
		return prov_join(graph, loans, prov_borrow(graph, prov_temp_root_of(graph, e, loans), nil, false, span, "view")), true
	}
	return loans, false
}

// design.md "Built-in procedures": an argument an `assert` or `panic` report
// prints keeps its type, and the report borrows it until it has printed the last.
// What it holds is suspended that long, so a later argument cannot write what it
// reaches, and printing only reads, so two arguments may name the same place. A
// written `format` may instead write through a mutable carrier it is handed.
@(private)
prov_printed_argument :: proc(graph: ^Flow_Graph, e: Expr) -> (held: []int, printed: []int) {
	type := prov_type(graph, e)
	span := expr_span(e)
	writes := prov_print_may_write(graph.k.c, type)
	if content, kept, through := prov_view_parts_through_carrier(graph, e, span, !writes); through {
		return prov_join(graph, content, kept), content
	}
	loans := prov_reborrow_traversal(graph, prov_read_carrier(graph, e, !writes), span, false)
	held, _ = prov_lend_read_only(graph, e, loans, span)
	return held, loans
}

// Whether printing a `type` hands a written `format` a mutable carrier. A pointer or
// slice prints what it views, and the slot gets that by a read-only `self: ^`, so the
// mutable carrier that matters is one held in what is viewed. A distinct one may have
// a `format` that takes it by value.
@(private = "file")
prov_print_may_write :: proc(c: ^Compiler, type: Type_Id) -> bool {
	if !type_prints_through_method(c, type) {
		return false
	}
	viewed := type
	for {
		kind := underlying_kind(c, viewed)
		if type_underlying(c, viewed) != viewed || (kind != .Pointer && kind != .Slice) {
			break
		}
		viewed = underlying_info(c, viewed).element
	}
	return type_carries_borrow(c, viewed).mutable
}

// standard-library.md "Printed forms": printing reads what a pointer points to, and
// so on down, once a report has evaluated its last argument. `printed` is what each
// argument holds of that, which the read may go through.
@(private)
prov_read_printed_reach :: proc(graph: ^Flow_Graph, printed: []int, span: Span) {
	if len(printed) == 0 {
		return
	}
	graph.has_content_load = true
	prov_emit(graph, Prov_Event{kind = .Load, slot = prov_temp_slot(graph), into = printed, load = .Deep, span = span, reads_only = true})
}

// A read-only view of a field, element, or pointee reached through a pointer or
// a slice, as `s[0]` or `p^.x`, is an address in what the carrier names, so it
// keeps that in use whatever later happens to the carrier. A carrier it reborrows
// is suspended for as long. By parts: what the place holds, and the snapshot of the
// carriers it is reached through.
@(private = "file")
prov_view_parts_through_carrier :: proc(graph: ^Flow_Graph, e: Expr, span: Span, reads_only := false) -> (content: []int, kept: []int, through: bool) {
	if !prov_reads_plainly_through(graph, e) {
		return nil, nil, false
	}
	if _, _, named := prov_place_of(graph, e); named {
		return nil, nil, false
	}
	// A mutable call result holds its source's mutable loan, but a view of what it
	// names only needs that kept valid: a read of the source does not touch it.
	read_only_hold := false
	if hops := prov_place_hops(graph, e); len(hops) > 0 {
		carrier := prov_value(graph, hops[len(hops) - 1].carrier).origin
		read_only_hold = prov_expr_is_temporary(carrier) && type_carries_borrow(graph.k.c, prov_type(graph, carrier)).mutable
	}
	type := prov_type(graph, e)
	only := reads_only || prov_read_is_reads_only(graph.k.c, type) || prov_type_is_plain_view(graph.k.c, type)
	carriers, path, reached := prov_read_through_carrier(graph, e, only)
	if !reached {
		return nil, nil, false
	}
	content = prov_load_content(graph, carriers, path, type, span, only, place = e)
	kept = prov_snapshot(graph, carriers, span)
	for slot, index in carriers {
		if read_only_hold || prov_slot_is_mutable_carrier(graph, slot) {
			append(&graph.reborrows, Prov_Reborrow{source = slot, derived = kept[index], span = span, mutable = false})
		}
	}
	if read_only_hold {
		for slot in prov_join(graph, content, kept) {
			graph.prov_slots[slot].read_only_hold = true
		}
	}
	return content, kept, true
}

// design.md "string type conversions", "Dynamic arrays", "Fixed arrays", and
// "Variadic parameters": a `string` read as a `string_view`, a `[dynamic]T` or
// `[N]T` as a `[]T`, or a `T` a `..^T` pack lends as a `^T`, borrows the owner it
// came from, or the temporary that holds it. A constant viewed in its read-only
// storage borrows nothing, which a `..^T` pack's is only when it is materialized:
// an unnamed one is lent from a temporary of its call.
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
		if base_is_const(base) {
			return loans
		}
		return prov_join(graph, loans, prov_borrow(graph, root, path, false, span, noun))
	}
	// Reached through a pointer or view: the view borrows what that names.
	if carriers, _, through := prov_read_through_carrier(graph, e); through {
		return carriers
	}
	loans := walk_flow_expr(graph, e)
	static :=base_is_const(base) && (underlying_kind(graph.k.c, viewed) != .Pointer || materialization_of(graph.k.c, e) != nil)
	if static || !base_is_const(base) && !prov_expr_is_temporary(e) {
		return loans
	}
	return prov_join(graph, loans, prov_borrow(graph, prov_temp_root_of(graph, e, loans), nil, false, span, noun))
}

// A slice whose elements hold no borrows, or a pointer to such a value, which
// printing it, or a read-only `dyn` view of it, reads as a `[]T` or `^T` is read:
// nothing it calls can write through it. A distinct type's own `format` is left out,
// as it takes the value and may write what it names; what it generates only reads.
@(private = "file")
prov_type_is_plain_view :: proc(c: ^Compiler, type: Type_Id) -> bool {
	#partial switch underlying_kind(c, type) {
	case .Slice, .Pointer:
	case:
		return false
	}
	return !type_has_written_format(c, type) && !type_carries_borrow(c, underlying_info(c, type).element).any
}

// A plain view converted to a read-only carrier, as `(dyn Shape)(b)`, only reads it, as
// one erased implicitly does (`prov_read_only_view`), so two such views of a mutable
// carrier may be live together. False when `v` is no such conversion.
@(private)
prov_read_only_conversion :: proc(graph: ^Flow_Graph, v: ^Expr_Call) -> ([]int, bool) {
	c := graph.k.c
	type := prov_type(graph, v)
	if len(v.bound) != 1 || v.bound[0] == nil || !type_is_carrier(c, type) || type_carries_borrow(c, type).mutable {
		return nil, false
	}
	e := v.bound[0]
	span := expr_span(e)
	if ident, plain := prov_plain_view_local(graph, e); plain {
		return prov_reborrow_traversal(graph, prov_read_ident(graph, ident, reads_only = true), span, false), true
	}
	if prov_plain_view_place(graph, e, prov_type(graph, e)) {
		return prov_reborrow_traversal(graph, prov_read_carrier(graph, e, true), span, false), true
	}
	return nil, false
}

// A local holding a plain view (`prov_type_is_plain_view`).
@(private = "file")
prov_plain_view_local :: proc(graph: ^Flow_Graph, e: Expr) -> (^Expr_Ident, bool) {
	ident, type, ok := prov_view_local(graph, e)
	if !ok {
		return nil, false
	}
	return ident, prov_type_is_plain_view(graph.k.c, type)
}

// A field or element of a local read as `type`, a plain view
// (`prov_type_is_plain_view`).
@(private = "file")
prov_plain_view_place :: proc(graph: ^Flow_Graph, e: Expr, type: Type_Id) -> bool {
	if expr_base(e) == nil || prov_repr(graph, e).view_from != INVALID_TYPE || type == INVALID_TYPE {
		return false
	}
	if _, is_ident := e.(^Expr_Ident); is_ident {
		return false
	}
	if !prov_type_is_plain_view(graph.k.c, type) {
		return false
	}
	_, _, place := prov_place_of(graph, e)
	return place
}

// The ordinary walk with the erasure hook suppressed.
@(private = "file")
walk_flow_expr_erased :: proc(graph: ^Flow_Graph, e: Expr) -> []int {
	prov_begin_conversion(graph, e, .Erasure)
	defer prov_end_conversion(graph)
	return walk_flow_expr(graph, e)
}

// ------------------------------------------------------------- places --

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
		if type_indexes_through_view(graph.k.c, prov_value(graph, carrier).type) {
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
// reading the carriers (`Prov_Through_Borrow.walk_reads`).
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
		prov_read_through(graph, carriers, hops[0].path, expr_span(place), place)
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

@(private)
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
	captures := prov_indices_may_write(graph.k.c, indices[:]) && !(store && at == 0)
	only := reads_only && !captures
	slots: []int
	if at == len(hops) - 1 {
		if _, _, named := prov_place_of(graph, carrier); named {
			own := make([dynamic]Expr, 0, 0, graph.alloc)
			prov_segment_indices(carrier, nil, &own)
			from := prov_next_event(graph)
			slots = prov_read_carrier(graph, carrier, only)
			if !prov_indices_may_write(graph.k.c, own[:]) {
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
			graph, outer, hops[at + 1].path, prov_type(graph, carrier), expr_span(carrier), reads_only = loads,
			place = carrier,
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
		prov_def_copy(graph, derived, slot, span)
		append(&graph.reborrows, Prov_Reborrow{source = slot, derived = derived, span = span, mutable = false})
		append(&out, derived)
	}
	return out[:]
}

// An index that may run a program's code may write the carrier being indexed.
@(private)
prov_indices_may_write :: proc(c: ^Compiler, indices: []Expr) -> bool {
	for index in indices {
		if prov_expr_may_write(c, index) {
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

@(private)
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
		if len(v.bound) == 0 && underlying_kind(graph.k.c, prov_type(graph, v.operand)) == .Map {
			// A map index hashes its key and compares it with the stored ones.
			prov_key_effects(graph, prov_type(graph, v.operand), v.span)
			if publish_map_keys && len(v.indices) == 1 {
				prov_publish_map_key(graph, v, key_sources)
			}
		}
	}
}

// Assigning through a map place may insert its key; an existing equal key stays,
// so the key dependency joins.
@(private = "file")
prov_publish_map_key :: proc(graph: ^Flow_Graph, v: ^Expr_Index, key_sources: []int) {
	map_type := prov_type(graph, v.operand)
	key_type := underlying_info(graph.k.c, map_type).key
	prov_copy_effects(graph, key_type, v.span)
	prov_retain_escape(graph, v.operand, key_sources, v.span)
	root, path, ok := prov_place_of(graph, v.operand)
	if !ok {
		prov_store_map_key_region(graph, prov_input_value(graph, v.operand), prov_input_value(graph, v.indices[0]))
		// Reached through a carrier: publish to what it may name.
		if through := prov_retain_through_carrier(graph, v.operand); len(through) > 0 {
			prov_reborrow(graph, key_sources, key_type)
			prov_emit(graph, Prov_Event {
				kind = .Publish, span = v.span, sources = key_sources, into = through,
			})
		}
		return
	}
	entry := prov_extend(graph, path, prov_map_entry_step(graph, map_type, v.indices[0]))
	written := prov_extend(graph, entry, proj_field(PROJ_MAP_KEY))
	prov_event(graph, Prov_Event_Key_Escape{prov_input_value(graph, v.indices[0]), expr_span(v.indices[0]), graph.roots[int(root)].symbol, prov_owner_name(graph, v.indices[0])})
	prov_define_value_regions(graph, root, written, prov_input_value(graph, v.indices[0]))
	if content := prov_content_at(graph, root, written); len(content) > 0 {
		prov_define_content(graph, content, key_sources, v.span, written, key_type, true)
	}
}

@(private)
prov_const_int :: proc(graph: ^Flow_Graph, e: Expr) -> (i64, bool) {
	base := expr_base(e)
	if base == nil || base.const_value.kind != .Integer {
		return 0, false
	}
	return bi_to_i64(graph.k.c, base.const_value.integer)
}

// A slice's optional constant bound, `default` when it is not written.
@(private = "file")
prov_const_bound :: proc(graph: ^Flow_Graph, e: Expr, default: i64) -> (i64, bool) {
	if e == nil {
		return default, true
	}
	return prov_const_int(graph, e)
}

@(private = "file")
prov_range_step :: proc(graph: ^Flow_Graph, v: ^Expr_Slice) -> Proj_Step {
	low, low_ok := prov_const_bound(graph, v.lo, 0)
	high, high_ok := i64(0), false
	if v.hi != nil {
		high, high_ok = prov_const_int(graph, v.hi)
	} else if info := underlying_info(graph.k.c, prov_type(graph, v.operand)); info != nil && info.kind == .Array {
		high, high_ok = i64(info.count), true
	}
	if !low_ok || !high_ok || high <= low {
		return proj_wild()
	}
	return proj_range(low, high)
}

// ------------------------------------------------------- statement hooks --

@(private)
prov_read_ident :: proc(graph: ^Flow_Graph, v: ^Expr_Ident, reads_only := false) -> []int {
	if root := prov_root_for_symbol(graph, v.symbol); root != NO_ROOT {
		prov_access(graph, root, nil, .Read, v.span, reads_only = reads_only)
	}
	if slot, is_carrier := prov_slot_for_symbol(graph, v.symbol); is_carrier {
		sources := prov_one(graph, slot)
		prov_emit(graph, Prov_Event {
			kind = .Live, sources = sources, span = v.span, reads_only = reads_only,
		})
		return sources
	}
	if content := prov_content_slots(graph, v.symbol); len(content) > 0 {
		prov_emit(graph, Prov_Event{kind = .Live, sources = content, span = v.span, reads_only = reads_only})
		return content
	}
	return nil
}

@(private)
prov_invalidate :: proc(graph: ^Flow_Graph, place: Expr, span: Span, verb: string) -> (carriers: []int, below: []Proj_Step, through: bool) {
	if root, path, ok := prov_place_of(graph, place); ok {
		prov_walk_subscripts(graph, place)
		prov_access(graph, root, path, .Invalidate, span, verb)
		return
	}
	walk_flow_expr(graph, place)
	return prov_write_through_place(graph, place, span)
}

// A borrow of `operand` as a place, for `&operand` and `return inout operand`.
@(private)
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
		if loans, through := prov_borrow_through(graph, operand, mutable, span, what); through {
			return loans
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

// design.md "Weakening and reborrows": a borrow of a place reached through
// carriers is a place loan of it, read-only or mutable, which an access through
// any carrier naming that storage at an overlapping place conflicts with while
// the borrow is in use. A read-only borrow only reads the carriers it goes
// through, which another read-only reborrow of them allows; a mutable one writes
// what it borrows, which covers the read. A read-only destination weakens a
// mutable one (`prov_through_marker`). A slice, given as `bounds`, has its
// bounds evaluated after the carriers. False when `place` is reached through no
// carrier.
@(private = "file")
prov_borrow_through :: proc(graph: ^Flow_Graph, place: Expr, mutable: bool, span: Span, what: string, bounds: ^Expr_Slice = nil) -> (loans: []int, through: bool) {
	walk := make([dynamic]Prov_Event_At, 0, 0, graph.alloc)
	carriers, below, reached := prov_read_through_carrier(graph, place, reads_only = !mutable, walk = &walk, reads = !mutable)
	if !reached {
		return nil, false
	}
	if bounds != nil {
		prov_walk_slice_bounds(graph, bounds)
	}
	at, end := -1, -1
	if mutable {
		at = prov_write_through(graph, carriers, below, span, "mutable borrow", place)
		end = at < 0 ? -1 : prov_next_event(graph)
	}
	held := prov_next_event(graph)
	prov_use_held(graph, carriers, below, prov_type(graph, place), span, !mutable)
	prov_note_walk_reads(graph, &walk, held)
	marker := prov_through_marker(graph, at, end, walk[:])
	return prov_join(graph, prov_place_loan(graph, carriers, below, mutable, what, place, borrows = true), marker), true
}

// A slot standing for a borrow through carriers (`Prov_Through_Borrow`):
// its `.Through` events from `at` up to `end`, -1 for both when it writes
// nothing, and the reads of the carriers it went through. Weakened to a read-only
// destination, as `look(&mut p[0])` passes it, the borrow writes nothing and only
// reads the carriers, which the slot lets `prov_reborrow` settle.
@(private = "file")
prov_through_marker :: proc(graph: ^Flow_Graph, at, end: int, walk: []Prov_Event_At) -> []int {
	if graph.current == NO_BLOCK {
		return nil
	}
	marker := prov_temp_slot(graph)
	graph.prov_slots[marker].borrow = Prov_Through_Borrow{Prov_Event_At{graph.current, at}, end, walk}
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

@(private = "file")
prov_walk_slice_bounds :: proc(graph: ^Flow_Graph, v: ^Expr_Slice) {
	if v.lo != nil {
		walk_flow_expr(graph, v.lo)
	}
	if v.hi != nil {
		walk_flow_expr(graph, v.hi)
	}
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
		prov_walk_slice_bounds(graph, v)
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
		what := carrier_noun(graph.k.c, prov_type(graph, v))
		if loans, through := prov_borrow_through(graph, v.operand, mutable, v.span, what, v); through {
			return loans
		}
	}
	source: []int
	if ident, plain := prov_plain_slice_local(graph, v.operand); plain && !mutable {
		source = prov_read_ident(graph, ident, reads_only = true) // a read-only view only reads
	} else {
		source = walk_flow_expr(graph, v.operand)
	}
	prov_walk_slice_bounds(graph, v)
	// Reslicing a carrier keeps its loans; slicing an owner also borrows it, and
	// a temporary owner such as `[dynamic]int{1, 2}` ends with its statement
	// unless a local's value extends it.
	if array && prov_expr_is_temporary(v.operand) {
		temporary := prov_borrow(graph, prov_temp_root_of(graph, v.operand, source), nil, mutable, v.span, "slice")
		return prov_join(graph, source, temporary)
	}
	return source
}

// design.md "Slice literals": the hidden array is always extended, an owner
// ending with its block, and a named array's `&mut a[:]` lends as this literal
// lends it. Its content is held by slots of the array's shape, so a store through
// the slice lands in or replaces one element's, and a load reads what it holds
// now. A slice of it holds only its loan.
@(private)
prov_slice_literal :: proc(graph: ^Flow_Graph, literal: ^Expr_Composite, mutable: bool) -> []int {
	span := literal.span
	backing := prov_repr(graph, literal).backing
	storage := prov_storage_id(graph, Written_Storage{temporary = &literal.base, type = backing}, .Slice_Literal)
	root := prov_root_for_storage(graph, storage)
	graph.roots[int(root)].kind = .Slice_Literal
	graph.roots[int(root)].name = "this slice literal"
	slots := graph.roots[int(root)].slots
	if slots == nil {
		slots = prov_temp_content(graph, backing)
		for slot in slots {
			graph.prov_slots[slot].kind = .Literal
			graph.prov_slots[slot].name = "this slice literal's element"
		}
		graph.roots[int(root)].slots = slots
		graph.has_content_load ||= len(slots) > 0
	}
	prov_composite_content(graph, literal, slots, backing)
	// Its elements are dropped with the block's locals, so their drop hooks run
	// there and read what the elements borrow then, even after the slice
	// that viewed them was overwritten (design.md "Temporaries and procedure
	// boundaries").
	graph.roots[int(root)].extended = true
	graph.roots[int(root)].dropped = backing
	for element, index in literal.elements {
		if element.value == nil { continue }
		copies := index < len(literal.element_clones) && literal.element_clones[index]
		prov_define_value_regions(graph, root, {prov_array_element_step(literal, index)}, prov_input_value(graph, element.value), copies = copies)
	}
	append(&graph.in_scope, Flow_Cleanup{kind = .Prov_Root, root = root, span = span})
	// All of the array, as `a[:]` lends it, which tells the elements apart.
	count := underlying_info(graph.k.c, backing).count
	path := count > 0 ? prov_extend(graph, nil, proj_range(0, i64(count))) : nil
	return prov_borrow(graph, root, path, mutable, span, "slice")
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

// A protocol loop's iterator is dropped with the loop, like an extended temporary
// nothing can name.
@(private)
prov_note_iterator_drop :: proc(graph: ^Flow_Graph, s: ^Stmt_Foreach) {
	span := expr_span(s.iterable)
	root := prov_new_root(graph, .Temporary, span, "this iterator")
	graph.roots[int(root)].extended = true
	graph.roots[int(root)].dropped = s.iterator_type
	append(&graph.in_scope, Flow_Cleanup{kind = .Prov_Root, root = root, span = span})
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
	extends := expr_base(e).extended
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
	prov_temp_root_content(graph, root, prov_type(graph, e), content, span)
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

// design.md "Procedure result contracts": a load through a borrow of a temporary
// reads what the temporary holds, as one through a borrow of a named local reads
// the local's content, and never stands for the temporary itself. Its root holds
// `content`, what walking the value gave, in slots of its type's carrier shape, as
// a slice literal's root does (`prov_slice_literal`), so `name(&View{text})`
// borrows what `text` lends and not the `View` that ends with the statement.
@(private = "file")
prov_temp_root_content :: proc(graph: ^Flow_Graph, root: Root_Id, type: Type_Id, content: []int, span: Span) {
	if len(content) == 0 {
		return
	}
	slots := graph.roots[int(root)].slots
	if slots == nil {
		slots = prov_temp_content(graph, type)
		if len(slots) == 0 {
			return
		}
		graph.roots[int(root)].slots = slots
		graph.has_content_load = true
	}
	prov_define_content(graph, slots, content, span, value_type = type)
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
	case ^Expr_Unary:
		return v.resolution.kind == .User_Operator && v.value_category != .Place
	case ^Expr_Slice:
		return v.resolution.kind == .User_Operator && v.value_category != .Place
	case ^Expr_Postfix:
		// A temporary box's payload ends with the box.
		return v.op == .Or_Return || (v.boxed && prov_expr_is_temporary(v.operand))
	case ^Expr_Selector:
		// `pkg.name` is a whole global, not a field of its operand.
		return v.resolution.kind != .Value && prov_expr_is_temporary(v.operand)
	case ^Expr_Index:
		if v.resolution.kind == .User_Operator {
			return v.value_category != .Place
		}
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
		projected := -1
		source: []Proj_Step
		if d.destructure.active {
			projected = prov_destructure_index(graph.k.c, &d.destructure, symbol_index)
			source = prov_extend(graph, nil, proj_field(projected))
		}
		clones := d.destructure.active ? d.destructure.clones : d.value_clones
		prov_declare_region(graph, id, sym, prov_input_value(graph, initializer), projected, symbol_index < len(clones) && clones[symbol_index])
		prov_note_written_alias(graph, id, initializer, source = source)
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
		if !d.destructure.active && initializer != nil {
			prov_note_reslice(graph, slot, initializer)
		}
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
	projected: int,
	copies: bool,
) {
	recorded := prov_effect_active(graph) && prov_effect_symbol_relevant(graph, id)
	if recorded { prov_effect_begin(graph, Prov_Effect_Declare{id, value, projected, copies}) }
	defer prov_effect_end(graph, recorded)
	initializer := prov_value(graph, value).origin
	source: []Proj_Step
	if projected >= 0 {
		source = prov_extend(graph, nil, proj_field(projected))
	}
	initializer_region := Region_Set{}
	if initializer != nil && type_is_carrier(graph.k.c, sym.type) && !type_is_region_provider(graph.k.c, sym.type) {
		initializer_region = prov_storage_region(graph, value)
	} else if initializer != nil {
		initializer_region = prov_result_region_at(graph, value, source)
	}
	// A provider moved in keeps its region, and so its token.
	if initializer != nil && sym.duration == .None && projected < 0 {
		prov_declare_moved_providers(graph, id, value)
	}
	if type_is_region_provider(graph.k.c, sym.type) && sym.duration == .None {
		prov_declare_provider(graph, id, initializer != nil, initializer_region)
		return
	}
	if type_is_carrier(graph.k.c, sym.type) {
		if initializer != nil {
			prov_merge_region_of(graph, id, initializer_region)
		}
		return
	}
	// A record holding an allocator handle keeps its region as an owner does
	// (design.md "Allocator regions and region provenance"), but owns nothing a
	// reset would strand.
	if !prov_type_has_region(graph.k.c, sym.type) {
		return
	}
	set := Region_Set{}
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
		prov_define_value_regions(graph, prov_root_for_symbol(graph, id), nil, value, source, copies, id)
	}
	// An owner copied from a place may be cloned.
	if initializer != nil && clone_may_allocate(graph.k.c, sym.type) && expression_is_borrowed_place(initializer) {
		cloned := prov_destination_allocator(graph, id)
		region_merge(&cloned, initializer_region)
		prov_note_allocator_use(graph, cloned, sym.span, owned = true)
	}
	if !region_is_empty(set) {
		prov_define_region_content(graph, prov_root_for_symbol(graph, id), nil, set, own = true)
	}
	if sym.duration != .None {
		owned := prov_copied_owner_region(graph, value, source, copies, prov_destination_allocator(graph, id))
		region_merge(&owned, set)
		prov_check_lasting_storage(graph, sym, owned)
	}
}

// design.md "Allocator regions and region provenance": a local `mem.Arena` or
// `mem.Scratch` is a region of its own, with what it was initialized from as a
// parent.
@(private = "file")
prov_declare_provider :: proc(graph: ^Flow_Graph, id: Symbol_Id, initialized: bool, initializer_region: Region_Set) {
	prov_merge_region_of(graph, id, prov_provider_region(graph, id))
	if initialized && !region_is_empty(initializer_region) {
		prov_merge_parent(graph, id, initializer_region)
	}
}

// A `static` or `thread_local` local outlives a region the body received or made.
@(private = "file")
prov_check_lasting_storage :: proc(graph: ^Flow_Graph, sym: ^Symbol, owned: Region_Set) {
	if region_is_parameter_backed(owned) || region_has_local(owned) {
		prov_emit(graph, Prov_Event {
			kind   = .Region_Escape,
			span   = sym.span,
			verb   = fmt.aprintf("`%s`", identifier_text(graph.k.c, sym.name), allocator = graph.alloc),
			name   = storage_phrase(sym.duration),
			region = owned,
		})
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

// A destination of a multiple assignment stored through a carrier, read before
// any target is written (`prov_assign`): what `prov_read_through_carrier`
// returned, with each carrier another target redefines held as it was.
@(private = "file")
Prov_Destination :: struct {
	through: []int,
	below:   []Proj_Step,
	reached: bool,
	read:    bool,
}

@(private)
prov_assign :: proc(graph: ^Flow_Graph, s: ^Stmt_Assign, value_loans: [][]int) {
	value_loans := value_loans
	written := prov_assign_redefines(graph, s)
	if len(written) > 0 && value_loans != nil {
		captured := make([][]int, len(value_loans), graph.alloc)
		for loans, index in value_loans {
			captured[index] = prov_capture_slots(graph, loans, written, s.op_span)
		}
		value_loans = captured
	}
	destinations := prov_assign_destinations(graph, s, written)
	permutes := prov_assign_permutes(graph, s)
	clones := s.destructure.active ? s.destructure.clones : s.rhs_clones
	for target, index in s.lhs {
		copies := index < len(clones) && clones[index]
		source: []Proj_Step
		if s.destructure.active { source = {proj_field(prov_destructure_index(graph.k.c, &s.destructure, index))} }
		sources: []int
		value: Expr
		if s.destructure.active {
			value = s.rhs[0]
			if len(value_loans) > 0 {
				sources = prov_destructure_field(
					graph, value_loans[0], &s.destructure, index, prov_type(graph, target), expr_span(target),
				)
			}
		} else if index < len(s.rhs) {
			value = s.rhs[index]
			if index < len(value_loans) {
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
		// design.md "Weakening and reborrows": a reordering leaves each carrier in one
		// place, so what it reads is moved out rather than copied.
		first_reborrow := len(graph.reborrows)
		defer if permutes {
			for &reborrow, at in graph.reborrows {
				read := graph.prov_slots[reborrow.derived].kind == .Temporary && slice.contains(sources, reborrow.derived)
				reborrow.moved ||= read || at >= first_reborrow && slice.contains(sources, reborrow.source)
			}
			for slot in sources {
				graph.prov_slots[slot].moved_out = true
			}
		}
		target_type := prov_type(graph, target)
		if s.op == .Assign {
			// The old value ends first; a provider moved in then joins the local.
			// A destination already moved out holds nothing to drop.
			if index >= len(s.destination_live) || s.destination_live[index] != .Dead {
				prov_drop_effects(graph, target_type, expr_span(target), region = prov_drop_region(graph, target))
			}
			provider_assign_end(graph, target)
			if root := provider_place_root(graph, target); root != INVALID_SYMBOL && value != nil {
				_, path, _ := prov_place_of(graph, target)
				prov_merge_moved_providers(graph, root, prov_input_value(graph, value), path)
			}
		}
		if ident, is_ident := target.(^Expr_Ident); is_ident && s.op == .Assign {
			if value != nil && type_is_region_provider(graph.k.c, target_type) {
				// A provider's own region stays its token; the new value's parent joins
				// the parents it depends on.
				prov_merge_value_region(graph, ident.symbol, prov_input_value(graph, value), source, storage = !s.destructure.active && type_is_carrier(graph.k.c, target_type), provider = true)
			} else if value != nil && prov_type_has_region(graph.k.c, target_type) {
				if !type_is_carrier(graph.k.c, target_type) {
					prov_define_value_regions(graph, prov_root_for_symbol(graph, ident.symbol), nil, prov_input_value(graph, value), source, copies, ident.symbol)
				} else {
					prov_merge_value_region(graph, ident.symbol, prov_input_value(graph, value), source, storage = !s.destructure.active, provider = false)
				}
			}
			prov_note_written_alias(graph, ident.symbol, value, source = source)
			prov_retain_escape(graph, target, sources, expr_span(target))
			prov_drop_use(graph, ident.symbol, expr_span(target))
			prov_invalidate(graph, target, expr_span(target), "assigned")
			if slot, is_carrier := prov_slot_for_symbol(graph, ident.symbol); is_carrier {
				if !s.destructure.active && value != nil {
					prov_note_reslice(graph, slot, value)
				}
				prov_define_one_content(graph, slot, sources, expr_span(target))
			} else if content := prov_content_slots(graph, ident.symbol); len(content) > 0 {
				prov_define_content(graph, content, sources, expr_span(target))
			}
			continue
		}
		prov_retain_escape(graph, target, sources, expr_span(target))
		replaces_read := value != nil && len(s.lhs) == 1 && prov_reads_below(graph.k.c, value, target)
		root, path, place_ok := prov_place_of(graph, target)
		if place_ok && s.op == .Assign {
			prov_note_written_alias(graph, graph.roots[int(root)].symbol, value, path, target_type, source)
		}
		if !place_ok && s.op == .Assign {
			destination := Prov_Destination{}
			if index < len(destinations) { destination = destinations[index] }
			if prov_assign_through_carrier(graph, s, target, value, sources, destination, permutes, replaces_read) {
				continue
			}
		}
		if place_ok {
			// As for a whole local: a record holding only handles keeps their
			// regions too (design.md "Allocator regions and region provenance").
			if value != nil && s.op == .Assign && prov_store_keeps_region(graph.k.c, target_type) {
				prov_define_value_regions(graph, root, path, prov_input_value(graph, value), source, copies, place_root_symbol(target))
			}
			prov_walk_subscripts(graph, target, s.op == .Assign)
			prov_access(graph, root, path, .Write, expr_span(target))
			// design.md "Weakening and reborrows": storing a carrier into itself
			// suspends nothing, and leaves what the place holds as it is.
			stored_back := value != nil && len(s.lhs) == 1 && prov_names_same_place(graph.k.c, value, target)
			if content := prov_content_at(graph, root, path); len(content) > 0 && s.op == .Assign && !stored_back {
				prov_define_content(graph, content, sources, expr_span(target), path, target_type, replaces_read = replaces_read)
			}
			continue
		}
		walk_flow_expr(graph, target)
		if s.op != .Assign {
			prov_write_through_place(graph, target, expr_span(target))
		}
	}
}

// The slots a multiple assignment's targets redefine: a carrier local's own, or
// the content slots of a record local. design.md "Evaluation order": every value
// is evaluated before any write, so a value read from a variable this statement
// also writes, as in `a, b = b, a`, keeps what the variable held then.
@(private = "file")
prov_assign_redefines :: proc(graph: ^Flow_Graph, s: ^Stmt_Assign) -> []int {
	written := make([dynamic]int, 0, len(s.lhs), graph.alloc)
	if len(s.lhs) == 1 {
		return written[:]
	}
	for target in s.lhs {
		if ident, is_ident := target.(^Expr_Ident); is_ident {
			if slot, is_carrier := prov_slot_for_symbol(graph, ident.symbol); is_carrier {
				append(&written, slot)
			} else {
				append(&written, ..prov_content_slots(graph, ident.symbol))
			}
		} else if root, path, place_ok := prov_place_of(graph, target); place_ok {
			append(&written, ..prov_content_at(graph, root, path))
		}
	}
	return written[:]
}

// The destinations are evaluated all before the first write, so a store through a
// carrier another target of this statement redefines, as `p^.head` in
// `p, p^.head = &mut y, p^.tail`, goes where the carrier pointed then (design.md
// "Values that contain borrows").
@(private = "file")
prov_assign_destinations :: proc(graph: ^Flow_Graph, s: ^Stmt_Assign, written: []int) -> []Prov_Destination {
	if len(s.lhs) == 1 || s.op != .Assign {
		return nil
	}
	destinations := make([]Prov_Destination, len(s.lhs), graph.alloc)
	for target, index in s.lhs {
		if _, is_ident := target.(^Expr_Ident); is_ident {
			continue
		}
		if _, _, place_ok := prov_place_of(graph, target); place_ok {
			continue
		}
		through, below, reached := prov_read_through_carrier(graph, target, store = true)
		if reached {
			held := prov_capture_slots(graph, through, written, expr_span(target))
			// A diagnostic about the store names the carrier it went through.
			for slot, at in held {
				if slot != through[at] && graph.prov_slots[slot].name == "" {
					graph.prov_slots[slot].name = graph.prov_slots[through[at]].name
				}
			}
			through = held
		}
		destinations[index] = Prov_Destination{through, below, reached, true}
	}
	return destinations
}

// A store through a carrier, or into what an `inout` result names; false when
// `target` is neither. design.md "Weakening and reborrows": the store reads each
// carrier it goes through, so one read out of another, as `p^^.a` in
// `p^^.a^.value = 3`, uses what a copy of it, as `node := p^^.a`, suspends.
@(private = "file")
prov_assign_through_carrier :: proc(
	graph: ^Flow_Graph, s: ^Stmt_Assign, target, value: Expr, sources: []int, evaluated: Prov_Destination, permutes, replaces_read: bool,
) -> bool {
	destination := evaluated
	if !destination.read {
		destination.through, destination.below, destination.reached = prov_read_through_carrier(graph, target, store = true)
	}
	through, below, reached := destination.through, destination.below, destination.reached
	walked := false
	if !reached {
		through, walked = prov_inout_result_place(graph, target)
	}
	if reached && len(through) == 0 {
		prov_walk_subscripts(graph, target, true)
		return true
	}
	if len(through) == 0 && !walked {
		return false
	}
	if !walked {
		prov_write_through(graph, through, below, expr_span(target), "write", target)
	}
	prov_store_region(graph, prov_input_value(graph, target), prov_input_value(graph, value))
	if !walked {
		prov_walk_subscripts(graph, target, true)
	}
	if len(through) > 0 {
		prov_publish_store(graph, s, target, sources, through, below, permutes, replaces_read)
	}
	if walked {
		prov_emit(graph, Prov_Event{kind = .Live, sources = through, span = expr_span(target)})
		prov_reach(graph, through, expr_span(target))
	}
	return true
}

// design.md "Weakening and reborrows": what a store through the carriers `through`
// leaves where they point.
@(private = "file")
prov_publish_store :: proc(graph: ^Flow_Graph, s: ^Stmt_Assign, target: Expr, sources, through: []int, below: []Proj_Step, permutes, replaces_read: bool) {
	target_type := prov_type(graph, target)
	links := len(sources) > 0
	lands: Prov_Store_Target
	if element, found := prov_view_element_store(graph, target, target_type); found {
		lands = element
	}
	if links {
		// What it read below its target was used by that read, which reports a copy of it
		// in use, so it does not use it again.
		if !replaces_read {
			prov_use_stored(graph, sources, target_type, expr_span(target))
		}
		graph.has_linked_store = true
	}
	publish := Prov_Event {
		kind = .Publish, span = expr_span(target), sources = sources, into = through,
		linked = prov_store_linked(graph.k.c, target_type), store = lands, carried = target_type, links_copies = links,
		replaces_read = replaces_read,
		permutes = permutes, element = prov_local_view_element(graph, target),
		through_element = lands == nil && prov_may_point_at_element(graph, through),
	}
	// design.md "Evaluation order": a destination is evaluated before an
	// earlier target of the same statement is written, so the view it
	// went through is not the one the definitions reaching here made.
	for other in s.lhs {
		if ident, is_ident := other.(^Expr_Ident); is_ident && publish.element.slot > 0 {
			if slot, found := prov_slot_for_symbol(graph, ident.symbol); found && slot + 1 == publish.element.slot {
				publish.element = {}
			}
		}
	}
	// design.md "Values that contain borrows": carriers pointing at
	// one place replace what it holds wherever they name one storage
	// (`publish_into_loan`); a prefix places were merged into is not one.
	offsets, found, merged := prov_value_offset(graph, through)
	paths := prov_offset_paths(graph, offsets) if found && !merged else nil
	if len(paths) == 1 && prov_offsets_agree(graph, through, offsets) && path_is_exact(paths[0]) {
		if path_is_exact(below) {
			publish.path, publish.one_place, publish.place_path = prov_concat_path(graph, paths[0], below), true, paths[0]
			graph.has_replacing_store = true
		} else if lands == nil && publish.linked {
			// It lands only in the slots along the place it names, whose
			// copy is linked to them.
			publish.path, publish.place_path = prov_concat_path(graph, paths[0], below), paths[0]
		}
	}
	if len(sources) > 0 || publish.one_place {
		prov_emit(graph, publish)
	}
}

// A store of `type` that keeps regions in the place it lands in: an owner, an
// allocator handle, or a value holding either, though a carrier's regions are
// what it points at.
@(private = "file")
prov_store_keeps_region :: proc(c: ^Compiler, type: Type_Id) -> bool {
	return type_is_managed(c, type) || type_is_allocator(c, type) ||
		prov_type_has_region(c, type) && !type_is_carrier(c, type)
}

// Whether a multiple assignment only reorders its targets' values, as
// `a[0], a[1] = a[1], a[0]`: each value ends in one place, so nothing is copied
// (`Carrier_Move`).
@(private)
prov_assign_permutes :: proc(graph: ^Flow_Graph, s: ^Stmt_Assign) -> bool {
	if len(s.lhs) < 2 || len(s.lhs) != len(s.rhs) || s.op != .Assign {
		return false
	}
	used := make([]bool, len(s.lhs), graph.alloc)
	next: for value in s.rhs {
		for target, index in s.lhs {
			if !used[index] && prov_names_same_place(graph.k.c, value, target) {
				used[index] = true
				continue next
			}
		}
		return false
	}
	return true
}

// Whether `value` is read out through what `place` holds, as `list.next^.next` for
// `list.next`, so storing it there replaces the carrier it was read through
// (design.md "Weakening and reborrows").
@(private = "file")
prov_reads_below :: proc(c: ^Compiler, value, place: Expr) -> bool {
	at := value
	through := false
	for at != nil {
		if through && prov_names_same_place(c, at, place) {
			return true
		}
		#partial switch v in at {
		case ^Expr_Selector:
			at = v.operand
		case ^Expr_Postfix:
			if v.op != .Caret {
				return false
			}
			at = v.operand
			through = true
		case:
			return false
		}
	}
	return false
}

// Whether two expressions of one assignment name one place. Each is evaluated
// before any write (design.md "Evaluation order"), so the variables they read
// hold one value for both; what could change that between the evaluations is a
// call, an operator, or a map's indexing, none of which this accepts. Two
// expressions it cannot tell the same are taken to be different.
@(private = "file")
prov_names_same_place :: proc(c: ^Compiler, a, b: Expr) -> bool {
	x, y := expr_base(a), expr_base(b)
	if x == nil || y == nil || x.type != y.type {
		return false
	}
	if base_is_const(x) != base_is_const(y) {
		return false
	}
	if base_is_const(x) {
		equal, comparable := fold_comparison(c, .Eq_Eq, x.const_value, y.const_value)
		return comparable && equal
	}
	if conversion_source(x) != INVALID_TYPE || conversion_source(y) != INVALID_TYPE {
		return false
	}
	#partial switch first in a {
	case ^Expr_Ident:
		second, same := b.(^Expr_Ident)
		return same && first.symbol != INVALID_SYMBOL && first.symbol == second.symbol
	case ^Expr_Selector:
		second, same := b.(^Expr_Selector)
		return same && first.resolution.kind == .Field && second.resolution.kind == .Field && first.name.id == second.name.id &&
		       first.operand != nil && second.operand != nil && prov_names_same_place(c, first.operand, second.operand)
	case ^Expr_Postfix:
		second, same := b.(^Expr_Postfix)
		return same && first.op == .Caret && second.op == .Caret && prov_names_same_place(c, first.operand, second.operand)
	case ^Expr_Index:
		second, same := b.(^Expr_Index)
		if !same || len(first.bound) != 0 || len(second.bound) != 0 || len(first.indices) != len(second.indices) ||
		   first.resolution.kind == .User_Operator || second.resolution.kind == .User_Operator ||
		   underlying_kind(c, expr_base(first.operand).type) == .Map ||
		   !prov_names_same_place(c, first.operand, second.operand) {
			return false
		}
		for index, at in first.indices {
			if !prov_names_same_place(c, index, second.indices[at]) {
				return false
			}
		}
		return true
	}
	return false
}

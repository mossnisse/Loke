// The state a provenance graph builds (`Prov_State`), the facts its fixed point
// carries between rounds (`Prov_Facts`), and the event vocabulary the solvers read.
package lokec

import "core:mem"

// The state only the provenance modes build.
Prov_State :: struct {
	input: ^Prov_Input,
	// The conversions the walk is evaluating the sources of (`prov_repr`).
	converting: [dynamic]Prov_Converting,
	roots:          [dynamic]Prov_Root,
	loans:          [dynamic]Prov_Loan,
	prov_slots:     [dynamic]Prov_Slot,
	// Made only by `prov_add_reborrow`, which keeps `reborrow_chains`.
	reborrows:      [dynamic]Prov_Reborrow,
	reborrow_chains: Prov_Reborrow_Chains,
	// The loans of places reached through carriers (`prov_place_loan`), and
	// each one's index by its snapshot slot.
	place_loans:    [dynamic]Prov_Place_Loan,
	place_loan_of:  map[int]int,
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
	// The `chunks_mut` traversals and `split_at_mut` calls, and the index of each
	// by the slots its parts are made in: a traversal's chunk binding
	// (`prov_bind_chunk`), a split's two halves (`prov_divide_halves`).
	divisions:      [dynamic]Prov_Division,
	division_of:    map[int]int,
	// The `&mut` loop bindings, and where a store through each lands
	// (`prov_note_traversal`).
	traversals:     map[Symbol_Id]Prov_Traversal,
	// The slots standing for what the caller storage each parameter loan names
	// holds (`prov_caller_slots`).
	caller_slots:   map[Loan_Id][dynamic]int,
	// Per view parameter's own loan and constant index, the caller slots
	// standing for that one element (`prov_view_element`).
	view_elements:  map[Prov_View_Element][]int,
	// Per view parameter, its root and own loan once `prov_view_parameter_loan`
	// has found them; roots and loans only grow, so a found pair stays first.
	view_parameter_loans: map[Symbol_Id]Prov_View_Parameter_Loan,
	// Each owner's name as diagnostics quote it (`prov_owner_name`).
	owner_names:    map[Symbol_Id]string,
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
	state.place_loan_of = make(map[int]int, allocator)
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
	state.view_parameter_loans = make(map[Symbol_Id]Prov_View_Parameter_Loan, allocator)
	state.owner_names = make(map[Symbol_Id]string, allocator)
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
	state.reborrow_chains = new_prov_reborrow_chains(allocator)
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
	state.task_slots = make(map[Symbol_Id]int, allocator)
	state.task_holds = make(map[Symbol_Id][]int, allocator)
	state.pool_tasks = make(map[Symbol_Id][]Pool_Task, allocator)
	state.spawn_holds = make(map[^Stmt_Spawn]int, allocator)
	state.divisions = make([dynamic]Prov_Division, allocator)
	state.division_of = make(map[int]int, allocator)
	state.parallel_scopes = make([dynamic]Symbol_Id, allocator)
	state.task_sites = make([dynamic]Task_Site, allocator)
	return state
}

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
	// A `chunks_mut` traversal binds its next chunk, so every value in the chunk
	// bound until now is in an earlier one (`Prov_Division`).
	Chunk_Step,
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

// Every kind's fields, kept in an order that leaves almost no padding: the small
// ones are grouped, so a field added should go beside those of its size.
Prov_Event :: struct {
	precision: Precision_Loss,
	kind:    Prov_Kind,
	access:  Access_Kind,
	// `Retain`: the destination's storage kind; `verb` names it.
	retain: Retain_Kind,
	span:    Span,
	slot:    int,
	loan:    Loan_Id,
	sources: []int,
	root:    Root_Id,
	path:    []Proj_Step,
	verb:    string,
	name:    string,
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
	// `Live`: a call's use of what it borrows, which may read whatever they reach.
	hands_on:      bool,
	// Checks nothing when a diagnostic was reported inside its span: it uses again
	// what an expression there used, and one report of that is enough.
	repeats_inner: bool,
	// `Live`: what the storage a call's arguments lend holds, which stays live for
	// the call, though it may read one element and is no use of the others
	// (`with_held_content`, `Slot_Use`). Without `hands_on`, what a measured receiver
	// holds, and so what that storage holds in turn.
	keeps_live:    []int,
	// `Def`: one more than the index of the place loan the slot is the
	// snapshot of, which its value then carries (`Prov_Place_Loan`), or 0.
	place_loan:    int,
	// `Def`: one more than the mark of the part the slot's value is made in
	// (`Prov_Division`), or 0. `Chunk_Step`: one more than the first mark of the
	// traversal stepping.
	division_mark: int,
	// `Publish`: see `Prov_Store_Target`.
	store:         Prov_Store_Target,
	// `Publish`: the type stored, or INVALID_TYPE when not known
	// (`Carrier_Move`).
	carried:       Type_Id,
	// `Task_Start`, `Shared_Effect`: see `Prov_Kind`.
	symbol:        Symbol_Id,
	// `Publish`, `Def`: the value stored was read below the place it replaces, as
	// `cur^.next = cur^.next^.next`. Where that place's old value holds no reborrow, no
	// copy of it outlives the statement, so what was read below it is reached no more
	// and its copies are linked nowhere (`run_links_held_event`).
	replaces_read: bool,
	// `Publish`: part of an assignment that only reorders its targets' values
	// (`prov_assign_permutes`).
	permutes:      bool,
	// `Publish`: `into` hold the source's own loans, as a traversal's do, which what
	// is stored holds only for having been read through them: the source does not
	// come to borrow itself (`prov_publish_traversal`).
	strips:        bool,
	// `Publish`: of a store through a user's iterator's binding, which says nothing
	// of where it lands, so it lands only in slots that could hold `carried`
	// (`Prov_Traversal.lent`).
	lands_by_type: bool,
	// `Load`, `Publish`: its carriers may all point into one element of a view
	// parameter, which the solve settles (`carriers_element`).
	through_element: bool,
	// `Publish`: each carrier it copies is linked as a reborrow to every slot it
	// may land in: one carrier, which `prov_reborrow` links, or a value holding
	// carriers, each on a path of one type, to the slots of that type where it
	// lands (`prov_link_landed`).
	// Any other store through a parameter's loan, and one of such a value landing
	// in another slot, also joins into the parameter itself (`publish_into_loan`).
	linked:        bool,
	// `Publish`: the solve links each carrier it copies to the slots it lands in
	// (`prov_link_landed`), from this store on.
	links_copies:  bool,
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
	// `Publish`: tells its links from another store's (`Prov_Reborrow.from_store`).
	store_id:      int,
	// `Rearrange`: see `Prov_Kind`.
	rearranged:    Carrier_Move,
	// `Load`: the one element of a view parameter it names, whose caller slots it
	// reads when through that loan, instead of those standing for every element.
	// `Load`: what it reads below the storage its carriers name, where one of them
	// points below the whole of it (`prov_load_places`); nil reads `path`.
	load_places:   [][]Proj_Step,
	load_element:  Prov_Element_Slots,
	// `Def` of a named slot: one more than the index of its definition in
	// `view_defs` (`prov_note_view`), or 0.
	view_def:      int,
	// `Through`, the `Def` of a place loan's snapshot, and a `Load` out of or a
	// `Publish` into a local view: the constant element of a named view the place
	// is in (`Prov_View_At`), for a `Publish` one of the range the borrow the view
	// holds lends (`prov_local_view_element`).
	element:       Prov_View_At,
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

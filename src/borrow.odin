// Root and region provenance: the two lifetime analyses design.md specifies
// under "Borrows and lifetimes" and "Allocator regions and region provenance"
// (m5b-plan steps 1-4).
//
// The analyses share `src/cfg.odin`'s control-flow view and its provenance event
// stream, but answer different questions and keep separate lattices:
//
//   root provenance    which storage does this carrier borrow, is that storage
//                      still there, and is every competing access compatible
//   region provenance  which allocator region backs this owner, and does the
//                      owner or a dependant survive a reset of it
//
// Both run after every package body is checked, over a disposable graph rebuilt
// in a read-only provenance mode: replaying M5a's lifecycle actions would
// duplicate its diagnostics and overwrite settled annotations (m5b-plan decision
// "CFG purity").
//
// Which lattice each operation reaches, and why the other one does not
// (m5b-plan step 5). A blank column is a claim, not an omission.
//
//   operation                       root   region  note
//   ------------------------------- ------ ------- ---------------------------
//   `&place`                        yes            mutable loan of the place
//   slicing a place                 yes            capability from the result
//   reslicing a carrier             yes            keeps the source loans
//   slicing a value temporary       yes            hidden array, lexical scope
//   `foreach` over a place          yes            iterator loan, live in body
//   erasure into `any_view`         yes            read-only loan of the subject
//   `dyn` conversion                yes            the pointer's own loans
//   a borrowed parameter            yes            one loan of the caller's root
//   an `inout` parameter/result     yes            aliases the caller's root
//   a user `[:]` result             yes            borrows the receiver
//   reading/writing a place         yes            compatible-access check
//   `move` / `drop` / `exchange`    yes            invalidates the old value
//   full assignment                 yes    yes     invalidates; may escape a region
//   `new` / `new_clone`             yes    yes     allocation root plus its region
//   `free`                          yes            ends one allocation root
//   `free_all`                             yes     ends every root in the region
//   a reset-capable call                    yes     the same effect, propagated
//   an allocator value                      yes     region identity only
//   an owning result with an
//     allocator argument                    yes     no borrow edge at all
//   a call through a procedure
//     value                         yes    yes     conservative in both
//
// Operations absent from both columns are design.md's "What is not checked":
// a carrier stored in a record field, a global or callback state, a retained
// argument, `rawptr`/`[^]T`/unknown `^T`, `core:unsafe`, and cross-thread
// transfer. `tests/run/m5b_trust_boundary.loke` keeps that list executable.
package lokec

import "core:fmt"
import "core:mem"

Root_Id :: distinct int
Loan_Id :: distinct int

NO_ROOT :: Root_Id(-1)
NO_LOAN :: Loan_Id(-1)

// design.md "Storage roots and borrow carriers": a root is a lexical
// variable/temporary, static object, materialized constant, hidden slice-literal
// array, or fresh allocation. `Param` is the caller's storage reached through a
// borrowed parameter: a root this body cannot see but can name.
Root_Kind :: enum u8 {
	Local,
	Slice_Literal,
	Temporary,
	Static,
	Materialized,
	Allocation,
	Param,
	Unknown,
}

// Whether storage of this kind is still there after the procedure returns. A
// lexical local, an ordinary temporary and a hidden slice-literal array are the
// three that end with the frame.
root_outlives_body :: proc(kind: Root_Kind) -> bool {
	#partial switch kind {
	case .Local, .Slice_Literal, .Temporary:
		return false
	}
	return true
}

// How a diagnostic names a root. A lexical root is quoted source text; an
// allocation or a hidden literal array has no name the reader wrote.
root_label :: proc(c: ^Compiler, root: Prov_Root) -> string {
	if root.symbol == INVALID_SYMBOL {
		return root.name
	}
	return fmt.aprintf("`%s`", root.name, allocator = c.semantic_allocator)
}

// The subject of a sentence about a root: its written name when it has one, and
// what kind of storage it is when it does not.
root_phrase :: proc(c: ^Compiler, root: Prov_Root) -> string {
	if root.symbol != INVALID_SYMBOL {
		return root_label(c, root)
	}
	return fmt.aprintf("the %s it borrows", root_kind_text(root.kind), allocator = c.semantic_allocator)
}

root_kind_text :: proc(kind: Root_Kind) -> string {
	switch kind {
	case .Local:         return "local"
	case .Slice_Literal: return "slice literal"
	case .Temporary:     return "temporary"
	case .Static:        return "static-duration storage"
	case .Materialized:  return "materialized constant"
	case .Allocation:    return "allocation"
	case .Param:         return "caller storage"
	case .Unknown:       return "unknown storage"
	}
	return "storage"
}

Prov_Root :: struct {
	kind:   Root_Kind,
	symbol: Symbol_Id,
	span:   Span,
	name:   string,
	// `Param`: the borrowed parameter this root arrived through, which is what a
	// direct call substitutes an actual argument into (m5b-plan step 2).
	param_index: int,
}

// ---------------------------------------------------------- projections --

Proj_Kind :: enum u8 {
	Field,
	// A half-open constant element range. A single index `i` normalises to
	// [i, i+1), so one relation answers index/index, index/range and range/range.
	Range,
	Deref,
	// A dynamic index or range, a union field, an opaque dereference, or
	// user-defined addressing: overlaps every sibling conservatively.
	Wild,
}

Proj_Step :: struct {
	kind: Proj_Kind,
	lo:   i64,
	hi:   i64,
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

// design.md's one rule is about overlapping storage. Two paths into one root
// overlap unless some step proves them disjoint, so a prefix overlaps everything
// below it -- which is what makes whole-root invalidation reach every descendant.
paths_overlap :: proc(a, b: []Proj_Step) -> bool {
	shared := min(len(a), len(b))
	for index in 0 ..< shared {
		if !steps_overlap(a[index], b[index]) {
			return false
		}
	}
	return true
}

@(private = "file")
steps_overlap :: proc(a, b: Proj_Step) -> bool {
	if a.kind == .Wild || b.kind == .Wild || a.kind != b.kind {
		return true // nothing was proven distinct
	}
	switch a.kind {
	case .Field:
		return a.lo == b.lo
	case .Range:
		return a.lo < b.hi && b.lo < a.hi
	case .Deref:
		return true
	case .Wild:
		return true
	}
	return true
}

// ---------------------------------------------------------------- loans --

// One borrow. `mutable` is the capability design.md gives the carrier's type:
// `^T`, `[]mut T` and `inout` exclude competing access, while `[]T`,
// `string_view` and ordinary parameter access permit compatible reads.
Prov_Loan :: struct {
	root:    Root_Id,
	path:    []Proj_Step,
	mutable: bool,
	span:    Span,
	what:    string,
}

// A carrier value the analysis follows: a variable, parameter or expression
// temporary whose value refers to a root. Reaching-loan state is per slot, so
// overwriting one carrier ends only the value that was overwritten.
Prov_Slot :: struct {
	symbol: Symbol_Id,
	name:   string,
	span:   Span,
	// The loan this expression temporary was created with, if it holds a fresh
	// borrow. design.md: "A mutable slice implicitly weakens to a read-only
	// slice", and that conversion is written at the destination, not at the
	// slicing expression, so the capability is settled once the destination is
	// known.
	fresh_loan: Loan_Id,
}

// design.md "Storage roots and borrow carriers" lists the built-in carriers.
// `rawptr` and `[^]T` are deliberately absent: they carry no checked provenance.
type_is_carrier :: proc(c: ^Compiler, type: Type_Id) -> bool {
	if type == INVALID_TYPE {
		return false
	}
	#partial switch type_kind(c, type_underlying(c, type)) {
	case .Pointer, .Slice, .String_View, .CString_View, .Any_View, .Dyn:
		// design.md "C string views": a view from `to_c_view()` is "valid for that
		// complete expression" and "cannot be assigned, returned, or stored", which
		// is exactly what following it as a carrier enforces. One received from
		// foreign code has no owner the compiler knows, so it simply carries no
		// loan — the documented trust boundary, not a second rule.
		return true
	}
	return false
}

// design.md "Capabilities and the one rule": "`^T`, `[]mut T`, and `inout` are
// mutable borrows", while `[]T`, `string_view` and ordinary parameter access are
// immutable ones.
carrier_is_mutable :: proc(c: ^Compiler, type: Type_Id) -> bool {
	#partial switch type_kind(c, type_underlying(c, type)) {
	case .Pointer:
		return true
	case .Slice:
		return slice_is_mutable(c, type)
	}
	return false
}

carrier_noun :: proc(c: ^Compiler, type: Type_Id) -> string {
	#partial switch type_kind(c, type_underlying(c, type)) {
	case .Pointer:     return "pointer"
	case .Slice:       return "slice"
	case .String_View:  return "string view"
	case .CString_View: return "C string view"
	case .Any_View:    return "view"
	case .Dyn:         return "dyn view"
	}
	return "borrow"
}

// ---------------------------------------------------------- regions --

// design.md "Allocator regions and region provenance": "Allocator values have a
// region identity in addition to their allocation procedures and failure
// policy." What the analysis needs from that identity is where it came from: a
// parameter of this body, the process-wide default provider, or somewhere it
// cannot see.
//
// design.md also settles the precision question: "When compile-time
// region-identity analysis cannot prove two allocator values distinct, the
// lifetime check conservatively treats their regions as possibly identical." M5
// has no source-level provider that creates a region, so no two identities are
// ever proven distinct and a reset must assume it ends every tracked region.
//
// ponytail: region identity is flow-insensitive, one entry per allocator
// binding. An allocator variable that is reassigned to a different provider
// merges both identities, which is conservative in the safe direction. Make it
// a proper lattice when M6 gives regions something to be precise about.
Region_Set :: struct {
	// Which `Allocator` parameters of the enclosing body this value may name.
	params:  []bool,
	// The default provider's region, which outlives the whole program.
	default: bool,
	unknown: bool,
}

region_is_parameter_backed :: proc(set: Region_Set) -> bool {
	for value in set.params {
		if value {
			return true
		}
	}
	return false
}

region_is_empty :: proc(set: Region_Set) -> bool {
	return !set.default && !set.unknown && !region_is_parameter_backed(set)
}

region_merge :: proc(into: ^Region_Set, from: Region_Set) {
	for value, index in from.params {
		if value && index < len(into.params) {
			into.params[index] = true
		}
	}
	into.default ||= from.default
	into.unknown ||= from.unknown
}

// ------------------------------------------------------- result summaries --

// design.md "Temporaries and procedure boundaries": "For a direct call to a
// named Loke declaration or generic instantiation, the compiler records a
// result-provenance summary with the declaration. For each result it records two
// independent components when applicable."
//
// This is the root component; the region component joins it in m5b-plan step 3.
// Every field is a *possibility*, so the join is a union and the lattice is
// finite, which is what makes the whole-program fixed point below terminate.
Result_Provenance :: struct {
	// Which borrowed parameters the result may name storage of.
	params:  []bool,
	// Static-duration or materialized storage, which outlives every caller.
	static:  bool,
	// A fresh allocation root, which is what lets a returned pointer reach
	// checked `free`.
	fresh:   bool,
	// Callee-local storage. Returning it is already an error in the callee; the
	// component exists so a caller does not silently believe the result.
	local:   bool,
	unknown: bool,
	// design.md: "an owning result constructed with an allocator parameter
	// derives its region provenance from that allocator argument at the call
	// site." The region component is independent of the root component above:
	// passing one rule does not waive the other.
	region:  Region_Set,
}

Proc_Summary :: struct {
	results: []Result_Provenance,
}

result_summary :: proc(c: ^Compiler, declaration: Symbol_Id, result: int) -> (Result_Provenance, bool) {
	summary, found := c.result_summaries[declaration]
	if !found || result >= len(summary.results) {
		return Result_Provenance{}, false
	}
	return summary.results[result], true
}

// Union of two possibilities. Returns whether the destination grew, which is the
// fixed point's termination signal.
@(private = "file")
merge_provenance :: proc(into: ^Result_Provenance, from: Result_Provenance) -> bool {
	changed := false
	for value, index in from.params {
		if value && index < len(into.params) && !into.params[index] {
			into.params[index] = true
			changed = true
		}
	}
	for value, index in from.region.params {
		if value && index < len(into.region.params) && !into.region.params[index] {
			into.region.params[index] = true
			changed = true
		}
	}
	if from.region.default && !into.region.default { into.region.default, changed = true, true }
	if from.region.unknown && !into.region.unknown { into.region.unknown, changed = true, true }
	if from.static && !into.static   { into.static, changed  = true, true }
	if from.fresh && !into.fresh     { into.fresh, changed   = true, true }
	if from.local && !into.local     { into.local, changed   = true, true }
	if from.unknown && !into.unknown { into.unknown, changed = true, true }
	return changed
}

// ------------------------------------------------------------- the solver --

// Per-body state the lattices share. `reach` is the forward component (which
// loans a carrier slot may hold), `live` the backward one (which slots have a
// later use); a loan is live exactly where a slot that may hold it is.
@(private = "file")
Prov_State :: struct {
	graph:   ^Flow_Graph,
	k:       ^Checker,
	slots:   int,
	loans:   int,
	roots:   int,
	reach:   []bool,
	invalid: []bool,
	live:    []bool,
	uses:    []Span,
	merged:  []bool,
}

@(private = "file")
reach_row :: proc(state: ^Prov_State, buffer: []bool, slot: int) -> []bool {
	return buffer[slot * state.loans:(slot + 1) * state.loans]
}

// One checked concrete body, and whether checking it was clean. A body that
// already failed has unresolved types and missing bindings, so running two more
// analyses over it would report noise about a mistake already reported.
Checked_Body :: struct {
	literal: ^Expr_Proc,
	clean:   bool,
}

// Source order says nothing about the call graph, so summaries are iterated to a
// fixed point rather than solved once per declaration. The lattice is finite and
// every step is a union, so a natural worklist-style iteration terminates without
// imposing a source-visible call-depth limit.

// The whole program's provenance, after every package body and promoted generic
// instance is checked. Summaries settle first, then diagnostics run with actual
// argument roots substituted at direct calls. One disposable graph is built and
// released at a time, so no analysis allocation outlives the body it describes.
analyze_program_provenance :: proc(k: ^Checker) {
	for {
		changed := false
		for body in k.c.checked_bodies {
			if body.clean && summarize_body(k, body.literal) {
				changed = true
			}
		}
		if !changed {
			break
		}
	}
	for body in k.c.checked_bodies {
		if body.clean {
			analyze_provenance(k, body.literal)
		}
	}
}

// One round of one body's result equations. Read-only apart from the summary it
// merges into package metadata.
@(private = "file")
summarize_body :: proc(k: ^Checker, literal: ^Expr_Proc) -> bool {
	sym := symbol_of(k.c, literal.symbol)
	if sym == nil || len(sym.results) == 0 {
		return false
	}
	summary, found := k.c.result_summaries[literal.symbol]
	if !found {
		summary = new(Proc_Summary, k.c.semantic_allocator)
		summary.results = make([]Result_Provenance, len(sym.results), k.c.semantic_allocator)
		for index in 0 ..< len(summary.results) {
			summary.results[index].params = make([]bool, len(sym.param_symbols), k.c.semantic_allocator)
			summary.results[index].region.params = make([]bool, len(sym.param_symbols), k.c.semantic_allocator)
		}
		k.c.result_summaries[literal.symbol] = summary
	}
	defer free_all(k.c.analysis_allocator)
	graph := build_flow_graph(k, literal, k.c.analysis_allocator, .Prov_Summary)
	if graph == nil {
		return false
	}
	state := Prov_State{graph = graph, k = k}
	if !prepare_state(&state) {
		return false
	}
	solve_reaching(&state)
	return collect_escape_provenance(&state, summary)
}

// The equations: every loan that can reach a `return` becomes one possibility in
// that result's summary.
@(private = "file")
collect_escape_provenance :: proc(state: ^Prov_State, summary: ^Proc_Summary) -> bool {
	graph := state.graph
	changed := false
	for block in graph.blocks {
		if !block.prov_visited {
			continue
		}
		copy(state.reach, block.reach_entry)
		copy(state.invalid, block.invalid_entry)
		for event in block.prov {
			if event.kind == .Escape && event.result < len(summary.results) {
				into := &summary.results[event.result]
				if !region_is_empty(event.region) {
					before := into.region
					region_merge(&into.region, event.region)
					if before.default != into.region.default ||
					   before.unknown != into.region.unknown ||
					   !bools_equal(before.params, into.region.params) {
						changed = true
					}
				}
				for source in event.sources {
					for held, index in reach_row(state, state.reach, source) {
						if held && merge_loan_provenance(state, into, graph.loans[index]) {
							changed = true
						}
					}
				}
			}
			run_prov_event(state, event, state.reach, state.invalid)
		}
	}
	return changed
}

@(private = "file")
merge_loan_provenance :: proc(state: ^Prov_State, into: ^Result_Provenance, loan: Prov_Loan) -> bool {
	root := state.graph.roots[int(loan.root)]
	one := Result_Provenance{}
	switch root.kind {
	case .Param:
		if root.param_index >= 0 && root.param_index < len(into.params) {
			if into.params[root.param_index] {
				return false
			}
			into.params[root.param_index] = true
			return true
		}
		one.unknown = true
	case .Static, .Materialized:
		one.static = true
	case .Allocation:
		one.fresh = true
	case .Local, .Slice_Literal, .Temporary:
		one.local = true
	case .Unknown:
		one.unknown = true
	}
	return merge_provenance(into, one)
}

// One concrete body's root and region diagnostics.
analyze_provenance :: proc(k: ^Checker, literal: ^Expr_Proc) {
	defer free_all(k.c.analysis_allocator)
	graph := build_flow_graph(k, literal, k.c.analysis_allocator, .Prov_Diagnose)
	if graph == nil {
		return
	}
	solve_provenance(k, graph)
}

@(private = "file")
solve_provenance :: proc(k: ^Checker, graph: ^Flow_Graph) {
	state := Prov_State{graph = graph, k = k}
	if !prepare_state(&state) {
		return
	}
	solve_reaching(&state)
	solve_loan_liveness(&state)
	report_provenance(&state)
}

// Sizes the per-block lattice storage. False when the body borrows nothing at
// all, so neither rule can fail and neither pass has to run.
@(private = "file")
prepare_state :: proc(state: ^Prov_State) -> bool {
	graph := state.graph
	state.slots = len(graph.prov_slots)
	state.loans = len(graph.loans)
	state.roots = len(graph.roots)
	if state.loans == 0 && !graph.has_region_event {
		return false
	}
	width := max(state.slots * state.loans, 1)
	for block in graph.blocks {
		block.reach_entry = make([]bool, width, graph.alloc)
		block.reach_exit = make([]bool, width, graph.alloc)
		block.invalid_entry = make([]bool, state.loans, graph.alloc)
		block.invalid_exit = make([]bool, state.loans, graph.alloc)
		block.live_entry = make([]bool, max(state.slots, 1), graph.alloc)
		block.live_exit = make([]bool, max(state.slots, 1), graph.alloc)
		block.use_entry = make([]Span, max(state.slots, 1), graph.alloc)
		block.use_exit = make([]Span, max(state.slots, 1), graph.alloc)
		block.prov_visited = false
	}
	state.reach = make([]bool, width, graph.alloc)
	state.invalid = make([]bool, state.loans, graph.alloc)
	state.live = make([]bool, max(state.slots, 1), graph.alloc)
	state.uses = make([]Span, max(state.slots, 1), graph.alloc)
	state.merged = make([]bool, state.loans, graph.alloc)
	return true
}

// Forward: which loans each carrier slot may hold, and which loans an earlier
// invalidation already ended.
@(private = "file")
solve_reaching :: proc(state: ^Prov_State) {
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
		mem.zero_slice(state.invalid)
		if id != 0 {
			seen := false
			for predecessor in block.preds {
				source := graph.blocks[predecessor]
				if !source.prov_visited {
					continue
				}
				for value, index in source.reach_exit {
					state.reach[index] ||= value
				}
				for value, index in source.invalid_exit {
					state.invalid[index] ||= value
				}
				seen = true
			}
			if !seen {
				continue
			}
		} else {
			// A borrowed parameter arrives already holding the caller's root.
			for entry in graph.entry_defs {
				reach_row(state, state.reach, entry.slot)[int(entry.loan)] = true
			}
		}
		copy(block.reach_entry, state.reach)
		copy(block.invalid_entry, state.invalid)
		for event in block.prov {
			run_prov_event(state, event, state.reach, state.invalid)
		}
		if block.prov_visited &&
		   bools_equal(block.reach_exit, state.reach) &&
		   bools_equal(block.invalid_exit, state.invalid) {
			continue
		}
		copy(block.reach_exit, state.reach)
		copy(block.invalid_exit, state.invalid)
		block.prov_visited = true
		for successor in block.succs {
			if !queued[int(successor)] {
				append(&queue, successor)
				queued[int(successor)] = true
			}
		}
	}
}

@(private = "file")
bools_equal :: proc(a, b: []bool) -> bool {
	for value, index in a {
		if value != b[index] {
			return false
		}
	}
	return true
}

@(private = "file")
run_prov_event :: proc(state: ^Prov_State, event: Prov_Event, reach: []bool, invalid: []bool) {
	graph := state.graph
	#partial switch event.kind {
	case .Def:
		mem.zero_slice(state.merged)
		for source in event.sources {
			for value, index in reach_row(state, reach, source) {
				state.merged[index] ||= value
			}
		}
		if event.loan != NO_LOAN {
			// A loan ID names one syntactic creation site, which can execute again
			// after an earlier assignment, reset, or loop iteration invalidated its
			// previous instance. The fresh definition starts a new valid instance;
			// copied definitions keep the invalid state of their source loans.
			invalid[int(event.loan)] = false
			state.merged[int(event.loan)] = true
		}
		copy(reach_row(state, reach, event.slot), state.merged)
	case .Live:
		// Only a loop head's re-read sets this. The loan was created once, before
		// the loop, but it is re-established every iteration, so an invalidation
		// recorded inside the body must not reach the body's own entry through the
		// back edge -- that would hide the very conflict it is evidence of.
		if !event.revives {
			break
		}
		for source in event.sources {
			for held, index in reach_row(state, reach, source) {
				if held {
					invalid[index] = false
				}
			}
		}
	case .Access:
		if event.access != .Invalidate {
			break
		}
		for loan, index in graph.loans {
			if loan.root == event.root && paths_overlap(loan.path, event.path) {
				invalid[index] = true
			}
		}
	case .Root_End:
		for loan, index in graph.loans {
			if loan.root == event.root {
				invalid[index] = true
			}
		}
	case .Reset:
		// An accepted reset ends every allocation root in the region and
		// invalidates all locally tracked aliases of them.
		for loan, index in graph.loans {
			if graph.roots[int(loan.root)].kind == .Allocation {
				invalid[index] = true
			}
		}
	case .Free:
		// Every loan of the released allocation ends, which is what makes a later
		// use of any locally tracked alias diagnosable instead of silently dangling.
		for source in event.sources {
			for held, index in reach_row(state, reach, source) {
				if !held {
					continue
				}
				root := graph.loans[index].root
				for loan, other in graph.loans {
					if loan.root == root {
						invalid[other] = true
					}
				}
			}
		}
	}
}

// Backward: which carrier slots have a later use, and where that use is. A loan
// is live exactly where a slot that may hold it is, which is design.md's
// "creation to its last use", including the last use of every copy.
@(private = "file")
solve_loan_liveness :: proc(state: ^Prov_State) {
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
		for index in 0 ..< len(state.uses) {
			state.uses[index] = no_span()
		}
		for successor in block.succs {
			target := graph.blocks[successor]
			for value, index in target.live_entry {
				if value && !state.live[index] {
					state.live[index] = true
					state.uses[index] = target.use_entry[index]
				}
			}
		}
		copy(block.live_exit, state.live)
		copy(block.use_exit, state.uses)
		for index := len(block.prov) - 1; index >= 0; index -= 1 {
			run_live_event(block.prov[index], state.live, state.uses)
		}
		if bools_equal(block.live_entry, state.live) {
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

@(private = "file")
run_live_event :: proc(event: Prov_Event, live: []bool, uses: []Span) {
	#partial switch event.kind {
	case .Def:
		// A full overwrite ends the value that was there, not the variable: the
		// sources are read first, and their own `Live` events precede this one.
		live[event.slot] = false
	case .Live, .Escape, .Free:
		for source in event.sources {
			live[source] = true
			uses[source] = event.span
		}
	}
}

// ------------------------------------------------------------ reporting --

@(private = "file")
report_provenance :: proc(state: ^Prov_State) {
	graph := state.graph
	for block in graph.blocks {
		if !block.prov_visited || len(block.prov) == 0 {
			continue
		}
		count := len(block.prov)
		// Liveness *after* each event, replayed from this block's exit state, so a
		// conflict can name the later use that keeps the loan alive.
		live_after := make([][]bool, count, graph.alloc)
		use_after := make([][]Span, count, graph.alloc)
		live := make([]bool, max(state.slots, 1), graph.alloc)
		uses := make([]Span, max(state.slots, 1), graph.alloc)
		copy(live, block.live_exit)
		copy(uses, block.use_exit)
		for index := count - 1; index >= 0; index -= 1 {
			live_after[index] = make([]bool, max(state.slots, 1), graph.alloc)
			use_after[index] = make([]Span, max(state.slots, 1), graph.alloc)
			copy(live_after[index], live)
			copy(use_after[index], uses)
			run_live_event(block.prov[index], live, uses)
		}

		copy(state.reach, block.reach_entry)
		copy(state.invalid, block.invalid_entry)
		for event, index in block.prov {
			check_prov_event(state, event, live_after[index], use_after[index])
			run_prov_event(state, event, state.reach, state.invalid)
		}
	}
}

// Whether a live loan and one access to its root are compatible. design.md: an
// immutable borrow permits compatible reads; a mutable borrow excludes every
// competing access.
@(private = "file")
access_conflicts :: proc(loan: Prov_Loan, event: Prov_Event) -> bool {
	if loan.root != event.root || !paths_overlap(loan.path, event.path) {
		return false
	}
	return event.access != .Read || loan.mutable
}

@(private = "file")
check_prov_event :: proc(state: ^Prov_State, event: Prov_Event, live: []bool, uses: []Span) {
	graph := state.graph
	#partial switch event.kind {
	case .Access:
		for slot in 0 ..< state.slots {
			if !live[slot] {
				continue
			}
			for held, index in reach_row(state, state.reach, slot) {
				if !held || state.invalid[index] {
					continue
				}
				loan := graph.loans[index]
				if !access_conflicts(loan, event) {
					continue
				}
				report_borrow_conflict(state, event, loan, uses[slot])
				return
			}
		}
	case .Root_End:
		for slot in 0 ..< state.slots {
			if !live[slot] {
				continue
			}
			for held, index in reach_row(state, state.reach, slot) {
				if !held || state.invalid[index] {
					continue
				}
				loan := graph.loans[index]
				if loan.root != event.root {
					continue
				}
				report_root_outlived(state, event, loan, uses[slot])
				return
			}
		}
	case .Escape:
		// design.md: "A borrow derived from a local root cannot be returned."
		// Static, materialized and freshly allocated roots are all still there
		// when the caller resumes, and unknown provenance is not evidence of a
		// failure -- only an operation that needs a proof rejects it.
		for source in event.sources {
			for held, index in reach_row(state, state.reach, source) {
				if !held || state.invalid[index] {
					continue
				}
				loan := graph.loans[index]
				root := graph.roots[int(loan.root)]
				if root_outlives_body(root.kind) {
					continue
				}
				errorf(
					state.k.c,
					event.span,
					"L0526",
					"this %s cannot be returned: %s ends when this procedure returns",
					loan.what,
					root_phrase(state.k.c, root),
				)
				if root.symbol != INVALID_SYMBOL && root.span.file != NO_FILE {
					add_notef(state.k.c, root.span, "%s is declared here", root_label(state.k.c, root))
				}
				add_notef(state.k.c, loan.span, "the %s is created here", loan.what)
				return
			}
		}
	case .Reset:
		check_region_reset(state, event, live, uses)
	case .Region_Escape:
		// design.md: an owner "backed by a region created in the current
		// procedure may not be ... assigned to `static`, `thread_local`, or
		// file-scope storage". A bare pointer, slice or view stored the same way
		// is the documented v1 trust boundary and is deliberately not checked.
		errorf(
			state.k.c,
			event.span,
			"L0536",
			"`%s` is backed by an allocator region this procedure received, so it cannot be stored in %s, which outlives that region",
			event.verb,
			event.name,
		)
	case .Free:
		if roots, ok := check_free_provenance(state, event); ok {
			// design.md: `free` "invalidates every locally tracked pointer or view
			// of that allocation", so a surviving alias is the error, not the
			// dangling read it would later perform.
			for root in roots {
				report_live_dependants(state, root, event.span, live, uses, "released")
			}
		}
	}
}


// design.md: "The compiler rejects `free_all`, or any call carrying the same
// allocator-reset effect, while a live owning value (managed or manual) or
// borrow still refers to storage from that allocator."
//
// Two independent questions. First, may this body reset this region at all --
// design.md: "It may not hide a reset of a global or other pre-existing
// allocator: such an allocator is taken through an `@(allocator_reset)`
// parameter instead." Second, would anything survive the reset.
@(private = "file")
check_region_reset :: proc(state: ^Prov_State, event: Prov_Event, live: []bool, uses: []Span) {
	graph := state.graph
	if event.access == .Invalidate && !event.reset_covered {
		// The direct form: `free_all` on a region that existed before entry.
		errorf(
			state.k.c,
			event.span,
			"L0538",
			"this resets a region that existed before the call, so the allocator must arrive through an `@(allocator_reset)` parameter",
		)
		return
	}
	if event.access == .Write && !event.reset_covered {
		// The transitive form: handing one of this body's own allocator
		// parameters to a reset-capable procedure resets a caller's region.
		if event.name != "" {
			errorf(
				state.k.c,
				event.span,
				"L0538",
				"this call may reset `%s`, so `%s` must be marked `@(allocator_reset)`",
				event.name,
				event.name,
			)
		} else {
			errorf(
				state.k.c,
				event.span,
				"L0538",
				"this call may reset a pre-existing or unknown allocator region, so the reset cannot be hidden in this procedure",
			)
		}
		return
	}
	// A locally tracked owner that still needs its cleanup would run that cleanup
	// over released storage.
	if event.verb != "" {
		errorf(
			state.k.c,
			event.span,
			"L0537",
			"this reset would end the region backing `%s`, which is still live here",
			event.verb,
		)
		add_notef(state.k.c, event.owner_span, "`%s` is declared here and is cleaned up after this point", event.verb)
		return
	}
	// design.md: the proof is that no dependant survives the reset, not that
	// every allocation was already freed. An allocation whose carriers have no
	// later use is simply released by it.
	for slot in 0 ..< state.slots {
		if !live[slot] {
			continue
		}
		for held, index in reach_row(state, state.reach, slot) {
			if !held || state.invalid[index] {
				continue
			}
			loan := graph.loans[index]
			if graph.roots[int(loan.root)].kind != .Allocation {
				continue
			}
			errorf(
				state.k.c,
				event.span,
				"L0537",
				"this reset ends every allocation in the region, but a %s of one of them is still in use",
				loan.what,
			)
			add_notef(state.k.c, loan.span, "the %s is created here", loan.what)
			if uses[slot].file != NO_FILE {
				add_notef(state.k.c, uses[slot], "and is still used here, which keeps it live")
			}
			return
		}
	}
}

// Any loan of `root` that still has a later use when `root` ends here.
@(private = "file")
report_live_dependants :: proc(
	state: ^Prov_State,
	root: Root_Id,
	span: Span,
	live: []bool,
	uses: []Span,
	verb: string,
) {
	graph := state.graph
	for slot in 0 ..< state.slots {
		if !live[slot] {
			continue
		}
		for held, index in reach_row(state, state.reach, slot) {
			if !held || state.invalid[index] {
				continue
			}
			loan := graph.loans[index]
			if loan.root != root {
				continue
			}
			descriptor := graph.roots[int(root)]
			errorf(
				state.k.c,
				span,
				"L0512",
				"%s cannot be %s here: a %s of it is still in use",
				root_label(state.k.c, descriptor),
				verb,
				loan.what,
			)
			add_borrow_notes(state, descriptor, loan, uses[slot])
			return
		}
	}
}

@(private = "file")
report_borrow_conflict :: proc(state: ^Prov_State, event: Prov_Event, loan: Prov_Loan, later: Span) {
	k := state.k
	root := state.graph.roots[int(loan.root)]
	if event.access == .Invalidate {
		errorf(
			k.c,
			event.span,
			"L0512",
			"%s cannot be %s here: a %s %s of it is still in use",
			root_label(k.c, root),
			event.verb == "" ? "invalidated" : event.verb,
			loan.mutable ? "mutable" : "read-only",
			loan.what,
		)
	} else {
		errorf(
			k.c,
			event.span,
			"L0511",
			"this %s of %s is not compatible with the %s %s of it that is still in use",
			event.access == .Write ? "write" : "read",
			root_label(k.c, root),
			loan.mutable ? "mutable" : "read-only",
			loan.what,
		)
	}
	add_borrow_notes(state, root, loan, later)
}

@(private = "file")
report_root_outlived :: proc(state: ^Prov_State, event: Prov_Event, loan: Prov_Loan, later: Span) {
	k := state.k
	root := state.graph.roots[int(loan.root)]
	label := root_label(k.c, root)
	// The storage ends at a closing brace the reader did not write an operation
	// at, so the use that needs it is the actionable place to point.
	errorf(
		k.c,
		later.file == NO_FILE ? event.span : later,
		"L0513",
		"this %s is used after %s, the %s it borrows, has ended",
		loan.what,
		label,
		root_kind_text(root.kind),
	)
	if root.span.file != NO_FILE {
		add_notef(k.c, root.span, "%s is declared here and ends with its scope", label)
	}
	add_notef(k.c, loan.span, "the %s is created here", loan.what)
}

// design.md: "The diagnostic must name the root, the borrow's creation, the
// conflicting or invalidating operation, and the later use that keeps the borrow
// live." The operation itself is the primary span.
@(private = "file")
add_borrow_notes :: proc(state: ^Prov_State, root: Prov_Root, loan: Prov_Loan, later: Span) {
	k := state.k
	// An anonymous root has no declaration of its own: the creation note below
	// already points at the operation that made it.
	if root.symbol != INVALID_SYMBOL && root.span.file != NO_FILE {
		add_notef(
			k.c,
			root.span,
			"%s is the %s this %s borrows",
			root_label(k.c, root),
			root_kind_text(root.kind),
			loan.what,
		)
	}
	add_notef(k.c, loan.span, "the %s is created here", loan.what)
	if later.file != NO_FILE {
		add_notef(k.c, later, "and is still used here, which keeps it live")
	}
}

// design.md: `free` "ends the allocation root designated by a checked base
// pointer from `new` or `new_clone`". M5a accepted only a direct result binding;
// propagated provenance replaces that narrowing with the real question.
@(private = "file")
check_free_provenance :: proc(state: ^Prov_State, event: Prov_Event) -> ([]Root_Id, bool) {
	graph := state.graph
	found := 0
	roots := make([dynamic]Root_Id, graph.alloc)
	for source in event.sources {
		for held, index in reach_row(state, state.reach, source) {
			if !held {
				continue
			}
			if state.invalid[index] {
				errorf(state.k.c, event.span, "L0514", "this allocation has already been released")
				add_notef(state.k.c, graph.loans[index].span, "the pointer is created here")
				return nil, false
			}
			found += 1
			base := graph.loans[index]
			root := graph.roots[int(base.root)]
			if root.kind != .Allocation {
				errorf(
					state.k.c,
					event.span,
					"L0514",
					"`free` releases an allocation from `new` or `new_clone`; this pointer may designate %s",
					root_kind_text(root.kind),
				)
				add_notef(state.k.c, base.span, "this possible pointer is created here")
				return nil, false
			}
			if len(base.path) != 0 {
				errorf(
					state.k.c,
					event.span,
					"L0514",
					"`free` takes the allocation base pointer, not a pointer that may be derived from it",
				)
				add_notef(state.k.c, base.span, "this possible pointer is created here")
				return nil, false
			}
			already := false
			for candidate in roots {
				already ||= candidate == base.root
			}
			if !already {
				append(&roots, base.root)
			}
		}
	}
	if found == 0 {
		errorf(
			state.k.c,
			event.span,
			"L0514",
			"`free` needs a pointer whose allocation root the compiler can see; this one has unknown provenance",
		)
		return nil, false
	}
	return roots[:], true
}

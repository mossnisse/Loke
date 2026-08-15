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
	case .Pointer, .Slice, .String_View, .Any_View, .Dyn:
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
	case .String_View: return "string view"
	case .Any_View:    return "view"
	case .Dyn:         return "dyn view"
	}
	return "borrow"
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
// every step is a union, so this terminates; the bound is a safety net against a
// non-monotone mistake, not a documented depth limit.
PROVENANCE_SUMMARY_ROUNDS :: 32

// The whole program's provenance, after every package body and promoted generic
// instance is checked. Summaries settle first, then diagnostics run with actual
// argument roots substituted at direct calls. One disposable graph is built and
// released at a time, so no analysis allocation outlives the body it describes.
analyze_program_provenance :: proc(k: ^Checker) {
	for _ in 0 ..< PROVENANCE_SUMMARY_ROUNDS {
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
	if state.loans == 0 {
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
			state.merged[int(event.loan)] = true
		}
		copy(reach_row(state, reach, event.slot), state.merged)
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
	case .Free:
		if base, ok := check_free_provenance(state, event); ok {
			// design.md: `free` "invalidates every locally tracked pointer or view
			// of that allocation", so a surviving alias is the error, not the
			// dangling read it would later perform.
			report_live_dependants(state, base.root, event.span, live, uses, "released")
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
check_free_provenance :: proc(state: ^Prov_State, event: Prov_Event) -> (Prov_Loan, bool) {
	graph := state.graph
	found := 0
	base := Prov_Loan{}
	for source in event.sources {
		for held, index in reach_row(state, state.reach, source) {
			if !held {
				continue
			}
			if state.invalid[index] {
				errorf(state.k.c, event.span, "L0514", "this allocation has already been released")
				add_notef(state.k.c, graph.loans[index].span, "the pointer is created here")
				return base, false
			}
			found += 1
			base = graph.loans[index]
		}
	}
	if found == 0 {
		errorf(
			state.k.c,
			event.span,
			"L0514",
			"`free` needs a pointer whose allocation root the compiler can see; this one has unknown provenance",
		)
		return base, false
	}
	root := graph.roots[int(base.root)]
	if root.kind != .Allocation {
		errorf(
			state.k.c,
			event.span,
			"L0514",
			"`free` releases an allocation from `new` or `new_clone`; this pointer designates %s",
			root_kind_text(root.kind),
		)
		add_notef(state.k.c, base.span, "the pointer is created here")
		return base, false
	}
	if len(base.path) != 0 {
		errorf(
			state.k.c,
			event.span,
			"L0514",
			"`free` takes the allocation base pointer, not a pointer derived from it",
		)
		add_notef(state.k.c, base.span, "the pointer is created here")
		return base, false
	}
	return base, true
}

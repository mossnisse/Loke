// Ownership: `move`, explicit `drop`, and the liveness that decides where the
// compiler drops a managed local (m5a-plan step 4).
//
// design.md "Managed values and storage": "The compiler performs dataflow
// analysis and classifies a lexical local as definitely live, definitely dead,
// or conditionally live at each program point. A use that requires a value is
// valid only in the definitely-live state."
//
// Both halves of that live here. `move` and `drop` are compiler special forms
// over a storage location rather than ordinary calls, so they are checked as
// syntax; the classification itself runs once per concrete body over the
// `src/cfg.odin` view, after the body is checked and every node has its type.
//
// The analysis writes two facts back onto each local's symbol: whether scope
// exit drops it at all, and whether it reaches its scope exits in the same
// state on every path. Only the second case needs a runtime flag, which is what
// keeps "no source or ABI rule requires a flag" true for the ordinary local.
package lokec

import "core:fmt"
import "core:mem"

// ------------------------------------------------------ the special forms --

// design.md "Assignment statements": "`move(value)` transfers ownership without
// a copy. The operation writes the inert zero representation to the lexical
// source and marks it dead until a later full assignment."
check_move :: proc(k: ^Checker, v: ^Expr_Move) {
	v.value_category = .Value
	operand := check_single_expr(k, v.value)
	if operand == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}
	v.type = operand
	if !require_lexical_owner(k, v.value, "move") {
		v.type = INVALID_TYPE
	}
}

// design.md "Storage modifiers": `drop(value)` "runs the cleanup operation,
// writes the inert zero representation, and marks the variable dead".
check_drop_builtin :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident) {
	v.type = TYPE_VOID
	v.value_category = .Value
	if len(v.args) != 1 || v.args[0].name.text != "" || v.args[0].mode != .Value {
		errorf(k.c, v.span, "L0496", "`drop` takes one argument, the variable being cleaned up")
		v.type = INVALID_TYPE
		return
	}
	if check_single_expr(k, v.args[0].value) == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}
	if !require_lexical_owner(k, v.args[0].value, "drop") {
		v.type = INVALID_TYPE
		return
	}
	bound := make([]Expr, 1, k.c.semantic_allocator)
	bound[0] = v.args[0].value
	v.bound = bound
}

// design.md: "The operand of `drop` must name a variable. Like `move`, `drop`
// operates on a storage location", it "cannot operate directly on a field, an
// element, or a map entry", and applying either "to file-scope, `static`, or
// `thread_local` storage, or to a subplace rooted in such storage, is a
// compile-time error".
require_lexical_owner :: proc(k: ^Checker, e: Expr, form: string) -> bool {
	ident, is_ident := e.(^Expr_Ident)
	sym := is_ident ? symbol_of(k.c, ident.symbol) : nil
	if sym == nil || (sym.kind != .Var && sym.kind != .Parameter && sym.kind != .Result) {
		errorf(
			k.c,
			expr_span(e),
			"L0497",
			"`%s` names a variable; move the owner out of the aggregate first, or %s the whole value",
			form,
			form,
		)
		return false
	}
	// design.md: "A binding with static storage duration is always live after
	// this initialization. `move` and explicit `drop` are forbidden on it and on
	// a subplace rooted in it; otherwise one procedure could make the binding dead
	// while another procedure accessed it."
	if (sym.decl != nil && sym.decl.top_level) || sym.duration != .None {
		errorf(
			k.c,
			expr_span(e),
			"L0498",
			"`%s` cannot be applied to %s, which is always live",
			form,
			sym.duration == .Thread_Local ? "`thread_local` storage" :
				sym.duration == .Static ? "`static` storage" : "file-scope storage",
		)
		add_notef(k.c, sym.span, "declared here; `exchange` replaces a static-duration value instead")
		return false
	}
	// design.md "Parameter semantics": an ordinary `value: T` parameter is a
	// non-owning immutable borrow. Consuming one is the caller's `move` at the
	// call site, not this body's.
	if sym.kind == .Parameter && sym.mode != .Inout {
		errorf(
			k.c,
			expr_span(e),
			"L0499",
			"`%s` borrows `%s`, so this body does not own it; `move` at the call site is what transfers ownership",
			form,
			identifier_text(k.c, sym.name),
		)
		add_notef(k.c, sym.span, "declared here")
		return false
	}
	return true
}


// design.md "Exchange": `exchange(inout destination, replacement)` "replaces a
// definitely live value and returns its previous value without cloning it". The
// destination's type supplies the context for the replacement, which is why the
// built-in has no written signature.
check_exchange_builtin :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident) {
	v.value_category = .Value
	if len(v.args) != 2 {
		errorf(k.c, v.span, "L0505", "`exchange` takes a destination place and its replacement")
		v.type = INVALID_TYPE
		return
	}
	// "Like any `inout` operation", the marker is written at the call site.
	if v.args[0].mode != .Inout {
		errorf(
			k.c,
			v.args[0].span,
			"L0505",
			"`exchange` replaces the destination, so it is written `exchange(inout place, replacement)`",
		)
		v.type = INVALID_TYPE
		return
	}
	// `exchange` is a built-in with no written signature, so it has no parameter
	// name to address and no second modal position — permanently, not pending a
	// milestone (m7-plan step 6).
	if v.args[0].name.text != "" || v.args[1].name.text != "" {
		errorf(k.c, v.span, "L0505", "`exchange` takes positional arguments only")
		v.type = INVALID_TYPE
		return
	}
	if v.args[1].mode != .Value {
		errorf(k.c, v.args[1].span, "L0505", "`exchange`'s replacement is passed by value")
		v.type = INVALID_TYPE
		return
	}

	destination := check_single_expr(k, v.args[0].value)
	if destination == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}
	base := expr_base(v.args[0].value)
	if base == nil || !base.assignable {
		report_not_assignable(k, base, "the destination of an `exchange`")
		v.type = INVALID_TYPE
		return
	}
	// The destination's type supplies the context, so `{}` means its zero value.
	if !check_value_expr(k, v.args[1].value, destination, "exchange into") {
		v.type = INVALID_TYPE
		return
	}

	bound := make([]Expr, 2, k.c.semantic_allocator)
	bound[0] = v.args[0].value
	bound[1] = v.args[1].value
	v.bound = bound
	v.type = destination
	// The replacement is installed as one lifecycle operation with the old value's
	// move out, so a hook may have to exist for the destination's type.
	contribute_lifecycle_members(k, destination)
}

// ------------------------------------------------- ownership at the call --

// design.md "Parameter semantics": "Both non-default modes are required at the
// call site, not just at the declaration ... an argument to a `move` parameter
// must be written `move(expr)`. Omitting the marker is an error naming the
// parameter and the mode it needs." Method-call syntax supplies an `inout`
// receiver's marker, because that borrow ends with the call and leaves the
// source usable. A consuming receiver does not: it leaves the source dead, so
// it is written `move(value).method()` like every other transfer.
require_argument_ownership :: proc(k: ^Checker, v: ^Expr_Call, declaration: Symbol_Id) {
	sym := symbol_of(k.c, declaration)
	if sym == nil {
		return
	}
	info := type_of(k.c, sym.proc_type)
	if info == nil {
		return
	}
	first := 0
	if sym.has_receiver && sym.receiver != .Move {
		first = 1 // an `inout` receiver's marker is implicit in method-call syntax
	}
	for slot in first ..< len(v.bound) {
		if slot >= len(info.param_modes) || info.param_modes[slot] != .Move {
			continue
		}
		argument := v.bound[slot]
		if argument == nil {
			continue
		}
		if _, is_move := argument.(^Expr_Move); is_move {
			continue
		}
		name := "this parameter"
		if slot < len(sym.param_symbols) {
			if parameter := symbol_of(k.c, sym.param_symbols[slot]); parameter != nil {
				name = identifier_text(k.c, parameter.name)
			}
		}
		errorf(
			k.c,
			expr_span(argument),
			"L0501",
			"`%s` is a `move` parameter, so this argument is written `move(...)`",
			name,
		)
	}
}

// design.md: "Returning such a borrowed managed parameter by value performs a
// logical clone, because the callee owns nothing it could move out. ... In
// contrast, returning a managed local, named result, temporary, or `move`
// parameter transfers that owned value into result storage without cloning."
classify_return_value :: proc(k: ^Checker, value: ^Return_Value, result: Type_Id) {
	if value.is_inout || !type_is_managed(k.c, result) {
		return
	}
	root := place_root_symbol(k.c, value.expr)
	sym := symbol_of(k.c, root)
	if sym == nil {
		return // a temporary: already owned, nothing to clone
	}
	// An owned source transfers. Everything else the callee can name is borrowed.
	if sym.kind == .Var && sym.decl != nil && !sym.decl.top_level {
		return
	}
	if sym.kind == .Result {
		return
	}
	if sym.kind == .Parameter && sym.mode == .Move {
		return
	}
	if type_clone_disabled(k.c, result) {
		errorf(
			k.c,
			expr_span(value.expr),
			"L0502",
			"`%s` is move-only, so a borrowed value of it cannot be returned by value; return a `move` parameter or a local instead",
			type_name(k.c, result),
		)
		return
	}
	value.clone_on_return = true
	// The generated entry point has to exist by emission.
	contribute_lifecycle_members(k, result)
}

// The variable a place expression is rooted in, or INVALID_SYMBOL for a
// temporary. Field and element selection do not change the root.
place_root_symbol :: proc(c: ^Compiler, e: Expr) -> Symbol_Id {
	#partial switch v in e {
	case ^Expr_Ident:
		return v.symbol
	case ^Expr_Selector:
		return place_root_symbol(c, v.operand)
	case ^Expr_Index:
		return place_root_symbol(c, v.operand)
	}
	return INVALID_SYMBOL
}

// -------------------------------------------------------------- copy sites --

// design.md "Assignment statements": "Assignment has value semantics.
// Assignment of a mutable owning value creates an independent value. It does not
// create a hidden alias to the same allocation."
//
// So the question at a binding or an assignment is only whether the source
// already owns what it produces. A call result, a literal, a conversion, and
// `move(x)` all hand over something owned and transfer it; a place names storage
// someone else still owns, and consuming it is a copy.
expression_is_borrowed_place :: proc(c: ^Compiler, e: Expr) -> bool {
	if _, is_move := e.(^Expr_Move); is_move {
		return false
	}
	return place_root_symbol(c, e) != INVALID_SYMBOL
}

// design.md: "The compiler does not silently move a dynamic array, map, runtime
// string, `shared(T)`, or type with a custom copy hook. This rule also applies
// at the last use of the source."
@(private = "file")
classify_copy :: proc(k: ^Checker, value: Expr, type: Type_Id, site: string) -> bool {
	if value == nil || !type_is_managed(k.c, type) || !expression_is_borrowed_place(k.c, value) {
		return false
	}
	if type_clone_disabled(k.c, type) {
		errorf(
			k.c,
			expr_span(value),
			"L0503",
			"`%s` is move-only, so this %s cannot copy it; write `move(...)` to transfer ownership instead",
			type_name(k.c, type),
			site,
		)
		return false
	}
	contribute_lifecycle_members(k, type)
	return true
}

// Aggregate construction has the same value semantics as a binding: a place
// continues to own its value, so the field/element receives a clone; a
// temporary or `move` hands ownership to the aggregate. Literal copies are not
// one of the four copy-cost warning sites, but they still need the lifecycle
// operation and the move-only diagnostic.
classify_composite_element :: proc(k: ^Checker, v: ^Expr_Composite, index: int, type: Type_Id) {
	if !classify_copy(k, v.elements[index].value, type, "aggregate literal") {
		return
	}
	if v.element_clones == nil {
		v.element_clones = make([]bool, len(v.elements), k.c.semantic_allocator)
	}
	v.element_clones[index] = true
}

classify_declaration_copies :: proc(k: ^Checker, d: ^Decl, in_loop := false) {
	if d.kind == .Const || d.top_level || len(d.values) != len(d.symbols) {
		return // one call filling several names hands over results it already owns
	}
	clones: []bool
	for value, index in d.values {
		sym := symbol_of(k.c, d.symbols[index])
		if sym == nil || sym.kind != .Var {
			continue
		}
		if value != nil && expression_is_borrowed_place(k.c, value) {
			report_copy_cost(k, .Binding, expr_span(value), value, sym.type, in_loop)
		}
		if !classify_copy(k, value, sym.type, "binding") {
			continue
		}
		if clones == nil {
			clones = make([]bool, len(d.values), k.c.semantic_allocator)
		}
		clones[index] = true
	}
	d.value_clones = clones
}

classify_assignment_copies :: proc(k: ^Checker, s: ^Stmt_Assign, in_loop := false) {
	if s.op != .Assign {
		return // a compound assignment reads and writes one place, and copies nothing
	}
	// The destination state is recorded per target whether or not the source is a
	// copy: a transfer still replaces a value that has to be dropped first.
	if s.destination_live == nil && len(s.lhs) > 0 {
		s.destination_live = make([]Liveness, len(s.lhs), k.c.semantic_allocator)
		for index in 0 ..< len(s.lhs) {
			// A place the analysis does not track is a field or element of a live
			// aggregate, so its previous value is there to be dropped.
			s.destination_live[index] = .Live
		}
	}
	if len(s.rhs) != len(s.lhs) {
		return
	}
	clones: []bool
	for value, index in s.rhs {
		base := expr_base(s.lhs[index])
		if base == nil {
			continue
		}
		// A container literal replacing a destination with a written policy is
		// built with that policy's provider, not with a default-backed temporary.
		bind_literal_allocator(k.c, value, place_root_symbol(k.c, s.lhs[index]))
		if expression_is_borrowed_place(k.c, value) {
			report_copy_cost(k, .Assignment, expr_span(value), value, base.type, in_loop)
		}
		if !classify_copy(k, value, base.type, "assignment") {
			continue
		}
		if clones == nil {
			clones = make([]bool, len(s.rhs), k.c.semantic_allocator)
		}
		clones[index] = true
	}
	s.rhs_clones = clones
}

// --------------------------------------------------------- storage duration --

// design.md "Storage modifiers": "File-scope, `static`, and `thread_local`
// declarations use constant initialization. The initializer must be a
// compile-time constant. If there is no initializer, the declaration uses the
// zero value." A local with either duration also needs module-level storage,
// which is what this records.
record_static_local :: proc(k: ^Checker, d: ^Decl) {
	for symbol_id, index in d.symbols {
		sym := symbol_of(k.c, symbol_id)
		if sym == nil || sym.kind != .Var {
			continue
		}
		if index < len(d.values) && d.values[index] != nil && !is_const_expr(d.values[index]) {
			errorf(
				k.c,
				expr_span(d.values[index]),
				"L0506",
				"a `%s` declaration is initialised once, before any code runs, so its initialiser must be a compile-time constant",
				d.duration == .Static ? "static" : "thread_local",
			)
			continue
		}
		append(&k.c.static_locals, symbol_id)
	}
}

// ------------------------------------------------------- copy-cost report --

// design.md "Copy-cost diagnostics": "A **copy site** is a point that duplicates
// a value instead of moving or borrowing it", and the four of them are a trivial
// aggregate copied into a `value: T` parameter, a binding, an assignment, and the
// return of a borrowed managed owner by value.
//
// Size is never a type error, so this is a warning and the threshold is an
// option. What it must not do is warn merely because a type is large: an
// ordinary `value: T` parameter *borrows* a managed owner, and a hidden-pointer
// ABI may move nothing at all, so neither is a copy site.
Copy_Site :: enum {
	Argument,
	Binding,
	Assignment,
	Return,
}

@(private = "file")
copy_site_text :: proc(site: Copy_Site) -> string {
	switch site {
	case .Argument:   return "argument"
	case .Binding:    return "binding"
	case .Assignment: return "assignment"
	case .Return:     return "return"
	}
	return "copy"
}

// Whether a copy of `type` is worth reporting, and why. A clone that may
// allocate is expensive whatever its inline size, which is the case design.md
// asks to be made more prominent.
@(private = "file")
copy_is_expensive :: proc(c: ^Compiler, type: Type_Id) -> (bool, bool) {
	allocates := type_is_managed(c, type) && type_clone_is_fallible(c, type)
	if !c.copy_cost_enabled {
		return false, allocates
	}
	return allocates || type_size(c, type) >= c.copy_cost_threshold, allocates
}

report_copy_cost :: proc(k: ^Checker, site: Copy_Site, span: Span, source: Expr, type: Type_Id, in_loop: bool) {
	expensive, allocates := copy_is_expensive(k.c, type)
	if !expensive {
		return
	}
	name := ""
	if root := symbol_of(k.c, place_root_symbol(k.c, source)); root != nil {
		name = identifier_text(k.c, root.name)
	}
	source_text := name == "" ? fmt.aprintf("a `%s`", type_name(k.c, type), allocator = k.c.semantic_allocator) :
		fmt.aprintf("`%s`", name, allocator = k.c.semantic_allocator)
	// A clone is not a fixed-size copy: reporting only its inline bytes would
	// understate it, since the allocation it makes is the expensive half.
	if allocates {
		warnf(k.c, span, "L0507", "this %s clones %s", copy_site_text(site), source_text)
		add_notef(
			k.c,
			no_span(),
			"`%s` has a lifecycle clone, which may allocate; its inline representation is %d bytes",
			type_name(k.c, type),
			type_size(k.c, type),
		)
	} else {
		warnf(
			k.c, span, "L0507",
			"this %s copies %d bytes from %s",
			copy_site_text(site), type_size(k.c, type), source_text,
		)
	}
	if in_loop {
		add_notef(k.c, no_span(), "this runs on every iteration of the enclosing loop")
	}
	// design.md: the advice is transfer or sharing. It "must not recommend
	// `inout` solely as an optimization, because `inout` grants mutation rights
	// and changes which aliases are legal".
	if name != "" && site != .Return {
		add_notef(k.c, no_span(), "write `move(%s)` if `%s` is no longer needed", name, name)
	}
	add_notef(k.c, no_span(), "take a pointer or `shared(T)` if the two names should share one value")
}

// ------------------------------------------------------------- liveness --

// Where a local sits at one program point. The join of two different states is
// `Conditional`, which is exactly design.md's "conditionally live".
Liveness :: enum u8 {
	Dead,
	Live,
	Conditional,
}

@(private = "file")
join :: proc(a, b: Liveness) -> Liveness {
	return a == b ? a : .Conditional
}

// One concrete body's answer, run after checking so every node carries its type
// and every `defer` already has its slot.
analyze_ownership :: proc(k: ^Checker, literal: ^Expr_Proc) {
	// A nested literal is checked, and analysed, before the body containing it
	// reaches here, so one reserved arena reset per body is enough.
	defer free_all(k.c.analysis_allocator)
	graph := build_flow_graph(k, literal, k.c.analysis_allocator)
	if graph == nil {
		return
	}
	solve_liveness(k, graph)
	assign_cleanup_slots(k, graph)
}

// Forward dataflow to a fixed point. The lattice has three points and the graph
// is finite, so the worklist terminates; a block is re-queued only when one of
// its predecessors produced a new exit state.
@(private = "file")
solve_liveness :: proc(k: ^Checker, graph: ^Flow_Graph) {
	tracked := len(graph.tracked)
	if tracked == 0 {
		return
	}
	for block in graph.blocks {
		block.entry_state = make([]Liveness, tracked, graph.alloc)
		block.exit_state = make([]Liveness, tracked, graph.alloc)
		block.visited = false
	}

	// A worklist reaches the finite lattice's actual fixed point. A source-level
	// nesting depth must never become an undocumented analysis limit.
	queue := make([dynamic]Block_Id, 0, len(graph.blocks), graph.alloc)
	in_queue := make([]bool, len(graph.blocks), graph.alloc)
	state := make([]Liveness, tracked, graph.alloc)
	append(&queue, Block_Id(0))
	in_queue[0] = true
	for head := 0; head < len(queue); head += 1 {
		id := queue[head]
		index := int(id)
		block := graph.blocks[index]
		in_queue[index] = false
		mem.zero_slice(state)
		if index == 0 {
			// An ordinary parameter is a borrow and a local is dead until its
			// declaration completes; a `move` parameter arrives owned.
			for slot in 0 ..< tracked {
				state[slot] = graph.tracked[slot].live_on_entry ? .Live : .Dead
			}
		} else {
			first := true
			for predecessor in block.preds {
				source := graph.blocks[predecessor]
				if !source.visited {
					continue
				}
				for slot in 0 ..< tracked {
					state[slot] = first ? source.exit_state[slot] : join(state[slot], source.exit_state[slot])
				}
				first = false
			}
			if first {
				continue // no reachable predecessor yet
			}
		}
		copy(block.entry_state, state)
		run_events(graph, block, state)
		if block.visited && states_equal(block.exit_state, state) {
			continue
		}
		copy(block.exit_state, state)
		block.visited = true
		for successor in block.succs {
			position := int(successor)
			if !in_queue[position] {
				append(&queue, successor)
				in_queue[position] = true
			}
		}
	}

	// A second walk with the fixed point in hand: this is where the events that
	// need an answer — a use, a cleanup point — read their state.
	for block in graph.blocks {
		if !block.visited {
			continue
		}
		mem.zero_slice(state)
		copy(state, block.entry_state)
		report_events(k, graph, block, state)
	}
}

@(private = "file")
states_equal :: proc(a, b: []Liveness) -> bool {
	for value, index in a {
		if value != b[index] {
			return false
		}
	}
	return true
}

@(private = "file")
run_events :: proc(graph: ^Flow_Graph, block: ^Flow_Block, state: []Liveness) {
	for event in block.events {
		#partial switch event.kind {
		case .Init, .Assign:
			state[event.slot] = .Live
		case .Kill:
			state[event.slot] = .Dead
		case .Cleanup:
			state[event.slot] = .Dead
		}
	}
}

// The diagnostics and the cleanup obligations, with the solved entry state.
@(private = "file")
report_events :: proc(k: ^Checker, graph: ^Flow_Graph, block: ^Flow_Block, state: []Liveness) {
	for event in block.events {
		if event.kind == .Reset_Point {
			record_reset_liveness(k, graph, event, state)
			continue
		}
		local := &graph.tracked[event.slot]
		#partial switch event.kind {
		case .Init:
			state[event.slot] = .Live
		case .Assign:
			// design.md: assignment drops the destination's previous value, so what
			// the emitter needs here is the state on the way in, not on the way out.
			if event.assign != nil && event.target < len(event.assign.destination_live) {
				event.assign.destination_live[event.target] = state[event.slot]
			}
			if state[event.slot] == .Conditional {
				local.conditional_assign = true
			}
			state[event.slot] = .Live
		case .Kill:
			if state[event.slot] != .Live {
				report_not_live(k, event, state[event.slot])
			}
			state[event.slot] = .Dead
		case .Use:
			if state[event.slot] != .Live {
				report_not_live(k, event, state[event.slot])
			}
		case .Cleanup:
			// Every cleanup point of one local votes: any disagreement between
			// them, or a conditional state at one of them, makes the drop
			// conditional and gives the slot a runtime flag.
			local.seen_cleanup = true
			switch state[event.slot] {
			case .Live:
				local.live_exit = true
			case .Dead:
				local.dead_exit = true
			case .Conditional:
				local.live_exit, local.dead_exit = true, true
			}
			state[event.slot] = .Dead
		}
	}
}

// design.md: "For this rule, an owner is live when it may be used later or still
// requires cleanup on an outgoing path. An explicitly dropped manual owner is
// dead and no longer blocks reset."
//
// That is exactly this analysis's `.Dead`, and only `.Dead`: a conditionally
// live owner may still need its cleanup on one path, so it keeps blocking. The
// reset check itself runs in a later pass over a different graph, so the answer
// is recorded against the call node both passes walk, in the compilation arena
// rather than this analysis's own (m6b-plan step 5).
@(private = "file")
record_reset_liveness :: proc(k: ^Checker, graph: ^Flow_Graph, event: Flow_Event, state: []Liveness) {
	if event.call == nil {
		return
	}
	dead := make([dynamic]Symbol_Id, 0, 4, k.c.semantic_allocator)
	for local, slot in graph.tracked {
		if state[slot] == .Dead {
			append(&dead, local.symbol)
		}
	}
	k.c.reset_dead[event.call] = dead[:]
}

@(private = "file")
report_not_live :: proc(k: ^Checker, event: Flow_Event, state: Liveness) {
	action := event.verb == "" ? "used" : event.verb
	if state == .Dead {
		errorf(
			k.c,
			event.span,
			"L0500",
			"`%s` cannot be %s here: it has already been moved, dropped, or released",
			event.name,
			action,
		)
		return
	}
	errorf(
		k.c,
		event.span,
		"L0500",
		"`%s` cannot be %s here: it is live on only some of the paths that reach this point",
		event.name,
		action,
	)
}

// design.md: "A managed local declaration places an implicit conditional
// `defer drop(value)` at the declaration point." The slot joins the same
// registration order every explicit `defer` uses, so cleanup replays one
// reverse order rather than two.
@(private = "file")
assign_cleanup_slots :: proc(k: ^Checker, graph: ^Flow_Graph) {
	for local in graph.tracked {
		sym := symbol_of(k.c, local.symbol)
		if sym == nil {
			continue
		}
		// Reaching a cleanup point live is what gives a local an implicit drop. An
		// allocation root reaches the same points but owns no cleanup.
		sym.drop_at_exit = local.owns_cleanup && local.seen_cleanup && local.live_exit
		// A hidden flag exists only where a lowering has to tell the runtime paths
		// apart: cleanup points that disagree, or an assignment whose destination
		// is live on one path and dead on another (design.md "Managed values and
		// storage": "No flag is required for every variable").
		sym.drop_conditional = (sym.drop_at_exit && local.dead_exit) || local.conditional_assign
		if !sym.drop_conditional {
			continue
		}
		sym.cleanup_slot = k.defer_slots
		k.defer_slots += 1
	}
}

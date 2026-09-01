// Ownership: `move`, explicit `drop`, and the liveness that decides where the
// compiler drops a managed local, per the dataflow rules in design.md
// "Managed values and storage".
//
// `move` and `drop` are compiler special forms over a storage location, not
// ordinary calls, so they are checked as syntax; classification itself runs
// once per concrete body over the `src/cfg.odin` view, after the body is
// checked and every node has its type.
//
// The analysis writes two facts back onto each local's symbol: whether scope
// exit drops it at all, and whether it reaches its scope exits in the same
// state on every path. Only the second case needs a runtime flag — what keeps
// "no source or ABI rule requires a flag" true for the ordinary local.
package lokec

import "core:fmt"
import "core:mem"

// ------------------------------------------------------ the special forms --

// `move(value)` transfers ownership without a copy, zeroing the source and
// marking it dead (design.md "Assignment statements").
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

// `drop(value)` runs the cleanup operation, zeroes the value, and marks the
// variable dead (design.md "Storage modifiers").
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

// `unsafe.forget(value)` consumes an owning operand, marks it dead, and runs
// no cleanup hook — for it or anything it owns transitively (design.md
// "Forgotten owners"). Not a lifetime extension: a borrow of the operand is
// invalidated here exactly as it would be at a `drop`.
check_forget_builtin :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident) {
	v.type = TYPE_VOID
	v.value_category = .Value
	if len(v.args) != 1 || v.args[0].name.text != "" || v.args[0].mode != .Value {
		errorf(k.c, v.span, "L0649", "`unsafe.forget` takes one argument, the value whose cleanup is suppressed")
		v.type = INVALID_TYPE
		return
	}
	operand := v.args[0].value
	// Checked once, whichever form it takes: an `Expr_Move` goes through
	// `check_move`, which applies the lexical-owner and static-duration rules
	// every other transfer obeys.
	type := check_single_expr(k, operand)
	if type == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}
	// A place still belongs to whoever declared it, so consuming it is written
	// out — the same rule a `move` parameter and a consuming receiver follow. A
	// value temporary is already owned, which permits
	// `unsafe.forget(exchange(inout tls_value, {}))`.
	if expression_is_borrowed_place(k.c, operand) {
		errorf(
			k.c,
			expr_span(operand),
			"L0501",
			"`unsafe.forget` consumes its operand, so a place is written `unsafe.forget(move(...))`",
		)
		v.type = INVALID_TYPE
		return
	}
	// A managed value is accepted even with checked borrows inside it: forgetting
	// it leaks what it owns and ends those loans. An unmanaged value owns
	// nothing but provenance, and forgetting a bare borrow means nothing.
	if !type_is_managed(k.c, type) && type_carries_borrow(k.c, type).any {
		errorf(
			k.c,
			expr_span(operand),
			"L0650",
			"`%s` owns nothing and carries a borrow, so there is no cleanup for `unsafe.forget` to suppress",
			type_name(k.c, type),
		)
		v.type = INVALID_TYPE
		return
	}
	bound := make([]Expr, 1, k.c.semantic_allocator)
	bound[0] = operand
	v.bound = bound
}

// `move` and `drop` both operate on a lexical storage location — never a
// field, element, or map entry, nor file-scope/`static`/`thread_local`
// storage or a subplace of it (design.md, `drop`'s operand rules).
require_lexical_owner :: proc(k: ^Checker, e: Expr, form: string) -> bool {
	ident, is_ident := e.(^Expr_Ident)
	sym := is_ident ? symbol_of(k.c, ident.symbol) : nil
	if sym == nil || (sym.kind != .Var && sym.kind != .Parameter) {
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
	// A static-duration binding is always live once initialized; `move`/`drop`
	// on it (or a subplace of it) is forbidden, or one procedure could make it
	// dead while another still accessed it (design.md).
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
	// An ordinary `value: T` parameter is a non-owning immutable borrow
	// (design.md "Parameter semantics"); consuming it is the caller's `move`
	// at the call site, not this body's. A `move` parameter is the exception:
	// design.md says an owner received through one "may be used locally or
	// returned", and moving it onward is how it is stored.
	if sym.kind == .Parameter && sym.mode == .Value {
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


// `exchange(inout destination, replacement)` replaces a definitely live value
// and returns its previous value without cloning (design.md "Exchange"). The
// destination's type supplies the context, which is why the built-in has no
// written signature.
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

// A `move` argument must be marked at the call site too, not just at the
// declaration (design.md "Parameter semantics"). Method-call syntax supplies an
// `inout` receiver's marker implicitly, since that borrow ends with the call and
// leaves the source usable; a consuming receiver leaves the source dead, so it's
// written `move(value).method()` like any other transfer.
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

// Returning a borrowed managed parameter by value performs a logical clone,
// since the callee owns nothing it could move out; a managed local, named
// result, temporary, or `move` parameter transfers ownership into result
// storage instead (design.md).
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

// Assignment has value semantics: it creates an independent value, never a
// hidden alias to the same allocation (design.md "Assignment statements"). So
// the question at a binding or an assignment is only whether the source
// already owns what it produces: a call result, a literal, a conversion, and
// `move(x)` all hand over something owned and transfer it, while a place names
// storage someone else still owns, and consuming it is a copy.
expression_is_borrowed_place :: proc(c: ^Compiler, e: Expr) -> bool {
	if _, is_move := e.(^Expr_Move); is_move {
		return false
	}
	return place_root_symbol(c, e) != INVALID_SYMBOL
}

// The compiler never silently moves a dynamic array, map, runtime string,
// `shared(T)`, or type with a custom copy hook — including at the source's
// last use (design.md).
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

// Aggregate construction has a binding's value semantics: a place continues to
// own its value, so the field/element receives a clone; a temporary or `move`
// hands ownership to the aggregate. Literal copies aren't one of the four
// copy-cost warning sites, but still need the lifecycle operation and the
// move-only diagnostic.
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
	if d.destructure.active {
		classify_destructure(k, &d.destructure, d.values[0], in_loop)
		return
	}
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
	if s.destructure.active {
		if s.destination_live == nil && len(s.lhs) > 0 {
			s.destination_live = make([]Liveness, len(s.lhs), k.c.semantic_allocator)
			for index in 0 ..< len(s.lhs) {
				s.destination_live[index] = .Live
			}
		}
		classify_destructure(k, &s.destructure, s.rhs[0], in_loop)
		return
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

// design.md "Destructuring": the operand's category decides for the whole
// form, then each retained field is classified on its own. `classify_copy` is
// unreachable through `classify_declaration_copies`/`classify_assignment_copies`
// here — both return when value and target counts differ — so this drives it
// directly, field by field, reporting the copy cost per cloned field rather
// than once for the whole record.
@(private = "file")
classify_destructure :: proc(k: ^Checker, plan: ^Destructure, operand: Expr, in_loop: bool) {
	if !plan.from_place {
		return // a temporary or a `move` transfers its fields; nothing is cloned
	}
	clones: []bool
	for field_id, index in plan.fields {
		if index < len(plan.retained) && !plan.retained[index] {
			continue
		}
		field := symbol_of(k.c, field_id)
		if field == nil || !type_is_managed(k.c, field.type) {
			continue
		}
		report_copy_cost(k, .Binding, expr_span(operand), operand, field.type, in_loop)
		if type_clone_disabled(k.c, field.type) {
			errorf(
				k.c, expr_span(operand), "L0503",
				"field `%s` is `%s`, which is move-only, so this destructure cannot copy it; write `move(...)` to transfer ownership instead",
				identifier_text(k.c, field.name), type_name(k.c, field.type),
			)
			continue
		}
		contribute_lifecycle_members(k, field.type)
		if clones == nil {
			clones = make([]bool, len(plan.fields), k.c.semantic_allocator)
		}
		clones[index] = true
	}
	plan.clones = clones
}

// --------------------------------------------------------- storage duration --

// File-scope, `static`, and `thread_local` declarations use constant
// initialization: the initializer must be a compile-time constant, or the
// zero value is used (design.md "Storage modifiers"). A local with either
// duration also needs module-level storage — recorded here.
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

// A copy site is a point that duplicates a value instead of moving or
// borrowing it (design.md "Copy-cost diagnostics"): a trivial aggregate copied
// into a `value: T` parameter, a binding, an assignment, or the return of a
// borrowed managed owner by value.
//
// Size is never a type error, so this is a warning with a configurable
// threshold, and it must not fire merely because a type is large: an ordinary
// `value: T` parameter *borrows* a managed owner, and a hidden-pointer ABI may
// move nothing at all, so neither is a copy site.
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
	// design.md "Shared ownership": "`try_clone` increments the strong count
	// without a new allocation". The hook's signature is fallible like every
	// other one, so only the language's knowledge of the type says that copying
	// a handle is an atomic increment rather than a duplication of `T`.
	allocates := type_is_managed(c, type) && type_clone_is_fallible(c, type) &&
		!type_is_shared_handle(c, type)
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
	// The advice is transfer or sharing only — never `inout` as an optimization,
	// since `inout` grants mutation rights and changes which aliases are legal
	// (design.md).
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

// An owner is live when it may be used later or still requires cleanup on an
// outgoing path; an explicitly dropped owner is dead and no longer blocks reset
// (design.md). That is exactly this analysis's `.Dead`, and only `.Dead`: a
// conditionally live owner may still need cleanup on one path, so it keeps
// blocking. Recorded against the call node both the reset pass and this one
// walk, in the compilation arena rather than this analysis's own — the reset
// check runs later, over a different graph.
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

// A managed local declaration places an implicit conditional
// `defer drop(value)` at the declaration point (design.md). The slot joins the
// same registration order every explicit `defer` uses, so cleanup replays one
// reverse order, not two.
@(private = "file")
assign_cleanup_slots :: proc(k: ^Checker, graph: ^Flow_Graph) {
	for local in graph.tracked {
		sym := symbol_of(k.c, local.symbol)
		if sym == nil {
			continue
		}
		// Reaching a cleanup point live is what gives a local an implicit drop.
		sym.drop_at_exit = local.seen_cleanup && local.live_exit
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

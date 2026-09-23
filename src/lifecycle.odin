// Ownership checking, copy classification, and local liveness.
package lokec

import "core:fmt"
import "core:mem"

// ------------------------------------------------------ the special forms --

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

check_drop_builtin :: proc(k: ^Checker, v: ^Expr_Call) {
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

// `unsafe.forget` consumes without cleanup; it does not extend borrows.
check_forget_builtin :: proc(k: ^Checker, v: ^Expr_Call) {
	v.type = TYPE_VOID
	v.value_category = .Value
	if len(v.args) != 1 || v.args[0].name.text != "" || v.args[0].mode != .Value {
		errorf(k.c, v.span, "L0649", "`unsafe.forget` takes one argument, the value whose cleanup is suppressed")
		v.type = INVALID_TYPE
		return
	}
	operand := v.args[0].value
	type := check_single_expr(k, operand)
	if type == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}
	// A place must spell its transfer; a temporary is already owned.
	if expression_is_borrowed_place(operand) {
		errorf(
			k.c,
			expr_span(operand),
			"L0501",
			"`unsafe.forget` consumes its operand, so a place is written `unsafe.forget(move(...))`",
		)
		v.type = INVALID_TYPE
		return
	}
	// Forgetting a non-owner must not discard borrow provenance.
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

// `move` and `drop` require an owned lexical variable.
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
	// Static-duration storage is always live.
	if symbol_outlives_bodies(sym) {
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
	// Borrowed switch and iteration bindings do not own their values.
	if sym.borrowed_binding != .None {
		if sym.borrowed_binding == .Switch_Payload {
			errorf(
				k.c,
				expr_span(e),
				"L0690",
				"`%s` views the payload of a switch over a place, which still owns it; `switch (%s in move(...))` hands it over first",
				form,
				identifier_text(k.c, sym.name),
			)
		} else {
			errorf(
				k.c,
				expr_span(e),
				"L0690",
				"`%s` views an element a `foreach` source still owns; take the element out of the source instead",
				form,
			)
		}
		add_notef(k.c, sym.span, "bound here")
		return false
	}
	// Only a `move` parameter is owned by the callee.
	if sym.kind == .Parameter && sym.mode != .Move {
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


// `exchange` replaces a live value and returns the old one without cloning.
check_exchange_builtin :: proc(k: ^Checker, v: ^Expr_Call) {
	v.value_category = .Value
	if len(v.args) != 2 {
		errorf(k.c, v.span, "L0505", "`exchange` takes a destination place and its replacement")
		v.type = INVALID_TYPE
		return
	}
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
	if !check_value_expr(k, v.args[1].value, destination, "exchange into") {
		v.type = INVALID_TYPE
		return
	}
	note_nil_write(k, v.args[0].value, v.args[1].value)

	bound := make([]Expr, 2, k.c.semantic_allocator)
	bound[0] = v.args[0].value
	bound[1] = v.args[1].value
	v.bound = bound
	v.type = destination
	contribute_lifecycle_members(k, destination)
}

// Move values across container capacity whose liveness the compiler cannot track.
check_capacity_builtin :: proc(k: ^Checker, v: ^Expr_Call, kind: Builtin_Kind) {
	taking := kind == .Unsafe_Take
	name := taking ? "unsafe.take" : "unsafe.write"
	wanted := taking ? 1 : 2
	v.value_category = .Value
	v.type = taking ? INVALID_TYPE : TYPE_VOID
	if len(v.args) != wanted {
		errorf(
			k.c, v.span, "L0692",
			taking ? "`unsafe.take` takes one argument, the place the value is read out of" :
				"`unsafe.write` takes the place and the value written into it",
		)
		v.type = INVALID_TYPE
		return
	}
	for argument in v.args {
		if argument.name.text != "" || argument.mode != .Value {
			errorf(k.c, v.span, "L0692", "`%s` takes positional arguments only", name)
			v.type = INVALID_TYPE
			return
		}
	}
	place := check_single_expr(k, v.args[0].value)
	if place == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}
	base := expr_base(v.args[0].value)
	if base == nil || !base.assignable {
		report_not_assignable(k, base, taking ? "the place `unsafe.take` reads" : "the place `unsafe.write` fills")
		v.type = INVALID_TYPE
		return
	}
	if _, is_ident := v.args[0].value.(^Expr_Ident); is_ident {
		errorf(
			k.c, expr_span(v.args[0].value), "L0692",
			"`%s` reaches storage whose liveness is not tracked, and a variable's is; %s",
			name, taking ? "`move` takes a variable's value out" : "an ordinary assignment fills it",
		)
		v.type = INVALID_TYPE
		return
	}
	bound := make([]Expr, wanted, k.c.semantic_allocator)
	bound[0] = v.args[0].value
	if !taking {
		if !check_value_expr(k, v.args[1].value, place, "write into") {
			v.type = INVALID_TYPE
			return
		}
		classify_copy_cost(k, v.args[1].value, place, .Write)
		classify_copy(k, v.args[1].value, place, .Write)
		bound[1] = v.args[1].value
	}
	v.bound = bound
	if taking {
		v.type = place
		contribute_lifecycle_members(k, place)
	}
}

// ------------------------------------------------- ownership at the call --

// A place passed to a `move` parameter must spell the transfer.
require_argument_ownership :: proc(
	k: ^Checker, v: ^Expr_Call, declaration: Symbol_Id, signature: ^Type_Info = nil,
) {
	sym := symbol_of(k.c, declaration)
	info := signature
	if info == nil && sym != nil {
		info = type_of(k.c, sym.proc_type)
	}
	if info == nil {
		return
	}
	first := 0
	if sym != nil && sym.has_receiver && sym.receiver != .Move {
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
		if expression_is_owned_argument(argument) {
			continue
		}
		// A call through a procedure value has no declaration to name the parameter.
		name := "this parameter"
		if sym != nil && slot < len(sym.param_symbols) {
			if parameter := symbol_of(k.c, sym.param_symbols[slot]); parameter != nil {
				name = fmt.aprintf("`%s`", identifier_text(k.c, parameter.name), allocator = k.c.semantic_allocator)
			}
		}
		errorf(
			k.c,
			expr_span(argument),
			"L0501",
			"%s is a `move` parameter, so this argument is written `move(...)`",
			name,
		)
	}
}

// Only ordinary lexical locals and `move` parameters own their named values.
@(private = "file")
symbol_is_owned_here :: proc(sym: ^Symbol) -> bool {
	return sym != nil && sym.borrowed_binding == .None &&
		((sym.kind == .Var && sym.decl != nil && !symbol_outlives_bodies(sym)) ||
		 (sym.kind == .Parameter && sym.mode == .Move))
}

// Borrowed managed results clone; owned values transfer.
classify_return_value :: proc(k: ^Checker, value: ^Return_Value, result: Type_Id) {
	if value.is_inout || !type_is_managed(k.c, result) {
		return
	}
	root := place_root_symbol(value.expr)
	sym := symbol_of(k.c, root)
	base := expr_base(value.expr)
	if sym == nil && base != nil && base.value_category != .Place {
		return // a temporary: already owned, nothing to clone
	}
	if _, is_ident := value.expr.(^Expr_Ident); is_ident && sym != nil {
		if symbol_is_owned_here(sym) {
			return
		}
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
	contribute_lifecycle_members(k, result)
}

// The variable a place expression is rooted in, or INVALID_SYMBOL for a
// temporary. Field and element selection do not change the root.
place_root_symbol :: proc(e: Expr) -> Symbol_Id {
	#partial switch v in e {
	case ^Expr_Ident:
		return v.symbol
	case ^Expr_Selector:
		return place_root_symbol(v.operand)
	case ^Expr_Index:
		// A value-returning `operator([])` produces a temporary, not a place.
		if v.resolution.kind == .User_Operator && v.value_category != .Place {
			return INVALID_SYMBOL
		}
		return place_root_symbol(v.operand)
	}
	return INVALID_SYMBOL
}

// -------------------------------------------------------------- copy sites --

// Places copy; values and explicit moves transfer.
expression_is_borrowed_place :: proc(e: Expr) -> bool {
	base := expr_base(e)
	return base != nil && base.value_category == .Place
}

// Value category covers indirect places that have no lexical root.
expression_is_owned_argument :: proc(e: Expr) -> bool {
	base := expr_base(e)
	return base != nil && base.value_category == .Value
}

classify_copy :: proc(k: ^Checker, value: Expr, type: Type_Id, site: Copy_Site) -> bool {
	if value == nil || !type_is_managed(k.c, type) || !expression_is_borrowed_place(value) {
		return false
	}
	if type_clone_disabled(k.c, type) {
		errorf(
			k.c,
			expr_span(value),
			"L0503",
			"`%s` is move-only, so this %s cannot copy it; write `move(...)` to transfer ownership instead",
			type_name(k.c, type),
			copy_site_text(site),
		)
		return false
	}
	contribute_lifecycle_members(k, type)
	return true
}

// Copy cost also applies to large unmanaged aggregates.
classify_copy_cost :: proc(k: ^Checker, value: Expr, type: Type_Id, site: Copy_Site) {
	if value == nil || !expression_is_borrowed_place(value) {
		return
	}
	// A conversion builds a different value rather than copying its operand.
	base := expr_base(value)
	if base == nil || base.type != type || base.erased_from != INVALID_TYPE {
		return
	}
	report_copy_cost(k, site, expr_span(value), value, type, k.loop_depth > 0)
}

// Aggregate elements follow ordinary copy/transfer rules.
classify_composite_element :: proc(k: ^Checker, v: ^Expr_Composite, index: int, type: Type_Id) {
	classify_copy_cost(k, v.elements[index].value, type, .Literal)
	if !classify_copy(k, v.elements[index].value, type, .Literal) {
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
		if value != nil && expression_is_borrowed_place(value) {
			report_copy_cost(k, .Binding, expr_span(value), value, sym.type, in_loop)
		}
		if !classify_copy(k, value, sym.type, .Binding) {
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
	if s.destination_live == nil && len(s.lhs) > 0 {
		s.destination_live = make([]Liveness, len(s.lhs), k.c.semantic_allocator)
		for index in 0 ..< len(s.lhs) {
			s.destination_live[index] = .Live
		}
	}
	if s.destructure.active {
		classify_destructure(k, &s.destructure, s.rhs[0], in_loop)
		return
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
		bind_literal_allocator(k.c, value, place_root_symbol(s.lhs[index]))
		// `_ = place` takes nothing, so there is no copy to make: a clone here
		// allocates a value the discard has no destination for and never drops.
		if is_discard(s.lhs[index]) {
			continue
		}
		if expression_is_borrowed_place(value) {
			report_copy_cost(k, .Assignment, expr_span(value), value, base.type, in_loop)
		}
		if !classify_copy(k, value, base.type, .Assignment) {
			continue
		}
		if clones == nil {
			clones = make([]bool, len(s.rhs), k.c.semantic_allocator)
		}
		clones[index] = true
	}
	s.rhs_clones = clones
}

// A place destructure clones each retained managed field.
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

// Static-duration locals use constant initialization and module storage.
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
	Or_Else,
	Or_Return,
	// The sites that reach a value inside a larger expression. A copy here is the
	// easiest kind to miss, being written as construction rather than as an
	// assignment, so each one names what it was building.
	Literal,
	Insertion,
	Write,
	Variadic,
	Variant,
	Conversion,
	Or_Else_Fallback,
}

@(private = "file")
copy_site_text :: proc(site: Copy_Site) -> string {
	switch site {
	case .Argument:         return "argument"
	case .Binding:          return "binding"
	case .Assignment:       return "assignment"
	case .Return:           return "return"
	case .Or_Else:          return "`or_else`"
	case .Or_Return:        return "`or_return`"
	case .Literal:          return "aggregate literal"
	case .Insertion:        return "insertion"
	case .Write:            return "write"
	case .Variadic:         return "variadic argument"
	case .Variant:          return "variant construction"
	case .Conversion:       return "conversion"
	case .Or_Else_Fallback: return "`or_else` fallback"
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
	// A binding that only views its source has no ownership to hand over, so the
	// `move` advice below would name something `move` is not allowed to take.
	transferable := false
	if root := symbol_of(k.c, place_root_symbol(source)); root != nil {
		name = identifier_text(k.c, root.name)
		_, is_ident := source.(^Expr_Ident)
		transferable = is_ident && symbol_is_owned_here(root)
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
	if name != "" && transferable && site != .Return {
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
		run_events(block, state)
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
run_events :: proc(block: ^Flow_Block, state: []Liveness) {
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
			local.ever_written = true
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
			local.ever_written = true
			state[event.slot] = .Live
		case .Kill:
			if state[event.slot] != .Live {
				report_not_live(k, event, state[event.slot], local.ever_written)
			}
			state[event.slot] = .Dead
		case .Use:
			// `x: T = ---` asserts that something else fills the storage, so an
			// ordinary read, borrow, or address of it is accepted (design.md
			// "Built-in values"). `move` and `drop` still are not: they are `.Kill`.
			if state[event.slot] != .Live && !local.unchecked {
				report_not_live(k, event, state[event.slot], local.ever_written)
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
// blocking. Recorded against the call node or provider-cleanup ordinal both
// passes walk, in the compilation arena rather than this analysis's own — the
// reset check runs later, over a different graph.
@(private = "file")
record_reset_liveness :: proc(k: ^Checker, graph: ^Flow_Graph, event: Flow_Event, state: []Liveness) {
	if event.call == nil && event.cleanup_reset.body == nil {
		return
	}
	dead := make([dynamic]Symbol_Id, 0, 4, k.c.semantic_allocator)
	for local, slot in graph.tracked {
		if state[slot] == .Dead {
			append(&dead, local.symbol)
		}
	}
	if event.call != nil {
		k.c.reset_dead[event.call] = dead[:]
	} else {
		k.c.cleanup_reset_dead[event.cleanup_reset] = dead[:]
	}
}

@(private = "file")
report_not_live :: proc(k: ^Checker, event: Flow_Event, state: Liveness, ever_written: bool) {
	action := event.verb == "" ? "used" : event.verb
	if state == .Dead {
		// design.md "Variable declarations": a local starts dead, so one nothing
		// ever assigns holds no value rather than having lost one.
		message := "`%s` cannot be %s here: it has no value yet"
		if ever_written {
			message = "`%s` cannot be %s here: it has already been moved, dropped, or released"
		}
		errorf(k.c, event.span, "L0500", message, event.name, action)
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
		// Definite initialization follows every local; only a managed one has a
		// cleanup a hidden flag could have to disambiguate.
		if !type_is_managed(k.c, sym.type) {
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

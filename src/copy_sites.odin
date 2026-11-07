// Which expressions copy or transfer, and the report of what a copy costs.
package lokec

import "core:fmt"

// Only lexical locals and `move` parameters own their named values. An owned
// foreach leaf or consuming case binding is a local too (design.md "Element
// bindings", "Switch ownership"); a borrowing one says so.
@(private = "file")
symbol_is_owned_here :: proc(sym: ^Symbol) -> bool {
	return sym != nil && sym.borrowed_binding == .None &&
		((sym.kind == .Var && !symbol_outlives_bodies(sym)) ||
		 (sym.kind == .Parameter && sym.mode == .Move))
}

// Borrowed managed results clone; owned values transfer.
classify_return_value :: proc(k: ^Checker, value: ^Return_Value, result: Type_Id) {
	if value.is_inout || !type_is_managed(k.c, result) || !expression_is_borrowed_place(value.expr) {
		return
	}
	if ident, is_ident := value.expr.(^Expr_Ident); is_ident && symbol_is_owned_here(symbol_of(k.c, ident.symbol)) {
		return
	}
	// design.md "Widening by label"
	copied := copied_type(value.expr, result)
	if !type_is_managed(k.c, copied) {
		return
	}
	if type_clone_disabled(k.c, copied) {
		errorf(
			k.c,
			expr_span(value.expr),
			"L0502",
			"`%s` is move-only, so a borrowed value of it cannot be returned by value; return a `move` parameter or a local instead",
			type_name(k.c, copied),
		)
		return
	}
	value.clone_on_return = true
	contribute_lifecycle_members(k, copied)
	record_copy(k, .Return, expr_span(value.expr), value.expr, copied)
}

// design.md "Success returns": a wrapped `return x;` takes `x` as the plain
// statement does, so an owned local transfers into the success variant, as
// `move(x)` would, instead of being copied as a written `.ok(x)` copies it.
transfer_returned_local :: proc(k: ^Checker, e: Expr) -> Expr {
	ident, is_ident := e.(^Expr_Ident)
	if !is_ident || !type_is_managed(k.c, ident.type) || !symbol_is_owned_here(symbol_of(k.c, ident.symbol)) {
		return e
	}
	moved := new(Expr_Move, k.c.semantic_allocator)
	moved.span, moved.type, moved.value_category = ident.span, ident.type, .Value
	moved.value = ident
	moved.implicit = true
	return moved
}

// Places copy; values and explicit moves transfer.
expression_is_borrowed_place :: proc(e: Expr) -> bool {
	base := expr_base(e)
	return base != nil && base.value_category == .Place
}

// The type a copy of `value` clones at: its own, which for a widened union is
// the smaller one (design.md "Widening by label"), or the destination's.
copied_type :: proc(value: Expr, destination: Type_Id) -> Type_Id {
	if base := expr_base(value); base != nil && base.widened_from != INVALID_TYPE {
		return base.widened_from
	}
	return destination
}

// Value category covers indirect places that have no lexical root.
expression_is_owned_argument :: proc(e: Expr) -> bool {
	base := expr_base(e)
	return base != nil && base.value_category == .Value
}

classify_copy :: proc(k: ^Checker, value: Expr, destination: Type_Id, site: Copy_Site) -> bool {
	if !expression_is_borrowed_place(value) {
		return false
	}
	// design.md "Widening by label"
	type := copied_type(value, destination)
	if !type_is_managed(k.c, type) {
		return false
	}
	if type_clone_disabled(k.c, type) {
		errorf(
			k.c,
			expr_span(value),
			"L0503",
			"`%s` is move-only, so this %s cannot copy it; write `move(...)` to transfer ownership instead",
			type_name(k.c, type),
			COPY_SITE_TEXT[site],
		)
		return false
	}
	contribute_lifecycle_members(k, type)
	expr_base(value).copied_as = type
	return true
}

// Copy cost also applies to large unmanaged aggregates.
classify_copy_cost :: proc(k: ^Checker, value: Expr, type: Type_Id, site: Copy_Site) {
	if !expression_is_borrowed_place(value) {
		return
	}
	// A conversion builds a different value rather than copying its operand;
	// a widened union is copied before it is remapped.
	base := expr_base(value)
	if base.type != type || base.erased_from != INVALID_TYPE {
		return
	}
	record_copy(k, site, expr_span(value), value, copied_type(value, type))
}

// A copy site that reports what the copy costs and asks whether it clones.
classify_costed_copy :: proc(k: ^Checker, value: Expr, type: Type_Id, site: Copy_Site) -> bool {
	classify_copy_cost(k, value, type, site)
	return classify_copy(k, value, type, site)
}

// Sets `clones[index]`, allocating the `count` of them on the first.
@(private = "file")
mark_clone :: proc(k: ^Checker, clones: ^[]bool, count, index: int) {
	if clones^ == nil {
		clones^ = make([]bool, count, k.c.semantic_allocator)
	}
	clones[index] = true
}

classify_composite_element :: proc(k: ^Checker, v: ^Expr_Composite, index: int, type: Type_Id) {
	if classify_costed_copy(k, v.elements[index].value, type, .Literal) {
		mark_clone(k, &v.element_clones, len(v.elements), index)
	}
}

classify_declaration_copies :: proc(k: ^Checker, d: ^Decl) {
	if d.destructure.active {
		classify_destructure(k, &d.destructure, d.values[0])
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
		if expression_is_borrowed_place(value) {
			record_copy(k, .Binding, expr_span(value), value, copied_type(value, sym.type), Held_Copy_Report{decl = d, index = index})
		}
		if classify_copy(k, value, sym.type, .Binding) {
			mark_clone(k, &clones, len(d.values), index)
		}
	}
	d.value_clones = clones
}

classify_assignment_copies :: proc(k: ^Checker, s: ^Stmt_Assign) {
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
		classify_destructure(k, &s.destructure, s.rhs[0])
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
			record_copy(k, .Assignment, expr_span(value), value, copied_type(value, base.type), Held_Copy_Report{assign = s, index = index})
		}
		if classify_copy(k, value, base.type, .Assignment) {
			mark_clone(k, &clones, len(s.rhs), index)
		}
	}
	s.rhs_clones = clones
}

// A place destructure clones each retained managed field. The operand itself is
// not copied: its effects are its cloned fields' (`prov_destructure_copy_effects`).
@(private = "file")
classify_destructure :: proc(k: ^Checker, plan: ^Destructure, operand: Expr) {
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
		warn_copy_cost(k, .Binding, expr_span(operand), operand, field.type)
		if type_clone_disabled(k.c, field.type) {
			errorf(
				k.c, expr_span(operand), "L0503",
				"field `%s` is `%s`, which is move-only, so this destructure cannot copy it; write `move(...)` to transfer ownership instead",
				identifier_text(k.c, field.name), type_name(k.c, field.type),
			)
			continue
		}
		contribute_lifecycle_members(k, field.type)
		mark_clone(k, &clones, len(plan.fields), index)
	}
	plan.clones = clones
}

// ------------------------------------------------------- copy-cost report --

// A point that duplicates a value instead of moving or borrowing it (design.md "Copy-cost diagnostics").
Copy_Site :: enum {
	Argument,
	Binding,
	Assignment,
	Return,
	Or_Else,
	Or_Return,
	// Inside a larger expression, where a copy is easy to miss.
	Literal,
	Insertion,
	Write,
	Variadic,
	Variant,
	Conversion,
	Or_Else_Fallback,
	Conditional,
	Box,
	Unsafe_Allocation,
	Adapter,
}

@(private = "file", rodata)
COPY_SITE_TEXT := [Copy_Site]string {
	.Argument          = "argument",
	.Binding           = "binding",
	.Assignment        = "assignment",
	.Return            = "return",
	.Or_Else           = "`or_else`",
	.Or_Return         = "`or_return`",
	.Literal           = "aggregate literal",
	.Insertion         = "insertion",
	.Write             = "write",
	.Variadic          = "variadic argument",
	.Variant           = "variant construction",
	.Conversion        = "conversion",
	.Or_Else_Fallback  = "`or_else` fallback",
	.Conditional       = "conditional expression",
	.Box               = "box",
	.Unsafe_Allocation = "unsafe allocation",
	.Adapter           = "iteration adapter",
}

// A binding or assignment copy whose report waits for last-use transfer: the
// copy it names may yet become a move (design.md "Last-use transfer"), or an adapter's
// copy of its source, which `foreach` may yet peel and not make (design.md
// "Iteration adapters"). A copy that may allocate waits either way; one costed by its
// bytes waits only for an adapter, as last-use transfer moves only what clones.
Held_Copy_Report :: struct {
	decl:    ^Decl,
	assign:  ^Stmt_Assign,
	adapter: ^Expr_Call,
	index:   int,
	site:    Copy_Site,
	span:    Span,
	source:  Expr,
	type:    Type_Id,
	in_loop: bool,
	// Costed by its bytes (`report_inline_copy`), not as a clone that may allocate.
	inline:  bool,
	// The adapter's view is the source of a `copied()` (`record_adapter_copy`).
	under_copied: bool,
}

// A copy of `source` at `type`: provenance reads what it clones at, and the
// cost is warned of.
record_copy :: proc(
	k: ^Checker, site: Copy_Site, span: Span, source: Expr, type: Type_Id,
	held := Held_Copy_Report{},
) {
	if base := expr_base(source); base != nil {
		base.copied_as = type
	}
	warn_copy_cost(k, site, span, source, type, held)
}

// A copy that may allocate is reported as one whatever its size, since its
// inline bytes say nothing of what it duplicates; any other copy by the bytes
// it duplicates. A `string` or `Shared(T)` copy retains, and costs neither. A
// move-only type has no copy to cost: the site reports that it cannot be copied.
@(private = "file")
warn_copy_cost :: proc(
	k: ^Checker, site: Copy_Site, span: Span, source: Expr, type: Type_Id,
	held := Held_Copy_Report{},
) {
	if !k.c.copy_cost_enabled || type_clone_disabled(k.c, type) {
		return
	}
	in_loop := k.loop_depth + k.expanded_in_loops > 0
	allocates := clone_may_allocate(k.c, type)
	if !allocates && (underlying_kind(k.c, type) == .String || type_is_shared_handle(k.c, type) || type_size(k.c, type) < k.c.copy_cost_threshold) {
		return
	}
	waits := held.adapter != nil || allocates && (held.decl != nil || held.assign != nil)
	if !waits {
		report_copy(k, Held_Copy_Report{site = site, span = span, source = source, type = type, in_loop = in_loop, inline = !allocates})
		return
	}
	if k.c.held_copy_reports == nil {
		k.c.held_copy_reports = make([dynamic]Held_Copy_Report, 0, 4, k.c.semantic_allocator)
	}
	held := held
	held.site, held.span, held.source, held.type, held.in_loop, held.inline = site, span, source, type, in_loop, !allocates
	append(&k.c.held_copy_reports, held)
}

@(private = "file")
report_copy :: proc(k: ^Checker, held: Held_Copy_Report) {
	adapter_hint := held.under_copied ? ADAPTER_UNDER_COPIED_HINT : ADAPTER_COPY_HINT
	if held.inline {
		report_inline_copy(k, held.site, held.span, held.source, held.type, held.in_loop, adapter_hint)
	} else {
		report_allocating_copy(k, held.site, held.span, held.source, held.in_loop, adapter_hint)
	}
}

@(private = "file")
report_inline_copy :: proc(k: ^Checker, site: Copy_Site, span: Span, source: Expr, type: Type_Id, in_loop: bool, adapter_hint: string) {
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
	warnf(
		k.c, span, "L0507",
		"this %s copies %d bytes from %s",
		COPY_SITE_TEXT[site], type_size(k.c, type), source_text,
	)
	if in_loop {
		add_notef(k.c, NO_SPAN, "this runs on every iteration of the enclosing loop")
	}
	if site == .Adapter {
		add_notef(k.c, NO_SPAN, "%s", adapter_hint)
		return
	}
	// Never advise inout: it grants mutation and changes which aliases are legal (design.md).
	if name != "" && transferable && site != .Return {
		add_notef(k.c, NO_SPAN, "write `move(%s)` if `%s` is no longer needed", name, name)
	}
	add_notef(k.c, NO_SPAN, "take a pointer or `Shared(T)` if the two names should share one value")
}

@(private = "file")
ADAPTER_COPY_HINT :: "a `foreach` written over the adapter call makes no copy"

// A `foreach` takes apart no adapter below `copied()`, but `copied()` written first
// borrows the source, and an adapter over it holds only that borrow.
@(private = "file")
ADAPTER_UNDER_COPIED_HINT :: "write `copied()` before this adapter: it borrows the source, and this adapter over it copies nothing"

@(private = "file")
report_allocating_copy :: proc(k: ^Checker, site: Copy_Site, span: Span, source: Expr, in_loop: bool, adapter_hint: string) {
	object := "a value that may allocate"
	hint := "write `.clone()` on it if the copy is intended"
	if root := symbol_of(k.c, place_root_symbol(source)); root != nil {
		name := identifier_text(k.c, root.name)
		if _, is_ident := source.(^Expr_Ident); is_ident {
			object = fmt.aprintf("`%s`, which may allocate", name, allocator = k.c.semantic_allocator)
			hint = fmt.aprintf("write `%s.clone()` if the copy is intended", name, allocator = k.c.semantic_allocator)
		} else {
			object = fmt.aprintf("part of `%s`, which may allocate", name, allocator = k.c.semantic_allocator)
		}
	}
	if site == .Adapter {
		hint = adapter_hint
	}
	warnf(k.c, span, "L0507", "this %s clones %s", COPY_SITE_TEXT[site], object)
	if in_loop {
		add_notef(k.c, NO_SPAN, "this runs on every iteration of the enclosing loop")
	}
	add_notef(k.c, NO_SPAN, "%s", hint)
}

// The held reports, from `mark` on, whose copies last-use transfer left copies.
// Whether the copy a held report names is still made, now the body is checked.
@(private = "file")
held_copy_is_made :: proc(held: Held_Copy_Report) -> bool {
	if held.adapter != nil {
		return !held.adapter.adapter_peeled
	}
	clones := held.decl != nil ? held.decl.value_clones : held.assign.rhs_clones
	return held.index < len(clones) && clones[held.index]
}

// design.md "Iteration adapters": an adapter over a mutable view keeps its own copy of the
// source, which its call makes unless `foreach` peels it, and which is costed as any copy
// is (design.md "Copy-cost diagnostics").
record_adapter_copy :: proc(k: ^Checker, v: ^Expr_Call, chosen: ^Symbol) {
	if chosen == nil || chosen.synth != .Adapter_View || len(v.bound) != 1 || !committing(k.c) {
		return
	}
	source := v.bound[0]
	// A `foreach` peels no adapter below `copied()`, so the held report of the
	// adapter it is written over gives other advice (`ADAPTER_UNDER_COPIED_HINT`).
	if inner, is_call := source.(^Expr_Call); is_call && type_of(k.c, chosen.result).adapter_kind == .Copied {
		#reverse for &held in k.c.held_copy_reports {
			if held.adapter == inner {
				held.under_copied = true
				break
			}
		}
	}
	if !type_of(k.c, chosen.result).adapter_by_value {
		return
	}
	if base := expr_base(source); base != nil {
		warn_copy_cost(k, .Adapter, expr_span(source), source, base.type, Held_Copy_Report{adapter = v})
	}
}

// A nested procedure literal is analysed while its enclosing body is still being
// checked, so each body flushes only what it held. A static `foreach` checks a
// copy of its body per expansion, so one site may be held more than once.
flush_held_copy_reports :: proc(k: ^Checker, mark: int) {
	reported := make(map[Span]bool, context.temp_allocator)
	for held in k.c.held_copy_reports[mark:] {
		if reported[held.span] || !held_copy_is_made(held) {
			continue
		}
		reported[held.span] = true
		report_copy(k, held)
	}
	resize(&k.c.held_copy_reports, mark)
}

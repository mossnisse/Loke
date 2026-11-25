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

// A returned borrowed place is copied, and a managed one cloned; owned values
// transfer.
classify_return_value :: proc(k: ^Checker, value: ^Return_Value, result: Type_Id) {
	if value.is_inout || !expression_is_borrowed_place(value.expr) {
		return
	}
	if ident, is_ident := value.expr.(^Expr_Ident); is_ident && symbol_is_owned_here(symbol_of(k.c, ident.symbol)) {
		return
	}
	// design.md "Widening by label"
	copied := copied_type(value.expr, result)
	if !type_is_managed(k.c, copied) {
		// A scalar's size is never the point, as for an argument.
		if type_is_aggregate(k.c, copied) {
			classify_copy_cost(k, value.expr, result, .Return)
		}
		return
	}
	if report_borrowed_move_only_return(k, value.expr, copied) {
		return
	}
	value.clone_on_return = true
	contribute_lifecycle_members(k, copied)
	classify_copy_cost(k, value.expr, result, .Return)
}

// design.md "Parameter semantics and ABI lowering": a borrowed move-only value
// cannot be returned, as it cannot be copied. Reports whether `copied`, what
// returning `e` copies, is one.
report_borrowed_move_only_return :: proc(k: ^Checker, e: Expr, copied: Type_Id) -> bool {
	if !type_clone_disabled(k.c, copied) {
		return false
	}
	errorf(
		k.c, expr_span(e), "L0502",
		"`%s` is move-only, so a borrowed value of it cannot be returned by value; return a `move` parameter or a local instead",
		type_name(k.c, copied),
	)
	return true
}

// design.md "Returned constructions": an owned managed local the return takes
// transfers, as `move(x)` would, instead of being copied.
@(private = "file")
transfer_returned_local :: proc(k: ^Checker, e: Expr) -> Expr {
	ident, is_ident := e.(^Expr_Ident)
	if !is_ident || !type_is_managed(k.c, ident.type) || !symbol_is_owned_here(symbol_of(k.c, ident.symbol)) {
		return e
	}
	moved := new(Expr_Move, k.c.semantic_allocator)
	moved.span, moved.type, moved.value_category = ident.span, ident.type, .Value
	moved.value = ident
	moved.implicit = true
	moved.returned = true
	symbol_of(k.c, ident.symbol).returned_at = ident.span
	return moved
}

// design.md "Returned constructions": `e` is the value a `return` returns, to be
// checked against `expected`. Its constructions pass the mark on to their
// operands as they check them, and each name it writes once is noted, since
// only such an operand transfers. Reports whether a name may be written once
// and as a key as well, for `settle_returned_value` to decide once checked.
mark_returned_value :: proc(k: ^Checker, e: Expr, expected: Type_Id) -> (unsettled: bool) {
	mark_returned(e)
	names, uses := returned_name_uses(k, e, expected, checked = false)
	for name in names {
		name.return_uses = uses[name.name]
		unsettled ||= name.return_uses == .Once_Or_Key
	}
	return
}

// design.md "Returned constructions": a name the returned value writes once,
// beside a bare key that may name it too, is copied as it is checked. Once the
// whole value `e` is checked against `expected`, a literal checked as a record
// has field names for keys, so a name only they shared is written once after
// all, and its copy becomes the transfer. A literal checking left untyped, as
// one a union argument expansion checks only in its copies, still may name it.
settle_returned_value :: proc(k: ^Checker, e: Expr, expected: Type_Id) {
	Settle :: struct {
		k:    ^Checker,
		uses: map[string]Return_Uses,
	}
	settle := Settle{k = k}
	_, settle.uses = returned_name_uses(k, e, expected, checked = true)
	each_cloned_operand(e, &settle, proc(data: rawptr, operand: Operand_Site) {
		settle := (^Settle)(data)
		if operand.ident.return_uses != .Once_Or_Key || settle.uses[operand.ident.name] != .Once {
			return
		}
		moved := transfer_returned_local(settle.k, operand.ident)
		if moved == operand.ident {
			return
		}
		operand.ident.copied_as = INVALID_TYPE
		operand.clone^ = false
		operand.site^ = moved
		if operand.also != nil {
			operand.also^ = moved
		}
	})
}

// Each name the returned value `e` writes, and by name how often: `.Many`, `.Once`,
// or `.Once_Or_Key` when a key may name it too.
@(private = "file")
returned_name_uses :: proc(k: ^Checker, e: Expr, expected: Type_Id, checked: bool) -> (names: [dynamic]^Expr_Ident, uses: map[string]Return_Uses) {
	names = make([dynamic]^Expr_Ident, context.temp_allocator)
	keys := make([dynamic]^Expr_Ident, context.temp_allocator)
	walk := Returned_Names{k, &names, &keys, checked}
	collect_returned_names(&walk, e, expected)
	uses = make(map[string]Return_Uses, context.temp_allocator)
	for name in names {
		uses[name.name] = name.name in uses ? .Many : .Once
	}
	for key in keys {
		if uses[key.name] == .Once {
			uses[key.name] = .Once_Or_Key
		}
	}
	return
}

@(private = "file")
Returned_Names :: struct {
	k:       ^Checker,
	names:   ^[dynamic]^Expr_Ident,
	// Bare keys of literals whose type is not known yet.
	keys:    ^[dynamic]^Expr_Ident,
	// The value is checked, so a literal checking typed has that type.
	checked: bool,
}

// `collect_local_names` ahead of checking. Whether a literal's bare key is a
// field name or names a local depends on the literal's type, which checking has
// not recorded yet, so it is found here as checking will find it: the written
// type, or `expected` where the literal stands. Where neither is known, as for
// a call's argument, the key may be either, and goes to `keys`.
@(private = "file")
collect_returned_names :: proc(w: ^Returned_Names, e: Expr, expected: Type_Id) {
	#partial switch v in e {
	case ^Expr_Ident:
		append(w.names, v)
		return
	case ^Expr_Cond:
		collect_returned_names(w, v.cond, INVALID_TYPE)
		collect_returned_names(w, v.then, expected)
		collect_returned_names(w, v.otherwise, expected)
		return
	case ^Expr_Call:
		// `.name(payload)`, whose payload is checked against the variant's.
		if selector, is_selector := v.callee.(^Expr_Selector); is_selector && selector.operand == nil &&
		   len(v.args) == 1 && type_is_union(w.k.c, expected) {
			if index := union_index_of(w.k.c, expected, selector.name.text); index >= 0 {
				collect_returned_names(w, v.args[0].value, union_variant_payload(w.k.c, expected, index))
				return
			}
		}
	case ^Expr_Composite:
		if v.capture == nil {
			collect_returned_literal_names(w, v, expected)
			return
		}
		for entry in v.capture.entries {
			collect_returned_names(w, entry.value, INVALID_TYPE)
		}
	}
	expr_children(e, w, proc(data: rawptr, child: Expr) -> bool {
		collect_returned_names((^Returned_Names)(data), child, INVALID_TYPE)
		return false
	})
}

@(private = "file")
collect_returned_literal_names :: proc(w: ^Returned_Names, v: ^Expr_Composite, expected: Type_Id) {
	c := w.k.c
	collect_returned_names(w, v.type_expr, INVALID_TYPE)
	collect_returned_names(w, v.via, INVALID_TYPE)
	type := expected
	if w.checked && v.type != INVALID_TYPE {
		type = v.type
	} else if v.type_expr != nil {
		probe := begin_probe(c)
		type = resolve_type_syntax(w.k, v.type_expr)
		end_probe(c, probe)
	}
	info := underlying_info(c, type)
	kind := info.kind if info != nil else .Invalid
	positional: []Symbol_Id
	for element, index in v.elements {
		names_key := !key_names_field(v, element.key)
		key_type, value_type := INVALID_TYPE, INVALID_TYPE
		#partial switch kind {
		case .Struct:
			names_key = false
			value_type = literal_field_type(c, v, type, info, index, &positional)
		case .Map:
			names_key = true
			key_type, value_type = info.key, info.element
		case .Array, .Slice, .Dynamic_Array, .Simd:
			names_key = true
			value_type = info.element
		}
		if names_key {
			collect_returned_names(w, element.key, key_type)
		} else if kind == .Invalid {
			append(w.keys, element.key.(^Expr_Ident))
		}
		collect_returned_names(w, element.value, value_type)
	}
}

// The type of the struct field of `record` that a literal's element fills: the
// one checking resolved, the one its key names, or else the one at its
// position among `positional`, the named fields, listed once per literal.
// INVALID_TYPE when there is none.
@(private = "file")
literal_field_type :: proc(
	c: ^Compiler, v: ^Expr_Composite, record: Type_Id, info: ^Type_Info, index: int, positional: ^[]Symbol_Id,
) -> Type_Id {
	field := INVALID_SYMBOL
	key := v.elements[index].key
	switch {
	case v.type == record && len(v.field_indices) == len(v.elements):
		if slot := v.field_indices[index]; slot >= 0 && slot < len(info.fields) {
			field = info.fields[slot]
		}
	case key == nil:
		if positional^ == nil {
			positional^ = named_fields(c, info)
		}
		if index < len(positional^) {
			field = positional[index]
		}
	case:
		if label, is_label := key.(^Expr_Ident); is_label {
			field = field_named(c, record, identifier_of(c, label))
		}
	}
	symbol := symbol_of(c, field)
	return symbol.type if symbol != nil else INVALID_TYPE
}

// design.md "Returned constructions", "Last-use transfer": a local that a
// construction takes as an operand, where the construction keeps it and the
// flag that it is cloned.
Operand_Site :: struct {
	ident: ^Expr_Ident,
	site:  ^Expr,
	clone: ^bool,
	also:  ^Expr,
}

// Calls `visit` for each operand of the construction `e` that is a name cloned
// at its own type, as design.md "Returned constructions" defines operands: a
// variant's payload, a literal's elements, a conditional's arms, and the
// operands of any of those that is itself a construction. A capture's entries
// state their own modes, a designated array element may fill several slots, and
// a map's key is not one. A converted operand is not the local itself.
each_cloned_operand :: proc(e: Expr, data: rawptr, visit: proc(data: rawptr, operand: Operand_Site)) {
	note :: proc(site: ^Expr, clone: ^bool, data: rawptr, visit: proc(data: rawptr, operand: Operand_Site), also: ^Expr = nil) {
		ident, is_ident := site^.(^Expr_Ident)
		if !is_ident {
			each_cloned_operand(site^, data, visit)
			return
		}
		if clone != nil && clone^ && conversion_source(&ident.base) == INVALID_TYPE && ident.copied_as == ident.type {
			visit(data, Operand_Site{ident, site, clone, also})
		}
	}
	#partial switch v in e {
	case ^Expr_Composite:
		if v.capture != nil {
			return
		}
		for &element, index in v.elements {
			if !composite_element_designated(v, index) {
				note(&element.value, index < len(v.element_clones) ? &v.element_clones[index] : nil, data, visit)
			}
		}
	case ^Expr_Cond:
		note(&v.then, &v.then_clone, data, visit)
		note(&v.otherwise, &v.else_clone, data, visit)
	case ^Expr_Call:
		operation, constructs := &v.operation.(Call_Union_Construct)
		if !constructs || len(v.bound) != 1 {
			return
		}
		// The payload as written is the bound one until a transfer replaces both.
		also: ^Expr
		if len(v.args) == 1 && v.args[0].value == v.bound[0] {
			also = &v.args[0].value
		}
		note(&v.bound[0], &operation.clone, data, visit, also)
	}
}

mark_returned :: proc(e: Expr) {
	if base := expr_base(e); base != nil {
		base.returned = true
	}
}

// Every name `e` writes that may be a local of the procedure it is in. A
// procedure literal's body names none of them, and one with a capture clause
// names what the clause lists (design.md "Capture literals").
collect_local_names :: proc(e: Expr, names: ^[dynamic]^Expr_Ident) {
	if ident, is_ident := e.(^Expr_Ident); is_ident {
		append(names, ident)
		return
	}
	expr_children(e, names, proc(data: rawptr, child: Expr) -> bool {
		collect_local_names(child, (^[dynamic]^Expr_Ident)(data))
		return false
	})
}

// design.md "Returned constructions": an owned local that a returned construction
// or conditional expression, `parent`, takes as an operand of type `type`
// transfers as `move(x)` would, when the returned value names it nowhere else. A
// converted operand is not the local itself, and is copied as written.
transfer_returned_operand :: proc(k: ^Checker, parent: ^Expr_Base, e: Expr, type: Type_Id) -> Expr {
	return parent.returned ? transfer_sole_returned_name(k, e, type) : e
}

// `e`, the returned value or an operand of a returned construction checked
// against `type`, as it is taken: transferred when it is a name the return
// writes once, at its own type. design.md "Success returns": the success a
// wrapped `return x;` stands for takes `x` as the written `.ok(x)` would.
transfer_sole_returned_name :: proc(k: ^Checker, e: Expr, type: Type_Id) -> Expr {
	ident, is_ident := e.(^Expr_Ident)
	if !is_ident || ident.type != type || conversion_source(&ident.base) != INVALID_TYPE {
		return e
	}
	// A key that also names it makes a copy, which `settle_returned_value`
	// makes the transfer once the key is known to be a field's name, unless
	// there is no copy to make: then the move is right whatever the key turns
	// out to be, as a second use of a move-only local is an error either way.
	switch ident.return_uses {
	case .Many:
		return e
	case .Once_Or_Key:
		if !type_clone_disabled(k.c, type) {
			return e
		}
	case .Once:
	}
	return transfer_returned_local(k, e)
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

// What a diagnostic adds after `move(...)` for a place whose owner goes on
// using it: a copy is a temporary, which a `move` parameter takes unmarked
// (design.md "Parameter semantics and ABI lowering"). "" for a type with no copy.
copy_spelling_advice :: proc(c: ^Compiler, place: Expr) -> string {
	base := expr_base(place)
	if base == nil || base.type == INVALID_TYPE || type_clone_disabled(c, base.type) {
		return ""
	}
	return ", or `.clone()` for a copy"
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
classify_copy_cost :: proc(k: ^Checker, value: Expr, type: Type_Id, site: Copy_Site, held := Held_Copy_Report{}) {
	if !expression_is_borrowed_place(value) {
		return
	}
	// A view, splat, or erasure builds a different value rather than copying its
	// operand; a widened union is copied before it is remapped.
	base := expr_base(value)
	if base.type != type || base.view_from != INVALID_TYPE || base.splat_from != INVALID_TYPE ||
	   base.erased_from != INVALID_TYPE {
		return
	}
	record_copy(k, site, expr_span(value), value, copied_type(value, type), held)
}

// A copy site that reports what the copy costs and asks whether it clones.
classify_costed_copy :: proc(k: ^Checker, value: Expr, type: Type_Id, site: Copy_Site) -> bool {
	classify_copy_cost(k, value, type, site)
	return classify_copy(k, value, type, site)
}

// The copy of `value`, operand `index` of the construction `parent`. An owned
// local may yet transfer at its last use (design.md "Last-use transfer"), so the
// report of what its copy costs waits for that. A probe's report rolls back
// with the probe, so it is made at once.
classify_operand_copy :: proc(k: ^Checker, parent: Expr, index: int, value: Expr, type: Type_Id, site: Copy_Site) -> bool {
	held := Held_Copy_Report{}
	if ident, is_ident := value.(^Expr_Ident); is_ident && committing(k.c) && symbol_is_owned_here(symbol_of(k.c, ident.symbol)) {
		held = Held_Copy_Report{operand_of = parent, index = index}
	}
	classify_copy_cost(k, value, type, site, held)
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
	if classify_operand_copy(k, v, index, v.elements[index].value, type, .Literal) {
		mark_clone(k, &v.element_clones, len(v.elements), index)
	}
}

classify_declaration_copies :: proc(k: ^Checker, d: ^Decl) {
	if d.destructure.active {
		classify_destructure(k, &d.destructure, d.values[0], .Binding)
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
		classify_copy_cost(k, value, sym.type, .Binding, Held_Copy_Report{decl = d, index = index})
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
	if s.destructure.active {
		classify_destructure(k, &s.destructure, s.rhs[0], .Assignment)
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
		classify_copy_cost(k, value, base.type, .Assignment, Held_Copy_Report{assign = s, index = index})
		if classify_copy(k, value, base.type, .Assignment) {
			mark_clone(k, &clones, len(s.rhs), index)
		}
	}
	s.rhs_clones = clones
}

// A place destructure copies each retained field, and clones each managed one.
// The operand itself is not copied: its effects are its cloned fields'
// (`prov_destructure_copy_effects`).
@(private = "file")
classify_destructure :: proc(k: ^Checker, plan: ^Destructure, operand: Expr, site: Copy_Site) {
	if !plan.from_place {
		return // a temporary or a `move` transfers its fields; nothing is cloned
	}
	clones: []bool
	for field_id, index in plan.fields {
		if index < len(plan.retained) && !plan.retained[index] {
			continue
		}
		field := symbol_of(k.c, field_id)
		if field == nil {
			continue
		}
		managed := type_is_managed(k.c, field.type)
		// A scalar's size is never the point, as for an argument.
		if managed || type_is_aggregate(k.c, field.type) {
			warn_copy_cost(k, site, expr_span(operand), operand, field.type, Held_Copy_Report{field = field.name})
		}
		if !managed {
			continue
		}
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

// A point that duplicates a value instead of moving or borrowing it (compiler-guide.md "Copy-cost diagnostics").
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

// A copy by a binding or assignment, or of a construction's operand, whose report
// waits for last-use transfer: the copy it names may yet become a move
// (design.md "Last-use transfer"), or an adapter's copy of its source, which
// `foreach` may yet peel and not make (design.md "Iteration adapters"). A copy
// that may allocate waits either way; one costed by its bytes waits only for an
// adapter, as last-use transfer moves only what clones, or for a returned
// operand that `settle_returned_value` may transfer.
Held_Copy_Report :: struct {
	decl:    ^Decl,
	assign:  ^Stmt_Assign,
	adapter: ^Expr_Call,
	// The literal, variant construction, or conditional copying its operand `index`.
	operand_of: Expr,
	index:   int,
	site:    Copy_Site,
	span:    Span,
	source:  Expr,
	type:    Type_Id,
	in_loop: bool,
	// Costed by its bytes (`report_inline_copy`), not as a clone that may allocate.
	inline:  bool,
	// The field of `source` a destructure copies, or INVALID_IDENTIFIER for all of it.
	field:   Identifier_Id,
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
	held := held
	held.site, held.span, held.source, held.type, held.in_loop, held.inline = site, span, source, type, in_loop, !allocates
	// design.md "Returned constructions": `settle_returned_value` may yet make an
	// operand's copy a transfer, whatever the copy costs.
	ident, is_ident := source.(^Expr_Ident)
	settles := held.operand_of != nil && is_ident && ident.return_uses == .Once_Or_Key
	waits := held.adapter != nil || settles || allocates && (held.decl != nil || held.assign != nil || held.operand_of != nil)
	if !waits {
		report_copy(k, held)
		return
	}
	if k.c.held_copy_reports == nil {
		k.c.held_copy_reports = make([dynamic]Held_Copy_Report, 0, 4, k.c.semantic_allocator)
	}
	append(&k.c.held_copy_reports, held)
}

@(private = "file")
report_copy :: proc(k: ^Checker, held: Held_Copy_Report) {
	if held.inline {
		report_inline_copy(k, held)
	} else {
		report_allocating_copy(k, held)
	}
}

// The local `held.source` is rooted at, if any, and whether the source is that
// local itself. `copied` spells what is copied: the local, a destructured field
// of it as `local.field`, or else the local holding it.
@(private = "file")
copied_source :: proc(k: ^Checker, held: Held_Copy_Report) -> (root: ^Symbol, whole: bool, copied: string) {
	if root = symbol_of(k.c, place_root_symbol(held.source)); root == nil {
		return
	}
	_, whole = held.source.(^Expr_Ident)
	copied = identifier_text(k.c, root.name)
	if whole && held.field != INVALID_IDENTIFIER {
		copied = fmt.tprintf("%s.%s", copied, identifier_text(k.c, held.field))
	}
	return
}

@(private = "file")
report_inline_copy :: proc(k: ^Checker, held: Held_Copy_Report) {
	root, whole, copied := copied_source(k, held)
	text := fmt.tprintf("`%s`", copied)
	if root == nil {
		text = fmt.tprintf("a `%s`", type_name_alloc(k.c, held.type, context.temp_allocator))
	}
	warnf(
		k.c, held.span, "L0507",
		"this %s copies %d bytes from %s",
		COPY_SITE_TEXT[held.site], type_size(k.c, held.type), text,
	)
	if held.in_loop {
		add_notef(k.c, NO_SPAN, "this runs on every iteration of the enclosing loop")
	}
	if held.site == .Adapter {
		add_notef(k.c, NO_SPAN, "%s", adapter_hint(held))
		return
	}
	// Never advise inout: it grants mutation and changes which aliases are legal
	// (design.md). A binding that only views its source has no ownership to hand
	// over, so `move` advice would name something `move` is not allowed to take.
	if whole && symbol_is_owned_here(root) && held.site != .Return {
		name := identifier_text(k.c, root.name)
		add_notef(k.c, NO_SPAN, "write `move(%s)` if `%s` is no longer needed", name, name)
	}
	add_notef(k.c, NO_SPAN, "take a pointer or `Shared(T)` if the two names should share one value")
}

@(private = "file")
adapter_hint :: proc(held: Held_Copy_Report) -> string {
	return held.under_copied ? ADAPTER_UNDER_COPIED_HINT : ADAPTER_COPY_HINT
}

@(private = "file")
ADAPTER_COPY_HINT :: "a `foreach` written over the adapter call makes no copy"

// A `foreach` takes apart no adapter below `copied()`, but `copied()` written first
// borrows the source, and an adapter over it holds only that borrow.
@(private = "file")
ADAPTER_UNDER_COPIED_HINT :: "write `copied()` before this adapter: it borrows the source, and this adapter over it copies nothing"

@(private = "file")
report_allocating_copy :: proc(k: ^Checker, held: Held_Copy_Report) {
	root, whole, copied := copied_source(k, held)
	object := "a value that may allocate"
	hint := "write `.clone()` on it if the copy is intended"
	if whole {
		object = fmt.tprintf("`%s`, which may allocate", copied)
		hint = fmt.tprintf("write `%s.clone()` if the copy is intended", copied)
	} else if root != nil {
		object = fmt.tprintf("part of `%s`, which may allocate", copied)
	}
	if held.site == .Adapter {
		hint = adapter_hint(held)
	}
	warnf(k.c, held.span, "L0507", "this %s clones %s", COPY_SITE_TEXT[held.site], object)
	if held.in_loop {
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
	clones: []bool
	#partial switch parent in held.operand_of {
	case ^Expr_Composite:
		clones = parent.element_clones
	case ^Expr_Cond:
		return held.index == 0 ? parent.then_clone : parent.else_clone
	case ^Expr_Call:
		operation, constructs := parent.operation.(Call_Union_Construct)
		return constructs && operation.clone
	case:
		clones = held.decl != nil ? held.decl.value_clones : held.assign.rhs_clones
	}
	return held.index < len(clones) && clones[held.index]
}

// design.md "Iteration adapters": an adapter over a mutable view keeps its own copy of the
// source, which its call makes unless `foreach` peels it, and which is costed as any copy
// is (compiler-guide.md "Copy-cost diagnostics").
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
	if len(k.c.held_copy_reports) <= mark {
		return
	}
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

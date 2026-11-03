// Runtime `foreach`: which traversal a header names, and what each binding
// receives.
//
// A `foreach` over a built-in lowers directly to a loop, and anything else walks
// the iteration protocol. `iteration_mutable.odin` holds the mutable protocol
// walk, which shares the binder here.
package lokec

check_runtime_foreach :: proc(k: ^Checker, s: ^Stmt_Foreach) -> Flow_Info {
	if len(s.bindings) == 0 {
		errorf(k.c, s.span, "L0456", "a `foreach` binds at least one name")
		return FLOWS
	}
	outer := k.scope
	k.scope = new_scope(k.c, outer, .Local)
	defer k.scope = outer

	// Resolve calls first, so a user member named `indexed` keeps its meaning.
	if _, is_call := s.iterable.(^Expr_Call); is_call {
		if check_single_expr(k, s.iterable) == INVALID_TYPE { return FLOWS }
	}
	peel_resolved_adapter(k, s)

	// A type is never iterable; an enum name probably meant `.values()`.
	if named := resolve_type_syntax(k, s.iterable); named != INVALID_TYPE {
		errorf(
			k.c, expr_span(s.iterable), "L0456",
			"`%s` is a type, so it is not iterable%s",
			type_name(k.c, named),
			type_is_enum(k.c, named) ? "; write `.values()` for its members" : "",
		)
		return FLOWS
	}

	subject := expr_base(s.iterable).type
	if subject == INVALID_TYPE { subject = check_single_expr(k, s.iterable) }
	if subject == INVALID_TYPE {
		return FLOWS
	}
	// Nominal, like indexing and slicing: a `distinct` carrier falls to
	// `check_protocol_foreach`, which asks for the iterator its own type
	// declares (design.md "Distinct types").
	info := type_of(k.c, subject)
	if info == nil {
		return FLOWS
	}

	switch {
	case info.kind == .Array:
		s.kind = .Array
		s.count = info.count
	case info.kind == .Slice:
		s.kind = .Slice
	case info.kind == .Dynamic_Array:
		s.kind = .Dynamic
	case info.kind == .Map:
		s.kind = .Map
	case info.kind == .String || info.kind == .String_View:
		s.kind = .Text
	case info.is_range:
		// A written range lowers without building a `Range(T)`.
		_, written := s.iterable.(^Expr_Range)
		s.kind = written ? .Range : .Stored_Range
	case:
		return check_protocol_foreach(k, s, subject)
	}

	// The indexed lowering needs an array constant's address.
	if s.kind == .Array {
		request_materialization(k, s.iterable)
	}
	if foreach_is_place_loop(s) {
		return check_place_foreach(k, s, subject, info)
	}
	// design.md "Iteration adapters": `reversed()` resolved over a map or text
	// only through the program's own `iter_reverse`, which is a protocol walk.
	if s.adapter == .Reversed && (s.kind == .Map || s.kind == .Text) {
		return check_protocol_foreach(k, s, subject)
	}
	s.element_type = foreach_element_type(k, s, subject, info)
	return check_foreach_body(k, s)
}

// design.md "By-reference iteration": a `&mut` anywhere in the header makes this
// a place loop over the container's own storage.
foreach_is_place_loop :: proc(s: ^Stmt_Foreach) -> bool {
	return first_ref_binding(s.bindings) != nil
}

@(private = "file")
first_ref_binding :: proc(bindings: []Foreach_Binding) -> ^Foreach_Binding {
	for &binding in bindings {
		if binding.is_ref {
			return &binding
		}
		if found := first_ref_binding(binding.group); found != nil {
			return found
		}
	}
	return nil
}

// Where a by-reference loop that cannot be one is reported: at its `&`.
ref_span :: proc(s: ^Stmt_Foreach) -> Span {
	return first_ref_binding(s.bindings).name.span
}

// How a built-in traversal hands over its element: `stored` is the mode of what
// it walks, except that a map's key is always read-only.
@(private = "file")
builtin_yield :: proc(c: ^Compiler, s: ^Stmt_Foreach, stored: Yield_Kind) -> Yield_Desc {
	yield := Yield_Desc{kind = stored}
	if s.kind == .Map {
		yield = yield_pair(c, Yield_Desc{kind = .Borrowed}, yield)
	}
	return s.indexed ? indexed_yield(c, yield) : yield
}

// The protocol's element, item and yield, as `indexed()` in the header numbers them.
foreach_numbered :: proc(
	c: ^Compiler, s: ^Stmt_Foreach, element, item: Type_Id, yield: Yield_Desc,
) -> (Type_Id, Type_Id, Yield_Desc) {
	if !s.indexed {
		return element, item, yield
	}
	return indexed_element_type(c, element), indexed_element_type(c, item), indexed_yield(c, yield)
}

// The `Element` this loop yields, after the header's adapter.
@(private = "file")
foreach_element_type :: proc(k: ^Checker, s: ^Stmt_Foreach, under: Type_Id, info: ^Type_Info) -> Type_Id {
	traversed := s.kind == .Text ? TYPE_RUNE : info.element
	if s.kind == .Map {
		traversed = map_entry_type(k.c, under)
	}
	return s.indexed ? indexed_element_type(k.c, traversed) : traversed
}

@(private = "file")
check_place_foreach :: proc(k: ^Checker, s: ^Stmt_Foreach, subject: Type_Id, info: ^Type_Info) -> Flow_Info {
	#partial switch s.kind {
	case .Array, .Dynamic, .Map:
		if !expr_base(s.iterable).assignable {
			report_not_assignable(k, expr_base(s.iterable), "a by-reference `foreach`")
			return FLOWS
		}
	case .Slice:
		// design.md "Slices": the slice's own `mut`, not its variable's.
		if !info.mutable {
			errorf(
				k.c,
				ref_span(s),
				"L0480",
				"`%s` yields read-only elements, so it cannot be iterated by reference; use `[]mut %s` for mutation, or drop the `&mut` to read them",
				type_name(k.c, subject),
				type_name(k.c, info.element),
			)
			return FLOWS
		}
	case .Range, .Stored_Range:
		errorf(k.c, ref_span(s), "L0457", "a range produces values, so it cannot be iterated by reference")
		return FLOWS
	case .Text:
		errorf(
			k.c, ref_span(s), "L0564",
			"a string yields decoded code points, so it cannot be iterated by reference",
		)
		return FLOWS
	}
	s.element_type = foreach_element_type(k, s, subject, info)
	if !gate_type(k, s.element_type, expr_span(s.iterable)) {
		return FLOWS
	}
	return check_foreach_pattern_and_block(k, s, INVALID_TYPE, builtin_yield(k.c, s, .Mutable))
}

// design.md "Iteration protocol": associated `Element` and `Iterator`,
// `value.iter()`, and `next(self: inout Iterator) -> Option(Element)`.
@(private = "file")
check_protocol_foreach :: proc(k: ^Checker, s: ^Stmt_Foreach, subject: Type_Id) -> Flow_Info {
	if foreach_is_place_loop(s) { return check_mutable_protocol_foreach(k, s, subject) }
	element := associated_type_of(k, subject, "Element")
	iterator := associated_type_of(k, subject, "Iterator")
	iter := iteration_member(k, subject, "iter")
	iter_sym := symbol_of(k.c, iter)
	if element == INVALID_TYPE || iterator == INVALID_TYPE ||
	   !iteration_proc_matches(k, iter_sym, subject, .Borrow, iterator) {
		errorf(
			k.c,
			expr_span(s.iterable),
			"L0456",
			"`%s` is not iterable: it needs associated `Element` and `Iterator` members and an `iter` procedure",
			type_name(k.c, subject),
		)
		return FLOWS
	}
	// Only `reversed()` selects `iter_reverse`.
	if s.adapter == .Reversed {
		reverse := iteration_member(k, subject, "iter_reverse")
		if !iteration_proc_matches(k, symbol_of(k.c, reverse), subject, .Borrow, iterator) {
			errorf(
				k.c,
				expr_span(s.iterable),
				"L0460",
				"`%s` cannot be reversed: it needs `iter_reverse :: proc(self) -> %s`",
				type_name(k.c, subject),
				type_name(k.c, iterator),
			)
			return FLOWS
		}
		iter = reverse
	}
	next, yield, item, usable := foreach_next_member(k, s, iterator, element, .Owned)
	if !usable {
		return FLOWS
	}

	element, item, yield = foreach_numbered(k.c, s, element, item, yield)
	if !yield_is_owned(yield) {
		s.borrows = true
		s.item_type = item
	}

	s.kind = .Protocol
	s.element_type = element
	s.iterator_type = iterator
	s.iter_symbol = iter
	s.next_symbol = next
	enroll_synth(k.c, iter)
	enroll_synth(k.c, next)
	return check_foreach_body(k, s, yield)
}

// The iterator's `next`, how it yields against `element`, and what it hands back,
// reporting a `next` the protocol cannot call.
foreach_next_member :: proc(k: ^Checker, s: ^Stmt_Foreach, iterator, element: Type_Id, fallback: Yield_Kind) -> (next: Symbol_Id, yield: Yield_Desc, item: Type_Id, ok: bool) {
	// `next`'s `Item` says how the element is handed over.
	yield = iterator_yield(k, iterator, element, fallback)
	item = iterator_item_type(k, iterator, element, yield, expr_span(s.iterable))
	if item == INVALID_TYPE {
		return
	}
	next = iteration_member(k, iterator, "next")
	if !iteration_proc_matches(k, symbol_of(k.c, next), iterator, .Inout, option_type(k, item)) {
		errorf(
			k.c,
			expr_span(s.iterable),
			"L0456",
			"`%s` needs `next :: proc(self: inout %s) -> Option(%s)`",
			type_name(k.c, iterator),
			type_name(k.c, iterator),
			type_name(k.c, item),
		)
		// `next` may exist but be excluded by a failed `where`.
		note_excluded_member(k, iterator, "next")
		return
	}
	return next, yield, item, true
}

// design.md "Element bindings": the one binder for every value loop. One name
// binds the whole `Element`; more destructure a record positionally. `yield` is
// how a protocol `next` hands the element over; a built-in traversal decides
// that here.
@(private = "file")
check_foreach_body :: proc(k: ^Checker, s: ^Stmt_Foreach, yield := Yield_Desc{}) -> Flow_Info {
	element := s.element_type
	if !gate_type(k, element, expr_span(s.iterable)) {
		return FLOWS
	}
	handed := yield
	if s.kind != .Protocol {
		// design.md "Borrowing iteration": a container lends its stored elements.
		// Text and ranges generate theirs, so they hand over owned values.
		generated := s.kind == .Text || s.kind == .Range || s.kind == .Stored_Range
		handed = builtin_yield(k.c, s, generated ? .Owned : .Borrowed)
		s.borrows = !yield_is_owned(handed)
		if s.borrows && handed.kind == .Record {
			s.item_type = yield_item_type(k, element, handed, expr_span(s.iterable))
			if s.item_type == INVALID_TYPE {
				return FLOWS
			}
		}
	}
	// An owned element is dropped each step. Asked here too because `indexed()`
	// wraps it in a record of its own.
	if !s.borrows && type_is_managed(k.c, element) {
		contribute_lifecycle_members(k, element)
	}
	return check_foreach_pattern_and_block(k, s, s.item_type, handed)
}

// The header's whole pattern against `s.element_type`, then the body.
check_foreach_pattern_and_block :: proc(k: ^Checker, s: ^Stmt_Foreach, item: Type_Id, desc: Yield_Desc) -> Flow_Info {
	if !check_foreach_pattern(k, s, s.bindings, s.element_type, item, desc, foreach_packed_source(k, s)) {
		return FLOWS
	}
	return check_foreach_block(k, s)
}

// Binds one recursive pattern, for value and place loops alike (only a place
// loop has `&` leaves). `item` is the projected form, where a record of lent
// pointers binds whole; a direct place loop passes INVALID_TYPE. `desc` says
// how each part is handed over, and an `&mut` leaf must land on a mutable one
// (design.md "Element bindings").
@(private = "file")
check_foreach_pattern :: proc(
	k: ^Checker, s: ^Stmt_Foreach, bindings: []Foreach_Binding, logical, item: Type_Id, desc: Yield_Desc,
	packed: string,
) -> bool {
	if len(bindings) == 1 {
		binding := &bindings[0]
		if len(binding.group) > 0 {
			return check_foreach_pattern(k, s, binding.group, logical, item, desc, packed)
		}
		if binding.is_ref && desc.kind != .Mutable {
			report_immutable_ref_leaf(k, binding^, desc)
			return false
		}
		return bind_pattern_leaf(k, s, binding, logical, item, desc, packed)
	}
	fields, eligible := destructure_fields(
		k, logical, len(bindings), bindings[0].name.span, "L0459", "bound by a `foreach`",
	)
	if !eligible {
		// design.md "Element bindings"
		if raw_data(bindings) == raw_data(s.bindings) && len(bindings) == 2 && !type_is_destructurable(k.c, logical) {
			add_notef(k.c, bindings[0].name.span, "a loop never invents an index; iterate `source.indexed()` to receive one")
		}
		return false
	}
	// design.md "Destructuring": an owned record that `next` hands over is taken
	// apart, which a custom hook forbids. A lent or copied one is projected.
	if desc.kind == .Owned && reject_hooked_destructure(k, logical, bindings[0].name.span) {
		return false
	}
	info := underlying_info(k.c, logical)
	for index in 0 ..< len(bindings) {
		field := symbol_of(k.c, fields[index])
		slot := int(field.index)
		// A record descriptor names each part; any other applies to all of them.
		part := desc.kind == .Record ? desc.fields[slot] : desc
		// design.md "@(packed)": a field of a packed record, and everything
		// stored inside it, may be misaligned.
		origin := packed
		if origin == "" && info.packed {
			origin = identifier_text(k.c, field.name)
		}
		projected := foreach_projected_field(k.c, item, slot)
		if !check_foreach_pattern(k, s, bindings[index:index + 1], field.type, projected, part, origin) {
			return false
		}
	}
	return true
}

@(private = "file")
report_immutable_ref_leaf :: proc(k: ^Checker, binding: Foreach_Binding, desc: Yield_Desc) {
	#partial switch desc.kind {
	case .Owned:
		errorf(
			k.c, binding.name.span, "L0457",
			"`%s` is made by the traversal, like the `indexed()` counter, so it cannot be taken by reference",
			binding.name.text,
		)
	case .Borrowed:
		errorf(
			k.c, binding.name.span, "L0457",
			"`%s` is lent read-only, so it cannot be taken by reference",
			binding.name.text,
		)
	case:
		errorf(
			k.c, binding.name.span, "L0457",
			"`%s` is a record of parts lent separately; bind its fields, and take the mutable ones by reference",
			binding.name.text,
		)
	}
}

// Whether a leaf binds the projected `item`: two different record types.
foreach_projected_record :: proc(c: ^Compiler, logical, item: Type_Id) -> bool {
	if logical == INVALID_TYPE || item == INVALID_TYPE || logical == item { return false }
	a, b := underlying_info(c, logical), underlying_info(c, item)
	return a != nil && b != nil && a.kind == .Struct && b.kind == .Struct
}

// The type field `slot` projects to, when `item` is a record.
foreach_projected_field :: proc(c: ^Compiler, item: Type_Id, slot: int) -> Type_Id {
	info := underlying_info(c, item)
	if info == nil || info.kind != .Struct || slot >= len(info.fields) { return INVALID_TYPE }
	field := symbol_of(c, info.fields[slot])
	return field != nil ? field.type : INVALID_TYPE
}

// A leaf binds its logical type, or the projected record of pointers when both
// are records. A place loop's leaves, like a lending loop's, name storage the
// source still owns, except a part `next` hands over owned (design.md "Element
// bindings"): that leaf owns its value, even beside lent siblings. A projected
// record is the step's own slot, holding the parts' pointers.
@(private = "file")
bind_pattern_leaf :: proc(
	k: ^Checker, s: ^Stmt_Foreach, binding: ^Foreach_Binding, logical, item: Type_Id, part: Yield_Desc,
	packed: string,
) -> bool {
	bound := foreach_projected_record(k.c, logical, item) ? item : logical
	if !gate_type(k, bound, expr_span(s.iterable)) { return false }
	owned := bound == item || part.kind == .Owned || (!foreach_is_place_loop(s) && !s.borrows)
	// design.md "@(packed)": a writable leaf needs the address of a field
	// that may be misaligned; a read-only one is bound as a copy.
	if packed != "" && binding.is_ref {
		errorf(
			k.c, binding.name.span, "L0614",
			"cannot bind `%s` with `&mut`: it is reached through a packed struct", packed,
		)
		return false
	}
	binding.symbol = bind_loop_name(k, binding^, bound, !owned)
	// It is bound as a copy, which cannot be borrowed (design.md "@(packed)").
	if sym := symbol_of(k.c, binding.symbol); sym != nil && packed != "" && !owned {
		sym.packed_field = packed
	}
	return true
}

// design.md "@(packed)": the elements of a fixed array stored in a packed
// struct are as misaligned as the array. Every other container's elements are
// storage of their own.
@(private = "file")
foreach_packed_source :: proc(k: ^Checker, s: ^Stmt_Foreach) -> string {
	if s.kind != .Array {
		return ""
	}
	field, _ := packed_field_reached(k, s.iterable)
	return field
}

@(private = "file")
check_foreach_block :: proc(k: ^Checker, s: ^Stmt_Foreach) -> Flow_Info {
	outer_header, outer_broken := k.loop_header, k.loop_broken
	k.loop_header, k.loop_broken = false, false
	k.loop_depth += 1
	body := check_scoped_block(k, s.body)
	k.loop_depth -= 1
	k.loop_header, k.loop_broken = outer_header, outer_broken
	return Flow_Info{can_fall_through = true, returns = body.returns}
}

@(private = "file")
bind_loop_name :: proc(k: ^Checker, binding: Foreach_Binding, type: Type_Id, borrows: bool) -> Symbol_Id {
	if binding.name.text == "_" || binding.name.text == "" {
		return INVALID_SYMBOL
	}
	id := name_identifier(k.c, binding.name)
	// The checks `declare_all` gives a local (design.md "Variable declarations").
	if _, ok := k.scope.names[id]; ok {
		errorf(k.c, binding.name.span, "L0304", "`%s` is already declared in this scope", binding.name.text)
		return INVALID_SYMBOL
	}
	if reject_reserved_name(k, id, binding.name.span) {
		return INVALID_SYMBOL
	}
	outer, owner := lookup_symbol_with_scope(k.scope.parent, id)
	if outer != INVALID_SYMBOL && (owner.kind == .Local || owner.kind == .Procedure) {
		errorf(k.c, binding.name.span, "L0305", "`%s` shadows an outer declaration", binding.name.text)
		note_shadowed_capture(k, outer)
	}
	symbol := new_symbol(k.c, Symbol {
		name      = id,
		span      = binding.name.span,
		kind      = .Var,
		type      = type,
		pkg       = k.pkg,
		immutable = !binding.is_ref,
		// Names storage the source still owns.
		borrowed_binding = borrows ? .Loop_Element : .None,
	})
	k.scope.names[id] = symbol
	return symbol
}

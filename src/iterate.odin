// Runtime `foreach` and the iteration protocol (m4b-plan step 4).
//
// design.md requires built-ins to *satisfy* the same static `Iterable` interface
// a user type does, not to be implemented through it. So there are two paths and
// they must agree:
//
//   - `foreach` over an integer range or a fixed array lowers directly to an
//     index loop. No iterator object is built.
//   - the compiler still contributes associated `Element`/`Iterator` members, an
//     `iter` overload, and an opaque iterator with `next`, so a value passed
//     through a generic parameter constrained by `Iterable` works without
//     relying on the syntax lowering.
//
// A range is a real runtime value, not just syntax: `..<` and `..=` must survive
// being stored in a variable or passed to a generic procedure, which a
// syntax-only lowering loses. `Range(T)` is a compiler-owned struct carrying its
// low endpoint, high endpoint, and closed flag, so it reuses the existing
// layout, constant, parameter-passing, and emission paths rather than adding a
// second aggregate model.
package lokec

import "core:fmt"

RANGE_LOW :: 0
RANGE_HIGH :: 1
RANGE_CLOSED :: 2

ITER_RANGE_CURRENT :: 0
ITER_RANGE_HIGH :: 1
ITER_RANGE_CLOSED :: 2

ITER_ARRAY_DATA :: 0
ITER_ARRAY_INDEX :: 1

ITER_MAP_TABLE :: 0
ITER_MAP_CURSOR :: 1

// A procedure the compiler contributes rather than the user writing it. It has
// a real symbol and a real emitted body; the backend knows how to write each
// shape (the same seam `delegate` uses for its forwarding overloads).
Synth_Kind :: enum {
	None,
	Range_Iter,
	Range_Next,
	Array_Iter,
	Array_Next,
	// A slice iterates through the same `{ data, index }` shape as an array; only
	// the bound differs, because a slice carries its length rather than having it
	// baked into the type.
	Slice_Next,
	// A dynamic array's `iter` builds the same `{ data, index }` a slice's does,
	// out of the header's current storage and length words, so `Slice_Next` is
	// its `next` verbatim. The iterator deliberately does not hold the container:
	// an iterator is a borrow, and a managed field in it would be followed by a
	// drop that has no business running.
	Dynamic_Iter,
	// design.md "Maps": `{ table, cursor }`, walked by the runtime's slot scan.
	Map_Iter,
	Map_Next,
	// design.md "Lifecycle hooks and resource types": a record that writes no
	// `try_clone` still has one, and `clone` is always generated from it
	// (m5a-plan step 3).
	Try_Clone,
	Clone,
	// `dyn I` satisfies `I` through compiler-provided forwarding slots (design.md).
	// Each one calls through the view's own witness.
	Dyn_Forward,
	// design.md "Dynamic arrays" and "Maps": one contributed container operation.
	// Which one is `Symbol.container_op` (m6b-plan step 2).
	Container_Op,
	// design.md "Allocators": one `mem.Arena`/`mem.Scratch` operation. Which one
	// is `Symbol.provider_op` (m6b-plan step 5).
	Provider_Op,
}

// ---------------------------------------------------------- range values --

range_type :: proc(c: ^Compiler, element: Type_Id) -> Type_Id {
	if existing, found := c.range_types[element]; found {
		return existing
	}
	name := intern_identifier(c, fmt.aprintf("Range(%s)", type_name(c, element), allocator = c.semantic_allocator))
	type := new_type(c, Type_Info{kind = .Struct, name = name, element = element, is_range = true})
	fields := make([]Symbol_Id, 3, c.semantic_allocator)
	fields[RANGE_LOW] = new_field(c, "low", element, RANGE_LOW, public = true)
	fields[RANGE_HIGH] = new_field(c, "high", element, RANGE_HIGH, public = true)
	fields[RANGE_CLOSED] = new_field(c, "closed", TYPE_BOOL, RANGE_CLOSED, public = true)
	if info := type_of(c, type); info != nil {
		info.fields = fields
		info.mangled = fmt.aprintf("Range.%s", llvm_safe(type_name(c, element)), allocator = c.semantic_allocator)
	}
	c.range_types[element] = type
	return type
}

// ------------------------------------------------------- iterator types --

@(private = "file")
range_iterator_type :: proc(c: ^Compiler, range: Type_Id) -> Type_Id {
	if existing, found := c.iterator_types[range]; found {
		return existing
	}
	element := type_of(c, range).element
	name := intern_identifier(c, fmt.aprintf("Range_Iterator(%s)", type_name(c, element), allocator = c.semantic_allocator))
	type := new_type(c, Type_Info{kind = .Struct, name = name, element = element})
	fields := make([]Symbol_Id, 3, c.semantic_allocator)
	fields[ITER_RANGE_CURRENT] = new_field(c, "current", element, ITER_RANGE_CURRENT, public = true)
	fields[ITER_RANGE_HIGH] = new_field(c, "high", element, ITER_RANGE_HIGH, public = true)
	fields[ITER_RANGE_CLOSED] = new_field(c, "closed", TYPE_BOOL, ITER_RANGE_CLOSED, public = true)
	if info := type_of(c, type); info != nil {
		info.fields = fields
		info.mangled = fmt.aprintf("Range_Iterator.%s", llvm_safe(type_name(c, element)), allocator = c.semantic_allocator)
	}
	c.iterator_types[range] = type
	return type
}

// `holds` is what the iterator stores, which is the iterable itself except for a
// dynamic array: that one stores the `{ data, len }` view of its current
// allocation. The key stays the iterable, so each one keeps its own iterator
// type and its own single contributed `next`.
@(private = "file")
array_iterator_type :: proc(c: ^Compiler, array: Type_Id, holds := INVALID_TYPE) -> Type_Id {
	if existing, found := c.iterator_types[array]; found {
		return existing
	}
	stored := holds == INVALID_TYPE ? array : holds
	element := type_of(c, array).element
	name := intern_identifier(c, fmt.aprintf("Array_Iterator(%s)", type_name(c, array), allocator = c.semantic_allocator))
	type := new_type(c, Type_Info{kind = .Struct, name = name, element = element})
	fields := make([]Symbol_Id, 2, c.semantic_allocator)
	fields[ITER_ARRAY_DATA] = new_field(c, "data", stored, ITER_ARRAY_DATA, public = true)
	fields[ITER_ARRAY_INDEX] = new_field(c, "index", TYPE_INT, ITER_ARRAY_INDEX, public = true)
	if info := type_of(c, type); info != nil {
		info.fields = fields
		info.mangled = fmt.aprintf("Array_Iterator.%s", llvm_safe(type_name(c, array)), allocator = c.semantic_allocator)
	}
	c.iterator_types[array] = type
	return type
}

// design.md "Maps": iteration is a slot walk whose position is one integer the
// runtime hands back. The table pointer is raw on purpose -- the iterator is a
// borrow of the map, not a second header that anything would drop.
@(private = "file")
map_iterator_type :: proc(c: ^Compiler, subject: Type_Id) -> Type_Id {
	if existing, found := c.iterator_types[subject]; found {
		return existing
	}
	element := type_of(c, subject).element
	name := intern_identifier(c, fmt.aprintf("Map_Iterator(%s)", type_name(c, subject), allocator = c.semantic_allocator))
	type := new_type(c, Type_Info{kind = .Struct, name = name, element = element})
	fields := make([]Symbol_Id, 2, c.semantic_allocator)
	fields[ITER_MAP_TABLE] = new_field(c, "table", TYPE_RAWPTR, ITER_MAP_TABLE, public = true)
	fields[ITER_MAP_CURSOR] = new_field(c, "cursor", TYPE_INT, ITER_MAP_CURSOR, public = true)
	if info := type_of(c, type); info != nil {
		info.fields = fields
		// The map this walks. `next` needs its operation table, and the raw table
		// pointer alone cannot name it.
		info.key = subject
		info.mangled = fmt.aprintf("Map_Iterator.%s", llvm_safe(type_name(c, subject)), allocator = c.semantic_allocator)
	}
	c.iterator_types[subject] = type
	return type
}

// --------------------------------------------- compiler-contributed members --

// Installs `Element`, `Iterator`, and the iterator's `next` on a built-in
// iterable, so interface checking and generic code see exactly what a user type
// declares by hand. Idempotent through its own contribution flag: the lifecycle
// hooks append to the same table, so a member count cannot be the guard.
ensure_iteration_members :: proc(k: ^Checker, type: Type_Id) {
	under := type_underlying(k.c, type)
	info := type_of(k.c, under)
	if info == nil || .Iteration in info.contributed {
		return
	}
	info.contributed += {.Iteration}
	iterator := INVALID_TYPE
	element := INVALID_TYPE
	iter_kind := Synth_Kind.None
	next_kind := Synth_Kind.None
	switch {
	case info.is_range:
		element = info.element
		iterator = range_iterator_type(k.c, under)
		iter_kind, next_kind = .Range_Iter, .Range_Next
	case info.kind == .Array:
		element = info.element
		iterator = array_iterator_type(k.c, under)
		iter_kind, next_kind = .Array_Iter, .Array_Next
	case info.kind == .Slice:
		// The iterator holds the slice by value, so `iter` is the array one
		// verbatim: `{ data, 0 }`. Only `next`'s bound is different.
		element = info.element
		iterator = array_iterator_type(k.c, under)
		iter_kind, next_kind = .Array_Iter, .Slice_Next
	case info.kind == .Dynamic_Array:
		// design.md "Dynamic arrays": iteration views the current allocation and
		// stops at the length. That is exactly a slice, so the protocol members are
		// the slice ones with a different `iter`.
		element = info.element
		iterator = array_iterator_type(k.c, under, slice_of(k.c, info.element, mutable = false))
		iter_kind, next_kind = .Dynamic_Iter, .Slice_Next
	case info.kind == .Map:
		// design.md "Maps": one name binds the value, so the protocol's single
		// `Element` is the value type. The key is reachable only through the
		// two-name loop form, which is direct iteration rather than the protocol.
		element = info.element
		iterator = map_iterator_type(k.c, under)
		iter_kind, next_kind = .Map_Iter, .Map_Next
	case:
		return
	}

	members := make([]Symbol_Id, 3, k.c.semantic_allocator)
	members[0] = new_associated_type(k.c, "Element", element, under)
	members[1] = new_associated_type(k.c, "Iterator", iterator, under)
	members[2] = synth_proc(k.c, "iter", iter_kind, under, []Type_Id{under}, []Param_Mode{.Value}, []Type_Id{iterator})
	add_members(k.c, under, members)

	// `next(self: inout Iterator) -> (Element, bool)` — the optional-ok shape the
	// protocol requires, on the opaque iterator.
	next_members := make([]Symbol_Id, 1, k.c.semantic_allocator)
	next := synth_proc(
		k.c, "next", next_kind, iterator,
		[]Type_Id{iterator}, []Param_Mode{.Inout}, []Type_Id{element, TYPE_BOOL},
	)
	if sym := symbol_of(k.c, next); sym != nil {
		sym.has_receiver = true
		sym.receiver = .Inout
	}
	next_members[0] = next
	add_members(k.c, iterator, next_members)
}

// Appends a contributed member set. The type store may have grown while the
// symbols were made, so the info pointer is taken fresh here.
add_members :: proc(c: ^Compiler, type: Type_Id, added: []Symbol_Id) {
	info := type_of(c, type)
	if info == nil || len(added) == 0 {
		return
	}
	if len(info.members) == 0 {
		info.members = added
		return
	}
	merged := make([]Symbol_Id, len(info.members) + len(added), c.semantic_allocator)
	copy(merged, info.members)
	copy(merged[len(info.members):], added)
	info.members = merged
}

@(private = "file")
new_associated_type :: proc(c: ^Compiler, name: string, value, owner: Type_Id) -> Symbol_Id {
	return new_symbol(c, Symbol {
		name        = intern_identifier(c, name),
		span        = no_span(),
		kind        = .Const,
		type        = TYPE_TYPE,
		const_value = type_const(value),
		owner_type  = owner,
		public      = true,
	})
}

synth_proc :: proc(
	c: ^Compiler,
	name: string,
	kind: Synth_Kind,
	owner: Type_Id,
	params: []Type_Id,
	modes: []Param_Mode,
	results: []Type_Id,
) -> Symbol_Id {
	param_copy := make([]Type_Id, len(params), c.semantic_allocator)
	result_copy := make([]Type_Id, len(results), c.semantic_allocator)
	copy(param_copy, params)
	copy(result_copy, results)
	id := new_symbol(c, Symbol {
		name          = intern_identifier(c, name),
		span          = no_span(),
		kind          = .Proc,
		public        = true,
		owner_type    = owner,
		params        = param_copy,
		results       = result_copy,
		param_symbols = make([]Symbol_Id, len(params), c.semantic_allocator),
		param_defaults = make([]Expr, len(params), c.semantic_allocator),
		result_symbols = make([]Symbol_Id, len(results), c.semantic_allocator),
		proc_type     = intern_proc_type(c, param_copy, modes, result_copy, make([]bool, len(results), c.semantic_allocator), ""),
		synth         = kind,
	})
	append(&c.synth_procs, id)
	return id
}

// ---------------------------------------------------------- the `iter` call --

// The compiler contributes the `iter` overload (design.md). A user type
// declares `iter` as an ordinary `impl` member, and this is what makes the free
// call in the `Iterable` requirement — and in generic code — find it.
check_iter_builtin :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident) {
	v.value_category = .Value
	if len(v.args) != 1 {
		errorf(k.c, v.span, "L0322", "`iter` takes 1 argument, found %d", len(v.args))
		v.type = INVALID_TYPE
		return
	}
	subject := check_single_expr(k, v.args[0].value)
	if subject == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}
	ensure_iteration_members(k, subject)
	chosen := iteration_member(k, subject, "iter")
	sym := symbol_of(k.c, chosen)
	iterator := associated_type_of(k, subject, "Iterator")
	if iterator == INVALID_TYPE || !iteration_proc_matches(k, sym, subject, .Value, []Type_Id{iterator}) {
		errorf(
			k.c,
			expr_span(v.args[0].value),
			"L0456",
			"`%s` is not iterable: it needs associated `Element` and `Iterator` members and an `iter` procedure",
			type_name(k.c, subject),
		)
		v.type = INVALID_TYPE
		return
	}
	bound := make([]Expr, 1, k.c.semantic_allocator)
	bound[0] = v.args[0].value
	v.bound = bound
	// Rewrite the callee to name the selected procedure, so every later phase —
	// the backend included — sees an ordinary direct call.
	annotate_chosen_callee(k, v, chosen)
	v.resolution = Resolution{kind = .Call, symbol = chosen, chosen_overload = chosen}
	v.type = sym.results[0]
}

@(private = "file")
iteration_proc_matches :: proc(
	k: ^Checker,
	sym: ^Symbol,
	parameter: Type_Id,
	mode: Param_Mode,
	results: []Type_Id,
) -> bool {
	if sym == nil || sym.kind != .Proc || len(sym.params) != 1 || sym.params[0] != parameter ||
	   len(sym.results) != len(results) {
		return false
	}
	info := type_of(k.c, sym.proc_type)
	if info == nil || info.convention != "" || len(info.param_modes) != 1 || info.param_modes[0] != mode {
		return false
	}
	for result, index in results {
		if sym.results[index] != result ||
		   (index < len(info.result_inout) && info.result_inout[index]) {
			return false
		}
	}
	return true
}

// One named member of an iterable, looked up without the extension table: the
// protocol is inherent.
iteration_member :: proc(k: ^Checker, type: Type_Id, name: string) -> Symbol_Id {
	ensure_iteration_members(k, type)
	info := underlying_info(k.c, type)
	if info == nil {
		return INVALID_SYMBOL
	}
	return member_named_in(k.c, info.members, intern_identifier(k.c, name))
}

// The associated type a member names, or INVALID_TYPE.
associated_type_of :: proc(k: ^Checker, type: Type_Id, name: string) -> Type_Id {
	member := iteration_member(k, type, name)
	sym := symbol_of(k.c, member)
	if sym == nil {
		return INVALID_TYPE
	}
	if sym.kind == .Type {
		return sym.type
	}
	if sym.kind == .Const {
		if sym.decl != nil && sym.decl.check_state == .Unchecked {
			check_member_decl_in_place(k, member, type)
			sym = symbol_of(k.c, member)
		}
		if sym.const_value.kind == .Type {
			return sym.const_value.type_value
		}
	}
	return INVALID_TYPE
}

// -------------------------------------------------------- runtime foreach --

check_runtime_foreach :: proc(k: ^Checker, s: ^Stmt_Foreach) -> Flow_Info {
	if len(s.bindings) == 0 || len(s.bindings) > 2 {
		errorf(k.c, s.span, "L0456", "a `foreach` binds one or two names")
		return FLOWS
	}

	outer := k.scope
	k.scope = new_scope(k.c, outer, .Local)
	defer k.scope = outer

	// A written range keeps its endpoints: the direct lowering never builds a
	// `Range(T)` value for it.
	if written, is_range := s.iterable.(^Expr_Range); is_range {
		return check_range_foreach(k, s, written)
	}

	subject := check_single_expr(k, s.iterable)
	if subject == INVALID_TYPE {
		return FLOWS
	}
	under := type_underlying(k.c, subject)
	info := type_of(k.c, under)
	if info == nil {
		return FLOWS
	}

	switch {
	case info.kind == .Array:
		s.kind = .Array
		s.element_type = info.element
		s.count = info.count
	case info.kind == .Slice:
		s.kind = .Slice
		s.element_type = info.element
	case info.kind == .Dynamic_Array:
		s.kind = .Dynamic
		s.element_type = info.element
	case info.kind == .Map:
		// Map values can be iterated by-reference, but map keys are immutable and
		// cannot be (design.md). One name binds the value; two bind the key and the
		// value, which is the exception to "value, index".
		s.kind = .Map
		s.element_type = info.element
		s.key_type = info.key
	case info.kind == .String || info.kind == .String_View:
		// String iteration yields Unicode scalar values by default; byte iteration
		// is explicit (design.md) — `foreach (b, i in text.bytes())`.
		s.kind = .Text
		s.element_type = TYPE_RUNE
	case info.is_range:
		s.kind = .Stored_Range
		s.element_type = info.element
	case:
		return check_protocol_foreach(k, s, subject)
	}

	// The index binding is a counter (design.md). A map is the exception — its
	// second name is the *value*, and that is the one a `&` may take.
	if len(s.bindings) == 2 && s.bindings[1].is_ref && s.kind != .Map {
		errorf(k.c, s.bindings[1].name.span, "L0457", "the index binding is a counter and cannot be taken by reference")
		return FLOWS
	}
	if s.kind == .Map {
		// Map values can be iterated by-reference, but map keys are immutable and
		// cannot be (design.md).
		key_binding := len(s.bindings) == 2 ? 0 : -1
		if key_binding >= 0 && s.bindings[key_binding].is_ref {
			errorf(
				k.c, s.bindings[key_binding].name.span, "L0591",
				"a map key is immutable, so it cannot be iterated by reference; write `foreach (key, &value in m)`",
			)
			return FLOWS
		}
		value_binding := len(s.bindings) == 2 ? 1 : 0
		if s.bindings[value_binding].is_ref && !expr_base(s.iterable).assignable {
			report_not_assignable(k, expr_base(s.iterable), "a by-reference `foreach`")
			return FLOWS
		}
		return check_map_foreach_body(k, s)
	}
	// Element assignment and iteration by reference require `[]mut T` (design.md
	// "Slices"). The capability is the slice's own, not whether the variable
	// holding it can be rebound.
	if s.kind == .Slice {
		if s.bindings[0].is_ref && !info.mutable {
			errorf(
				k.c,
				s.bindings[0].name.span,
				"L0480",
				"`%s` yields read-only elements, so it cannot be iterated by reference; use `[]mut %s`",
				type_name(k.c, subject),
				type_name(k.c, info.element),
			)
			return FLOWS
		}
	} else if s.kind != .Text && s.bindings[0].is_ref && !expr_base(s.iterable).assignable {
		report_not_assignable(k, expr_base(s.iterable), "a by-reference `foreach`")
		return FLOWS
	}
	if s.kind == .Stored_Range && s.bindings[0].is_ref {
		errorf(k.c, s.bindings[0].name.span, "L0457", "a range produces values, so it cannot be iterated by reference")
		return FLOWS
	}
	if s.kind == .Text && s.bindings[0].is_ref {
		errorf(
			k.c, s.bindings[0].name.span, "L0564",
			"a string yields decoded code points, so it cannot be iterated by reference",
		)
		return FLOWS
	}
	return check_foreach_body(k, s, s.element_type)
}

// design.md's example is `foreach (key, &value in some_map)`. The first of two
// names is the key, not a counter, so the ordinary body binder cannot be reused
// as is.
@(private = "file")
check_map_foreach_body :: proc(k: ^Checker, s: ^Stmt_Foreach) -> Flow_Info {
	if len(s.bindings) == 1 {
		return check_foreach_body(k, s, s.element_type)
	}
	if !gate_type(k, s.key_type, expr_span(s.iterable)) ||
	   !gate_type(k, s.element_type, expr_span(s.iterable)) {
		return FLOWS
	}
	// Map values can be iterated by-reference, but map keys are immutable and
	// cannot be (design.md). An immutable key binding is therefore a
	// *borrow* of the stored key rather than a copy — which is what lets
	// `map[string]V` be iterated at all, and why no per-iteration clone or drop
	// is needed for it. The loop's whole-container loan is what keeps that
	// borrow valid across the back-edge.
	if !s.bindings[1].is_ref && type_is_managed(k.c, s.element_type) {
		errorf(
			k.c, s.bindings[1].name.span, "L0504",
			"a by-value `foreach` over `%s` copies a managed value, which M5a does not clean up per iteration; write `&%s`",
			type_name(k.c, s.element_type),
			s.bindings[1].name.text,
		)
		return FLOWS
	}
	s.bindings[0].symbol = bind_loop_name(k, s.bindings[0], s.key_type, false)
	s.bindings[1].symbol = bind_loop_name(k, s.bindings[1], s.element_type, s.bindings[1].is_ref)

	incoming := clone_result_assignments(k.c, k.assigned_results)
	k.loop_depth += 1
	body := check_scoped_block(k, s.body)
	k.loop_depth -= 1
	k.assigned_results = incoming
	return Flow_Info{can_fall_through = true, returns = body.returns}
}

@(private = "file")
check_range_foreach :: proc(k: ^Checker, s: ^Stmt_Foreach, written: ^Expr_Range) -> Flow_Info {
	element := check_single_expr(k, written)
	if element == INVALID_TYPE {
		return FLOWS
	}
	if s.bindings[0].is_ref {
		errorf(k.c, s.bindings[0].name.span, "L0457", "a range produces values, so it cannot be iterated by reference")
		return FLOWS
	}
	s.kind = .Range
	s.element_type = underlying_info(k.c, element).element
	return check_foreach_body(k, s, s.element_type)
}

// design.md "Iteration protocol": associated `Element` and `Iterator`,
// `iter(value)`, and `next(self: inout Iterator) -> (Element, bool)`.
@(private = "file")
check_protocol_foreach :: proc(k: ^Checker, s: ^Stmt_Foreach, subject: Type_Id) -> Flow_Info {
	if s.bindings[0].is_ref {
		// design.md "By-reference iteration": by-reference `foreach` is a
		// built-in-container facility, and the protocol has only value-producing
		// `next`.
		errorf(
			k.c,
			s.bindings[0].name.span,
			"L0457",
			"`%s` cannot be iterated by reference; expose a mutable slice or an indexed `inout` operation instead",
			type_name(k.c, subject),
		)
		return FLOWS
	}
	element := associated_type_of(k, subject, "Element")
	iterator := associated_type_of(k, subject, "Iterator")
	iter := iteration_member(k, subject, "iter")
	iter_sym := symbol_of(k.c, iter)
	if element == INVALID_TYPE || iterator == INVALID_TYPE ||
	   !iteration_proc_matches(k, iter_sym, subject, .Value, []Type_Id{iterator}) {
		errorf(
			k.c,
			expr_span(s.iterable),
			"L0456",
			"`%s` is not iterable: it needs associated `Element` and `Iterator` members and an `iter` procedure",
			type_name(k.c, subject),
		)
		return FLOWS
	}
	// Bare `foreach` never selects `iter_reverse`: only `iter` is consulted here,
	// and a user `iter_reverse` stays an ordinary callable overload.
	next := iteration_member(k, iterator, "next")
	next_sym := symbol_of(k.c, next)
	if !iteration_proc_matches(k, next_sym, iterator, .Inout, []Type_Id{element, TYPE_BOOL}) {
		errorf(
			k.c,
			expr_span(s.iterable),
			"L0456",
			"`%s` needs `next :: proc(self: inout %s) -> (%s, bool)`",
			type_name(k.c, iterator),
			type_name(k.c, iterator),
			type_name(k.c, element),
		)
		return FLOWS
	}

	s.kind = .Protocol
	s.element_type = element
	s.iterator_type = iterator
	s.iter_symbol = iter
	s.next_symbol = next
	return check_foreach_body(k, s, element)
}

@(private = "file")
check_foreach_body :: proc(k: ^Checker, s: ^Stmt_Foreach, element: Type_Id) -> Flow_Info {
	if !gate_type(k, element, expr_span(s.iterable)) {
		return FLOWS
	}
	// By default each iterated value is a copy (design.md). A managed element
	// would therefore need a per-iteration clone and a per-iteration drop, which
	// is loop-body cleanup the M5a CFG does not place yet.
	if !s.bindings[0].is_ref && type_is_managed(k.c, element) {
		errorf(
			k.c,
			s.bindings[0].name.span,
			"L0504",
			"a by-value `foreach` over `%s` copies a managed element, which M5a does not clean up per iteration; iterate `&value` over a `[]mut %s`, or index the sequence",
			type_name(k.c, element),
			type_name(k.c, element),
		)
		return FLOWS
	}
	s.bindings[0].symbol = bind_loop_name(k, s.bindings[0], element, s.bindings[0].is_ref)
	if len(s.bindings) == 2 {
		s.bindings[1].symbol = bind_loop_name(k, s.bindings[1], TYPE_INT, false)
	}

	incoming := clone_result_assignments(k.c, k.assigned_results)
	k.loop_depth += 1
	body := check_scoped_block(k, s.body)
	k.loop_depth -= 1
	// A `foreach` may execute zero times, so nothing the body assigns is
	// guaranteed on the way out.
	k.assigned_results = incoming
	return Flow_Info{can_fall_through = true, returns = body.returns}
}

@(private = "file")
bind_loop_name :: proc(k: ^Checker, binding: Foreach_Binding, type: Type_Id, mutable: bool) -> Symbol_Id {
	if binding.name.text == "_" || binding.name.text == "" {
		return INVALID_SYMBOL
	}
	id := binding.name.id
	if id == INVALID_IDENTIFIER {
		id = intern_identifier(k.c, binding.name.text)
	}
	symbol := new_symbol(k.c, Symbol {
		name      = id,
		span      = binding.name.span,
		kind      = .Var,
		type      = type,
		pkg       = k.pkg,
		// By default each iterated value is a copy, and assignment to the copy
		// does not modify the source; `&value` makes the binding the element.
		immutable = !mutable,
	})
	k.scope.names[id] = symbol
	return symbol
}

// ------------------------------------------------------- range expressions --

// `a ..< b` and `a ..= b` as a value. design.md gives no comparison or
// arithmetic operations on a range, so this only builds one.
check_range :: proc(k: ^Checker, v: ^Expr_Range) {
	v.value_category = .Value
	low := check_single_expr(k, v.lo)
	high := check_single_expr(k, v.hi)
	if low == INVALID_TYPE || high == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}
	element, unified := unify_range_endpoints(k, v, low, high)
	if !unified {
		v.type = INVALID_TYPE
		return
	}
	if !type_is_integer(k.c, element) && !type_is_rune(k.c, element) {
		errorf(
			k.c,
			v.op_span,
			"L0458",
			"a range needs integer or rune endpoints, found `%s`",
			type_name(k.c, element),
		)
		v.type = INVALID_TYPE
		return
	}
	v.type = range_type(k.c, element)
	ensure_iteration_members(k, v.type)
}

@(private = "file")
unify_range_endpoints :: proc(k: ^Checker, v: ^Expr_Range, low, high: Type_Id) -> (Type_Id, bool) {
	if low == high {
		return type_is_untyped(k.c, low) ? default_type(k.c, low) : low, true
	}
	// One untyped endpoint takes the other's concrete type, as an arithmetic
	// operand would.
	switch {
	case type_is_untyped(k.c, low) && type_is_untyped(k.c, high):
		merged := default_type(k.c, low)
		return merged, materialize(k, v.lo, merged) && materialize(k, v.hi, merged)
	case type_is_untyped(k.c, low):
		return high, materialize(k, v.lo, high)
	case type_is_untyped(k.c, high):
		return low, materialize(k, v.hi, low)
	}
	errorf(
		k.c,
		v.op_span,
		"L0458",
		"a range's endpoints must have the same type, found `%s` and `%s`",
		type_name(k.c, low),
		type_name(k.c, high),
	)
	return INVALID_TYPE, false
}

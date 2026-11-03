// Runtime `foreach` and the iteration protocol.
//
// A `foreach` over a built-in lowers directly to a loop, while the compiler also
// contributes `Element`, `Iterator`, `iter` and `next`, so the same value
// satisfies `Iterable` in generic code. `Range(T)` is an ordinary compiler-owned
// struct, so a range survives being stored or passed.
package lokec

import "core:fmt"

RANGE_LOW :: 0
RANGE_HIGH :: 1
RANGE_CLOSED :: 2

ITER_RANGE_CURRENT :: 0
ITER_RANGE_HIGH :: 1
ITER_RANGE_CLOSED :: 2
ITER_RANGE_REVERSED :: 3

ITER_ARRAY_DATA :: 0
ITER_ARRAY_INDEX :: 1
ITER_ARRAY_REVERSED :: 2

ITER_MAP_TABLE :: 0
ITER_MAP_CURSOR :: 1

// A view holds one thing (a map's table pointer or a `string_view`); its
// iterator adds a cursor.
VIEW_SOURCE :: 0
ITER_TEXT_VIEW :: 0
ITER_TEXT_OFFSET :: 1

// Which traversal a contributed view names.
View_Kind :: enum {
	None,
	Entries,
	Keys,
	Values,
	Rune_Offsets,
}

View_Key :: struct {
	source: Type_Id,
	kind:   View_Kind,
}

// ---------------------------------------------------------- range values --

range_type :: proc(c: ^Compiler, element: Type_Id) -> Type_Id {
	if existing, found := c.range_types[element]; found {
		return existing
	}
	fields := make([]Symbol_Id, 3, c.semantic_allocator)
	fields[RANGE_LOW] = new_field(c, "low", element, RANGE_LOW, public = true)
	fields[RANGE_HIGH] = new_field(c, "high", element, RANGE_HIGH, public = true)
	fields[RANGE_CLOSED] = new_field(c, "closed", TYPE_BOOL, RANGE_CLOSED, public = true)
	type := new_type(c, Type_Info{
		kind = .Struct, element = element, is_range = true, fields = fields,
		name = intern_identifier(c, fmt.tprintf("Range(%s)", type_name(c, element))),
		backend_label = fmt.aprintf("Range.%s", type_name(c, element), allocator = c.semantic_allocator),
	})
	c.range_types[element] = type
	return type
}

// `Range` is predeclared, like `Simd`, and a program's own `Range` shadows it.
range_callee :: proc(k: ^Checker, callee: Expr) -> bool {
	ident, is_ident := callee.(^Expr_Ident)
	if !is_ident || ident.name != "Range" {
		return false
	}
	return lookup_symbol(k.scope, identifier_of(k.c, ident)) == INVALID_SYMBOL
}

// `Range(T)` in type position.
resolve_range_application :: proc(k: ^Checker, v: ^Expr_Call) -> Type_Id {
	if v.denoted_type != INVALID_TYPE {
		return v.denoted_type
	}
	if len(v.args) != 1 || v.args[0].name.text != "" {
		errorf(k.c, v.span, "L0689", "`Range` takes one endpoint type, as in `Range(int)`")
		return INVALID_TYPE
	}
	element := resolve_type_syntax(k, v.args[0].value)
	if element == INVALID_TYPE {
		report_unresolved_type(k, v.args[0].value)
		return INVALID_TYPE
	}
	if !require_range_endpoint(k, element, expr_span(v.args[0].value)) {
		return INVALID_TYPE
	}
	v.denoted_type = range_type(k.c, element)
	ensure_iteration_members(k, v.denoted_type)
	v.resolution.kind = .Type
	v.value_category = .Type
	return v.denoted_type
}

@(private = "file")
require_range_endpoint :: proc(k: ^Checker, element: Type_Id, span: Span) -> bool {
	if type_is_integer(k.c, element) || type_is_rune(k.c, element) {
		return true
	}
	errorf(k.c, span, "L0458", "a range needs integer or rune endpoints, found `%s`", type_name(k.c, element))
	return false
}

// `a ..< b` and `a ..= b` as a value. An expected `Range(T)` gives two
// unfixed endpoints their type.
check_range :: proc(k: ^Checker, v: ^Expr_Range, expected := INVALID_TYPE) {
	v.value_category = .Value
	low := check_single_expr(k, v.lo)
	high := check_single_expr(k, v.hi)
	if low == INVALID_TYPE || high == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}
	hint := INVALID_TYPE
	if info := type_of(k.c, expected); expected != INVALID_TYPE && info != nil && info.is_range {
		hint = info.element
	}
	element, unified := unify_range_endpoints(k, v, low, high, hint)
	if !unified || !require_range_endpoint(k, element, v.op_span) {
		v.type = INVALID_TYPE
		return
	}
	v.type = range_type(k.c, element)
	ensure_iteration_members(k, v.type)
}

@(private = "file")
unify_range_endpoints :: proc(k: ^Checker, v: ^Expr_Range, low, high, hint: Type_Id) -> (Type_Id, bool) {
	if low == high && !type_is_untyped(k.c, low) {
		return low, true
	}
	// Untyped endpoints are materialized, so an out-of-range constant is reported.
	switch {
	case type_is_untyped(k.c, low) && type_is_untyped(k.c, high):
		merged := hint != INVALID_TYPE ? hint : default_type(k.c, low)
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

// ------------------------------------------------------- element records --

// Element records are ordinary anonymous records (design.md "Element bindings").

ELEMENT_FIRST :: 0
ELEMENT_SECOND :: 1

// A map's `Element`: `(key: K, value: V)` (design.md "Iteration adapters").
map_entry_type :: proc(c: ^Compiler, subject: Type_Id) -> Type_Id {
	info := type_of(c, subject)
	return anon_record_type(c, []Anon_Member{
		{name = intern_identifier(c, "key"), type = info.key},
		{name = intern_identifier(c, "value"), type = info.element},
	})
}

// `indexed()`'s `Element`: `(value: E, index: int)`.
indexed_element_type :: proc(c: ^Compiler, element: Type_Id) -> Type_Id {
	return anon_record_type(c, []Anon_Member{
		{name = intern_identifier(c, "value"), type = element},
		{name = intern_identifier(c, "index"), type = TYPE_INT},
	})
}

// `rune_offsets()`'s `Element`: `(value: rune, offset: int)`, a byte offset.
@(private = "file")
rune_offset_type :: proc(c: ^Compiler) -> Type_Id {
	return anon_record_type(c, []Anon_Member{
		{name = intern_identifier(c, "value"), type = TYPE_RUNE},
		{name = intern_identifier(c, "offset"), type = TYPE_INT},
	})
}

// ------------------------------------------------------- iterator types --

@(private = "file")
range_iterator_type :: proc(c: ^Compiler, range: Type_Id) -> Type_Id {
	if existing, found := c.iterator_types[range]; found {
		return existing
	}
	element := type_of(c, range).element
	fields := make([]Symbol_Id, 4, c.semantic_allocator)
	fields[ITER_RANGE_CURRENT] = new_field(c, "current", element, ITER_RANGE_CURRENT)
	fields[ITER_RANGE_HIGH] = new_field(c, "high", element, ITER_RANGE_HIGH)
	fields[ITER_RANGE_CLOSED] = new_field(c, "closed", TYPE_BOOL, ITER_RANGE_CLOSED)
	fields[ITER_RANGE_REVERSED] = new_field(c, "reversed", TYPE_BOOL, ITER_RANGE_REVERSED)
	type := new_type(c, Type_Info{
		kind = .Struct, element = element, fields = fields,
		name = intern_identifier(c, fmt.tprintf("Range_Iterator(%s)", type_name(c, element))),
		backend_label = fmt.aprintf("Range_Iterator.%s", type_name(c, element), allocator = c.semantic_allocator),
	})
	c.iterator_types[range] = type
	return type
}

// `holds` is what the iterator stores: a slice for runtime arrays, otherwise
// the iterable itself. The cache key stays the iterable.
@(private = "file")
array_iterator_type :: proc(c: ^Compiler, array, holds: Type_Id) -> Type_Id {
	if existing, found := c.iterator_types[array]; found {
		return existing
	}
	element := type_of(c, array).element
	fields := make([]Symbol_Id, 3, c.semantic_allocator)
	fields[ITER_ARRAY_DATA] = new_field(c, "data", holds, ITER_ARRAY_DATA)
	fields[ITER_ARRAY_INDEX] = new_field(c, "index", TYPE_INT, ITER_ARRAY_INDEX)
	fields[ITER_ARRAY_REVERSED] = new_field(c, "reversed", TYPE_BOOL, ITER_ARRAY_REVERSED)
	type := new_type(c, Type_Info{
		kind = .Struct, element = element, fields = fields,
		name = intern_identifier(c, fmt.tprintf("Array_Iterator(%s)", type_name(c, array))),
		backend_label = fmt.aprintf("Array_Iterator.%s", type_name(c, array), allocator = c.semantic_allocator),
		descriptor = type_is_compile_time_only(c, element),
	})
	c.iterator_types[array] = type
	return type
}

// A slot walk over a raw table pointer: the iterator borrows the map, so there
// is no second header to drop.
@(private = "file")
map_iterator_type :: proc(c: ^Compiler, subject: Type_Id) -> Type_Id {
	if existing, found := c.iterator_types[subject]; found {
		return existing
	}
	type := new_map_cursor_type(c, subject, map_entry_type(c, subject), "Map_Iterator")
	c.iterator_types[subject] = type
	return type
}

// `{ table, cursor }` over `subject`, named `label`. `key` is there because `next`
// needs the map's operation table.
new_map_cursor_type :: proc(c: ^Compiler, subject, element: Type_Id, label: string) -> Type_Id {
	fields := make([]Symbol_Id, 2, c.semantic_allocator)
	fields[ITER_MAP_TABLE] = new_field(c, "table", TYPE_RAWPTR, ITER_MAP_TABLE)
	fields[ITER_MAP_CURSOR] = new_field(c, "cursor", TYPE_INT, ITER_MAP_CURSOR)
	return new_type(c, Type_Info{
		kind = .Struct, element = element, key = subject, is_view = true, fields = fields,
		name = intern_identifier(c, fmt.tprintf("%s(%s)", label, type_name(c, subject))),
		backend_label = fmt.aprintf("%s.%s", label, type_name(c, subject), allocator = c.semantic_allocator),
	})
}

// --------------------------------------------------------- container views --

// design.md "Iteration adapters": `entries()`, `keys()`, `values()` and
// `rune_offsets()` are one-field borrowed values, cheap to create and copy.
container_view_type :: proc(c: ^Compiler, source: Type_Id, kind: View_Kind) -> Type_Id {
	key := View_Key{source = source, kind = kind}
	if existing, found := c.view_types[key]; found {
		return existing
	}
	label, held, element := "", INVALID_TYPE, INVALID_TYPE
	#partial switch kind {
	case .Entries:
		label, held, element = "Map_Entries", TYPE_RAWPTR, map_entry_type(c, source)
	case .Keys:
		label, held, element = "Map_Keys", TYPE_RAWPTR, type_of(c, source).key
	case .Values:
		label, held, element = "Map_Values", TYPE_RAWPTR, type_of(c, source).element
	case .Rune_Offsets:
		label, held, element = "Rune_Offsets", TYPE_STRING_VIEW, rune_offset_type(c)
	}
	// One rune-offset view serves every text type; a map view names its map.
	text := kind == .Rune_Offsets
	spelling := text ? label : fmt.tprintf("%s(%s)", label, type_name(c, source))
	fields := make([]Symbol_Id, 1, c.semantic_allocator)
	fields[VIEW_SOURCE] = new_field(c, "source", held, VIEW_SOURCE)
	type := new_type(c, Type_Info{
		kind = .Struct, element = element, is_view = true, view_kind = kind, fields = fields,
		name = intern_identifier(c, spelling),
		key = text ? INVALID_TYPE : source,
		backend_label = text ? label : fmt.aprintf("%s.%s", label, type_name(c, source), allocator = c.semantic_allocator),
	})
	c.view_types[key] = type
	return type
}

// `{ table, cursor }` again, for a traversal that yields one half of the slot.
@(private = "file")
map_view_iterator_type :: proc(c: ^Compiler, view: Type_Id, label: string) -> Type_Id {
	if existing, found := c.iterator_types[view]; found {
		return existing
	}
	info := type_of(c, view)
	type := new_map_cursor_type(c, info.key, info.element, label)
	c.iterator_types[view] = type
	return type
}

// A byte cursor advanced by the runtime's UTF-8 decoder, shared by every text
// type per yielded `Element`.
@(private = "file")
text_iterator_type :: proc(c: ^Compiler, cache_key: Type_Id, element: Type_Id, label: string) -> Type_Id {
	if existing, found := c.iterator_types[cache_key]; found {
		return existing
	}
	fields := make([]Symbol_Id, 2, c.semantic_allocator)
	fields[ITER_TEXT_VIEW] = new_field(c, "view", TYPE_STRING_VIEW, ITER_TEXT_VIEW)
	fields[ITER_TEXT_OFFSET] = new_field(c, "offset", TYPE_INT, ITER_TEXT_OFFSET)
	type := new_type(c, Type_Info{
		kind = .Struct, element = element, is_view = true, fields = fields,
		name = intern_identifier(c, label), backend_label = label,
	})
	c.iterator_types[cache_key] = type
	return type
}

// --------------------------------------------- compiler-contributed members --

// Installs `Element`, `Iterator`, `iter` and the iterator's `next` on a built-in
// iterable. Guarded by a flag, since other contributions share the member table.
ensure_iteration_members :: proc(k: ^Checker, type: Type_Id) {
	under := type_underlying(k.c, type)
	info := type_of(k.c, under)
	if info == nil || .Iteration in info.contributed {
		return
	}
	info.contributed += {.Iteration}
	traversal, iterable := builtin_traversal(k.c, under, info)
	if !iterable {
		return
	}
	element, iterator, next_kind := traversal.element, traversal.iterator, traversal.next

	// design.md "Borrowing iteration": stored elements are lent. An owned managed
	// `Element` needs its copy and drop before the iterator's body asks.
	lends := next_kind == .Slice_Ref_Next || next_kind == .Map_Next ||
	         next_kind == .Map_Keys_Next || next_kind == .Map_Values_Next
	if !lends && type_is_managed(k.c, element) {
		contribute_lifecycle_members(k, element)
	}

	members := make([dynamic]Symbol_Id, 0, 4, k.c.semantic_allocator)
	append(&members, new_associated_type(k.c, "Element", element, under))
	append(&members, new_associated_type(k.c, "Iterator", iterator, under))
	append(&members, synth_self_member(k.c, "iter", traversal.iter, under, .Borrow, iterator))
	if traversal.iter_reverse != .None {
		append(&members, synth_self_member(k.c, "iter_reverse", traversal.iter_reverse, under, .Borrow, iterator))
	}
	add_members(k.c, under, members[:])

	// `next` goes on the iterator, which two iterables may share (a `string` and
	// a `string_view`), so it carries its own contribution flag.
	iterator_info := type_of(k.c, iterator)
	if iterator_info == nil || .Iteration in iterator_info.contributed {
		return
	}
	iterator_info.contributed += {.Iteration}
	// A copying `next` over a move-only element has no copy to make.
	if next_kind == .Array_Next && type_clone_disabled(k.c, element) { return }
	// A map lends a record of two pointers, since the table never holds a record.
	item := lends ? pointer_to(k.c, element, false) : element
	if next_kind == .Map_Next {
		lent := yield_pair(k.c, Yield_Desc{kind = .Borrowed}, Yield_Desc{kind = .Borrowed})
		item = yield_item_type(k, element, lent, no_span())
		if item == INVALID_TYPE { return }
	}
	next := synth_receiver_proc(
		k.c, "next", next_kind, iterator,
		[]Type_Id{iterator}, []Param_Mode{.Inout}, option_type(k, item),
	)
	add_members(k.c, iterator, []Symbol_Id{next})
}

// What a built-in iterable contributes, before any member is made of it.
@(private = "file")
Builtin_Traversal :: struct {
	element, iterator:        Type_Id,
	iter, iter_reverse, next: Synth_Kind,
}

// False for a type that is not a built-in iterable.
@(private = "file")
builtin_traversal :: proc(c: ^Compiler, under: Type_Id, info: ^Type_Info) -> (t: Builtin_Traversal, ok: bool) {
	t.element = info.element
	switch {
	case info.is_range:
		t.iterator = range_iterator_type(c, under)
		t.iter, t.iter_reverse, t.next = .Range_Iter, .Range_Iter_Reverse, .Range_Next
	case info.kind == .Array:
		t.iter, t.iter_reverse = .Array_Iter, .Array_Iter_Reverse
		// A compile-time-only element has no storage to lend.
		if type_is_compile_time_only(c, t.element) {
			t.iterator = array_iterator_type(c, under, under)
			t.next = .Array_Next
		} else {
			t.iterator = array_iterator_type(c, under, slice_of(c, t.element, mutable = false))
			t.next = .Slice_Ref_Next
		}
	case info.kind == .Slice:
		// An array's `iter`, holding the slice itself.
		t.iterator = array_iterator_type(c, under, under)
		t.iter, t.iter_reverse, t.next = .Array_Iter, .Array_Iter_Reverse, .Slice_Ref_Next
	case info.kind == .Dynamic_Array:
		// Iterates exactly like a slice of its current contents.
		t.iterator = array_iterator_type(c, under, slice_of(c, t.element, mutable = false))
		t.iter, t.iter_reverse, t.next = .Dynamic_Iter, .Dynamic_Iter_Reverse, .Slice_Ref_Next
	case info.kind == .Map:
		t.element = map_entry_type(c, under)
		t.iterator = map_iterator_type(c, under)
		t.iter, t.next = .Map_Iter, .Map_Next
	case info.kind == .String || info.kind == .String_View:
		t.element = TYPE_RUNE
		t.iterator = text_iterator_type(c, TYPE_STRING_VIEW, TYPE_RUNE, "Text_Iterator")
		t.iter, t.next = .Text_Iter, .Text_Next
	case info.view_kind == .Rune_Offsets:
		t.iterator = text_iterator_type(c, under, t.element, "Rune_Offset_Iterator")
		t.iter, t.next = .Text_Iter, .Rune_Offsets_Next
	case info.view_kind == .Entries:
		// Yields the map's own `Element`, so it reuses the map's iterator.
		t.iterator = map_iterator_type(c, info.key)
		t.iter, t.next = .Map_View_Iter, .Map_Next
	case info.view_kind == .Keys:
		t.iterator = map_view_iterator_type(c, under, "Map_Keys_Iterator")
		t.iter, t.next = .Map_View_Iter, .Map_Keys_Next
	case info.view_kind == .Values:
		t.iterator = map_view_iterator_type(c, under, "Map_Values_Iterator")
		t.iter, t.next = .Map_View_Iter, .Map_Values_Next
	case:
		return t, false
	}
	return t, true
}

iteration_proc_matches :: proc(
	k: ^Checker,
	sym: ^Symbol,
	parameter: Type_Id,
	mode: Param_Mode,
	result: Type_Id,
) -> bool {
	if sym == nil || sym.kind != .Proc || len(sym.params) != 1 || sym.params[0] != parameter ||
	   sym.result != result {
		return false
	}
	info := type_of(k.c, sym.proc_type)
	if info == nil || info.convention != "" || len(info.param_modes) != 1 {
		return false
	}
	// design.md "Receiver forms": a view of the source is `self: ^`; an `iter`
	// that borrows nothing from it may take a plain value `self`.
	if info.param_modes[0] != mode && !(mode == .Borrow && info.param_modes[0] == .Value) {
		return false
	}
	return !info.result_inout
}

// One protocol member, looked up from the declaration's own package.
iteration_member :: proc(k: ^Checker, type: Type_Id, name: string) -> Symbol_Id {
	member := find_member(k, type, intern_identifier(k.c, name))
	group := symbol_of(k.c, member)
	if group == nil || group.kind != .Proc_Group {
		return member
	}
	// Protocol calls have only their receiver. Ignore overloads taking more
	// arguments, and leave multiple receiver-only overloads ambiguous.
	found := INVALID_SYMBOL
	for candidate in group.members {
		sym := symbol_of(k.c, candidate)
		if sym == nil || sym.kind != .Proc || sym.bound_excluded || !sym.has_receiver ||
		   len(sym.params) != 1 || sym.params[0] != type {
			continue
		}
		if found != INVALID_SYMBOL {
			return member
		}
		found = candidate
	}
	return found != INVALID_SYMBOL ? found : member
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
			check_symbol_decl_in_place(k, member, type)
			sym = symbol_of(k.c, member)
		}
		if const_names_type(k.c, sym.const_value, sym.type) {
			return sym.const_value.type_value
		}
	}
	return INVALID_TYPE
}

// -------------------------------------------------------- runtime foreach --

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

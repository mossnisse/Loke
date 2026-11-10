// Ranges and the iteration protocol's built-in side.
//
// The compiler contributes `Element`, `Iterator`, `iter` and `next` to a built-in,
// so the same value satisfies `Iterable` in generic code. `Range(T)` is an
// ordinary compiler-owned struct, so a range survives being stored or passed.
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

// An adapter view holds its source, or a pointer to it. The iterator
// `indexed()` or `copied()` makes wraps the source's iterator, and `indexed()`
// adds a counter.
ADAPTER_SOURCE :: 0
ITER_ADAPTER_INNER :: 0
ITER_ADAPTER_INDEX :: 1

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
	type := new_owned_record(c, "Range", element, {
		RANGE_LOW = {"low", element, true},
		RANGE_HIGH = {"high", element, true},
		RANGE_CLOSED = {"closed", TYPE_BOOL, true},
	}, {element = element, is_range = true})
	c.range_types[element] = type
	return type
}

// `Range(T)` in type position.
resolve_range_application :: proc(k: ^Checker, v: ^Expr_Call) -> Type_Id {
	if v.denoted_type != INVALID_TYPE {
		return v.denoted_type
	}
	if !has_one_plain_argument(v) {
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
		return
	}
	hint := INVALID_TYPE
	if info := type_of(k.c, expected); expected != INVALID_TYPE && info != nil && info.is_range {
		hint = info.element
	}
	element, unified := unify_range_endpoints(k, v, low, high, hint)
	if !unified || !require_range_endpoint(k, element, v.op_span) {
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

// A field of a compiler-made record, at its position in the list.
Owned_Field :: struct {
	name:   string,
	type:   Type_Id,
	public: bool,
}

// The field symbols of a compiler-made record, numbered by position.
owned_fields :: proc(c: ^Compiler, fields: []Owned_Field) -> []Symbol_Id {
	ids := make([]Symbol_Id, len(fields), c.semantic_allocator)
	for field, index in fields {
		ids[index] = new_field(c, field.name, field.type, index, field.public)
	}
	return ids
}

// A compiler-made record of `fields`, with what `base` says besides. It is
// `label(over)` to a reader and `label.over` to the backend, spelled from names
// rather than ids, or plain `label` when it is made over no type.
new_owned_record :: proc(c: ^Compiler, label: string, over: Type_Id, fields: []Owned_Field, base: Type_Info = {}) -> Type_Id {
	info := base
	info.kind = .Struct
	info.fields = owned_fields(c, fields)
	if over == INVALID_TYPE {
		info.name = intern_identifier(c, label)
		info.backend_label = label
	} else {
		over_name := type_name(c, over)
		info.name = intern_identifier(c, fmt.tprintf("%s(%s)", label, over_name))
		info.backend_label = fmt.aprintf("%s.%s", label, over_name, allocator = c.semantic_allocator)
	}
	return new_type(c, info)
}

@(private = "file")
range_iterator_type :: proc(c: ^Compiler, range: Type_Id) -> Type_Id {
	if existing, found := c.iterator_types[range]; found {
		return existing
	}
	element := type_of(c, range).element
	type := new_owned_record(c, "Range_Iterator", element, {
		ITER_RANGE_CURRENT = {"current", element, false},
		ITER_RANGE_HIGH = {"high", element, false},
		ITER_RANGE_CLOSED = {"closed", TYPE_BOOL, false},
		ITER_RANGE_REVERSED = {"reversed", TYPE_BOOL, false},
	}, {element = element})
	c.iterator_types[range] = type
	return type
}

// The iterator of a sequence `subject`, holding `data` under the name `data_name`.
array_iterator_record :: proc(c: ^Compiler, label: string, subject, data: Type_Id, data_name: string, base: Type_Info) -> Type_Id {
	return new_owned_record(c, label, subject, {
		ITER_ARRAY_DATA = {data_name, data, false},
		ITER_ARRAY_INDEX = {"index", TYPE_INT, false},
		ITER_ARRAY_REVERSED = {"reversed", TYPE_BOOL, false},
	}, base)
}

// `holds` is what the iterator stores: a slice for runtime arrays, otherwise
// the iterable itself. The cache key stays the iterable.
@(private = "file")
array_iterator_type :: proc(c: ^Compiler, array, holds: Type_Id) -> Type_Id {
	if existing, found := c.iterator_types[array]; found {
		return existing
	}
	element := type_of(c, array).element
	type := array_iterator_record(c, "Array_Iterator", array, holds, "data", {
		element = element, descriptor = type_is_compile_time_only(c, element),
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
	return new_owned_record(c, label, subject, {
		ITER_MAP_TABLE = {"table", TYPE_RAWPTR, false},
		ITER_MAP_CURSOR = {"cursor", TYPE_INT, false},
	}, {element = element, key = subject, is_view = true})
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
	over := kind == .Rune_Offsets ? INVALID_TYPE : source
	type := new_owned_record(c, label, over, {VIEW_SOURCE = {"source", held, false}}, {
		element = element, is_view = true, view_kind = kind, key = over,
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
	type := new_owned_record(c, label, INVALID_TYPE, {
		ITER_TEXT_VIEW = {"view", TYPE_STRING_VIEW, false},
		ITER_TEXT_OFFSET = {"offset", TYPE_INT, false},
	}, {element = element, is_view = true})
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
		item = yield_item_type(k, element, lent, NO_SPAN)
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
	if sym := symbol_of(k.c, member); sym != nil && sym.kind == .Type {
		return sym.type
	}
	return const_type_value(k, member, type)
}

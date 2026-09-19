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

// A procedure the compiler contributes: a real symbol whose body the backend
// writes by shape.
Synth_Kind :: enum {
	None,
	Adapter_View,
	Adapter_Iter,
	Indexed_Next,
	Copied_Next,
	Iterator_Copy,
	// Receiver forms of the built-in `len`, `cap` and `hash`.
	Standard_Len,
	Standard_Cap,
	Standard_Hash,
	Range_Iter,
	Range_Iter_Reverse,
	Range_Next,
	Array_Iter,
	Array_Iter_Reverse,
	Array_Next,
	Slice_Next,
	Slice_Mut_Next,
	Slice_Ref_Next,
	// Builds a slice's `{ data, index }`, so `next` is the slice one.
	Dynamic_Iter,
	Dynamic_Iter_Reverse,
	Map_Iter,
	Map_Next,
	Map_Keys_Next,
	Map_Values_Next,
	Map_View_Iter,
	// Serves `string`, `string_view` and the rune-offset view alike.
	Text_Iter,
	Text_Next,
	Rune_Offsets_Next,
	Try_Clone,
	Clone,
	Dyn_Forward,
	// Which operation is `Symbol.container_op`.
	Container_Op,
	// Which operation is `Symbol.provider_op`.
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
		info.mangled = fmt.aprintf("Range.%s", llvm_safe(type_name(c, element), allocator = context.temp_allocator), allocator = c.semantic_allocator)
	}
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
	if !type_is_integer(k.c, element) && !type_is_rune(k.c, element) {
		errorf(
			k.c, expr_span(v.args[0].value), "L0458",
			"a range needs integer or rune endpoints, found `%s`",
			type_name(k.c, element),
		)
		return INVALID_TYPE
	}
	v.denoted_type = range_type(k.c, element)
	ensure_iteration_members(k, v.denoted_type)
	v.resolution.kind = .Type
	v.value_category = .Type
	return v.denoted_type
}

// ------------------------------------------------------- element records --

// Element records are ordinary anonymous records (design.md "Element bindings").

ELEMENT_FIRST :: 0
ELEMENT_SECOND :: 1

// A map's `Element`: `(key: K, value: V)` (design.md "Iteration adapters").
map_entry_type :: proc(c: ^Compiler, subject: Type_Id) -> Type_Id {
	info := type_of(c, subject)
	return anon_record_type(c, []Anon_Record_Field{
		{name = intern_identifier(c, "key"), type = info.key},
		{name = intern_identifier(c, "value"), type = info.element},
	})
}

// The `Yield` a map's iterator declares: both stored halves are lent.
map_entry_yield_type :: proc(c: ^Compiler) -> Type_Id {
	borrowed := c.yield_markers[Yield_Kind.Borrowed]
	return anon_record_type(c, []Anon_Record_Field{
		{name = intern_identifier(c, "key"), type = borrowed},
		{name = intern_identifier(c, "value"), type = borrowed},
	})
}

// `indexed()`'s `Yield`: the source's lending, plus an owned counter.
indexed_yield_type :: proc(c: ^Compiler, value: Yield_Kind) -> Type_Id {
	return anon_record_type(c, []Anon_Record_Field{
		{name = intern_identifier(c, "value"), type = c.yield_markers[value]},
		{name = intern_identifier(c, "index"), type = c.yield_markers[Yield_Kind.Owned]},
	})
}

// `indexed()`'s `Element`: `(value: E, index: int)`.
indexed_element_type :: proc(c: ^Compiler, element: Type_Id) -> Type_Id {
	return anon_record_type(c, []Anon_Record_Field{
		{name = intern_identifier(c, "value"), type = element},
		{name = intern_identifier(c, "index"), type = TYPE_INT},
	})
}

// `rune_offsets()`'s `Element`: `(value: rune, offset: int)`, a byte offset.
rune_offset_type :: proc(c: ^Compiler) -> Type_Id {
	return anon_record_type(c, []Anon_Record_Field{
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
	name := intern_identifier(c, fmt.aprintf("Range_Iterator(%s)", type_name(c, element), allocator = c.semantic_allocator))
	type := new_type(c, Type_Info{kind = .Struct, name = name, element = element})
	fields := make([]Symbol_Id, 4, c.semantic_allocator)
	fields[ITER_RANGE_CURRENT] = new_field(c, "current", element, ITER_RANGE_CURRENT, public = true)
	fields[ITER_RANGE_HIGH] = new_field(c, "high", element, ITER_RANGE_HIGH, public = true)
	fields[ITER_RANGE_CLOSED] = new_field(c, "closed", TYPE_BOOL, ITER_RANGE_CLOSED, public = true)
	fields[ITER_RANGE_REVERSED] = new_field(c, "reversed", TYPE_BOOL, ITER_RANGE_REVERSED, public = true)
	if info := type_of(c, type); info != nil {
		info.fields = fields
		info.mangled = fmt.aprintf("Range_Iterator.%s", llvm_safe(type_name(c, element), allocator = context.temp_allocator), allocator = c.semantic_allocator)
	}
	c.iterator_types[range] = type
	return type
}

// `holds` is what the iterator stores: a slice for runtime arrays, otherwise
// the iterable itself. The cache key stays the iterable.
@(private = "file")
array_iterator_type :: proc(c: ^Compiler, array: Type_Id, holds := INVALID_TYPE) -> Type_Id {
	if existing, found := c.iterator_types[array]; found {
		return existing
	}
	stored := holds == INVALID_TYPE ? array : holds
	element := type_of(c, array).element
	name := intern_identifier(c, fmt.aprintf("Array_Iterator(%s)", type_name(c, array), allocator = c.semantic_allocator))
	type := new_type(c, Type_Info{kind = .Struct, name = name, element = element})
	fields := make([]Symbol_Id, 3, c.semantic_allocator)
	fields[ITER_ARRAY_DATA] = new_field(c, "data", stored, ITER_ARRAY_DATA, public = true)
	fields[ITER_ARRAY_INDEX] = new_field(c, "index", TYPE_INT, ITER_ARRAY_INDEX, public = true)
	fields[ITER_ARRAY_REVERSED] = new_field(c, "reversed", TYPE_BOOL, ITER_ARRAY_REVERSED, public = true)
	if info := type_of(c, type); info != nil {
		info.fields = fields
		info.mangled = fmt.aprintf("Array_Iterator.%s", llvm_safe(type_name(c, array), allocator = context.temp_allocator), allocator = c.semantic_allocator)
		info.descriptor = type_is_compile_time_only(c, element)
	}
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
	element := map_entry_type(c, subject)
	name := intern_identifier(c, fmt.aprintf("Map_Iterator(%s)", type_name(c, subject), allocator = c.semantic_allocator))
	type := new_type(c, Type_Info{kind = .Struct, name = name, element = element, is_view = true})
	fields := make([]Symbol_Id, 2, c.semantic_allocator)
	fields[ITER_MAP_TABLE] = new_field(c, "table", TYPE_RAWPTR, ITER_MAP_TABLE, public = true)
	fields[ITER_MAP_CURSOR] = new_field(c, "cursor", TYPE_INT, ITER_MAP_CURSOR, public = true)
	if info := type_of(c, type); info != nil {
		info.fields = fields
		info.key = subject // `next` needs the map's operation table
		info.mangled = fmt.aprintf("Map_Iterator.%s", llvm_safe(type_name(c, subject), allocator = context.temp_allocator), allocator = c.semantic_allocator)
	}
	c.iterator_types[subject] = type
	return type
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
	switch kind {
	case .None:
		return INVALID_TYPE
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
	spelling := kind == .Rune_Offsets ? label :
	            fmt.aprintf("%s(%s)", label, type_name(c, source), allocator = c.semantic_allocator)
	name := intern_identifier(c, spelling)
	type := new_type(c, Type_Info{
		kind = .Struct, name = name, element = element, is_view = true, view_kind = kind,
	})
	fields := make([]Symbol_Id, 1, c.semantic_allocator)
	fields[VIEW_SOURCE] = new_field(c, "source", held, VIEW_SOURCE)
	if info := type_of(c, type); info != nil {
		info.fields = fields
		info.key = kind == .Rune_Offsets ? INVALID_TYPE : source
		info.mangled = kind == .Rune_Offsets ? label :
		               fmt.aprintf("%s.%s", label, llvm_safe(type_name(c, source), allocator = context.temp_allocator), allocator = c.semantic_allocator)
	}
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
	subject := info.key
	name := intern_identifier(c, fmt.aprintf("%s(%s)", label, type_name(c, subject), allocator = c.semantic_allocator))
	type := new_type(c, Type_Info{kind = .Struct, name = name, element = info.element, is_view = true})
	fields := make([]Symbol_Id, 2, c.semantic_allocator)
	fields[ITER_MAP_TABLE] = new_field(c, "table", TYPE_RAWPTR, ITER_MAP_TABLE)
	fields[ITER_MAP_CURSOR] = new_field(c, "cursor", TYPE_INT, ITER_MAP_CURSOR)
	if made := type_of(c, type); made != nil {
		made.fields = fields
		made.key = subject
		made.mangled = fmt.aprintf("%s.%s", label, llvm_safe(type_name(c, subject), allocator = context.temp_allocator), allocator = c.semantic_allocator)
	}
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
	name := intern_identifier(c, label)
	type := new_type(c, Type_Info{kind = .Struct, name = name, element = element, is_view = true})
	fields := make([]Symbol_Id, 2, c.semantic_allocator)
	fields[ITER_TEXT_VIEW] = new_field(c, "view", TYPE_STRING_VIEW, ITER_TEXT_VIEW)
	fields[ITER_TEXT_OFFSET] = new_field(c, "offset", TYPE_INT, ITER_TEXT_OFFSET)
	if info := type_of(c, type); info != nil {
		info.fields = fields
		info.mangled = label
	}
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
	iterator := INVALID_TYPE
	element := INVALID_TYPE
	iter_kind := Synth_Kind.None
	reverse_kind := Synth_Kind.None
	next_kind := Synth_Kind.None
	lends_halves := false
	switch {
	case info.is_range:
		element = info.element
		iterator = range_iterator_type(k.c, under)
		iter_kind, reverse_kind, next_kind = .Range_Iter, .Range_Iter_Reverse, .Range_Next
	case info.kind == .Array:
		element = info.element
		held := under
		// A compile-time-only element has no storage to lend.
		next_kind = .Array_Next
		if !type_is_compile_time_only(k.c, element) {
			held = slice_of(k.c, element, mutable = false)
			next_kind = .Slice_Ref_Next
		}
		iterator = array_iterator_type(k.c, under, held)
		iter_kind, reverse_kind = .Array_Iter, .Array_Iter_Reverse
	case info.kind == .Slice:
		// Same `iter` as an array; only `next`'s bound differs.
		element = info.element
		iterator = array_iterator_type(k.c, under)
		iter_kind, reverse_kind, next_kind = .Array_Iter, .Array_Iter_Reverse, .Slice_Ref_Next
	case info.kind == .Dynamic_Array:
		// Iterates exactly like a slice of its current contents.
		element = info.element
		iterator = array_iterator_type(k.c, under, slice_of(k.c, info.element, mutable = false))
		iter_kind, reverse_kind, next_kind = .Dynamic_Iter, .Dynamic_Iter_Reverse, .Slice_Ref_Next
	case info.kind == .Map:
		// The `Element` is the `{key, value}` entry.
		element = map_entry_type(k.c, under)
		iterator = map_iterator_type(k.c, under)
		iter_kind, next_kind = .Map_Iter, .Map_Next
	case info.kind == .String || info.kind == .String_View:
		element = TYPE_RUNE
		iterator = text_iterator_type(k.c, TYPE_STRING_VIEW, TYPE_RUNE, "Text_Iterator")
		iter_kind, next_kind = .Text_Iter, .Text_Next
	case info.view_kind != .None:
		element = info.element
		switch info.view_kind {
		case .Rune_Offsets:
			iterator = text_iterator_type(k.c, under, element, "Rune_Offset_Iterator")
			iter_kind, next_kind = .Text_Iter, .Rune_Offsets_Next
		case .Entries:
			// Yields the map's own `Element`, so it reuses the map's iterator.
			iterator = map_iterator_type(k.c, info.key)
			iter_kind, next_kind = .Map_View_Iter, .Map_Next
		case .Keys:
			iterator = map_view_iterator_type(k.c, under, "Map_Keys_Iterator")
			iter_kind, next_kind = .Map_View_Iter, .Map_Keys_Next
			lends_halves = true
		case .Values:
			iterator = map_view_iterator_type(k.c, under, "Map_Values_Iterator")
			iter_kind, next_kind = .Map_View_Iter, .Map_Values_Next
			lends_halves = true
		case .None:
			return
		}
	case:
		return
	}

	// design.md "Borrowing iteration": stored elements are lent. An owned managed
	// `Element` needs its copy and drop before the iterator's body asks.
	lends := next_kind == .Slice_Ref_Next || lends_halves || next_kind == .Map_Next
	if !lends && type_is_managed(k.c, element) {
		contribute_lifecycle_members(k, element)
	}

	members := make([dynamic]Symbol_Id, 0, 4, k.c.semantic_allocator)
	append(&members, new_associated_type(k.c, "Element", element, under))
	append(&members, new_associated_type(k.c, "Iterator", iterator, under))
	append(&members, iter_member(k.c, "iter", iter_kind, under, iterator))
	if reverse_kind != .None {
		append(&members, iter_member(k.c, "iter_reverse", reverse_kind, under, iterator))
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
	entry_yield := next_kind == .Map_Next
	descriptor := k.c.yield_markers[Yield_Kind.Borrowed]
	item := lends ? pointer_to(k.c, element, false) : element
	if entry_yield {
		lent := []Yield_Desc{{kind = .Borrowed}, {kind = .Borrowed}}
		descriptor = map_entry_yield_type(k.c)
		item = yield_item_type(k, element, Yield_Desc{kind = .Record, fields = lent}, no_span())
		if item == INVALID_TYPE { return }
	}
	next_members := make([]Symbol_Id, lends ? 2 : 1, k.c.semantic_allocator)
	next := synth_proc(
		k.c, "next", next_kind, iterator,
		[]Type_Id{iterator}, []Param_Mode{.Inout}, option_type(k, item),
	)
	if sym := symbol_of(k.c, next); sym != nil {
		sym.has_receiver = true
		sym.receiver = .Inout
	}
	next_members[0] = next
	if lends {
		next_members[1] = new_associated_type(k.c, "Yield", descriptor, iterator)
	}
	add_members(k.c, iterator, next_members)
}

// `source.iter()` or `iter_reverse()`: a borrowing receiver whose result borrows
// from it. A synthesised member has no body for provenance to walk, so that
// dependency is written here.
@(private = "file")
iter_member :: proc(c: ^Compiler, name: string, kind: Synth_Kind, owner, iterator: Type_Id) -> Symbol_Id {
	id := synth_proc(c, name, kind, owner, []Type_Id{owner}, []Param_Mode{.Borrow}, iterator)
	if sym := symbol_of(c, id); sym != nil {
		sym.has_receiver = true
		sym.receiver = .Borrow
	}
	set_synth_result_summary(c, id, 0)
	return id
}

// Appends to a type's members. The info pointer is taken fresh: the type store
// may have grown while the symbols were made.
add_members :: proc(c: ^Compiler, type: Type_Id, added: []Symbol_Id) {
	info := type_of(c, type)
	if info == nil || len(added) == 0 {
		return
	}
	merged := make([]Symbol_Id, len(info.members) + len(added), c.semantic_allocator)
	copy(merged, info.members)
	copy(merged[len(info.members):], added)
	info.members = merged
}

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
	result: Type_Id,
) -> Symbol_Id {
	param_copy := make([]Type_Id, len(params), c.semantic_allocator)
	copy(param_copy, params)
	id := new_symbol(c, Symbol {
		name          = intern_identifier(c, name),
		span          = no_span(),
		kind          = .Proc,
		public        = true,
		owner_type    = owner,
		params        = param_copy,
		result        = result,
		param_symbols = make([]Symbol_Id, len(params), c.semantic_allocator),
		param_defaults = make([]Expr, len(params), c.semantic_allocator),
		proc_type     = intern_proc_type(c, param_copy, modes, result, false, ""),
		synth         = kind,
	})
	append(&c.synth_procs, id)
	return id
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
	if info == nil || info.convention != "" || len(info.param_modes) != 1 || info.param_modes[0] != mode {
		return false
	}
	return !info.result_inout
}

// One protocol member, looked up from the declaration's own package.
iteration_member :: proc(k: ^Checker, type: Type_Id, name: string) -> Symbol_Id {
	return find_member(k, type, intern_identifier(k.c, name))
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
		if sym.const_value.kind == .Type {
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
	adapter_name := peel_resolved_adapter(k, s)

	// A written range lowers without building a `Range(T)`.
	if written, is_range := s.iterable.(^Expr_Range); is_range {
		return check_range_foreach(k, s, written, adapter_name)
	}

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
	under := type_underlying(k.c, subject)
	info := type_of(k.c, under)
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
		s.kind = .Stored_Range
	case:
		return check_protocol_foreach(k, s, subject)
	}

	if !check_adapter_applies(k, s, subject, adapter_name) {
		return FLOWS
	}
	// The indexed lowering needs an array constant's address.
	if s.kind == .Array {
		request_materialization(k, s.iterable)
	}
	if foreach_is_place_loop(s) {
		return check_place_foreach(k, s, subject, info)
	}
	s.element_type = foreach_element_type(k, s, under, info)
	return check_foreach_body(k, s)
}

// design.md "By-reference iteration": a `&` anywhere in the header makes this
// a place loop over the container's own storage.
foreach_is_place_loop :: proc(s: ^Stmt_Foreach) -> bool {
	return first_ref_binding(s.bindings) != nil
}

// The first `&` leaf in a pattern, or nil.
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
	if ref := first_ref_binding(s.bindings); ref != nil {
		return ref.name.span
	}
	return s.bindings[0].name.span
}

// design.md "Borrowing iteration": a container lends its stored elements. Text
// and ranges generate theirs, so they hand over owned values.
foreach_lends_elements :: proc(s: ^Stmt_Foreach) -> bool {
	if foreach_is_place_loop(s) {
		return false
	}
	#partial switch s.kind {
	case .Array, .Slice, .Dynamic, .Map:
		return true
	}
	return false
}

// Which parts of a built record this traversal lends: `indexed()` over a map is
// `{value: {key: borrowed, value: borrowed}, index: owned}`.
@(private = "file")
foreach_record_yield :: proc(k: ^Checker, s: ^Stmt_Foreach) -> Yield_Desc {
	base := Yield_Desc{kind = .Borrowed}
	if s.kind == .Map {
		fields := make([]Yield_Desc, 2, k.c.semantic_allocator)
		fields[0], fields[1] = Yield_Desc{kind = .Borrowed}, Yield_Desc{kind = .Borrowed}
		base = Yield_Desc{kind = .Record, fields = fields}
	}
	if s.indexed {
		fields := make([]Yield_Desc, 2, k.c.semantic_allocator)
		fields[0], fields[1] = base, Yield_Desc{kind = .Owned}
		return Yield_Desc{kind = .Record, fields = fields}
	}
	return base
}

// design.md "Element bindings": whether the traversal builds a record of lent
// parts, which a single name then receives as those parts' pointers.
@(private = "file")
foreach_builds_lent_record :: proc(s: ^Stmt_Foreach) -> bool {
	return s.borrows && (s.indexed || s.kind == .Map)
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

// A map has no order, and the runtime cannot decode UTF-8 backwards.
@(private = "file")
check_adapter_applies :: proc(k: ^Checker, s: ^Stmt_Foreach, subject: Type_Id, name: Name) -> bool {
	if s.adapter == .None {
		return true
	}
	ok := s.kind == .Array || s.kind == .Slice || s.kind == .Dynamic ||
	      s.kind == .Range || s.kind == .Stored_Range
	if !ok {
		errorf(
			k.c, name.span, "L0460",
			"`%s()` is not a traversal of `%s`",
			name.text, type_name(k.c, subject),
		)
	}
	return ok
}

@(private = "file")
check_place_foreach :: proc(k: ^Checker, s: ^Stmt_Foreach, subject: Type_Id, info: ^Type_Info) -> Flow_Info {
	switch s.kind {
	case .Map:
		errorf(
			k.c, s.span, "L0457",
			"a map entry is not a mutable element; iterate `map.values()` to mutate values",
		)
		return FLOWS
	case .Slice:
		// design.md "Slices": the slice's own `mut`, not its variable's.
		if !info.mutable {
			errorf(
				k.c,
				ref_span(s),
				"L0480",
				"`%s` yields read-only elements, so it cannot be iterated by reference; use `[]mut %s` for mutation, or drop the `&` to read them",
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
	case .Array, .Dynamic:
		if !expr_base(s.iterable).assignable {
			report_not_assignable(k, expr_base(s.iterable), "a by-reference `foreach`")
			return FLOWS
		}
	case .Unresolved, .Static, .Protocol:
		return FLOWS
	}
	s.element_type = info.element
	if !gate_type(k, s.element_type, expr_span(s.iterable)) {
		return FLOWS
	}
	s.element_type = s.indexed ? indexed_element_type(k.c, s.element_type) : s.element_type
	if !check_foreach_pattern(k, s, s.bindings, s.element_type, INVALID_TYPE) { return FLOWS }
	return check_foreach_block(k, s)
}

@(private = "file")
check_range_foreach :: proc(k: ^Checker, s: ^Stmt_Foreach, written: ^Expr_Range, adapter_name: Name) -> Flow_Info {
	element := check_single_expr(k, written)
	if element == INVALID_TYPE {
		return FLOWS
	}
	s.kind = .Range
	if !check_adapter_applies(k, s, element, adapter_name) {
		return FLOWS
	}
	if foreach_is_place_loop(s) {
		errorf(k.c, ref_span(s), "L0457", "a range produces values, so it cannot be iterated by reference")
		return FLOWS
	}
	endpoint := underlying_info(k.c, element).element
	s.element_type = s.indexed ? indexed_element_type(k.c, endpoint) : endpoint
	return check_foreach_body(k, s)
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
	// `next` returns the `Item` the iterator's `Yield` makes of the element.
	yield, yield_ok := iterator_yield(k, iterator, expr_span(s.iterable))
	if !yield_ok {
		return FLOWS
	}
	item := yield_item_type(k, element, yield, expr_span(s.iterable))
	if item == INVALID_TYPE {
		return FLOWS
	}
	next := iteration_member(k, iterator, "next")
	next_sym := symbol_of(k.c, next)
	if !iteration_proc_matches(k, next_sym, iterator, .Inout, option_type(k, item)) {
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
		return FLOWS
	}

	effective_yield := yield
	effective_element := element
	effective_item := item
	if s.indexed {
		fields := make([]Yield_Desc, 2, k.c.semantic_allocator)
		fields[0], fields[1] = yield, Yield_Desc{kind = .Owned}
		effective_yield = Yield_Desc{kind = .Record, fields = fields}
		effective_element = indexed_element_type(k.c, element)
		effective_item = yield_item_type(k, effective_element, effective_yield, expr_span(s.iterable))
		if effective_item == INVALID_TYPE { return FLOWS }
	}
	if !yield_is_owned(effective_yield) {
		s.borrows = true
		s.item_type = effective_item
	}

	s.kind = .Protocol
	s.element_type = effective_element
	s.iterator_type = iterator
	s.iter_symbol = iter
	s.next_symbol = next
	return check_foreach_body(k, s)
}

// design.md "Element bindings": the one binder for every value loop. One name
// binds the whole `Element`; more destructure a record positionally.
@(private = "file")
check_foreach_body :: proc(k: ^Checker, s: ^Stmt_Foreach) -> Flow_Info {
	element := s.element_type
	if !gate_type(k, element, expr_span(s.iterable)) {
		return FLOWS
	}
	// The protocol path already read its iterator's `Yield`.
	if s.kind != .Protocol {
		s.borrows = foreach_lends_elements(s)
	}
	if s.item_type == INVALID_TYPE && foreach_builds_lent_record(s) {
		s.item_type = yield_item_type(k, element, foreach_record_yield(k, s), expr_span(s.iterable))
		if s.item_type == INVALID_TYPE {
			return FLOWS
		}
	}
	// A copying built-in traversal cannot copy a move-only element; a protocol
	// `next` already hands one over.
	owns := !s.borrows && s.kind != .Protocol
	if owns && !require_copyable_element(k, s, element) {
		return FLOWS
	}
	// An owned element is dropped each step. Asked here too because `indexed()`
	// wraps it in a record of its own.
	if !s.borrows && type_is_managed(k.c, element) {
		contribute_lifecycle_members(k, element)
	}
	if !check_foreach_pattern(k, s, s.bindings, element, s.item_type) { return FLOWS }
	return check_foreach_block(k, s)
}

// Binds one recursive pattern, for value and place loops alike (only a place
// loop has `&` leaves). `item` is a value loop's projected form, where a record
// of lent pointers binds whole; a place loop passes INVALID_TYPE. An
// `indexed()` counter can never be `&`.
check_foreach_pattern :: proc(
	k: ^Checker, s: ^Stmt_Foreach, bindings: []Foreach_Binding, logical, item: Type_Id, refs_allowed := true,
) -> bool {
	if len(bindings) == 1 && len(bindings[0].group) > 0 {
		return check_foreach_pattern(k, s, bindings[0].group, logical, item, refs_allowed)
	}
	if len(bindings) == 1 {
		if bindings[0].is_ref && !refs_allowed {
			errorf(k.c, bindings[0].name.span, "L0457", "this generated iteration field cannot be taken by reference")
			return false
		}
		return bind_pattern_leaf(k, s, &bindings[0], logical, item)
	}
	info := underlying_info(k.c, logical)
	if info == nil || info.kind != .Struct || len(info.fields) != len(bindings) {
		report_pattern_arity(k, bindings, logical, info)
		return false
	}
	fields, eligible := destructure_fields(
		k, logical, len(bindings), bindings[0].name.span, "L0459", "bound by a `foreach`",
	)
	if !eligible { return false }
	item_info := underlying_info(k.c, item)
	for &binding, index in bindings {
		field := symbol_of(k.c, fields[index])
		if field == nil { return false }
		projected := INVALID_TYPE
		if item_info != nil && item_info.kind == .Struct && index < len(item_info.fields) {
			if projected_field := symbol_of(k.c, item_info.fields[index]); projected_field != nil {
				projected = projected_field.type
			}
		}
		field_refs := refs_allowed && !(s.indexed && logical == s.element_type && index == ELEMENT_SECOND)
		if len(binding.group) > 0 {
			if !check_foreach_pattern(k, s, binding.group, field.type, projected, field_refs) { return false }
			continue
		}
		if binding.is_ref && !field_refs {
			errorf(k.c, binding.name.span, "L0457", "the iteration index is a counter and cannot be taken by reference")
			return false
		}
		if !bind_pattern_leaf(k, s, &binding, field.type, projected) { return false }
	}
	return true
}

// A leaf binds its logical type, or the projected record of pointers when both
// are records. A place loop's leaves, like a lending loop's, name storage the
// source still owns.
@(private = "file")
bind_pattern_leaf :: proc(k: ^Checker, s: ^Stmt_Foreach, binding: ^Foreach_Binding, logical, item: Type_Id) -> bool {
	bound := logical
	if item != INVALID_TYPE && item != logical {
		item_info := underlying_info(k.c, item)
		logical_info := underlying_info(k.c, logical)
		if item_info != nil && logical_info != nil && item_info.kind == .Struct && logical_info.kind == .Struct {
			bound = item
		}
	}
	if !gate_type(k, bound, expr_span(s.iterable)) { return false }
	binding.symbol = bind_loop_name(k, binding^, bound, binding.is_ref, s.borrows || foreach_is_place_loop(s))
	return true
}

@(private = "file")
report_pattern_arity :: proc(k: ^Checker, bindings: []Foreach_Binding, element: Type_Id, info: ^Type_Info) {
	span := len(bindings) > 0 ? bindings[0].name.span : no_span()
	count := info != nil && info.kind == .Struct ? len(info.fields) : 0
	errorf(
		k.c, span, "L0459", "`%s` has %d fields, so this `foreach` pattern needs 1 or %d parts, not %d",
		type_name(k.c, element), count, count, len(bindings),
	)
}

@(private = "file")
require_copyable_element :: proc(k: ^Checker, s: ^Stmt_Foreach, element: Type_Id) -> bool {
	if !type_clone_disabled(k.c, element) {
		return true
	}
	errorf(
		k.c, expr_span(s.iterable), "L0491",
		"`%s` is move-only, so a by-value `foreach` cannot copy it out of the container; bind the parts the traversal lends, or remove the elements",
		type_name(k.c, element),
	)
	return false
}

check_foreach_block :: proc(k: ^Checker, s: ^Stmt_Foreach) -> Flow_Info {
	k.loop_depth += 1
	body := check_scoped_block(k, s.body)
	k.loop_depth -= 1
	return Flow_Info{can_fall_through = true, returns = body.returns}
}

bind_loop_name :: proc(
	k: ^Checker, binding: Foreach_Binding, type: Type_Id, mutable: bool, borrows := false,
) -> Symbol_Id {
	if binding.name.text == "_" || binding.name.text == "" {
		return INVALID_SYMBOL
	}
	id := name_identifier(k.c, binding.name)
	if reject_reserved_name(k, id, binding.name.span) {
		return INVALID_SYMBOL
	}
	symbol := new_symbol(k.c, Symbol {
		name      = id,
		span      = binding.name.span,
		kind      = .Var,
		type      = type,
		pkg       = k.pkg,
		immutable = !mutable,
		// Names storage the source still owns.
		borrowed_binding = binding.is_ref || borrows ? .Loop_Element : .None,
	})
	k.scope.names[id] = symbol
	return symbol
}

// ------------------------------------------------------- range expressions --

// `a ..< b` and `a ..= b` as a value.
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
	if low == high && !type_is_untyped(k.c, low) {
		return low, true
	}
	// Untyped endpoints are materialized, so an out-of-range constant is reported.
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

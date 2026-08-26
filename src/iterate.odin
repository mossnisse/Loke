// Runtime `foreach` and the iteration protocol.
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
ITER_RANGE_REVERSED :: 3

ITER_ARRAY_DATA :: 0
ITER_ARRAY_INDEX :: 1
ITER_ARRAY_REVERSED :: 2

ITER_MAP_TABLE :: 0
ITER_MAP_CURSOR :: 1

// A procedure the compiler contributes rather than the user writing it. It has
// a real symbol and a real emitted body; the backend knows how to write each
// shape (the same seam `delegate` uses for its forwarding overloads).
Synth_Kind :: enum {
	None,
	// Compiler-owned canonical receiver methods for the built-in `len`, `cap`,
	// and `hash` operations. Their free spellings resolve to these same symbols.
	Standard_Len,
	Standard_Cap,
	Standard_Hash,
	Range_Iter,
	Range_Iter_Reverse,
	Range_Next,
	Array_Iter,
	Array_Iter_Reverse,
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
	Dynamic_Iter_Reverse,
	// design.md "Maps": `{ table, cursor }`, walked by the runtime's slot scan.
	Map_Iter,
	Map_Next,
	// design.md "Lifecycle hooks and resource types": a record that writes no
	// `try_clone` still has one, and `clone` is always generated from it.
	Try_Clone,
	Clone,
	// `dyn I` satisfies `I` through compiler-provided forwarding slots (design.md).
	// Each one calls through the view's own witness.
	Dyn_Forward,
	// design.md "Dynamic arrays" and "Maps": one contributed container operation.
	// Which one is `Symbol.container_op`.
	Container_Op,
	// design.md "Allocators": one `mem.Arena`/`mem.Scratch` operation. Which one
	// is `Symbol.provider_op`.
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

// ------------------------------------------------------- element records --

// The two-field records a loop can bind whole or destructure. They are ordinary
// public-field structs built the way `Range(T)` is, so `entry.key` and a
// two-name header are the same element seen two ways (design.md "Element
// bindings").

ELEMENT_FIRST :: 0
ELEMENT_SECOND :: 1

// A map's `Element`: `struct{key: K, value: V}` (design.md "Iteration adapters").
map_entry_type :: proc(c: ^Compiler, subject: Type_Id) -> Type_Id {
	if existing, found := c.entry_types[subject]; found {
		return existing
	}
	info := type_of(c, subject)
	key, value := info.key, info.element
	type := element_record(
		c,
		fmt.aprintf("Map_Entry(%s)", type_name(c, subject), allocator = c.semantic_allocator),
		fmt.aprintf("Map_Entry.%s", llvm_safe(type_name(c, subject)), allocator = c.semantic_allocator),
		"key", key, "value", value,
	)
	c.entry_types[subject] = type
	return type
}

// `indexed()`'s `Element`: `struct{value: E, index: int}`.
indexed_element_type :: proc(c: ^Compiler, element: Type_Id) -> Type_Id {
	if existing, found := c.indexed_types[element]; found {
		return existing
	}
	type := element_record(
		c,
		fmt.aprintf("Indexed(%s)", type_name(c, element), allocator = c.semantic_allocator),
		fmt.aprintf("Indexed.%s", llvm_safe(type_name(c, element)), allocator = c.semantic_allocator),
		"value", element, "index", TYPE_INT,
	)
	c.indexed_types[element] = type
	return type
}

// `rune_offsets()`'s `Element`: `struct{value: rune, offset: int}`. The offset is
// the byte index the code point begins at, which is why it is a separate adapter
// from `indexed()`'s rune ordinal (design.md "String iteration").
rune_offset_type :: proc(c: ^Compiler) -> Type_Id {
	if c.rune_offset_type != INVALID_TYPE {
		return c.rune_offset_type
	}
	type := element_record(c, "Rune_Offset", "Rune_Offset", "value", TYPE_RUNE, "offset", TYPE_INT)
	c.rune_offset_type = type
	return type
}

@(private = "file")
element_record :: proc(
	c: ^Compiler,
	name, mangled: string,
	first_name: string, first: Type_Id,
	second_name: string, second: Type_Id,
) -> Type_Id {
	type := new_type(c, Type_Info{kind = .Struct, name = intern_identifier(c, name)})
	fields := make([]Symbol_Id, 2, c.semantic_allocator)
	fields[ELEMENT_FIRST] = new_field(c, first_name, first, ELEMENT_FIRST, public = true)
	fields[ELEMENT_SECOND] = new_field(c, second_name, second, ELEMENT_SECOND, public = true)
	if info := type_of(c, type); info != nil {
		info.fields = fields
		info.mangled = mangled
	}
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
	fields := make([]Symbol_Id, 4, c.semantic_allocator)
	fields[ITER_RANGE_CURRENT] = new_field(c, "current", element, ITER_RANGE_CURRENT, public = true)
	fields[ITER_RANGE_HIGH] = new_field(c, "high", element, ITER_RANGE_HIGH, public = true)
	fields[ITER_RANGE_CLOSED] = new_field(c, "closed", TYPE_BOOL, ITER_RANGE_CLOSED, public = true)
	fields[ITER_RANGE_REVERSED] = new_field(c, "reversed", TYPE_BOOL, ITER_RANGE_REVERSED, public = true)
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
	fields := make([]Symbol_Id, 3, c.semantic_allocator)
	fields[ITER_ARRAY_DATA] = new_field(c, "data", stored, ITER_ARRAY_DATA, public = true)
	fields[ITER_ARRAY_INDEX] = new_field(c, "index", TYPE_INT, ITER_ARRAY_INDEX, public = true)
	fields[ITER_ARRAY_REVERSED] = new_field(c, "reversed", TYPE_BOOL, ITER_ARRAY_REVERSED, public = true)
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
	element := map_entry_type(c, subject)
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
	reverse_kind := Synth_Kind.None
	next_kind := Synth_Kind.None
	switch {
	case info.is_range:
		element = info.element
		iterator = range_iterator_type(k.c, under)
		iter_kind, reverse_kind, next_kind = .Range_Iter, .Range_Iter_Reverse, .Range_Next
	case info.kind == .Array:
		element = info.element
		iterator = array_iterator_type(k.c, under)
		iter_kind, reverse_kind, next_kind = .Array_Iter, .Array_Iter_Reverse, .Array_Next
	case info.kind == .Slice:
		// The iterator holds the slice by value, so `iter` is the array one
		// verbatim: `{ data, 0 }`. Only `next`'s bound is different.
		element = info.element
		iterator = array_iterator_type(k.c, under)
		iter_kind, reverse_kind, next_kind = .Array_Iter, .Array_Iter_Reverse, .Slice_Next
	case info.kind == .Dynamic_Array:
		// design.md "Dynamic arrays": iteration views the current allocation and
		// stops at the length. That is exactly a slice, so the protocol members are
		// the slice ones with a different `iter`.
		element = info.element
		iterator = array_iterator_type(k.c, under, slice_of(k.c, info.element, mutable = false))
		iter_kind, reverse_kind, next_kind = .Dynamic_Iter, .Dynamic_Iter_Reverse, .Slice_Next
	case info.kind == .Map:
		// design.md "Iteration adapters": a map's `Element` is its `{key, value}`
		// entry, so a one-name loop binds the whole entry and a two-name loop
		// destructures it. `values()` and `keys()` name the other two traversals.
		element = map_entry_type(k.c, under)
		iterator = map_iterator_type(k.c, under)
		iter_kind, next_kind = .Map_Iter, .Map_Next
	case:
		return
	}

	member_count := reverse_kind == .None ? 3 : 4
	members := make([]Symbol_Id, member_count, k.c.semantic_allocator)
	members[0] = new_associated_type(k.c, "Element", element, under)
	members[1] = new_associated_type(k.c, "Iterator", iterator, under)
	// design.md "Iteration protocol": `iter` takes a receiver, so `source.iter()`
	// is the protocol spelling and the free `iter(source)` overload still finds it.
	members[2] = synth_proc(k.c, "iter", iter_kind, under, []Type_Id{under}, []Param_Mode{.Value}, []Type_Id{iterator})
	if sym := symbol_of(k.c, members[2]); sym != nil {
		sym.has_receiver = true
		sym.receiver = .Value
	}
	if reverse_kind != .None {
		members[3] = synth_proc(
			k.c, "iter_reverse", reverse_kind, under,
			[]Type_Id{under}, []Param_Mode{.Value}, []Type_Id{iterator},
		)
		if sym := symbol_of(k.c, members[3]); sym != nil {
			sym.has_receiver = true
			sym.receiver = .Value
		}
	}
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

// `iter(source)` is the closed standard alias for `source.iter()`. Protocol
// validation belongs to `Iterable`/`foreach`; a direct alias call performs the
// same overload selection as direct method syntax and rewrites to that member.
check_iter_builtin :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident, expected: Type_Id) {
	check_standard_alias(k, v, ident, expected)
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

// One named protocol member, using the declaration's frozen lookup package.
// This admits an inherent member or an extension visible where the loop/free
// `iter` call is defined, without consulting an instantiating caller's methods.
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

// design.md "Iteration adapters": the names a `foreach` header recognizes as an
// alternative traversal of its iterable. They are the compiler-contributed
// surface, so inside a header they always mean the adapter.
@(private = "file")
foreach_adapter_named :: proc(name: string) -> (Foreach_Adapter, bool) {
	switch name {
	case "indexed":
		return .None, true
	case "reversed":
		return .Reversed, false
	case "entries":
		return .Entries, false
	case "keys":
		return .Keys, false
	case "values":
		return .Values, false
	case "runes":
		return .Runes, false
	case "rune_offsets":
		return .Rune_Offsets, false
	}
	return .None, false
}

// Rewrites `source.adapter()` in the header to `source`, recording which
// traversal was asked for. The adapter selects the lowering; it never builds an
// iterator object of its own. Adapters compose, so this peels a chain: one
// traversal, with `indexed()` numbering it from the outside.
peel_foreach_adapter :: proc(k: ^Checker, s: ^Stmt_Foreach) -> (Foreach_Adapter, Name) {
	adapter := Foreach_Adapter.None
	reported: Name
	for {
		call, is_call := s.iterable.(^Expr_Call)
		if !is_call || len(call.args) != 0 {
			break
		}
		selector, is_selector := call.callee.(^Expr_Selector)
		if !is_selector || selector.operand == nil {
			break
		}
		peeled, is_indexed := foreach_adapter_named(selector.name.text)
		if peeled == .None && !is_indexed {
			break
		}
		// `Enum.values()` is the members array, not a map's value view: it is an
		// ordinary constant expression and the loop iterates its result.
		if peeled == .Values && type_is_enum(k.c, resolve_type_syntax(k, selector.operand)) {
			break
		}
		// A rejected chain is still consumed, so the header reports once rather
		// than failing again on the leftover call.
		if is_indexed {
			if s.indexed || adapter != .None {
				errorf(
					k.c, selector.name.span, "L0460",
					"`indexed()` numbers the traversal it wraps, so it comes last and only once",
				)
			}
			s.indexed = true
		} else {
			if adapter != .None {
				errorf(
					k.c, selector.name.span, "L0460",
					"a `foreach` takes one traversal, and `%s()` is a second one",
					selector.name.text,
				)
			}
			adapter = peeled
		}
		reported = selector.name
		s.iterable = selector.operand
	}
	return adapter, reported
}

check_runtime_foreach :: proc(k: ^Checker, s: ^Stmt_Foreach) -> Flow_Info {
	if len(s.bindings) == 0 {
		errorf(k.c, s.span, "L0456", "a `foreach` binds at least one name")
		return FLOWS
	}

	outer := k.scope
	k.scope = new_scope(k.c, outer, .Local)
	defer k.scope = outer

	adapter, adapter_name := peel_foreach_adapter(k, s)
	s.adapter = adapter

	// A written range keeps its endpoints: the direct lowering never builds a
	// `Range(T)` value for it.
	if written, is_range := s.iterable.(^Expr_Range); is_range {
		return check_range_foreach(k, s, written, adapter_name)
	}

	// design.md: a *type* is never an iterable, so an enum name in the header is
	// the members array with its `.values()` left off.
	if named := resolve_type_syntax(k, s.iterable); named != INVALID_TYPE {
		errorf(
			k.c, expr_span(s.iterable), "L0456",
			"`%s` is a type, so it is not iterable%s",
			type_name(k.c, named),
			type_is_enum(k.c, named) ? "; write `.values()` for its members" : "",
		)
		return FLOWS
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
		s.count = info.count
	case info.kind == .Slice:
		s.kind = .Slice
	case info.kind == .Dynamic_Array:
		s.kind = .Dynamic
	case info.kind == .Map:
		s.kind = .Map
	case info.kind == .String || info.kind == .String_View:
		// String iteration yields Unicode scalar values by default; byte iteration
		// is explicit (design.md) — `foreach (b, i in text.bytes().indexed())`.
		s.kind = .Text
	case info.is_range:
		s.kind = .Stored_Range
	case:
		return check_protocol_foreach(k, s, subject)
	}

	if !check_adapter_applies(k, s, subject, adapter_name) {
		return FLOWS
	}
	if foreach_is_place_loop(s) {
		return check_place_foreach(k, s, subject, info)
	}
	s.element_type = foreach_element_type(k, s, under, info)
	return check_foreach_body(k, s)
}

// design.md "By-reference iteration": a `&` anywhere in the header makes this a
// place loop, which projects the container's own storage instead of binding an
// `Element`. Classified before the binding semantics are checked, because the
// two shapes read their names differently.
foreach_is_place_loop :: proc(s: ^Stmt_Foreach) -> bool {
	for binding in s.bindings {
		if binding.is_ref {
			return true
		}
	}
	return false
}

// The `Element` this loop yields, after the header's adapter.
@(private = "file")
foreach_element_type :: proc(k: ^Checker, s: ^Stmt_Foreach, under: Type_Id, info: ^Type_Info) -> Type_Id {
	yielded := s.kind == .Text ? TYPE_RUNE : info.element
	traversed := yielded
	#partial switch s.adapter {
	case .Rune_Offsets:
		traversed = rune_offset_type(k.c)
	case .Keys:
		traversed = info.key
	case .Values:
		traversed = info.element
	case:
		if s.kind == .Map {
			traversed = map_entry_type(k.c, under)
		}
	}
	// `indexed()` numbers whatever traversal precedes it, so it wraps last.
	return s.indexed ? indexed_element_type(k.c, traversed) : traversed
}

// design.md "Iteration adapters": `indexed()` and `reversed()` are contributed to
// every iterable, and the rest are views of one container's own storage.
@(private = "file")
check_adapter_applies :: proc(k: ^Checker, s: ^Stmt_Foreach, subject: Type_Id, name: Name) -> bool {
	ok := false
	#partial switch s.adapter {
	case .None:
		return true
	case .Reversed:
		// A map's order is unspecified, and walking UTF-8 backwards needs a decoder
		// the version 1 runtime does not have.
		ok = s.kind == .Array || s.kind == .Slice || s.kind == .Dynamic ||
		     s.kind == .Range || s.kind == .Stored_Range
	case .Entries, .Keys, .Values:
		ok = s.kind == .Map
	case .Runes, .Rune_Offsets:
		ok = s.kind == .Text
	}
	if !ok {
		errorf(
			k.c, name.span, "L0460",
			"`%s()` is not a traversal of `%s`",
			name.text, type_name(k.c, subject),
		)
	}
	return ok
}

// design.md "By-reference iteration": the built-in place forms, unchanged. Their
// names are fixed by the container — a value and an index, or a key and a value —
// rather than read off an `Element` record.
@(private = "file")
check_place_foreach :: proc(k: ^Checker, s: ^Stmt_Foreach, subject: Type_Id, info: ^Type_Info) -> Flow_Info {
	if s.adapter != .None || s.indexed {
		errorf(
			k.c, s.span, "L0460",
			"an adapter yields values, so it cannot be iterated by reference; drop the `&`",
		)
		return FLOWS
	}
	if len(s.bindings) > 2 {
		errorf(k.c, s.bindings[2].name.span, "L0459", "a by-reference `foreach` binds one or two names")
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
		if !s.bindings[value_binding].is_ref {
			errorf(
				k.c, s.bindings[value_binding].name.span, "L0459",
				"a by-reference `foreach` over a map binds `&value`, or `key, &value`",
			)
			return FLOWS
		}
		if !expr_base(s.iterable).assignable {
			report_not_assignable(k, expr_base(s.iterable), "a by-reference `foreach`")
			return FLOWS
		}
		s.element_type = info.element
		if !gate_type(k, info.key, expr_span(s.iterable)) ||
		   !gate_type(k, s.element_type, expr_span(s.iterable)) {
			return FLOWS
		}
		if key_binding >= 0 {
			// An immutable key binding is a *borrow* of the stored key rather than a
			// copy — which is what lets `map[string]V` be iterated at all, and why no
			// per-iteration clone or drop is needed for it. The loop's whole-container
			// loan is what keeps that borrow valid across the back-edge.
			s.bindings[key_binding].symbol = bind_loop_name(k, s.bindings[key_binding], info.key, false)
		}
		s.bindings[value_binding].symbol = bind_loop_name(k, s.bindings[value_binding], s.element_type, true)
		return check_foreach_block(k, s)
	}
	// The index binding is the loop's own counter, so it is never a place.
	if len(s.bindings) == 2 && s.bindings[1].is_ref {
		errorf(k.c, s.bindings[1].name.span, "L0457", "the index binding is a counter and cannot be taken by reference")
		return FLOWS
	}
	if !s.bindings[0].is_ref {
		errorf(k.c, s.bindings[0].name.span, "L0459", "a by-reference `foreach` binds `&value`, or `&value, index`")
		return FLOWS
	}
	switch s.kind {
	case .Slice:
		// Element assignment and iteration by reference require `[]mut T` (design.md
		// "Slices"). The capability is the slice's own, not whether the variable
		// holding it can be rebound.
		if !info.mutable {
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
	case .Range, .Stored_Range:
		errorf(k.c, s.bindings[0].name.span, "L0457", "a range produces values, so it cannot be iterated by reference")
		return FLOWS
	case .Text:
		errorf(
			k.c, s.bindings[0].name.span, "L0564",
			"a string yields decoded code points, so it cannot be iterated by reference",
		)
		return FLOWS
	case .Array, .Dynamic:
		if !expr_base(s.iterable).assignable {
			report_not_assignable(k, expr_base(s.iterable), "a by-reference `foreach`")
			return FLOWS
		}
	case .Unresolved, .Static, .Map, .Protocol:
		return FLOWS
	}
	s.element_type = info.element
	if !gate_type(k, s.element_type, expr_span(s.iterable)) {
		return FLOWS
	}
	s.bindings[0].symbol = bind_loop_name(k, s.bindings[0], s.element_type, true)
	if len(s.bindings) == 2 {
		s.bindings[1].symbol = bind_loop_name(k, s.bindings[1], TYPE_INT, false)
	}
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
	if s.bindings[0].is_ref {
		errorf(k.c, s.bindings[0].name.span, "L0457", "a range produces values, so it cannot be iterated by reference")
		return FLOWS
	}
	endpoint := underlying_info(k.c, element).element
	s.element_type = s.indexed ? indexed_element_type(k.c, endpoint) : endpoint
	return check_foreach_body(k, s)
}

// design.md "Iteration protocol": associated `Element` and `Iterator`,
// `value.iter()`, and `next(self: inout Iterator) -> (Element, bool)`.
@(private = "file")
check_protocol_foreach :: proc(k: ^Checker, s: ^Stmt_Foreach, subject: Type_Id) -> Flow_Info {
	// Only `indexed()` and `reversed()` are contributed to a user iterable; the
	// container views belong to one built-in's storage.
	#partial switch s.adapter {
	case .Entries, .Keys, .Values, .Runes, .Rune_Offsets:
		errorf(
			k.c, expr_span(s.iterable), "L0460",
			"that traversal belongs to a built-in container, not to `%s`",
			type_name(k.c, subject),
		)
		return FLOWS
	}
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
	// Bare `foreach` never selects `iter_reverse`; `reversed()` is what asks for
	// it, and it produces the same `Iterator` (design.md "Iteration adapters").
	if s.adapter == .Reversed {
		reverse := iteration_member(k, subject, "iter_reverse")
		if !iteration_proc_matches(k, symbol_of(k.c, reverse), subject, .Value, []Type_Id{iterator}) {
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
	s.element_type = s.indexed ? indexed_element_type(k.c, element) : element
	s.iterator_type = iterator
	s.iter_symbol = iter
	s.next_symbol = next
	return check_foreach_body(k, s)
}

// design.md "Element bindings": one binding names the whole `Element`; two or
// more require a record `Element` with exactly that many visible fields and bind
// them positionally. This is the one binder every value loop goes through,
// whatever lowering produced the element.
@(private = "file")
check_foreach_body :: proc(k: ^Checker, s: ^Stmt_Foreach) -> Flow_Info {
	element := s.element_type
	if !gate_type(k, element, expr_span(s.iterable)) {
		return FLOWS
	}
	if len(s.bindings) == 1 {
		if !bind_element_field(k, s, 0, element, borrowed = foreach_field_borrowed(s, 0)) {
			return FLOWS
		}
		return check_foreach_block(k, s)
	}
	info := underlying_info(k.c, element)
	if info == nil || info.kind != .Struct || len(info.fields) != len(s.bindings) {
		report_arity_mismatch(k, s, element, info)
		return FLOWS
	}
	for binding, index in s.bindings {
		field := symbol_of(k.c, info.fields[index])
		if field == nil {
			return FLOWS
		}
		if !require_visible_field(k, binding.name.span, element, info.fields[index], "L0459", "bound by a `foreach`") {
			return FLOWS
		}
		if !bind_element_field(k, s, index, field.type, borrowed = foreach_field_borrowed(s, index)) {
			return FLOWS
		}
	}
	return check_foreach_block(k, s)
}

// A field bound in place rather than copied: a map's key, which is immutable and
// therefore borrows the stored key. That is what lets `map[string]V` be iterated
// without a per-iteration clone and drop.
@(private = "file")
foreach_field_borrowed :: proc(s: ^Stmt_Foreach, index: int) -> bool {
	if s.kind != .Map || s.indexed {
		return false
	}
	#partial switch s.adapter {
	case .Keys:
		return true
	case .None, .Entries:
		return len(s.bindings) > 1 && index == 0
	}
	return false
}

@(private = "file")
bind_element_field :: proc(
	k: ^Checker,
	s: ^Stmt_Foreach,
	index: int,
	type: Type_Id,
	borrowed: bool,
) -> bool {
	binding := s.bindings[index]
	if binding.is_ref {
		errorf(
			k.c, binding.name.span, "L0457",
			"a value binding names a copy of the element, so it cannot take `&`",
		)
		return false
	}
	// By default each iterated value is a copy (design.md). A managed element
	// would therefore need a per-iteration clone and a per-iteration drop, which
	// is loop-body cleanup the M5a CFG does not place yet.
	if !borrowed && type_is_managed(k.c, type) {
		errorf(
			k.c,
			binding.name.span,
			"L0504",
			"a by-value `foreach` over `%s` copies a managed element, which M5a does not clean up per iteration; iterate `&value` over a `[]mut %s`, or index the sequence",
			type_name(k.c, type),
			type_name(k.c, type),
		)
		return false
	}
	if !gate_type(k, type, expr_span(s.iterable)) {
		return false
	}
	s.bindings[index].symbol = bind_loop_name(k, binding, type, false)
	return true
}

@(private = "file")
report_arity_mismatch :: proc(k: ^Checker, s: ^Stmt_Foreach, element: Type_Id, info: ^Type_Info) {
	span := s.bindings[1].name.span
	if info != nil && info.kind == .Struct {
		errorf(
			k.c, span, "L0459",
			"`%s` has %d fields, so a `foreach` over it binds 1 or %d names, not %d",
			type_name(k.c, element), len(info.fields), len(info.fields), len(s.bindings),
		)
		return
	}
	errorf(
		k.c, span, "L0459",
		"`%s` is not a record, so a `foreach` over it binds one name",
		type_name(k.c, element),
	)
	// The index a loop used to supply is now the iterable's own (design.md
	// "Element bindings"), so point at the traversal that carries it.
	#partial switch s.kind {
	case .Text:
		add_notef(k.c, span, "for a rune ordinal write `.indexed()`, and for a byte offset `.rune_offsets()`")
	case .Array, .Slice, .Dynamic, .Range, .Stored_Range, .Protocol:
		add_notef(k.c, span, "for an index write `.indexed()`")
	}
}

@(private = "file")
check_foreach_block :: proc(k: ^Checker, s: ^Stmt_Foreach) -> Flow_Info {
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

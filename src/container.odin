// The managed containers `[dynamic]T` and `map[K]V` (design.md "Dynamic arrays",
// "Maps"). Both are four-word headers whose all-zero value is empty and usable:
//
//   [dynamic]T   { rawptr data,  int len, int cap, Allocator allocator }
//   map[K]V      { rawptr table, int len, int cap, Allocator allocator }
//
// The storage behind them lives in `runtime/container.c`; the compiler supplies
// each element type's clone, drop, hash, and compare operations.
package lokec

import "core:fmt"

// design.md "Container insertion": a `try_` form copies its element in, so a
// failure leaves the caller's argument untouched, and a move-only element has
// no such form.
container_member_is_try :: proc(c: ^Compiler, symbol: ^Symbol) -> bool {
	text := identifier_text(c, symbol.name)
	return len(text) > 4 && text[:4] == "try_"
}

// Header field positions, shared by both containers.
CONTAINER_STORAGE :: 0
CONTAINER_LEN     :: 1
CONTAINER_CAP     :: 2
CONTAINER_ALLOC   :: 3

// The one place a `[dynamic]T` type is created.
dynamic_array_of :: proc(c: ^Compiler, element: Type_Id) -> Type_Id {
	if element == INVALID_TYPE {
		return INVALID_TYPE
	}
	type := intern_type(
		c,
		Type_Key{kind = .Dynamic_Array, element = element},
		Type_Info{kind = .Dynamic_Array, element = element},
	)
	ensure_container_fields(c, type)
	return type
}

// The one place a `map[K]V` type is created.
map_of :: proc(c: ^Compiler, key: Type_Id, value: Type_Id) -> Type_Id {
	if key == INVALID_TYPE || value == INVALID_TYPE {
		return INVALID_TYPE
	}
	type := intern_type(
		c,
		Type_Key{kind = .Map, element = value, key = key},
		Type_Info{kind = .Map, element = value, key = key},
	)
	ensure_container_fields(c, type)
	return type
}

// Installed as the type is interned (`dynamic_array_of`, `map_of`).
@(private = "file")
ensure_container_fields :: proc(c: ^Compiler, type: Type_Id) {
	info := type_of(c, type)
	if info == nil || len(info.fields) > 0 {
		return
	}
	storage := ""
	#partial switch info.kind {
	case .Dynamic_Array:
		storage = "data"
	case .Map:
		storage = "table"
	case:
		return
	}
	fields := make([]Symbol_Id, 4, c.semantic_allocator)
	fields[CONTAINER_STORAGE] = new_field(c, storage, TYPE_RAWPTR, CONTAINER_STORAGE)
	fields[CONTAINER_LEN] = new_field(c, "len", TYPE_INT, CONTAINER_LEN)
	fields[CONTAINER_CAP] = new_field(c, "cap", TYPE_INT, CONTAINER_CAP)
	fields[CONTAINER_ALLOC] = new_field(c, "allocator", TYPE_ALLOCATOR, CONTAINER_ALLOC)
	type_of(c, type).fields = fields
}

type_is_dynamic_array :: proc(c: ^Compiler, id: Type_Id) -> bool {
	return underlying_kind(c, id) == .Dynamic_Array
}

type_is_map :: proc(c: ^Compiler, id: Type_Id) -> bool {
	return underlying_kind(c, id) == .Map
}

// Either managed container.
type_is_container :: proc(c: ^Compiler, id: Type_Id) -> bool {
	info := underlying_info(c, id)
	if info == nil {
		return false
	}
	return info.kind == .Dynamic_Array || info.kind == .Map
}

// The element (`[dynamic]T`'s `T`, `map[K]V`'s `V`), or INVALID_TYPE.
container_element :: proc(c: ^Compiler, id: Type_Id) -> Type_Id {
	info := underlying_info(c, id)
	if info == nil || (info.kind != .Dynamic_Array && info.kind != .Map) {
		return INVALID_TYPE
	}
	return info.element
}

// A map's key type, or INVALID_TYPE for anything else.
container_key :: proc(c: ^Compiler, id: Type_Id) -> Type_Id {
	info := underlying_info(c, id)
	if info == nil || info.kind != .Map {
		return INVALID_TYPE
	}
	return info.key
}

// ------------------------------------------------------ contributed members --

// Which operation a contributed member is. A panicking spelling and its `try_`
// form share one entry; the member's result type tells them apart.
Container_Op :: enum {
	None,
	Append,
	Insert,
	Pop,
	Remove,
	Remove_Unordered,
	Clear,
	Resize,
	Reserve,
	Shrink,
	// Also contributed to `[]mut T`: an `impl` in `core:slice` would be an
	// extension visible only there.
	Sort,
	Reverse_Sort,
	// standard-library.md "Swapping elements": one operation, since two `inout` borrows of
	// the same sequence could not be proven distinct.
	Swap,
	// standard-library.md "Splitting a mutable slice": two halves that are one reborrow
	// of the receiver, which no library procedure could prove disjoint.
	Split_At_Mut,
	// standard-library.md "Chunks of a mutable slice": a view whose chunks borrow the
	// receiver, not the view.
	Chunks_Mut,
	Map_Find,
	Map_Find_Or_Insert,
	Map_Lookup_Value,
	Map_Try_Insert,
	Map_Remove,
	Map_Clear,
	Map_Reserve,
	Map_Shrink,
	// design.md "Iteration adapters": borrowed views.
	Map_Entries,
	Map_Keys,
	Map_Values,
}

// What a container operation does that its signature does not say, for provenance
// and lowering.
Container_Op_Effect :: enum {
	// Its arguments land in the receiver's content.
	Stores_Content,
	// A provider moved into it is stored there and carries its region along.
	Stores_Provider,
	// It may drop a provider the receiver holds.
	Drops_Provider,
	// It may allocate, resize, or free storage, or drop elements that own storage.
	Allocates,
	Empties,
	// It reorders the elements in place, storing none.
	Permutes,
	// A carrier in one element may end up in another.
	Moves_Elements,
	// It returns what an element held, not a borrow of the container.
	Removes_Element,
	// design.md "Iteration adapters": a map view read-borrows the map.
	Returns_View,
	// standard-library.md "Splitting a mutable slice", "Chunks of a mutable slice": the
	// result views what the receiver views, so the receiver is lent as a mutable
	// carrier argument is.
	Lends_Receiver,
}

// One row per operation, and not `#partial`, so a new operation has to say.
@(rodata)
CONTAINER_OP_EFFECTS := [Container_Op]bit_set[Container_Op_Effect] {
	.None               = {},
	.Append             = {.Stores_Content, .Stores_Provider, .Allocates},
	.Insert             = {.Stores_Content, .Stores_Provider, .Allocates, .Moves_Elements},
	.Pop                = {.Drops_Provider, .Removes_Element},
	.Remove             = {.Drops_Provider, .Moves_Elements, .Removes_Element},
	.Remove_Unordered   = {.Drops_Provider, .Moves_Elements, .Removes_Element},
	.Clear              = {.Drops_Provider, .Allocates, .Empties},
	.Resize             = {.Drops_Provider, .Allocates},
	.Reserve            = {.Allocates},
	.Shrink             = {.Allocates},
	.Sort               = {.Permutes, .Moves_Elements},
	.Reverse_Sort       = {.Permutes, .Moves_Elements},
	.Swap               = {.Permutes, .Moves_Elements},
	.Split_At_Mut       = {.Lends_Receiver},
	.Chunks_Mut         = {.Lends_Receiver},
	.Map_Find           = {},
	// No `.Stores_Provider`: a present key drops the element (design.md "Map
	// container operations").
	.Map_Find_Or_Insert = {.Stores_Content, .Allocates},
	.Map_Lookup_Value   = {},
	.Map_Try_Insert     = {.Stores_Content, .Stores_Provider, .Drops_Provider, .Allocates},
	.Map_Remove         = {.Drops_Provider, .Allocates, .Removes_Element},
	.Map_Clear          = {.Drops_Provider, .Allocates, .Empties},
	.Map_Reserve        = {.Allocates},
	.Map_Shrink         = {.Allocates},
	.Map_Entries        = {.Returns_View},
	.Map_Keys           = {.Returns_View},
	.Map_Values         = {.Returns_View},
}

// design.md "Dynamic arrays": the operations are real members, so calls reuse
// overload ranking, `..T` packing, defaults, and the `inout` receiver rule.
ensure_container_members :: proc(k: ^Checker, type: Type_Id) {
	info := type_of(k.c, type)
	if info == nil || .Container in info.contributed {
		return
	}
	if info.kind == .Map {
		info.contributed += {.Container}
		ensure_map_members(k, type, info)
		return
	}
	if info.kind == .Slice {
		info.contributed += {.Container}
		ensure_slice_members(k, type, info)
		return
	}
	if info.kind != .Dynamic_Array {
		return
	}
	info.contributed += {.Container}
	element := info.element
	// Insertion clones.
	contribute_lifecycle_members(k, element)

	members := make([dynamic]Symbol_Id, 0, 17, k.c.semantic_allocator)
	none := INVALID_TYPE
	fails := k.c.alloc_result_type

	pack := slice_of(k.c, element, mutable = false)
	append(&members, container_member(
		k, type, "append", .Append,
		[]Type_Id{type, pack}, []Param_Mode{.Inout, .Variadic}, none, 0,
	))
	append(&members, container_member(
		k, type, "try_append", .Append,
		[]Type_Id{type, pack}, []Param_Mode{.Inout, .Variadic}, fails, 0,
	))
	append(&members, container_member(
		k, type, "insert", .Insert,
		[]Type_Id{type, TYPE_INT, element}, []Param_Mode{.Inout, .Value, .Value}, none, 0,
	))
	append(&members, container_member(
		k, type, "try_insert", .Insert,
		[]Type_Id{type, TYPE_INT, element}, []Param_Mode{.Inout, .Value, .Value}, fails, 0,
	))
	// A synthesised member has no body, so its result provenance is written as a
	// summary.
	pop := container_member(
		k, type, "pop", .Pop,
		[]Type_Id{type}, []Param_Mode{.Inout}, option_type(k, element), 0,
	)
	set_synth_result_summary(k.c, pop, 0)
	append(&members, pop)
	remove := container_member(
		k, type, "remove", .Remove,
		[]Type_Id{type, TYPE_INT}, []Param_Mode{.Inout, .Value}, element, 0,
	)
	set_synth_result_summary(k.c, remove, 0)
	append(&members, remove)
	remove_unordered := container_member(
		k, type, "remove_unordered", .Remove_Unordered,
		[]Type_Id{type, TYPE_INT}, []Param_Mode{.Inout, .Value}, element, 0,
	)
	set_synth_result_summary(k.c, remove_unordered, 0)
	append(&members, remove_unordered)
	append(&members, container_member(
		k, type, "clear", .Clear, []Type_Id{type}, []Param_Mode{.Inout}, none, 0,
	))
	append(&members, container_member(
		k, type, "resize", .Resize,
		[]Type_Id{type, TYPE_INT}, []Param_Mode{.Inout, .Value}, none, 0,
	))
	append(&members, container_member(
		k, type, "try_resize", .Resize,
		[]Type_Id{type, TYPE_INT}, []Param_Mode{.Inout, .Value}, fails, 0,
	))
	append(&members, container_member(
		k, type, "reserve", .Reserve,
		[]Type_Id{type, TYPE_INT}, []Param_Mode{.Inout, .Value}, none, 0,
	))
	append(&members, container_member(
		k, type, "try_reserve", .Reserve,
		[]Type_Id{type, TYPE_INT}, []Param_Mode{.Inout, .Value}, fails, 0,
	))
	// `shrink()` is `shrink(0)`: the target is `max(len, min_capacity)`.
	append(&members, container_member(
		k, type, "shrink", .Shrink,
		[]Type_Id{type, TYPE_INT}, []Param_Mode{.Inout, .Value}, none, 1,
	))
	append(&members, container_member(
		k, type, "try_shrink", .Shrink,
		[]Type_Id{type, TYPE_INT}, []Param_Mode{.Inout, .Value}, fails, 1,
	))
	append(&members, container_member(
		k, type, "sort", .Sort, []Type_Id{type}, []Param_Mode{.Inout}, none, 0,
	))
	append(&members, container_member(
		k, type, "reverse_sort", .Reverse_Sort, []Type_Id{type}, []Param_Mode{.Inout}, none, 0,
	))
	append(&members, container_member(
		k, type, "swap", .Swap,
		[]Type_Id{type, TYPE_INT, TYPE_INT}, []Param_Mode{.Inout, .Value, .Value}, none, 0,
	))
	add_members(k.c, type, members[:])
}

// standard-library.md "Sorting slices": only `[]mut T` has these members. The receiver is a
// value, since the slice header is a borrow of the caller's elements.
@(private = "file")
ensure_slice_members :: proc(k: ^Checker, type: Type_Id, info: ^Type_Info) {
	if !info.mutable {
		return
	}
	members := make([dynamic]Symbol_Id, 0, 4, k.c.semantic_allocator)
	append(&members, container_member(
		k, type, "sort", .Sort,
		[]Type_Id{type}, []Param_Mode{.Value}, INVALID_TYPE, 0, .Value,
	))
	append(&members, container_member(
		k, type, "reverse_sort", .Reverse_Sort,
		[]Type_Id{type}, []Param_Mode{.Value}, INVALID_TYPE, 0, .Value,
	))
	append(&members, container_member(
		k, type, "swap", .Swap,
		[]Type_Id{type, TYPE_INT, TYPE_INT}, []Param_Mode{.Value, .Value, .Value},
		INVALID_TYPE, 0, .Value,
	))
	// Both halves borrow the receiver, so the caller's slice stays suspended
	// while either is live.
	halves := anon_record_type(k.c, []Anon_Record_Field{
		{name = intern_identifier(k.c, "left"), type = type},
		{name = intern_identifier(k.c, "right"), type = type},
	})
	split := container_member(
		k, type, "split_at_mut", .Split_At_Mut,
		[]Type_Id{type, TYPE_INT}, []Param_Mode{.Value, .Value}, halves, 0, .Value,
	)
	set_synth_content_summary(k.c, split, 0)
	append(&members, split)
	chunks := container_member(
		k, type, "chunks_mut", .Chunks_Mut,
		[]Type_Id{type, TYPE_INT}, []Param_Mode{.Value, .Value}, chunks_mut_type(k, type), 0, .Value,
	)
	set_synth_content_summary(k.c, chunks, 0)
	append(&members, chunks)
	add_members(k.c, type, members[:])
}

// Field positions of `Chunks_Mut(T)`.
CHUNKS_REST :: 0
CHUNKS_SIZE :: 1

// standard-library.md "Chunks of a mutable slice": what `chunks_mut` returns, which is its
// own iterator. It holds the part of the slice not yet handed out and the chunk
// length.
@(private = "file")
chunks_mut_type :: proc(k: ^Checker, slice: Type_Id) -> Type_Id {
	c := k.c
	name := intern_identifier(c, fmt.aprintf("Chunks_Mut(%s)", type_name(c, slice), allocator = c.semantic_allocator))
	type := new_type(c, Type_Info{kind = .Struct, name = name, element = slice})
	fields := make([]Symbol_Id, 2, c.semantic_allocator)
	fields[CHUNKS_REST] = new_field(c, "rest", slice, CHUNKS_REST)
	fields[CHUNKS_SIZE] = new_field(c, "size", TYPE_INT, CHUNKS_SIZE)
	info := type_of(c, type)
	info.fields = fields
	info.backend_label = fmt.aprintf("Chunks_Mut.%d", slice, allocator = c.semantic_allocator)
	info.contributed += {.Iteration}
	add_members(c, type, []Symbol_Id{
		new_associated_type(c, "Element", slice, type),
		new_associated_type(c, "Iterator", type, type),
		synth_self_member(k.c, "iter", .Iterator_Copy, type, .Borrow, type),
		synth_self_member(k.c, "next", .Chunks_Next, type, .Inout, option_type(k, slice)),
	})
	return type
}

// design.md "Map container operations".
@(private = "file")
ensure_map_members :: proc(k: ^Checker, type: Type_Id, info: ^Type_Info) {
	key, value := info.key, info.element
	// Insertion clones both halves.
	contribute_lifecycle_members(k, key)
	contribute_lifecycle_members(k, value)

	members := make([dynamic]Symbol_Id, 0, 8, k.c.semantic_allocator)
	none := INVALID_TYPE
	fails := k.c.alloc_result_type
	// design.md "Maps": a lookup takes the borrowed key form; insertion stores
	// the owned key.
	query := key
	if key == TYPE_STRING {
		query = TYPE_STRING_VIEW
	}

	// `inout`, because the returned pointer can mutate the stored value.
	find_mut := container_member(
		k, type, "find_mut", .Map_Find,
		[]Type_Id{type, query}, []Param_Mode{.Inout, .Value},
		option_type(k, pointer_to(k.c, value, true)), 0,
	)
	set_synth_result_summary(k.c, find_mut, 0)
	append(&members, find_mut)
	// The same probe through a read-only borrow.
	find := container_member(
		k, type, "find", .Map_Find,
		[]Type_Id{type, query}, []Param_Mode{.Value, .Value},
		option_type(k, pointer_to(k.c, value, false)), 0, .Value,
	)
	set_synth_result_summary(k.c, find, 0)
	append(&members, find)
	// The owning read, so the receiver is immutable.
	lookup := container_member(
		k, type, "lookup_value", .Map_Lookup_Value,
		[]Type_Id{type, query}, []Param_Mode{.Value, .Value},
		option_type(k, value), 0, .Value,
	)
	set_synth_result_summary(k.c, lookup, 0)
	append(&members, lookup)
	// Inserts the given value when the key is absent, and answers the slot.
	for spelling in ([2]struct{name: string, result: Type_Id}{
		{"find_or_insert", pointer_to(k.c, value, true)},
		{"try_find_or_insert", result_type(k, pointer_to(k.c, value, true), TYPE_ALLOCATOR_ERROR)},
	}) {
		inserting := container_member(
			k, type, spelling.name, .Map_Find_Or_Insert,
			[]Type_Id{type, key, value}, []Param_Mode{.Inout, .Value, .Value}, spelling.result, 0,
		)
		set_synth_result_summary(k.c, inserting, 0)
		append(&members, inserting)
	}
	append(&members, container_member(
		k, type, "try_insert", .Map_Try_Insert,
		[]Type_Id{type, key, value}, []Param_Mode{.Inout, .Value, .Value}, fails, 0,
	))
	map_remove := container_member(
		k, type, "remove", .Map_Remove,
		[]Type_Id{type, query}, []Param_Mode{.Inout, .Value}, option_type(k, value), 0,
	)
	set_synth_result_summary(k.c, map_remove, 0)
	append(&members, map_remove)
	append(&members, container_member(
		k, type, "clear", .Map_Clear, []Type_Id{type}, []Param_Mode{.Inout}, none, 0,
	))
	append(&members, container_member(
		k, type, "reserve", .Map_Reserve,
		[]Type_Id{type, TYPE_INT}, []Param_Mode{.Inout, .Value}, none, 0,
	))
	append(&members, container_member(
		k, type, "try_reserve", .Map_Reserve,
		[]Type_Id{type, TYPE_INT}, []Param_Mode{.Inout, .Value}, fails, 0,
	))
	append(&members, container_member(
		k, type, "shrink", .Map_Shrink,
		[]Type_Id{type, TYPE_INT}, []Param_Mode{.Inout, .Value}, none, 1,
	))
	append(&members, container_member(
		k, type, "try_shrink", .Map_Shrink,
		[]Type_Id{type, TYPE_INT}, []Param_Mode{.Inout, .Value}, fails, 1,
	))
	// design.md "Iteration adapters": the views borrow through the receiver.
	views := [3]struct{name: string, op: Container_Op, kind: View_Kind}{
		{"entries", .Map_Entries, .Entries},
		{"keys", .Map_Keys, .Keys},
		{"values", .Map_Values, .Values},
	}
	for view in views {
		result := container_view_type(k.c, type, view.kind)
		ensure_iteration_members(k, result)
		member := container_member(
			k, type, view.name, view.op, []Type_Id{type}, []Param_Mode{.Value}, result, 0, .Value,
		)
		set_synth_result_summary(k.c, member, 0)
		append(&members, member)
	}
	add_members(k.c, type, members[:])
}

// -------------------------------------------------------------- ordering --

// How an element type answers `<`, settled once during checking so every
// package sorts it the same way. `Unordered` means already reported.
Order_Policy_Kind :: enum { Unresolved, Builtin, Inherent, Unordered }

Order_Policy :: struct {
	kind: Order_Policy_Kind,
	less: Symbol_Id,
}

// A delegated `<` has no body, so it is followed to what it forwards to.
@(private = "file")
resolve_element_order_policy :: proc(c: ^Compiler, element: Type_Id) -> (Order_Policy, string) {
	if element == INVALID_TYPE {
		return Order_Policy{}, "is not a type"
	}
	found := inherent_less_operator(c, element)
	for depth := 0; found != INVALID_SYMBOL && depth < 64; depth += 1 {
		sym := symbol_of(c, found)
		if sym == nil {
			break
		}
		if !sym.delegated {
			return Order_Policy{kind = .Inherent, less = found}, ""
		}
		if sym.delegate_target == INVALID_SYMBOL {
			return Order_Policy{kind = .Builtin}, ""
		}
		found = sym.delegate_target
	}
	if type_is_ordered(c, element) {
		return Order_Policy{kind = .Builtin}, ""
	}
	if blocker := record_order_blocker(c, element); blocker != "" {
		return Order_Policy{}, fmt.tprintf("does not satisfy `interfaces.Ordered`: %s", blocker)
	}
	return Order_Policy{}, "does not satisfy `interfaces.Ordered`: it has no `<`"
}

@(private = "file")
inherent_less_operator :: proc(c: ^Compiler, type: Type_Id) -> Symbol_Id {
	callable, _ := inherent_self_operator(c, type, "<")
	return callable
}

// The procedure a type's own `symbol_text` operator runs over two of its
// values, and the declaration naming it: that procedure, or the group it is a
// member of (design.md "Explicit procedure overloading"), which is what
// visibility asks about. A delegated operator is returned as itself.
inherent_self_operator :: proc(c: ^Compiler, type: Type_Id, symbol_text: string) -> (callable, declared: Symbol_Id) {
	info := type_of(c, type)
	if info == nil {
		return INVALID_SYMBOL, INVALID_SYMBOL
	}
	for member in info.members {
		sym := symbol_of(c, member)
		if sym == nil || sym.operator != symbol_text {
			continue
		}
		if sym.kind != .Proc_Group {
			if operator_on_self(sym, type) {
				return member, member
			}
			continue
		}
		for nested in sym.members {
			if inner := symbol_of(c, nested); inner != nil && operator_on_self(inner, type) {
				return nested, member
			}
		}
	}
	return INVALID_SYMBOL, INVALID_SYMBOL
}

// A binary operator over two values of `type`, the one a sort or a map key
// uses; `(a: T, b: int)` is a different operation.
operator_on_self :: proc(sym: ^Symbol, type: Type_Id) -> bool {
	return !sym.bound_excluded && len(sym.params) == 2 && sym.params[0] == type && sym.params[1] == type
}

resolved_element_order_policy :: proc(c: ^Compiler, element: Type_Id) -> Order_Policy {
	return c.order_policies[element]
}

// The gate on `sort` and `reverse_sort`: it settles the element's `<`, which the
// emitted sort reads.
@(private = "file")
require_sort_order_policy :: proc(k: ^Checker, receiver: Type_Id, span: Span) {
	element := container_element(k.c, receiver)
	if element == INVALID_TYPE {
		element = slice_element(k.c, receiver)
	}
	#partial switch resolved_element_order_policy(k.c, element).kind {
	case .Builtin, .Inherent:
		return
	case .Unordered:
		return // already reported, once, at this element
	}
	policy, reason := resolve_element_order_policy(k.c, element)
	if reason == "" {
		k.c.order_policies[element] = policy
		return
	}
	if committing(k.c) {
		k.c.order_policies[element] = Order_Policy{kind = .Unordered}
	}
	errorf(
		k.c, span, "L0651",
		"`%s` cannot be sorted: its element `%s` %s",
		type_name(k.c, receiver), type_name(k.c, element), reason,
	)
}

// The bound slot of the element a container insertion takes, or -1 for any other
// operation.
container_inserted_slot :: proc(op: Container_Op) -> int {
	#partial switch op {
	case .Insert, .Map_Find_Or_Insert, .Map_Try_Insert:
		return 2
	}
	return -1
}

// The requirements of a container operation, whichever spelling called it:
// `values.resize(1)`, `([dynamic]T).resize(inout values, 1)`, or a group. They
// leave the call's type alone, so a destructuring keeps its arity.
check_container_call :: proc(k: ^Checker, v: ^Expr_Call, chosen: ^Symbol) {
	if chosen == nil {
		return
	}
	check_container_element(k, v.span, chosen)
	element := container_element(k.c, len(chosen.params) > 0 ? chosen.params[0] : INVALID_TYPE)
	// design.md "Container insertion": taken like an initialization, so a
	// borrowed place is copied and a move-only one needs `move(...)`.
	if slot := container_inserted_slot(chosen.container_op); slot >= 0 && slot < len(v.bound) {
		classify_copy_cost(k, v.bound[slot], element, .Insertion)
		if type_clone_disabled(k.c, element) {
			classify_copy(k, v.bound[slot], element, .Insertion)
		}
	}
	// A lone spread lends its slice instead of building a pack, and `append`
	// would keep the elements.
	if chosen.container_op == .Append && type_clone_disabled(k.c, element) && v.variadic_forwards && len(v.bound) > 1 {
		report_move_only_spread(k, v.bound[1], element)
	}
}

// What a container operation requires of its element type alone, so it holds
// for a call and for the operation taken as a procedure value.
check_container_element :: proc(k: ^Checker, span: Span, chosen: ^Symbol) {
	if chosen.container_op == .None || len(chosen.params) == 0 {
		return
	}
	element := container_element(k.c, chosen.params[0])
	#partial switch chosen.container_op {
	case .Resize:
		// design.md "Zero values": growth fills new slots with the element's zero.
		require_type_has_zero(k, element, span, "growing a container")
	case .Map_Lookup_Value:
		if type_clone_disabled(k.c, element) {
			errorf(
				k.c, span, "L0491",
				"`%s` is move-only, so `lookup_value` cannot copy it out; use `find`, which borrows",
				type_name(k.c, element),
			)
		}
	case .Sort, .Reverse_Sort:
		require_sort_order_policy(k, chosen.params[0], span)
	}
}

// design.md "Maps": a key needs a coherent inherent `==` and `hash`. Checked
// where the map type is named.
require_map_key_policy :: proc(k: ^Checker, type: Type_Id, span: Span) -> bool {
	key := container_key(k.c, type)
	if key == INVALID_TYPE {
		return true
	}
	// A rejection is cached as `.Unresolved`, so each key reports once.
	if policy, settled := k.c.map_key_policies[key]; settled {
		return policy.kind != .Unresolved
	}
	// A speculative probe's diagnostics are rolled back, so it must not cache one.
	if committing(k.c) {
		k.c.map_key_policies[key] = Key_Policy{}
	}
	// Keys are copied in and out.
	if type_clone_disabled(k.c, key) {
		errorf(
			k.c, span, "L0586",
			"`%s` cannot be a map key: it is move-only, and a key must be copyable",
			type_name(k.c, key),
		)
		return false
	}
	settle_part_hashes(k, key)
	policy, reason := resolve_map_key_policy(k.c, key)
	if reason == "" && policy.kind == .Inherent {
		resolve_symbol_signature_in_place(k, policy.hash)
		if sym := symbol_of(k.c, policy.hash); sym == nil || !key_hash_signature_ok(sym, key) {
			reason = "has an inherent `hash`, which must be written `proc(self, seed: uint) -> uint`"
		}
	}
	if reason == "" {
		k.c.map_key_policies[key] = policy
		return true
	}
	errorf(
		k.c, span, "L0586",
		"`%s` cannot be a map key: it %s",
		type_name(k.c, key), reason,
	)
	add_notef(
		k.c, no_span(),
		"an extension block does not qualify; wrap the key in a local `distinct` type with its own inherent operations",
	)
	return false
}

// Settles the key policy of every map nested in `type`.
require_nested_map_key_policies :: proc(k: ^Checker, type: Type_Id, span: Span) -> bool {
	seen := make(map[Type_Id]bool)
	defer delete(seen)
	return require_nested_map_key_policies_inner(k, type, span, &seen)
}

@(private = "file")
require_nested_map_key_policies_inner :: proc(k: ^Checker, type: Type_Id, span: Span, seen: ^map[Type_Id]bool) -> bool {
	if type == INVALID_TYPE || seen[type] { return true }
	seen[type] = true
	info := type_of(k.c, type)
	if info == nil { return true }
	#partial switch info.kind {
	case .Map:
		if !require_map_key_policy(k, type, span) { return false }
		if !require_nested_map_key_policies_inner(k, info.key, span, seen) { return false }
		return require_nested_map_key_policies_inner(k, info.element, span, seen)
	case .Array, .Dynamic_Array, .Slice, .Pointer, .C_Pointer, .Distinct:
		return require_nested_map_key_policies_inner(k, info.element, span, seen)
	case .Struct:
		for field in info.fields {
			if sym := symbol_of(k.c, field); sym != nil &&
			   !require_nested_map_key_policies_inner(k, sym.type, span, seen) { return false }
		}
	case .Union:
		for variant in info.variants {
			if !require_nested_map_key_policies_inner(k, variant, span, seen) { return false }
		}
	case .Proc:
		for parameter in info.parameters {
			if !require_nested_map_key_policies_inner(k, parameter, span, seen) { return false }
		}
		if info.result != INVALID_TYPE && !require_nested_map_key_policies_inner(k, info.result, span, seen) {
			return false
		}
	}
	return true
}

// `defaulted` is the first parameter position that takes the constant zero, or
// 0 when every parameter is required.
@(private = "file")
container_member :: proc(
	k: ^Checker,
	owner: Type_Id,
	name: string,
	op: Container_Op,
	params: []Type_Id,
	modes: []Param_Mode,
	result: Type_Id,
	defaulted: int,
	receiver := Param_Mode.Inout,
) -> Symbol_Id {
	// design.md "Receiver forms": a read-only receiver is taken by address, like a
	// written `self: ^`.
	signature_modes, receiver_mode := modes, receiver
	if receiver == .Value && len(modes) > 0 && modes[0] == .Value {
		adjusted := make([]Param_Mode, len(modes), k.c.semantic_allocator)
		copy(adjusted, modes)
		adjusted[0] = .Borrow
		signature_modes, receiver_mode = adjusted, .Borrow
	}
	id := synth_proc(k.c, name, .Container_Op, owner, params, signature_modes, result)
	if sym := symbol_of(k.c, id); sym != nil {
		sym.has_receiver = true
		sym.receiver = receiver_mode
		sym.container_op = op
		if defaulted > 0 {
			sym.param_defaults[defaulted] = zero_int_arg(k.c)
		}
	}
	// Named `key` for named-argument binding.
	#partial switch op {
	case .Map_Find, .Map_Find_Or_Insert, .Map_Lookup_Value, .Map_Try_Insert, .Map_Remove:
		symbol_of(k.c, id).param_symbols[1] = new_parameter(k.c, intern_identifier(k.c, "key"), params[1], modes[1])
	}
	return id
}

// The shared constant `0` for a defaulted `shrink` floor.
@(private = "file")
zero_int_arg :: proc(c: ^Compiler) -> Expr {
	if c.zero_int_arg != nil {
		return c.zero_int_arg
	}
	literal := new(Expr_Literal, c.semantic_allocator)
	literal.span = no_span()
	literal.kind = .Int
	literal.type = TYPE_INT
	literal.value_category = .Value
	literal.is_const = true
	literal.const_value = int_const(c, 0)
	c.zero_int_arg = literal
	return literal
}

// ------------------------------------------------------- allocator policy --

// design.md "Allocators": `T via expression` records the declaration's allocator
// policy on its symbols. It selects for revival, copies in, and literals built
// here; a live destination keeps the allocator its value was built with.
check_via_policy :: proc(k: ^Checker, d: ^Decl, declared: Type_Id) -> bool {
	if d.via == nil {
		return true
	}
	// Static storage cannot run the allocator expression.
	if d.top_level || d.duration != .None {
		storage_kind :=
			d.duration == .Thread_Local ? "`thread_local` storage" :
			d.duration == .Static ? "`static` storage" : "file-scope storage"
		errorf(
			k.c,
			expr_span(d.via),
			"L0576",
			"`via` selects a provider by running an expression, which %s cannot do; it starts allocator-unbound and binds on first use",
			storage_kind,
		)
		return false
	}
	if declared == INVALID_TYPE {
		return false // the written type already said why
	}
	// design.md "Shared ownership": the control block stores the allocator.
	if type_is_shared_handle(k.c, declared) {
		errorf(
			k.c,
			expr_span(d.via),
			"L0671",
			"`%s` stores its allocator in the control block, so a declaration cannot select one with `via`",
			type_name(k.c, declared),
		)
		add_notef(
			k.c,
			no_span(),
			"select it where the value is made: `shared(value, allocator=...)` or `try_shared(value, allocator)`",
		)
		return false
	}
	if !type_accepts_via(k.c, declared) {
		errorf(
			k.c,
			expr_span(d.via),
			"L0577",
			"`via` selects the provider a value is built with, and `%s` has no destination allocation to select",
			type_name(k.c, declared),
		)
		add_notef(
			k.c,
			no_span(),
			"`via` applies to a managed owner whose storage is allocated as it grows, such as `[dynamic]T`, `map[K]V`, or a record with a `try_clone`",
		)
		return false
	}
	allocator := check_single_expr(k, d.via, TYPE_ALLOCATOR)
	if allocator == INVALID_TYPE {
		return false
	}
	if type_underlying(k.c, allocator) != TYPE_ALLOCATOR {
		errorf(
			k.c,
			expr_span(d.via),
			"L0578",
			"a `via` policy names an `Allocator`, found `%s`",
			type_name(k.c, allocator),
		)
		return false
	}
	// A copy into this destination clones.
	contribute_lifecycle_members(k, declared)
	for symbol_id in d.symbols {
		if sym := symbol_of(k.c, symbol_id); sym != nil {
			sym.via = d.via
		}
	}
	return true
}

// A trivial or borrowed value owns no allocation; a move-only value has no
// clone to pass an allocator to; an immutable `string` shares storage through
// a retain rather than allocating into a destination.
type_accepts_via :: proc(c: ^Compiler, type: Type_Id) -> bool {
	if type == INVALID_TYPE || !type_is_managed(c, type) {
		return false
	}
	if type_clone_disabled(c, type) {
		return false
	}
	info := underlying_info(c, type)
	if info == nil {
		return false
	}
	#partial switch info.kind {
	case .String:
		return false
	}
	return true
}

// A container literal built into a destination with a `via` policy uses that
// allocator directly.
bind_literal_allocator :: proc(c: ^Compiler, value: Expr, destination: Symbol_Id) {
	written := symbol_via_allocator(c, destination)
	if written == nil {
		return
	}
	literal, is_literal := value.(^Expr_Composite)
	if !is_literal || !type_is_container(c, literal.type) {
		return
	}
	literal.via = written
}

// The destination's written `via`, or nil for the lazy default binding.
symbol_via_allocator :: proc(c: ^Compiler, symbol_id: Symbol_Id) -> Expr {
	sym := symbol_of(c, symbol_id)
	return sym == nil ? nil : sym.via
}

// design.md "Dynamic arrays" and "Maps":
//
//   make([dynamic]T, len: int = 0, cap: int = len, allocator = default)
//   make(map[K]V, reservation: int = 0, allocator = default)
//
// both returning `(container, Allocator_Error)`. `Allocator` is a distinct type,
// so the trailing allocator is recognised by its type rather than its position,
// and it alone has a name to write: `allocator=`.
check_make_builtin :: proc(k: ^Checker, v: ^Expr_Call, fallible: bool) {
	v.type = INVALID_TYPE
	if len(v.args) == 0 {
		errorf(k.c, v.span, "L0579", "`make` names the container type to create")
		return
	}
	for arg, index in v.args {
		shape := arg
		if index > 0 && arg.name.text == "allocator" {
			shape.name = {}
		}
		if shape.name.text != "" || shape.mode != .Value {
			reject_builtin_argument_shape(k, shape)
			return
		}
	}
	container := operand_type(k, v.args[0].value, "make", false)
	if container == INVALID_TYPE || !gate_type(k, container, expr_span(v.args[0].value)) {
		return
	}
	if !type_is_container(k.c, container) {
		errorf(
			k.c,
			expr_span(v.args[0].value),
			"L0579",
			"`make` creates a `[dynamic]T` or a `map[K]V`, found `%s`",
			type_name(k.c, container),
		)
		return
	}
	// A move-only element has no clone, but `make` never copies one.
	contribute_lifecycle_members(k, container)

	is_map := type_is_map(k.c, container)
	max_counts := is_map ? 1 : 2
	// Fixed shape: the counts in written order, then the allocator or nil.
	bound := make([]Expr, max_counts + 1, k.c.semantic_allocator)
	counts := 0
	for index in 1 ..< len(v.args) {
		argument := v.args[index].value
		named := v.args[index].name.text != ""
		last := index == len(v.args) - 1
		// Only the last argument may be the allocator, so the others expect `int`.
		hint := named ? TYPE_ALLOCATOR : last ? INVALID_TYPE : TYPE_INT
		if check_single_expr(k, argument, hint) == INVALID_TYPE {
			return
		}
		is_allocator := type_underlying(k.c, expr_base(argument).type) == TYPE_ALLOCATOR
		if named || is_allocator {
			if !last {
				errorf(k.c, expr_span(argument), "L0579", "the allocator is `make`'s last argument")
				return
			}
			if !is_allocator {
				errorf(
					k.c, expr_span(argument), "L0490",
					"an allocator argument is an `Allocator`, found `%s`", type_name(k.c, expr_base(argument).type),
				)
				return
			}
			bound[max_counts] = argument
			continue
		}
		if counts == max_counts {
			shape := is_map ? "a map, an optional reservation, and an optional allocator" :
				"a dynamic array type, an optional length and capacity, and an optional allocator"
			errorf(k.c, expr_span(argument), "L0579", "`make` takes %s", shape)
			return
		}
		if !materialize(k, argument, TYPE_INT) {
			return
		}
		if expr_base(argument).type != TYPE_INT {
			errorf(
				k.c,
				expr_span(argument),
				"L0579",
				"a `make` %s is an `int`, found `%s`",
				is_map ? "reservation" : "length or capacity",
				type_name(k.c, expr_base(argument).type),
			)
			return
		}
		bound[counts] = argument
		counts += 1
	}
	v.bound = bound
	v.operation = Call_Allocation{type = container, fallible = fallible}
	// design.md "Zero values": only a length fills slots with zeroes, and a
	// constant `0` fills none.
	if !is_map && counts > 0 && !is_constant_zero(bound[0]) {
		if !require_type_has_zero(
			k, container_element(k.c, container), expr_span(bound[0]), "a `make` length",
		) {
			return
		}
	}

	v.type = fallible ? result_type(k, container, TYPE_ALLOCATOR_ERROR) : container
}

@(private = "file")
is_constant_zero :: proc(e: Expr) -> bool {
	base := expr_base(e)
	return base.is_const && base.const_value.kind == .Integer && bi_is_zero(base.const_value.integer)
}

// `core:slice.sort_by_intrinsic(values, &comparator)`. The public wrapper hands
// it an ordering record whose `call` compares two elements; this records the
// exact `call` method for lowering and guards against a malformed replacement
// standard package.
check_slice_sort_by :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident) {
	if !builtin_arity_ok(k, v, ident, "L0322", 2) {
		return
	}

	values := check_single_expr(k, v.args[0].value)
	values_info := underlying_info(k.c, values)
	if values_info == nil || values_info.kind != .Slice || !values_info.mutable {
		errorf(
			k.c, expr_span(v.args[0].value), "L0651",
			"`%s` needs a mutable slice, found `%s`", ident.name, type_name(k.c, values),
		)
		return
	}

	ctx := check_single_expr(k, v.args[1].value)
	context_info := underlying_info(k.c, ctx)
	if context_info == nil || context_info.kind != .Pointer {
		errorf(
			k.c, expr_span(v.args[1].value), "L0651",
			"`%s` needs a pointer to its comparator, found `%s`", ident.name, type_name(k.c, ctx),
		)
		return
	}

	element := values_info.element
	comparator := context_info.element
	name := intern_identifier(k.c, "call")
	match := INVALID_SYMBOL
	matches := 0
	for candidate in method_candidates(k, comparator, name) {
		sym := symbol_of(k.c, candidate)
		if sym != nil && slot_matches(
			k, sym,
			[]Type_Id{comparator, element, element},
			[]Param_Mode{.Borrow, .Value, .Value},
			TYPE_BOOL, false,
		) {
			match = candidate
			matches += 1
		}
	}
	if matches != 1 {
		errorf(
			k.c, v.span, "L0651",
			"`%s` must provide exactly one `call(self, left: %s, right: %s) -> bool` method for sorting",
			type_name(k.c, comparator), type_name(k.c, element), type_name(k.c, element),
		)
		return
	}

	v.bound = bound_exprs(k, v.args[0].value, v.args[1].value)
	v.operation = Call_Sort_By{comparator = match}
	v.type = TYPE_VOID
}

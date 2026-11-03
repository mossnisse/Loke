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
	ensure_container_fields(c, type, "data")
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
	ensure_container_fields(c, type, "table")
	return type
}

@(private = "file")
ensure_container_fields :: proc(c: ^Compiler, type: Type_Id, storage: string) {
	info := type_of(c, type)
	if len(info.fields) > 0 {
		return
	}
	info.fields = make([]Symbol_Id, 4, c.semantic_allocator)
	info.fields[CONTAINER_STORAGE] = new_field(c, storage, TYPE_RAWPTR, CONTAINER_STORAGE)
	info.fields[CONTAINER_LEN] = new_field(c, "len", TYPE_INT, CONTAINER_LEN)
	info.fields[CONTAINER_CAP] = new_field(c, "cap", TYPE_INT, CONTAINER_CAP)
	info.fields[CONTAINER_ALLOC] = new_field(c, "allocator", TYPE_ALLOCATOR, CONTAINER_ALLOC)
}

type_is_dynamic_array :: proc(c: ^Compiler, id: Type_Id) -> bool {
	return underlying_kind(c, id) == .Dynamic_Array
}

type_is_map :: proc(c: ^Compiler, id: Type_Id) -> bool {
	return underlying_kind(c, id) == .Map
}

type_is_container :: proc(c: ^Compiler, id: Type_Id) -> bool {
	kind := underlying_kind(c, id)
	return kind == .Dynamic_Array || kind == .Map
}

// The element (`[dynamic]T`'s `T`, `map[K]V`'s `V`), or INVALID_TYPE.
container_element :: proc(c: ^Compiler, id: Type_Id) -> Type_Id {
	info := underlying_info(c, id)
	if info == nil || (info.kind != .Dynamic_Array && info.kind != .Map) {
		return INVALID_TYPE
	}
	return info.element
}

container_key :: proc(c: ^Compiler, id: Type_Id) -> Type_Id {
	info := underlying_info(c, id)
	if info == nil || info.kind != .Map {
		return INVALID_TYPE
	}
	return info.key
}

// The element of a container or a slice, or INVALID_TYPE: what a sort orders.
sequence_element :: proc(c: ^Compiler, id: Type_Id) -> Type_Id {
	element := container_element(c, id)
	return element != INVALID_TYPE ? element : slice_element(c, id)
}

// ------------------------------------------------------ contributed members --

// Which operation a contributed member is. A panicking spelling and its `try_`
// form share one entry.
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

// design.md "Container insertion": a `try_` form copies its element in, so a
// failure leaves the caller's argument untouched, and a move-only element has
// no such form.
container_member_is_try :: proc(c: ^Compiler, symbol: ^Symbol) -> bool {
	text := identifier_text(c, symbol.name)
	return len(text) > 4 && text[:4] == "try_"
}

// design.md "Dynamic arrays": the operations are real members, so calls reuse
// overload ranking, `..T` packing, defaults, and the `inout` receiver rule.
ensure_container_members :: proc(k: ^Checker, type: Type_Id) {
	info := type_of(k.c, type)
	if info == nil || .Container in info.contributed {
		return
	}
	info.contributed += {.Container}
	#partial switch info.kind {
	case .Dynamic_Array:
		ensure_dynamic_members(k, type, info.element)
	case .Slice:
		if info.mutable {
			ensure_slice_members(k, type)
		}
	case .Map:
		ensure_map_members(k, type, info.key, info.element)
	}
}

@(private = "file")
ensure_dynamic_members :: proc(k: ^Checker, type: Type_Id, element: Type_Id) {
	// Insertion clones.
	contribute_lifecycle_members(k, element)

	members := make([dynamic]Symbol_Id, 0, 17)
	defer delete(members)
	none := INVALID_TYPE

	pack := slice_of(k.c, element, mutable = false)
	append_fallible_members(k, &members, type, "append", "try_append", .Append, {pack}, variadic = true)
	append_fallible_members(k, &members, type, "insert", "try_insert", .Insert, {TYPE_INT, element})
	append_lending_member(k, &members, type, "pop", .Pop, .Inout, nil, option_type(k, element))
	append_lending_member(k, &members, type, "remove", .Remove, .Inout, {TYPE_INT}, element)
	append_lending_member(k, &members, type, "remove_unordered", .Remove_Unordered, .Inout, {TYPE_INT}, element)
	append(&members, container_member(k, type, "clear", .Clear, .Inout, nil, none))
	append_fallible_members(k, &members, type, "resize", "try_resize", .Resize, {TYPE_INT})
	append_fallible_members(k, &members, type, "reserve", "try_reserve", .Reserve, {TYPE_INT})
	// `shrink()` is `shrink(0)`: the target is `max(len, min_capacity)`.
	append_fallible_members(k, &members, type, "shrink", "try_shrink", .Shrink, {TYPE_INT}, defaults_zero = true)
	append(&members, container_member(k, type, "sort", .Sort, .Inout, nil, none))
	append(&members, container_member(k, type, "reverse_sort", .Reverse_Sort, .Inout, nil, none))
	append(&members, container_member(k, type, "swap", .Swap, .Inout, {TYPE_INT, TYPE_INT}, none))
	add_members(k.c, type, members[:])
}

// standard-library.md "Sorting slices": only `[]mut T` has these members. The
// receiver is borrowed: the header is itself a borrow of the caller's elements.
@(private = "file")
ensure_slice_members :: proc(k: ^Checker, type: Type_Id) {
	none := INVALID_TYPE
	// Both halves borrow the receiver, so the caller's slice stays suspended
	// while either is live.
	halves := anon_record_type(k.c, []Anon_Record_Field{
		{name = intern_identifier(k.c, "left"), type = type},
		{name = intern_identifier(k.c, "right"), type = type},
	})
	split := container_member(k, type, "split_at_mut", .Split_At_Mut, .Borrow, {TYPE_INT}, halves)
	set_synth_result_summary(k.c, split, 0, per_path = true)
	chunks := container_member(k, type, "chunks_mut", .Chunks_Mut, .Borrow, {TYPE_INT}, chunks_mut_type(k, type))
	set_synth_result_summary(k.c, chunks, 0, per_path = true)
	add_members(k.c, type, []Symbol_Id{
		container_member(k, type, "sort", .Sort, .Borrow, nil, none),
		container_member(k, type, "reverse_sort", .Reverse_Sort, .Borrow, nil, none),
		container_member(k, type, "swap", .Swap, .Borrow, {TYPE_INT, TYPE_INT}, none),
		split,
		chunks,
	})
}

// Field positions of `Chunks_Mut(T)`.
CHUNKS_REST :: 0
CHUNKS_SIZE :: 1

// standard-library.md "Chunks of a mutable slice": what `chunks_mut` returns, its
// own iterator.
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
ensure_map_members :: proc(k: ^Checker, type: Type_Id, key, value: Type_Id) {
	// Insertion clones both halves.
	contribute_lifecycle_members(k, key)
	contribute_lifecycle_members(k, value)

	members := make([dynamic]Symbol_Id, 0, 15)
	defer delete(members)
	none := INVALID_TYPE
	// design.md "Maps": a lookup takes the borrowed key form; insertion stores
	// the owned key.
	query := key
	if key == TYPE_STRING {
		query = TYPE_STRING_VIEW
	}

	// `inout`, because the returned pointer can mutate the stored value.
	append_lending_member(k, &members, type, "find_mut", .Map_Find, .Inout, {query}, option_type(k, pointer_to(k.c, value, true)))
	append_lending_member(k, &members, type, "find", .Map_Find, .Borrow, {query}, option_type(k, pointer_to(k.c, value, false)))
	// The owning read, so the receiver is immutable.
	append_lending_member(k, &members, type, "lookup_value", .Map_Lookup_Value, .Borrow, {query}, option_type(k, value))
	slot := pointer_to(k.c, value, true)
	try_slot := result_type(k, slot, TYPE_ALLOCATOR_ERROR)
	append_lending_member(k, &members, type, "find_or_insert", .Map_Find_Or_Insert, .Inout, {key, value}, slot)
	append_lending_member(k, &members, type, "try_find_or_insert", .Map_Find_Or_Insert, .Inout, {key, value}, try_slot)
	append(&members, container_member(k, type, "try_insert", .Map_Try_Insert, .Inout, {key, value}, k.c.alloc_result_type))
	append_lending_member(k, &members, type, "remove", .Map_Remove, .Inout, {query}, option_type(k, value))
	append(&members, container_member(k, type, "clear", .Map_Clear, .Inout, nil, none))
	append_fallible_members(k, &members, type, "reserve", "try_reserve", .Map_Reserve, {TYPE_INT})
	append_fallible_members(k, &members, type, "shrink", "try_shrink", .Map_Shrink, {TYPE_INT}, defaults_zero = true)
	// design.md "Iteration adapters": the views borrow through the receiver.
	views := [3]struct{name: string, op: Container_Op, kind: View_Kind}{
		{"entries", .Map_Entries, .Entries},
		{"keys", .Map_Keys, .Keys},
		{"values", .Map_Values, .Values},
	}
	for view in views {
		result := container_view_type(k.c, type, view.kind)
		ensure_iteration_members(k, result)
		append_lending_member(k, &members, type, view.name, view.op, .Borrow, nil, result)
	}
	add_members(k.c, type, members[:])
}

// One operation: its receiver, by `receiver`, then by-value parameters of the
// `trailing` types. design.md "Receiver forms": a read-only receiver is
// `.Borrow`, taken by address like a written `self: ^`. `defaults_zero` lets a
// call omit the first trailing parameter; `variadic` makes the last a pack.
@(private = "file")
container_member :: proc(
	k: ^Checker,
	owner: Type_Id,
	name: string,
	op: Container_Op,
	receiver: Param_Mode,
	trailing: []Type_Id,
	result: Type_Id,
	defaults_zero := false,
	variadic := false,
) -> Symbol_Id {
	params: [3]Type_Id
	modes: [3]Param_Mode
	count := 1 + len(trailing)
	params[0], modes[0] = owner, receiver
	copy(params[1:], trailing)
	if variadic {
		modes[count - 1] = .Variadic
	}
	id := synth_receiver_proc(k.c, name, .Container_Op, owner, params[:count], modes[:count], result)
	sym := symbol_of(k.c, id)
	sym.container_op = op
	if defaults_zero {
		sym.param_defaults[1] = zero_literal_arg(k.c, TYPE_INT)
	}
	// Named `key` for named-argument binding.
	#partial switch op {
	case .Map_Find, .Map_Find_Or_Insert, .Map_Lookup_Value, .Map_Try_Insert, .Map_Remove:
		sym.param_symbols[1] = new_parameter(k.c, intern_identifier(k.c, "key"), trailing[0], .Value)
	}
	return id
}

// A member whose result borrows through its receiver, or is owned in its regions.
@(private = "file")
append_lending_member :: proc(
	k: ^Checker,
	members: ^[dynamic]Symbol_Id,
	owner: Type_Id,
	name: string,
	op: Container_Op,
	receiver: Param_Mode,
	trailing: []Type_Id,
	result: Type_Id,
) {
	id := container_member(k, owner, name, op, receiver, trailing, result)
	set_synth_result_summary(k.c, id, 0)
	append(members, id)
}

// One signature's two spellings: the panicking one, and the `try_` form that
// answers the allocation's result.
@(private = "file")
append_fallible_members :: proc(
	k: ^Checker,
	members: ^[dynamic]Symbol_Id,
	owner: Type_Id,
	name, try_name: string,
	op: Container_Op,
	trailing: []Type_Id,
	defaults_zero := false,
	variadic := false,
) {
	append(members, container_member(k, owner, name, op, .Inout, trailing, INVALID_TYPE, defaults_zero, variadic))
	append(members, container_member(k, owner, try_name, op, .Inout, trailing, k.c.alloc_result_type, defaults_zero, variadic))
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
	callable, _ := inherent_self_operator(c, element, "<")
	less, builtin := operator_delegate_end(c, callable)
	if builtin {
		return Order_Policy{kind = .Builtin}, ""
	}
	if less != INVALID_SYMBOL {
		return Order_Policy{kind = .Inherent, less = less}, ""
	}
	if type_is_ordered(c, element) {
		return Order_Policy{kind = .Builtin}, ""
	}
	if blocker := record_order_blocker(c, element); blocker != "" {
		return Order_Policy{}, fmt.tprintf("does not satisfy `interfaces.Ordered`: %s", blocker)
	}
	return Order_Policy{}, "does not satisfy `interfaces.Ordered`: it has no `<`"
}

resolved_element_order_policy :: proc(c: ^Compiler, element: Type_Id) -> Order_Policy {
	return c.order_policies[element]
}

// The gate on `sort` and `reverse_sort`: it settles the element's `<`, which the
// emitted sort reads.
@(private = "file")
require_sort_order_policy :: proc(k: ^Checker, receiver: Type_Id, span: Span) {
	element := sequence_element(k.c, receiver)
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

// ------------------------------------------------- operation requirements --

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
	if chosen == nil || chosen.container_op == .None {
		return
	}
	check_container_element(k, v.span, chosen)
	element := container_element(k.c, chosen.params[0])
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
	if chosen.container_op == .None {
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

// ------------------------------------------------------- allocator policy --

bind_literal_allocator :: proc(c: ^Compiler, value: Expr, destination: Symbol_Id) {
	if literal, is_literal := value.(^Expr_Composite); is_literal && type_is_container(c, literal.type) {
		literal.via = symbol_via_allocator(c, destination)
	}
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

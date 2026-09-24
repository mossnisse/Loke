// The managed containers `[dynamic]T` and `map[K]V` (design.md "Dynamic arrays",
// "Maps"). Both are four-word headers whose all-zero value is empty and usable:
//
//   [dynamic]T   { rawptr data,  int len, int cap, Allocator allocator }
//   map[K]V      { rawptr table, int len, int cap, Allocator allocator }
//
// The storage behind them lives in `runtime/container.c`; the compiler supplies
// each element type's clone, drop, hash, and compare operations.
package lokec

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

// Installed on first use, since interning runs where making a symbol is not yet
// safe. Idempotent.
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
	// A `^Type_Info` points into the growing type store, so it is never held
	// across the field symbols being made.
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
	// design.md "Swapping elements": one operation, since two `inout` borrows of
	// the same sequence could not be proven distinct.
	Swap,
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
	fails := result_type(k, k.c.unit_type, TYPE_ALLOCATOR_ERROR)

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

// design.md "Sorting slices": only `[]mut T` has these members. The receiver is a
// value, since the slice header is a borrow of the caller's elements.
@(private = "file")
ensure_slice_members :: proc(k: ^Checker, type: Type_Id, info: ^Type_Info) {
	if !info.mutable {
		return
	}
	members := make([dynamic]Symbol_Id, 0, 3, k.c.semantic_allocator)
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
	add_members(k.c, type, members[:])
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
	fails := result_type(k, k.c.unit_type, TYPE_ALLOCATOR_ERROR)
	// design.md "Maps": a lookup takes the borrowed key form; insertion stores
	// the owned key.
	query := key
	if key == TYPE_STRING {
		query = TYPE_STRING_VIEW
	}

	// `inout`, because the returned pointer can mutate the stored value.
	find := container_member(
		k, type, "find", .Map_Find,
		[]Type_Id{type, query}, []Param_Mode{.Inout, .Value},
		option_type(k, pointer_to(k.c, value, true)), 0,
	)
	set_synth_result_summary(k.c, find, 0)
	append(&members, find)
	// The same probe through a read-only borrow.
	find_ref := container_member(
		k, type, "find_ref", .Map_Find,
		[]Type_Id{type, query}, []Param_Mode{.Value, .Value},
		option_type(k, pointer_to(k.c, value, false)), 0, .Value,
	)
	set_synth_result_summary(k.c, find_ref, 0)
	append(&members, find_ref)
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
	return Order_Policy{}, "does not satisfy `interfaces.Ordered`: it has no `<`"
}

@(private = "file")
inherent_less_operator :: proc(c: ^Compiler, type: Type_Id) -> Symbol_Id {
	info := type_of(c, type)
	if info == nil {
		return INVALID_SYMBOL
	}
	for member in info.members {
		if sym := symbol_of(c, member); sym != nil && sym.operator == "<" && operator_on_self(sym, type) {
			return member
		}
	}
	return INVALID_SYMBOL
}

// A binary operator over two values of `type`, the one a sort or a map key
// uses; `(a: T, b: int)` is a different operation.
operator_on_self :: proc(sym: ^Symbol, type: Type_Id) -> bool {
	return !sym.bound_excluded && len(sym.params) == 2 && sym.params[0] == type && sym.params[1] == type
}

resolved_element_order_policy :: proc(c: ^Compiler, element: Type_Id) -> Order_Policy {
	return c.order_policies[element]
}

// The gate on `sort` and `reverse_sort`, reported at the call.
require_sort_order_policy :: proc(k: ^Checker, chosen: ^Symbol, span: Span) -> bool {
	if chosen == nil || chosen.synth != .Container_Op {
		return true
	}
	#partial switch chosen.container_op {
	case .Sort, .Reverse_Sort:
	case:
		return true
	}
	receiver := len(chosen.params) > 0 ? chosen.params[0] : INVALID_TYPE
	element := container_element(k.c, receiver)
	if element == INVALID_TYPE {
		element = slice_element(k.c, receiver)
	}
	#partial switch resolved_element_order_policy(k.c, element).kind {
	case .Builtin, .Inherent:
		return true
	case .Unordered:
		return false // already reported, once, at this element
	}
	policy, reason := resolve_element_order_policy(k.c, element)
	if reason == "" {
		k.c.order_policies[element] = policy
		return true
	}
	if k.c.speculation_depth == 0 {
		k.c.order_policies[element] = Order_Policy{kind = .Unordered}
	}
	errorf(
		k.c, span, "L0651",
		"`%s` cannot be sorted: its element `%s` %s",
		type_name(k.c, receiver), type_name(k.c, element), reason,
	)
	return false
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
	if k.c.speculation_depth == 0 {
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
	// Keep a value snapshot: resolving an operation can grow the type store.
	shape := info^
	#partial switch shape.kind {
	case .Map:
		if !require_map_key_policy(k, type, span) { return false }
		if !require_nested_map_key_policies_inner(k, shape.key, span, seen) { return false }
		return require_nested_map_key_policies_inner(k, shape.element, span, seen)
	case .Array, .Dynamic_Array, .Slice, .Pointer, .C_Pointer, .Distinct:
		return require_nested_map_key_policies_inner(k, shape.element, span, seen)
	case .Struct:
		for field in shape.fields {
			if sym := symbol_of(k.c, field); sym != nil &&
			   !require_nested_map_key_policies_inner(k, sym.type, span, seen) { return false }
		}
	case .Union:
		for variant in shape.variants {
			if !require_nested_map_key_policies_inner(k, variant, span, seen) { return false }
		}
	case .Proc:
		for parameter in shape.parameters {
			if !require_nested_map_key_policies_inner(k, parameter, span, seen) { return false }
		}
		if shape.result != INVALID_TYPE && !require_nested_map_key_policies_inner(k, shape.result, span, seen) {
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
		key_symbol := new_symbol(k.c, Symbol{
			name = intern_identifier(k.c, "key"), kind = .Parameter,
			type = params[1], mode = modes[1],
		})
		symbol_of(k.c, id).param_symbols[1] = key_symbol
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
			"`via` applies to a managed owner whose clone takes a destination allocator, such as `[dynamic]T`, `map[K]V`, or a record with a `try_clone`",
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

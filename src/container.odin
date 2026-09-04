// The two managed containers: `[dynamic]T` and `map[K]V`.
//
// design.md "Dynamic arrays" and "Maps". Both are owning values with deep copy
// semantics, and both are frozen as four words:
//
//   [dynamic]T   { rawptr data,  int len, int cap, Allocator allocator }
//   map[K]V      { rawptr table, int len, int cap, Allocator allocator }
//
// The all-zero value is empty, allocator-unbound, constant, and immediately
// usable, which is what lets a file-scope, `static`, or `thread_local` container
// be constant-initialised with no code running before `main`.
//
// Like `[]T`, both are compiler-owned struct-shaped types with synthesised
// fields, so layout, parameter passing, zero constants, and emission reuse the
// aggregate paths that already exist instead of growing a second mechanism. The
// fields are not user-visible: field selection is offered for `.Struct` only.
//
// Everything behind `data` and `table` — growth, slot control bytes, the seed,
// checked byte sizes — belongs to the versioned C helpers in
// `runtime/container.c`. What C cannot know is what one concrete Loke element
// costs to clone, drop, hash, or compare, so the compiler hands every call one
// generated operation table (`src/emit_llvm.odin`).
package lokec

// Both headers share these four positions: `data`/`table`, length, capacity,
// and the bound provider handle.
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

// Installed on first use rather than at intern time, for the same reason a
// slice's are: a field is a symbol, and interning runs where making one is not
// yet safe. Idempotent, so every entry point may ask.
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
	// design.md "Allocators": the header retains the provider its drop releases
	// through, which is why a container can be dropped without its declaration in
	// scope.
	fields[CONTAINER_ALLOC] = new_field(c, "allocator", TYPE_ALLOCATOR, CONTAINER_ALLOC)
	// The store may have grown while the field symbols were made.
	info = type_of(c, type)
	info.fields = fields
}

type_is_dynamic_array :: proc(c: ^Compiler, id: Type_Id) -> bool {
	return underlying_kind(c, id) == .Dynamic_Array
}

type_is_map :: proc(c: ^Compiler, id: Type_Id) -> bool {
	return underlying_kind(c, id) == .Map
}

// Either managed container. Both share one header shape, one operation-table
// shape, and one allocator-binding policy, so most callers want this rather
// than one of the two above.
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

// Which operation one contributed member is, so the backend writes the right
// body without matching on its name.
//
// design.md "Typed fallibility" spells each mutating operation twice, once
// panicking on allocation failure and once reporting it. Those are one
// operation; `symbol.result` says which spelling a call reached, so the pair
// shares an entry rather than being a second source of truth for it.
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
	// design.md "Dynamic array container operations" and "Sorting slices".
	// Contributed to a mutable slice as well as to a dynamic array, because an
	// `impl []mut T` written in `core:slice` would be an *extension* visible only
	// inside that package, and design.md's own `s.sort()` is written in user code.
	Sort,
	Reverse_Sort,
	// The map half. `find` never inserts; `m[key] = v` and every chain rooted in
	// one are places rather than calls, so they are not members.
	Map_Find,
	Map_Lookup_Value,
	Map_Try_Insert,
	Map_Remove,
	Map_Clear,
	Map_Reserve,
	Map_Shrink,
	// design.md "Iteration adapters": the three borrowed traversals. Each answers
	// with an opaque view that allocates nothing and copies no element; the copy
	// happens per step, inside the view's `next`.
	Map_Entries,
	Map_Keys,
	Map_Values,
}

// design.md "Dynamic arrays": the operation set, contributed as real members so
// `xs.append(1)` is an ordinary method call — not cosmetic, it makes these
// operations reachable from generic code constrained by the standard
// catalogue, and reuses overload ranking, `..T` packing, default arguments,
// and the `inout`-receiver place rule instead of a second call path.
//
// The `..T` pack a variadic receives *is* a read-only slice, so `append` clones
// each element in through its selected allocator — a move-only element can't
// travel through the variadic form, and `insert` takes one value for the same
// reason.
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
	// Insertion clones, so the element's own copy entry point has to exist.
	contribute_lifecycle_members(k, element)

	members := make([dynamic]Symbol_Id, 0, 16, k.c.semantic_allocator)
	none := INVALID_TYPE
	// design.md "Typed fallibility": a recoverable operation reports through
	// `Result(Unit, Allocator_Error)`, never a trailing status.
	fails := result_type(k, unit_type(k.c), TYPE_ALLOCATOR_ERROR)

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
	// design.md "Typed fallibility": an empty container yields `.none`. The
	// removed value's provenance is the element's, not the container's — what
	// comes back holds what that element held. Written as a summary for the
	// same reason `lookup_value` has one: a synthesised member has no body for
	// the fixed point to walk.
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
	// design.md spells `shrink` twice, with and without a floor. One signature
	// with a default of zero is the same two calls: the target is always
	// `max(len, min_capacity)`, and zero is what "shrink to fit" means.
	append(&members, container_member(
		k, type, "shrink", .Shrink,
		[]Type_Id{type, TYPE_INT}, []Param_Mode{.Inout, .Value}, none, 1,
	))
	append(&members, container_member(
		k, type, "try_shrink", .Shrink,
		[]Type_Id{type, TYPE_INT}, []Param_Mode{.Inout, .Value}, fails, 1,
	))
	// A sort rearranges the whole container, so its receiver is `inout` like
	// `append`'s: every outstanding view of it ends at the call.
	append(&members, container_member(
		k, type, "sort", .Sort, []Type_Id{type}, []Param_Mode{.Inout}, none, 0,
	))
	append(&members, container_member(
		k, type, "reverse_sort", .Reverse_Sort, []Type_Id{type}, []Param_Mode{.Inout}, none, 0,
	))
	add_members(k.c, type, members[:])
}

// design.md "Sorting slices": the library procedures accept `[]mut T`, and
// passing a read-only `[]T` is a compile-time error. That rule is the member
// set — a read-only slice simply has no `sort` to call, so the rejection is the
// ordinary one for a member a type does not have.
//
// The receiver is a *value*: a slice is a borrow, so the header is copied while
// the elements it names are the caller's. Making it `inout` instead would force
// `slice.sort(inout s)` at every call and stop `core:slice`'s own free form —
// which holds its slice in an ordinary immutable parameter — from forwarding to
// it at all.
@(private = "file")
ensure_slice_members :: proc(k: ^Checker, type: Type_Id, info: ^Type_Info) {
	if !info.mutable {
		return
	}
	members := make([dynamic]Symbol_Id, 0, 2, k.c.semantic_allocator)
	append(&members, container_member(
		k, type, "sort", .Sort,
		[]Type_Id{type}, []Param_Mode{.Value}, INVALID_TYPE, 0, .Value,
	))
	append(&members, container_member(
		k, type, "reverse_sort", .Reverse_Sort,
		[]Type_Id{type}, []Param_Mode{.Value}, INVALID_TYPE, 0, .Value,
	))
	add_members(k.c, type, members[:])
}

// design.md "Map container operations": `len`, `cap`, `clear`, `reserve`,
// `shrink`, and the non-inserting `find`. Insertion is a *place* — `m[key] = v`
// and every field or index chain rooted in one — so the only call form of it is
// the recoverable `try_insert`.
@(private = "file")
ensure_map_members :: proc(k: ^Checker, type: Type_Id, info: ^Type_Info) {
	key, value := info.key, info.element
	// Both halves are cloned on insertion, so both copy entry points must exist.
	contribute_lifecycle_members(k, key)
	contribute_lifecycle_members(k, value)

	members := make([dynamic]Symbol_Id, 0, 8, k.c.semantic_allocator)
	none := INVALID_TYPE
	fails := result_type(k, unit_type(k.c), TYPE_ALLOCATOR_ERROR)

	// `find` returns `Option(^mut V)` over the existing value — it never inserts
	// (design.md). The receiver is `inout` because the returned pointer grants
	// mutation of the stored value. Typed fallibility changed only the result
	// representation; the borrow and invalidation rules did not.
	find := container_member(
		k, type, "find", .Map_Find,
		[]Type_Id{type, key}, []Param_Mode{.Inout, .Value},
		option_type(k, pointer_to(k.c, value, true)), 0,
	)
	set_synth_result_summary(k.c, find, 0)
	append(&members, find)
	// design.md "Maps": the owning read. Unlike `find` it hands back an
	// independently owned value rather than a pointer into the table, so its
	// receiver is immutable and an immutable parameter or a temporary map can be
	// read through it.
	lookup := container_member(
		k, type, "lookup_value", .Map_Lookup_Value,
		[]Type_Id{type, key}, []Param_Mode{.Value, .Value},
		option_type(k, value), 0, .Value,
	)
	// A synthesised member has no body, so without a written summary a carrier
	// payload falls through to `.Unknown` storage, losing the provenance the
	// map index it replaces already carried. The payload's provenance is
	// exactly the receiver's: an owned managed value depends on nothing, but a
	// `map[K]string_view` payload still borrows through the map.
	set_synth_result_summary(k.c, lookup, 0)
	append(&members, lookup)
	append(&members, container_member(
		k, type, "try_insert", .Map_Try_Insert,
		[]Type_Id{type, key, value}, []Param_Mode{.Inout, .Value, .Value}, fails, 0,
	))
	// design.md: removal moves the stored value to the result and answers
	// `.none` when the key was absent.
	map_remove := container_member(
		k, type, "remove", .Map_Remove,
		[]Type_Id{type, key}, []Param_Mode{.Inout, .Value}, option_type(k, value), 0,
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
	// design.md "Iteration adapters": three ordinary methods answering three
	// ordinary values. Their receiver is immutable — a view reads the table, and
	// a live one is what stops the map being mutated under it — and the result
	// borrows through it, which is what the summary records.
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

// How one element type answers `<`. Resolved once per element type during
// checking and read unchanged by the backend, exactly as a map key's
// `==`/`hash` pair is: one `[dynamic]T` must sort the same way in every package
// it travels through, so an extension block in a *caller* never enters the
// answer.
// `Unordered` is a *settled* answer, not a missing one: the element has no `<`,
// it has been reported once, and every later call on that type is answered from
// here rather than reported again.
Order_Policy_Kind :: enum { Unresolved, Builtin, Inherent, Unordered }

Order_Policy :: struct {
	kind: Order_Policy_Kind,
	less: Symbol_Id,
}

// Unlike a map key's policy this follows a *delegated* `operator(<)`: a
// delegation has no body of its own — it is unwrapped at each call site — so it
// is followed to whatever it forwards to, which is either the underlying type's
// own operator or the underlying built-in comparison. There is no second
// operation for it to stay coherent with, which is why a map key's policy stops
// at a delegation and this one does not.
@(private = "file")
resolve_element_order_policy :: proc(c: ^Compiler, element: Type_Id) -> (Order_Policy, string) {
	if element == INVALID_TYPE {
		return Order_Policy{}, "is not a type"
	}
	found := inherent_less_operator(c, element)
	// A chain of `distinct` types each delegating to the next ends either at a
	// written operator or at the built-in one; the bound is the chain length.
	for depth := 0; found != INVALID_SYMBOL && depth < 64; depth += 1 {
		sym := symbol_of(c, found)
		if sym == nil {
			break
		}
		if !sym.delegated {
			return Order_Policy{kind = .Inherent, less = found}, ""
		}
		if sym.delegate_target == INVALID_SYMBOL {
			// Delegating to the built-in comparison on the shared representation.
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
		if sym := symbol_of(c, member); sym != nil && sym.operator == "<" {
			return member
		}
	}
	return INVALID_SYMBOL
}

// A missing choice is a broken phase contract, never permission to repeat
// member lookup in the backend.
resolved_element_order_policy :: proc(c: ^Compiler, element: Type_Id) -> Order_Policy {
	return c.order_policies[element]
}

// The gate on `sort` and `reverse_sort`. It names the container and its element
// once, rather than letting a monomorphised comparison fail somewhere inside a
// sort the caller never wrote.
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
	k.c.order_policies[element] = Order_Policy{kind = .Unordered}
	errorf(
		k.c, span, "L0651",
		"`%s` cannot be sorted: its element `%s` %s",
		type_name(k.c, receiver), type_name(k.c, element), reason,
	)
	return false
}

// Any type can be a map key if it satisfies `interfaces.Hashable` with a
// coherent `==` and `value.hash(seed: uint) -> uint` (design.md "Maps"), and
// a user key's pair must be inherent. Checked where the map type is named
// rather than at each operation, so one map reports once.
require_map_key_policy :: proc(k: ^Checker, type: Type_Id, span: Span) -> bool {
	key := container_key(k.c, type)
	if key == INVALID_TYPE {
		return true
	}
	if resolved_map_key_policy(k.c, key).kind != .Unresolved { return true }
	policy, reason := resolve_map_key_policy(k.c, key)
	if reason == "" {
		// Selecting semantic IDs is safe even for a hypothetical signature. It
		// does not commit bodies, typeids, materializations, or witness globals.
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

// A map named through a field, pointer, container element or signature needs
// the same settled key policy as a directly declared map. Walk after signature
// resolution (from gate_type), when inherent key operations are available.
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
	// design.md "Receiver forms": a synthesized immutable receiver is the same
	// borrow a written `self` is, so it carries the same mode — otherwise a
	// built-in container's `iter` would not compare equal to a user type's.
	// Callers still spell it `.Value`, which is the shape of the parameter; this
	// is the one place that becomes the receiver mode.
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
	// Synthesized members participate in ordinary named-argument binding too.
	#partial switch op {
	case .Map_Find, .Map_Lookup_Value, .Map_Try_Insert, .Map_Remove:
		key_symbol := new_symbol(k.c, Symbol{
			name = intern_identifier(k.c, "key"), kind = .Parameter,
			type = params[1], mode = modes[1],
		})
		symbol_of(k.c, id).param_symbols[1] = key_symbol
	}
	return id
}

// The constant `0` a defaulted `shrink` floor uses. One shared node, exactly as
// a written default argument is shared by every call site that omits it.
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

// design.md "Allocators": a declaration may select the provider its value is
// built with by writing `T via expression`, separating two facts: the
// *policy* belongs to the declaration and survives drop and move, while the
// *handle* belongs to the current live value and travels with it.
//
// So `via` is recorded on the symbol and selects for a later revival, an
// implicit copy into this destination, and a container literal constructed
// here — but not for a destination that is already live, since design.md says
// a live destination keeps the allocator its value was built with.
//
// `via` is allowed on lexical allocator-binding owners whose canonical clone
// accepts a destination allocator, and rejected on everything with no
// destination allocation to select.
check_via_policy :: proc(k: ^Checker, d: ^Decl, declared: Type_Id) -> bool {
	if d.via == nil {
		return true
	}
	// Rejected *before* the expression is checked: a runtime allocator call is
	// not a constant initialiser, so a static-duration declaration could not run
	// it at all. Such a container begins in the constant, allocator-unbound
	// zero state (design.md).
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
	// design.md "Shared ownership": "The control block stores the allocator, so a
	// `shared(T)` declaration cannot use `via`". The generic rejection below
	// would say the type has no destination allocation to select, which is the
	// opposite of the truth — it has one, chosen where the value was made.
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
	// The clone entry point a copy into this destination calls has to exist by
	// emission, exactly as it does for an ordinary implicit copy.
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

// Allocator binding: "A container literal initializing or replacing a known
// destination constructs directly with that destination's selected allocator
// rather than allocating a default-backed temporary first." So a literal
// whose destination has a written policy carries that policy, and
// the backend writes it into the header before the first reservation.
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

// The provider a construction into this destination selects: the declaration's
// written `via`, or nil for the lazy default binding. Kept as one lookup so the
// checker and the backend cannot develop separate ideas of which handle a
// destination uses.
symbol_via_allocator :: proc(c: ^Compiler, symbol_id: Symbol_Id) -> Expr {
	sym := symbol_of(c, symbol_id)
	return sym == nil ? nil : sym.via
}

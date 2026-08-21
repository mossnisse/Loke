// The two managed containers: `[dynamic]T` and `map[K]V` (m6b-plan step 1).
//
// design.md "Dynamic arrays" and "Maps". Both are owning values with deep copy
// semantics, and m6b-plan freezes both as four words:
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
	info := type_of(c, type_underlying(c, id))
	return info != nil && info.kind == .Dynamic_Array
}

type_is_map :: proc(c: ^Compiler, id: Type_Id) -> bool {
	info := type_of(c, type_underlying(c, id))
	return info != nil && info.kind == .Map
}

// Either managed container. Both share one header shape, one operation-table
// shape, and one allocator-binding policy, so most callers want this rather
// than one of the two above.
type_is_container :: proc(c: ^Compiler, id: Type_Id) -> bool {
	info := type_of(c, type_underlying(c, id))
	if info == nil {
		return false
	}
	return info.kind == .Dynamic_Array || info.kind == .Map
}

// The element (`[dynamic]T`'s `T`, `map[K]V`'s `V`), or INVALID_TYPE.
container_element :: proc(c: ^Compiler, id: Type_Id) -> Type_Id {
	info := type_of(c, type_underlying(c, id))
	if info == nil || (info.kind != .Dynamic_Array && info.kind != .Map) {
		return INVALID_TYPE
	}
	return info.element
}

// A map's key type, or INVALID_TYPE for anything else.
container_key :: proc(c: ^Compiler, id: Type_Id) -> Type_Id {
	info := type_of(c, type_underlying(c, id))
	if info == nil || info.kind != .Map {
		return INVALID_TYPE
	}
	return info.key
}

// ------------------------------------------------------ contributed members --

// Which operation one contributed member is, so the backend writes the right
// body without matching on its name.
Container_Op :: enum {
	None,
	Append,
	Try_Append,
	Insert,
	Try_Insert,
	Pop,
	Remove,
	Remove_Unordered,
	Clear,
	Resize,
	Try_Resize,
	Reserve,
	Try_Reserve,
	Shrink,
	Try_Shrink,
	// The map half. `find` never inserts; `m[key] = v` and every chain rooted in
	// one are places rather than calls, so they are not members.
	Map_Find,
	Map_Try_Insert,
	Map_Remove,
	Map_Clear,
	Map_Reserve,
	Map_Try_Reserve,
	Map_Shrink,
	Map_Try_Shrink,
}

// design.md "Dynamic arrays": the operation set, contributed as real members so
// `xs.append(1)` is an ordinary method call. That is not cosmetic — it is what
// makes the same operations reachable from generic code constrained by the
// standard catalogue, and it reuses overload ranking, `..T` packing, default
// arguments, and the `inout`-receiver place rule instead of growing a second
// call path beside them (m6b-plan step 2).
//
// The `..T` pack a variadic receives *is* a read-only slice, so `append` clones
// each element into the container through its selected allocator. A move-only
// element therefore cannot travel through the variadic form; `insert` takes one
// value and has the same rule for the same reason.
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
	if info.kind != .Dynamic_Array {
		return
	}
	info.contributed += {.Container}
	element := info.element
	// Insertion clones, so the element's own copy entry point has to exist.
	contribute_lifecycle_members(k, element)

	members := make([dynamic]Symbol_Id, 0, 16, k.c.semantic_allocator)
	none := []Type_Id{}
	fails := []Type_Id{TYPE_ALLOCATOR_ERROR}

	pack := slice_of(k.c, element, mutable = false)
	append(&members, container_member(
		k, type, "append", .Append,
		[]Type_Id{type, pack}, []Param_Mode{.Inout, .Variadic}, none, 0,
	))
	append(&members, container_member(
		k, type, "try_append", .Try_Append,
		[]Type_Id{type, pack}, []Param_Mode{.Inout, .Variadic}, fails, 0,
	))
	append(&members, container_member(
		k, type, "insert", .Insert,
		[]Type_Id{type, TYPE_INT, element}, []Param_Mode{.Inout, .Value, .Value}, none, 0,
	))
	append(&members, container_member(
		k, type, "try_insert", .Try_Insert,
		[]Type_Id{type, TYPE_INT, element}, []Param_Mode{.Inout, .Value, .Value}, fails, 0,
	))
	// design.md optional-ok: an empty container yields the zero value and false.
	append(&members, container_member(
		k, type, "pop", .Pop,
		[]Type_Id{type}, []Param_Mode{.Inout}, []Type_Id{element, TYPE_BOOL}, 0,
	))
	append(&members, container_member(
		k, type, "remove", .Remove,
		[]Type_Id{type, TYPE_INT}, []Param_Mode{.Inout, .Value}, []Type_Id{element}, 0,
	))
	append(&members, container_member(
		k, type, "remove_unordered", .Remove_Unordered,
		[]Type_Id{type, TYPE_INT}, []Param_Mode{.Inout, .Value}, []Type_Id{element}, 0,
	))
	append(&members, container_member(
		k, type, "clear", .Clear, []Type_Id{type}, []Param_Mode{.Inout}, none, 0,
	))
	append(&members, container_member(
		k, type, "resize", .Resize,
		[]Type_Id{type, TYPE_INT}, []Param_Mode{.Inout, .Value}, none, 0,
	))
	append(&members, container_member(
		k, type, "try_resize", .Try_Resize,
		[]Type_Id{type, TYPE_INT}, []Param_Mode{.Inout, .Value}, fails, 0,
	))
	append(&members, container_member(
		k, type, "reserve", .Reserve,
		[]Type_Id{type, TYPE_INT}, []Param_Mode{.Inout, .Value}, none, 0,
	))
	append(&members, container_member(
		k, type, "try_reserve", .Try_Reserve,
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
		k, type, "try_shrink", .Try_Shrink,
		[]Type_Id{type, TYPE_INT}, []Param_Mode{.Inout, .Value}, fails, 1,
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
	none := []Type_Id{}
	fails := []Type_Id{TYPE_ALLOCATOR_ERROR}

	// design.md: `find` "returns a pointer to the existing value and `true`, or
	// `nil` and `false`. It does not insert." The receiver is `inout` because the
	// pointer it hands back grants mutation of the stored value.
	append(&members, container_member(
		k, type, "find", .Map_Find,
		[]Type_Id{type, key}, []Param_Mode{.Inout, .Value},
		[]Type_Id{pointer_to(k.c, value), TYPE_BOOL}, 0,
	))
	append(&members, container_member(
		k, type, "try_insert", .Map_Try_Insert,
		[]Type_Id{type, key, value}, []Param_Mode{.Inout, .Value, .Value}, fails, 0,
	))
	// design.md: removal moves the stored value to the result and answers
	// zero/false when the key was absent.
	append(&members, container_member(
		k, type, "remove", .Map_Remove,
		[]Type_Id{type, key}, []Param_Mode{.Inout, .Value}, []Type_Id{value, TYPE_BOOL}, 0,
	))
	append(&members, container_member(
		k, type, "clear", .Map_Clear, []Type_Id{type}, []Param_Mode{.Inout}, none, 0,
	))
	append(&members, container_member(
		k, type, "reserve", .Map_Reserve,
		[]Type_Id{type, TYPE_INT}, []Param_Mode{.Inout, .Value}, none, 0,
	))
	append(&members, container_member(
		k, type, "try_reserve", .Map_Try_Reserve,
		[]Type_Id{type, TYPE_INT}, []Param_Mode{.Inout, .Value}, fails, 0,
	))
	append(&members, container_member(
		k, type, "shrink", .Map_Shrink,
		[]Type_Id{type, TYPE_INT}, []Param_Mode{.Inout, .Value}, none, 1,
	))
	append(&members, container_member(
		k, type, "try_shrink", .Map_Try_Shrink,
		[]Type_Id{type, TYPE_INT}, []Param_Mode{.Inout, .Value}, fails, 1,
	))
	add_members(k.c, type, members[:])
}

// design.md "Maps": "Any type can be a map key when it satisfies the operations
// of `interfaces.Hashable`, with a **coherent** `==` and `hash(value, seed:
// uint) -> uint`", and a user key's pair must be inherent. Checked where the map
// type is named rather than at each operation, so one map reports once.
require_map_key_policy :: proc(k: ^Checker, type: Type_Id, span: Span) -> bool {
	key := container_key(k.c, type)
	if key == INVALID_TYPE {
		return true
	}
	policy := map_key_policy(k, key)
	if policy.reason == "" {
		return true
	}
	errorf(
		k.c, span, "L0586",
		"`%s` cannot be a map key: it %s",
		type_name(k.c, key), policy.reason,
	)
	add_notef(
		k.c, no_span(),
		"an `extend` block does not qualify; wrap the key in a local `distinct` type with its own inherent operations",
	)
	return false
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
	results: []Type_Id,
	defaulted: int,
) -> Symbol_Id {
	id := synth_proc(k.c, name, .Container_Op, owner, params, modes, results)
	if sym := symbol_of(k.c, id); sym != nil {
		sym.has_receiver = true
		sym.receiver = .Inout
		sym.container_op = op
		if defaulted > 0 {
			sym.param_defaults[defaulted] = zero_int_arg(k.c)
		}
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
// built with by writing `T via expression`. m6b-plan decision "Allocator
// binding" separates the two facts this creates: the *policy* belongs to the
// declaration and survives drop and move, while the *handle* belongs to the
// current live value and travels with it.
//
// So `via` is recorded on the symbol and is what a later revival, an implicit
// copy into this destination, and a container literal constructed here all
// select. It is not consulted for a destination that is already live: design.md
// says a live destination keeps the allocator its value was built with.
//
// m6b-plan decision "`via` applicability": allowed on lexical allocator-binding
// owners whose canonical clone accepts a destination allocator, and rejected on
// everything with no destination allocation to select.
check_via_policy :: proc(k: ^Checker, d: ^Decl, declared: Type_Id) -> bool {
	if d.via == nil {
		return true
	}
	// Rejected *before* the expression is checked: a runtime allocator call is
	// not a constant initialiser, so a static-duration declaration could not run
	// it at all. design.md: such a container "begins in the constant
	// allocator-unbound zero state".
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

// m6b-plan decision "`via` applicability". A trivial or borrowed value owns no
// allocation; a move-only value has no clone to pass an allocator to; an
// immutable `string` shares storage through a retain rather than allocating into
// a destination.
type_accepts_via :: proc(c: ^Compiler, type: Type_Id) -> bool {
	if type == INVALID_TYPE || !type_is_managed(c, type) {
		return false
	}
	if type_clone_disabled(c, type) {
		return false
	}
	info := type_of(c, type_underlying(c, type))
	if info == nil {
		return false
	}
	#partial switch info.kind {
	case .String:
		return false
	}
	return true
}

// m6b-plan decision "Allocator binding": "A container literal initializing or
// replacing a known destination constructs directly with that destination's
// selected allocator rather than allocating a default-backed temporary first."
// So a literal whose destination has a written policy carries that policy, and
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

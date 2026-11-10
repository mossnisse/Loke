// Indexing and slicing: built-in carriers, maps, user `operator([])` and
// `operator([:])` overloads, and the packed fields a place reaches. Other
// expressions are in `check_expr.odin`.
package lokec

// ---------------------------------------------------------------- indexing --

check_index :: proc(k: ^Checker, v: ^Expr_Index, position: Expr_Position) {
	reach := operand_position(position)
	place, inserts := reach != .Value, position == .Insert
	// In `outer[key][i] = v` only the last index may insert; `outer[key]` must
	// already exist (design.md "Maps").
	operand := check_single_expr(k, v.operand, position = reach)
	if operand == INVALID_TYPE {
		return
	}

	// design.md "Owned values": `b[i]` indexes the payload.
	if boxed := underlying_info(k.c, operand); boxed != nil && boxed.kind == .Box {
		v.operand = implicit_box_deref(k, v.operand, boxed.element)
		operand = boxed.element
	}

	// Nominal (design.md "Distinct types"): a distinct type reaches
	// check_user_index, not the built-in table.
	base_type := operand
	operand_base := expr_base(v.operand)
	through_pointer := false
	pointer_mutable := false
	pointee := INVALID_TYPE
	if info := type_of(k.c, base_type); info != nil && info.kind == .Pointer {
		pointee = info.element
		base_type = info.element
		through_pointer = true
		pointer_mutable = info.mutable
	}
	info := type_of(k.c, base_type)
	single := len(v.indices) == 1
	// A carrier is reached through its header, so the hop is written as p^.
	if through_pointer && info != nil &&
	   (info.kind == .Slice || info.kind == .Dynamic_Array || info.kind == .Map || info.kind == .C_Pointer) {
		v.operand = implicit_pointer_deref(k, v.operand, pointee, pointer_mutable)
		operand_base = expr_base(v.operand)
		through_pointer = false
	}
	// A UTF-8 code point may span several bytes (design.md "string type").
	if info != nil && (info.kind == .String || info.kind == .String_View) {
		errorf(
			k.c, v.span, "L0563",
			"`%s` cannot be indexed by an integer, because a UTF-8 code point may span several bytes",
			type_name(k.c, operand),
		)
		add_notef(k.c, v.span, "use `text.bytes()[index]`, a subrange `text[low:high]`, or rune iteration")
		return
	}
	if info != nil && single {
		#partial switch info.kind {
		case .C_Pointer:
			// Unchecked, and writable exactly as `p^` is (design.md "C pointers").
			if !check_integer_index(k, v.indices[0]) { return }
			if !require_unsafe_import(k, v.span, "indexing a C pointer") {
				return
			}
			v.type = info.element
			v.value_category = .Place
			v.addressable = true
			v.assignable = true
			v.immutable = .None
			return
		case .Slice:
			// The element lives in the slice's root, so `[]mut T` decides the write,
			// not whether the slice variable itself is assignable.
			if !check_integer_index(k, v.indices[0]) { return }
			v.type = info.element
			v.value_category = .Place
			v.addressable = true
			v.assignable = info.mutable
			v.immutable = info.mutable ? .None : .Through_Slice
			return
		case .Dynamic_Array:
			// The element lives in the container's allocation, so it has the
			// container's capability (design.md "Dynamic arrays").
			if !check_integer_index(k, v.indices[0]) { return }
			owned_element_place(&v.base, info.element, operand_base)
			return
		case .Map:
			check_map_index(k, v, info, place, inserts, operand_base)
			return
		case .Simd:
			// A lane index must be a constant (design.md "SIMD vectors").
			check_simd_index(k, v, info, base_type, operand_base, through_pointer, pointer_mutable)
			return
		}
	}
	// Built-in indexing first; a user `operator([])` supplies what it does not.
	indexable := info != nil && (info.kind == .Array || info.kind == .Slice)
	if !indexable || !single {
		if check_user_index(k, v, operand, position) {
			return
		}
		if indexable {
			// Permanently reserved for a user `operator([])` (design.md "Indexing
			// and slicing").
			errorf(
				k.c, v.span, "L0362",
				"`%s` takes one index; `a[i, j]` is reserved for a user `operator([])` taking that many",
				type_name(k.c, operand),
			)
		} else {
			errorf(k.c, v.span, "L0362", "`%s` cannot be indexed", type_name(k.c, operand))
		}
		return
	}

	check_array_index(k, v, info, base_type, operand_base, through_pointer, pointer_mutable)
}

// Whether `check_index` answers `operand[...]` itself. Built-in indexing takes
// one index and cannot be shadowed; a distinct type is nominal, so it never does.
index_is_builtin :: proc(c: ^Compiler, operand: Type_Id, indices: int) -> bool {
	info := type_of(c, operand)
	if info != nil && (info.kind == .Box || info.kind == .Pointer) {
		info = type_of(c, info.element)
	}
	if info == nil {
		return false
	}
	#partial switch info.kind {
	case .String, .String_View:
		return true
	case .C_Pointer, .Slice, .Dynamic_Array, .Map, .Simd, .Array:
		return indices == 1
	}
	return false
}

// `a[i]` for a fixed array.
@(private = "file")
check_array_index :: proc(
	k: ^Checker, v: ^Expr_Index, info: ^Type_Info, array: Type_Id, operand: ^Expr_Base,
	through_pointer, pointer_mutable: bool,
) {
	if !check_integer_index(k, v.indices[0]) {
		return
	}
	v.type = info.element
	v.value_category = .Place
	inherit_capability(&v.base, operand, through_pointer, pointer_mutable)

	index := expr_base(v.indices[0])
	// A constant indexed at runtime needs read-only storage (design.md
	// "Materialization"); a constant index folds below instead.
	if base_is_const(operand) && !base_is_const(index) && request_materialization(k, v.operand) {
		v.addressable = false
		v.assignable = false
		v.immutable = .Read_Only
	}
	if index.const_value.kind != .Integer && index.const_value.kind != .Rune {
		return
	}
	value, ok := bi_to_i64(k.c, index.const_value.integer)
	if !ok || value < 0 || u64(value) >= info.count {
		errorf(
			k.c, expr_span(v.indices[0]), "L0361", "index %s is out of range for `%s`",
			bi_text(k.c, index.const_value.integer), type_name(k.c, array),
		)
		v.type = INVALID_TYPE
		return
	}
	fold_constant_element(v, operand, value)
}

// A constant array's or vector's element, at an index already in range, is a
// constant.
fold_constant_element :: proc(v: ^Expr_Index, operand: ^Expr_Base, index: i64) {
	if operand.const_value.kind == .Aggregate {
		v.const_value = operand.const_value.aggregate.elements[index]
		v.immutable = .Constant
	}
}

// An index into a built-in sequence: an integer, `int` when unfixed.
check_integer_index :: proc(k: ^Checker, e: Expr) -> bool {
	type := check_single_expr(k, e, TYPE_INT)
	if type == INVALID_TYPE || !materialize(k, e, TYPE_INT) {
		return false
	}
	// design.md "Fixed arrays": an index has an integer or rune type.
	if index_type := expr_base(e).type; !type_is_integer(k.c, index_type) && !type_is_rune(k.c, index_type) {
		errorf(k.c, expr_span(e), "L0362", "an index must be an integer or rune, found `%s`", type_name(k.c, type))
		return false
	}
	return true
}

// `ok := key in m` (design.md "Maps") and `ok := x in low ..< high`
// (design.md "Ranges").
check_in :: proc(k: ^Checker, v: ^Expr_Binary) {
	// A written range takes its endpoint type from a typed element, so
	// `ch in 'a' ..= 'z'` tests a `u8` against a `Range(u8)`.
	if written, is_range := v.rhs.(^Expr_Range); is_range {
		element := check_single_expr(k, v.lhs)
		if element == INVALID_TYPE {
			return
		}
		hint := INVALID_TYPE
		if !type_is_untyped(k.c, element) && (type_is_integer(k.c, element) || type_is_rune(k.c, element)) {
			hint = range_type(k.c, element)
		}
		if check_single_expr(k, written, hint) == INVALID_TYPE {
			return
		}
		check_range_membership(k, v, written.type)
		return
	}
	container := check_single_expr(k, v.rhs)
	if container == INVALID_TYPE {
		return
	}
	if info := type_of(k.c, container); info != nil && info.is_range {
		if check_single_expr(k, v.lhs, info.element) == INVALID_TYPE {
			return
		}
		check_range_membership(k, v, container)
		return
	}
	if !type_is_map(k.c, container) {
		element := check_single_expr(k, v.lhs)
		if element == INVALID_TYPE {
			return
		}
		if check_user_binary(k, v, element, container) {
			return
		}
		errorf(
			k.c, v.op_span, "L0587",
			"`in` tests a `map[K]V` for a key or a `Range(T)` for a value, found `%s`", type_name(k.c, container),
		)
		return
	}
	if !check_map_key(k, v.lhs, container_key(k.c, container), true) {
		return
	}
	v.type = TYPE_BOOL
}

// design.md "Ranges": `x in r` holds when `r.low <= x` and `x` is below
// `r.high`, or at it for a closed range. The element is already checked.
@(private = "file")
check_range_membership :: proc(k: ^Checker, v: ^Expr_Binary, range: Type_Id) {
	element := type_of(k.c, range).element
	if !materialize_value_expr(k, v.lhs, element, "test a range of") {
		return
	}
	v.type = TYPE_BOOL
}

// design.md "Maps": a key that is only compared may be a `string_view` for a
// `map[string]V`; one that is stored must be the owned `string`.
@(private = "file")
check_map_key :: proc(k: ^Checker, e: Expr, key: Type_Id, borrows: bool) -> bool {
	type := check_single_expr(k, e, key)
	if type == INVALID_TYPE || key == INVALID_TYPE {
		return false
	}
	if key == TYPE_STRING && type == TYPE_STRING_VIEW {
		if borrows {
			return true
		}
		errorf(k.c, expr_span(e), "L0310", "an inserted key must be an owned `string`, found `string_view`")
		add_notef(k.c, NO_SPAN, "`.copy()` makes a `string` from a `string_view`")
		return false
	}
	return materialize_value_expr(k, e, key, "look up")
}

// design.md "Maps": only `m[key] = elem` creates an entry. Every other position
// names part of an element that must already be there, and panics for a missing
// key. Insertion may reallocate, so it is a mutable borrow of `m` for the
// statement, which `src/cfg.odin` records.
@(private = "file")
check_map_index :: proc(
	k: ^Checker, v: ^Expr_Index, info: ^Type_Info, place, inserts: bool, operand: ^Expr_Base,
) {
	if !check_map_key(k, v.indices[0], info.key, !inserts) {
		return
	}
	v.map_inserts = inserts
	v.type = info.element
	contribute_lifecycle_members(k, info.key)
	contribute_lifecycle_members(k, info.element)
	if !place {
		// `m.lookup_value(key)` and `m.find(key)` are the forms that do not panic.
		return
	}
	owned_element_place(&v.base, info.element, operand)
	if inserts && !v.assignable {
		report_not_assignable(k, &v.base, "an inserting map index")
		v.type = INVALID_TYPE
	}
}

// design.md "Indexing and slicing": a place position requires the `inout`
// overload; any other position prefers the value one.
@(private = "file")
check_user_index :: proc(k: ^Checker, v: ^Expr_Index, operand: Type_Id, position: Expr_Position) -> bool {
	all := operator_candidates_for_receiver(k, "[]", operand)
	if len(all) == 0 {
		return false
	}
	candidates := select_by_place(k, all, operand_position(position) != .Value)
	if len(candidates) == 0 && position == .Sliced_Mutably {
		candidates = all
	}
	if len(candidates) == 0 {
		errorf(
			k.c,
			v.span,
			"L0419",
			"`%s` has no `operator([])` returning `inout`, so this is not a place",
			type_name(k.c, operand),
		)
		return true
	}

	args, ok := index_arguments(k, v.operand, v.indices, candidates)
	if !ok {
		return true
	}
	chosen, bound := resolve_operator(k, v.span, "[]", candidates, args)
	if chosen == INVALID_SYMBOL {
		return true
	}
	v.bound = bound
	annotate_user_operator(k, &v.base, chosen)
	if operator_result_is_place(k, chosen) {
		v.value_category = .Place
		v.addressable = true
		v.assignable = true
		v.immutable = .None
	}
	return true
}

// `x[lo:hi]`: built in for a carrier, `operator([:])` for anything else.
check_slice :: proc(k: ^Checker, v: ^Expr_Slice, expected: Type_Id) {
	operand := check_single_expr(k, v.operand, position = v.mutable ? .Sliced_Mutably : .Value)
	if operand == INVALID_TYPE {
		return
	}
	if check_builtin_slice(k, v, operand) {
		return
	}
	all := operator_candidates_for_receiver(k, "[:]", operand)
	if len(all) == 0 {
		errorf(
			k.c, v.span, "L0362",
			"`%s` cannot be sliced; a user type needs an `operator([:])` overload",
			type_name(k.c, operand),
		)
		return
	}
	slicers := select_slicers(k, all, v.mutable)
	if len(slicers) == 0 {
		if v.mutable {
			errorf(
				k.c, v.span, "L0419",
				"`%s` has no `operator([:])` yielding a `[]mut T`, so it cannot be sliced mutably",
				type_name(k.c, operand),
			)
		} else {
			errorf(
				k.c, v.span, "L0419",
				"`%s` has only a mutable `operator([:])`; slice it with `&mut`, as in `&mut x[a:b]`",
				type_name(k.c, operand),
			)
		}
		return
	}
	// design.md "Indexing and slicing": an omitted endpoint means what it means
	// for built-in slicing, 0 and `x.len()`. The length is read from a second copy
	// of the operand, so only an operand whose evaluation has no effect qualifies.
	if v.lo == nil {
		zero := new(Expr_Literal, k.c.semantic_allocator)
		zero.span = v.span
		zero.kind = .Int
		zero.text = "0"
		v.lo = zero
	}
	length_omitted := false
	if v.hi == nil {
		if !is_effect_free_place(v.operand) {
			errorf(
				k.c, v.span, "L0421",
				"an omitted high endpoint is the operand's `len()`, so the operand must be a variable, field, or dereference; write the endpoint",
			)
			return
		}
		v.hi = synth_call(k.c, synth_selector(k.c, clone_expr(k.c, v.operand), "len", v.span), nil, v.span)
		length_omitted = true
	}
	endpoints := make([]Expr, 2, k.c.semantic_allocator)
	endpoints[0], endpoints[1] = v.lo, v.hi
	args, ok := index_arguments(k, v.operand, endpoints, slicers)
	if !ok {
		if length_omitted && expr_base(v.hi).type == INVALID_TYPE {
			add_notef(k.c, v.span, "an omitted high endpoint is the operand's `len()`")
		}
		return
	}
	chosen, bound := resolve_operator(k, v.span, "[:]", slicers, args)
	if chosen == INVALID_SYMBOL {
		return
	}
	v.bound = bound
	sym := annotate_user_operator(k, &v.base, chosen)
	// A `[]mut T` needs an exclusive receiver (design.md "Capabilities and the
	// one rule").
	if slice_is_mutable(k.c, v.type) && sym.receiver != .Inout {
		errorf(
			k.c,
			v.span,
			"L0547",
			"this `operator([:])` yields `%s`, which is an exclusive borrow, so its `self` parameter must be `inout`",
			type_name(k.c, v.type),
		)
		add_notef(k.c, sym.span, "declared here with a read-only receiver, which can only yield a read-only slice")
		v.type = INVALID_TYPE
	}
}

// design.md "Indexing and slicing": `&mut x[a:b]` selects the overload yielding
// `[]mut T`, and `x[a:b]` the one yielding anything else. The destination
// selects nothing.
@(private = "file")
select_slicers :: proc(k: ^Checker, all: []Symbol_Id, mutable: bool) -> []Symbol_Id {
	out := make([dynamic]Symbol_Id, 0, len(all), context.temp_allocator)
	for candidate in all {
		if sym := symbol_of(k.c, candidate); sym != nil && slice_is_mutable(k.c, sym.result) == mutable {
			append(&out, candidate)
		}
	}
	return out[:]
}

// A variable, a field path, or a dereference: evaluating one twice reads the same
// place and runs nothing.
is_effect_free_place :: proc(e: Expr) -> bool {
	#partial switch v in e {
	case ^Expr_Ident:
		return true
	case ^Expr_Selector:
		return is_effect_free_place(v.operand)
	case ^Expr_Postfix:
		return v.op == .Caret && is_effect_free_place(v.operand)
	}
	return false
}

// design.md "Slices". False for anything but a built-in carrier.
@(private = "file")
check_builtin_slice :: proc(k: ^Checker, v: ^Expr_Slice, operand: Type_Id) -> bool {
	// Nominal, like `check_index`: a `distinct []T` leaves this to the user
	// `operator([:])` its declaration has to bring over.
	info := type_of(k.c, operand)
	if info == nil {
		return false
	}
	#partial switch info.kind {
	case .Array, .Slice, .Dynamic_Array, .String, .String_View, .C_Pointer:
	case:
		return false
	}
	base := expr_base(v.operand)
	// A constant array slices its materialised storage, which is static and
	// read-only.
	materialized := info.kind == .Array && request_materialization(k, v.operand)
	lo := v.lo == nil || check_slice_endpoint(k, v.lo)
	hi := v.hi == nil || check_slice_endpoint(k, v.hi)
	ok := lo && hi
	// The slice keeps its root's address, which a temporary would not outlive.
	if info.kind == .Array && !materialized && !base.addressable {
		errorf(k.c, v.span, "L0477", "`%s` has no storage to slice; bind it to a variable first", type_name(k.c, operand))
		ok = false
	}
	// A slice's elements are ordinary, aligned places (design.md "@(packed)").
	if field, packed := packed_field_reached(k, v.operand); packed && info.kind == .Array {
		errorf(k.c, v.span, "L0614", "cannot slice `%s`: it is reached through a packed struct", field)
		ok = false
	}
	v.immutable = .Temporary
	if info.kind == .C_Pointer && !require_unsafe_import(k, v.span, "slicing a C pointer") {
		ok = false
	}
	if !ok {
		return true
	}
	// design.md "Slices": `a[lo:hi]` is read-only; `&mut a[lo:hi]` asks for the
	// mutable capability, which the operand must have.
	#partial switch info.kind {
	case .Array, .Dynamic_Array:
		if v.mutable && !base.assignable {
			report_not_assignable(k, base, "sliced mutably")
			return true
		}
		v.type = slice_of(k.c, info.element, v.mutable)
	case .Slice:
		if v.mutable && !info.mutable {
			errorf(
				k.c, v.span, "L0478",
				"`%s` is read-only, and a read-only slice never becomes mutable", type_name(k.c, operand),
			)
			return true
		}
		v.type = slice_of(k.c, info.element, v.mutable)
	case .String, .String_View:
		if v.mutable {
			errorf(k.c, v.span, "L0478", "a string is immutable and cannot be sliced mutably")
			return true
		}
		// The bounds are checked at run time against the length and the encoding.
		v.type = TYPE_STRING_VIEW
	case .C_Pointer:
		// Without a high bound there is no length, so the result stays a C
		// pointer (design.md "C pointers").
		v.type = v.hi == nil ? c_pointer_to(k.c, info.element) : slice_of(k.c, info.element, mutable = true)
	}
	return true
}

@(private = "file")
check_slice_endpoint :: proc(k: ^Checker, e: Expr) -> bool {
	type := check_single_expr(k, e, TYPE_INT)
	if type == INVALID_TYPE {
		return false
	}
	if type_is_untyped(k.c, type) {
		return materialize(k, e, TYPE_INT)
	}
	if !type_is_integer(k.c, type) {
		errorf(k.c, expr_span(e), "L0477", "a slice bound must be an integer, found `%s`", type_name(k.c, type))
		return false
	}
	return true
}

// The overloads a place or value position may use; a value position falls back
// to `inout` ones when there is nothing else.
@(private = "file")
select_by_place :: proc(k: ^Checker, all: []Symbol_Id, place: bool) -> []Symbol_Id {
	out := make([dynamic]Symbol_Id, 0, len(all), context.temp_allocator)
	for candidate in all {
		if operator_result_is_place(k, candidate) == place {
			append(&out, candidate)
		}
	}
	if len(out) == 0 && !place {
		return all
	}
	return out[:]
}

// The already-checked receiver, then every index, checked here once.
index_arguments :: proc(
	k: ^Checker,
	receiver: Expr,
	indices: []Expr,
	candidates: []Symbol_Id,
) -> ([]Arg_Info, bool) {
	args := make([]Arg_Info, len(indices) + 1, context.temp_allocator)
	args[0] = arg_from_expr(receiver)
	args[0].is_receiver = true
	ok := true
	for index, position in indices {
		expected := agreed_index_param(k, candidates, position, len(indices))
		if check_single_expr(k, index, expected) == INVALID_TYPE {
			ok = false
			continue
		}
		args[position + 1] = arg_from_expr(index)
	}
	return args, ok
}

// The expected type for an index, so `counts[.North]` resolves: the parameter
// type every candidate agrees on, or INVALID_TYPE.
@(private = "file")
agreed_index_param :: proc(k: ^Checker, candidates: []Symbol_Id, position: int, arity: int) -> Type_Id {
	agreed := INVALID_TYPE
	for id in candidates {
		sym := symbol_of(k.c, id)
		if sym == nil || len(sym.params) != arity + 1 {
			continue
		}
		if agreed == INVALID_TYPE {
			agreed = sym.params[position + 1]
		} else if agreed != sym.params[position + 1] {
			return INVALID_TYPE
		}
	}
	return agreed
}

// ---------------------------------------------------------- packed fields --

// design.md "@(packed)": the name of a field that may be misaligned because
// it, or a field holding it in the same storage, sits in a packed struct.
@(private)
packed_field_reached :: proc(k: ^Checker, operand: Expr) -> (string, bool) {
	cur := operand
	for {
		name: string
		next: Expr
		#partial switch v in cur {
		case ^Expr_Ident:
			// A case binding over a packed field names that field.
			if sym := symbol_of(k.c, v.symbol); sym != nil && sym.packed_field != "" {
				return sym.packed_field, true
			}
			return "", false
		case ^Expr_Selector:
			name, next = v.name.text, v.operand
		case ^Expr_Index:
			// An embedded array's element shares the array's storage; any other
			// indexed container is separate storage.
			if underlying_kind(k.c, expr_base(v.operand).type) != .Array {
				return "", false
			}
			cur = v.operand
			continue
		case ^Expr_Call:
			// `field.get(value)` selects from what `value` points at.
			reflect, is_reflect := v.operation.(Call_Reflect)
			sym := symbol_of(k.c, reflect.field)
			if !is_reflect || reflect.op != .Field_Get || sym == nil || len(v.bound) != 1 {
				return "", false
			}
			name, next = identifier_text(k.c, sym.name), v.bound[0]
		}
		if next == nil {
			return "", false
		}
		struct_type := type_underlying(k.c, expr_base(next).type)
		through_pointer := false
		if info := type_of(k.c, struct_type); info != nil && info.kind == .Pointer {
			struct_type = type_underlying(k.c, info.element)
			through_pointer = true
		}
		if info := type_of(k.c, struct_type); info != nil && info.kind == .Struct && info.packed {
			return name, true
		}
		// A pointer's target is separate storage, aligned for its own type.
		if through_pointer {
			return "", false
		}
		cur = next
	}
}

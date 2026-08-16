// The compiler-contributed `hash` operation (m4b-plan step 2).
//
// design.md's standard catalogue promises that booleans, integers, floats,
// runes, pointers, enums, `typeid`, and recursively hashable fixed arrays
// satisfy `Hashable`. `Hashable` is ordinary Loke source with an ordinary
// `hash(value, seed) -> uint` requirement, so the compiler has to supply an
// operation for those types rather than special-casing the interface.
//
// The mix is 64-bit FNV-1a's step, applied once per scalar and folded over an
// aggregate's elements. It is not a cryptographic hash and makes no stability
// promise across compiler versions; what it must do is agree between the
// compile-time and runtime paths, which is why both spell the same two steps.
//
// ponytail: one non-seeded mixing constant, no per-process seed. A hash-flooding
// defence belongs with the map implementation (M6b), which is what would
// choose and thread a per-table seed.
package lokec

// The 64-bit FNV prime.
HASH_MULTIPLIER :: u64(1099511628211)

// design.md: `bool`, integers, floats, runes, pointers including `rawptr` and
// multi-pointers, enums, `typeid`, and recursively hashable fixed arrays.
type_is_hashable :: proc(c: ^Compiler, id: Type_Id) -> bool {
	under := type_underlying(c, id)
	info := type_of(c, under)
	if info == nil {
		return false
	}
	#partial switch info.kind {
	case .Bool, .Int, .Float, .Rune, .Enum, .Typeid,
	     .Raw_Pointer, .Pointer, .Multi_Pointer, .Proc,
	     .Untyped_Int, .Untyped_Float, .Untyped_Bool, .Untyped_Rune:
		return true
	case .Array:
		return type_is_hashable(c, info.element)
	}
	return false
}

// ------------------------------------------------------------- checking --

check_hash_builtin :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident) {
	v.value_category = .Value
	if len(v.args) != 2 {
		errorf(k.c, v.span, "L0322", "`hash` takes 2 arguments, found %d", len(v.args))
		v.type = INVALID_TYPE
		return
	}
	bound := make([]Expr, 2, k.c.semantic_allocator)
	value_type := check_single_expr(k, v.args[0].value)
	if value_type == INVALID_TYPE {
		v.type = INVALID_TYPE
		return
	}
	// An untyped constant takes its default type before hashing, so `hash(1, s)`
	// and `hash(int(1), s)` agree.
	if type_is_untyped(k.c, value_type) {
		value_type = default_type(k.c, value_type)
		if !materialize(k, v.args[0].value, value_type) {
			v.type = INVALID_TYPE
			return
		}
	}
	if !type_is_hashable(k.c, value_type) {
		errorf(
			k.c,
			expr_span(v.args[0].value),
			"L0445",
			"`%s` has no compiler-supplied `hash`; a record or union needs its own coherent equality and hash pair",
			type_name(k.c, value_type),
		)
		v.type = INVALID_TYPE
		return
	}
	bound[0] = v.args[0].value
	bound[1] = v.args[1].value
	if !check_value_expr(k, v.args[1].value, TYPE_UINT, "pass") {
		v.type = INVALID_TYPE
		return
	}
	v.bound = bound
	v.type = TYPE_UINT
}

// --------------------------------------------------------- compile time --

// The integer image of one scalar, which is what the mix consumes. `+0` and `-0`
// hash identically because they compare equal.
hash_scalar_bits :: proc(c: ^Compiler, value: Const_Value, type: Type_Id) -> u64 {
	under := type_underlying(c, type)
	#partial switch type_kind(c, under) {
	case .Bool, .Untyped_Bool:
		return value.boolean ? 1 : 0
	case .Float, .Untyped_Float:
		if value.float == 0 {
			return 0
		}
		info := type_of(c, under)
		if info != nil && info.bits == 32 {
			// Constants live as f64 in the evaluator. Hash the representation of
			// the declared scalar type, which is what runtime lowering observes.
			return u64(transmute(u32)f32(value.float))
		}
		return transmute(u64)value.float
	case .Raw_Pointer, .Pointer, .Multi_Pointer, .Proc:
		return 0 // the only compile-time pointer constant is nil
	}
	wrapped := bi_wrap(c, value.integer, 64, false)
	bits, _ := bi_to_u64(c, wrapped)
	return bits
}

hash_const :: proc(c: ^Compiler, value: Const_Value, type: Type_Id, seed: u64) -> u64 {
	under := type_underlying(c, type)
	info := type_of(c, under)
	if info != nil && info.kind == .Array {
		result := seed
		for index in 0 ..< int(info.count) {
			element := Const_Value{}
			if value.aggregate != nil && index < len(value.aggregate.elements) {
				element = value.aggregate.elements[index]
			}
			result = hash_const(c, element, info.element, result)
		}
		return result
	}
	return (seed ~ hash_scalar_bits(c, value, type)) * HASH_MULTIPLIER
}

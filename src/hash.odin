// The compiler-contributed `hash` operation.
//
// design.md's standard catalogue promises that booleans, integers, floats,
// runes, pointers, enums, `typeid`, and recursively hashable fixed arrays
// satisfy `Hashable`. `Hashable` is ordinary Loke source with an ordinary
// `value.hash(seed) -> uint` requirement, so the compiler has to supply a
// receiver member for those types rather than special-casing the interface.
//
// The mix is 64-bit FNV-1a's step, applied once per scalar and folded over an
// aggregate's elements. It is not a cryptographic hash and makes no stability
// promise across compiler versions; what it must do is agree between the
// compile-time and runtime paths, which is why both spell the same two steps.
//
// ponytail: one non-seeded mixing constant. The per-table seed a map threads
// through `hash` is what varies the result between tables; a per-*process* seed,
// which is what a hash-flooding defence needs, is not derived here.
package lokec

import "core:mem"

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
	case .String, .String_View, .Untyped_String:
		// design.md's catalogue lists both text carriers. Their `==` is already
		// byte-wise, so a byte-wise hash is the coherent partner.
		return true
	case .Array:
		return type_is_hashable(c, info.element)
	}
	return false
}

// A map key needs a coherent `==` and `value.hash(seed: uint) -> uint`; for
// a user-defined key, both must be inherent implementations belonging to the
// key type, since a caller-local extension doesn't qualify even when an
// ordinary interface check in that extension's package would pass
// (design.md "Maps").
//
// So this asks only two questions: does the compiler supply the pair, or does
// the key type's *own* package declare both? An extension block never enters the
// answer, which is what makes one `map[K]V` use one policy in every package it
// travels through.
Key_Policy_Kind :: enum { Unresolved, Builtin, Inherent }

// A checked operation choice, shared by CTFE and every backend. This record
// contains semantic IDs only; no lookup or code generation happens when read.
Key_Policy :: struct {
	kind:      Key_Policy_Kind,
	hash:      Symbol_Id,
	equal:     Symbol_Id,
}

// Checking is the only phase allowed to select a policy. Failed lookups are not
// cached: discovery may still be installing inherent members.
resolve_map_key_policy :: proc(c: ^Compiler, key: Type_Id) -> (Key_Policy, string) {
	if key == INVALID_TYPE {
		return Key_Policy{}, "is not a type"
	}
	hash := inherent_member_named(c, key, "hash")
	equal := inherent_operator_named(c, key, "==")
	// design.md "Maps": "A different policy wraps the key in a local `distinct`
	// type with its own inherent operations." A key that declares either half of
	// the pair means that policy, so the built-in catalogue answers only for a key
	// that declares neither. Asking the catalogue first resolves a `distinct`
	// scalar through to its underlying type and pairs that type's hash with the
	// key's own `==`, which is the incoherence this check exists to prevent.
	if hash == INVALID_SYMBOL && equal == INVALID_SYMBOL {
		if type_is_hashable(c, key) {
			return Key_Policy{kind = .Builtin}, ""
		}
		return Key_Policy{}, "needs an inherent `==` and `value.hash(seed: uint) -> uint` pair in its own package"
	}
	if hash == INVALID_SYMBOL {
		return Key_Policy{}, "has an inherent `==` but no inherent `hash`"
	}
	if equal == INVALID_SYMBOL {
		return Key_Policy{}, "has an inherent `hash` but no inherent `==`"
	}
	return Key_Policy{kind = .Inherent, hash = hash, equal = equal}, ""
}

// A missing choice is a broken phase contract, never permission to repeat
// overload/member lookup or silently substitute structural equality.
resolved_map_key_policy :: proc(c: ^Compiler, key: Type_Id) -> Key_Policy {
	return c.map_key_policies[key]
}

// An inherent member of the type's own package, never an extension one and never
// one the compiler contributed: a synthesized `hash` is the built-in policy
// itself, and finding it here would make every scalar key look user-defined.
// `members` on the type is exactly the inherent set (`src/impl.odin` keeps
// extensions in the extending package instead), and it is read from the key type
// itself rather than its underlying one, because a `distinct` type does not
// inherit the underlying type's operations (design.md "Distinct types").
@(private = "file")
inherent_member_named :: proc(c: ^Compiler, type: Type_Id, name: string) -> Symbol_Id {
	info := type_of(c, type)
	if info == nil {
		return INVALID_SYMBOL
	}
	wanted := intern_identifier(c, name)
	for member in info.members {
		sym := symbol_of(c, member)
		if sym != nil && sym.name == wanted && sym.kind == .Proc && sym.operator == "" &&
		   sym.synth == .None {
			return member
		}
	}
	return INVALID_SYMBOL
}

@(private = "file")
inherent_operator_named :: proc(c: ^Compiler, type: Type_Id, symbol_text: string) -> Symbol_Id {
	info := type_of(c, type)
	if info == nil {
		return INVALID_SYMBOL
	}
	for member in info.members {
		sym := symbol_of(c, member)
		// A delegated operator is the underlying type's own operation wrapped, so
		// it announces no policy of its own: the underlying type's hash is already
		// its coherent partner (design.md "Delegating operators").
		if sym != nil && sym.operator == symbol_text && !sym.delegated {
			return member
		}
	}
	return INVALID_SYMBOL
}

// ------------------------------------------------------------- checking --

check_hash_builtin :: proc(k: ^Checker, v: ^Expr_Call, ident: ^Expr_Ident, expected: Type_Id) {
	v.value_category = .Value
	if len(v.args) != 2 {
		errorf(k.c, v.span, "L0322", "`hash` takes 2 arguments, found %d", len(v.args))
		v.type = INVALID_TYPE
		return
	}
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
	// The built-in types own compiler-contributed `hash` methods; records and
	// unions use the method in their inherent `impl`. The free spelling selects
	// that one member in both cases.
	check_standard_alias(k, v, ident, expected, receiver_checked = true)
}

// --------------------------------------------------------- compile time --

// The integer image of one scalar, which is what the mix consumes. `+0` and `-0`
// hash identically because they compare equal.
hash_scalar_bits :: proc(c: ^Compiler, value: Const_Value, type: Type_Id, allocator: mem.Allocator = {}) -> u64 {
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
	storage := value_allocator(c, allocator)
	wrapped := bi_wrap(storage, value.integer, 64, false)
	bits, _ := bi_to_u64(storage, wrapped)
	return bits
}

hash_const :: proc(c: ^Compiler, value: Const_Value, type: Type_Id, seed: u64, allocator: mem.Allocator = {}) -> u64 {
	under := type_underlying(c, type)
	info := type_of(c, under)
	#partial switch type_kind(c, under) {
	case .String, .String_View, .Untyped_String:
		// Byte-wise, exactly as `loke_rt_v1_hash_bytes` does it at run time.
		result := seed
		for index in 0 ..< len(value.text) {
			result = (result ~ u64(value.text[index])) * HASH_MULTIPLIER
		}
		return result
	}
	if info != nil && info.kind == .Array {
		result := seed
		for index in 0 ..< int(info.count) {
			element := Const_Value{}
			if value.aggregate != nil && index < len(value.aggregate.elements) {
				element = value.aggregate.elements[index]
			}
			result = hash_const(c, element, info.element, result, allocator)
		}
		return result
	}
	return (seed ~ hash_scalar_bits(c, value, type, allocator)) * HASH_MULTIPLIER
}
